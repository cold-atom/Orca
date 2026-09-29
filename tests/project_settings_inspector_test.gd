extends SceneTree

const ProjectSettingsInspector = preload("res://addons/orca/scripts/project_settings_inspector.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

var _failures := PackedStringArray()
var _fixture_paths := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_summary()
	_test_explicit_setting()
	_test_feature_override_and_output_limit()
	_test_input_actions_and_bounds()
	_test_rejections()
	_cleanup()
	_finish()


func _test_summary() -> void:
	var result: Dictionary = ProjectSettingsInspector.inspect()
	_expect(result.get("success", false), "the bounded project settings overview should succeed")
	var content := str(result.get("content", ""))
	_expect(content.to_utf8_buffer().size() <= ProjectSettingsInspector.MAX_OUTPUT_BYTES, "the overview must respect its output byte limit")
	var parsed = JSON.parse_string(content)
	_expect(typeof(parsed) == TYPE_DICTIONARY, "the overview should be valid whole JSON")
	if typeof(parsed) == TYPE_DICTIONARY:
		_expect(parsed.get("source") == "effective_project_settings", "the overview should identify its data source")
		_expect(typeof(parsed.get("application")) == TYPE_ARRAY, "the overview should include selected application settings")
		_expect(typeof(parsed.get("input_actions")) == TYPE_ARRAY, "the overview should include bounded input actions")
		_expect(typeof(parsed.get("rendering")) == TYPE_ARRAY, "the overview should include selected rendering settings")


func _test_explicit_setting() -> void:
	var path := "physics/2d/default_gravity_vector"
	var result: Dictionary = ProjectSettingsInspector.inspect(path)
	_expect(result.get("success", false), "an explicit existing setting should be readable")
	var parsed = JSON.parse_string(str(result.get("content", "")))
	_expect(typeof(parsed) == TYPE_DICTIONARY, "an explicit setting should return valid JSON")
	if typeof(parsed) == TYPE_DICTIONARY:
		_expect(parsed.get("setting_path") == path, "the explicit report should retain the exact path")
		_expect(parsed.get("setting", {}).get("type") == "Vector2", "explicit values should retain their Godot Variant type")
	var tool_result: Dictionary = Tools.execute_tool("inspect_project_settings", {"setting_path": path})
	_expect(tool_result.get("success", false), "the public tool dispatcher should execute explicit setting reads")
	_expect(tool_result.get("data", {}).get("open_path") == "res://project.godot", "successful settings reads should provide project.godot navigation")


func _test_feature_override_and_output_limit() -> void:
	if OS.has_feature("linux"):
		var override_path := "application/config/name.linux"
		_set_fixture(override_path, "Orca Feature Override")
		var overridden: Dictionary = ProjectSettingsInspector.inspect("application/config/name")
		_expect(overridden.get("report", {}).get("setting", {}).get("value") == "Orca Feature Override", "explicit reads should apply active Godot feature overrides")
	var large_items := []
	for index in range(ProjectSettingsInspector.MAX_COLLECTION_ITEMS):
		large_items.append(("value-%d-" % index) + "x".repeat(ProjectSettingsInspector.MAX_STRING_CHARS))
	var large_value := {}
	for index in range(ProjectSettingsInspector.MAX_COLLECTION_ITEMS):
		large_value["key_%d" % index] = large_items
	var oversized_report := {"source": "test", "setting_path": "rendering/test", "setting": {"type": "Dictionary", "value": large_value}}
	var content := ProjectSettingsInspector._serialize_explicit(oversized_report)
	_expect(content.to_utf8_buffer().size() <= ProjectSettingsInspector.MAX_OUTPUT_BYTES, "explicit setting output must respect the hard byte limit")
	var parsed = JSON.parse_string(content)
	_expect(typeof(parsed) == TYPE_DICTIONARY, "bounded explicit output should remain valid whole JSON")
	if typeof(parsed) == TYPE_DICTIONARY:
		_expect(parsed.get("truncation", {}).get("reasons", []).has("output_limit"), "oversized explicit values should report output truncation")


func _test_input_actions_and_bounds() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_SPACE
	var action_path := "input/orca_test_action"
	_set_fixture(action_path, {"deadzone": 0.25, "events": [event]})
	var result: Dictionary = ProjectSettingsInspector.inspect()
	var report: Dictionary = result.get("report", {})
	var found := false
	for action in report.get("input_actions", []):
		if action.get("name") == "orca_test_action":
			found = true
			_expect(action.get("deadzone") == 0.25, "input action deadzones should be retained")
			_expect(action.get("events", []).size() == 1, "input events should be summarized")
			_expect(action.get("events", [])[0].get("type") == "InputEventKey", "input event classes should be typed")
	_expect(found, "custom input actions should appear in the overview")

	for index in range(ProjectSettingsInspector.MAX_INPUT_ACTIONS + 2):
		_set_fixture("input/orca_test_bound_%03d" % index, {"deadzone": 0.5, "events": []})
	result = ProjectSettingsInspector.inspect()
	report = result.get("report", {})
	_expect(int(report.get("returned_input_action_count", 0)) <= ProjectSettingsInspector.MAX_INPUT_ACTIONS, "returned input actions should be hard bounded")
	_expect(report.get("truncation", {}).get("reasons", []).has("input_action_limit"), "input action truncation should be explicit")


func _test_rejections() -> void:
	for path in ["missing/setting", "application/config/api_key", "/malformed", "bad//path", "x".repeat(ProjectSettingsInspector.MAX_SETTING_PATH_CHARS + 1)]:
		var result: Dictionary = ProjectSettingsInspector.inspect(path)
		_expect(not result.get("success", true), "invalid or unavailable setting paths should fail: " + path)
	var wrong_type: Dictionary = Tools.execute_tool("inspect_project_settings", {"setting_path": 42})
	_expect(not wrong_type.get("success", true), "setting_path should require an exact string type")
	var sensitive: Dictionary = Tools.execute_tool("inspect_project_settings", {"setting_path": "application/config/private_key"})
	_expect(not sensitive.get("success", true), "sensitive-looking settings should be blocked")
	_expect(not sensitive.get("data", {}).has("open_path"), "failed settings reads should expose no navigation")
	_expect(not Tools.execute_tool("inspect_project_settings", {"setting_path": "custom/safe_value"}).get("success", true), "non-allowlisted custom settings should be blocked")
	_expect(not Tools.execute_tool("inspect_project_settings", {"setting_path": ""}).get("success", true), "an explicit empty setting path should be rejected")
	_expect(not Tools.execute_tool("inspect_project_settings", {"unexpected": true}).get("success", true), "unknown arguments should be rejected at runtime")
	var nested_path := "input/orca_test_nested_metadata"
	_set_fixture(nested_path, {"deadzone": 0.5, "events": [], "api_key": "nested-secret-value"})
	var nested: Dictionary = ProjectSettingsInspector.inspect(nested_path)
	_expect(nested.get("success", false), "valid input action dictionaries should remain readable")
	_expect(not str(nested.get("content", "")).contains("nested-secret-value"), "unknown nested input action values must not be exposed")
	var malformed_path := "input/orca_test_malformed"
	_set_fixture(malformed_path, "embedded-secret-value")
	var malformed: Dictionary = ProjectSettingsInspector.inspect(malformed_path)
	_expect(not malformed.get("success", true), "malformed dynamic setting families should not expose arbitrary scalar values")
	var malformed_action_path := "input/orca_test_malformed_action"
	_set_fixture(malformed_action_path, {"deadzone": "deadzone-secret", "events": ["event-secret"]})
	var malformed_action: Dictionary = ProjectSettingsInspector.inspect(malformed_action_path)
	_expect(malformed_action.get("success", false), "malformed input action members should produce a redacted structural report")
	_expect(not str(malformed_action.get("content", "")).contains("deadzone-secret") and not str(malformed_action.get("content", "")).contains("event-secret"), "malformed input action members must be redacted")
	var malformed_autoload_path := "autoload/OrcaTestMalformed"
	_set_fixture(malformed_autoload_path, "autoload-secret")
	var malformed_autoload: Dictionary = ProjectSettingsInspector.inspect(malformed_autoload_path)
	_expect(not malformed_autoload.get("success", true), "autoload values must use the expected resource path shape")
	var summary: Dictionary = ProjectSettingsInspector.inspect()
	_expect(not str(summary.get("content", "")).contains("embedded-secret-value"), "the overview must not expose malformed dynamic setting values")
	_expect(not str(summary.get("content", "")).contains("deadzone-secret") and not str(summary.get("content", "")).contains("event-secret") and not str(summary.get("content", "")).contains("autoload-secret"), "the overview must redact malformed dynamic setting members")


func _set_fixture(path: String, value) -> void:
	ProjectSettings.set_setting(path, value)
	_fixture_paths.append(path)


func _cleanup() -> void:
	for path in _fixture_paths:
		ProjectSettings.set_setting(path, null)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("project_settings_inspector_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("project_settings_inspector_test: ", failure)
	quit(1)
