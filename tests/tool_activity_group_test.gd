extends SceneTree

const ToolActivityGroup = preload("res://addons/orca/scripts/tool_activity_group.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	get_root().size = Vector2i(300, 900)
	var group = ToolActivityGroup.new()
	get_root().add_child(group)
	await process_frame
	var opened := []
	group.open_requested.connect(func(path: String, line: int, column: int): opened.append([path, line, column]))
	var first = group.add_tool("read_1", "read_file", {"filepath": "res://a/very/long/path/that/must/not/widen/the/dock/player.gd", "start_line": 12})
	var second = group.add_tool("search_1", "search_files", {"query": "a deliberately long search query that should be clipped", "path": "res://"})
	_expect(group.call_count() == 2, "a group should retain every consecutive call")
	_expect(group.aggregate_outcome() == "running", "a group with running children should be running")
	group.complete_tool("read_1", {"content": "read result", "outcome": "completed", "data": {"open_path": "res://player.gd", "open_line": 12, "open_column": 3}}, 400)
	_expect(group.aggregate_outcome() == "running", "one running child should keep the group running")
	group.complete_tool("search_1", {"content": "search failed", "outcome": "failed", "data": {}}, 700)
	_expect(group.aggregate_outcome() == "failed", "a failed child should make the completed group failed")
	_expect(group.total_duration_ms() == 1100, "aggregate duration should sum child durations")
	first.open_requested.emit("res://player.gd", 12, 3)
	_expect(opened.size() == 1 and opened[0] == ["res://player.gd", 12, 3], "child navigation should be forwarded unchanged")
	group.set_expanded(true)
	first._toggle_details()
	second._toggle_details()
	await process_frame
	await process_frame
	_expect(group.get_combined_minimum_size().x <= 300.0, "expanded groups must remain within the 300 px dock width")
	group.close_for_appends()
	_expect(not group.can_append(), "closed groups should reject future appends")
	_expect(group.add_tool("late", "read_file", {}) == null, "a closed group must not accept another call")
	group.queue_free()
	var scene_group = ToolActivityGroup.new()
	get_root().add_child(scene_group)
	await process_frame
	scene_group.add_tool("scene_1", "inspect_scene", {"scene_path": "res://scenes/a/very/long/scene/path/main.tscn"})
	_expect(scene_group._header_button.text.contains("Inspect scene"), "scene inspection should have a readable grouped activity label")
	_expect(scene_group._header_button.text.contains("main.tscn"), "singleton scene inspection should retain its target")
	scene_group.complete_tool("scene_1", {"content": "inspected", "outcome": "completed", "data": {"open_path": "res://scenes/main.tscn"}}, 25)
	await process_frame
	_expect(scene_group.get_combined_minimum_size().x <= 300.0, "scene inspection groups should remain within 300 px")
	scene_group.queue_free()
	var settings_group = ToolActivityGroup.new()
	get_root().add_child(settings_group)
	await process_frame
	settings_group.add_tool("settings_1", "inspect_project_settings", {"setting_path": "application/run/main_scene"})
	_expect(settings_group._header_button.text.contains("Inspect project settings"), "project settings inspection should have a readable grouped activity label")
	_expect(settings_group._header_button.text.contains("application/run/main_scene"), "an explicit setting read should retain its target")
	settings_group.complete_tool("settings_1", {"content": "inspected", "outcome": "completed", "data": {"open_path": "res://project.godot"}}, 20)
	await process_frame
	_expect(settings_group.get_combined_minimum_size().x <= 300.0, "project settings groups should remain within 300 px")
	settings_group.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("tool_activity_group_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("tool_activity_group_test: ", failure)
	quit(1)
