extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_media_types()
	_test_fragmented_sse_and_eof_flush()
	_test_streamed_tool_metadata()
	_test_structured_error_metadata()
	_test_provider_error_formatting()
	_test_required_auth_configuration()
	_test_tool_call_validation()
	_test_completion_validation()
	_test_terminal_signal_ownership()
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
	_expect(client._validate_json_response({"choices": [{"message": {"content": "ok"}, "finish_reason": "stop"}]}).is_empty(), "valid non-streamed JSON assistant messages should pass validation")
	client.free()


func _test_completion_validation() -> void:
	var client = ApiClient.new()
	var valid_call := {"id": "call_1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	_expect(not client._validate_completion("", [], "stop").is_empty(), "empty DONE responses must fail")
	_expect(not client._validate_completion("   \n", [], "stop").is_empty(), "whitespace-only responses must fail")
	_expect(not client._validate_json_response({"choices": [{"message": {"content": ""}, "finish_reason": "stop"}]}).is_empty(), "empty JSON responses must fail")
	_expect(not client._validate_json_response({"choices": [{"message": {"content": " \n\t"}, "finish_reason": "stop"}]}).is_empty(), "whitespace-only JSON responses must fail")
	_expect(not client._validate_json_response({"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}).is_empty(), "usage-only JSON responses must fail")
	_expect(not client._validate_json_response({"choices": [{"message": {"content": null, "reasoning_content": "hidden"}, "finish_reason": "stop"}]}).is_empty(), "reasoning-only JSON responses must fail")
	_expect(client._validate_completion("visible", [], "stop").is_empty(), "normal visible content should succeed")
	_expect(client._validate_completion("", [valid_call], "tool_calls").is_empty(), "tool-only responses should succeed")
	_expect(client._validate_json_response({"choices": [{"message": {"content": null, "tool_calls": [valid_call]}, "finish_reason": "tool_calls"}]}).is_empty(), "tool-only JSON responses should succeed")
	_expect(not client._validate_completion("partial", [], "length").is_empty(), "length finishes must fail despite partial content")
	_expect(not client._validate_completion("partial", [], "content_filter").is_empty(), "content-filter finishes must fail despite partial content")
	_expect(not client._validate_json_response({"choices": [{"message": {"content": "partial"}, "finish_reason": "length"}]}).is_empty(), "length-truncated JSON responses must fail")
	_expect(client._validate_completion("visible", [], null).is_empty(), "meaningful content should remain compatible with providers that omit finish reasons")
	_expect(client._validate_completion("visible", [], "end_turn").is_empty(), "meaningful content should remain compatible with provider-specific successful finish reasons")
	_expect(not client._validate_completion("", [valid_call], "stop").is_empty(), "tool calls with a stop finish must fail as contradictory")
	_expect(not client._validate_completion("visible", [], "tool_calls").is_empty(), "tool-call finishes without calls must fail as contradictory")
	_expect(not client._json_has_partial_response({"choices": [{"message": {"content": "", "reasoning_content": null, "reasoning_details": []}}]}), "empty optional reasoning fields must not claim partial output")
	client._generation_deadline_ms = Time.get_ticks_msec() - 1
	_expect(client._response_generation_timed_out(), "the total generation deadline should expire independently of stream activity")
	client.free()


func _test_terminal_signal_ownership() -> void:
	var client = ApiClient.new()
	var signals := {"failed": 0, "cancelled": 0}
	client.request_failed.connect(func(_error: Dictionary): signals["failed"] += 1)
	client.request_cancelled.connect(func(): signals["cancelled"] += 1)
	client._is_requesting = true
	client._request_serial = 7
	client.cancel_request()
	client._fail_request(7, "stale", "connection", false)
	_expect(signals["cancelled"] == 1 and signals["failed"] == 0, "cancellation should own the request serial and suppress stale terminal failures")
	_expect(not client._finish_request(8), "an already terminated request must not be claimed again")
	client.free()


func _test_provider_error_formatting() -> void:
	var client = ApiClient.new()
	_expect(client._format_http_error(400, '{"error":{"message":"model does not support chat"}}').contains("does not support chat"), "nested provider chat errors should become plain guidance")
	_expect(client._format_http_error(400, '{"error":"This model is an embedding model"}').contains("does not support chat"), "string embedding errors should become plain guidance")
	var bounded := client._format_http_error(500, '{"message":"%s"}' % "x".repeat(ApiClient.MAX_PROVIDER_ERROR_CHARS + 100))
	_expect(bounded.length() <= ApiClient.MAX_PROVIDER_ERROR_CHARS + 32, "provider error messages should be bounded")
	_expect(client._format_http_error(500, "<html>failure</html>") == "Provider returned HTTP 500.", "HTML error bodies should not be shown to users")
	client._configured_provider = "lmstudio"
	client._configured_request_model = "embedding-model"
	_expect(client._local_model_mismatch_error("llama-chat").contains("served model"), "local provider model substitution should produce a clear error")
	client.free()


func _test_required_auth_configuration() -> void:
	var client = ApiClient.new()
	var observed := {"failure": {}}
	client.request_failed.connect(func(error: Dictionary): observed["failure"] = error)
	client.send_chat_completion([{"role": "user", "content": "test"}], [], {
		"provider": "custom",
		"base_url": "http://127.0.0.1:1/v1",
		"api_key": "",
		"model": "fixture"
	})
	_expect(observed["failure"].get("category") == "configuration", "authenticated OpenAI-compatible profiles should still reject an empty API key before transport")
	observed["failure"] = {}
	client.send_chat_completion([{"role": "user", "content": "test"}], [], {
		"provider": "custom",
		"base_url": "http://127.0.0.1:1/v1",
		"api_key": "   ",
		"model": "fixture"
	})
	_expect(observed["failure"].get("category") == "configuration", "whitespace credentials should not bypass required authentication")
	for unsafe_config in [
		{"provider": "ollama", "base_url": "http://192.168.1.20:11434/v1", "api_key": "", "model": "fixture"},
		{"provider": "custom", "base_url": "https://models.example.com/v1", "api_key": "secret", "model": "fixture"},
		{"provider": "ollama", "base_url": "http://127.0.0.1:11434/v1/chat/completions", "api_key": "", "model": "fixture"}
	]:
		observed["failure"] = {}
		client.send_chat_completion([{"role": "user", "content": "test"}], [], unsafe_config)
		_expect(observed["failure"].get("category") == "configuration" and not client.is_requesting(), "unsafe or unconfirmed endpoint should fail before transport: " + str(unsafe_config.get("base_url")))
	client.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
