@tool
extends Container

## Title + outcome badge, with an optional visible qualification underneath.
## Layout measures shaped text (including fallback fonts) and badge padding.
## Captions never determine the dock's minimum width or split inside a word.
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const STATUS_NOTE := &"orca_status_note"
const STATUS_CAPTION := &"orca_status_caption"
const COMPACT_CAPTION := &"orca_status_compact_caption"
var _height := 0.0
var _note: Label


func create_status_badge() -> Label:
	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var font_size := 12
	if Engine.is_editor_hint():
		font_size = maxi(EditorInterface.get_editor_theme().get_font_size("font_size", "Label") - 1, 11)
	status.add_theme_font_size_override("font_size", font_size)
	_style_badge(status, Color(0.67, 0.7, 0.76))
	add_child(status)
	_note = Label.new()
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.add_theme_font_size_override("font_size", font_size)
	_note.add_theme_color_override("font_color", Color(0.67, 0.7, 0.76))
	_note.hide()
	add_child(_note)
	return status


static func set_status(label: Label, outcome: String, message := "") -> void:
	# Presentation only: callers retain canonical runtime status/permissions.
	var captions := {
		"running": ["Running", ""], "completed": ["Completed", ""],
		"failed": ["Failed", ""], "applying": ["Applying", ""],
		"applied": ["Applied", ""], "rejected": ["Rejected", ""],
		"reverted": ["Reverted", ""], "interrupted": ["Interrupted", ""],
		"cancelled": ["Cancelled", ""], "review": ["Review", ""],
		"trust_review": ["Review", "Script trust review."],
		"applied_recovery": ["Applied", "Check recovery before further changes."],
		"reverted_recovery": ["Reverted", "Check recovery before further changes."],
		"revert_failed": ["Failed", "Revert failed."],
		"recovery_conflict": ["Conflict", "Recovery conflict; check recovery."],
		"apply_recovery_required": ["Recovery", "Check recovery after applying."],
		"revert_recovery_required": ["Recovery", "Check recovery after reverting."],
		"applied_editor": ["Save pending", "Applied in editor; save the scene before running."],
		"saved_editor": ["Saved", "Not verified."],
		"save_observed_editor": ["Save observed", "Save observed; not verified."],
		"undone_editor": ["Undone", "Undone in editor."],
		"reverted_editor": ["Save pending", "Reverted in editor; save the scene before running."],
		"editor_changed": ["Changed", "Editor state changed."],
	}
	var caption: Array = captions.get(outcome, [outcome.replace("_", " ").capitalize(), ""])
	Localization.bind(label, &"text", str(caption[0]))
	label.set_meta(STATUS_CAPTION, str(caption[0]))
	var compact_captions := {"applied_editor": "Unsaved", "reverted_editor": "Unsaved", "save_observed_editor": "Saved", "interrupted": "Stopped"}
	label.set_meta(COMPACT_CAPTION, str(compact_captions.get(outcome, "")))
	label.set_meta(STATUS_NOTE, str(caption[1]))
	var tooltip: Array = [["%s", [Localization.source(str(caption[0]))]]]
	if not str(caption[1]).is_empty():
		tooltip.append(["\n%s", [Localization.source(str(caption[1]))]])
	if not message.is_empty():
		tooltip.append(["\n%s", [message]]) # Original receipt/evidence stays untranslated.
	Localization.bind_parts(label, &"tooltip_text", tooltip)
	var color := Color(0.67, 0.7, 0.76)
	if outcome in ["running", "applying", "review"]:
		color = Color(0.55, 0.72, 0.95)
	elif outcome in ["completed", "applied", "saved_editor"]:
		color = Color(0.45, 0.82, 0.55)
	elif outcome in ["failed", "revert_failed", "recovery_conflict", "editor_changed"]:
		color = Color(0.95, 0.4, 0.4)
	elif outcome in ["trust_review", "applied_recovery", "reverted_recovery", "apply_recovery_required", "revert_recovery_required", "applied_editor", "save_observed_editor", "reverted_editor", "interrupted"]:
		color = Color(0.87, 0.7, 0.4)
	_style_badge(label, color)
	label.get_parent().queue_sort()


static func _style_badge(label: Label, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color, 0.09)
	style.border_color = Color(color, 0.18)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(4))
	style.content_margin_left = UiMetrics.scaled(7)
	style.content_margin_right = UiMetrics.scaled(7)
	style.content_margin_top = UiMetrics.scaled(2)
	style.content_margin_bottom = UiMetrics.scaled(2)
	label.add_theme_stylebox_override("normal", style)
	label.add_theme_color_override("font_color", color)


static func set_disclosure(button: Button, expanded: bool) -> void:
	if Engine.is_editor_hint():
		button.icon = EditorInterface.get_editor_theme().get_icon("GuiTreeArrowDown" if expanded else "GuiTreeArrowRight", "EditorIcons")
	else:
		button.icon = button.get_theme_icon("arrow" if expanded else "arrow_collapsed", "Tree")
	button.add_theme_constant_override("h_separation", UiMetrics.scaled_int(6))


func _get_minimum_size() -> Vector2:
	return Vector2(0, _height)


func _notification(what: int) -> void:
	if what in [NOTIFICATION_THEME_CHANGED, NOTIFICATION_TRANSLATION_CHANGED]:
		queue_sort()
	if what != NOTIFICATION_SORT_CHILDREN or get_child_count() < 2:
		return
	var title := get_child(0) as Control
	var status := get_child(1) as Label
	if title == null or status == null:
		return
	var gap := UiMetrics.scaled(8)
	var width := maxf(1, size.x)
	var caption_source := str(status.get_meta(STATUS_CAPTION, ""))
	var compact_source := str(status.get_meta(COMPACT_CAPTION, ""))
	if not caption_source.is_empty():
		var chosen := compact_source if not compact_source.is_empty() and _caption_width(status, Localization.message(caption_source)) > width else caption_source
		if status.text != Localization.message(chosen):
			Localization.bind(status, &"text", chosen)
	var caption_width := _caption_width(status, status.atr(status.text))
	# Preserve the font and a complete word before spending scarce space on padding.
	var style := status.get_theme_stylebox("normal") as StyleBoxFlat
	if style != null:
		# Evaluate against normal padding so resize cannot alternate compact/full insets.
		var normal_width := caption_width - style.get_minimum_size().x + UiMetrics.scaled(14)
		var padding := UiMetrics.scaled(2) if normal_width > width else UiMetrics.scaled(7)
		if style.content_margin_left != padding:
			style.content_margin_left = padding
			style.content_margin_right = padding
			caption_width = _caption_width(status, status.atr(status.text))
	var title_reserve := maxf(UiMetrics.scaled(96), title.get_theme_font_size("font_size") * 8.0)
	var stacked := caption_width + gap + title_reserve > width
	var status_width := minf(width, caption_width)
	var title_height := title.get_combined_minimum_size().y
	# Label updates wrapped height after receiving its actual width. Its minimum
	# size notification schedules the next sort, including live language changes.
	var status_height := status.get_combined_minimum_size().y
	var row_gap := UiMetrics.scaled(4)
	var height := title_height + row_gap + status_height if stacked else maxf(title_height, status_height)
	fit_child_in_rect(title, Rect2(0, 0, width if stacked else maxf(0, width - status_width - gap), title_height if stacked else height))
	fit_child_in_rect(status, Rect2(0 if stacked else width - status_width, title_height + row_gap if stacked else (height - status_height) / 2, status_width, status_height))
	if _note != null:
		var note_source := str(status.get_meta(STATUS_NOTE, ""))
		if _note.get_meta("source", "") != note_source:
			_note.set_meta("source", note_source)
			Localization.bind(_note, &"text", note_source)
		_note.visible = not note_source.is_empty()
		if _note.visible:
			if _note.get_theme_font_size("font_size") != status.get_theme_font_size("font_size"):
				_note.add_theme_font_size_override("font_size", status.get_theme_font_size("font_size"))
			var note_height := _note.get_combined_minimum_size().y
			fit_child_in_rect(_note, Rect2(0, height + row_gap, width, note_height))
			height += row_gap + note_height
	if not is_equal_approx(height, _height):
		_height = height
		update_minimum_size()


func _caption_width(status: Label, caption: String) -> float:
	var font := status.get_theme_font("font")
	var font_size := status.get_theme_font_size("font_size")
	var shaped := TextLine.new()
	shaped.add_string(caption, font, font_size, status.language)
	# Reserve conservatively for native Label layout as well as shaped fallback.
	var text_width := maxf(shaped.get_size().x, font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	return ceilf(text_width + status.get_theme_stylebox("normal").get_minimum_size().x) + 2
