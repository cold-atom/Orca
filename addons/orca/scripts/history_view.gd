@tool
extends PanelContainer

signal done_requested
signal session_requested(session_id: String)
signal delete_requested(session_id: String)
signal delete_all_requested
signal new_session_requested

var _list: VBoxContainer
var _empty_label: Label
var _delete_dialog: ConfirmationDialog
var _delete_session_id := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_ui()


func set_sessions(sessions: Array, current_session_id: String) -> void:
	for child in _list.get_children():
		child.queue_free()
	_empty_label.visible = sessions.is_empty()
	for summary in sessions:
		if typeof(summary) == TYPE_DICTIONARY:
			_add_session_row(summary, current_session_id)


func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.075, 0.085, 1)
	add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	content.add_child(header)
	var title := Label.new()
	title.text = "HISTORY"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var new_button := Button.new()
	new_button.text = "New Chat"
	new_button.tooltip_text = "Save the current session and start a new conversation"
	new_button.pressed.connect(func(): new_session_requested.emit())
	header.add_child(new_button)
	var done_button := Button.new()
	done_button.text = "Done"
	done_button.pressed.connect(func(): done_requested.emit())
	header.add_child(done_button)

	var description := Label.new()
	description.text = "Conversations are stored locally for this project."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", Color(0.58, 0.61, 0.66))
	content.add_child(description)

	var toolbar := HBoxContainer.new()
	content.add_child(toolbar)
	var count_hint := Label.new()
	count_hint.text = "Up to 50 recent sessions"
	count_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	count_hint.add_theme_color_override("font_color", Color(0.48, 0.51, 0.56))
	toolbar.add_child(count_hint)
	var clear_button := Button.new()
	clear_button.text = "Delete All"
	clear_button.flat = true
	clear_button.pressed.connect(_confirm_delete_all)
	toolbar.add_child(clear_button)

	var separator := HSeparator.new()
	content.add_child(separator)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_list)
	_empty_label = Label.new()
	_empty_label.text = "No saved conversations yet."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_empty_label.add_theme_color_override("font_color", Color(0.58, 0.61, 0.66))
	content.add_child(_empty_label)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.confirmed.connect(_on_delete_confirmed)
	add_child(_delete_dialog)


func _add_session_row(summary: Dictionary, current_session_id: String) -> void:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.095, 0.105, 0.12, 1)
	style.border_color = Color(0.22, 0.24, 0.27, 1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(9)
	panel.add_theme_stylebox_override("panel", style)
	_list.add_child(panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	panel.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var title := Label.new()
	title.text = str(summary.get("title", "Conversation"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	heading.add_child(title)
	var time_label := Label.new()
	time_label.text = _format_timestamp(float(summary.get("updated_at", 0.0)))
	time_label.add_theme_color_override("font_color", Color(0.5, 0.53, 0.58))
	heading.add_child(time_label)

	var preview := Label.new()
	preview.text = str(summary.get("last_prompt", "No prompt preview"))
	preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview.max_lines_visible = 2
	preview.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	preview.add_theme_color_override("font_color", Color(0.7, 0.72, 0.76))
	content.add_child(preview)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 7)
	content.add_child(footer)
	var mode_name := "Work" if int(summary.get("mode", 1)) == 1 else "Plan"
	var detail := Label.new()
	detail.text = "%s · %s" % [mode_name, str(summary.get("model", "Unknown model"))]
	if int(summary.get("changed_file_count", 0)) > 0:
		detail.text += " · %d changed" % int(summary["changed_file_count"])
	if bool(summary.get("cost_available", false)):
		detail.text += " · $%.4f" % float(summary.get("cost_usd", 0.0))
	if not bool(summary.get("clean", true)) or not bool(summary.get("resumable", true)):
		detail.text += " · View only"
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.add_theme_color_override("font_color", Color(0.5, 0.6, 0.67))
	footer.add_child(detail)
	var session_id := str(summary.get("id", ""))
	var delete_button := Button.new()
	delete_button.text = "Delete"
	delete_button.flat = true
	delete_button.pressed.connect(_confirm_delete.bind(session_id, title.text))
	footer.add_child(delete_button)
	var open_button := Button.new()
	open_button.text = "Current" if session_id == current_session_id else "Open"
	open_button.disabled = session_id == current_session_id
	open_button.pressed.connect(func(): session_requested.emit(session_id))
	footer.add_child(open_button)


func _confirm_delete(session_id: String, title: String) -> void:
	_delete_session_id = session_id
	_delete_dialog.title = "Delete Conversation"
	_delete_dialog.dialog_text = "Delete \"%s\"? This cannot be undone." % title
	_delete_dialog.ok_button_text = "Delete"
	_delete_dialog.popup_centered()


func _confirm_delete_all() -> void:
	_delete_session_id = "*"
	_delete_dialog.title = "Delete All Conversations"
	_delete_dialog.dialog_text = "Delete all saved Orca conversations for this project? This cannot be undone."
	_delete_dialog.ok_button_text = "Delete All"
	_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _delete_session_id == "*":
		delete_all_requested.emit()
	elif not _delete_session_id.is_empty():
		delete_requested.emit(_delete_session_id)
	_delete_session_id = ""


func _format_timestamp(unix_time: float) -> String:
	if unix_time <= 0.0:
		return "Unknown"
	var value := Time.get_datetime_dict_from_unix_time(int(unix_time))
	return "%04d-%02d-%02d %02d:%02d" % [value.year, value.month, value.day, value.hour, value.minute]
