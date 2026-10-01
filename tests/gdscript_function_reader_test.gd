extends SceneTree

const FunctionReader = preload("res://addons/orca/scripts/gdscript_function_reader.gd")
const FIXTURE := "res://tests/fixtures/gdscript_function_reader_fixture.gd"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_disk_read_and_lexing()
	_test_ambiguity_and_hint()
	_test_editor_source_and_crlf()
	_test_bounds()
	_test_rejections()
	_test_symbolic_link_rejection()
	_finish()


func _test_disk_read_and_lexing() -> void:
	var result := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "documented"})
	_expect(result.get("success", false), "a saved function should be readable")
	_expect(result.get("source_kind") == "disk", "saved source should identify disk provenance")
	_expect(str(result.get("disk_sha256", "")).length() == 64, "disk source should include its SHA-256")
	_expect(result.get("start_line") == 3 and result.get("declaration_line") == 7, "documentation and multiline annotations should be included with one-based navigation")
	_expect(str(result.get("content", "")).begins_with("## Returns"), "documentation should be returned by default")
	_expect(str(result.get("content", "")).contains("func fake_in_triple():"), "string contents inside the selected function should remain exact")
	_expect(result.get("function_end_line") == 16, "comments, strings, and multiline signatures must not alter the function boundary")
	var without_docs := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "documented", "include_documentation": false})
	_expect(without_docs.get("start_line") == without_docs.get("declaration_line"), "documentation exclusion should start at the declaration")
	var after := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "after_classes"})
	_expect(after.get("success", false) and after.get("class_path") == "", "dedenting should leave nested class scope")


func _test_ambiguity_and_hint() -> void:
	var ambiguous := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "duplicate"})
	_expect(not ambiguous.get("success", true), "duplicate names in nested classes should fail without a hint")
	_expect(ambiguous.get("candidate_count") == 2 and ambiguous.get("candidates", []).size() == 2, "ambiguity should return bounded candidate locations")
	var selected := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "duplicate", "start_line_hint": 27})
	_expect(selected.get("success", false), "a unique line hint should resolve duplicate names")
	_expect(selected.get("class_path") == "Second.Nested", "candidate scope should identify nested classes")
	_expect(str(selected.get("content", "")).contains("second"), "the hinted candidate should be returned")


func _test_editor_source_and_crlf() -> void:
	var source := "extends Node\r\n\r\n## Live docs\r\nfunc live(\r\n\tvalue := \"# text\"\r\n):\r\n\treturn value\r\n\r\nfunc disk_only():\r\n\tpass\r\n"
	var result := FunctionReader.read_function(
		{"filepath": FIXTURE, "function_name": "live"},
		{"filepath": FIXTURE, "source": source}
	)
	_expect(result.get("success", false), "a matching caller-supplied editor source should be readable")
	_expect(result.get("source_kind") == "editor", "open source should identify editor provenance")
	_expect(not result.has("disk_sha256"), "editor source must not claim a disk SHA")
	_expect(str(result.get("content", "")).contains("\r\n"), "CRLF source should retain CRLF in returned content")
	_expect(result.get("declaration_line") == 4 and result.get("function_end_line") == 7, "CRLF lines should use correct one-based ranges")


func _test_bounds() -> void:
	var many_lines := "func huge():\n"
	for index in range(FunctionReader.MAX_RETURN_LINES + 20):
		many_lines += "\tvar value_%d = %d\n" % [index, index]
	var line_bounded := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "huge"}, {"filepath": FIXTURE, "source": many_lines})
	_expect(line_bounded.get("returned_line_count") == FunctionReader.MAX_RETURN_LINES, "function output should enforce the line bound")
	_expect(line_bounded.get("truncation_reasons", []).has("line_limit"), "line truncation should be explicit")
	var wide_source := "func wide():\n\tvar value = \"%s\"\n" % "x".repeat(FunctionReader.MAX_RETURN_BYTES + 100)
	var byte_bounded := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "wide"}, {"filepath": FIXTURE, "source": wide_source})
	_expect(str(byte_bounded.get("content", "")).to_utf8_buffer().size() <= FunctionReader.MAX_RETURN_BYTES, "function output should enforce the UTF-8 byte bound")
	_expect(byte_bounded.get("truncation_reasons", []).has("byte_limit"), "byte truncation should be explicit")
	var oversized := "func oversized():\n\tpass\n" + "x".repeat(FunctionReader.MAX_SOURCE_BYTES)
	_expect(not FunctionReader.read_function({"filepath": FIXTURE, "function_name": "oversized"}, {"filepath": FIXTURE, "source": oversized}).get("success", true), "open source over 2 MiB should fail")
	var duplicates := ""
	for index in range(FunctionReader.MAX_CANDIDATES + 5):
		duplicates += "class Candidate%d:\n\tfunc repeated():\n\t\tpass\n" % index
	var many_candidates := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "repeated"}, {"filepath": FIXTURE, "source": duplicates})
	_expect(many_candidates.get("candidate_count") == FunctionReader.MAX_CANDIDATES + 5, "ambiguity should report the complete candidate count")
	_expect(many_candidates.get("candidates", []).size() == FunctionReader.MAX_CANDIDATES and many_candidates.get("candidates_truncated") == true, "ambiguity details should be capped at twenty candidates")


func _test_rejections() -> void:
	for arguments in [
		{},
		{"filepath": 42, "function_name": "documented"},
		{"filepath": FIXTURE, "function_name": "not valid"},
		{"filepath": FIXTURE, "function_name": "documented", "start_line_hint": 0},
		{"filepath": FIXTURE, "function_name": "documented", "include_documentation": "yes"},
		{"filepath": FIXTURE, "function_name": "documented", "unknown": true},
		{"filepath": "tests/fixtures/gdscript_function_reader_fixture.gd", "function_name": "documented"},
		{"filepath": "res://tests/fixtures/../fixtures/gdscript_function_reader_fixture.gd", "function_name": "documented"},
		{"filepath": "res://project.godot", "function_name": "documented"},
		{"filepath": "res://addons/orca/scripts/tools.gd", "function_name": "execute_tool"},
		{"filepath": "res://tests/fixtures/missing.gd", "function_name": "missing"}
	]:
		_expect(not FunctionReader.read_function(arguments).get("success", true), "invalid arguments or targets should fail: " + str(arguments))
	var mismatch := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "documented"}, {"filepath": "res://other.gd", "source": "func documented():\n\tpass"})
	_expect(not mismatch.get("success", true), "an editor source for another path should fail")
	var fake_only := FunctionReader.read_function({"filepath": FIXTURE, "function_name": "fake_in_comment"})
	_expect(not fake_only.get("success", true), "function text in comments should not become a candidate")


func _test_symbolic_link_rejection() -> void:
	if not OS.has_feature("linux") and not OS.has_feature("macos"):
		return
	var link_path := "res://tests/fixtures/gdscript_function_reader_link.gd"
	var absolute_link := ProjectSettings.globalize_path(link_path)
	var absolute_fixture := ProjectSettings.globalize_path(FIXTURE)
	DirAccess.remove_absolute(absolute_link)
	var exit_code := OS.execute("ln", PackedStringArray(["-s", absolute_fixture, absolute_link]))
	if exit_code != 0:
		_expect(false, "the symlink rejection fixture could not be created")
		return
	var result := FunctionReader.read_function({"filepath": link_path, "function_name": "documented"})
	_expect(not result.get("success", true), "script paths containing symbolic links should fail")
	DirAccess.remove_absolute(absolute_link)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("gdscript_function_reader_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("gdscript_function_reader_test: ", failure)
	quit(1)
