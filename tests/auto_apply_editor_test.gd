@tool
extends "res://tests/editor_test_case.gd"

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Component = preload("res://tests/auto_apply_test.gd")

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	var fixture_storage := ""
	func _refresh_model_metadata() -> void: pass
	func _restore_active_session() -> void:
		session_store = Store.new(fixture_storage)
		_session = session_store.create_session(agent_controller.get_mode(), "openai", "fixture")

var failures := PackedStringArray()
var originals := {}
var settings: EditorSettings
var view
var path := ""
var storage := ""

func _init() -> void: call_deferred("_run")

func _exit_tree() -> void:
	_restore_preferences()

func _restore_preferences() -> void:
	if settings == null:
		return
	for key in originals:
		if originals[key]["exists"]: settings.set_setting(key, originals[key]["value"])
		else: settings.erase(key)

func check(value: bool, message: String) -> void:
	if not value: failures.append(message)

func _run() -> void:
	check(Engine.is_editor_hint(), "auto apply editor fixture requires the real editor")
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	await create_timer(0.5).timeout
	root.size = Vector2i(Metrics.scaled_int(1200), Metrics.scaled_int(900))
	settings = EditorInterface.get_editor_settings()
	for key in [Config.SETTING_PROVIDER, "orca/providers/openai/api_key", "orca/providers/openai/model"]:
		originals[key] = {"exists": settings.has_setting(key), "value": settings.get_setting(key) if settings.has_setting(key) else null}
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	var ui_only := OS.get_cmdline_user_args().has("--ui-only")
	storage = "user://orca_auto_apply_editor_test_%d" % Time.get_ticks_usec()
	if not ui_only:
		path = "res://tests/auto_apply_editor_fixture_%d.gd" % Time.get_ticks_usec()
		_put(Component.OLD)
	view = ChatScene.instantiate()
	view.set_script(FixtureChat)
	view.fixture_storage = storage
	root.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	view.size = Metrics.scaled_vector(Vector2(300, 850))
	view.size.y = minf(view.size.y, root.size.y - Metrics.scaled(10))
	await _settle()
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	check(view._edit_permission_button.is_visible_in_tree() and not view._edit_permission_status.visible and not view.agent_controller.auto_apply_enabled(), "empty dock shows the discoverable Review edits chip without authorizing writes")
	view.prompt_input.text = "Keep this draft"
	view._edit_permission_button.pressed.emit()
	check(view._edit_permission_dialog.visible and not view.agent_controller.auto_apply_enabled(), "opening permission selection is not a grant")
	await _dialog_bounds("first open")
	view._edit_permission_dialog.hide()
	check(view.prompt_input.text == "Keep this draft", "dismissing permission selection preserves the draft")
	view._edit_permission_button.pressed.emit()
	await _dialog_bounds("second open")
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	check(view.agent_controller.auto_apply_enabled() and view._edit_permission_status.is_visible_in_tree() and not view._edit_permission_button.visible, "confirmation replaces the floating chip with the active header indicator")
	await _layout()
	await _overlay_interaction()
	if ui_only:
		await _visual_cards()
		await _finish_fixture()
		return
	view.prompt_input.text = "Edit the fixture"
	view._on_send_button_pressed()
	check(view.agent_controller.is_busy() and _permission_control().is_visible_in_tree() and not _permission_control().disabled, "header revocation remains available during an active request")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("automatic")]})
	await _settle()
	check(FileAccess.get_file_as_string(path) == Component.NEW and client.requests.size() == 2, "actual dock automatic edit writes and continues")
	var card = view._change_cards.get("automatic")
	check(card != null and not card._apply_button.visible and not card._reject_button.visible and card._diff_label.visible, "automatic edits retain the normal inline diff with no approval buttons")
	check(card._diff_label.get_parsed_text().contains("const VALUE = 1") and card._diff_label.get_parsed_text().contains("const VALUE = 2"), "automatic inline review shows both exact source versions")
	check(card._revert_button.visible and card._revert_button.disabled, "Revert is visible but disabled until the request completes")
	check(_permission_control().tooltip_text.contains("revoke"), "visible permission control explains revocation")
	client.complete({"role": "assistant", "content": "Finished."})
	await _settle()
	check(not card._revert_button.disabled, "completed automatic edit can be reverted in idle Work")
	var saved: Dictionary = view.session_store.load_session(view._session["id"])
	check(saved["script_changes"].size() == 1 and saved["script_changes"][0]["status"] == "applied", "actual UI writer durably stores the applied checkpoint")
	var checkpoint_id: String = saved["script_changes"][0]["id"]
	check(view._restore_session(saved), "actual History restoration succeeds")
	await _settle()
	check(not view.agent_controller.auto_apply_enabled() and view._edit_permission_status.accessibility_name.contains("Review edits") and not view._edit_permission_button.visible, "History restoration shows compact Review edits without covering restored changes")
	var checkpoint_only := saved.duplicate(true)
	checkpoint_only["events"] = []
	checkpoint_only["continuation"] = []
	check(view._restore_session(checkpoint_only), "durable checkpoint history restores even when visible events were compacted away")
	check(not view.empty_state.visible and view._edit_permission_status.visible and not view._edit_permission_button.visible, "checkpoint-only review never reintroduces the empty-state logo or floating permission chip")
	check(view._restore_session(saved), "normal saved history remains restorable after checkpoint-only review")
	var restored = view._change_cards.get(checkpoint_id)
	check(restored != null and restored._proposal.get("_lazy_diff", false) and restored._revert_button.visible, "restored automatic edits retain lazy review and guarded Revert")
	restored._show_expanded_diff()
	await _settle()
	var review: Window
	for child in restored.get_children():
		if child is Window: review = child
	check(review != null and review.visible and not restored._proposal.get("diff", {}).get("operations", []).is_empty(), "restored diff materializes only on explicit expansion")
	check(restored._diff_label.visible and restored._diff_label.get_parsed_text().contains("const VALUE = 2"), "explicit historical expansion also fills the inline review")
	if review != null: restored._dismiss_expanded_diff(review)
	await _settle()
	await _dirty_revert(restored)
	restored._revert_button.pressed.emit()
	await _settle()
	check(FileAccess.get_file_as_string(path) == Component.OLD and view._session["script_changes"][0]["status"] == "reverted", "restored Revert restores original bytes and persists the result")
	await _dirty_apply(client)
	view._start_new_session()
	await _settle()
	view.prompt_input.text = "Start with review, then allow this session"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("pending-grant")]})
	check(FileAccess.get_file_as_string(path) == Component.OLD and view._edit_permission_status.is_visible_in_tree() and not _permission_control().disabled, "first eligible proposal exposes compact session permission while waiting for review")
	var pending_card = view._change_cards.get("pending-grant")
	var reviewed_diff: String = pending_card._diff_label.text
	check(pending_card._apply_button.visible and pending_card._reject_button.visible and pending_card._diff_label.visible, "manual script review retains its inline diff and decisions")
	_permission_control().pressed.emit()
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	check(FileAccess.get_file_as_string(path) == Component.NEW and view.agent_controller.auto_apply_enabled(), "exact pending-proposal confirmation grants the session and applies through the normal automatic path")
	check(pending_card._diff_label.visible and pending_card._diff_label.text == reviewed_diff and not pending_card._apply_button.visible and pending_card._revert_button.visible, "switching a reviewed proposal to automatic application preserves the same inline diff")
	client.complete({"role": "assistant", "content": "Done."})
	view._start_new_session()
	await _settle()
	view._edit_permission_button.pressed.emit()
	view._edit_permission_dialog.hide()
	view._start_new_session()
	view._edit_permission_dialog.confirmed.emit()
	check(not view.agent_controller.auto_apply_enabled(), "a stale confirmation cannot grant a new session")
	view.agent_controller.set_mode(0)
	check(view._edit_permission_button.disabled, "Plan cannot enable automatic editing")
	view.agent_controller.set_mode(1)
	view._edit_permission_button.pressed.emit()
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	view._set_request_active(true)
	view._edit_permission_status.pressed.emit()
	check(not view.agent_controller.auto_apply_enabled() and _permission_control().disabled, "one active-turn header click revokes permission immediately")
	view._set_request_active(false)
	await _finish_fixture()

func _finish_fixture() -> void:
	view._session = {}
	view._has_session_content = false
	var store = view.session_store
	view.queue_free()
	await _settle()
	if not path.is_empty():
		EditorInterface.get_script_editor().close_file(path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".uid"))
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage + "/index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage))
	_restore_preferences()
	if not path.is_empty(): EditorInterface.get_resource_filesystem().scan()
	await _settle()
	for failure in failures: push_error(failure)
	print("auto_apply_editor_test: %d failures%s" % [failures.size(), " (UI-only; no project writes)" if path.is_empty() else ""])
	quit(0 if failures.is_empty() else 1)

func _visual_cards() -> void:
	view.empty_state.hide()
	view._has_session_content = true
	view._sync_metrics_visibility()
	var card := preload("res://addons/orca/scripts/change_card.gd").new()
	view.chat_feed.add_child(card)
	var proposal := {"id": "visual", "filepath": "res://visual.gd", "existed": true, "status": "pending", "old_content": Component.OLD, "new_content": Component.NEW, "diff": preload("res://addons/orca/scripts/diff_utils.gd").create_diff(Component.OLD, Component.NEW), "validation": {"message": "GDScript is valid."}}
	card.configure(proposal)
	var manual_diff: String = card._diff_label.text
	proposal["_auto_apply"] = true
	card.configure(proposal)
	card.set_status("applied", "Synthetic visual fixture")
	await _settle()
	check(card._diff_label.visible and card._diff_label.text == manual_diff and card._revert_button.visible, "rendered automatic and manual cards share the exact inline review")
	check(card.get_global_rect().grow(1).encloses(card._diff_label.get_global_rect()), "rendered inline diff stays inside its card")
	card._show_expanded_diff()
	await _settle()
	for child in card.get_children():
		if child is Window: card._dismiss_expanded_diff(child)
	_permission_control().pressed.emit()
	check(not view.agent_controller.auto_apply_enabled(), "rendered header icon revokes its session grant")
	await _settle()

func _put(content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _patch(id: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "apply_patch", "arguments": JSON.stringify({"filepath": path, "base_hash": Component.OLD.sha256_text(), "edits": [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}]})}}

func _settle() -> void:
	for frame in 8: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame

func _layout() -> void:
	var overlay: Control = view._edit_permission_button.get_parent()
	var button: Button = view._edit_permission_button
	var original_font := button.get_theme_font_size("font_size")
	var status_font: int = view._edit_permission_status.get_theme_font_size("font_size")
	var body_font: int = view._edit_permission_dialog_body.get_theme_font_size("normal_font_size")
	var remember_font: int = view._edit_permission_remember.get_theme_font_size("font_size")
	var dialog_buttons := [view._edit_permission_dialog.get_ok_button(), view._edit_permission_dialog.get_cancel_button()]
	var action_fonts := []
	for action in dialog_buttons: action_fonts.append(action.get_theme_font_size("font_size"))
	check(view.header.get_child_count() == 2, "edit permission does not reserve a third header row")
	check(view.composer_content.get_child_count() == 2 and not view.composer_content.has_node("EditPermissionRow"), "composer contains only prompt and its original actions")
	check(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE and overlay.get_combined_minimum_size() == Vector2.ZERO, "transparent overlay passes input through and contributes no layout minimum")
	check(button.icon != null and button.accessibility_name.contains("Script edit permission"), "floating chip has an edit icon and accessible state")
	var original_layout := _chat_layout_snapshot()
	for multiplier in [1.0, 1.5, 2.0]:
		button.add_theme_font_size_override("font_size", roundi(original_font * multiplier))
		view._edit_permission_status.add_theme_font_size_override("font_size", roundi(status_font * multiplier))
		await _settle()
		check(view.get_combined_minimum_size().x <= Metrics.scaled(300), "permission control does not widen a 300-unit dock at %.1fx fonts" % multiplier)
		for enabled in [false, true]:
			view.agent_controller.set_auto_apply_enabled(enabled)
			await _settle()
			_permission_bounds("%s at %.1fx fonts" % ["Auto apply" if enabled else "Review edits", multiplier], true)
			check(button.visible != enabled and view._edit_permission_status.visible == enabled, "empty-state controls switch from the chip to the header only when Auto apply is selected")
			check(_chat_layout_snapshot() == original_layout, "caption/font changes preserve header, conversation, composer and empty-state geometry")
			overlay.hide()
			await _settle()
			check(_chat_layout_snapshot() == original_layout, "hiding the permission chip frees no reserved conversation row")
			overlay.show()
			await _settle()
		view._edit_permission_dialog_body.add_theme_font_size_override("normal_font_size", roundi(body_font * multiplier))
		view._edit_permission_remember.add_theme_font_size_override("font_size", roundi(remember_font * multiplier))
		for index in dialog_buttons.size():
			dialog_buttons[index].add_theme_font_size_override("font_size", roundi(action_fonts[index] * multiplier))
		view._edit_permission_dialog.popup_centered(view._edit_permission_dialog_size())
		await _dialog_bounds("%.1fx fonts" % multiplier)
		if multiplier == 2.0:
			var body: RichTextLabel = view._edit_permission_dialog_body
			check(body.get_content_height() > body.size.y and body.scroll_active, "large-font permission explanation scrolls within its fixed body")
			var action_position: Vector2 = dialog_buttons[0].global_position
			body.get_v_scroll_bar().value = body.get_v_scroll_bar().max_value
			await _settle()
			check(dialog_buttons[0].global_position == action_position, "scrolling the explanation does not move the confirmation footer")
		view._edit_permission_dialog.hide()
	# At an even narrower width the caption may clip, but cannot force the dock
	# wider or overlap its scrollbar. The complete state remains in its tooltip.
	view.size.x = Metrics.scaled(220)
	await _settle()
	_permission_bounds("220-unit dock at 2x fonts", false)
	check(view.get_combined_minimum_size().x <= Metrics.scaled(220), "compact permission status does not widen an unusually narrow dock")
	view.size.x = Metrics.scaled(300)
	button.add_theme_font_size_override("font_size", original_font)
	view._edit_permission_status.add_theme_font_size_override("font_size", status_font)
	view._edit_permission_dialog_body.add_theme_font_size_override("normal_font_size", body_font)
	view._edit_permission_remember.add_theme_font_size_override("font_size", remember_font)
	for index in dialog_buttons.size(): dialog_buttons[index].add_theme_font_size_override("font_size", action_fonts[index])
	await _settle()

func _chat_layout_snapshot() -> Array:
	return [view.header.get_global_rect(), view.chat_scroll.get_global_rect(), view.composer.get_global_rect(), view.empty_state.get_global_rect()]

func _permission_control() -> Button:
	return view._edit_permission_status if view._edit_permission_status.visible else view._edit_permission_button

func _permission_bounds(scenario: String, full_caption: bool) -> void:
	var button := _permission_control()
	var bounds: Rect2 = view.chat_scroll.get_global_rect()
	var chip := button.get_global_rect()
	if button == view._edit_permission_status:
		check(view.header.get_global_rect().grow(1).encloses(chip) and not bounds.intersects(chip), "compact permission stays inside the header and never covers conversation text: " + scenario)
		check(chip.size.is_equal_approx(Metrics.scaled_vector(Vector2(24, 24))), "header permission keeps a small fixed editor-scaled target: %s, actual %s expected %s" % [scenario, chip.size, Metrics.scaled_vector(Vector2(24, 24))])
		check(chip.position.x >= view.header_title.get_global_rect().end.x and chip.end.x <= view.new_session_button.global_position.x, "permission sits beside ORCA without overlapping header actions: " + scenario)
		check(button.text.is_empty() and button.icon != null and button.focus_mode == Control.FOCUS_ALL, "compact permission has only an icon and remains keyboard-accessible")
		return
	var scrollbar: VScrollBar = view.chat_scroll.get_v_scroll_bar()
	check(bounds.grow(1).encloses(chip) and chip.size.x > 0 and chip.size.y > 0, "floating permission stays within the conversation: " + scenario)
	check(not chip.intersects(view.header.get_global_rect()) and not chip.intersects(view.composer.get_global_rect()), "floating permission does not cover header/composer: " + scenario)
	check(absf(chip.position.y - bounds.position.y - Metrics.scaled(4)) < 2, "floating permission tracks the top of the conversation: " + scenario)
	var right := scrollbar.global_position.x if scrollbar.is_visible_in_tree() else bounds.end.x
	check(absf(chip.end.x - right + Metrics.scaled(4)) < 2, "floating permission stays right-aligned beside the scrollbar: " + scenario)
	if scrollbar.is_visible_in_tree():
		check(not chip.intersects(scrollbar.get_global_rect()), "floating permission leaves the scrollbar accessible: " + scenario)
	if full_caption:
		var caption_width := button.get_theme_font("font").get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x
		check(button.size.x >= caption_width + Metrics.scaled(20), "permission caption and icon remain complete: " + scenario)

func _overlay_interaction() -> void:
	# Route actual mouse events through the editor viewport, rather than emitting
	# chip signals, to catch transparent-overlay interception and layer mistakes.
	var response: RichTextLabel = view._add_message("Orca", "Readable conversation line.\n".repeat(60), Color.LIGHT_GREEN, "assistant")
	view._has_session_content = true
	view._sync_metrics_visibility()
	await _settle()
	_permission_bounds("populated conversation", true)
	check(not view._edit_permission_button.visible and view._edit_permission_status.is_visible_in_tree(), "populated conversation has no floating permission chip")
	view.chat_scroll.scroll_vertical = 0
	await _settle()
	var chip: Rect2 = view._edit_permission_status.get_global_rect()
	var point: Vector2 = view.chat_scroll.global_position + Metrics.scaled_vector(Vector2(30, 80))
	await _mouse_motion(point)
	var wheel := InputEventMouseButton.new()
	wheel.position = point
	wheel.global_position = point
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.factor = 1.0
	var previous_scroll: int = view.chat_scroll.scroll_vertical
	root.push_input(wheel, true)
	wheel.pressed = false
	root.push_input(wheel, true)
	await _settle()
	check(view.chat_scroll.scroll_vertical > previous_scroll, "transparent permission overlay allows actual conversation wheel scrolling")
	check(view._edit_permission_status.get_global_rect().is_equal_approx(chip), "header permission stays fixed while conversation messages scroll")
	view.chat_scroll.scroll_vertical = 0
	await _settle()
	var start: Vector2 = response.global_position + Vector2(Metrics.scaled(16), response.get_line_offset(1) + response.get_theme_font("normal_font").get_height(response.get_theme_font_size("normal_font_size")) / 2)
	await _mouse_motion(start)
	_mouse_button(start, true, true)
	_mouse_button(start, false)
	check(not response.get_selected_text().is_empty(), "transparent permission overlay allows actual conversation text selection")
	await _click_chip()
	check(not view.agent_controller.auto_apply_enabled() and not view._edit_permission_button.visible, "actual header click revokes edits without reintroducing a floating conversation chip")
	var review_color: Color = view._edit_permission_status.get_theme_color("icon_normal_color")
	await _click_chip()
	check(view._edit_permission_dialog.visible and not view.agent_controller.auto_apply_enabled(), "actual compact Review edits click opens confirmation without granting edits")
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	check(view._edit_permission_status.get_theme_color("icon_normal_color").g > review_color.g, "active permission uses the green accent instead of the muted review icon")
	# While other header actions are locked, the visible icon still revokes with
	# an actual viewport click. This never depends on opening Settings or modes.
	view._set_request_active(true)
	check(not view._edit_permission_status.disabled and view.mode_button.disabled and view.settings_button.disabled, "header permission remains available while modes/settings are locked")
	await _click_chip()
	check(not view.agent_controller.auto_apply_enabled() and view._edit_permission_status.disabled, "actual active-turn header click revokes before any later write")
	view._set_request_active(false)
	await _click_chip()
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	view._on_settings_button_pressed()
	check(not _permission_control().is_visible_in_tree(), "Settings hides the header permission control")
	view._on_settings_done()
	view._on_history_button_pressed()
	check(not _permission_control().is_visible_in_tree(), "History hides the header permission control")
	view._on_history_done()
	view._clear_chat_feed()
	view._has_session_content = false
	view._sync_metrics_visibility()
	await _settle()
	_permission_bounds("returned empty state with Auto apply", true)
	check(not view._edit_permission_button.visible and view._edit_permission_status.visible, "Auto apply keeps the empty state free of the large chip")
	check(view.agent_controller.auto_apply_enabled(), "overlay layout/navigation checks preserve the explicitly confirmed grant")

func _mouse_motion(point: Vector2, mask: int = 0) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.button_mask = mask
	root.warp_mouse(point)
	await process_frame
	await process_frame
	root.push_input(motion, true)
	await process_frame

func _mouse_button(point: Vector2, pressed: bool, double_click: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.double_click = double_click
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event, true)

func _click_chip() -> void:
	var point := _permission_control().get_global_rect().get_center()
	await _mouse_motion(point)
	_mouse_button(point, true)
	_mouse_button(point, false)
	await _settle()

func _dialog_bounds(scenario: String) -> void:
	if DisplayServer.get_name() == "headless":
		# Native popup_centered() has no usable display on the headless backend.
		# Exercise its requested layout; the graphical run checks actual popups.
		view._edit_permission_dialog.size = view._edit_permission_dialog_size()
	await _settle()
	var dialog: ConfirmationDialog = view._edit_permission_dialog
	var bounds := Rect2(Vector2.ZERO, Vector2(dialog.size)).grow(1)
	check(dialog.size == view._edit_permission_dialog_size(), "permission dialog keeps its bounded nonzero requested size: %s actual %s requested %s owner %s" % [scenario, dialog.size, view._edit_permission_dialog_size(), view.get_window().size])
	var body: RichTextLabel = view._edit_permission_dialog_body
	check(bounds.encloses(body.get_global_rect()) and body.size.x > 0 and body.size.y > 0, "scrolling explanation stays inside the dialog: " + scenario)
	var remember: CheckBox = view._edit_permission_remember
	check(bounds.encloses(remember.get_global_rect()) and body.get_global_rect().end.y <= remember.get_global_rect().position.y, "remember checkbox stays visible beneath the scrolling explanation: " + scenario)
	for action in [dialog.get_ok_button(), dialog.get_cancel_button()]:
		check(action.is_visible_in_tree() and bounds.encloses(action.get_global_rect()), "permission action remains visible: " + scenario)
		check(body.get_global_rect().end.y <= action.get_global_rect().position.y, "permission explanation cannot push actions offscreen: " + scenario)
		check(remember.get_global_rect().end.y <= action.get_global_rect().position.y, "remember option cannot cover confirmation actions: " + scenario)

func _open_dirty(source: String) -> CodeEdit:
	var script := ResourceLoader.load(path, "Script", ResourceLoader.CACHE_MODE_REPLACE) as Script
	EditorInterface.edit_script(script, 1, 1, true)
	for frame in 30: await process_frame
	var editor := EditorInterface.get_script_editor().get_current_editor()
	var code: CodeEdit = editor.get_base_editor() if editor != null else null
	check(code != null, "fixture opens through the public script editor")
	if code != null:
		code.text = source
		for frame in 30: await process_frame
		check(EditorContext.has_unsaved_file(path), "real editor buffer becomes dirty")
	return code

func _dirty_revert(card) -> void:
	var unsaved := Component.NEW + "# unsaved user edit\n"
	var code := await _open_dirty(unsaved)
	card._revert_button.pressed.emit()
	check(FileAccess.get_file_as_string(path) == Component.NEW and code != null and code.text == unsaved, "restored Revert preserves dirty editor source and disk bytes")
	EditorInterface.get_script_editor().close_file(path)
	await _settle()

func _dirty_apply(client) -> void:
	_permission_control().pressed.emit()
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()
	var unsaved := Component.OLD + "# dirty before automatic edit\n"
	var code := await _open_dirty(unsaved)
	view.prompt_input.text = "Edit dirty fixture"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("dirty")]})
	check(FileAccess.get_file_as_string(path) == Component.OLD and code != null and code.text == unsaved, "automatic preparation cannot overwrite an actual unsaved buffer")
	client.complete({"role": "assistant", "content": "Save the dirty script first."})
	EditorInterface.get_script_editor().close_file(path)
	await _settle()
