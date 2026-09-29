extends SceneTree

const PatchUtils = preload("res://addons/orca/scripts/patch_utils.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_materialization()
	_test_newline_preservation()
	_test_invalid_edits()
	_finish()


func _test_materialization() -> void:
	_expect_content("one\ntwo\nthree\n", [{"start_line": 2, "end_line": 2, "replacement": "TWO"}], "one\nTWO\nthree\n", "replace one line")
	_expect_content("one\ntwo\nthree\n", [{"start_line": 2, "end_line": 1, "replacement": "inserted"}], "one\ninserted\ntwo\nthree\n", "insert before a line")
	_expect_content("one\ntwo\nthree\n", [{"start_line": 2, "end_line": 2, "replacement": ""}], "one\nthree\n", "delete one line")
	_expect_content("one\ntwo", [{"start_line": 3, "end_line": 2, "replacement": "three"}], "one\ntwo\nthree", "append without a final newline")
	_expect_content("one\ntwo\n", [{"start_line": 3, "end_line": 2, "replacement": "three"}], "one\ntwo\nthree", "append after a final newline")
	_expect_content("", [{"start_line": 1, "end_line": 0, "replacement": "first"}], "first", "create content from an empty file")
	_expect_content("one\ntwo\nthree\n", [{"start_line": 2, "end_line": 2, "replacement": "TWO\nextra"}], "one\nTWO\nextra\nthree\n", "replace one line with multiple lines")
	_expect_content("one\ntwo\nthree\n", [
		{"start_line": 3, "end_line": 3, "replacement": "THREE"},
		{"start_line": 1, "end_line": 1, "replacement": "ONE"}
	], "ONE\ntwo\nTHREE\n", "sort and apply independent edits")
	_expect_content("one\ntwo\n", [
		{"start_line": 1, "end_line": 1, "replacement": "ONE"},
		{"start_line": 2, "end_line": 2, "replacement": "TWO"}
	], "ONE\nTWO\n", "allow adjacent non-overlapping edits")


func _test_newline_preservation() -> void:
	_expect_content("one\r\ntwo\r\n", [{"start_line": 2, "end_line": 2, "replacement": "TWO\nextra"}], "one\r\nTWO\r\nextra\r\n", "preserve CRLF with LF replacement text")
	_expect_content("one\r\ntwo\r\n", [{"start_line": 2, "end_line": 2, "replacement": "TWO\r\nextra"}], "one\r\nTWO\r\nextra\r\n", "preserve CRLF without doubling carriage returns")


func _test_invalid_edits() -> void:
	_expect_failure("one\n", [], "reject an empty edit list")
	_expect_failure("one\n", ["invalid"], "reject non-object edits")
	_expect_failure("one\n", [{"start_line": 0, "end_line": 0, "replacement": "x"}], "reject start line zero")
	_expect_failure("one\n", [{"start_line": 3, "end_line": 2, "replacement": "x"}], "reject a start beyond append position")
	_expect_failure("one\ntwo\n", [{"start_line": 2, "end_line": 0, "replacement": "x"}], "reject an end before insertion position")
	_expect_failure("one\n", [{"start_line": 1, "end_line": 2, "replacement": "x"}], "reject an end beyond the file")
	_expect_failure("one\ntwo\n", [
		{"start_line": 1, "end_line": 1, "replacement": "x"},
		{"start_line": 1, "end_line": 0, "replacement": "y"}
	], "reject duplicate edit positions")
	_expect_failure("one\ntwo\nthree\n", [
		{"start_line": 1, "end_line": 2, "replacement": "x"},
		{"start_line": 2, "end_line": 3, "replacement": "y"}
	], "reject overlapping replacements")
	_expect_failure("one\ntwo\nthree\n", [
		{"start_line": 1, "end_line": 3, "replacement": "x"},
		{"start_line": 2, "end_line": 1, "replacement": "y"}
	], "reject insertion inside a replacement")


func _expect_content(content: String, edits: Array, expected: String, label: String) -> void:
	var result: Dictionary = PatchUtils.apply_line_edits(content, edits)
	_expect(result.get("success", false), label + " should succeed")
	if result.get("success", false):
		_expect(result.get("content", "") == expected, label + " produced unexpected content")


func _expect_failure(content: String, edits: Array, label: String) -> void:
	var result: Dictionary = PatchUtils.apply_line_edits(content, edits)
	_expect(not result.get("success", false), label)
	_expect(not str(result.get("error", "")).is_empty(), label + " should explain the failure")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("patch_utils_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("patch_utils_test: ", failure)
	quit(1)
