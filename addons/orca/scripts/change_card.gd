@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

signal action_requested(change_id: String, action: String)
signal open_requested(filepath: String, line: int, column: int)

var _proposal: Dictionary
var _title_label: Label
var _status_label: Label
var _validation_label: Label
var _diff_label: RichTextLabel
var _apply_button: Button
var _reject_button: Button
var _revert_button: Button
var _open_button: Button
var _syncing_scroll := false
var _diff_font_size := 12


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.085, 0.095, 0.11, 1)
	panel_style.border_color = Color(0.26, 0.3, 0.35, 1)
	panel_style.set_border_width_all(UiMetrics.scaled_int(1))
	panel_style.set_corner_radius_all(UiMetrics.scaled_int(7))
	panel_style.set_content_margin_all(UiMetrics.scaled(8))
	add_theme_stylebox_override("panel", panel_style)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	add_child(content)
	var label_font_size := 13
	var meta_font_size := 11
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		label_font_size = maxi(editor_theme.get_font_size("font_size", "Label"), 12)
		meta_font_size = maxi(label_font_size - 1, 11)
		_diff_font_size = maxi(editor_theme.get_font_size("font_size", "TextEdit"), 12)

	var header := HBoxContainer.new()
	content.add_child(header)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", label_font_size)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_title_label)
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", meta_font_size)
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.add_theme_font_size_override("font_size", meta_font_size)
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	_validation_label.visible = false
	content.add_child(_validation_label)

	_diff_label = RichTextLabel.new()
	_diff_label.bbcode_enabled = true
	_diff_label.fit_content = false
	_diff_label.selection_enabled = true
	_diff_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_diff_label.custom_minimum_size = Vector2(0, UiMetrics.scaled(70))
	content.add_child(_diff_label)

	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	content.add_child(navigation)

	var expand_button := Button.new()
	expand_button.text = "Expand Diff"
	expand_button.flat = true
	expand_button.add_theme_font_size_override("font_size", label_font_size)
	expand_button.pressed.connect(_show_expanded_diff)
	navigation.add_child(expand_button)
	_open_button = Button.new()
	_open_button.text = "Open File"
	_open_button.flat = true
	_open_button.add_theme_font_size_override("font_size", label_font_size)
	_open_button.pressed.connect(_open_changed_file)
	navigation.add_child(_open_button)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	content.add_child(actions)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	_reject_button = Button.new()
	_reject_button.text = "Reject"
	_reject_button.add_theme_font_size_override("font_size", label_font_size)
	_reject_button.pressed.connect(func(): action_requested.emit(_proposal.get("id", ""), "reject"))
	actions.add_child(_reject_button)

	_apply_button = Button.new()
	_apply_button.text = "Apply"
	_apply_button.add_theme_font_size_override("font_size", label_font_size)
	_apply_button.pressed.connect(func(): action_requested.emit(_proposal.get("id", ""), "apply"))
	actions.add_child(_apply_button)

	_revert_button = Button.new()
	_revert_button.text = "Revert"
	_revert_button.add_theme_font_size_override("font_size", label_font_size)
	_revert_button.visible = false
	_revert_button.pressed.connect(func(): action_requested.emit(_proposal.get("id", ""), "revert"))
	actions.add_child(_revert_button)


func configure(proposal: Dictionary) -> void:
	_proposal = proposal
	var diff: Dictionary = proposal.get("diff", {})
	_title_label.text = "Modified  " + str(proposal.get("filepath", ""))
	_status_label.text = "+%d  -%d" % [diff.get("additions", 0), diff.get("deletions", 0)]
	_status_label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.68))
	var validation: Dictionary = proposal.get("validation", {})
	_open_button.disabled = not proposal.get("existed", false)
	if not validation.is_empty():
		_validation_label.text = "Validated: " + str(validation.get("message", "Passed"))
		_validation_label.visible = true
	_diff_label.text = _format_unified_diff(diff.get("display_operations", []))


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	_status_label.text = status.replace("_", " ").to_upper()
	_status_label.tooltip_text = message
	_apply_button.visible = false
	_reject_button.visible = false
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed"]
	_open_button.disabled = not _proposal.get("existed", false) and status not in ["applied", "applied_recovery", "revert_failed"]
	match status:
		"applied":
			_status_label.add_theme_color_override("font_color", Color(0.45, 0.82, 0.55))
		"applied_recovery":
			_status_label.add_theme_color_override("font_color", Color(0.95, 0.68, 0.28))
		"rejected", "reverted":
			_status_label.add_theme_color_override("font_color", Color(0.62, 0.65, 0.7))
		_:
			_status_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))


func _format_unified_diff(operations: Array) -> String:
	var lines := PackedStringArray()
	var shown := mini(operations.size(), 180)
	for index in range(shown):
		var operation: Dictionary = operations[index]
		var type: String = operation.get("type", "context")
		if type == "separator":
			lines.append("[color=#78808c]      ...[/color]")
			continue
		var old_number := "" if operation.get("old_line", 0) == 0 else str(operation["old_line"])
		var new_number := "" if operation.get("new_line", 0) == 0 else str(operation["new_line"])
		var marker := " "
		var color := "#aeb5bf"
		var background := "#00000000"
		if type == "add":
			marker = "+"
			color = "#b7e4c1"
			background = "#173d28"
		elif type == "remove":
			marker = "-"
			color = "#f2b8b5"
			background = "#492126"
		var text := _escape_bbcode(str(operation.get("text", "")))
		lines.append("[bgcolor=%s][color=%s][font_size=%d]%4s %4s %s %s[/font_size][/color][/bgcolor]" % [background, color, _diff_font_size, old_number, new_number, marker, text])
	if operations.size() > shown:
		lines.append("[color=#78808c]... %d more diff lines. Use Expand Diff to view the full files.[/color]" % (operations.size() - shown))
	return "\n".join(lines)


func _show_expanded_diff() -> void:
	var dialog := Window.new()
	dialog.title = "Review Changes · " + str(_proposal.get("filepath", ""))
	var available := get_window().size
	var maximum := Vector2i(maxi(1, int(available.x * 0.9)), maxi(1, int(available.y * 0.9)))
	dialog.min_size = Vector2i(
		mini(UiMetrics.scaled_int(760), maximum.x),
		mini(UiMetrics.scaled_int(480), maximum.y)
	)
	dialog.size = Vector2i(
		mini(UiMetrics.scaled_int(1050), maximum.x),
		mini(UiMetrics.scaled_int(700), maximum.y)
	)
	dialog.transient = true
	dialog.exclusive = true
	dialog.close_requested.connect(func(): _dismiss_expanded_diff(dialog))
	add_child(dialog)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_top", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_right", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(10))
	dialog.add_child(margin)
	var layout := VBoxContainer.new()
	margin.add_child(layout)
	var panes: SplitContainer
	if dialog.size.x >= UiMetrics.scaled(800):
		panes = HSplitContainer.new()
	else:
		panes = VSplitContainer.new()
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(panes)
	var old_edit := _create_code_pane(panes, "Previous", str(_proposal.get("old_content", "")))
	var new_edit := _create_code_pane(panes, "Proposed", str(_proposal.get("new_content", "")))
	_highlight_changed_lines(old_edit, new_edit)
	_sync_scrollbars(old_edit, new_edit)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	layout.add_child(actions)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func(): _dismiss_expanded_diff(dialog))
	actions.add_child(close_button)
	if _proposal.get("status", "pending") == "pending":
		var reject_button := Button.new()
		reject_button.text = "Reject"
		reject_button.pressed.connect(func():
			_dismiss_expanded_diff(dialog)
			action_requested.emit(_proposal.get("id", ""), "reject")
		)
		actions.add_child(reject_button)
		var apply_button := Button.new()
		apply_button.text = "Apply"
		apply_button.pressed.connect(func():
			_dismiss_expanded_diff(dialog)
			action_requested.emit(_proposal.get("id", ""), "apply")
		)
		actions.add_child(apply_button)
	dialog.popup_centered()


func _dismiss_expanded_diff(dialog: Window) -> void:
	dialog.hide()
	dialog.queue_free()


func _open_changed_file() -> void:
	var line := 1
	for operation in _proposal.get("diff", {}).get("operations", []):
		if operation.get("type") == "add" and operation.get("new_line", 0) > 0:
			line = operation["new_line"]
			break
		if operation.get("type") == "remove" and operation.get("old_line", 0) > 0:
			line = operation["old_line"]
			break
	open_requested.emit(str(_proposal.get("filepath", "")), line, 1)


func _create_code_pane(parent: Control, title: String, content: String) -> CodeEdit:
	var pane := VBoxContainer.new()
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(pane)
	var label := Label.new()
	label.text = title
	pane.add_child(label)
	var editor := CodeEdit.new()
	editor.text = content
	editor.editable = false
	editor.gutters_draw_line_numbers = true
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.add_child(editor)
	return editor


func _highlight_changed_lines(old_edit: CodeEdit, new_edit: CodeEdit) -> void:
	var operations: Array = _proposal.get("diff", {}).get("operations", [])
	for operation in operations:
		var old_line := int(operation.get("old_line", 0))
		var new_line := int(operation.get("new_line", 0))
		if operation.get("type") == "remove" and old_line > 0 and old_line <= old_edit.get_line_count():
			old_edit.set_line_background_color(old_line - 1, Color(0.29, 0.13, 0.15, 0.85))
		elif operation.get("type") == "add" and new_line > 0 and new_line <= new_edit.get_line_count():
			new_edit.set_line_background_color(new_line - 1, Color(0.09, 0.24, 0.15, 0.85))


func _sync_scrollbars(old_edit: CodeEdit, new_edit: CodeEdit) -> void:
	old_edit.get_v_scroll_bar().value_changed.connect(func(value: float):
		if _syncing_scroll:
			return
		_syncing_scroll = true
		new_edit.scroll_vertical = value
		_syncing_scroll = false
	)
	new_edit.get_v_scroll_bar().value_changed.connect(func(value: float):
		if _syncing_scroll:
			return
		_syncing_scroll = true
		old_edit.scroll_vertical = value
		_syncing_scroll = false
	)


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "\u0001").replace("]", "\u0002").replace("\u0001", "[lb]").replace("\u0002", "[rb]")
