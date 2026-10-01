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
	var intelligence_group = ToolActivityGroup.new()
	get_root().add_child(intelligence_group)
	await process_frame
	var help_topics := []
	intelligence_group.help_requested.connect(func(topic: String): help_topics.append(topic))
	var api_card = intelligence_group.add_tool("api_1", "inspect_godot_api", {"class_name": "Node", "member_name": "add_child", "member_kind": "method", "include_inherited": true})
	_expect(intelligence_group._header_button.text.contains("Inspect Godot API"), "Godot API inspection should have an Orca-native grouped label")
	_expect(intelligence_group._header_button.text.contains("Node.add_child"), "Godot API inspection should retain a concise class/member target")
	intelligence_group.complete_tool("api_1", {"content": "private API report", "outcome": "completed", "data": {"help_topic": "class_method:Node:add_child"}}, 15)
	_expect(api_card._help_button.visible and api_card._help_button.text == "Open Docs", "safe API help metadata should expose Open Docs")
	api_card._help_button.pressed.emit()
	_expect(help_topics == ["class_method:Node:add_child"], "help navigation should be forwarded through the activity group")
	intelligence_group.set_expanded(true)
	api_card._toggle_details()
	await process_frame
	_expect(intelligence_group.get_combined_minimum_size().x <= 300.0, "expanded intelligence activity and Open Docs must fit a 300 px dock")
	intelligence_group.queue_free()
	var invalid_help_group = ToolActivityGroup.new()
	get_root().add_child(invalid_help_group)
	await process_frame
	var invalid_card = invalid_help_group.add_tool("api_bad", "inspect_godot_api", {"class_name": "Node"})
	invalid_help_group.complete_tool("api_bad", {"content": "report", "outcome": "completed", "data": {"help_topic": "https://example.invalid/docs"}}, 5)
	_expect(not invalid_card._help_button.visible, "unrecognized help topic prefixes must not expose navigation")
	invalid_help_group.complete_tool("api_bad", {"content": "report", "outcome": "completed", "data": {"help_topic": "class_name:" + "N".repeat(300)}}, 5)
	_expect(not invalid_card._help_button.visible, "oversized help topics must not expose navigation")
	invalid_help_group.queue_free()
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
