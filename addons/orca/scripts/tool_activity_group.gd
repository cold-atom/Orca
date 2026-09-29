@tool
extends PanelContainer

signal open_requested(filepath: String, line: int, column: int)

const ToolActivityCard = preload("res://addons/orca/scripts/tool_activity_card.gd")

var _header_button: Button
var _status_label: Label
var _body: VBoxContainer
var _expanded := false
var _accepting := true
var _cards: Dictionary = {}
var _tool_names: Dictionary = {}
var _targets: Dictionary = {}
var _outcomes: Dictionary = {}
var _durations: Dictionary = {}


func _ready() -> void:
	set_meta("orca_tool_group", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.075, 0.082, 0.095, 0.92)
	panel_style.border_color = Color(0.22, 0.25, 0.29, 1)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(7)
	panel_style.set_content_margin_all(6)
	add_theme_stylebox_override("panel", panel_style)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 5)
	add_child(content)
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)

	var label_font_size := 13
	var meta_font_size := 11
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		label_font_size = maxi(editor_theme.get_font_size("font_size", "Label"), 12)
		meta_font_size = maxi(label_font_size - 1, 11)
	_header_button = Button.new()
	_header_button.flat = true
	_header_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header_button.custom_minimum_size.x = 0
	_header_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_button.clip_text = true
	_header_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_button.add_theme_font_size_override("font_size", label_font_size)
	_header_button.pressed.connect(_toggle)
	header.add_child(_header_button)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", meta_font_size)
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_status_label)

	_body = VBoxContainer.new()
	_body.set_meta("orca_tool_group_body", true)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 5)
	_body.visible = false
	content.add_child(_body)
	_update_header()


func add_tool(call_id: String, tool_name: String, arguments: Dictionary):
	if not _accepting or _cards.has(call_id):
		return null
	var card = ToolActivityCard.new()
	_body.add_child(card)
	card.configure(tool_name, arguments)
	card.open_requested.connect(func(path: String, line: int, column: int): open_requested.emit(path, line, column))
	_cards[call_id] = card
	_tool_names[call_id] = tool_name
	_targets[call_id] = _target_from_arguments(arguments)
	_outcomes[call_id] = "running"
	_durations[call_id] = 0
	_update_header()
	return card


func complete_tool(call_id: String, execution: Dictionary, duration_ms: int) -> void:
	if not _cards.has(call_id):
		return
	var card = _cards[call_id]
	if is_instance_valid(card):
		card.complete(execution, duration_ms)
	_outcomes[call_id] = str(execution.get("outcome", "failed"))
	_durations[call_id] = maxi(0, duration_ms)
	_update_header()


func close_for_appends() -> void:
	_accepting = false


func can_append() -> bool:
	return _accepting


func call_count() -> int:
	return _cards.size()


func aggregate_outcome() -> String:
	if _outcomes.values().any(func(outcome): return outcome == "running"):
		return "running"
	if _outcomes.values().any(func(outcome): return outcome == "failed"):
		return "failed"
	if _outcomes.values().any(func(outcome): return outcome in ["interrupted", "cancelled", "rejected"]):
		return "interrupted"
	return "completed"


func total_duration_ms() -> int:
	var total := 0
	for duration in _durations.values():
		total += int(duration)
	return total


func get_card(call_id: String):
	return _cards.get(call_id, null)


func set_expanded(expanded: bool) -> void:
	_expanded = expanded
	if _body != null:
		_body.visible = expanded
	_update_header()


func _toggle() -> void:
	set_expanded(not _expanded)


func _update_header() -> void:
	if _header_button == null:
		return
	var count := call_count()
	var title := _group_title()
	_header_button.text = ("v" if _expanded else ">") + "  " + title
	_header_button.tooltip_text = title
	var outcome := aggregate_outcome()
	var duration := total_duration_ms()
	_status_label.text = outcome.to_upper()
	if outcome != "running":
		_status_label.text += " · " + _format_duration(duration)
	var color := Color(0.55, 0.72, 0.95)
	if outcome == "completed":
		color = Color(0.45, 0.82, 0.55)
	elif outcome == "failed":
		color = Color(0.95, 0.4, 0.4)
	elif outcome == "interrupted":
		color = Color(0.78, 0.64, 0.36)
	_status_label.add_theme_color_override("font_color", color)
	_status_label.tooltip_text = "%d call%s · %s" % [count, "" if count == 1 else "s", _format_duration(duration)]


func _group_title() -> String:
	var count := call_count()
	if count == 0:
		return "Project activity"
	var unique_names: Dictionary = {}
	for tool_name in _tool_names.values():
		unique_names[str(tool_name)] = true
	var title := "Project activity"
	if unique_names.size() == 1:
		match str(unique_names.keys()[0]):
			"read_file":
				title = "Read file" if count == 1 else "Read files"
			"list_directory":
				title = "List directory" if count == 1 else "List directories"
			"search_files":
				title = "Search project"
			"inspect_scene":
				title = "Inspect scene" if count == 1 else "Inspect scenes"
			"inspect_project_settings":
				title = "Inspect project settings"
			"get_editor_context":
				title = "Inspect editor context"
			"get_diagnostics":
				title = "Read game status and diagnostics"
			"observe_game_run":
				title = "Observe game run"
	if count == 1:
		var target := str(_targets.get(_targets.keys()[0], ""))
		if not target.is_empty():
			title += "  " + target
	return "%s · %d" % [title, count]


func _target_from_arguments(arguments: Dictionary) -> String:
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


func _format_duration(duration_ms: int) -> String:
	if duration_ms < 1000:
		return str(duration_ms) + " ms"
	return "%.1f s" % (duration_ms / 1000.0)
