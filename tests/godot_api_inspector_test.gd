extends SceneTree

const GodotApiInspector = preload("res://addons/orca/scripts/godot_api_inspector.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_node_overview()
	_test_inherited_and_exact_method()
	_test_member_kinds()
	_test_unknowns_and_types()
	_test_bounds_and_help_topics()
	_test_global_class_metadata()
	_test_no_instantiation_calls()
	_finish()


func _test_node_overview() -> void:
	var result: Dictionary = GodotApiInspector.inspect({"class_name": "Node"})
	_expect(result.get("success", false), "Node overview should succeed")
	_expect(result.get("outcome") == "completed", "successful results should use the Tools outcome shape")
	var content := str(result.get("content", ""))
	_expect(content.to_utf8_buffer().size() <= GodotApiInspector.MAX_OUTPUT_BYTES, "overview output must remain within 64 KiB")
	var parsed = JSON.parse_string(content)
	_expect(typeof(parsed) == TYPE_DICTIONARY, "overview content should be valid whole JSON")
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_expect(parsed.get("source") == "godot_classdb", "the report should identify ClassDB as its source")
	_expect(parsed.get("class", {}).get("name") == "Node", "the requested class should be retained")
	_expect(parsed.get("engine_version", {}).get("major") == 4, "the engine version should be included")
	_expect(parsed.get("members", []).size() <= GodotApiInspector.MAX_OVERVIEW_MEMBERS, "class overviews should return at most 80 members")
	_expect(result.get("data", {}).get("returned_member_count") == parsed.get("returned_member_count"), "structured data should match serialized content")


func _test_inherited_and_exact_method() -> void:
	var result: Dictionary = GodotApiInspector.inspect({"class_name": "Node2D", "member_name": "add_child", "member_kind": "method", "include_inherited": true})
	_expect(result.get("success", false), "an inherited exact method should be found when requested")
	var member := _first_member(result)
	_expect(member.get("declaring_class") == "Node", "inherited methods should identify their declaring class")
	_expect(str(member.get("signature", "")).begins_with("add_child("), "methods should include a readable signature")
	_expect(member.get("arguments", []).size() <= GodotApiInspector.MAX_ARGUMENTS, "method arguments should be bounded")
	var local_only: Dictionary = GodotApiInspector.inspect({"class_name": "Node2D", "member_name": "add_child", "member_kind": "method", "include_inherited": false})
	_expect(not local_only.get("success", true), "inherited methods should be excluded when include_inherited is false")


func _test_member_kinds() -> void:
	var cases := [
		["property", "name", "Node"],
		["signal", "ready", "Node"],
		["constant", "PROCESS_MODE_INHERIT", "Node"],
		["enum", "ProcessMode", "Node"]
	]
	for entry in cases:
		var result: Dictionary = GodotApiInspector.inspect({"class_name": "Node", "member_name": entry[1], "member_kind": entry[0]})
		_expect(result.get("success", false), "%s lookup should succeed" % entry[0])
		var member := _first_member(result)
		_expect(member.get("kind") == entry[0], "%s lookup should return the requested kind" % entry[0])
		_expect(member.get("declaring_class") == entry[2], "%s should include its declaring class" % entry[0])
		if entry[0] == "property":
			_expect(typeof(member.get("type")) == TYPE_DICTIONARY, "properties should include their reflected type")
		if entry[0] == "signal":
			_expect(member.has("arguments"), "signals should include reflected arguments")
		if entry[0] == "constant":
			_expect(typeof(member.get("value")) == TYPE_INT, "constants should include integer values")
		if entry[0] == "enum":
			_expect(not member.get("values", []).is_empty(), "enums should include named integer values")


func _test_unknowns_and_types() -> void:
	var invalid := [
		{},
		{"class_name": 42},
		{"class_name": ""},
		{"class_name": "DefinitelyNotAGodotClass"},
		{"class_name": "Node", "member_name": ""},
		{"class_name": "Node", "member_name": 42},
		{"class_name": "Node", "member_kind": "field"},
		{"class_name": "Node", "include_inherited": 1},
		{"class_name": "Node", "unexpected": true},
		{"class_name": "Node", "member_name": "definitely_missing", "member_kind": "auto"},
		{"class_name": "x".repeat(GodotApiInspector.MAX_STRING_CHARS + 1)}
	]
	for arguments in invalid:
		var result: Dictionary = GodotApiInspector.inspect(arguments)
		_expect(not result.get("success", true), "invalid arguments or unknown API names should fail")
		_expect(result.get("outcome") == "failed" and result.get("data", {}).is_empty(), "failures should use the Tools result shape without navigation data")


func _test_bounds_and_help_topics() -> void:
	var overview: Dictionary = GodotApiInspector.inspect({"class_name": "Object", "include_inherited": true})
	var report: Dictionary = overview.get("data", {})
	_expect(report.get("members", []).size() <= GodotApiInspector.MAX_OVERVIEW_MEMBERS, "overview member bounds should be enforced")
	_expect(report.get("class", {}).get("hierarchy", []).size() <= GodotApiInspector.MAX_PARENT_DEPTH, "parent traversal should be bounded")
	_expect(report.get("help_topic") == "class_name:Object", "class help topics should use the public topic format")
	var exact: Dictionary = GodotApiInspector.inspect({"class_name": "Node", "member_name": "add_child", "member_kind": "method"})
	_expect(exact.get("data", {}).get("members", []).size() <= GodotApiInspector.MAX_EXACT_MATCHES, "exact matches should be bounded")
	_expect(_first_member(exact).get("help_topic") == "class_method:Node:add_child", "member help topics should be generated from reflected identifiers")
	var filtered: Dictionary = GodotApiInspector.inspect({"class_name": "Node", "member_kind": "signal", "include_inherited": false})
	for member in filtered.get("data", {}).get("members", []):
		_expect(member.get("kind") == "signal", "overview member_kind should filter records")


func _test_global_class_metadata() -> void:
	var found := false
	for metadata in ProjectSettings.get_global_class_list():
		if typeof(metadata) != TYPE_DICTIONARY or str(metadata.get("class", "")) != "OrcaDiagnosticsService":
			continue
		found = true
		var result: Dictionary = GodotApiInspector.inspect({"class_name": "OrcaDiagnosticsService", "include_inherited": false})
		_expect(result.get("success", false), "registered project global classes should be recognized without loading their scripts")
		_expect(result.get("data", {}).get("class", {}).get("global_class", {}).get("path") == str(metadata.get("path", "")), "global class metadata should retain its registered path")
		_expect(result.get("data", {}).get("members", []).is_empty(), "unloaded global classes should not claim script-declared members")
		break
	_expect(found, "the project's registered Orca global class should be available as metadata")


func _test_no_instantiation_calls() -> void:
	var file := FileAccess.open("res://addons/orca/scripts/godot_api_inspector.gd", FileAccess.READ)
	_expect(file != null, "the inspector source should be readable for the no-instantiation regression check")
	if file == null:
		return
	var source := file.get_as_text()
	file.close()
	_expect(not source.contains("ClassDB.instantiate"), "API reflection must not instantiate ClassDB objects")
	_expect(not source.contains(".instantiate("), "API reflection must not instantiate scenes")
	_expect(not source.contains(".new()"), "API reflection must not construct reflected classes")
	_expect(not source.contains("EditorHelp"), "API reflection must not scrape private Help controls")


func _first_member(result: Dictionary) -> Dictionary:
	var members: Array = result.get("data", {}).get("members", [])
	return members[0] if not members.is_empty() else {}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("godot_api_inspector_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("godot_api_inspector_test: ", failure)
	quit(1)
