extends SceneTree

const Client = preload("res://addons/orca/scripts/api_client.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Attachments = preload("res://addons/orca/scripts/image_attachments.gd")
const Capability = preload("res://addons/orca/scripts/image_capability.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const ModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
var failures := PackedStringArray()
var serial := 0
var base: String = OS.get_environment("ORCA_PROVIDER_FIXTURE_URL")


func _init() -> void: call_deferred("run")


func run() -> void:
	await _qwen()
	await _anthropic()
	for failure in failures: printerr(failure)
	print("dedicated_provider_integration_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _qwen() -> void:
	var source := [{"role": "system", "content": "primary"}, {"role": "system", "content": "fresh editor context"}, {"role": "user", "content": "inspect"}]
	var tools := [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}}]
	var result := await request("qwen", "loop", source, tools)
	_expect(result.get("kind") == "completed", "Qwen streams fragmented tool calls")
	if result.get("kind") == "completed":
		var message: Dictionary = result["response"]["choices"][0]["message"]
		_expect(message.get("tool_calls", []).size() == 1 and message["tool_calls"][0]["function"]["arguments"] == "{\"path\":\"res://player.gd\"}", "Qwen reconstructs exact arguments")
		source.append(message)
		source.append({"role": "tool", "tool_call_id": "qwen-call", "content": "saved script source"})
		source.append({"role": "system", "content": "refreshed task context"})
		result = await request("qwen", "loop", source, tools)
		_expect(result.get("kind") == "completed" and result.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "Qwen complete", "Qwen accepts matching results and refreshed context")
	var probe := Probe.new()
	get_root().add_child(probe)
	var outcome := {}
	probe.probe_passed.connect(func(binding): outcome["binding"] = binding)
	probe.probe_failed.connect(func(_binding, error): outcome["error"] = error)
	probe.start_probe(profile("qwen", "probe"))
	var deadline := Time.get_ticks_msec() + 10000
	while outcome.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	_expect(outcome.has("binding"), "Qwen passes the actual synthetic two-request probe: " + str(outcome))
	probe.queue_free()
	result = await request("qwen", "cancel", [{"role": "user", "content": "stop"}], [], true)
	_expect(result.get("kind") == "cancelled", "Qwen cancellation has one terminal outcome")


func profile(provider: String, scenario: String) -> Dictionary:
	return {"provider": provider, "base_url": base + "/" + provider + "/" + scenario, "api_key": "synthetic-fixture-key", "model": "qwen-plus" if provider == "qwen" else "claude-sonnet-4-6", "reasoning_effort": "off" if provider == "qwen" else "high", "api_mode": "chat_completions" if provider == "qwen" else "anthropic_messages", "confirmed_origin": EndpointPolicy.inspect_base_url(base)["origin"]}


func request(provider: String, scenario: String, messages: Array, tools: Array, cancel_on_text: bool = false) -> Dictionary:
	serial += 1
	var id := serial
	var client := Client.new()
	get_root().add_child(client)
	var result := {}
	var terminals := {"count": 0}
	var visible := {"text": ""}
	client.request_completed.connect(func(request_id, response):
		_expect(request_id == id, "completion retains request identity")
		terminals["count"] += 1
		result.merge({"kind": "completed", "response": response}))
	client.request_failed.connect(func(request_id, error):
		_expect(request_id == id, "failure retains request identity")
		terminals["count"] += 1
		result.merge({"kind": "failed", "error": error}))
	client.request_cancelled.connect(func(request_id):
		_expect(request_id == id, "cancellation retains request identity")
		terminals["count"] += 1
		result["kind"] = "cancelled")
	client.stream_delta.connect(func(request_id, text):
		_expect(request_id == id, "stream retains request identity")
		visible["text"] += text
		if cancel_on_text: client.cancel_request())
	var config := profile(provider, scenario)
	if scenario == "image": config["image_input_override"] = {"binding": Capability.binding(config), "enabled": true}
	client.send_chat_completion(messages, tools, config, {Client.LIFECYCLE_REQUEST_ID_OPTION: id})
	var deadline := Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	await process_frame
	_expect(terminals["count"] == 1, "exactly one terminal signal: " + scenario)
	_expect(not client.is_requesting() and client._http_client == null and client._line_buffer.is_empty(), "request state is released: " + scenario)
	result["visible"] = visible["text"]
	client.queue_free()
	await process_frame
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)


func _anthropic() -> void:
	var tools := [{"type": "function", "function": {"name": "read_file", "description": "Read", "parameters": {"type": "object"}}}, {"type": "function", "function": {"name": "list_directory", "parameters": {"type": "object"}}}]
	var source := [{"role": "system", "content": "primary"}, {"role": "system", "content": "fresh context"}, {"role": "user", "content": "inspect"}]
	var result := await request("anthropic", "loop", source, tools)
	_expect(result.get("kind") == "completed" and not result.get("visible", "").contains("PRIVATE_THINKING"), "native stream separates signed thinking from visible content: " + str(result))
	if result.get("kind") == "completed":
		var message: Dictionary = result["response"]["choices"][0]["message"]
		_expect(message.get("tool_calls", []).size() == 2, "native parallel tool calls normalize")
		_expect(result["response"]["usage"].get("input_tokens") == 20 and result["response"]["usage"].get("output_tokens") == 9, "native cumulative usage and separate cache counters normalize once")
		source.append(message)
		for call in message.get("tool_calls", []): source.append({"role": "tool", "tool_call_id": call["id"], "content": "result " + call["id"]})
		source.append({"role": "system", "content": "refreshed native task context"})
		result = await request("anthropic", "loop", source, tools)
		_expect(result.get("kind") == "completed" and result.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "Claude complete", "native signed continuation and grouped tool results are accepted: " + str(result))
	var probe := Probe.new()
	get_root().add_child(probe)
	var outcome := {}
	probe.probe_passed.connect(func(binding): outcome["binding"] = binding)
	probe.probe_failed.connect(func(_binding, error): outcome["error"] = error)
	probe.start_probe(profile("anthropic", "probe"))
	var deadline := Time.get_ticks_msec() + 10000
	while outcome.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	_expect(outcome.has("binding"), "native two-request compatibility probe accepts exact acknowledgement: " + str(outcome))
	probe.queue_free()
	for scenario in ["error", "error_http", "truncated", "malformed", "duplicate", "unsupported", "hidden_only", "max_tokens"]:
		result = await request("anthropic", scenario, [{"role": "user", "content": "test"}], tools)
		_expect(result.get("kind") == "failed", "native malformed/incomplete response fails before tool dispatch: " + scenario)
		_expect(not JSON.stringify(result).contains("PRIVATE_THINKING") and not JSON.stringify(result).contains("signed_native"), "native provider errors cannot echo private continuation")
	result = await request("anthropic", "cancel", [{"role": "user", "content": "stop"}], [], true)
	_expect(result.get("kind") == "cancelled", "native Stop has one terminal outcome")
	result = await request("anthropic", "json", [{"role": "user", "content": "test JSON"}], [])
	_expect(result.get("kind") == "completed" and result.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "native JSON complete", "non-streaming native fallback normalizes: " + str(result))
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.BLUE)
	var record: Dictionary = Attachments.prepare_image(image)["image"]
	var image_source := [{"role": "user", "content": "Inspect image", "images": [record]}]
	var original := image_source.duplicate(true)
	result = await request("anthropic", "image", image_source, tools)
	_expect(result.get("kind") == "completed" and image_source == original, "native image projection preserves canonical bytes")
	if result.get("kind") == "completed":
		var message: Dictionary = result["response"]["choices"][0]["message"]
		image_source.append(message)
		for call in message.get("tool_calls", []): image_source.append({"role": "tool", "tool_call_id": call["id"], "content": "image result"})
		result = await request("anthropic", "image", image_source, tools)
		_expect(result.get("kind") == "completed", "images survive native tool continuation")
	var service := ModelService.new()
	get_root().add_child(service)
	var discovery := {}
	service.models_loaded.connect(func(_provider, models, _cached): discovery["models"] = models)
	service.models_failed.connect(func(_provider, error): discovery["error"] = error)
	service.fetch_models("anthropic", profile("anthropic", "discovery"))
	deadline = Time.get_ticks_msec() + 10000
	while discovery.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	_expect(discovery.get("models", []).size() == 1 and discovery["models"][0].get("image_input") == true and discovery["models"][0].get("context_window") == 200000, "native model discovery uses its headers and typed capability metadata: " + str(discovery))
	service.queue_free()
