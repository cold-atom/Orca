extends SceneTree

const ToolLoopGuard = preload("res://addons/orca/scripts/tool_loop_guard.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_identical_calls()
	_test_identical_failures()
	_test_alternating_cycle()
	_test_identical_rounds()
	_test_changed_output()
	_test_progress_epoch_reset()
	_test_unchanged_observation()
	_test_canonical_dictionary_ordering()
	_finish()


func _test_identical_calls() -> void:
	var guard := ToolLoopGuard.new()
	var calls := [_call("read_file", {"filepath": "res://player.gd"}, "success", {"content": "same"})]
	_expect(not guard.record_round(calls, 0).triggered, "the first identical call should not trigger")
	_expect(not guard.record_round(calls, 0).triggered, "the second identical call should not trigger")
	_expect_reason(guard.record_round(calls, 0), ToolLoopGuard.REASON_IDENTICAL_CALL_RESULT, "three identical successful calls")


func _test_identical_failures() -> void:
	var guard := ToolLoopGuard.new()
	var failure := _call("read_file", {"filepath": "res://missing.gd"}, "failure", {"error": "missing"})
	guard.record_round([failure], 0)
	guard.record_round([failure], 0)
	_expect_reason(guard.record_round([failure], 0), ToolLoopGuard.REASON_IDENTICAL_CALL_RESULT, "three identical failed calls")


func _test_alternating_cycle() -> void:
	var guard := ToolLoopGuard.new()
	var first := _call("read_file", {"filepath": "res://a.gd"}, "success", "A")
	var second := _call("read_file", {"filepath": "res://b.gd"}, "success", "B")
	guard.record_round([first, second], 0)
	guard.record_round([first, second], 0)
	_expect_reason(guard.record_round([first, second], 0), ToolLoopGuard.REASON_ALTERNATING_CALL_CYCLE, "an ABABAB call cycle")


func _test_identical_rounds() -> void:
	var guard := ToolLoopGuard.new()
	var calls := [
		_call("read_file", {"filepath": "res://a.gd"}, "success", "A"),
		_call("search_files", {"query": "target"}, "success", "B"),
		_call("get_diagnostics", {}, "success", "C"),
	]
	guard.record_round(calls, 0)
	guard.record_round(calls, 0)
	_expect_reason(guard.record_round(calls, 0), ToolLoopGuard.REASON_IDENTICAL_ROUND, "three identical complete rounds")


func _test_changed_output() -> void:
	var guard := ToolLoopGuard.new()
	for index in range(3):
		var result := guard.record_round([_call("observe_game_run", {"run_id": 1}, "success", {"sequence": index})], 0)
		_expect(not result.triggered, "changed tool output should not be treated as an identical call")


func _test_progress_epoch_reset() -> void:
	var guard := ToolLoopGuard.new()
	for index in range(3):
		_expect(not guard.record_round([_unique_call(index)], 0).triggered, "three no-progress rounds should remain below the threshold")
	_expect(not guard.record_round([_unique_call(3)], 1).triggered, "a changed progress epoch should reset no-progress counting")
	for index in range(4, 7):
		_expect(not guard.record_round([_unique_call(index)], 1).triggered, "the reset no-progress count should remain below four rounds")
	_expect_reason(guard.record_round([_unique_call(7)], 1), ToolLoopGuard.REASON_NO_PROGRESS, "four rounds after the progress reset")
	guard.reset()
	_expect(not guard.record_round([_unique_call(8)], 0).triggered, "reset should begin an independent turn")


func _test_unchanged_observation() -> void:
	var guard := ToolLoopGuard.new()
	var observation := _call("observe_game_run", {"run_id": 9}, "success", {"sequence": 4, "state": "running"})
	guard.record_round([observation], 2)
	guard.record_round([observation], 2)
	_expect_reason(guard.record_round([observation], 2), ToolLoopGuard.REASON_IDENTICAL_CALL_RESULT, "an unchanged observation")


func _test_canonical_dictionary_ordering() -> void:
	var first := {"outer": {"b": 2, "a": 1}, "items": [{"y": true, "x": null}]}
	var second := {"items": [{"x": null, "y": true}], "outer": {"a": 1, "b": 2}}
	_expect(ToolLoopGuard.fingerprint(first) == ToolLoopGuard.fingerprint(second), "recursive dictionary ordering should not change fingerprints")


func _call(name: String, arguments: Variant, outcome: Variant, result: Variant) -> Dictionary:
	return {"name": name, "arguments": arguments, "outcome": outcome, "result": result}


func _unique_call(index: int) -> Dictionary:
	return _call("tool_" + str(index), {"index": index}, "success", {"value": index})


func _expect_reason(result: Dictionary, reason: String, label: String) -> void:
	_expect(result.get("triggered", false), label + " should trigger")
	_expect(result.get("reason", "") == reason, label + " should report reason " + reason)
	_expect(int(result.get("threshold", 0)) > 0, label + " should report its threshold")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("tool_loop_guard_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("tool_loop_guard_test: ", failure)
	quit(1)
