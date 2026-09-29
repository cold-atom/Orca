@tool
extends PanelContainer

const MAX_VISIBLE_HEIGHT := 160.0
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

var _header_button: Button
var _scroll: ScrollContainer
var _list: VBoxContainer
var _tasks: Array = []
var _expanded := true


func _ready() -> void:
	set_meta("orca_task_list", true)
	visible = false
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.075, 0.082, 0.095, 0.96)
	style.border_color = Color(0.23, 0.27, 0.32, 1)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(7))
	style.set_content_margin_all(UiMetrics.scaled(6))
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	add_child(content)
	var font_size := 13
	if Engine.is_editor_hint():
		font_size = maxi(EditorInterface.get_editor_theme().get_font_size("font_size", "Label"), 12)
	_header_button = Button.new()
	_header_button.flat = true
	_header_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header_button.custom_minimum_size.x = 0
	_header_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_button.clip_text = true
	_header_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_button.add_theme_font_size_override("font_size", font_size)
	_header_button.pressed.connect(func(): set_expanded(not _expanded))
	content.add_child(_header_button)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", UiMetrics.scaled_int(3))
	_scroll.add_child(_list)
	_update_header()


func set_tasks(tasks: Array) -> void:
	_tasks = tasks.duplicate(true)
	_rebuild()
	visible = not _tasks.is_empty()


func get_tasks() -> Array:
	return _tasks.duplicate(true)


func clear() -> void:
	set_tasks([])


func set_expanded(expanded: bool) -> void:
	_expanded = expanded
	if _scroll != null:
		_scroll.visible = expanded and not _tasks.is_empty()
	_update_header()


func is_expanded() -> bool:
	return _expanded


func _rebuild() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	for task in _tasks:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
		var status := str(task.get("status", "pending"))
		var marker := Label.new()
		marker.text = _status_marker(status)
		marker.tooltip_text = status.replace("_", " ").capitalize()
		marker.add_theme_color_override("font_color", _status_color(status))
		row.add_child(marker)
		var text := Label.new()
		text.text = str(task.get("content", ""))
		text.tooltip_text = text.text
		text.custom_minimum_size.x = 0
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_theme_color_override("font_color", Color(0.72, 0.74, 0.78) if status in ["completed", "cancelled"] else Color(0.86, 0.88, 0.92))
		row.add_child(text)
		_list.add_child(row)
	_scroll.custom_minimum_size.y = minf(
		UiMetrics.scaled(MAX_VISIBLE_HEIGHT),
		maxf(UiMetrics.scaled(28), _list.get_combined_minimum_size().y)
	)
	_scroll.visible = _expanded and not _tasks.is_empty()
	_update_header()


func _update_header() -> void:
	if _header_button == null:
		return
	var completed := 0
	var active := ""
	for task in _tasks:
		if task.get("status") == "completed":
			completed += 1
		elif task.get("status") == "in_progress":
			active = str(task.get("content", ""))
	var title := "Tasks %d/%d" % [completed, _tasks.size()]
	if not active.is_empty():
		title += "  " + active
	_header_button.text = ("v" if _expanded else ">") + "  " + title
	_header_button.tooltip_text = title


func _status_marker(status: String) -> String:
	match status:
		"in_progress":
			return ">"
		"completed":
			return "[x]"
		"blocked":
			return "!"
		"cancelled":
			return "-"
		_:
			return "[ ]"


func _status_color(status: String) -> Color:
	match status:
		"in_progress":
			return Color(0.95, 0.7, 0.35)
		"completed":
			return Color(0.45, 0.82, 0.55)
		"blocked":
			return Color(0.95, 0.4, 0.4)
		"cancelled":
			return Color(0.55, 0.57, 0.62)
		_:
			return Color(0.58, 0.66, 0.76)
