@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")

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


func _enter_tree() -> void:
	Localization.attach(self)


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
	_title_label.clip_text = true
	_title_label.add_theme_font_size_override("font_size", label_font_size)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(_title_label)
	_status_label = Label.new()
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.custom_minimum_size.x = UiMetrics.scaled(60)
	_status_label.add_theme_font_size_override("font_size", meta_font_size)
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_validation_label.add_theme_font_size_override("font_size", meta_font_size)
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	_validation_label.visible = false
	content.add_child(_validation_label)

	_diff_label = RichTextLabel.new()
	_diff_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_diff_label.bbcode_enabled = true
	_diff_label.fit_content = false
	_diff_label.selection_enabled = true
	_diff_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_diff_label.custom_minimum_size = Vector2(0, UiMetrics.scaled(70))
	content.add_child(_diff_label)

	var navigation := HFlowContainer.new()
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

	var actions := HFlowContainer.new()
	actions.alignment = FlowContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	content.add_child(actions)

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
	_revert_button.pressed.connect(func(): action_requested.emit(_proposal.get("id", ""), "inspect_recovery" if _proposal.get("status") in ["interrupted", "recovery_conflict", "apply_recovery_required", "revert_recovery_required"] else "revert"))
	actions.add_child(_revert_button)


func configure(proposal: Dictionary) -> void:
	_proposal = proposal
	var diff: Dictionary = proposal.get("diff", {})
	Localization.bind(_title_label, &"text", "Modified  %s", [str(proposal.get("filepath", ""))])
	_status_label.text = "+%d  -%d" % [diff.get("additions", 0), diff.get("deletions", 0)]
	_status_label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.68))
	var validation: Dictionary = proposal.get("validation", {})
	_open_button.disabled = not proposal.get("existed", false)
	if not validation.is_empty():
		Localization.bind(_validation_label, &"text", "Validated: %s", [Localization.source(str(validation.get("message", "Passed")))])
		_validation_label.visible = true
	_diff_label.text = _format_unified_diff(diff.get("display_operations", []))
	_diff_label.visible = not diff.get("display_operations", []).is_empty()
	_apply_button.visible = not proposal.get("_auto_apply", false)
	_reject_button.visible = not proposal.get("_auto_apply", false)
	if proposal.get("_auto_apply", false):
		_status_label.text = "APPLYING"


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	_status_label.text = status.replace("_", " ").to_upper()
	_status_label.tooltip_text = message
	_apply_button.visible = false
	_reject_button.visible = false
	var can_check := _proposal.has("_checkpoint_id") and status in ["interrupted", "recovery_conflict", "apply_recovery_required", "revert_recovery_required"]
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed"] or can_check
	_revert_button.text = "Check recovery" if can_check else "Revert"
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


func set_revert_available(available: bool) -> void:
	_revert_button.disabled = not available
	_revert_button.tooltip_text = "Revert rechecks current file state." if available else "Revert is available in idle Work mode."


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
	if _proposal.get("_lazy_diff", false):
		_proposal["diff"] = preload("res://addons/orca/scripts/diff_utils.gd").create_diff(str(_proposal.get("old_content", "")), str(_proposal.get("new_content", "")))
		_proposal["_lazy_diff"] = false
		_diff_label.text = _format_unified_diff(_proposal["diff"].get("display_operations", []))
		_diff_label.visible = not _proposal["diff"].get("display_operations", []).is_empty()
	var dialog := Window.new()
	Localization.bind(dialog, &"title", "Review Changes · %s", [str(_proposal.get("filepath", ""))])
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
	var panes := SplitContainer.new()
	panes.vertical = dialog.size.x < UiMetrics.scaled(800)
	panes.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(panes)
	dialog.size_changed.connect(func():
		var vertical := dialog.size.x < UiMetrics.scaled(800)
		if panes.vertical != vertical:
			panes.vertical = vertical
			panes.split_offsets = PackedInt32Array([0])
	)
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
	if _proposal.get("status", "pending") == "pending" and not _proposal.get("_auto_apply", false):
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
	pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pane.custom_minimum_size.x = maxf(0, minf(UiMetrics.scaled(240), parent.get_window().size.x - UiMetrics.scaled(20)))
	pane.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	parent.add_child(pane)
	var label := Label.new()
	label.text = title
	pane.add_child(label)
	var editor := CodeEdit.new()
	editor.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	if Engine.is_editor_hint():
		editor.theme = EditorInterface.get_editor_theme()
		if str(_proposal.get("filepath", "")).get_extension().to_lower() == "gd":
			editor.syntax_highlighter = GDScriptSyntaxHighlighter.new()
	editor.text = content
	editor.editable = false
	editor.gutters_draw_line_numbers = true
	editor.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	editor.scroll_past_end_of_file = false
	editor.minimap_draw = true
	editor.minimap_width = UiMetrics.scaled_int(72)
	editor.add_theme_constant_override("minimap_char_width", UiMetrics.scaled_int(1))
	# Godot's native change markers use a fixed 3 px row (2 px ink + 1 px gap).
	editor.add_theme_constant_override("minimap_char_height", 2)
	editor.add_theme_constant_override("minimap_line_spacing", 1)
	# Keep native syntax colors, but restore the charcoal review surface in dark themes.
	var normal := editor.get_theme_stylebox("normal").duplicate() as StyleBoxFlat
	if normal != null:
		if normal.bg_color.get_luminance() < 0.5:
			normal.bg_color = Color("#1a1a1a")
		normal.set_corner_radius_all(UiMetrics.scaled_int(6))
		normal.set_border_width_all(UiMetrics.scaled_int(1))
		normal.border_color = editor.get_theme_color("font_color") * Color(1, 1, 1, 0.06)
		normal.set_content_margin_all(UiMetrics.scaled(8))
		editor.add_theme_stylebox_override("normal", normal)
		editor.add_theme_stylebox_override("read_only", normal)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor.resized.connect(_sync_minimap_width.bind(editor))
	pane.add_child(editor)
	return editor


func _sync_minimap_width(editor: CodeEdit) -> void:
	# Leave most of each pane for readable code, including after splitter drags.
	editor.minimap_width = roundi(clampf(editor.size.x * 0.16, UiMetrics.scaled(44), UiMetrics.scaled(88)))


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
