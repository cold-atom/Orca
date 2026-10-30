@tool
extends Node

signal probe_step_changed(step: int)
signal probe_passed(binding: Dictionary)
signal probe_failed(binding: Dictionary, message: String)
signal probe_cancelled

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const DeepSeekCompatibility = preload("res://addons/orca/scripts/deepseek_response_compatibility.gd")
const RequestTimeouts = preload("res://addons/orca/scripts/request_timeouts.gd")

const PROBE_VERSION := 2
const PROBE_TIMEOUT_SECONDS := 45.0
const PROBE_FUNCTION := "orca_agent_probe"
const MAX_PROBE_ARGUMENT_BYTES := 1024
const MAX_PROBE_CALL_ID_BYTES := 256
const MAX_FINAL_CONTENT_BYTES := 1024
const CONTINUATION_CONTEXT := "ORCA SYNTHETIC CONTINUATION CHECK: The synthetic tool result is available. Return only the exact acknowledgement required by the initial instructions; do not call another tool. This fixed notice tests refreshed system context without including project or user data."

var _api_client
var _timer: Timer
var _state := "idle"
var _binding: Dictionary = {}
var _provider_config: Dictionary = {}
var _messages: Array = []
var _challenge := ""
var _request_id_serial := 0
var _expected_request_id := 0
var account_service


func _ready() -> void:
	if _api_client == null:
		_api_client = ApiClient.new()
	if _api_client.get_parent() == null:
		add_child(_api_client)
	_connect_client()
	if _api_client.get("account_service") != null or _api_client is ApiClient:
		_api_client.set("account_service", account_service)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = PROBE_TIMEOUT_SECONDS
	_timer.timeout.connect(_on_timeout)
	add_child(_timer)


func set_api_client_for_testing(client) -> void:
	_api_client = client


func start_probe(provider_config: Dictionary) -> bool:
	if is_running():
		return false
	var timeouts := RequestTimeouts.resolve(provider_config)
	if not timeouts.get("success", false):
		probe_failed.emit({}, str(timeouts["error"]))
		return false
	var binding_result := create_binding(provider_config)
	if not binding_result.get("success", false):
		probe_failed.emit({}, str(binding_result.get("error", "Could not bind compatibility probe.")))
		return false
	_binding = binding_result["binding"].duplicate(true)
	_provider_config = binding_result["config"].duplicate(true)
	_challenge = _generate_challenge()
	_messages = [
		{"role": "system", "content": "This is an isolated protocol compatibility test. Do not infer or discuss any project, files, editor state, or user data. First call the supplied function exactly once with the requested challenge and produce no other text. After receiving its tool result, reply exactly: ORCA_AGENT_PROBE_OK <challenge>, replacing <challenge> with the original challenge, and do not call another tool."},
		{"role": "user", "content": "Call %s exactly once with challenge \"%s\"." % [PROBE_FUNCTION, _challenge]}
	]
	_state = "first_request"
	_timer.start(RequestTimeouts.probe_timeout_seconds(_provider_config))
	_begin_probe_request(1, "first_request")
	return true


func cancel() -> void:
	if not is_running():
		return
	_state = "idle"
	_timer.stop()
	_api_client.cancel_request()
	_clear_sensitive_state()
	probe_cancelled.emit()


func is_running() -> bool:
	return _state != "idle"


static func create_binding(provider_config: Dictionary) -> Dictionary:
	var provider_id := str(provider_config.get("provider", "custom"))
	var authorization := EndpointPolicy.authorize_profile(provider_id, provider_config)
	if not authorization.get("success", false):
		return authorization
	var normalized_config: Dictionary = authorization.get("config", provider_config).duplicate(true)
	var model := str(normalized_config.get("model", ""))
	if model.is_empty() or model != model.strip_edges():
		return {"success": false, "error": "Select an exact model before testing Agent compatibility."}
	var provider = ProviderRegistry.get_provider(provider_id)
	var endpoint := EndpointPolicy.validate_generated_endpoint(provider.chat_url(normalized_config), str(authorization.get("origin", "")))
	if not endpoint.get("success", false):
		return endpoint
	return {"success": true, "config": normalized_config, "binding": {
		"probe_version": PROBE_VERSION,
		"provider": provider_id,
		"origin": str(endpoint.get("origin", "")),
		"base_url": str(normalized_config.get("base_url", "")),
		"chat_endpoint": str(endpoint.get("base_url", "")),
		"model": model,
		"reasoning_effort": str(normalized_config.get("reasoning_effort", "default")),
		"api_mode": provider.api_mode(normalized_config),
		"continuation_style": str(normalized_config.get("continuation_style", "standard")),
		"deepseek_format_version": DeepSeekCompatibility.FORMAT_VERSION if DeepSeekCompatibility.enabled(normalized_config) else 0,
		"hosted_identity": str(normalized_config.get("hosted_identity", "")),
		"capability_version": str(normalized_config.get("capability_version", ""))
	}}


static func record_matches_binding(record: Dictionary, binding: Dictionary) -> bool:
	if typeof(record) != TYPE_DICTIONARY:
		return false
	for key in ["probe_version", "provider", "origin", "base_url", "chat_endpoint", "model", "reasoning_effort"]:
		if record.get(key) != binding.get(key):
			return false
	if record.get("api_mode", "chat_completions") != binding.get("api_mode", "chat_completions") or record.get("continuation_style", "standard") != binding.get("continuation_style", "standard"):
		return false
	if record.get("deepseek_format_version", 0) != binding.get("deepseek_format_version", 0):
		return false
	for key in ["hosted_identity", "capability_version"]:
		if record.get(key, "") != binding.get(key, ""):
			return false
	return true


func _connect_client() -> void:
	_api_client.request_completed.connect(_on_request_completed)
	_api_client.request_failed.connect(_on_request_failed)
	_api_client.request_cancelled.connect(_on_request_cancelled)


func _on_request_completed(request_id: int, response: Dictionary) -> void:
	if request_id != _expected_request_id or not is_running():
		return
	_expected_request_id = 0
	if _provider_config.get("provider") == "orca_cloud":
		var metadata = response.get("_orca_cloud", {})
		if typeof(metadata) != TYPE_DICTIONARY or str(metadata.get("turn_binding", "")).is_empty():
			_fail("The hosted probe did not return a turn binding.")
			return
		_provider_config["hosted_turn_binding"] = metadata["turn_binding"]
	if _state == "first_request":
		var validated := _validate_first_response(response)
		if not validated.get("success", false):
			_fail(str(validated.get("error", "Probe tool call was incompatible.")))
			return
		var assistant_message: Dictionary = validated["assistant_message"]
		var call_id := str(validated["call_id"])
		_messages.append(assistant_message)
		_messages.append({"role": "tool", "tool_call_id": call_id, "content": JSON.stringify({"accepted": true, "challenge": _challenge, "required_reply": "ORCA_AGENT_PROBE_OK " + _challenge})})
		_messages.append({"role": "system", "content": CONTINUATION_CONTEXT})
		_state = "second_request"
		_begin_probe_request(2, "second_request")
		return
	if _state == "second_request":
		var error := _validate_final_response(response)
		if not error.is_empty():
			_fail(error)
			return
		var passed_binding := _binding.duplicate(true)
		_state = "idle"
		_timer.stop()
		_clear_sensitive_state()
		probe_passed.emit(passed_binding)


func _validate_first_response(response: Dictionary) -> Dictionary:
	var choices = response.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.size() != 1 or typeof(choices[0]) != TYPE_DICTIONARY:
		return {"success": false, "error": "Probe expected exactly one assistant choice."}
	var message = choices[0].get("message", {})
	var content = message.get("content", "") if typeof(message) == TYPE_DICTIONARY else ""
	if typeof(message) != TYPE_DICTIONARY or (content != null and not str(content).strip_edges().is_empty()):
		return {"success": false, "error": "Probe expected one tool call without assistant text."}
	var calls = message.get("tool_calls", [])
	if typeof(calls) != TYPE_ARRAY or calls.size() != 1 or typeof(calls[0]) != TYPE_DICTIONARY:
		return {"success": false, "error": "Probe expected exactly one tool call."}
	var call: Dictionary = calls[0]
	var call_id := str(call.get("id", ""))
	var function = call.get("function", {})
	if call.get("type") != "function" or call_id.is_empty() or call_id.to_utf8_buffer().size() > MAX_PROBE_CALL_ID_BYTES or typeof(function) != TYPE_DICTIONARY:
		return {"success": false, "error": "Probe tool call metadata was invalid."}
	if str(function.get("name", "")) != PROBE_FUNCTION or typeof(function.get("arguments")) != TYPE_STRING:
		return {"success": false, "error": "Probe function name or argument protocol was invalid."}
	var argument_text: String = function["arguments"]
	if argument_text.to_utf8_buffer().size() > MAX_PROBE_ARGUMENT_BYTES:
		return {"success": false, "error": "Probe arguments exceeded the compatibility limit."}
	var arguments = JSON.parse_string(argument_text)
	if typeof(arguments) != TYPE_DICTIONARY or arguments.keys() != ["challenge"] or arguments.get("challenge") != _challenge:
		return {"success": false, "error": "Probe challenge arguments did not match exactly."}
	return {"success": true, "assistant_message": message.duplicate(true), "call_id": call_id}


func _validate_final_response(response: Dictionary) -> String:
	var choices = response.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.size() != 1 or typeof(choices[0]) != TYPE_DICTIONARY:
		return "Probe continuation expected exactly one assistant choice."
	var message = choices[0].get("message", {})
	if typeof(message) != TYPE_DICTIONARY or not Array(message.get("tool_calls", [])).is_empty():
		return "Probe continuation attempted another tool call."
	if typeof(message.get("content")) != TYPE_STRING:
		return "Probe continuation did not return text acknowledgement content."
	var content: String = message["content"].strip_edges()
	if content.to_utf8_buffer().size() > MAX_FINAL_CONTENT_BYTES:
		return "Probe continuation acknowledgement exceeded the 1 KiB limit."
	var required := "ORCA_AGENT_PROBE_OK " + _challenge
	if content != required:
		var category := "extra formatting or text" if content.contains(required) else "missing or changed acknowledgement/challenge"
		var preview := content.replace(_challenge, "<challenge>").left(160)
		var clean := ""
		for character in preview:
			if character.unicode_at(0) >= 32:
				clean += character
			elif character in ["\n", "\r", "\t"]:
				clean += " "
		return "Probe continuation did not return the exact acknowledgement (%s). Synthetic reply: %s" % [category, clean if not clean.is_empty() else "<empty>"]
	return ""


func _probe_tool() -> Dictionary:
	return {"type": "function", "function": {
		"name": PROBE_FUNCTION,
		"description": "Synthetic Orca compatibility acknowledgement. It does not access files, editor state, processes, or external tools.",
		"parameters": {"type": "object", "properties": {"challenge": {"type": "string"}}, "required": ["challenge"], "additionalProperties": false}
	}}


func _generate_challenge() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


func _on_request_failed(request_id: int, error: Dictionary) -> void:
	if request_id != _expected_request_id or not is_running():
		return
	_expected_request_id = 0
	_fail(str(error.get("message", "Compatibility request failed.")))


func _on_request_cancelled(request_id: int) -> void:
	if request_id == _expected_request_id:
		_expected_request_id = 0


func _begin_probe_request(step: int, expected_state: String) -> void:
	_request_id_serial += 1
	_expected_request_id = _request_id_serial
	var request_id := _expected_request_id
	probe_step_changed.emit(step)
	if _state != expected_state or _expected_request_id != request_id:
		return
	var request_config := _provider_config.duplicate(true)
	if request_config.get("provider") == "orca_cloud":
		if account_service == null:
			_fail("Connect your Orca account before testing Agent tools.")
			return
		var auth: Dictionary = await account_service.authorization(str(request_config.get("hosted_identity", "")))
		if _state != expected_state or _expected_request_id != request_id:
			return
		if not auth.get("success", false):
			_fail("The Orca account connection expired. Reconnect and test again.")
			return
		request_config["api_key"] = auth["token"]
	_api_client.send_chat_completion(_messages, [_probe_tool()], request_config, {
		"allow_stream_options_retry": false,
		ApiClient.LIFECYCLE_REQUEST_ID_OPTION: request_id
	})


func _on_timeout() -> void:
	if is_running():
		var guidance := "" if _provider_config.get("provider") == "orca_cloud" else " Adjust %s for slow models." % RequestTimeouts.SETTINGS_LOCATION
		var message := "Compatibility probe timed out after %.0f seconds.%s" % [_timer.wait_time, guidance]
		_api_client.cancel_request()
		_fail(message)


func _fail(message: String) -> void:
	var failed_binding := _binding.duplicate(true)
	_state = "idle"
	_timer.stop()
	_clear_sensitive_state()
	probe_failed.emit(failed_binding, message.left(500))


func _clear_sensitive_state() -> void:
	_messages.clear()
	_provider_config.clear()
	_binding.clear()
	_challenge = ""
	_expected_request_id = 0
