@tool
extends "res://tests/editor_test_case.gd"

const Localization = preload("res://addons/orca/scripts/localization.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const CardHeader = preload("res://addons/orca/scripts/card_header.gd")
const CardFooter = preload("res://addons/orca/scripts/card_footer.gd")
const CARDS = [
	preload("res://addons/orca/scripts/change_card.gd"),
	preload("res://addons/orca/scripts/scene_change_card.gd"),
	preload("res://addons/orca/scripts/input_map_change_card.gd"),
	preload("res://addons/orca/scripts/main_scene_change_card.gd"),
	preload("res://addons/orca/scripts/project_settings_change_card.gd"),
	preload("res://addons/orca/scripts/tool_activity_card.gd"),
	preload("res://addons/orca/scripts/tool_activity_group.gd"),
]
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Control.new()
	root.add_child(host)
	var cards: Array[Control] = []
	for script in CARDS:
		var card := script.new() as Control
		host.add_child(card)
		cards.append(card)
		var title := card._status_label.get_parent().get_child(0) as Control
		title.text = "Modified  res://scripts/long_directory_name/slime.gd"
		_scale_fonts(card, 1.0)
	# All real card headers, including nested activity, must survive language,
	# font, caption and width changes without requiring card reconstruction.
	for locale in ["en", "zh_CN", "es", "ja", "ko"]:
		Localization.select_language(locale)
		for multiplier in [1.0, 1.5, 2.0]:
			for caption in ["running", "applying", "applied", "failed", "completed", "interrupted", "cancelled", "review", "applied_recovery", "applied_editor", "saved_editor", "save_observed_editor"]:
				for card in cards:
					CardHeader.set_status(card._status_label, caption, "Original receipt")
					_scale_fonts(card, multiplier)
				for width in [300, 220, 600, 300]:
					for card in cards:
						card.size = Vector2(UiMetrics.scaled(width - 36), 0) # dock/card/scrollbar budget
					for frame in 6:
						await process_frame
					for card in cards:
						_check_caption(card, "%s/%s/%s/%s" % [locale, multiplier, caption, width])
	Localization.select_language("en")
	await _test_activity_metadata(host)
	await _test_change_footer(cards[0])
	await _capture_preview(host, cards)
	host.queue_free()
	for frame in 4: await process_frame
	for failure in _failures: print("FAIL: ", failure)
	print("card_status_editor_test: PASS" if _failures.is_empty() else "card_status_editor_test: FAIL")
	quit(0 if _failures.is_empty() else 1)


func _check_caption(card: Control, context: String) -> void:
	var status := card._status_label as Label
	var header := status.get_parent() as Control
	var title := header.get_child(0) as Control
	_expect(not status.clip_text and status.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING, "outcome must not trim: " + context)
	_expect(status.get_visible_line_count() >= status.get_line_count(), "every wrapped status line must be visible: " + context)
	var natural := status.get_theme_font("font").get_string_size(status.atr(status.text), HORIZONTAL_ALIGNMENT_LEFT, -1, status.get_theme_font_size("font_size")).x + status.get_theme_stylebox("normal").get_minimum_size().x
	_expect(status.get_line_count() == 1, "ordinary badge must remain one line: " + context)
	_expect(natural <= status.size.x + 1, "caption + padding must fit in full: %s (natural %.1f, width %.1f, caption %s)" % [context, natural, status.size.x, status.atr(status.text)])
	_expect(status.position.x >= 0 and status.position.x + status.size.x <= header.size.x + 1, "status must stay inside header: " + context)
	_expect(status.position.y + status.size.y <= header.size.y + 1, "status height must remain inside card: " + context)
	_expect(not status.get_rect().intersects(title.get_rect()), "title and outcome must not overlap: " + context)
	_expect(header.get_combined_minimum_size().x == 0 and card.get_combined_minimum_size().x <= UiMetrics.scaled(300), "caption must not widen dock: " + context)
	var note := header._note as Label
	if not str(status.get_meta(CardHeader.STATUS_NOTE, "")).is_empty():
		_expect(note.visible and not note.text.is_empty(), "save/verification/recovery qualification must stay visible: " + context)
		_expect(note.get_visible_line_count() == note.get_line_count() and header.get_rect().size.y >= note.get_rect().end.y, "full qualification must fit below header: " + context)
	else:
		_expect(not note.visible, "ordinary outcomes must not retain stale qualifications: " + context)
	for button in card.find_children("*", "Button", true, false):
		var group := button.get_parent() as Control
		var footer := group.get_parent() as Control
		if footer != null and footer.get_script() == CardFooter and button.visible:
			_expect(footer.get_global_rect().grow(1).encloses(button.get_global_rect()), "native footer action must remain fully inside the card: " + context)


func _scale_fonts(node: Node, multiplier: float) -> void:
	if node is Label or node is Button:
		if not node.has_meta("base_font"):
			node.set_meta("base_font", node.get_theme_font_size("font_size"))
		node.add_theme_font_size_override("font_size", roundi(int(node.get_meta("base_font")) * multiplier))
	for child in node.get_children(): _scale_fonts(child, multiplier)


func _test_activity_metadata(host: Control) -> void:
	var group = CARDS[-1].new()
	host.add_child(group)
	var first = group.add_tool("first", "read_file", {"filepath": "res://Settings.gd"})
	var second = group.add_tool("second", "get_diagnostics", {})
	_expect(not group._duration_label.visible and not first._duration_label.visible, "running activities hide unfinished timings")
	group.complete_tool("first", {"outcome": "completed", "content": "Original evidence", "data": {}}, 38)
	group.complete_tool("second", {"outcome": "failed", "content": "Original failure", "data": {}}, 1000)
	for locale in ["en", "es", "zh_CN", "ja", "ko"]:
		Localization.select_language(locale)
		for frame in 4: await process_frame
		_expect(first._status_label.text == Localization.message("Completed") and group._status_label.text == Localization.message("Failed"), "completed badges translate live without timing text")
		_expect(not first._duration_label.visible and not group._duration_label.visible, "collapsed activities show no duration labels")
		_expect(first._header_button.tooltip_text.contains("38 ms") and first._status_label.tooltip_text.contains("38 ms"), "per-call timing remains in both header and badge tooltips")
		_expect(group._header_button.tooltip_text.contains("1.0 s") and group._status_label.tooltip_text.contains("1.0 s"), "aggregate timing remains in both group tooltips")
		_expect(first._header_button.text.contains("Settings.gd") and first._details.text == "Original evidence", "locale refresh preserves original paths and evidence")
		group.set_expanded(true)
		first._toggle_details()
		_expect(first._duration_label.visible and first._duration_label.text == Localization.message("Duration: %s") % "38 ms", "expanded activity shows localized duration separately")
		_expect(group._duration_label.visible and group._duration_label.text == Localization.message("Total tool time: %s") % "1.0 s", "expanded group identifies summed tool time")
		group.set_expanded(false)
		first._toggle_details()
	Localization.select_language("en")
	group.queue_free()
	for frame in 4: await process_frame


func _test_change_footer(card: Control) -> void:
	_scale_fonts(card, 1.0)
	card.configure({"id": "preview", "filepath": "res://scripts/Settings.gd", "existed": true, "validation": {"message": "GDScript is valid."}, "diff": {"additions": 3, "deletions": 1, "display_operations": [{"type": "add", "new_line": 3, "text": "const ACCENT := Color(\"#ff9b50\")"}]}})
	card.set_status("applied", "Applied original source")
	var footer := card._revert_button.get_parent().get_parent() as Control
	_expect(footer.get_script() == CardFooter, "change cards share the responsive footer")
	for width in [600, 220, 300, 600]:
		card.size = Vector2(UiMetrics.scaled(width - 36), 0)
		for frame in 8: await process_frame
		var navigation := footer.get_child(0) as Control
		var actions := footer.get_child(1) as Control
		_expect(not navigation.get_rect().intersects(actions.get_rect()), "footer navigation and actions stay separate at width %d" % width)
		_expect(footer.size.y >= maxf(navigation.get_rect().end.y, actions.get_rect().end.y), "footer encloses both groups at width %d" % width)
		_expect(actions.get_rect().end.x <= footer.size.x + 1, "actions remain inside the footer")
		_expect(is_equal_approx(actions.position.y, navigation.position.y) if width == 600 else true, "wide footer keeps navigation and Revert on the same row")
	var clicks := []
	card.action_requested.connect(func(id, action): clicks.append([id, action]))
	card._revert_button.pressed.emit()
	_expect(clicks == [["preview", "revert"]], "footer preserves canonical Revert action")
	_expect(card._title_label.text == "Modified · Settings.gd" and card._path_label.text == "res://scripts/Settings.gd" and card._title_label.tooltip_text == card._path_label.text, "file hierarchy preserves basename, original full path and tooltip")
	_expect(card._diff_stats_label.text == "+3  −1", "diff statistics survive outcome transitions")
	for locale in ["en", "es", "zh_CN", "ja", "ko"]:
		Localization.select_language(locale)
		for multiplier in [1.0, 2.0]:
			_scale_fonts(card, multiplier)
			card.size = Vector2(UiMetrics.scaled(220 - 36), 0)
			for frame in 8: await process_frame
			_expect(not card._validation_label.get_rect().intersects(card._diff_stats_label.get_rect()), "validation and counts use deliberate separate space at narrow larger fonts")
			_expect(card._validation_label.get_visible_line_count() == card._validation_label.get_line_count(), "complete wrapped validation remains visible")
			_expect(card.get_global_rect().grow(1).encloses(card._revert_button.get_global_rect()), "localized native action remains fully inside narrow file card")
	Localization.select_language("en")
	_scale_fonts(card, 1.0)


func _capture_preview(host: Control, cards: Array[Control]) -> void:
	var folder := OS.get_environment("ORCA_CARD_PREVIEW_DIR")
	if DisplayServer.get_name() == "headless" or folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return
	for card in cards: card.hide()
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.11, 0.115, 0.12)
	host.add_child(backdrop)
	var gallery := VBoxContainer.new()
	gallery.position = UiMetrics.scaled_vector(Vector2(30, 60))
	gallery.size.x = UiMetrics.scaled(340)
	gallery.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	host.add_child(gallery)
	host.remove_child(cards[0])
	gallery.add_child(cards[0])
	cards[0].show()
	var activity = CARDS[-2].new()
	gallery.add_child(activity)
	activity.configure("run_current_scene", {})
	activity.complete({"outcome": "failed", "content": "Original run evidence", "data": {}}, 4)
	var group = CARDS[-1].new()
	gallery.add_child(group)
	group.add_tool("preview", "get_editor_context", {})
	group.complete_tool("preview", {"outcome": "completed", "content": "Original editor context", "data": {}}, 38)
	var scene = CARDS[1].new()
	gallery.add_child(scene)
	scene.configure({"id": "scene-preview", "filepath": "res://Main.tscn", "scene_summary": {"operation": "attach_script"}, "validation": {"message": "Passed"}})
	scene.set_status("applied_editor", "Editor-only application; disk unchanged.")
	scene._find_details(scene).hide()
	for frame in 12: await process_frame
	backdrop.position = gallery.position
	backdrop.size = gallery.size
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().get_region(Rect2i(gallery.get_global_rect())).save_png(folder.path_join("card-gallery.png"))
	group.hide()
	scene.hide()
	activity.hide()
	_scale_fonts(gallery, 2.0)
	gallery.size.x = UiMetrics.scaled(220)
	for frame in 12: await process_frame
	backdrop.size = gallery.size
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().get_region(Rect2i(gallery.get_global_rect())).save_png(folder.path_join("card-narrow-2x.png"))


func _expect(condition: bool, message: String) -> void:
	if not condition and _failures.size() < 30: _failures.append(message)
