extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_media_types()
	_test_fragmented_sse_and_eof_flush()
	_test_streamed_tool_metadata()
	_test_structured_error_metadata()
	_test_tool_call_validation()
	if _failures.is_empty():
		print("api_client_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("api_client_test: ", failure)
	quit(1)


func _test_media_types() -> void:
	var client = ApiClient.new()
	_expect(client._is_json_media_type("application/json"), "application/json should be recognized")
	_expect(client._is_json_media_type("application/problem+json"), "+json media types should be recognized")
	_expect(not client._is_json_media_type("text/event-stream"), "SSE must not be treated as JSON")
	client.free()


func _test_fragmented_sse_and_eof_flush() -> void:
	var client = ApiClient.new()
	client._reset_stream_state()
	var deltas := PackedStringArray()
	client.stream_delta.connect(func(content: String): deltas.append(content))
	var event := "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":\"stop\"}]}\n\n"
	var bytes := event.to_utf8_buffer()
	client._consume_sse_bytes(bytes.slice(0, 17))
	client._consume_sse_bytes(bytes.slice(17))
	client._consume_sse_bytes("data: [DONE]".to_utf8_buffer())
	client._finish_sse_input()
	_expect("".join(deltas) == "Hello", "fragmented SSE content should be reconstructed")
	_expect(client._stream_done, "an unterminated final DONE event should complete at clean EOF")
	_expect(client._raw_response.is_empty(), "SSE parsing should not retain a raw response copy")
	client.free()


func _test_streamed_tool_metadata() -> void:
	var client = ApiClient.new()
	client._reset_stream_state()
	client._accumulate_tool_call({
		"index": 0,
		"id": "call_1",
		"type": "function",
		"function": {"name": "read_file", "arguments": "{}"},
		"extra_content": {"google": {"thought_signature": "opaque-"}}
	})
	client._accumulate_tool_call({
		"index": 0,
		"extra_content": {"google": {"thought_signature": "signature"}}
	})
	var tool_call: Dictionary = client._tool_calls.get(0, {})
	_expect(tool_call.get("extra_content", {}).get("google", {}).get("thought_signature") == "opaque-signature", "streamed tool calls should preserve fragmented opaque provider metadata")
	_expect(client._validate_tool_calls().is_empty(), "opaque tool metadata should not invalidate an otherwise valid call")
	client.free()


func _test_structured_error_metadata() -> void:
	var client = ApiClient.new()
	client._request_phase = "receiving_response"
	client._response_code = 200
	client._response_bytes_received = 4096
	client._assistant_content_bytes = 10
	var error: Dictionary = client._make_error("Disconnected", "connection", false)
	_expect(error.get("phase") == "receiving_response", "failure metadata should retain its transport phase")
	_expect(error.get("http_status") == 200, "failure metadata should retain its HTTP status")
	_expect(error.get("bytes_received") == 4096, "failure metadata should retain received bytes")
	_expect(error.get("partial_response") == true, "failure metadata should identify partial output")
	client.free()


func _test_tool_call_validation() -> void:
	var client = ApiClient.new()
	client._tool_calls = {
		0: {"id": "", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	}
	_expect(not client._validate_tool_calls().is_empty(), "empty tool-call IDs should be rejected")
	client._tool_calls = {
		0: {"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
		1: {"id": "call_1", "type": "function", "function": {"name": "search_files", "arguments": "{}"}}
	}
	_expect(not client._validate_tool_calls().is_empty(), "duplicate tool-call IDs should be rejected")
	client._tool_calls = {
		0: {"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	}
	_expect(client._validate_tool_calls().is_empty(), "valid tool calls should be accepted")
	var duplicate_json_calls := [
		{"id": "call_json", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
		{"id": "call_json", "type": "function", "function": {"name": "search_files", "arguments": "{}"}}
	]
	_expect(not client._validate_tool_call_array(duplicate_json_calls).is_empty(), "non-streamed JSON duplicate tool IDs should be rejected")
	var too_many := []
	for index in range(ApiClient.MAX_TOOL_CALLS_PER_RESPONSE + 1):
		too_many.append({"id": "call_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}})
	_expect(not client._validate_tool_call_array(too_many).is_empty(), "one provider response must have a bounded tool-call count")
	_expect(not client._validate_tool_call_array([{"id": "call_bad", "function": {"name": "read_file", "arguments": {}}}]).is_empty(), "tool arguments must remain protocol strings")
	_expect(not client._validate_tool_call_array([{"id": "call_type", "type": "custom", "function": {"name": "read_file", "arguments": "{}"}}]).is_empty(), "only function tool-call types should be accepted")
	_expect(not client._validate_tool_call_array([{"id": "call_missing_args", "type": "function", "function": {"name": "stop_game"}}]).is_empty(), "missing tool-call arguments should be rejected before side effects")
	_expect(not client._validate_json_response({"choices": [{"message": "invalid"}]}).is_empty(), "non-streamed JSON assistant messages must have a valid dictionary shape")
	_expect(not client._validate_json_response({"choices": []}).is_empty(), "non-streamed JSON responses must contain a choice")
	_expect(client._validate_json_response({"choices": [{"message": {"content": "ok"}}]}).is_empty(), "valid non-streamed JSON assistant messages should pass validation")
	client.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
