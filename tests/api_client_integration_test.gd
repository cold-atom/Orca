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
	_expect(success.get("response", {}).get("requested_model") == "test-model", "transport completion should preserve the request model snapshot")
	_expect(success.get("response", {}).get("requested_provider") == "custom", "transport completion should preserve the provider snapshot")
	_expect(success.get("response", {}).get("requested_api_url") == TEST_BASE_URL + "/success/chat/completions", "transport completion should preserve the endpoint snapshot")

	var empty_done := await _request("empty-done")
	_expect_malformed(empty_done, "an empty DONE stream")

	var reasoning_only := await _request("reasoning-only")
	_expect_malformed(reasoning_only, "a reasoning-only stream")

	var whitespace_only := await _request("whitespace-only")
	_expect_malformed(whitespace_only, "a whitespace-only stream")

	var normal_content := await _request("normal-content")
	_expect(normal_content.get("kind") == "completed", "normal visible content should complete")

	var tool_only := await _request("tool-only", "custom", "test-model", "default", true)
	_expect(tool_only.get("kind") == "completed", "a valid tool-only response should complete")

	var finish_length := await _request("finish-length")
	_expect_malformed(finish_length, "a length-truncated stream")
	_expect(finish_length.get("error", {}).get("partial_response") == true, "length-truncated visible output should be marked partial")

	var finish_filter := await _request("finish-content-filter")
	_expect_malformed(finish_filter, "a content-filtered stream")
	_expect(finish_filter.get("error", {}).get("partial_response") == true, "content-filtered visible output should be marked partial")

	var disconnect := await _request("disconnect")
	_expect(disconnect.get("kind") == "failed", "a truncated SSE stream should fail")
	_expect(disconnect.get("error", {}).get("category") == "connection", "a truncated stream should be categorized as a connection failure")
	_expect(disconnect.get("error", {}).get("partial_response") == true, "a truncated stream should report partial output")
	_expect(disconnect.get("buffers_cleared") == true, "failure cleanup should release stream buffers")

	var deadline := await _request("generation-deadline", "custom", "deadline-model", "default", false, "local-test-key", {
		ApiClient.INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION: 250
	})
	_expect(deadline.get("kind") == "failed", "an active stream exceeding the total generation deadline should fail: " + str(deadline))
	_expect(deadline.get("error", {}).get("category") == "timeout", "the total generation deadline should report the timeout category")
	_expect(str(deadline.get("error", {}).get("message", "")).contains("generation deadline"), "the total generation deadline should report its specific cause")
	_expect(deadline.get("error", {}).get("response_started") == true, "deadline metadata should record that the response started")
	_expect(deadline.get("error", {}).get("partial_response") == true, "hidden reasoning received before the deadline should be marked partial")
	_expect(int(deadline.get("error", {}).get("bytes_received", 0)) > 0, "deadline metadata should retain received transport bytes")
	_expect(deadline.get("failed_count") == 1, "the deadline should emit exactly one failure signal")
	_expect(deadline.get("completed_count") == 0 and deadline.get("cancelled_count") == 0, "the deadline must not emit completion or cancellation")
	_expect(deadline.get("request_cleaned") == true and deadline.get("buffers_cleared") == true, "deadline failure should close the client and clear request state")

	var retry_deadline := await _request("retry-generation-deadline", "custom", "retry-deadline-model", "default", false, "local-test-key", {
		ApiClient.INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION: 2000
	})
	_expect(retry_deadline.get("kind") == "failed", "a stream_options retry must remain bound by the original generation deadline: " + str(retry_deadline))
	_expect(retry_deadline.get("error", {}).get("category") == "timeout", "the compatibility retry should fail with the timeout category")
	_expect(retry_deadline.get("error", {}).get("message") == ApiClient.GENERATION_TIMEOUT_MESSAGE, "generation timeout wording should not depend on the configured duration")
	_expect(retry_deadline.get("error", {}).get("http_status") == 200, "the compatibility retry should begin its active SSE response before timing out")
	_expect(retry_deadline.get("error", {}).get("partial_response") == true, "active retry reasoning should be retained as partial-response metadata")
	_expect(retry_deadline.get("failed_count") == 1 and retry_deadline.get("completed_count") == 0, "the compatibility retry deadline should emit one terminal failure and no completion")
	_expect(retry_deadline.get("request_cleaned") == true and retry_deadline.get("buffers_cleared") == true, "compatibility retry timeout should clean up the client")

	var after_deadline := await _request("success")
	_expect(after_deadline.get("kind") == "completed", "the fixture server should accept a new client after deadline cleanup")

	var framed := await _request("framed")
	_expect(framed.get("kind") == "completed", "a valid stream with more than 4 MiB of provider framing should complete")
	_expect(framed.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "framed ok", "framing-heavy streams should retain their assistant content")

	var oversized := await _request("oversized")
	_expect(oversized.get("kind") == "failed", "an oversized SSE stream should fail")
	_expect(oversized.get("error", {}).get("category") == "response_limit", "an oversized stream should report the response limit category")
	_expect(int(oversized.get("error", {}).get("bytes_received", 0)) > ApiClient.MAX_RESPONSE_BYTES, "an oversized stream should report received bytes")
	_expect(oversized.get("buffers_cleared") == true, "size-limit cleanup should release stream buffers")

	var unexpected := await _request("unexpected")
	_expect(unexpected.get("kind") == "failed", "an unexpected success content type should fail")
	_expect(unexpected.get("error", {}).get("category") == "malformed_response", "unexpected content should be categorized as malformed")

	var gemini := await _request("gemini", "gemini", "gemini-3-flash-preview", "default", true)
	_expect(gemini.get("kind") == "completed", "Gemini-compatible SSE should complete")
	var gemini_calls: Array = gemini.get("response", {}).get("choices", [{}])[0].get("message", {}).get("tool_calls", [])
	_expect(gemini_calls.size() == 1, "Gemini-compatible SSE should return a tool call")
	_expect(gemini.get("response", {}).get("choices", [{}])[0].get("finish_reason") == "stop", "Gemini-compatible SSE should preserve its stop finish reason")
	if gemini_calls.size() == 1:
		_expect(gemini_calls[0].get("extra_content", {}).get("google", {}).get("thought_signature") == "test-signature", "Gemini thought signatures should survive SSE reconstruction")

	var gemini_loop := await _request("gemini-loop", "gemini", "gemini-3-flash-preview", "default", true)
	_expect(gemini_loop.get("kind") == "completed", "Gemini's first multi-round response should complete")
	var loop_message: Dictionary = gemini_loop.get("response", {}).get("choices", [{}])[0].get("message", {})
	var loop_calls: Array = loop_message.get("tool_calls", [])
	_expect(loop_calls.size() == 1, "Gemini's first multi-round response should contain one tool call")
	if loop_calls.size() == 1:
		_expect(loop_calls[0].get("extra_content", {}).get("google", {}).get("thought_signature") == "loop-signature", "fragmented Gemini thought signatures should reconstruct before continuation")
		var continuation_messages := [
			{"role": "user", "content": "test"},
			loop_message,
			{"role": "tool", "tool_call_id": str(loop_calls[0].get("id", "")), "content": "{\"success\":true,\"path\":\"res://game.gd\"}"},
		]
		var gemini_final := await _request("gemini-loop", "gemini", "gemini-3-flash-preview", "default", true, "local-test-key", {"allow_stream_options_retry": false}, continuation_messages)
		_expect(gemini_final.get("kind") == "completed", "Gemini should accept the exact assistant-call/tool-result continuation: " + str(gemini_final))
		_expect(gemini_final.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "gemini loop complete", "Gemini's validated continuation should return final assistant text")

	var deepseek_loop := await _request("deepseek-loop", "deepseek", "deepseek-chat", "high", true)
	_expect(deepseek_loop.get("kind") == "completed", "DeepSeek's first reasoning tool response should complete")
	var deepseek_message: Dictionary = deepseek_loop.get("response", {}).get("choices", [{}])[0].get("message", {})
	var deepseek_calls: Array = deepseek_message.get("tool_calls", [])
	_expect(deepseek_message.get("reasoning_content") == "plan-tool", "fragmented DeepSeek reasoning should reconstruct for continuation")
	_expect(deepseek_calls.size() == 1, "DeepSeek's first multi-round response should contain one tool call")
	if deepseek_calls.size() == 1:
		deepseek_message["reasoning"] = "strip-generic-reasoning"
		deepseek_message["reasoning_details"] = [{"type": "strip-openrouter-details"}]
		var deepseek_continuation := [
			{"role": "user", "content": "test"},
			deepseek_message,
			{"role": "tool", "tool_call_id": str(deepseek_calls[0].get("id", "")), "content": "{\"success\":true,\"path\":\"res://player.gd\"}"},
		]
		var deepseek_final := await _request("deepseek-loop", "deepseek", "deepseek-chat", "high", true, "local-test-key", {"allow_stream_options_retry": false}, deepseek_continuation)
		_expect(deepseek_final.get("kind") == "completed", "DeepSeek should accept preserved reasoning_content with sanitized incompatible fields: " + str(deepseek_final))
		_expect(deepseek_final.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "deepseek loop complete", "DeepSeek's validated continuation should return final assistant text")
		_expect(deepseek_final.get("response", {}).get("choices", [{}])[0].get("message", {}).get("reasoning_content") == "final-hidden", "DeepSeek final hidden reasoning should remain available to the controller without becoming visible text")

	var xai := await _request("xai", "xai", "grok-4", "high")
	_expect(xai.get("kind") == "completed", "xAI-compatible SSE should complete")
	_expect(xai.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "grok ok", "xAI-compatible content should be reconstructed")

	var xai_loop := await _request("xai-loop", "xai", "grok-4", "high", true)
	_expect(xai_loop.get("kind") == "completed", "xAI's first reasoning tool response should complete")
	var xai_message: Dictionary = xai_loop.get("response", {}).get("choices", [{}])[0].get("message", {})
	var xai_calls: Array = xai_message.get("tool_calls", [])
	_expect(xai_message.get("reasoning_content") == "grok-plan", "fragmented xAI reasoning should reconstruct for continuation")
	_expect(xai_calls.size() == 1, "xAI's first multi-round response should contain one tool call")
	if xai_calls.size() == 1:
		xai_message["reasoning"] = "strip-generic-reasoning"
		xai_message["reasoning_details"] = [{"type": "strip-openrouter-details"}]
		var xai_continuation := [
			{"role": "user", "content": "test"},
			xai_message,
			{"role": "tool", "tool_call_id": str(xai_calls[0].get("id", "")), "content": "{\"success\":true,\"scene\":\"res://game.tscn\"}"},
		]
		var xai_final := await _request("xai-loop", "xai", "grok-4", "high", true, "local-test-key", {"allow_stream_options_retry": false}, xai_continuation)
		_expect(xai_final.get("kind") == "completed", "xAI should accept preserved reasoning_content with sanitized incompatible fields: " + str(xai_final))
		_expect(xai_final.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "xai loop complete", "xAI's validated continuation should return final assistant text")

	var openrouter_loop := await _request("openrouter-loop", "openrouter", "anthropic/claude-sonnet-test", "high", true)
	_expect(openrouter_loop.get("kind") == "completed", "OpenRouter's first reasoning tool response should complete")
	var openrouter_message: Dictionary = openrouter_loop.get("response", {}).get("choices", [{}])[0].get("message", {})
	var openrouter_calls: Array = openrouter_message.get("tool_calls", [])
	var reasoning_details: Array = openrouter_message.get("reasoning_details", [])
	_expect(openrouter_calls.size() == 1, "OpenRouter's first multi-round response should contain one tool call")
	_expect(reasoning_details.size() == 1 and reasoning_details[0].get("text") == "route-plan" and reasoning_details[0].get("signature") == "sig-value", "indexed OpenRouter reasoning details should reconstruct fragmented text and signatures")
	if openrouter_calls.size() == 1 and reasoning_details.size() == 1:
		var openrouter_continuation := [
			{"role": "user", "content": "test"},
			openrouter_message,
			{"role": "tool", "tool_call_id": str(openrouter_calls[0].get("id", "")), "content": "{\"success\":true,\"matches\":2}"},
		]
		var openrouter_final := await _request("openrouter-loop", "openrouter", "anthropic/claude-sonnet-test", "high", true, "local-test-key", {"allow_stream_options_retry": false}, openrouter_continuation)
		_expect(openrouter_final.get("kind") == "completed", "OpenRouter should accept reconstructed reasoning_details verbatim on continuation: " + str(openrouter_final))
		_expect(openrouter_final.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "openrouter loop complete", "OpenRouter's validated continuation should return final assistant text")

	var local := await _request("local", "ollama", "local-model", "default", false, "")
	_expect(local.get("kind") == "completed", "a keyless local OpenAI-compatible request should complete")
	_expect(local.get("response", {}).get("choices", [{}])[0].get("message", {}).get("content") == "local ok", "keyless local content should use the shared SSE transport")

	var embedding_error := await _request("embedding-error", "lmstudio", "embedding-model", "default", false, "")
	_expect(embedding_error.get("kind") == "failed" and embedding_error.get("error", {}).get("category") == "http", "embedding chat rejection should remain an HTTP failure")
	_expect(str(embedding_error.get("error", {}).get("message", "")).contains("does not support chat") and not str(embedding_error.get("error", {}).get("message", "")).contains("{\"error\""), "embedding rejection should be plain guidance rather than raw JSON")

	var mismatch := await _request("model-mismatch", "lmstudio", "embedding-model", "default", false, "")
	_expect(mismatch.get("kind") == "failed" and mismatch.get("error", {}).get("category") == "model_mismatch", "local model substitution should fail instead of presenting another model's response: " + str(mismatch))

	if _failures.is_empty():
		print("api_client_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("api_client_integration_test: ", failure)
	quit(1)


func _request(scenario: String, provider: String = "custom", model: String = "test-model", effort: String = "default", include_tools: bool = false, api_key: String = "local-test-key", request_options: Dictionary = {}, messages: Array = []) -> Dictionary:
	var client = ApiClient.new()
	get_root().add_child(client)
	var result: Dictionary = {}
	var terminal_counts := {"completed": 0, "failed": 0, "cancelled": 0}
	var lifecycle_request_id := 700 + scenario.hash() % 100
	var observed_signal_ids: Array[int] = []
	client.stream_started.connect(func(request_id: int): observed_signal_ids.append(request_id))
	client.stream_delta.connect(func(request_id: int, _content: String): observed_signal_ids.append(request_id))
	client.request_completed.connect(func(request_id: int, response: Dictionary):
		observed_signal_ids.append(request_id)
		terminal_counts["completed"] += 1
		if result.is_empty():
			result["kind"] = "completed"
			result["response"] = response
			result["request_id"] = request_id
	)
	client.request_failed.connect(func(request_id: int, error: Dictionary):
		observed_signal_ids.append(request_id)
		terminal_counts["failed"] += 1
		if result.is_empty():
			result["kind"] = "failed"
			result["error"] = error
			result["request_id"] = request_id
	)
	client.request_cancelled.connect(func(request_id: int):
		observed_signal_ids.append(request_id)
		terminal_counts["cancelled"] += 1
		if result.is_empty():
			result["kind"] = "cancelled"
			result["request_id"] = request_id
	)
	client.send_chat_completion(
		[{"role": "user", "content": "test"}] if messages.is_empty() else messages,
		[{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}}] if include_tools else [],
		{
			"provider": provider,
			"base_url": TEST_BASE_URL + "/" + scenario,
			"api_key": api_key,
			"model": model,
			"reasoning_effort": effort,
			"confirmed_origin": "http://127.0.0.1:18473"
		},
		request_options.merged({ApiClient.LIFECYCLE_REQUEST_ID_OPTION: lifecycle_request_id}, true)
	)
	var deadline := Time.get_ticks_msec() + 10000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if result.is_empty():
		result = {"kind": "timeout"}
	await process_frame
	result["completed_count"] = terminal_counts["completed"]
	result["failed_count"] = terminal_counts["failed"]
	result["cancelled_count"] = terminal_counts["cancelled"]
	result["request_id_matches"] = result.get("request_id") == lifecycle_request_id
	result["all_signal_ids_match"] = observed_signal_ids.all(func(request_id: int): return request_id == lifecycle_request_id)
	_expect(result["request_id_matches"] and result["all_signal_ids_match"], "%s should carry one lifecycle ID on every API signal" % scenario)
	result["request_cleaned"] = not client.is_requesting() and client._http_client == null and client._generation_deadline_ms == 0 and client._response_generation_timeout_ms == ApiClient.RESPONSE_GENERATION_TIMEOUT_MS
	result["buffers_cleared"] = client._raw_response.is_empty() and client._line_buffer.is_empty() and client._assistant_content.is_empty()
	client.queue_free()
	await process_frame
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_malformed(result: Dictionary, description: String) -> void:
	_expect(result.get("kind") == "failed", description + " should fail")
	_expect(result.get("error", {}).get("category") == "malformed_response", description + " should be categorized as malformed")
