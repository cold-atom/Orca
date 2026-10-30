extends SceneTree

const ApiClient = preload("res://addons/orca/scripts/api_client.gd")

# Shorten only this fixture's waits; production profile validation still runs.
# There is no new runtime override that could disable or extend a deadline.
class ShortTimeoutClient extends ApiClient:
	var start_ms := 1000
	var idle_ms := 100
	var configured_timing: Dictionary = {}

	func _perform_request(request_id: int, endpoint: Dictionary, headers: PackedStringArray, body: Dictionary, allow_usage_retry: bool, retries: int) -> void:
		configured_timing = {"start_ms": _response_start_timeout_ms, "idle_ms": _inactivity_timeout_ms}
		_response_start_timeout_ms = mini(_response_start_timeout_ms, start_ms)
		_inactivity_timeout_ms = mini(_inactivity_timeout_ms, idle_ms)
		super._perform_request(request_id, endpoint, headers, body, allow_usage_retry, retries)


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var headers := await _request("headers", 1000, 100)
	_expect(headers.get("kind") == "completed", "delayed headers must succeed within the configured response-start wait")
	_expect(headers.get("configured_timing") == {"start_ms": 300000, "idle_ms": 60000}, "APIClient must use the local defaults before fixture-only shortening")
	var short_headers := await _request("headers", 100, 100)
	_expect_timeout(short_headers, "waiting_for_response", false)
	_expect(short_headers["error"]["message"].contains("Request Timeouts"), "start timeout must direct users to the provider controls")
	var body := await _request("body", 1000, 100)
	_expect(body.get("kind") == "completed", "early headers and a long initial-body silence must use response-start rather than idle timing")
	var short_body := await _request("body", 100, 100)
	_expect_timeout(short_body, "receiving_response", false)
	var shared := await _request("shared", 400, 100)
	_expect_timeout(shared, "receiving_response", false)
	var idle := await _request("idle", 1000, 100)
	_expect_timeout(idle, "receiving_response", true)
	_expect(idle["error"]["message"].contains("without data"), "post-start stall must identify stream inactivity")
	var generous_idle := await _request("idle", 1000, 1000)
	_expect(generous_idle.get("kind") == "completed", "increasing stream inactivity must allow a slow inter-chunk pause")
	var active := await _request("active", 100, 150)
	_expect(active.get("kind") == "completed", "ongoing hidden reasoning must renew inactivity after the first bytes")
	var total := await _request("active", 100, 150, {}, {ApiClient.INTERNAL_GENERATION_TIMEOUT_OVERRIDE_OPTION: 250})
	_expect_timeout(total, "receiving_response", true)
	_expect(total["error"]["message"] == ApiClient.GENERATION_TIMEOUT_MESSAGE, "stream progress must not extend the absolute generation deadline")
	for stage in ["headers", "body"]:
		var cancelled := await _request(stage, 1000, 100, {}, {}, true)
		_expect(cancelled.get("kind") == "cancelled" and cancelled["counts"] == {"completed": 0, "failed": 0, "cancelled": 1}, "Stop must cancel exactly once during delayed " + stage)
	var json := await _request("json", 1000, 100)
	_expect(json.get("kind") == "completed", "non-streaming JSON must also allow slow initial data")
	var responses := await _request("body", 1000, 100, {"provider": "azure", "api_mode": "responses", "custom_timeouts_enabled": true, "response_start_timeout_seconds": 180, "stream_inactivity_timeout_seconds": 90})
	_expect(responses.get("kind") == "completed" and responses.get("configured_timing") == {"start_ms": 180000, "idle_ms": 90000}, "Responses must use the same bounded configurable start/idle contract")
	var built_in := {"provider": "azure", "api_mode": "responses", "custom_timeouts_enabled": false, "response_start_timeout_seconds": 180, "stream_inactivity_timeout_seconds": 90}
	var default_body := await _request("body", 100, 1000, built_in)
	_expect(default_body.get("kind") == "completed" and default_body.get("configured_timing") == {"start_ms": 30000, "idle_ms": 60000}, "default hosted requests must allow initial body data after the header deadline using the original body wait")
	var default_headers := await _request("headers", 100, 1000, built_in)
	_expect_timeout(default_headers, "waiting_for_response", false)
	_expect(default_headers["error"]["message"].contains("response headers"), "legacy default header expiry must identify the separate original header wait")
	var default_idle := await _request("idle", 1000, 100, built_in.merged({"api_mode": "chat_completions"}, true))
	_expect_timeout(default_idle, "receiving_response", true)
	var default_body_timeout := await _request("body", 1000, 100, built_in)
	_expect_timeout(default_body_timeout, "receiving_response", false)
	_expect(default_body_timeout["error"]["message"].contains("without data"), "the default initial-body wait must use inactivity even before first bytes")
	_finish()


func _request(scenario: String, start_ms: int, idle_ms: int, profile: Dictionary = {}, options: Dictionary = {}, cancel: bool = false) -> Dictionary:
	var client := ShortTimeoutClient.new()
	client.start_ms = start_ms
	client.idle_ms = idle_ms
	get_root().add_child(client)
	var result := {}
	var counts := {"completed": 0, "failed": 0, "cancelled": 0}
	var ids: Array[int] = []
	client.request_completed.connect(func(id: int, _response: Dictionary):
		counts["completed"] += 1
		ids.append(id)
		result.merge({"kind": "completed"}, true))
	client.request_failed.connect(func(id: int, error: Dictionary):
		counts["failed"] += 1
		ids.append(id)
		result.merge({"kind": "failed", "error": error}, true))
	client.request_cancelled.connect(func(id: int):
		counts["cancelled"] += 1
		ids.append(id)
		result.merge({"kind": "cancelled"}, true))
	var config := {"provider": "ollama", "base_url": "http://127.0.0.1:18473/timeout/" + scenario, "model": "timeout-model", "api_key": "synthetic-timeout-key"}.merged(profile, true)
	var started := Time.get_ticks_msec()
	client.send_chat_completion([{"role": "user", "content": "Synthetic timing test"}], [], config, options.merged({ApiClient.LIFECYCLE_REQUEST_ID_OPTION: 81}, true))
	if cancel:
		create_timer(0.05).timeout.connect(client.cancel_request)
	while result.is_empty() and Time.get_ticks_msec() - started < 3000:
		await process_frame
	result["elapsed_ms"] = Time.get_ticks_msec() - started
	# Let the deliberately slow single-threaded fixture finish after Stop/error.
	await create_timer(0.4).timeout
	result["counts"] = counts
	result["configured_timing"] = client.configured_timing
	_expect(ids == [81], "every timeout scenario must emit exactly one owned terminal signal")
	_expect(not client.is_requesting() and client._http_client == null and client._generation_deadline_ms == 0 and client._request_config_snapshot.is_empty(), "terminal timing paths must close transport and clear private request state")
	_expect(client._response_start_timeout_ms == ApiClient.CONNECT_TIMEOUT_MS and client._inactivity_timeout_ms == ApiClient.INACTIVITY_TIMEOUT_MS and client._response_generation_timeout_ms == ApiClient.RESPONSE_GENERATION_TIMEOUT_MS, "terminal timing paths must reset request-scoped durations")
	_expect(not client._legacy_timeout_defaults, "terminal timing paths must reset default/custom policy before another request")
	_expect(client._line_buffer.is_empty() and client._raw_response.is_empty() and client._reasoning_content.is_empty(), "timing failures/cancellation must release response buffers")
	client.queue_free()
	await process_frame
	return result


func _expect_timeout(result: Dictionary, phase: String, partial: bool) -> void:
	_expect(result.get("kind") == "failed" and result.get("error", {}).get("category") == "timeout", "silent/overlong response must end with a timeout: " + str(result))
	_expect(result.get("error", {}).get("phase") == phase and result.get("error", {}).get("partial_response") == partial, "timeouts must retain phase and partial-output provenance")
	_expect(result.get("counts") == {"completed": 0, "failed": 1, "cancelled": 0}, "a submitted timed-out request must fail once without replay")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("timeout_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("timeout_integration_test: ", failure)
	quit(1)
