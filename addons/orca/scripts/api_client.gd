@tool
extends Node
const ScriptReferences = preload("res://addons/orca/scripts/script_references.gd")
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")

const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const ResponsesProtocol = preload("res://addons/orca/scripts/responses_protocol.gd")
const DeepSeekCompatibility = preload("res://addons/orca/scripts/deepseek_response_compatibility.gd")
const RequestTimeouts = preload("res://addons/orca/scripts/request_timeouts.gd")

signal request_completed(request_id: int, response: Dictionary)
signal request_failed(request_id: int, error: Dictionary)
signal request_cancelled(request_id: int)
signal stream_started(request_id: int)
signal stream_delta(request_id: int, content: String)
signal cloud_metadata_received(request_id: int, metadata: Dictionary)

const CONNECT_TIMEOUT_MS := RequestTimeouts.CONNECT_SECONDS * 1000
const INACTIVITY_TIMEOUT_MS := 60000
# Long reasoning models may be active continuously, but an editor request must still terminate.
const RESPONSE_GENERATION_TIMEOUT_MS := RequestTimeouts.TOTAL_GENERATION_MS
const INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION := "_orca_internal_generation_timeout_ms"
const LIFECYCLE_REQUEST_ID_OPTION := "lifecycle_request_id"
const INCLUDE_HISTORY_IMAGES_OPTION := "_orca_include_history_images"
const GENERATION_TIMEOUT_MESSAGE := "The response exceeded the total generation deadline."
const MAX_RESPONSE_BYTES := 16 * 1024 * 1024
const MAX_SSE_LINE_BYTES := 1024 * 1024
const MAX_SSE_EVENT_BYTES := 1024 * 1024
const MAX_ASSISTANT_CONTENT_BYTES := 2 * 1024 * 1024
const MAX_REASONING_CONTENT_BYTES := 2 * 1024 * 1024
const MAX_TOOL_ARGUMENT_BYTES := 2 * 1024 * 1024
const MAX_TOOL_METADATA_BYTES := 1024 * 1024
const MAX_REASONING_DETAILS_BYTES := 2 * 1024 * 1024
const MAX_ERROR_BODY_BYTES := 64 * 1024
const MAX_PROVIDER_ERROR_CHARS := 2048
const MAX_REASONING_DETAILS := 256
const MAX_TOOL_CALLS_PER_RESPONSE := 16
const CONNECT_RETRY_DELAY_SECONDS := 0.5
const MAX_CONNECT_RETRIES := 1

var _config
var _http_client: HTTPClient
var _request_serial := 0
var _lifecycle_request_id := 0
var _is_requesting := false
var _cancel_requested := false
var _raw_response := PackedByteArray()
var _line_buffer := PackedByteArray()
var _event_data_lines := PackedStringArray()
var _skip_next_lf := false
var _is_first_sse_line := true
var _received_sse_event := false
var _stream_done := false
var _stream_error := ""
var _assistant_content := ""
var _tool_calls: Dictionary = {}
var _finish_reason = null
var _stream_usage: Dictionary = {}
var _request_model := ""
var _configured_request_model := ""
var _configured_api_url := ""
var _request_may_have_usage := false
var _configured_provider := ""
var _reasoning_content := ""
var _reasoning_details: Array = []
var _response_bytes_received := 0
var _event_data_bytes := 0
var _assistant_content_bytes := 0
var _reasoning_content_bytes := 0
var _tool_argument_bytes := 0
var _tool_metadata_bytes := 0
var _reasoning_details_bytes := 0
var _request_phase := "idle"
var _response_code := 0
var _generation_deadline_ms := 0
var _response_generation_timeout_ms := RESPONSE_GENERATION_TIMEOUT_MS
var _response_start_timeout_ms := CONNECT_TIMEOUT_MS
var _inactivity_timeout_ms := INACTIVITY_TIMEOUT_MS
var _legacy_timeout_defaults := false
var _partial_response_detected := false
var _configured_api_mode := "chat_completions"
var _request_config_snapshot: Dictionary = {}
var _responses_reply: Dictionary = {}
var _responses_arguments: Dictionary = {}
var _deepseek_prefix_filter
var account_service
var _cloud_metadata: Dictionary = {}
var _cloud_error: Dictionary = {}
var _cloud_event_error := false
var _cloud_tool_names: Array[String] = []


func _ready() -> void:
	_config = preload("res://addons/orca/scripts/config.gd")


func is_requesting() -> bool:
	return _is_requesting


func last_request_may_have_usage() -> bool:
	return _request_may_have_usage


func send_chat_completion(messages: Array, tools: Array = [], provider_config: Dictionary = {}, request_options: Dictionary = {}) -> void:
	var lifecycle_request_id := int(request_options.get(LIFECYCLE_REQUEST_ID_OPTION, 0))
	if _is_requesting:
		request_failed.emit(lifecycle_request_id, _make_error("A request is already in progress.", "state", false))
		return
	_request_may_have_usage = false

	var request_config: Dictionary = _config.get_active_provider_config() if provider_config.is_empty() else provider_config.duplicate(true)
	var provider_id := str(request_config.get("provider", "custom"))
	var authorization := EndpointPolicy.authorize_profile(provider_id, request_config)
	if not authorization.get("success", false):
		request_failed.emit(lifecycle_request_id, _make_error(str(authorization.get("error", "Endpoint is not authorized.")), "configuration", false))
		return
	request_config = authorization.get("config", request_config)
	var timeouts := RequestTimeouts.resolve(request_config)
	if not timeouts.get("success", false):
		request_failed.emit(lifecycle_request_id, _make_error(str(timeouts["error"]), "configuration", false))
		return
	var provider = ProviderRegistry.get_provider(provider_id)
	_configured_api_mode = provider.api_mode(request_config)
	var api_key = str(request_config.get("api_key", "")).strip_edges()
	if provider_id == "orca_cloud" and (api_key.length() > 8192 or api_key.contains("\r") or api_key.contains("\n") or api_key.contains(" ")):
		request_failed.emit(lifecycle_request_id, _make_error("Invalid Orca account credentials.", "configuration", false))
		return
	if api_key.is_empty() and not bool(provider.definition().get("auth_optional", false)):
		request_failed.emit(lifecycle_request_id, _make_error("API Key is missing. Please set it in Settings.", "configuration", false))
		return
	if str(request_config.get("model", "")).is_empty():
		request_failed.emit(lifecycle_request_id, _make_error("No model is selected. Choose a model in Settings.", "configuration", false))
		return

	var url = provider.chat_url(request_config)
	var generated_endpoint := EndpointPolicy.validate_generated_endpoint(url, str(authorization.get("origin", "")))
	if not generated_endpoint.get("success", false):
		request_failed.emit(lifecycle_request_id, _make_error(str(generated_endpoint.get("error", "Invalid API endpoint.")), "configuration", false))
		return
	_configured_api_url = url

	var endpoint := _parse_url(url)
	if endpoint.is_empty():
		request_failed.emit(lifecycle_request_id, _make_error("Invalid API URL. Use a complete http:// or https:// URL.", "configuration", false))
		return

	var reference_error := ScriptReferences.validate_messages(messages)
	if not reference_error.is_empty():
		request_failed.emit(lifecycle_request_id, _make_error(reference_error, "configuration", false))
		return
	var has_images := false
	var validated_images := {}
	for message in messages:
		if typeof(message) != TYPE_DICTIONARY:
			continue
		if typeof(message.get("images", [])) != TYPE_ARRAY:
			request_failed.emit(lifecycle_request_id, _make_error("Invalid image attachments.", "configuration", false))
			return
		var images: Array = message.get("images", [])
		if images.size() > ImageAttachments.MAX_IMAGES or (not images.is_empty() and (message.get("role") != "user" or typeof(message.get("content")) != TYPE_STRING)):
			request_failed.emit(lifecycle_request_id, _make_error("Invalid image attachments.", "configuration", false))
			return
		for image in images:
			var image_id: String = image.get("id", "") if typeof(image) == TYPE_DICTIONARY and typeof(image.get("id")) == TYPE_STRING else ""
			if image_id.length() != 64:
				request_failed.emit(lifecycle_request_id, _make_error("Invalid image attachments.", "configuration", false))
				return
			var cached: Dictionary = validated_images.get(image_id, {})
			# Validate identical pixel records once per request. Name/resized are
			# display-only; modified data/dimensions still require full validation.
			if not cached.is_empty() and typeof(image.get("data")) == TYPE_STRING and typeof(image.get("width")) in [TYPE_INT, TYPE_FLOAT] and typeof(image.get("height")) in [TYPE_INT, TYPE_FLOAT] and image["data"] == cached["data"] and image["width"] == cached["width"] and image["height"] == cached["height"]:
				continue
			if cached.is_empty() and validated_images.size() >= ImageAttachments.MAX_SESSION_IMAGES:
				request_failed.emit(lifecycle_request_id, _make_error("Image history exceeds the 32 unique-image request limit.", "configuration", false))
				return
			if not ImageAttachments.valid_record(image):
				request_failed.emit(lifecycle_request_id, _make_error("Invalid image attachments.", "configuration", false))
				return
			validated_images[image_id] = {"data": image["data"], "width": image["width"], "height": image["height"]}
		has_images = has_images or not images.is_empty()
	var image_capability := ImageCapability.resolve(request_config) if has_images else "supported"
	var include_history_images := image_capability == "supported"
	if request_options.has(INCLUDE_HISTORY_IMAGES_OPTION):
		if typeof(request_options[INCLUDE_HISTORY_IMAGES_OPTION]) != TYPE_BOOL:
			request_failed.emit(lifecycle_request_id, _make_error("Invalid request image policy.", "configuration", false))
			return
		include_history_images = request_options[INCLUDE_HISTORY_IMAGES_OPTION]
	if has_images:
		var current_user := ImageAttachments.latest_user_index(messages)
		var current_has_images: bool = current_user >= 0 and not messages[current_user].get("images", []).is_empty()
		if include_history_images and image_capability != "supported":
			request_failed.emit(lifecycle_request_id, _make_error("Image input support changed or is unconfirmed for this request. Choose a vision-capable model or continue in a new text-only turn.", "configuration", false))
			return
		if not include_history_images and current_has_images:
			request_failed.emit(lifecycle_request_id, _make_error("This request cannot send new image attachments. Remove the draft images or start a turn with a vision-capable model.", "configuration", false))
			return
	var projected := ImageAttachments.request_messages(ScriptReferences.request_messages(messages), include_history_images)
	var body: Dictionary
	if _configured_api_mode == "responses":
		var converted := ResponsesProtocol.request_body(projected, tools, request_config)
		if not converted.get("success", false):
			request_failed.emit(lifecycle_request_id, _make_error(str(converted.get("error", "Invalid Responses request.")), "configuration", false))
			return
		body = converted["body"]
	else:
		body = {"model": request_config.get("model", ""), "messages": provider.prepare_messages(projected, request_config), "stream": true, "stream_options": {"include_usage": true}}
		if not tools.is_empty():
			body["tools"] = tools
			body["tool_choice"] = "auto"
		provider.apply_chat_options(body, str(request_config.get("reasoning_effort", "default")))
		if provider_id == "orca_cloud":
			body["max_tokens"] = clampi(int(request_config.get("hosted_output_tokens", 8192)), 1, 8192)
		for message in body["messages"]:
			if typeof(message) == TYPE_DICTIONARY:
				message.erase(ResponsesProtocol.PRIVATE_FIELD)
	if JSON.stringify(body).to_utf8_buffer().size() > ImageAttachments.MAX_REQUEST_BYTES:
		request_failed.emit(lifecycle_request_id, _make_error("The request exceeds the 16 MiB request limit. Start a new conversation or reduce attachments.", "configuration", false))
		return

	_request_config_snapshot = request_config.duplicate(true)
	_reset_stream_state()
	_generation_deadline_ms = 0
	_response_generation_timeout_ms = RESPONSE_GENERATION_TIMEOUT_MS
	_response_start_timeout_ms = int(timeouts["response_start_ms"])
	_inactivity_timeout_ms = int(timeouts["inactivity_ms"])
	_legacy_timeout_defaults = bool(timeouts["legacy_defaults"])
	if request_options.has(INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION):
		_response_generation_timeout_ms = clampi(int(request_options[INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION]), 1, RESPONSE_GENERATION_TIMEOUT_MS)
	_partial_response_detected = false
	_request_model = str(body["model"])
	_configured_request_model = _request_model
	_configured_provider = str(request_config.get("provider", "custom"))
	_is_requesting = true
	_cancel_requested = false
	_lifecycle_request_id = lifecycle_request_id
	_request_serial += 1
	_generation_deadline_ms = Time.get_ticks_msec() + _response_generation_timeout_ms
	var headers: PackedStringArray = provider.request_headers(api_key)
	if provider_id == "orca_cloud":
		headers.append("X-Orca-Contract-Version: 1")
		headers.append("X-Orca-Tool-Contract: orca-tools-v1")
		headers.append("Idempotency-Key: " + Crypto.new().generate_random_bytes(16).hex_encode())
		var binding := str(request_config.get("hosted_turn_binding", ""))
		if not binding.is_empty():
			if not _cloud_uuid(binding):
				_fail_request(_request_serial, "Invalid hosted turn binding.", "configuration", false)
				return
			headers.append("X-Orca-Turn-Binding: " + binding)
		for field in ["capability_version", "continuation_style"]:
			var value := str(request_config.get(field, ""))
			if value.length() > 64 or value.contains("\n") or value.contains("\r"):
				_fail_request(_request_serial, "Invalid hosted profile metadata.", "configuration", false)
				return
			if not value.is_empty():
				headers.append(("X-Orca-Capability-Version: " if field == "capability_version" else "X-Orca-Continuation-Style: ") + value)
		for tool in tools:
			if typeof(tool) == TYPE_DICTIONARY and typeof(tool.get("function")) == TYPE_DICTIONARY:
				_cloud_tool_names.append(str(tool["function"].get("name", "")))
	_perform_request(_request_serial, endpoint, headers, body, provider_id != "orca_cloud" and bool(request_options.get("allow_stream_options_retry", true)), MAX_CONNECT_RETRIES)


func cancel_request() -> void:
	if not _is_requesting:
		return
	var lifecycle_request_id := _lifecycle_request_id
	_cancel_cloud_operation()
	_cancel_requested = true
	_request_serial += 1
	_is_requesting = false
	if _http_client != null:
		_http_client.close()
		_http_client = null
	_reset_stream_state()
	_request_config_snapshot.clear()
	_generation_deadline_ms = 0
	_response_generation_timeout_ms = RESPONSE_GENERATION_TIMEOUT_MS
	_response_start_timeout_ms = CONNECT_TIMEOUT_MS
	_inactivity_timeout_ms = INACTIVITY_TIMEOUT_MS
	_legacy_timeout_defaults = false
	request_cancelled.emit(lifecycle_request_id)


func _perform_request(request_id: int, endpoint: Dictionary, base_headers: PackedStringArray, body: Dictionary, allow_usage_retry: bool, connect_retries_remaining: int) -> void:
	if _configured_provider == "orca_cloud" and _cloud_tool_names.is_empty():
		for tool in body.get("tools", []):
			_cloud_tool_names.append(str(tool.get("function", {}).get("name", "")))
	if _fail_if_generation_timed_out(request_id):
		return
	_http_client = HTTPClient.new()
	_http_client.read_chunk_size = 4096
	var json_body := JSON.stringify(body)
	var headers := base_headers.duplicate()
	headers.append("Content-Length: " + str(json_body.to_utf8_buffer().size()))

	var tls_options: TLSOptions = null
	if endpoint["scheme"] == "https":
		tls_options = TLSOptions.client()

	_request_phase = "connecting"
	var error := _http_client.connect_to_host(endpoint["host"], endpoint["port"], tls_options)
	if error != OK:
		await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Failed to connect to the API host: " + error_string(error), "connection")
		return

	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	while _is_current_request(request_id) and _http_client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		if _fail_if_generation_timed_out(request_id):
			return
		error = _http_client.poll()
		if error != OK:
			await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Connection failed: " + error_string(error), "connection")
			return
		if Time.get_ticks_msec() > deadline:
			await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, "Connection timed out.", "timeout")
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if _http_client.get_status() != HTTPClient.STATUS_CONNECTED:
		await _retry_connection_or_fail(request_id, endpoint, base_headers, body, allow_usage_retry, connect_retries_remaining, _status_error(_http_client.get_status()), _status_category(_http_client.get_status()))
		return

	_request_phase = "submitting"
	error = _http_client.request(HTTPClient.METHOD_POST, endpoint["target"], headers, json_body)
	if error != OK:
		_fail_request(request_id, "Failed to initiate HTTP request: " + error_string(error), "connection", true)
		return
	# Once HTTPClient accepts the POST, a later failure may still have incurred provider usage.
	_request_may_have_usage = true

	_request_phase = "waiting_for_response"
	# Custom/local response-start budgets span headers and the first body bytes.
	# The default hosted policy restores its separate body wait after headers.
	deadline = Time.get_ticks_msec() + _response_start_timeout_ms
	while _is_current_request(request_id) and _http_client.get_status() == HTTPClient.STATUS_REQUESTING:
		error = _http_client.poll()
		if error != OK:
			_fail_request(request_id, "HTTP request failed: " + error_string(error), "connection", true)
			return
		if _fail_if_generation_timed_out(request_id):
			return
		if Time.get_ticks_msec() > deadline:
			_fail_request(request_id, _response_start_timeout_message(), "timeout", true)
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if not _http_client.has_response():
		var response_status := _http_client.get_status()
		_fail_request(request_id, _status_error(response_status), _status_category(response_status), true)
		return

	var response_code := _http_client.get_response_code()
	_response_code = response_code
	var response_headers := _http_client.get_response_headers_as_dictionary()
	if _configured_provider == "orca_cloud":
		var receipt := _get_header(response_headers, "x-orca-request-id")
		var binding := _get_header(response_headers, "x-orca-turn-binding")
		if _cloud_uuid(receipt):
			_cloud_metadata["request_id"] = receipt
		if _cloud_uuid(binding):
			_cloud_metadata["turn_binding"] = binding
		_cloud_metadata["retry_after"] = clampi(int(_get_header(response_headers, "retry-after")), 0, 3600)
		if response_code == HTTPClient.RESPONSE_OK and (not _cloud_uuid(receipt) or not _cloud_uuid(binding)):
			_fail_request(request_id, "Orca Cloud returned invalid request ownership metadata.", "malformed_response", false)
			return
		if response_code == HTTPClient.RESPONSE_OK and (_get_header(response_headers, "x-orca-capability-version") != str(_request_config_snapshot.get("capability_version", "")) or _get_header(response_headers, "x-orca-continuation-style") != str(_request_config_snapshot.get("continuation_style", "standard"))):
			_fail_request(request_id, "The hosted model capability changed. Refresh Models and retest compatibility.", "malformed_response", false)
			return
		cloud_metadata_received.emit(_lifecycle_request_id, _cloud_metadata.duplicate(true))
		if not _is_current_request(request_id):
			return
	var content_type := _get_header(response_headers, "content-type").to_lower()
	var media_type := content_type.split(";", false, 1)[0].strip_edges()
	var is_sse := media_type == "text/event-stream"
	var is_json := _is_json_media_type(media_type)
	if response_code == HTTPClient.RESPONSE_OK:
		if is_sse:
			stream_started.emit(_lifecycle_request_id)
			if not _is_current_request(request_id):
				return

	_request_phase = "receiving_response"
	var last_activity := Time.get_ticks_msec()
	if _legacy_timeout_defaults:
		# Default hosted/managed requests retain the original separate 30-second
		# header wait and 60-second body wait, including before the first bytes.
		deadline = last_activity + _inactivity_timeout_ms
	while _is_current_request(request_id):
		if _fail_if_generation_timed_out(request_id):
			return
		if _response_bytes_received == 0 and Time.get_ticks_msec() > deadline:
			_fail_request(request_id, _inactivity_timeout_message() if _legacy_timeout_defaults else _response_start_timeout_message(), "timeout", false)
			return
		error = _http_client.poll()
		if error != OK:
			_fail_request(request_id, "Connection failed while receiving the response: " + error_string(error), "connection", false)
			return

		var received_data := false
		while _http_client.get_status() == HTTPClient.STATUS_BODY:
			if _fail_if_generation_timed_out(request_id):
				return
			var chunk := _http_client.read_response_body_chunk()
			if chunk.is_empty():
				break
			received_data = true
			last_activity = Time.get_ticks_msec()
			_response_bytes_received += chunk.size()
			if response_code == HTTPClient.RESPONSE_OK and is_sse:
				_consume_sse_bytes(chunk)
				if not _is_current_request(request_id):
					return
				if _stream_done:
					if _stream_error.is_empty():
						_complete_stream(request_id)
					else:
						_fail_request(request_id, _stream_error, _stream_error_category(), false)
					return
			else:
				_raw_response.append_array(chunk)
				var buffered_limit := MAX_ERROR_BODY_BYTES if response_code != HTTPClient.RESPONSE_OK else MAX_RESPONSE_BYTES
				if _raw_response.size() > buffered_limit:
					var message := "HTTP %d returned an error body larger than the %d KiB safety limit." % [response_code, MAX_ERROR_BODY_BYTES / 1024] if response_code != HTTPClient.RESPONSE_OK else "The JSON response exceeded the %s safety limit." % _format_bytes(MAX_RESPONSE_BYTES)
					_fail_request(request_id, message, "response_limit", false)
					return
			if _response_bytes_received > MAX_RESPONSE_BYTES:
				_fail_request(request_id, "The raw streamed response exceeded the %s aggregate transport limit (%s received). SSE framing, hidden reasoning, and tool arguments count toward this limit." % [_format_bytes(MAX_RESPONSE_BYTES), _format_bytes(_response_bytes_received)], "response_limit", false)
				return

		var status := _http_client.get_status()
		if status in [HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
			_fail_request(request_id, _status_error(status), _status_category(status), false)
			return
		if status in [HTTPClient.STATUS_CONNECTED, HTTPClient.STATUS_DISCONNECTED]:
			break
		if _response_bytes_received > 0 and not received_data and Time.get_ticks_msec() - last_activity > _inactivity_timeout_ms:
			_fail_request(request_id, _inactivity_timeout_message(), "timeout", false)
			return
		if _fail_if_generation_timed_out(request_id):
			return
		await get_tree().process_frame

	if not _is_current_request(request_id):
		return
	if _fail_if_generation_timed_out(request_id):
		return
	if response_code != HTTPClient.RESPONSE_OK:
		var error_body := _raw_response.get_string_from_utf8().strip_edges()
		if _configured_provider == "orca_cloud":
			var cloud = JSON.parse_string(error_body)
			_cloud_error = _normalized_cloud_error(cloud.get("error", {}) if typeof(cloud) == TYPE_DICTIONARY else {})
			_fail_request(request_id, str(_cloud_error["message"]), "http", false)
			return
		if allow_usage_retry and response_code in [400, 422] and error_body.to_lower().contains("stream_options"):
			_http_client.close()
			_http_client = null
			_reset_stream_state()
			body.erase("stream_options")
			await _perform_request(request_id, endpoint, base_headers, body, false, MAX_CONNECT_RETRIES)
			return
		var error_message := _format_http_error(response_code, error_body)
		_fail_request(request_id, error_message, "http", response_code in [408, 425, 429, 500, 502, 503, 504])
		return

	if is_json:
		if _configured_provider == "orca_cloud":
			_fail_request(request_id, "Orca Cloud must return a completed SSE stream.", "malformed_response", false)
			return
		_complete_json_response(request_id)
		return
	if not is_sse:
		_fail_request(request_id, "The API returned an unexpected Content-Type: %s." % (media_type if not media_type.is_empty() else "missing"), "malformed_response", false)
		return

	if _configured_provider == "orca_cloud" and (not _line_buffer.is_empty() or not _event_data_lines.is_empty()):
		_fail_request(request_id, "The hosted stream ended with an incomplete event.", "connection", false)
		return
	_finish_sse_input()
	if _stream_done:
		if _stream_error.is_empty():
			_complete_stream(request_id)
		else:
			_fail_request(request_id, _stream_error, _stream_error_category(), false)
		return
	if _configured_provider != "orca_cloud" and _received_sse_event and _finish_reason != null:
		_complete_stream(request_id)
		return

	_fail_request(request_id, "The response stream ended before its completion marker.", "connection", false)


func _consume_sse_bytes(bytes: PackedByteArray) -> void:
	var generation := _request_serial
	for byte in bytes:
		if _skip_next_lf:
			_skip_next_lf = false
			if byte == 10:
				continue
		if byte == 13:
			if not _valid_cloud_utf8_line():
				return
			_process_sse_line(_line_buffer.get_string_from_utf8())
			if generation != _request_serial:
				return
			_line_buffer.clear()
			_skip_next_lf = true
		elif byte == 10:
			if not _valid_cloud_utf8_line():
				return
			_process_sse_line(_line_buffer.get_string_from_utf8())
			if generation != _request_serial:
				return
			_line_buffer.clear()
		else:
			_line_buffer.append(byte)
			if _line_buffer.size() > MAX_SSE_LINE_BYTES:
				_stream_error = "A streamed response line exceeded the 1 MiB safety limit."
				_stream_done = true
				return


func _process_sse_line(line: String) -> void:
	if _is_first_sse_line:
		_is_first_sse_line = false
		if line.begins_with(String.chr(0xfeff)):
			line = line.substr(1)
	if line.is_empty():
		_dispatch_sse_event()
		return
	if line.begins_with(":"):
		return

	var separator := line.find(":")
	var field := line if separator == -1 else line.substr(0, separator)
	var value := "" if separator == -1 else line.substr(separator + 1)
	if value.begins_with(" "):
		value = value.substr(1)
	if field == "data":
		_event_data_bytes += value.to_utf8_buffer().size()
		if not _event_data_lines.is_empty():
			_event_data_bytes += 1
		if _event_data_bytes > MAX_SSE_EVENT_BYTES:
			_stream_error = "A streamed response event exceeded the 1 MiB safety limit."
			_stream_done = true
			return
		_event_data_lines.append(value)
	elif field == "event" and value == "error":
		_cloud_event_error = true


func _dispatch_sse_event() -> void:
	if _event_data_lines.is_empty():
		return
	var payload := "\n".join(_event_data_lines)
	_event_data_lines.clear()
	_event_data_bytes = 0
	_received_sse_event = true
	if payload.strip_edges() == "[DONE]":
		if _configured_provider == "orca_cloud" and (payload != "[DONE]" or _finish_reason == null or _cloud_event_error):
			_stream_error = "Orca Cloud ended without a valid successful completion."
		_stream_done = true
		return

	var json := JSON.new()
	if json.parse(payload) != OK:
		_stream_error = "The API returned a malformed streaming event."
		_stream_done = true
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		if _configured_provider == "orca_cloud":
			_stream_error = "Invalid hosted stream event."
			_stream_done = true
		return
	if _configured_provider == "orca_cloud" and (_cloud_event_error or data.has("error")):
		_cloud_error = _normalized_cloud_error(data.get("error", {}))
		_stream_error = str(_cloud_error["message"])
		_stream_done = true
		return
	if _configured_api_mode == "responses":
		_consume_responses_event(data)
		return
	if data.has("model"):
		_request_model = str(data["model"])
		if _configured_provider == "orca_cloud" and _request_model != _configured_request_model:
			_stream_error = "The hosted stream returned a different model profile."
			_stream_done = true
			return
		var model_error := _local_model_mismatch_error(_request_model)
		if not model_error.is_empty():
			_stream_error = model_error
			_stream_done = true
			return
	if data.has("usage"):
		var normalized_usage := _normalize_usage(data["usage"])
		if not normalized_usage.is_empty():
			_stream_usage = normalized_usage
	if data.has("error"):
		var api_error = data["error"]
		if typeof(api_error) == TYPE_DICTIONARY:
			_stream_error = str(api_error.get("message", "The API returned a streaming error."))
		else:
			_stream_error = str(api_error)
		_stream_done = true
		return

	var choices = data.get("choices", [])
	if _configured_provider == "orca_cloud" and (typeof(choices) != TYPE_ARRAY or choices.size() > 1 or (choices.is_empty() and not data.has("usage"))):
		_stream_error = "Invalid hosted completion choices."
		_stream_done = true
		return
	if typeof(choices) != TYPE_ARRAY or choices.is_empty():
		return
	var choice = choices[0]
	if _configured_provider == "orca_cloud" and (typeof(choice) != TYPE_DICTIONARY or choice.get("index") != 0 or typeof(choice.get("delta")) != TYPE_DICTIONARY or (_finish_reason != null and (not choice.get("delta", {}).is_empty() or choice.get("finish_reason") != null))):
		_stream_error = "Invalid hosted completion ordering."
		_stream_done = true
		return
	if typeof(choice) != TYPE_DICTIONARY:
		return
	var delta = choice.get("delta", {})
	if _configured_provider == "orca_cloud":
		if delta.has("reasoning") or delta.has("reasoning_details") or (typeof(delta.get("reasoning_content")) == TYPE_STRING and not delta["reasoning_content"].is_empty() and _request_config_snapshot.get("continuation_style", "standard") != "reasoning_content"):
			_stream_error = "The hosted profile returned unsupported private continuation."
			_stream_done = true
			return
		for field in ["content", "reasoning_content"]:
			if delta.get(field) != null and typeof(delta[field]) != TYPE_STRING:
				_stream_error = "Invalid hosted content delta."
				_stream_done = true
				return
	if typeof(delta) != TYPE_DICTIONARY:
		return

	var content = delta.get("content")
	if typeof(content) == TYPE_STRING and not content.is_empty():
		_assistant_content_bytes += content.to_utf8_buffer().size()
		if _assistant_content_bytes > MAX_ASSISTANT_CONTENT_BYTES:
			_stream_error = "Assistant text exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		_assistant_content += content
		var generation := _request_serial
		_emit_visible_delta(content)
		if generation != _request_serial:
			return
	var reasoning_content = delta.get("reasoning_content", delta.get("reasoning", null))
	if typeof(reasoning_content) == TYPE_STRING and not reasoning_content.is_empty():
		_reasoning_content_bytes += reasoning_content.to_utf8_buffer().size()
		if _reasoning_content_bytes > MAX_REASONING_CONTENT_BYTES:
			_stream_error = "Provider reasoning content exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		_reasoning_content += reasoning_content
	var reasoning_details = delta.get("reasoning_details", [])
	if typeof(reasoning_details) == TYPE_ARRAY:
		_accumulate_reasoning_details(reasoning_details)

	var tool_call_deltas = delta.get("tool_calls", [])
	if typeof(tool_call_deltas) == TYPE_ARRAY:
		for tool_call_delta in tool_call_deltas:
			_accumulate_tool_call(tool_call_delta)

	if choice.get("finish_reason") != null:
		_finish_reason = choice.get("finish_reason")


func _consume_responses_event(data: Dictionary) -> void:
	var event_type := str(data.get("type", ""))
	if event_type in ["error", "response.failed", "response.incomplete"]:
		var error = data.get("error", data.get("response", {}).get("error", {}) if typeof(data.get("response")) == TYPE_DICTIONARY else {})
		_stream_error = _sanitize_provider_error(str(error.get("message", "Responses did not complete successfully."))) if typeof(error) == TYPE_DICTIONARY else "Responses did not complete successfully."
		_stream_done = true
		return
	if event_type.ends_with(".delta"):
		var delta = data.get("delta")
		if typeof(delta) != TYPE_STRING:
			_stream_error = "Responses returned an invalid streaming delta."
			_stream_done = true
			return
		if event_type == "response.output_text.delta":
			_assistant_content_bytes += delta.to_utf8_buffer().size()
			if _assistant_content_bytes > MAX_ASSISTANT_CONTENT_BYTES:
				_stream_error = "Assistant text exceeded the 2 MiB safety limit."
				_stream_done = true
				return
			_assistant_content += delta
			_emit_visible_delta(delta)
		elif event_type == "response.function_call_arguments.delta":
			var index = data.get("output_index")
			if typeof(index) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(index)) or float(index) != floor(float(index)) or index < 0 or index >= ResponsesProtocol.MAX_ITEMS:
				_stream_error = "Responses returned an invalid function output index."
				_stream_done = true
				return
			_tool_argument_bytes += delta.to_utf8_buffer().size()
			if _tool_argument_bytes > MAX_TOOL_ARGUMENT_BYTES:
				_stream_error = "Tool-call arguments exceeded the 2 MiB safety limit."
				_stream_done = true
				return
			_responses_arguments[int(index)] = str(_responses_arguments.get(int(index), "")) + delta
		elif event_type.begins_with("response.reasoning"):
			_reasoning_content_bytes += delta.to_utf8_buffer().size()
			if _reasoning_content_bytes > MAX_REASONING_CONTENT_BYTES:
				_stream_error = "Provider reasoning exceeded the 2 MiB safety limit."
				_stream_done = true
		return
	if event_type == "response.output_item.added":
		_partial_response_detected = true
	if event_type != "response.completed":
		return
	var raw_response = data.get("response")
	if typeof(raw_response) != TYPE_DICTIONARY:
		_stream_error = "Responses returned an invalid completion event."
		_stream_done = true
		return
	var converted := ResponsesProtocol.completion(raw_response, _request_config_snapshot)
	if not converted.get("success", false):
		_stream_error = str(converted.get("error", "Invalid Responses completion."))
		_stream_done = true
		return
	var response: Dictionary = converted["response"]
	var final_text: String = str(converted.get("raw_content", response["choices"][0]["message"]["content"]))
	if not _assistant_content.is_empty() and _assistant_content != final_text:
		_stream_error = "Responses completion text did not match its streamed text."
		_stream_done = true
		return
	for index in _responses_arguments:
		var output: Array = raw_response["output"]
		if index >= output.size() or output[index].get("type") != "function_call" or output[index].get("arguments") != _responses_arguments[index]:
			_stream_error = "Responses completion arguments did not match their streamed arguments."
			_stream_done = true
			return
	var generation := _request_serial
	_flush_visible_prefix()
	if generation != _request_serial:
		return
	response["usage"] = _normalize_usage(response.get("usage", {}))
	_responses_reply = response
	_stream_done = true


func _emit_visible_delta(content: String) -> void:
	var visible := content
	if DeepSeekCompatibility.enabled(_request_config_snapshot):
		if _deepseek_prefix_filter == null:
			_deepseek_prefix_filter = DeepSeekCompatibility.new()
		visible = _deepseek_prefix_filter.push(content)
	if not visible.is_empty():
		stream_delta.emit(_lifecycle_request_id, visible)


func _flush_visible_prefix() -> void:
	if _deepseek_prefix_filter != null:
		var visible: String = _deepseek_prefix_filter.finish()
		if not visible.is_empty():
			stream_delta.emit(_lifecycle_request_id, visible)


func _add_request_identity(response: Dictionary) -> void:
	response["requested_model"] = _configured_request_model
	response["requested_api_url"] = _configured_api_url
	response["requested_provider"] = _configured_provider


func _accumulate_tool_call(delta) -> void:
	if typeof(delta) != TYPE_DICTIONARY:
		return
	var index := int(delta.get("index", 0))
	var tool_call: Dictionary = _tool_calls.get(index, {
		"id": "",
		"type": "function",
		"function": {"name": "", "arguments": ""}
	})
	if typeof(delta.get("id")) == TYPE_STRING:
		tool_call["id"] += delta["id"]
	if typeof(delta.get("type")) == TYPE_STRING:
		tool_call["type"] = delta["type"]
	var function_delta = delta.get("function", {})
	if typeof(function_delta) == TYPE_DICTIONARY:
		var function: Dictionary = tool_call["function"]
		if typeof(function_delta.get("name")) == TYPE_STRING:
			function["name"] += function_delta["name"]
		if typeof(function_delta.get("arguments")) == TYPE_STRING:
			_tool_argument_bytes += function_delta["arguments"].to_utf8_buffer().size()
			if _tool_argument_bytes > MAX_TOOL_ARGUMENT_BYTES:
				_stream_error = "Tool-call arguments exceeded the 2 MiB safety limit."
				_stream_done = true
				return
			function["arguments"] += function_delta["arguments"]
		tool_call["function"] = function
	var extra_content = delta.get("extra_content")
	if typeof(extra_content) == TYPE_DICTIONARY:
		_tool_metadata_bytes += JSON.stringify(extra_content).to_utf8_buffer().size()
		if _tool_metadata_bytes > MAX_TOOL_METADATA_BYTES:
			_stream_error = "Tool-call metadata exceeded the 1 MiB safety limit."
			_stream_done = true
			return
		tool_call["extra_content"] = _merge_stream_metadata(tool_call.get("extra_content", {}), extra_content)
	_tool_calls[index] = tool_call


func _merge_stream_metadata(existing, incoming, depth: int = 0):
	if depth >= 8 or typeof(existing) != TYPE_DICTIONARY or typeof(incoming) != TYPE_DICTIONARY:
		return incoming.duplicate(true) if typeof(incoming) in [TYPE_DICTIONARY, TYPE_ARRAY] else incoming
	var merged: Dictionary = existing.duplicate(true)
	for key in incoming:
		var value = incoming[key]
		if typeof(value) == TYPE_DICTIONARY and typeof(merged.get(key)) == TYPE_DICTIONARY:
			merged[key] = _merge_stream_metadata(merged[key], value, depth + 1)
		elif typeof(value) == TYPE_STRING and typeof(merged.get(key)) == TYPE_STRING:
			merged[key] += value
		else:
			merged[key] = value.duplicate(true) if typeof(value) in [TYPE_DICTIONARY, TYPE_ARRAY] else value
	return merged


func _accumulate_reasoning_details(deltas: Array) -> void:
	for local_index in range(deltas.size()):
		var raw_detail = deltas[local_index]
		if typeof(raw_detail) != TYPE_DICTIONARY:
			continue
		var detail: Dictionary = raw_detail
		_reasoning_details_bytes += JSON.stringify(detail).to_utf8_buffer().size()
		if _reasoning_details_bytes > MAX_REASONING_DETAILS_BYTES:
			_stream_error = "Provider reasoning details exceeded the 2 MiB safety limit."
			_stream_done = true
			return
		var detail_index := _reasoning_detail_index(detail)
		if detail_index < 0 or detail_index >= MAX_REASONING_DETAILS:
			_stream_error = "The provider returned too many reasoning detail blocks."
			_stream_done = true
			return
		while _reasoning_details.size() <= detail_index:
			_reasoning_details.append({})
		var accumulated: Dictionary = _reasoning_details[detail_index]
		for key in detail:
			var value = detail[key]
			if key in ["text", "summary", "data", "signature"] and typeof(value) == TYPE_STRING and typeof(accumulated.get(key)) == TYPE_STRING:
				accumulated[key] += value
			else:
				accumulated[key] = value
		_reasoning_details[detail_index] = accumulated


func _reasoning_detail_index(detail: Dictionary) -> int:
	if detail.has("index"):
		return maxi(0, int(detail["index"]))
	var detail_id := str(detail.get("id", ""))
	if not detail_id.is_empty():
		for index in range(_reasoning_details.size()):
			if str(_reasoning_details[index].get("id", "")) == detail_id:
				return index
	return _reasoning_details.size()


func _finish_sse_input() -> void:
	var generation := _request_serial
	if not _line_buffer.is_empty():
		_process_sse_line(_line_buffer.get_string_from_utf8())
		if generation != _request_serial:
			return
		_line_buffer.clear()
	if not _event_data_lines.is_empty() and not _stream_done:
		_dispatch_sse_event()


func _complete_stream(request_id: int) -> void:
	if not _is_current_request(request_id):
		return
	if _fail_if_generation_timed_out(request_id):
		return
	if _configured_api_mode == "responses":
		if _responses_reply.is_empty():
			_fail_request(request_id, "Responses stream ended without a completed response.", "malformed_response", false)
			return
		var response := _responses_reply.duplicate(true)
		_add_request_identity(response)
		if _finish_request(request_id):
			request_completed.emit(_lifecycle_request_id, response)
		return
	var completed_tool_calls := _stream_tool_calls()
	var visible_content := DeepSeekCompatibility.normalize(_assistant_content) if DeepSeekCompatibility.enabled(_request_config_snapshot) else _assistant_content
	var completion_error := _validate_completion(visible_content, completed_tool_calls, _finish_reason)
	if _configured_provider == "orca_cloud":
		for call in completed_tool_calls:
			if str(call.get("function", {}).get("name", "")) not in _cloud_tool_names or typeof(JSON.parse_string(str(call.get("function", {}).get("arguments", "")))) != TYPE_DICTIONARY:
				completion_error = "The hosted response returned an unoffered or invalid tool call."
	if not completion_error.is_empty():
		_fail_request(request_id, completion_error, "malformed_response", false)
		return
	_flush_visible_prefix()
	if not _is_current_request(request_id):
		return
	var assistant_message := {
		"role": "assistant",
		"content": visible_content
	}
	if not _tool_calls.is_empty():
		assistant_message["tool_calls"] = completed_tool_calls
	if not _reasoning_content.is_empty():
		assistant_message["reasoning_content"] = _reasoning_content
	if not _reasoning_details.is_empty():
		assistant_message["reasoning_details"] = _reasoning_details.duplicate(true)

	var response := {
		"choices": [{
			"message": assistant_message,
			"finish_reason": _finish_reason
		}],
		"model": _request_model,
		"requested_model": _configured_request_model,
		"requested_api_url": _configured_api_url,
		"requested_provider": _configured_provider
	}
	if not _stream_usage.is_empty():
		response["usage"] = _stream_usage.duplicate(true)
	if _configured_provider == "orca_cloud":
		response["_orca_cloud"] = _cloud_metadata.duplicate(true)
	var model_error := _local_model_mismatch_error(_request_model)
	if not model_error.is_empty():
		_fail_request(request_id, model_error, "model_mismatch", false)
		return
	if _finish_request(request_id):
		request_completed.emit(_lifecycle_request_id, response)


func _complete_json_response(request_id: int) -> void:
	if not _is_current_request(request_id):
		return
	if _fail_if_generation_timed_out(request_id):
		return
	var json := JSON.new()
	if json.parse(_raw_response.get_string_from_utf8()) != OK:
		_fail_request(request_id, "Failed to parse the API response.", "malformed_response", false)
		return
	var data = json.get_data()
	if typeof(data) != TYPE_DICTIONARY:
		_fail_request(request_id, "Invalid API response format.", "malformed_response", false)
		return
	if _configured_api_mode == "responses":
		_partial_response_detected = typeof(data.get("output")) == TYPE_ARRAY and not data["output"].is_empty()
		var converted := ResponsesProtocol.completion(data, _request_config_snapshot)
		if not converted.get("success", false):
			_fail_request(request_id, str(converted.get("error", "Invalid Responses response.")), "malformed_response", false)
			return
		data = converted["response"]
		data["usage"] = _normalize_usage(data.get("usage", {}))
	elif DeepSeekCompatibility.enabled(_request_config_snapshot):
		var choices = data.get("choices", [])
		if typeof(choices) == TYPE_ARRAY and not choices.is_empty() and typeof(choices[0]) == TYPE_DICTIONARY:
			var message = choices[0].get("message")
			if typeof(message) == TYPE_DICTIONARY and typeof(message.get("content")) == TYPE_STRING:
				_partial_response_detected = _json_has_partial_response(data)
				if message["content"].to_utf8_buffer().size() > MAX_ASSISTANT_CONTENT_BYTES:
					_fail_request(request_id, "Assistant text exceeded the 2 MiB safety limit.", "response_limit", false)
					return
				message["content"] = DeepSeekCompatibility.normalize(message["content"])
	_partial_response_detected = _partial_response_detected or _json_has_partial_response(data)
	var response_error := _validate_json_response(data)
	if not response_error.is_empty():
		_fail_request(request_id, response_error, "malformed_response", false)
		return
	if _configured_api_mode != "responses":
		data["choices"][0]["message"].erase(ResponsesProtocol.PRIVATE_FIELD)
	data["requested_model"] = _configured_request_model
	data["requested_api_url"] = _configured_api_url
	data["requested_provider"] = _configured_provider
	var model_error := _local_model_mismatch_error(str(data.get("model", "")))
	if not model_error.is_empty():
		_fail_request(request_id, model_error, "model_mismatch", false)
		return
	if _finish_request(request_id):
		request_completed.emit(_lifecycle_request_id, data)


func _finish_request(request_id: int) -> bool:
	if not _is_current_request(request_id):
		return false
	_is_requesting = false
	if _http_client != null:
		_http_client.close()
		_http_client = null
	_reset_stream_state()
	_generation_deadline_ms = 0
	_response_generation_timeout_ms = RESPONSE_GENERATION_TIMEOUT_MS
	_response_start_timeout_ms = CONNECT_TIMEOUT_MS
	_inactivity_timeout_ms = INACTIVITY_TIMEOUT_MS
	_legacy_timeout_defaults = false
	_partial_response_detected = false
	_request_config_snapshot.clear()
	return true


func _fail_request(request_id: int, message: String, category: String, retryable: bool) -> void:
	if not _is_current_request(request_id):
		return
	var error := _make_error(message, category, retryable)
	if _configured_provider == "orca_cloud":
		error.merge(_cloud_error, true)
		error["cloud_receipt"] = _cloud_metadata.duplicate(true)
		if _response_code == 401 and account_service != null:
			account_service.call_deferred("invalidate_access", str(_request_config_snapshot.get("hosted_identity", "")))
		_cancel_cloud_operation()
	if _finish_request(request_id):
		request_failed.emit(_lifecycle_request_id, error)


func _retry_connection_or_fail(request_id: int, endpoint: Dictionary, base_headers: PackedStringArray, body: Dictionary, allow_usage_retry: bool, retries_remaining: int, message: String, category: String) -> void:
	if _fail_if_generation_timed_out(request_id):
		return
	if retries_remaining <= 0:
		_fail_request(request_id, message, category, true)
		return
	if _http_client != null:
		_http_client.close()
		_http_client = null
	var retry_at_ms := Time.get_ticks_msec() + int(CONNECT_RETRY_DELAY_SECONDS * 1000.0)
	while _is_current_request(request_id) and Time.get_ticks_msec() < retry_at_ms:
		if _fail_if_generation_timed_out(request_id):
			return
		await get_tree().process_frame
	if not _is_current_request(request_id):
		return
	if _fail_if_generation_timed_out(request_id):
		return
	_reset_stream_state()
	await _perform_request(request_id, endpoint, base_headers, body, allow_usage_retry, retries_remaining - 1)


func _is_current_request(request_id: int) -> bool:
	return _is_requesting and not _cancel_requested and request_id == _request_serial


func _valid_cloud_utf8_line() -> bool:
	if _configured_provider != "orca_cloud" or _line_buffer.get_string_from_utf8().to_utf8_buffer() == _line_buffer:
		return true
	_stream_error = "The hosted stream contained invalid UTF-8."
	_stream_done = true
	return false


static func _cloud_uuid(value: String) -> bool:
	return value.length() == 36 and value.count("-") == 4 and value.replace("-", "").length() == 32 and value.replace("-", "").is_valid_hex_number(false)


func _normalized_cloud_error(raw) -> Dictionary:
	var messages := {
		"insufficient_credits": "Your Orca allowance cannot cover this request. Open Account → Orca Console to manage usage; completed work has been preserved.",
		"model_access_required": "This model requires an eligible Orca subscription. Choose an included model or open Orca Console.",
		"invalid_credentials": "Your Orca connection expired or was revoked. Reconnect in Account.",
		"account_suspended": "Your Orca account cannot currently make requests. Open Orca Console.",
		"upstream_malformed": "The hosted provider returned an incomplete or invalid response. No partial tools were executed.",
		"request_cancelled": "The hosted request was cancelled. It may still have incurred usage.",
		"request_exists": "This hosted operation already exists. It was not replayed.",
		"idempotency_conflict": "The hosted request key conflicts with an existing operation. It was not replayed.",
		"profile_changed": "The hosted capability changed. Refresh Models and retest compatibility.",
		"rate_limited": "Orca Cloud is busy or rate-limited. Wait before starting another request.",
		"cloud_request_failed": "Orca Cloud could not complete this request. Check your account and backend connection; completed work has been preserved."
	}
	var code := str(raw.get("code", "")) if typeof(raw) == TYPE_DICTIONARY else ""
	if _response_code == 401:
		code = "invalid_credentials"
	elif _response_code == 429:
		code = "rate_limited"
	if not messages.has(code):
		code = "cloud_request_failed"
	if typeof(raw) == TYPE_DICTIONARY and _cloud_uuid(str(raw.get("request_id", ""))):
		_cloud_metadata["request_id"] = raw["request_id"]
	return {"code": code, "message": messages[code], "retryable": false}


func _cancel_cloud_operation() -> void:
	if _configured_provider == "orca_cloud" and account_service != null and _cloud_uuid(str(_cloud_metadata.get("request_id", ""))):
		account_service.call_deferred("cancel_remote_request", str(_cloud_metadata["request_id"]), str(_request_config_snapshot.get("api_key", "")))


func _reset_stream_state() -> void:
	_cloud_metadata.clear()
	_cloud_error.clear()
	_cloud_tool_names.clear()
	_cloud_event_error = false
	_deepseek_prefix_filter = null
	_responses_reply.clear()
	_responses_arguments.clear()
	_raw_response.clear()
	_line_buffer.clear()
	_event_data_lines.clear()
	_skip_next_lf = false
	_is_first_sse_line = true
	_received_sse_event = false
	_stream_done = false
	_stream_error = ""
	_assistant_content = ""
	_tool_calls.clear()
	_finish_reason = null
	_stream_usage.clear()
	_reasoning_content = ""
	_reasoning_details.clear()
	_response_bytes_received = 0
	_event_data_bytes = 0
	_assistant_content_bytes = 0
	_reasoning_content_bytes = 0
	_tool_argument_bytes = 0
	_tool_metadata_bytes = 0
	_reasoning_details_bytes = 0
	_request_phase = "idle"
	_response_code = 0


func _validate_tool_calls() -> String:
	return _validate_tool_call_array(_stream_tool_calls())


func _stream_tool_calls() -> Array:
	var calls: Array = []
	var indices := _tool_calls.keys()
	indices.sort()
	for index in indices:
		calls.append(_tool_calls[index])
	return calls


func _validate_json_response(data: Dictionary) -> String:
	var choices = data.get("choices")
	if typeof(choices) != TYPE_ARRAY or choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
		return "The provider returned an invalid choices array."
	var message = choices[0].get("message")
	if typeof(message) != TYPE_DICTIONARY:
		return "The provider returned an invalid assistant message."
	if message.has("content") and message.get("content") != null and typeof(message.get("content")) != TYPE_STRING:
		return "The provider returned assistant content in an invalid format."
	var content := str(message.get("content", "")) if message.get("content") != null else ""
	var tool_calls = message.get("tool_calls", [])
	return _validate_completion(content, tool_calls, choices[0].get("finish_reason"))


func _validate_completion(content: String, tool_calls, finish_reason) -> String:
	var tool_call_error := _validate_tool_call_array(tool_calls)
	if not tool_call_error.is_empty():
		return tool_call_error
	var has_content := not content.strip_edges().is_empty()
	var has_tool_calls: bool = typeof(tool_calls) == TYPE_ARRAY and not tool_calls.is_empty()
	if not has_content and not has_tool_calls:
		return "The provider completed without visible assistant content or a valid tool call."
	# Some otherwise compatible providers omit or extend finish reasons. The
	# meaningful-output invariant remains the boundary in those cases.
	if finish_reason == null or str(finish_reason).strip_edges().is_empty():
		return ""
	var normalized_reason := str(finish_reason).strip_edges().to_lower()
	if normalized_reason in ["length", "max_tokens", "max_output_tokens", "content_filter", "safety", "blocked", "moderation"]:
		return "The provider stopped before completing the response (finish reason: %s)." % normalized_reason
	if normalized_reason == "stop":
		if has_tool_calls:
			var provider = ProviderRegistry.get_provider(_configured_provider)
			if not provider.allows_stop_finish_with_tool_calls():
				return "The provider returned tool calls with a contradictory stop finish reason."
		return ""
	if normalized_reason == "tool_calls":
		if not has_tool_calls:
			return "The provider reported a tool-call finish without a valid tool call."
		return ""
	return ""


func _json_has_partial_response(data: Dictionary) -> bool:
	var choices = data.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or choices.is_empty() or typeof(choices[0]) != TYPE_DICTIONARY:
		return false
	var message = choices[0].get("message", {})
	if typeof(message) != TYPE_DICTIONARY:
		return false
	var content = message.get("content")
	if typeof(content) == TYPE_STRING and not content.strip_edges().is_empty():
		return true
	var reasoning_content = message.get("reasoning_content")
	if typeof(reasoning_content) == TYPE_STRING and not reasoning_content.is_empty():
		return true
	var reasoning_details = message.get("reasoning_details")
	if typeof(reasoning_details) == TYPE_ARRAY and not reasoning_details.is_empty():
		return true
	return typeof(message.get("tool_calls")) == TYPE_ARRAY and not message.get("tool_calls").is_empty()


func _validate_tool_call_array(tool_calls) -> String:
	if typeof(tool_calls) != TYPE_ARRAY:
		return "The provider returned tool_calls in an invalid format."
	if tool_calls.size() > MAX_TOOL_CALLS_PER_RESPONSE:
		return "The provider returned more than %d tool calls in one response." % MAX_TOOL_CALLS_PER_RESPONSE
	var seen_ids: Dictionary = {}
	for raw_call in tool_calls:
		if typeof(raw_call) != TYPE_DICTIONARY:
			return "The provider returned an invalid tool call."
		var tool_call: Dictionary = raw_call
		if str(tool_call.get("type", "")) != "function":
			return "The provider returned a tool call with an invalid type."
		var call_id := str(tool_call.get("id", "")).strip_edges()
		if call_id.is_empty():
			return "The provider returned a tool call without an ID."
		if seen_ids.has(call_id):
			return "The provider returned duplicate tool-call IDs."
		seen_ids[call_id] = true
		var function = tool_call.get("function", {})
		if typeof(function) != TYPE_DICTIONARY or str(function.get("name", "")).strip_edges().is_empty():
			return "The provider returned a tool call without a function name."
		if not function.has("arguments") or typeof(function.get("arguments")) != TYPE_STRING:
			return "The provider returned tool-call arguments in an invalid format."
	return ""


func _make_error(message: String, category: String, retryable: bool) -> Dictionary:
	return {
		"message": message,
		"category": category,
		"phase": _request_phase,
		"retryable": retryable,
		"http_status": _response_code,
		"bytes_received": _response_bytes_received,
		"response_started": _response_code > 0,
		"partial_response": _partial_response_detected or _assistant_content_bytes > 0 or _reasoning_content_bytes > 0 or _reasoning_details_bytes > 0 or not _tool_calls.is_empty()
	}


func _response_generation_timed_out() -> bool:
	return _generation_deadline_ms > 0 and Time.get_ticks_msec() > _generation_deadline_ms


func _response_start_timeout_message() -> String:
	var waiting_for := "return response headers" if _legacy_timeout_defaults else "begin sending response data"
	return "The API did not %s within %.1f seconds.%s" % [waiting_for, _response_start_timeout_ms / 1000.0, _timeout_settings_guidance()]


func _inactivity_timeout_message() -> String:
	return "The response stream timed out after %.1f seconds without data.%s" % [_inactivity_timeout_ms / 1000.0, _timeout_settings_guidance()]


func _timeout_settings_guidance() -> String:
	return "" if _configured_provider == "orca_cloud" else " For slow model loading or generation, adjust %s. The total request limit is 10 minutes." % RequestTimeouts.SETTINGS_LOCATION


func _fail_if_generation_timed_out(request_id: int) -> bool:
	if not _response_generation_timed_out():
		return false
	_fail_request(request_id, GENERATION_TIMEOUT_MESSAGE, "timeout", false)
	return true


func _is_json_media_type(media_type: String) -> bool:
	return media_type == "application/json" or media_type.ends_with("+json")


func _format_bytes(byte_count: int) -> String:
	if byte_count >= 1024 * 1024:
		return "%.2f MiB" % (float(byte_count) / float(1024 * 1024))
	if byte_count >= 1024:
		return "%.1f KiB" % (float(byte_count) / 1024.0)
	return "%d bytes" % byte_count


func _normalize_usage(raw_usage) -> Dictionary:
	if typeof(raw_usage) != TYPE_DICTIONARY:
		return {}
	var input_value = raw_usage.get("prompt_tokens", raw_usage.get("input_tokens", null))
	var output_value = raw_usage.get("completion_tokens", raw_usage.get("output_tokens", null))
	if typeof(input_value) not in [TYPE_INT, TYPE_FLOAT] or typeof(output_value) not in [TYPE_INT, TYPE_FLOAT]:
		return {}
	var input_tokens := int(input_value)
	var output_tokens := int(output_value)
	if input_tokens < 0 or output_tokens < 0:
		return {}
	var total_value = raw_usage.get("total_tokens", input_tokens + output_tokens)
	var total_tokens := int(total_value) if typeof(total_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens + output_tokens
	if total_tokens < 0:
		total_tokens = input_tokens + output_tokens
	var cached_value = raw_usage.get("cached_tokens", 0)
	var cached_tokens := int(cached_value) if typeof(cached_value) in [TYPE_INT, TYPE_FLOAT] else 0
	var details = raw_usage.get("prompt_tokens_details", raw_usage.get("input_tokens_details", {}))
	if typeof(details) == TYPE_DICTIONARY:
		var detailed_cached = details.get("cached_tokens", cached_tokens)
		if typeof(detailed_cached) in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = int(detailed_cached)
		var detailed_cache_write = details.get("cache_write_tokens", null)
		if typeof(detailed_cache_write) in [TYPE_INT, TYPE_FLOAT]:
			raw_usage["cache_write_tokens"] = int(detailed_cache_write)
	var cache_hit_value = raw_usage.get("prompt_cache_hit_tokens", null)
	if typeof(cache_hit_value) in [TYPE_INT, TYPE_FLOAT]:
		cached_tokens = int(cache_hit_value)
	var cache_read_value = raw_usage.get("cache_read_input_tokens", null)
	var cache_write_value = raw_usage.get("cache_creation_input_tokens", raw_usage.get("cache_write_tokens", 0))
	var cache_write_tokens := int(cache_write_value) if typeof(cache_write_value) in [TYPE_INT, TYPE_FLOAT] else 0
	var regular_value = raw_usage.get("regular_input_tokens", null)
	var regular_input_tokens := int(regular_value) if typeof(regular_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens - cached_tokens - cache_write_tokens
	var has_separate_cache_counters: bool = typeof(cache_read_value) in [TYPE_INT, TYPE_FLOAT] or raw_usage.has("cache_creation_input_tokens")
	if has_separate_cache_counters:
		if typeof(cache_read_value) not in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = 0
		else:
			cached_tokens = int(cache_read_value)
		regular_input_tokens = int(input_value)
		input_tokens = regular_input_tokens + cached_tokens + cache_write_tokens
	elif typeof(regular_value) in [TYPE_INT, TYPE_FLOAT]:
		regular_input_tokens = int(regular_value)
	else:
		regular_input_tokens = input_tokens - cached_tokens - cache_write_tokens
	var usage := {
		"input_tokens": input_tokens,
		"regular_input_tokens": maxi(0, regular_input_tokens),
		"output_tokens": output_tokens,
		"total_tokens": maxi(total_tokens, input_tokens + output_tokens),
		"cached_tokens": clampi(cached_tokens, 0, input_tokens),
		"cache_write_tokens": clampi(cache_write_tokens, 0, input_tokens)
	}
	var reported_cost = raw_usage.get("cost", raw_usage.get("total_cost", null))
	if reported_cost != null and (typeof(reported_cost) == TYPE_FLOAT or typeof(reported_cost) == TYPE_INT) and float(reported_cost) >= 0.0:
		usage["cost"] = float(reported_cost)
	return usage


func _parse_url(url: String) -> Dictionary:
	var inspected := EndpointPolicy.inspect_endpoint(url)
	return inspected if inspected.get("success", false) else {}


func _format_http_error(response_code: int, error_body: String) -> String:
	var provider_message := ""
	var parsed = JSON.parse_string(error_body) if error_body.begins_with("{") else null
	if typeof(parsed) == TYPE_DICTIONARY:
		var error = parsed.get("error", null)
		if typeof(error) == TYPE_DICTIONARY and typeof(error.get("message")) == TYPE_STRING:
			provider_message = str(error["message"])
		elif typeof(error) == TYPE_STRING:
			provider_message = str(error)
		elif typeof(parsed.get("message")) == TYPE_STRING:
			provider_message = str(parsed["message"])
	elif not error_body.is_empty() and not error_body.begins_with("<"):
		provider_message = error_body
	provider_message = _sanitize_provider_error(provider_message)
	var lowered := provider_message.to_lower()
	if "does not support chat" in lowered or "embedding model" in lowered or "cannot generate chat" in lowered:
		return "The selected model does not support chat. Choose a chat-capable model in Settings or enter a different Model ID."
	return "Provider returned HTTP %d%s" % [response_code, ": " + provider_message if not provider_message.is_empty() else "."]


func _sanitize_provider_error(message: String) -> String:
	var sanitized := ""
	for character in message:
		var code := character.unicode_at(0)
		if code >= 32 or character in ["\n", "\t"]:
			sanitized += character
	return sanitized.strip_edges().left(MAX_PROVIDER_ERROR_CHARS)


func _local_model_mismatch_error(actual_model: String) -> String:
	if _configured_provider not in ["ollama", "lmstudio", "local_openai"] or "embed" not in _configured_request_model.to_lower() or actual_model.is_empty() or actual_model == _configured_request_model:
		return ""
	return "The local provider served model '%s' instead of the selected model '%s'. The selected model may not support chat or may not be loaded." % [actual_model.left(256), _configured_request_model.left(256)]


func _stream_error_category() -> String:
	if _stream_error.contains("limit"):
		return "response_limit"
	if _stream_error.begins_with("The local provider served model"):
		return "model_mismatch"
	return "malformed_response"


func _get_header(headers: Dictionary, requested_name: String) -> String:
	for header_name in headers:
		if str(header_name).to_lower() == requested_name:
			return str(headers[header_name])
	return ""


func _status_error(status: HTTPClient.Status) -> String:
	match status:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "Cannot resolve the API hostname."
		HTTPClient.STATUS_CANT_CONNECT:
			return "Cannot connect to the API host."
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "TLS handshake with the API host failed."
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "The API connection failed."
		_:
			return "The API connection closed unexpectedly."


func _status_category(status: HTTPClient.Status) -> String:
	if status == HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
		return "tls"
	if status == HTTPClient.STATUS_CANT_RESOLVE:
		return "dns"
	return "connection"
