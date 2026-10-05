extends SceneTree

const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")

class FakeApiClient extends Node:
	signal request_completed(response: Dictionary)
	signal request_failed(error: Dictionary)
	signal request_cancelled
	var requests: Array[Dictionary] = []
	var cancelled := false

	func send_chat_completion(messages: Array, tools: Array = [], provider_config: Dictionary = {}, request_options: Dictionary = {}) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "config": provider_config.duplicate(true), "options": request_options.duplicate(true)})

	func cancel_request() -> void:
		cancelled = true
		request_cancelled.emit()


class DeterministicProbe extends Probe:
	func _generate_challenge() -> String:
		return "fixed-challenge"


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_valid_round_trip()
	await _test_invalid_challenge_and_cancellation()
	_finish()


func _test_valid_round_trip() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var passed: Dictionary = {}
	probe.probe_passed.connect(func(binding: Dictionary): passed.merge(binding, true))
	_expect(probe.start_probe(_config()), "a valid bound profile should start the probe")
	_expect(fake.requests.size() == 1, "probe step one should send exactly one request")
	var first := fake.requests[0]
	var serialized := JSON.stringify(first.get("messages", []))
	_expect(not serialized.contains("res://") and not serialized.contains("AGENTS") and not serialized.contains("editor context"), "probe messages must not contain project or editor context")
	_expect(first.get("tools", []).size() == 1 and first.get("options", {}).get("allow_stream_options_retry") == false, "probe should send one synthetic tool without compatibility retries")
	fake.request_completed.emit({"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [{"id": "probe-call", "type": "function", "function": {"name": Probe.PROBE_FUNCTION, "arguments": "{\"challenge\":\"fixed-challenge\"}"}, "extra_content": {"opaque": "retained"}}]}}]})
	_expect(fake.requests.size() == 2, "valid step one should start the continuation")
	var continuation_messages: Array = fake.requests[1].get("messages", [])
	_expect(continuation_messages.size() == 4, "continuation should contain only synthetic system, user, assistant, and tool messages")
	_expect(continuation_messages[2].get("tool_calls", [])[0].get("extra_content", {}).get("opaque") == "retained", "continuation should preserve opaque assistant tool metadata")
	_expect(continuation_messages[3].get("role") == "tool" and continuation_messages[3].get("tool_call_id") == "probe-call", "synthetic result should match the exact provider call ID")
	_expect(fake.requests[1].get("options", {}).get("allow_stream_options_retry") == false, "probe continuation must not silently retry with a changed request after a tool result")
	fake.request_completed.emit({"choices": [{"message": {"role": "assistant", "content": "ORCA_AGENT_PROBE_OK fixed-challenge"}}]})
	_expect(not passed.is_empty() and passed.get("provider") == "ollama" and passed.get("model") == "fixture-model", "exact continuation acknowledgement should pass the bound probe")
	probe.queue_free()
	await process_frame


func _test_invalid_challenge_and_cancellation() -> void:
	var fake := FakeApiClient.new()
	var probe := DeterministicProbe.new()
	probe.set_api_client_for_testing(fake)
	get_root().add_child(probe)
	var failures := PackedStringArray()
	probe.probe_failed.connect(func(_binding: Dictionary, message: String): failures.append(message))
	probe.start_probe(_config())
	fake.request_completed.emit({"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": [{"id": "bad", "type": "function", "function": {"name": Probe.PROBE_FUNCTION, "arguments": "{\"challenge\":\"wrong\"}"}}]}}]})
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
