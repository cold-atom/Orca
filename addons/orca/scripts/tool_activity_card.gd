@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const CardHeader = preload("res://addons/orca/scripts/card_header.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

signal open_requested(filepath: String, line: int, column: int)
signal help_requested(topic: String)

const MAX_HELP_TOPIC_CHARS := 256
const HELP_TOPIC_PREFIXES := ["class_name", "class_method", "class_property", "class_signal", "class_constant", "class_enum"]

var _header_button: Button
var _status_label: Label
var _duration_label: Label
var _duration_ms := -1
var _details: TextEdit
var _open_button: Button
var _help_button: Button
var _expanded := false
var _tool_name := ""
var _target := ""
var _target_is_caption := false
var _open_path := ""
var _open_line := 1
var _open_column := 1
var _help_topic := ""
var _match_scroll: ScrollContainer
var _match_list: VBoxContainer
var _match_summary: Label
var _has_match_results := false


func _enter_tree() -> void:
	Localization.attach(self)


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

	var header := CardHeader.new()
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

	_status_label = header.create_status_badge()
	CardHeader.set_status(_status_label, "running")
	_duration_label = Label.new()
	_duration_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_duration_label.add_theme_font_size_override("font_size", meta_font_size)
	_duration_label.add_theme_color_override("font_color", Color(0.55, 0.62, 0.68))
	_duration_label.hide()
	content.add_child(_duration_label)

	var navigation := HFlowContainer.new()
	content.add_child(navigation)
	_open_button = Button.new()
	_open_button.text = "Open"
	_open_button.flat = true
	_open_button.add_theme_font_size_override("font_size", label_font_size)
	_open_button.visible = false
	_open_button.pressed.connect(func(): _request_open(_open_path, _open_line, _open_column))
	navigation.add_child(_open_button)

	_help_button = Button.new()
	_help_button.text = "Open Docs"
	_help_button.flat = true
	_help_button.add_theme_font_size_override("font_size", label_font_size)
	_help_button.visible = false
	_help_button.pressed.connect(func(): help_requested.emit(_help_topic))
	navigation.add_child(_help_button)

	_details = TextEdit.new()
	_details.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_details.custom_minimum_size = Vector2(0, UiMetrics.scaled(150))
	_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_details.editable = false
	_details.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_details.add_theme_font_size_override("font_size", label_font_size)
	_details.visible = false
	content.add_child(_details)
	_match_summary = Label.new()
	_match_summary.clip_text = true
	_match_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_match_summary.add_theme_color_override("font_color", Color(0.55, 0.62, 0.68))
	_match_summary.visible = false
	content.add_child(_match_summary)
	_match_scroll = ScrollContainer.new()
	_match_scroll.custom_minimum_size = Vector2(0, UiMetrics.scaled(160))
	_match_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_match_scroll.visible = false
	content.add_child(_match_scroll)
	_match_list = VBoxContainer.new()
	_match_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_match_scroll.add_child(_match_list)


func configure(tool_name: String, arguments: Dictionary) -> void:
	_tool_name = tool_name
	_target = _target_from_arguments(arguments)
	_target_is_caption = tool_name == "inspect_editor_scene" and str(arguments.get("scope", "selection")) in ["selection", "scene"]
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
	if _tool_name in ["search_files", "find_project_symbols", "find_symbol_references"]:
		_open_path = ""
		_open_button.hide()
		_has_match_results = typeof(data.get("matches")) == TYPE_ARRAY
		_set_navigation_matches(data.get("matches", []))
		var count := _match_list.get_child_count()
		var incomplete: bool = data.get("truncated", false) or data.get("truncation", {}).get("truncated", false) or (_has_match_results and data["matches"].size() > count)
		var caption_arguments := [count, Localization.source(" · Incomplete") if incomplete else ""]
		Localization.bind(_match_summary, &"text", "%d result(s)%s", caption_arguments)
		Localization.bind(_match_summary, &"tooltip_text", "%d result(s)%s", caption_arguments)
		_match_summary.visible = _expanded and _has_match_results
	if data.has("open_path"):
		_open_path = str(data["open_path"])
		_open_line = maxi(1, int(data.get("open_line", 1)))
		_open_column = maxi(1, int(data.get("open_column", 1)))
		_open_button.visible = not _open_path.is_empty()
	var help_topic := str(data.get("help_topic", ""))
	if is_safe_help_topic(help_topic):
		_help_topic = help_topic
		_help_button.visible = true
	_duration_ms = maxi(0, duration_ms)
	CardHeader.set_status(_status_label, outcome)
	Localization.bind(_duration_label, &"text", "Duration: %s", [_format_duration(_duration_ms)])
	var tooltip_parts: Array = _status_label.get_meta(Localization.BINDINGS)[&"tooltip_text"]["parts"].duplicate(true)
	tooltip_parts.append(["\n", []])
	tooltip_parts.append(["Duration: %s", [_format_duration(_duration_ms)]])
	Localization.bind_parts(_status_label, &"tooltip_text", tooltip_parts)
	_duration_label.visible = _expanded
	_update_header()


func _toggle_details() -> void:
	_expanded = not _expanded
	_details.visible = _expanded
	_duration_label.visible = _expanded and _duration_ms >= 0
	_match_scroll.visible = _expanded and _match_list.get_child_count() > 0
	_match_summary.visible = _expanded and _has_match_results
	_update_header()


func _update_header() -> void:
	CardHeader.set_disclosure(_header_button, _expanded)
	var label := _display_name(_tool_name)
	var parts: Array = [["%s", [Localization.source(label)]]]
	if not _target.is_empty():
		parts.append(["  %s", [Localization.source(_target) if _target_is_caption else _target]])
	Localization.bind_parts(_header_button, &"text", parts)
	Localization.bind_parts(_header_button, &"tooltip_text", parts + ([["\n", []], ["Duration: %s", [_format_duration(_duration_ms)]]] if _duration_ms >= 0 else []))


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
		"inspect_animation":
			return "Inspect animation"
		"inspect_editor_scene":
			return "Inspect live scene"
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
		"find_project_symbols":
			return "Find project symbols"
		"find_symbol_references":
			return "Find reference candidates"
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
	if _tool_name == "find_symbol_references":
		return str(arguments.get("symbol", ""))
	if _tool_name == "inspect_editor_scene":
		var scope := str(arguments.get("scope", "selection"))
		return "Selected nodes" if scope == "selection" else (str(arguments.get("node_path", ".")) if scope == "subtree" else "Scene hierarchy")
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
		var target := str(arguments["scene_path"])
		var focus := str(arguments.get("animation_name", arguments.get("node_path", "")))
		return target + (" :: " + focus if not focus.is_empty() else "")
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


func _set_navigation_matches(raw) -> void:
	for child in _match_list.get_children():
		_match_list.remove_child(child)
		child.queue_free()
	if typeof(raw) != TYPE_ARRAY:
		_match_scroll.hide()
		return
	for entry in raw.slice(0, 200 if _tool_name == "search_files" else 100):
		if typeof(entry) != TYPE_DICTIONARY or typeof(entry.get("filepath")) != TYPE_STRING or not Tools._is_integer_number(entry.get("line")) or not Tools._is_integer_number(entry.get("column")):
			continue
		var path: String = entry["filepath"]
		if not _safe_match_path(path) or float(entry["line"]) < 1 or float(entry["line"]) > 10000000 or float(entry["column"]) < 1 or float(entry["column"]) > 10000000:
			continue
		var line := int(entry["line"])
		var column := int(entry["column"])
		var button := Button.new()
		button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.text = "%s:%d · %s" % [path.trim_prefix("res://"), line, str(entry.get("preview", "") if _tool_name == "search_files" else entry.get("name", "")).left(128)]
		button.tooltip_text = "%s:%d:%d\n%s" % [path, line, column, str(entry.get("preview", "")).left(240)] if _tool_name == "search_files" else "%s:%d:%d\n%s · %s\n%s" % [path, line, column, str(entry.get("kind", "identifier")).left(32), str(entry.get("role", "reference_candidate")).left(32), str(entry.get("preview", "")).left(240)]
		button.pressed.connect(_request_open.bind(path, line, column))
		_match_list.add_child(button)
	_match_scroll.visible = _expanded and _match_list.get_child_count() > 0


func _request_open(path: String, line: int, column: int) -> void:
	if path.length() > 512 or not path.begins_with("res://") or not Tools._validate_path(path, false).is_empty() or not FileAccess.file_exists(path):
		return
	if _tool_name in ["search_files", "find_project_symbols", "find_symbol_references"] and (not _safe_match_path(path) or not FileAccess.file_exists(path)):
		return
	open_requested.emit(path, line, column)


func _safe_match_path(path: String) -> bool:
	if _tool_name != "search_files": return _safe_navigation_path(path)
	return path.length() <= 512 and path.begins_with("res://") and not path.to_utf8_buffer().has(0) and ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path()) == path and Tools._validate_path(path, false).is_empty()


static func _safe_navigation_path(path: String) -> bool:
	return path.length() <= 512 and path.begins_with("res://") and path.get_extension() == "gd" and ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path()) == path and Tools._validate_path(path, false).is_empty()


func _format_duration(duration_ms: int) -> String:
	if duration_ms < 1000:
		return str(duration_ms) + " ms"
	return "%.1f s" % (duration_ms / 1000.0)
