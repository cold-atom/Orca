extends SceneTree

const Protocol = preload("res://addons/orca/scripts/responses_protocol.gd")
const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Registry = preload("res://addons/orca/scripts/provider_registry.gd")
var _failures := PackedStringArray()
var _config := {"provider": "azure", "base_url": "http://127.0.0.1:18473/foundry", "model": "gpt-6.1-sol", "api_mode": "responses", "reasoning_effort": "high"}


func _init() -> void:
	_test_round_trip()
	_test_projected_budget()
	_test_invalid_output()
	_test_streaming()
	_test_binding_and_deepseek()
	if _failures.is_empty():
		print("responses_protocol_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("responses_protocol_test: ", failure)
		quit(1)


func _reply() -> Dictionary:
	return {"status": "completed", "model": "gpt-6.1-sol", "output": [
		{"id": "rs_1", "type": "reasoning", "summary": [{"type": "summary_text", "text": "HIDDEN_SUMMARY"}], "encrypted_content": "opaque"},
		{"id": "msg_1", "type": "message", "role": "assistant", "status": "completed", "phase": "commentary", "content": [{"type": "output_text", "text": "Inspecting Ω", "annotations": []}]},
		{"id": "fc_1", "type": "function_call", "call_id": "call_1", "name": "read_file", "arguments": "{}", "status": "completed"}
	]}


func _test_round_trip() -> void:
	var converted := Protocol.completion(_reply(), _config)
	_expect(converted.get("success", false), "a completed response should normalize")
	var message: Dictionary = converted["response"]["choices"][0]["message"]
	_expect(message["tool_calls"][0]["id"] == "call_1", "controller identity must use call_id, not output item id")
	_expect(not JSON.stringify(message).contains("HIDDEN_SUMMARY"), "private summaries should never enter controller/display records")
	var messages := [{"role": "system", "content": "context"}, {"role": "user", "content": [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": "data:image/png;base64,fixture"}}]}, message, {"role": "tool", "tool_call_id": "call_1", "content": "result"}, {"role": "system", "content": "refreshed"}]
	var tools := [{"type": "function", "function": {"name": "read_file", "description": "read", "parameters": {"type": "object", "properties": {}}}}]
	var before := messages.duplicate(true)
	var body: Dictionary = Protocol.request_body(messages, tools, _config)["body"]
	_expect(messages == before, "projection must preserve canonical history")
	_expect(body["store"] == false and not body.has("previous_response_id") and not body.has("stream_options") and body["reasoning"] == {"effort": "high"}, "stateless reasoning requests should have the correct protocol")
	_expect(body["tools"][0]["name"] == "read_file" and body["tools"][0]["strict"] == false and not body["tools"][0].has("function"), "function schemas should flatten without imposing new strict-schema requirements")
	_expect(body["input"][1]["content"][1]["type"] == "input_image", "images should use Responses input_image")
	_expect(body["input"][2]["encrypted_content"] == "opaque" and body["input"][3]["phase"] == "commentary", "opaque reasoning and assistant phases must survive tool follow-ups")
	_expect(body["input"][5] == {"type": "function_call_output", "call_id": "call_1", "output": "result"} and body["input"][6]["role"] == "system", "matching tool results and refreshed context must retain order")
	_expect(not JSON.stringify(body).contains(Protocol.PRIVATE_FIELD) and not JSON.stringify(body).contains("binding"), "internal continuation envelopes must not leak to the wire")
	var other := _config.duplicate(true)
	other["model"] = "different-deployment"
	_expect(not JSON.stringify(Protocol.request_body(messages, tools, other)).contains("opaque"), "opaque output must never cross model/profile bindings")
	message[Protocol.PRIVATE_FIELD]["items"][2]["arguments"] = "changed"
	_expect(not Protocol.request_body(messages, tools, _config).get("success", true), "corrupt retained output must fail instead of changing a completed call")
	message = converted["response"]["choices"][0]["message"].duplicate(true)
	message[Protocol.PRIVATE_FIELD]["items"][0]["encrypted_content"] = "a".repeat(4096)
	_expect(Budget.estimate_tokens([message], []) > 1000, "opaque continuation bytes must count toward context pressure")


func _test_projected_budget() -> void:
	var reply := _reply()
	reply["output"][1]["content"][0]["text"] = "useful evidence ".repeat(1000)
	var message: Dictionary = Protocol.completion(reply, _config)["response"]["choices"][0]["message"]
	var before := message.duplicate(true)
	var canonical := Budget.estimate_tokens([message], [])
	var projected := Budget.estimate_tokens([message], [], true, false, {}, _config)
	_expect(projected < canonical - 3000, "Responses budget must count visible text once, not once per canonical representation")
	_expect(message == before, "wire budgeting must not compact or mutate canonical history")
	message[Protocol.PRIVATE_FIELD]["items"][0]["encrypted_content"] = "z".repeat(12000)
	_expect(Budget.estimate_tokens([message], [], true, false, {}, _config) > projected + 3500, "projected budgeting must retain private reasoning cost")
	message[Protocol.PRIVATE_FIELD]["items"][1]["content"][0]["text"] = "corrupt"
	_expect(Budget.estimate_tokens([message], [], true, false, {}, _config) == Budget.estimate_tokens([message], []), "invalid retained state must keep the conservative estimate, never authorize a smaller request")


func _test_invalid_output() -> void:
	for status in ["incomplete", "failed", "cancelled", "in_progress"]:
		var reply := _reply()
		reply["status"] = status
		_expect(not Protocol.completion(reply, _config).get("success", true), "noncompleted status must fail: " + status)
	for item in [
		{"id": "fc_2", "type": "function_call", "call_id": "call_1", "name": "read_file", "arguments": "{}"},
		{"id": "ws", "type": "web_search_call"},
		{"id": "msg_2", "type": "message", "role": "assistant", "content": [{"type": "refusal", "refusal": "no"}]},
		{"id": "rs_1", "type": "reasoning"}
	]:
		var reply := _reply()
		reply["output"].append(item)
		_expect(not Protocol.completion(reply, _config).get("success", true), "invalid, duplicate, refused, and non-Orca output must fail")
	_expect(not Protocol.completion({"status": "completed", "output": [{"id": "rs", "type": "reasoning", "encrypted_content": "opaque"}]}, _config).get("success", true), "reasoning-only completion must fail")
	var oversized := _reply()
	oversized["output"][0]["encrypted_content"] = "x".repeat(Protocol.MAX_REASONING_BYTES + 1)
	_expect(not Protocol.completion(oversized, _config).get("success", true), "encrypted reasoning must be bounded")


func _test_streaming() -> void:
	var client := ApiClient.new()
	client._configured_api_mode = "responses"
	client._request_config_snapshot = _config.duplicate(true)
	var deltas := PackedStringArray()
	client.stream_delta.connect(func(_id: int, text: String): deltas.append(text))
	var events := [
		{"type": "response.output_text.delta", "delta": "Inspecting Ω"},
		{"type": "response.reasoning_summary_text.delta", "delta": "HIDDEN_SUMMARY"},
		{"type": "response.function_call_arguments.delta", "output_index": 2, "delta": "{"},
		{"type": "response.function_call_arguments.delta", "output_index": 2, "delta": "}"},
		{"type": "response.completed", "response": _reply()}
	]
	var bytes := "".to_utf8_buffer()
	for event in events:
		bytes.append_array(("event: " + event["type"] + "\ndata: " + JSON.stringify(event) + "\n\n").to_utf8_buffer())
	for byte in bytes:
		client._consume_sse_bytes(PackedByteArray([byte]))
	_expect(client._stream_done and client._stream_error.is_empty() and not client._responses_reply.is_empty(), "byte-fragmented Responses SSE must complete")
	_expect("".join(deltas) == "Inspecting Ω", "only visible text should stream; UTF-8 must survive fragmentation")
	client._reset_stream_state()
	client._consume_responses_event({"type": "response.function_call_arguments.delta", "output_index": 2, "delta": "wrong"})
	client._consume_responses_event({"type": "response.completed", "response": _reply()})
	_expect(not client._stream_error.is_empty() and client._responses_reply.is_empty(), "inconsistent streamed arguments must never reach execution")
	client._reset_stream_state()
	client._consume_responses_event({"type": "response.incomplete", "response": {"status": "incomplete"}})
	_expect(client._stream_done and not client._stream_error.is_empty(), "an incomplete stream must fail")
	client.free()
	var cancelled_client := ApiClient.new()
	cancelled_client._configured_api_mode = "responses"
	cancelled_client._request_config_snapshot = _config.duplicate(true)
	cancelled_client._is_requesting = true
	cancelled_client._request_serial = 5
	cancelled_client.stream_delta.connect(func(_id: int, _text: String): cancelled_client.cancel_request())
	var same_chunk := ("data: " + JSON.stringify({"type": "response.output_text.delta", "delta": "Inspecting Ω"}) + "\n\ndata: " + JSON.stringify({"type": "response.completed", "response": _reply()}) + "\n\n").to_utf8_buffer()
	cancelled_client._consume_sse_bytes(same_chunk)
	_expect(cancelled_client._responses_reply.is_empty() and cancelled_client._responses_arguments.is_empty() and cancelled_client._request_config_snapshot.is_empty(), "Stop during a delta must not let the remaining same-chunk terminal repopulate old request state")
	cancelled_client.free()


func _test_binding_and_deepseek() -> void:
	var config := _config.duplicate(true)
	var bound: Dictionary = Probe.create_binding(config)["binding"]
	config["api_mode"] = "chat_completions"
	_expect(not Probe.record_matches_binding(bound, Probe.create_binding(config)["binding"]), "API changes must invalidate compatibility")
	var chat_binding: Dictionary = Probe.create_binding(config)["binding"]
	config["continuation_style"] = "deepseek"
	_expect(not Probe.record_matches_binding(chat_binding, Probe.create_binding(config)["binding"]), "continuation changes must invalidate compatibility")
	var provider = Registry.get_provider("azure")
	var messages := [{"role": "assistant", "content": "", "reasoning_content": "opaque-deepseek", Protocol.PRIVATE_FIELD: {"binding": "private"}}]
	_expect(provider.prepare_messages(messages, config)[0].get("reasoning_content") == "opaque-deepseek", "explicit DeepSeek continuation must retain reasoning")
	config["continuation_style"] = "standard"
	_expect(not provider.prepare_messages(messages, config)[0].has("reasoning_content"), "standard GPT requests must not receive DeepSeek reasoning")
	var body := {}
	Registry.get_provider("custom").apply_chat_options(body, "none")
	_expect(body == {"reasoning_effort": "none"}, "custom Chat must support explicit None, not omission")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
