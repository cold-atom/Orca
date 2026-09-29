extends SceneTree

const Tools = preload("res://addons/orca/scripts/tools.gd")
const SceneInspector = preload("res://addons/orca/scripts/scene_inspector.gd")
const FIXTURE := "res://tests/fixtures/inspect_scene_fixture.tscn"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_complete_inspection()
	_test_bounds_and_structure_only()
	_test_variant_summaries()
	_test_rejections()
	_finish()


func _test_complete_inspection() -> void:
	var result: Dictionary = Tools.execute_tool("inspect_scene", {"scene_path": FIXTURE})
	_expect(result.get("success", false), "a valid saved scene should be inspectable")
	var content := str(result.get("content", ""))
	_expect(content.to_utf8_buffer().size() <= SceneInspector.MAX_OUTPUT_BYTES, "scene output must remain within its byte limit")
	var report = JSON.parse_string(content)
	_expect(report is Dictionary, "scene output should be valid JSON")
	if not report is Dictionary:
		return
	_expect(report.get("source") == "saved_scene_state", "scene output should identify its saved-state source")
	_expect(report.get("scene_node_count") == 5, "the fixture should expose five locally serialized nodes")
	_expect(report.get("scene_connection_count") == 1, "the fixture signal connection should be reported")
	var player := _node_by_path(report.get("nodes", []), "./Player")
	_expect(not player.is_empty() and player.get("type") == "CharacterBody2D", "node paths and types should be retained")
	_expect("actors" in player.get("groups", []), "node groups should be retained")
	var root := _node_by_path(report.get("nodes", []), ".")
	var position := _property_by_name(root.get("properties", []), "position")
	_expect(position.get("value", {}).get("type") == "Vector2", "Godot value types should be summarized safely")
	var instance := _node_by_path(report.get("nodes", []), "./ChildInstance")
	_expect(str(instance.get("instance_scene", "")).ends_with("inspect_scene_child.tscn"), "instanced scene paths should be reported without recursive expansion")
	var connections: Array = report.get("connections", [])
	if connections.size() == 1:
		_expect(connections[0].get("source") == "Timer" and connections[0].get("signal") == "timeout", "signal source and name should be retained")
		_expect(connections[0].get("method") == "_on_timer_timeout", "signal target method should be retained")
	_expect(result.get("data", {}).get("open_path") == FIXTURE, "successful inspection should expose validated scene navigation")


func _test_bounds_and_structure_only() -> void:
	var bounded: Dictionary = Tools.execute_tool("inspect_scene", {"scene_path": FIXTURE, "max_nodes": 2, "max_properties_per_node": 1})
	var report = JSON.parse_string(str(bounded.get("content", "")))
	_expect(report is Dictionary and report.get("returned_node_count") == 2, "requested node bounds should be clamped and enforced")
	_expect(report.get("truncation", {}).get("truncated") == true, "bounded scene output should report truncation")
	var structure: Dictionary = Tools.execute_tool("inspect_scene", {"scene_path": FIXTURE, "include_properties": false})
	var structure_report = JSON.parse_string(str(structure.get("content", "")))
	_expect(structure_report is Dictionary and structure_report.get("returned_node_count") == 5, "structure-only inspection should retain nodes")
	for node in structure_report.get("nodes", []):
		_expect(not node.has("properties"), "structure-only inspection should omit property values")


func _test_variant_summaries() -> void:
	var long_string = SceneInspector._summarize_variant("x".repeat(SceneInspector.MAX_STRING_CHARS + 20), 0)
	_expect(long_string is Dictionary and long_string.get("truncated") == true, "long strings should be summarized with explicit truncation")
	var values := []
	for index in range(SceneInspector.MAX_COLLECTION_ITEMS + 5):
		values.append(index)
	var array_summary: Dictionary = SceneInspector._summarize_variant(values, 0)
	_expect(array_summary.get("items", []).size() == SceneInspector.MAX_COLLECTION_ITEMS, "array summaries should be bounded")
	_expect(array_summary.get("truncated") == true, "bounded array summaries should report truncation")
	var deep = [[[[[1]]]]]
	var deep_summary = SceneInspector._summarize_variant(deep, 0)
	_expect(JSON.stringify(deep_summary).contains("depth_limit"), "recursive summaries should stop at the depth limit")


func _test_rejections() -> void:
	for arguments in [
		{"scene_path": 42},
		{"scene_path": FIXTURE, "include_properties": "yes"},
		{"scene_path": FIXTURE, "max_nodes": 2.5},
		{"scene_path": "/tmp/outside.tscn"},
		{"scene_path": "res://addons/orca/scenes/chat_window.tscn"},
		{"scene_path": "res://project.godot"},
		{"scene_path": "res://missing_scene.tscn"}
	]:
		var result: Dictionary = Tools.execute_tool("inspect_scene", arguments)
		_expect(not result.get("success", true), "invalid scene inspection targets should fail")
		_expect(not result.get("data", {}).has("open_path"), "failed inspection must not expose navigation metadata")


func _node_by_path(nodes: Array, path: String) -> Dictionary:
	for node in nodes:
		if str(node.get("path", "")) == path:
			return node
	return {}


func _property_by_name(properties: Array, name: String) -> Dictionary:
	for property in properties:
		if str(property.get("name", "")) == name:
			return property
	return {}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("scene_inspector_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("scene_inspector_test: ", failure)
	quit(1)
