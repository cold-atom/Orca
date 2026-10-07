@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

signal open_requested(filepath: String, line: int, column: int)
signal help_requested(topic: String)

const MAX_HELP_TOPIC_CHARS := 256
const HELP_TOPIC_PREFIXES := ["class_name", "class_method", "class_property", "class_signal", "class_constant", "class_enum"]

var _header_button: Button
var _status_label: Label
var _details: TextEdit
var _open_button: Button
var _help_button: Button
var _expanded := false
var _tool_name := ""
var _target := ""
var _open_path := ""
var _open_line := 1
var _open_column := 1
var _help_topic := ""


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.09, 0.1, 0.115, 0.9)
	panel_style.border_color = Color(0.2, 0.22, 0.25, 1)
	panel_style.set_border_width_all(UiMetrics.scaled_int(1))
	panel_style.set_corner_radius_all(UiMetrics.scaled_int(6))
	panel_style.set_content_margin_all(UiMetrics.scaled(6))
	add_theme_stylebox_override("panel", panel_style)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(4))
	add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	content.add_child(header)

	_header_button = Button.new()
	_header_button.flat = true
	_header_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header_button.custom_minimum_size.x = 0
	_header_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_button.clip_text = true
	_header_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var label_font_size := 13
	var meta_font_size := 11
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		label_font_size = maxi(editor_theme.get_font_size("font_size", "Label"), 12)
		meta_font_size = maxi(label_font_size - 1, 11)
	_header_button.add_theme_font_size_override("font_size", label_font_size)
	_header_button.pressed.connect(_toggle_details)
	header.add_child(_header_button)

	_status_label = Label.new()
	_status_label.text = "RUNNING"
	_status_label.add_theme_color_override("font_color", Color(0.55, 0.72, 0.95))
	_status_label.add_theme_font_size_override("font_size", meta_font_size)
	header.add_child(_status_label)

	_open_button = Button.new()
	_open_button.text = "Open"
	_open_button.flat = true
	_open_button.add_theme_font_size_override("font_size", label_font_size)
	_open_button.visible = false
	_open_button.pressed.connect(func(): open_requested.emit(_open_path, _open_line, _open_column))
	header.add_child(_open_button)

	_help_button = Button.new()
	_help_button.text = "Open Docs"
	_help_button.flat = true
	_help_button.add_theme_font_size_override("font_size", label_font_size)
	_help_button.visible = false
	_help_button.pressed.connect(func(): help_requested.emit(_help_topic))
	header.add_child(_help_button)

	_details = TextEdit.new()
	_details.custom_minimum_size = Vector2(0, UiMetrics.scaled(150))
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.editable = false
	_details.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_details.add_theme_font_size_override("font_size", label_font_size)
	_details.visible = false
	content.add_child(_details)


func configure(tool_name: String, arguments: Dictionary) -> void:
	_tool_name = tool_name
	_target = _target_from_arguments(arguments)
	_help_topic = ""
	_help_button.visible = false
	if arguments.has("filepath"):
		_open_path = str(arguments["filepath"])
		_open_line = maxi(1, int(arguments.get("start_line", 1)))
		_open_button.visible = not _open_path.is_empty()
	_update_header()


func complete(execution: Dictionary, duration_ms: int) -> void:
	var result := str(execution.get("content", ""))
	var outcome := str(execution.get("outcome", "failed"))
	var data: Dictionary = execution.get("data", {})
	_details.text = result
	if data.has("open_path"):
		_open_path = str(data["open_path"])
		_open_line = maxi(1, int(data.get("open_line", 1)))
		_open_column = maxi(1, int(data.get("open_column", 1)))
		_open_button.visible = not _open_path.is_empty()
	var help_topic := str(data.get("help_topic", ""))
	if is_safe_help_topic(help_topic):
		_help_topic = help_topic
		_help_button.visible = true
	_status_label.text = outcome.to_upper() + " · " + _format_duration(duration_ms)
	_status_label.add_theme_color_override(
		"font_color",
		Color(0.45, 0.82, 0.55) if outcome == "completed" or outcome == "applied" else Color(0.95, 0.4, 0.4)
	)
	_update_header()


func _toggle_details() -> void:
	_expanded = not _expanded
	_details.visible = _expanded
	_update_header()


func _update_header() -> void:
	var arrow := "v" if _expanded else ">"
	var label := _display_name(_tool_name)
	if not _target.is_empty():
		label += "  " + _target
	_header_button.text = arrow + "  " + label
	_header_button.tooltip_text = label


func _display_name(tool_name: String) -> String:
	match tool_name:
		"read_file":
			return "Read file"
		"list_directory":
			return "List directory"
		"search_files":
			return "Search project"
		"inspect_scene":
			return "Inspect scene"
		"inspect_project_settings":
			return "Inspect project settings"
		"read_project_skill":
			return "Read project skill"
		"inspect_godot_api":
			return "Inspect Godot API"
		"read_gdscript_function":
			return "Read GDScript function"
		"discover_dependencies":
			return "Discover dependencies"
		"get_editor_context":
			return "Inspect editor context"
		"get_diagnostics":
			return "Read game status and diagnostics"
		"observe_game_run":
			return "Observe game run"
		"verify_game_run":
			return "Verify game criterion"
		"run_current_scene":
			return "Run current scene"
		"run_main_scene":
			return "Run main scene"
		"stop_game":
			return "Stop Orca game"
		"update_tasks":
			return "Update task checklist"
		"request_work_mode":
			return "Work mode decision"
		"apply_patch":
			return "Prepare file patch"
		"propose_input_map_changes":
			return "Prepare Input Map changes"
		"propose_main_scene_change":
			return "Prepare main scene change"
		"propose_project_settings_changes":
			return "Prepare Project Settings changes"
		"propose_scene_changes":
			return "Prepare scene changes"
		_:
			return tool_name.replace("_", " ").capitalize()


func _target_from_arguments(arguments: Dictionary) -> String:
	if _tool_name == "read_project_skill":
		return str(arguments.get("name", ""))
	if _tool_name == "inspect_godot_api":
		var api_target := str(arguments.get("class_name", ""))
		var member := str(arguments.get("member_name", ""))
		return api_target + ("." + member if not member.is_empty() else "")
	if _tool_name == "read_gdscript_function":
		var function_path := str(arguments.get("filepath", ""))
		var function_name := str(arguments.get("function_name", ""))
		return function_path + (" :: " + function_name if not function_name.is_empty() else "")
	if _tool_name == "discover_dependencies":
		var dependency_path := str(arguments.get("filepath", ""))
		var direction := str(arguments.get("direction", ""))
		return dependency_path + (" · " + direction if not direction.is_empty() else "")
	if arguments.has("scene_path"):
		return str(arguments["scene_path"])
	if arguments.has("setting_path") and not str(arguments["setting_path"]).is_empty():
		return str(arguments["setting_path"])
	if arguments.has("filepath"):
		return str(arguments["filepath"])
	if arguments.has("query"):
		return '"' + str(arguments["query"]) + '"'
	if arguments.has("path"):
		return str(arguments["path"])
	return ""


static func is_safe_help_topic(topic: String) -> bool:
	if topic.is_empty() or topic.length() > MAX_HELP_TOPIC_CHARS or topic.contains("\n") or topic.contains("\r") or topic.contains("\t"):
		return false
	var parts := topic.split(":", true)
	if parts.is_empty() or parts[0] not in HELP_TOPIC_PREFIXES:
		return false
	var expected_parts := 2 if parts[0] == "class_name" else 3
	if parts.size() != expected_parts:
		return false
	for index in range(1, parts.size()):
		if str(parts[index]).is_empty():
			return false
	return true


func _format_duration(duration_ms: int) -> String:
	if duration_ms < 1000:
		return str(duration_ms) + " ms"
	return "%.1f s" % (duration_ms / 1000.0)
