extends SceneTree

const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const RequestTimeouts = preload("res://addons/orca/scripts/request_timeouts.gd")

class FakeApiClient extends Node:
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	var requests: Array[Dictionary] = []
	var cancelled := false

	func send_chat_completion(messages: Array, tools: Array = [], provider_config: Dictionary = {}, request_options: Dictionary = {}) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "config": provider_config.duplicate(true), "options": request_options.duplicate(true)})

	func cancel_request() -> void:
		cancelled = true
		if not requests.is_empty():
			request_cancelled.emit(int(requests[-1].get("options", {}).get("lifecycle_request_id", 0)))


class DeterministicProbe extends Probe:
	func _generate_challenge() -> String:
		return "fixed-challenge"


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_valid_round_trip()
	await _test_hosted_timing_opt_in()
	_test_probe_version_binding()
	await _test_invalid_challenge_and_cancellation()
	await _test_absolute_probe_timeout()
	await _test_synchronous_step_cancellation()
	_test_acknowledgement_diagnostics()
	_finish()


func _test_valid_round_trip() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var passed: Dictionary = {}
	var failures := PackedStringArray()
	probe.probe_passed.connect(func(binding: Dictionary): passed.merge(binding, true))
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): failures.append(message))
	_expect(probe.start_probe(_config()), "a valid bound profile should start the probe")
	_expect(fake.requests.size() == 1, "probe step one should send exactly one request")
	var first := fake.requests[0]
	_expect(probe._timer.wait_time == 780.0 and probe._timer.time_left > 45.0, "cold local model loading must not retain the former 45-second probe cutoff")
	var serialized := JSON.stringify(first.get("messages", []))
	_expect(not serialized.contains("res://") and not serialized.contains("AGENTS") and not serialized.contains("editor context"), "probe messages must not contain project or editor context")
	_expect(first.get("tools", []).size() == 1 and first.get("options", {}).get("allow_stream_options_retry") == false, "probe should send one synthetic tool without compatibility retries")
	var first_id := int(first.get("options", {}).get("lifecycle_request_id", 0))
	_expect(first_id > 0, "probe step one should own a lifecycle request ID")
	# Represent almost-exhausted total time without sleeping for model loading.
	probe._timer.start(0.5)
	fake.request_completed.emit(first_id, {"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [{"id": "probe-call", "type": "function", "function": {"name": Probe.PROBE_FUNCTION, "arguments": "{\"challenge\":\"fixed-challenge\"}"}, "extra_content": {"opaque": "retained"}}]}}]})
	_expect(fake.requests.size() == 2, "valid step one should start the continuation")
	_expect(probe._timer.time_left <= 0.5, "the second step must not restart an almost-exhausted absolute probe deadline")
	var continuation_messages: Array = fake.requests[1].get("messages", [])
	_expect(continuation_messages.size() == 5, "continuation should include synthetic refreshed system context after the matching tool result")
	_expect(continuation_messages[2].get("tool_calls", [])[0].get("extra_content", {}).get("opaque") == "retained", "continuation should preserve opaque assistant tool metadata")
	_expect(continuation_messages[3].get("role") == "tool" and continuation_messages[3].get("tool_call_id") == "probe-call", "synthetic result should match the exact provider call ID")
	_expect(continuation_messages[4] == {"role": "system", "content": Probe.CONTINUATION_CONTEXT}, "probe should exercise later system context through the real provider adapter")
	_expect(not JSON.stringify(continuation_messages).contains("res://"), "refreshed probe context must remain project-free")
	_expect(fake.requests[1].get("options", {}).get("allow_stream_options_retry") == false, "probe continuation must not silently retry with a changed request after a tool result")
	var second_id := int(fake.requests[1].get("options", {}).get("lifecycle_request_id", 0))
	_expect(second_id > first_id, "probe continuation should use a distinct lifecycle request ID")
	fake.request_completed.emit(first_id, {"choices": [{"message": {"role": "assistant", "content": "stale"}}]})
	fake.request_failed.emit(first_id, {"message": "stale failure"})
	fake.request_cancelled.emit(first_id)
	_expect(passed.is_empty() and failures.is_empty() and probe.is_running() and probe._expected_request_id == second_id, "stale probe completion, failure, and cancellation must not affect the second step")
	fake.request_completed.emit(second_id, {"choices": [{"message": {"role": "assistant", "content": "ORCA_AGENT_PROBE_OK fixed-challenge"}}]})
	_expect(not passed.is_empty() and passed.get("provider") == "ollama" and passed.get("model") == "fixture-model", "exact continuation acknowledgement should pass the bound probe")
	probe.queue_free()
	await process_frame


func _test_hosted_timing_opt_in() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var config := {"provider": "azure", "base_url": "http://127.0.0.1:18473/foundry", "model": "fixture-model", "api_key": "synthetic-key", "api_mode": "chat_completions", RequestTimeouts.RESPONSE_START_FIELD: 180, RequestTimeouts.INACTIVITY_FIELD: 90, RequestTimeouts.CUSTOM_ENABLED_FIELD: false}
	var binding: Dictionary = Probe.create_binding(config)["binding"]
	_expect(probe.start_probe(config) and probe._timer.wait_time == 45.0, "hosted defaults must retain the original 45-second total probe timer")
	probe.cancel()
	config[RequestTimeouts.CUSTOM_ENABLED_FIELD] = true
	_expect(Probe.create_binding(config)["binding"] == binding, "opting into timing changes must preserve the exact protocol binding")
	_expect(probe.start_probe(config) and probe._timer.wait_time == 600.0, "explicit hosted opt-in must use the selected bounded two-request budget")
	_expect(fake.requests[-1]["config"][RequestTimeouts.CUSTOM_ENABLED_FIELD] == true, "probe transport must receive the same snapshotted opt-in")
	probe.cancel()
	probe.queue_free()
	await process_frame


func _test_probe_version_binding() -> void:
	var config := _config()
	var binding: Dictionary = Probe.create_binding(config)["binding"]
	config[RequestTimeouts.RESPONSE_START_FIELD] = 600
	config[RequestTimeouts.INACTIVITY_FIELD] = 120
	_expect(Probe.create_binding(config)["binding"] == binding, "timeout preferences must not invalidate existing protocol compatibility records")
	var record := binding.duplicate(true)
	record["enabled"] = true
	config["agent_compatibility"] = record
	_expect(Config.agent_compatibility_status("ollama", config).get("enabled", false), "an exact current-version pass and opt-in should allow tools")
	record["probe_version"] = Probe.PROBE_VERSION - 1
	var status := Config.agent_compatibility_status("ollama", config)
	_expect(not status.get("passed", true) and not status.get("enabled", true), "older probe passes must fail closed after the refreshed-context contract changes")


func _test_invalid_challenge_and_cancellation() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var failures := PackedStringArray()
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): failures.append(message))
	var invalid := _config()
	invalid[RequestTimeouts.RESPONSE_START_FIELD] = 0
	_expect(not probe.start_probe(invalid) and fake.requests.is_empty() and not probe.is_running(), "invalid timeouts must not start synthetic inference")
	failures.clear()
	probe.start_probe(_config())
	var request_id := int(fake.requests[-1].get("options", {}).get("lifecycle_request_id", 0))
	fake.request_completed.emit(request_id, {"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": [{"id": "bad", "type": "function", "function": {"name": Probe.PROBE_FUNCTION, "arguments": "{\"challenge\":\"wrong\"}"}}]}}]})
	_expect(failures.size() == 1 and not probe.is_running(), "a wrong challenge should fail without a continuation")
	probe.start_probe(_config())
	probe.cancel()
	_expect(fake.cancelled and not probe.is_running(), "cancellation should stop the isolated request and clear probe state")
	fake.cancelled = false
	probe.start_probe(_config())
	probe._on_timeout()
	_expect(fake.cancelled and failures[-1].contains("timed out"), "the total probe timeout should cancel transport and fail once")
	probe.queue_free()
	await process_frame


func _test_absolute_probe_timeout() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var failures := PackedStringArray()
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): failures.append(message))
	var config := _config()
	config[RequestTimeouts.RESPONSE_START_FIELD] = 180
	config[RequestTimeouts.INACTIVITY_FIELD] = 90
	probe.start_probe(config)
	_expect(probe._timer.wait_time == 600.0 and fake.requests[0]["config"][RequestTimeouts.RESPONSE_START_FIELD] == 180, "probe must snapshot its selected timeout preferences")
	config[RequestTimeouts.RESPONSE_START_FIELD] = 600
	# Shorten only this fixture's total timer, then use its real timeout signal.
	probe._timer.start(0.2)
	fake.request_completed.emit(int(fake.requests[0]["options"]["lifecycle_request_id"]), {"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [{"id": "probe-call", "type": "function", "function": {"name": Probe.PROBE_FUNCTION, "arguments": "{\"challenge\":\"fixed-challenge\"}"}}]}}]})
	_expect(fake.requests.size() == 2 and fake.requests[1]["config"][RequestTimeouts.RESPONSE_START_FIELD] == 180, "step two must retain the original timeout snapshot")
	await create_timer(0.3).timeout
	_expect(failures.size() == 1 and fake.cancelled and not probe.is_running() and probe._provider_config.is_empty(), "total probe timer must expire during step two, cancel once, and clear private state")
	_expect(failures[0].contains("Request Timeouts"), "probe timeout must provide actionable settings guidance")
	probe.queue_free()
	await process_frame


func _test_synchronous_step_cancellation() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var cancelled := [0]
	probe.probe_cancelled.connect(func(): cancelled[0] += 1)
	probe.probe_step_changed.connect(func(_step: int): probe.cancel())
	_expect(probe.start_probe(_config()), "the synchronously cancelled probe should enter its bounded start path")
	_expect(cancelled[0] == 1 and fake.requests.is_empty() and not probe.is_running(), "cancellation from a probe-step signal must not launch an orphan request")
	probe.queue_free()
	await process_frame


func _test_acknowledgement_diagnostics() -> void:
	var probe := DeterministicProbe.new()
	probe._challenge = "fixed-challenge"
	var error: String = probe._validate_final_response({"choices": [{"message": {"content": "`ORCA_AGENT_PROBE_OK fixed-challenge`"}}]})
	_expect(error.contains("extra formatting") and error.contains("<challenge>") and not error.contains("fixed-challenge"), "synthetic diagnostics should distinguish formatting and redact the exact challenge")
	error = probe._validate_final_response({"choices": [{"message": {"content": "incorrect acknowledgement"}}]})
	_expect(error.contains("changed acknowledgement") and error.contains("incorrect acknowledgement"), "diagnostics should provide bounded synthetic reply evidence without weakening the gate")
	_expect(probe._validate_final_response({"choices": [{"message": {"content": "ORCA_AGENT_PROBE_OK fixed-challenge"}}]}).is_empty(), "only the exact correct acknowledgement should pass")
	probe.free()


func _config() -> Dictionary:
	return {"provider": "ollama", "base_url": "http://127.0.0.1:11434/v1", "api_key": "", "model": "fixture-model", "reasoning_effort": "default", "confirmed_origin": ""}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("agent_compatibility_probe_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("agent_compatibility_probe_test: ", failure)
	quit(1)
