extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")
const TEST_BASE_URL := "http://127.0.0.1:18473"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var success := await _request("success")
	_expect(success.get("kind") == "completed", "valid SSE should complete")
	var success_choices: Array = success.get("response", {}).get("choices", [])
	_expect(not success_choices.is_empty(), "valid SSE should return a choice: " + str(success))
	if not success_choices.is_empty():
		_expect(success_choices[0].get("message", {}).get("content") == "ok", "valid SSE content should be reconstructed")
		_expect(success_choices[0].get("finish_reason") == "stop", "stream completion should preserve finish_reason")
	_expect(success.get("response", {}).get("usage", {}).get("total_tokens") == 7, "stream completion should preserve usage-only events")

	var disconnect := await _request("disconnect")
	_expect(disconnect.get("kind") == "failed", "a truncated SSE stream should fail")
	_expect(disconnect.get("error", {}).get("category") == "connection", "a truncated stream should be categorized as a connection failure")
	_expect(disconnect.get("error", {}).get("partial_response") == true, "a truncated stream should report partial output")
	_expect(disconnect.get("buffers_cleared") == true, "failure cleanup should release stream buffers")

	var oversized := await _request("oversized")
	_expect(oversized.get("kind") == "failed", "an oversized SSE stream should fail")
	_expect(oversized.get("error", {}).get("category") == "response_limit", "an oversized stream should report the response limit category")
	_expect(int(oversized.get("error", {}).get("bytes_received", 0)) > 4 * 1024 * 1024, "an oversized stream should report received bytes")
	_expect(oversized.get("buffers_cleared") == true, "size-limit cleanup should release stream buffers")

	var unexpected := await _request("unexpected")
	_expect(unexpected.get("kind") == "failed", "an unexpected success content type should fail")
	_expect(unexpected.get("error", {}).get("category") == "malformed_response", "unexpected content should be categorized as malformed")

	var gemini := await _request("gemini", "gemini", "gemini-3-flash-preview", "default", true)
	_expect(gemini.get("kind") == "completed", "Gemini-compatible SSE should complete")
	var gemini_calls: Array = gemini.get("response", {}).get("choices", [{}])[0].get("message", {}).get("tool_calls", [])
	_expect(gemini_calls.size() == 1, "Gemini-compatible SSE should return a tool call")
	if gemini_calls.size() == 1:
		_expect(gemini_calls[0].get("extra_content", {}).get("google", {}).get("thought_signature") == "test-signature", "Gemini thought signatures should survive SSE reconstruction")

	var xai := await _request("xai", "xai", "grok-4", "high")
	_expect(xai.get("kind") == "completed", "xAI-compatible SSE should complete")
	_expect(xai.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "grok ok", "xAI-compatible content should be reconstructed")

	if _failures.is_empty():
		print("api_client_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("api_client_integration_test: ", failure)
	quit(1)


func _request(scenario: String, provider: String = "custom", model: String = "test-model", effort: String = "default", include_tools: bool = false) -> Dictionary:
	var client = ApiClient.new()
	get_root().add_child(client)
	var result: Dictionary = {}
	client.request_completed.connect(func(response: Dictionary):
		result["kind"] = "completed"
		result["response"] = response
	)
	client.request_failed.connect(func(error: Dictionary):
		result["kind"] = "failed"
		result["error"] = error
	)
	client.send_chat_completion(
		[{"role": "user", "content": "test"}],
		[{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}}] if include_tools else [],
		{
			"provider": provider,
			"base_url": TEST_BASE_URL + "/" + scenario,
			"api_key": "local-test-key",
			"model": model,
			"reasoning_effort": effort
		}
	)
	var deadline := Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if result.is_empty():
		result = {"kind": "timeout"}
	result["buffers_cleared"] = client._raw_response.is_empty() and client._line_buffer.is_empty() and client._assistant_content.is_empty()
	client.queue_free()
	await process_frame
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
