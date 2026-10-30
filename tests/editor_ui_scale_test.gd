extends SceneTree

const ChatWindowScene = preload("res://addons/orca/scenes/chat_window.tscn")
const ChatWindow = preload("res://addons/orca/scripts/chat_window.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")
const ChangeCard = preload("res://addons/orca/scripts/change_card.gd")
const DiffUtils = preload("res://addons/orca/scripts/diff_utils.gd")

class MemorySessionStore:
	extends RefCounted
	var saved_modes: Array[int] = []
	func save_session(session: Dictionary) -> Dictionary:
		saved_modes.append(int(session["mode"]))
		return {"success": true, "session": session.duplicate(true)}

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var scale := EditorInterface.get_editor_scale()
	get_root().size = Vector2i(UiMetrics.scaled_int(300), UiMetrics.scaled_int(800))
	_expect(is_equal_approx(UiMetrics.editor_scale(), scale), "UI metrics should use Godot's effective editor scale")
	var view = ChatWindowScene.instantiate()
	get_root().add_child(view)
	await process_frame
	await process_frame
	var margin := view.get_node("MarginContainer") as MarginContainer
	var logo := view.get_node("MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Logo") as TextureRect
	var mode := view.get_node("MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector") as Control
	_expect(margin.get_theme_constant("margin_left") == UiMetrics.scaled_int(10), "dock margins should follow the effective editor scale")
	_expect(logo.custom_minimum_size == UiMetrics.scaled_vector(Vector2(60, 60)), "empty-state logo geometry should follow the effective editor scale")
	var minimum_mode_size := UiMetrics.scaled_vector(Vector2(82, 24))
	_expect(mode.custom_minimum_size.x >= minimum_mode_size.x and mode.custom_minimum_size.y >= minimum_mode_size.y, "composer controls should preserve their scaled minimum target")
	view.prompt_input.text = ""
	view._sync_prompt_height()
	for frame in range(8):
		await process_frame
	var line_height: float = view.prompt_input.get_line_height()
	var style_height: float = view.prompt_input.get_theme_stylebox("normal").get_minimum_size().y
	_expect(view.prompt_input.custom_minimum_size.y == ceilf(ChatWindow.PROMPT_MIN_LINES * line_height + style_height), "composer height should derive from scaled editor font metrics")
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var record: Dictionary = ImageAttachments.prepare_image(image)["image"]
	_test_composer_mode_shortcut(view, record)
	_expect(view.image_icon_view.size.is_equal_approx(UiMetrics.scaled_vector(Vector2(22, 22))) and view.send_icon_view.size.is_equal_approx(view.image_icon_view.size), "image and Send artwork must share 22 px editor-scaled geometry independently of action-row height")
	view._sync_image_button("unsupported")
	var disabled_tint: Color = view.image_icon_view.self_modulate
	_expect(view.image_button.disabled and disabled_tint.a < 1.0, "unsupported image input must be non-clickable with visibly dimmed artwork")
	view._sync_image_button("supported")
	_expect(not view.image_button.disabled and view.image_icon_view.self_modulate.r > disabled_tint.r, "supported input must restore available icon appearance")
	view._sync_image_button("unknown")
	_expect(view.image_button.disabled, "unconfirmed image input must remain disabled")
	var composer_position: Vector2 = view.composer.global_position
	var composer_size: Vector2 = view.composer.size
	var conversation_rect: Rect2 = view.chat_scroll.get_global_rect()
	var empty_state_rect: Rect2 = view.empty_state.get_global_rect()
	view._draft_images = [record]
	view._refresh_attachment_tray()
	# Allow MarginContainer and nested containers to complete their deferred sorts.
	for frame in range(8):
		await process_frame
	var tray_rect: Rect2 = view._attachment_tray.get_global_rect()
	_expect(tray_rect.size.y <= UiMetrics.scaled(90), "attachment tray must remain one thumbnail row after real editor container layout")
	_expect(tray_rect.position.y >= view.composer.global_position.y - UiMetrics.scaled(100) and tray_rect.end.y <= view.composer.global_position.y, "attachment tray must occupy only the strip above the composer, never the dock/header")
	_expect(view.composer.global_position.is_equal_approx(composer_position) and view.composer.size.is_equal_approx(composer_size), "attaching an image must not move or resize the composer: before %s / %s, after %s / %s" % [composer_position, composer_size, view.composer.global_position, view.composer.size])
	_expect(view.chat_scroll.get_global_rect().is_equal_approx(conversation_rect) and view.empty_state.get_global_rect().is_equal_approx(empty_state_rect), "attachment overlay must not shrink the conversation or recenter the empty state")
	_expect(tray_rect.size.x <= UiMetrics.scaled(64) and view._attachment_tray.get_theme_stylebox("panel") is StyleBoxEmpty, "single thumbnail must float without a full-width section background")
	var remove_button := view._attachment_tray._row.get_child(0).get_child(1) as Button
	_expect(remove_button.size.x <= UiMetrics.scaled(24) and remove_button.size.y <= UiMetrics.scaled(24), "thumbnail removal must stay compact with real editor font/theme: %s" % remove_button.size)
	view._session_resumable = false
	view._on_image_button_pressed()
	_expect(not view._image_picker.visible, "unavailable image action must not open the picker even on a manually emitted action")
	view._session_resumable = true
	view.task_list_panel.set_tasks([{"content": "Attachment layout check", "status": "in_progress"}])
	view._draft_images = [record, record, record, record]
	view._refresh_attachment_tray()
	for frame in range(8):
		await process_frame
	_expect(view._attachment_tray.size.y <= UiMetrics.scaled(90) and view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "four thumbnails must retain one row without widening the narrow dock")
	_expect(not view._attachment_tray.get_global_rect().intersects(view.task_list_panel.get_global_rect()), "attachment strip must not cover a visible task checklist")
	var reference_conversation_rect: Rect2 = view.chat_scroll.get_global_rect()
	view._draft_script_paths = ["res://scripts/very_long_reference_filename_%d.gd" % 0, "res://scripts/player.gd", "res://scripts/game_manager.gd", "res://scripts/menu.gd"]
	view._refresh_script_reference_tray()
	for frame in 8:
		await process_frame
	_expect(view._script_reference_tray.get_global_rect().end.y <= view._attachment_tray.global_position.y and view._script_reference_tray.size.x <= view.composer.size.x, "script chips must fit above images without covering thumbnails or the checklist")
	_expect(view.chat_scroll.get_global_rect().is_equal_approx(reference_conversation_rect) and view.composer.size.is_equal_approx(composer_size), "script chips must preserve conversation and composer geometry")
	view._draft_script_paths.clear()
	view._refresh_script_reference_tray()
	view._draft_images.clear()
	view._refresh_attachment_tray()
	view._remove_draft_image(0)
	for frame in range(4):
		await process_frame
	_expect(not view._attachment_tray.visible, "removing attachments must hide the floating overlay")
	await _test_request_budget_header(view)
	view.main_content.hide()
	view.settings_view.show()
	await _test_account_layout(view)
	view.settings_view._show_section("about")
	var links: Array[Button] = []
	for link_name in ["AboutDocsLink", "AboutWebsiteLink", "AboutGitHubLink", "AboutIssuesLink", "AboutDiscussionsLink"]:
		links.append(view.settings_view.find_child(link_name, true, false) as Button)
	# Exercise actual editor typography and larger fonts after deferred layout.
	for font_multiplier in [1.0, 1.5, 2.0]:
		for link in links:
			for label in link.get_parent().find_children("*", "Label", true, false):
				if not label.has_meta("original_font_size"):
					label.set_meta("original_font_size", label.get_theme_font_size("font_size"))
				label.add_theme_font_size_override("font_size", roundi(label.get_meta("original_font_size") * font_multiplier))
		for frame in range(8):
			await process_frame
		for link in links:
			var frame_rect: Rect2 = link.get_global_rect().grow(0.5)
			for label in link.get_parent().find_children("*", "Label", true, false):
				_expect(frame_rect.encloses(label.get_global_rect()), "%s text must fit its clickable background at %.1fx font size" % [link.name, font_multiplier])
			var row: Control = link.get_parent()
			var next: Control = row.get_parent().get_child(row.get_index() + 1)
			_expect(row.get_global_rect().end.y <= next.get_global_rect().position.y, "%s must not overlap the following row or heading" % link.name)
		_expect(view.settings_view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "About links with larger fonts must fit the narrow dock")
	view.settings_view._show_section("provider")
	view.settings_view._load_provider("azure")
	await process_frame
	await process_frame
	_expect(view.settings_view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "Foundry Responses settings must fit the narrow editor dock")
	view.settings_view._on_api_mode_selected(1)
	await process_frame
	await process_frame
	_expect(view.settings_view.continuation_selector.visible and view.settings_view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "Foundry Chat/DeepSeek controls must fit the narrow editor dock")
	view.settings_view.hide()
	view.main_content.show()
	var model_name := "namespace/" + "long-full-model-id-".repeat(24)
	for source in ["A short response.", "```gdscript\nprint(1)\n```"]:
		view._add_final_assistant_message("Orca", source, Color.LIGHT_GREEN, {"model": model_name, "mode": 0})
		var panel: Control = view.chat_feed.get_child(view.chat_feed.get_child_count() - 1)
		var models := panel.find_children("*", "Label", true, false).filter(func(label): return label.has_meta("orca_response_model"))
		var modes := panel.find_children("*", "Label", true, false).filter(func(label): return label.has_meta("orca_response_mode"))
		_expect(models.size() == 1 and modes.size() == 1, "both plain/code editor responses must have one model/mode footer")
		if models.is_empty() or modes.is_empty():
			continue
		var model: Label = models[0]
		var response_mode: Label = modes[0]
		for font_multiplier in [1.0, 1.5, 2.0]:
			for label in [model, response_mode]:
				label.add_theme_font_size_override("font_size", roundi(view._meta_font_size * font_multiplier))
			for _frame in range(8):
				await process_frame
			var card_rect := panel.get_global_rect().grow(0.5)
			_expect(panel.get_combined_minimum_size().x <= UiMetrics.scaled(280) and card_rect.encloses(model.get_global_rect()) and card_rect.encloses(response_mode.get_global_rect()), "model/mode footer must stay inside a narrow real-editor card at %.1fx fonts" % font_multiplier)
			_expect(model.get_global_rect().end.x <= response_mode.get_global_rect().position.x and response_mode.text == "Plan", "long model names must not overlap or displace the response mode")
			_expect(model.tooltip_text == model_name and model.max_lines_visible == 2, "editor footer must preserve full model identity while bounding wrapped height")
	view.queue_free()
	await process_frame
	await _test_diff_minimap_navigation()
	if _failures.is_empty():
		print("editor_ui_scale_test: PASS (scale %.2f)" % scale)
		quit(0)
		return
	for failure in _failures:
		printerr("editor_ui_scale_test: ", failure)
	quit(1)


func _test_request_budget_header(view) -> void:
	var was_visible: bool = view.metrics_row.visible
	var original_usage: Dictionary = view._last_usage_summary.duplicate(true)
	var context_font: int = view.context_label.get_theme_font_size("font_size")
	var cost_font: int = view.cost_label.get_theme_font_size("font_size")
	var usage_signal: Signal = view.agent_controller.session_usage_changed
	var usage_callback := Callable(view, "_sync_session_usage")
	var was_connected := usage_signal.is_connected(usage_callback)
	_expect(was_connected, "the editor fixture must begin with normal controller usage updates connected")
	# This layout check injects UI-only usage, not a controller request. Catalog
	# completion can emit the idle controller's real usage between deferred sorts.
	if was_connected:
		usage_signal.disconnect(usage_callback)
	view.metrics_row.show()
	view._sync_session_usage({"context_tokens": 4088, "context_limit": 32768, "completed_requests": 5, "cost_available": true, "cost_usd": 0.0012, "request_budget": {"estimated_tokens": 38000, "context_limit": 32768, "input_budget": 24576, "output_reserve": 8192, "tool_reserve": 0, "status": "blocked", "active": false}})
	for multiplier in [1.0, 1.5, 2.0]:
		view.context_label.add_theme_font_size_override("font_size", roundi(context_font * multiplier))
		view.cost_label.add_theme_font_size_override("font_size", roundi(cost_font * multiplier))
		# Exercise the refresh race at every font size without depending on HTTP timing.
		view.model_catalog_service.call_deferred("emit_signal", "metadata_updated")
		for frame in 8:
			await process_frame
		var bounds: Rect2 = view.metrics_row.get_global_rect().grow(0.5)
		_expect(bounds.encloses(view.context_label.get_global_rect()) and bounds.encloses(view.cost_label.get_global_rect()), "estimated request and cost labels must remain inside the narrow header at larger fonts")
		_expect(view.context_label.get_global_rect().end.x <= view.cost_label.get_global_rect().position.x and view.get_combined_minimum_size().x <= UiMetrics.scaled(300), "long request estimates must clip without overlapping cost or widening the dock")
		_expect(view.context_label.tooltip_text.contains("38000") and view.context_label.tooltip_text.contains("24576"), "clipped request estimates must retain complete tooltip details at %.1fx fonts: %s" % [multiplier, view.context_label.tooltip_text])
	view.context_label.add_theme_font_size_override("font_size", context_font)
	view.cost_label.add_theme_font_size_override("font_size", cost_font)
	if was_connected:
		usage_signal.connect(usage_callback)
	usage_signal.emit({"context_tokens": 2048, "completed_requests": 1})
	_expect(view.context_label.text == "Context 2.0k", "normal controller usage updates must resume after the isolated layout check")
	usage_signal.emit(original_usage)
	view.metrics_row.visible = was_visible


func _test_account_layout(view) -> void:
	var settings = view.settings_view
	var tabs := [settings.provider_tab_button, settings.system_tab_button, settings.account_tab_button, settings.about_tab_button]
	for index in 3:
		_expect(tabs[index].get_index() < tabs[index + 1].get_index(), "Account navigation must follow System and precede About")
	_expect(settings.account_tab_button.icon.resource_path.ends_with("profile.svg"), "Account uses the supplied profile icon")
	settings._show_section("account")
	var account = view.account_service
	account.account = {"display_name": "A very long developer display name for narrow account layouts", "plan_name": "Starter", "allowance": {"available_units": 5000000, "reserved_units": 1234567}}
	account._tokens = {"session_id": "fixture-session", "access_token": "fixture-not-persisted"}
	account.state = "connected"
	account.status = "Your account is connected. Choose Orca Cloud in Provider settings."
	settings._render_account()
	for multiplier in [1.0, 1.5, 2.0]:
		for label in settings.account_scroll.find_children("*", "Label", true, false):
			if not label.has_meta("account_base_font"):
				label.set_meta("account_base_font", label.get_theme_font_size("font_size"))
			label.add_theme_font_size_override("font_size", roundi(label.get_meta("account_base_font") * multiplier))
		for frame in 8:
			await process_frame
		_expect(settings.get_combined_minimum_size().x <= UiMetrics.scaled(300), "Account must fit the narrow dock at larger fonts")
		for button in [settings.account_use_models_button, settings.account_refresh_button, settings.account_console_button, settings.account_sign_out_button]:
			_expect(button.get_global_rect().size.x <= settings.account_scroll.size.x, "Account action must remain inside its scroll surface")
	_expect(settings._account_usage_label.text.contains("$5.00") and settings._account_usage_label.text.contains("$1.23"), "Account renders exact integer allowance units")
	if OS.get_environment("ORCA_CAPTURE_ACCOUNT") == "1" and DisplayServer.get_name() != "headless":
		view.get_viewport().get_texture().get_image().save_png("/tmp/opencode/orca-account-settings.png")
	account._tokens.clear()
	account.account.clear()
	account.state = "signed_out"
	settings._render_account()
	_expect(settings.account_sign_in_button.visible and not settings.account_sign_out_button.visible, "Signed-out account has the browser connection action")


func _test_composer_mode_shortcut(view, record: Dictionary) -> void:
	var previous_session: Dictionary = view._session.duplicate(true)
	var previous_store = view.session_store
	var previous_has_content: bool = view._has_session_content
	var previous_mode: int = view.agent_controller.get_mode()
	var store := MemorySessionStore.new()
	view.session_store = store
	view._session = {"events": [], "mode": previous_mode}
	view._has_session_content = true
	view._draft_images = [record]
	view._draft_script_paths = ["res://scripts/tab_reference.gd"]
	var draft := "Explain this layout\nKeep this draft"
	view.prompt_input.text = draft
	view.prompt_input.grab_focus()
	view.prompt_input.set_caret_line(1)
	view.prompt_input.set_caret_column(7)
	view.prompt_input.select(1, 0, 1, 7)
	var caret_line: int = view.prompt_input.get_caret_line()
	var caret_column: int = view.prompt_input.get_caret_column()
	var selection: String = view.prompt_input.get_selected_text()
	var next_mode := 0 if previous_mode == 1 else 1
	_press_tab()
	_expect(view.agent_controller.get_mode() == next_mode and view.mode_label.text == ("Plan" if next_mode == 0 else "Work"), "real focused composer Tab must switch the controller and visible mode")
	_expect(view.prompt_input.has_focus() and view.prompt_input.text == draft and view.prompt_input.get_caret_line() == caret_line and view.prompt_input.get_caret_column() == caret_column and view.prompt_input.get_selected_text() == selection and view._draft_images == [record] and view._draft_script_paths == ["res://scripts/tab_reference.gd"], "mode switching must preserve focus, draft, caret, selection, and attachments")
	_expect(view._session["mode"] == next_mode and store.saved_modes == [next_mode] and view.mode_button.tooltip_text.contains("Tab to switch modes"), "Tab must use normal session persistence and disclose its shortcut")
	_press_tab({}, true)
	_expect(view.agent_controller.get_mode() == next_mode and store.saved_modes.size() == 1 and view.prompt_input.text == draft and view.prompt_input.has_focus(), "held Tab repeats must not switch again, edit the draft, or steal focus")
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode and store.saved_modes == [next_mode, previous_mode], "a second Tab must switch back and save the selected mode")
	var calls := store.saved_modes.size()
	for modifier in ["shift_pressed", "ctrl_pressed", "alt_pressed", "meta_pressed"]:
		view.prompt_input.grab_focus()
		_press_tab({modifier: true})
		_expect(view.agent_controller.get_mode() == previous_mode and store.saved_modes.size() == calls, "modified Tab must retain native behavior without switching mode: " + modifier)
	view.mode_button.grab_focus()
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode, "Tab outside the composer must not switch modes")
	view.prompt_input.grab_focus()
	view.prompt_input.text = draft
	view._set_request_active(true)
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode and view.prompt_input.text == draft and view.prompt_input.has_focus() and store.saved_modes.size() == calls, "active-response Tab must remain locked without modifying the draft")
	view._set_request_active(false)
	# Real controller permission checks still apply if UI state has not caught up.
	view.agent_controller._is_running = true
	view.agent_controller._pending_change_id = "shortcut_approval_fixture"
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode and store.saved_modes.size() == calls and view.prompt_input.text == draft, "a pending controller approval must deny shortcut switching even with idle UI")
	view.agent_controller._pending_change_id = ""
	view.agent_controller._is_running = false
	view._session_resumable = false
	view._set_request_active(false)
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode and store.saved_modes.size() == calls, "view-only sessions must not permit Tab mode changes")
	view._session_resumable = true
	view._set_request_active(false)
	view.main_content.hide()
	_press_tab()
	_expect(view.agent_controller.get_mode() == previous_mode and store.saved_modes.size() == calls, "hidden composer input must not switch modes")
	view.main_content.show()
	view._session = previous_session
	view.session_store = previous_store
	view._has_session_content = previous_has_content
	view._draft_images.clear()
	view._draft_script_paths.clear()
	view.prompt_input.text = ""
	view.prompt_input.release_focus()


func _press_tab(modifiers: Dictionary = {}, echo: bool = false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_TAB
	event.physical_keycode = KEY_TAB
	event.unicode = 9
	event.pressed = true
	event.echo = echo
	for modifier in modifiers:
		event.set(modifier, modifiers[modifier])
	get_root().push_input(event, true)
	event.pressed = false
	event.echo = false
	get_root().push_input(event, true)


func _test_diff_minimap_navigation() -> void:
	get_root().size = Vector2i(UiMetrics.scaled_int(1200), UiMetrics.scaled_int(800))
	for frame in range(4):
		await process_frame
	var lines := PackedStringArray(["extends Node", ""])
	for index in range(400):
		lines.append("var value_%d := Vector2(%d, 20) # Review navigation fixture" % [index, index])
	var old_content := "\n".join(lines)
	lines[120] = "var changed_value := Vector2(100, 40)"
	for index in range(25):
		lines.append("# Added line %d" % index)
	var new_content := "\n".join(lines)
	var card := ChangeCard.new()
	get_root().add_child(card)
	card.configure({
		"id": "minimap_review", "filepath": "res://navigation_fixture.gd",
		"old_content": old_content, "new_content": new_content,
		"diff": DiffUtils.create_diff(old_content, new_content), "status": "pending"
	})
	card._show_expanded_diff()
	for frame in range(8):
		await process_frame
	var dialog: Window
	for child in card.get_children():
		if child is Window:
			dialog = child
	if dialog == null:
		_expect(false, "expanded minimap fixture must open a review window")
		card.queue_free()
		return
	var editors := dialog.find_children("*", "CodeEdit", true, false)
	_expect(editors.size() == 2, "minimap navigation needs two review panes")
	if editors.size() != 2:
		card._dismiss_expanded_diff(dialog)
		card.queue_free()
		return
	var previous: CodeEdit = editors[0]
	var proposed: CodeEdit = editors[1]
	# The headless display reports no usable screen size to popup_centered().
	dialog.size = Vector2i(UiMetrics.scaled_int(1050), UiMetrics.scaled_int(700))
	for frame in range(8):
		await process_frame
	_expect(previous.syntax_highlighter is GDScriptSyntaxHighlighter and proposed.syntax_highlighter != previous.syntax_highlighter, "each GDScript review must have its own native syntax colors")
	_expect(previous.get_line_background_color(120).a > 0 and proposed.get_line_background_color(120).a > 0, "syntax/minimap styling must preserve removal and addition highlights")
	var panes := previous.get_parent().get_parent() as SplitContainer
	_expect(not panes.vertical, "a wide review must present side-by-side panes: root %s, dialog %s, scale %s" % [get_root().size, dialog.size, UiMetrics.editor_scale()])
	# Send real viewport GUI events into the native read-only minimap.
	for editor in [previous, proposed]:
		if DisplayServer.get_name() == "headless":
			# Native Window mouse coordinates require a real display server.
			editor.scroll_vertical = 80
			await process_frame
			_expect(absf(previous.scroll_vertical - proposed.scroll_vertical) < 1, "scroll navigation must stay synchronized in the headless layout fixture")
			continue
		previous.scroll_vertical = 0
		proposed.scroll_vertical = 0
		await process_frame
		var scrollbar_width: float = editor.get_v_scroll_bar().size.x
		var x: float = editor.size.x - scrollbar_width - editor.get_theme_stylebox("normal").get_margin(SIDE_RIGHT) - editor.minimap_width * 0.5
		var local := Vector2(x, editor.size.y * 0.5)
		_expect(editor.get_minimap_line_at_pos(Vector2i(local)) > editor.get_last_full_visible_line(), "the minimap click should target offscreen code")
		await _minimap_button(dialog, editor, local, true)
		await _minimap_button(dialog, editor, local, false)
		await create_timer(0.35).timeout
		_expect(editor.scroll_vertical > 10 and absf(previous.scroll_vertical - proposed.scroll_vertical) < 1, "clicking either read-only minimap must navigate both panes: %s / %s, position %s, size %s" % [previous.scroll_vertical, proposed.scroll_vertical, local, editor.size])
		var before: float = editor.scroll_vertical
		var viewport_center := _minimap_viewport_center(editor, x)
		await _minimap_button(dialog, editor, viewport_center, true)
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		var drag_to := viewport_center + Vector2(0, editor.size.y * 0.2)
		motion.position = editor.get_global_transform_with_canvas() * drag_to
		motion.global_position = motion.position
		motion.relative = drag_to - viewport_center
		dialog.warp_mouse(motion.position)
		await process_frame
		dialog.push_input(motion, true)
		await _minimap_button(dialog, editor, drag_to, false)
		await create_timer(0.35).timeout
		_expect(editor.scroll_vertical > before and absf(previous.scroll_vertical - proposed.scroll_vertical) < 1, "dragging either minimap must move the synchronized viewport: %s -> %s / %s" % [before, previous.scroll_vertical, proposed.scroll_vertical])
	# Resizing and splitter movement must retain readable code beside the overview.
	for width in [760, 1000]:
		dialog.size.x = UiMetrics.scaled_int(width)
		for frame in range(8):
			await process_frame
		_expect(panes.vertical == (width < 800), "review orientation must adapt after resizing")
		for editor in [previous, proposed]:
			_expect(editor.size.x - editor.minimap_width >= UiMetrics.scaled(180), "the minimap must leave room for readable code after resizing")
			_expect(editor.minimap_width >= UiMetrics.scaled_int(44) and editor.minimap_width <= UiMetrics.scaled_int(88), "the overview width must stay bounded at editor scale")
	var code_font_size := previous.get_theme_font_size("font_size")
	for font_multiplier in [1.0, 1.5, 2.0]:
		for editor in [previous, proposed]:
			editor.add_theme_font_size_override("font_size", roundi(code_font_size * font_multiplier))
		for frame in range(4):
			await process_frame
		for editor in [previous, proposed]:
			_expect(editor.get_global_rect().end.x <= dialog.size.x and editor.get_global_rect().end.y <= dialog.size.y, "code and minimaps must remain inside the review at %.1fx fonts" % font_multiplier)
	for editor in [previous, proposed]:
		editor.add_theme_font_size_override("font_size", code_font_size)
	panes.split_offsets = PackedInt32Array([roundi(UiMetrics.scaled(-180))])
	for frame in range(8):
		await process_frame
	_expect(previous.minimap_width < proposed.minimap_width, "overview widths must adapt independently when dragging the pane splitter: %s / %s, editors %s / %s" % [previous.minimap_width, proposed.minimap_width, previous.size, proposed.size])
	panes.split_offsets = PackedInt32Array([-100000])
	for frame in range(4):
		await process_frame
	_expect(previous.size.x - previous.minimap_width >= UiMetrics.scaled(180), "extreme splitter drags must preserve a usable code pane beside its minimap")
	previous.scroll_vertical = 100000
	await process_frame
	_expect(is_finite(previous.scroll_vertical) and is_finite(proposed.scroll_vertical), "unequal-length review panes must clamp end-of-file navigation")
	_expect(previous.text == old_content and proposed.text == new_content and not previous.editable and not proposed.editable, "minimap navigation must leave exact read-only review content intact")
	card._dismiss_expanded_diff(dialog)
	card.queue_free()
	await process_frame
	# Empty/new files use the same native overview without an invalid scroll range.
	var parent := VBoxContainer.new()
	get_root().add_child(parent)
	var empty_card := ChangeCard.new()
	var empty: CodeEdit = empty_card._create_code_pane(parent, "Previous", "")
	for frame in range(4):
		await process_frame
	_expect(empty.get_line_count() == 1 and empty.scroll_vertical == 0, "an empty previous file must remain a stable overview")
	parent.queue_free()
	empty_card.free()
	await process_frame


func _minimap_button(dialog: Window, editor: CodeEdit, local: Vector2, pressed: bool) -> void:
	# Native TextEdit minimap input reads the viewport mouse position.
	var motion := InputEventMouseMotion.new()
	motion.position = editor.get_global_transform_with_canvas() * local
	motion.global_position = motion.position
	motion.button_mask = 0 if pressed else MOUSE_BUTTON_MASK_LEFT
	dialog.warp_mouse(motion.position)
	await process_frame
	await process_frame
	dialog.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = editor.get_global_transform_with_canvas() * local
	event.global_position = event.position
	dialog.push_input(event, true)


func _minimap_viewport_center(editor: CodeEdit, x: float) -> Vector2:
	var middle := (editor.get_first_visible_line() + editor.get_last_full_visible_line()) / 2
	for y in range(roundi(editor.size.y)):
		if editor.get_minimap_line_at_pos(Vector2i(roundi(x), y)) >= middle:
			return Vector2(x, y)
	return Vector2(x, 0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
