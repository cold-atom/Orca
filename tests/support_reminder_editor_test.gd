@tool
extends "res://tests/editor_test_case.gd"

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Reminder = preload("res://addons/orca/scripts/support_reminder.gd")
const Card = preload("res://addons/orca/scripts/support_card.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	func _refresh_model_metadata() -> void: pass
	func _restore_active_session() -> void:
		_session = session_store.create_session(1, "openai", "gpt-4o-mini")

class Client extends Node:
	signal request_completed(id: int, response: Dictionary)
	signal request_failed(id: int, error: Dictionary)
	signal request_cancelled(id: int)
	signal stream_started(id: int)
	signal stream_delta(id: int, content: String)
	var requests: Array = []
	var requesting := false
	func send_chat_completion(messages, tools, profile, options) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "profile": profile.duplicate(true), "options": options.duplicate(true)})
		requesting = true
	func is_requesting() -> bool: return requesting
	func last_request_may_have_usage() -> bool: return false
	func cancel_request() -> void:
		requesting = false
		request_cancelled.emit(int(requests[-1]["options"]["lifecycle_request_id"]))
	func complete(message: Dictionary) -> void:
		requesting = false
		request_completed.emit(int(requests[-1]["options"]["lifecycle_request_id"]), {"choices": [{"message": message, "finish_reason": "tool_calls" if message.has("tool_calls") else "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
	func fail() -> void:
		requesting = false
		request_failed.emit(int(requests[-1]["options"]["lifecycle_request_id"]), {"message": "Synthetic fixture error"})

var failures: Array[String] = []
var view
var client: Client
var settings: EditorSettings
var now := 0


func _init() -> void: call_deferred("run")


func check(value: bool, message: String) -> void:
	if not value: failures.append(message)


func settle() -> void:
	for frame in 12: await process_frame


func ready_state() -> Dictionary:
	return Reminder.initial_state().merged({"first_use": now - 8 * Reminder.DAY_SECONDS, "last_use": now - Reminder.DAY_SECONDS, "turns": 10, "active_days": 3}, true)


func eligible_idle() -> void:
	view.prompt_input.release_focus()
	view._support_presented = false
	view._support_quiet_since = Time.get_ticks_msec() - view.SUPPORT_QUIET_MSEC
	view._scroll_follow_frames = 0
	view.chat_scroll.scroll_vertical = int(view.chat_scroll.get_v_scroll_bar().max_value)
	settings.set_setting(Reminder.SETTING, ready_state())


func blocked(description: String) -> void:
	eligible_idle()
	view._check_support_reminder()
	check(not view._support_card.visible and view._support_reminder.state()["shows"] == 0, description)


func layout_snapshot() -> Array:
	return [view.header.get_global_rect(), view.chat_scroll.get_global_rect(), view.chat_feed.get_global_rect(), view.empty_state.get_global_rect(), view.empty_content.get_global_rect(), view.empty_logo.get_global_rect(), view.empty_title.get_global_rect(), view.empty_description.get_global_rect(), view.empty_mode_hint.get_global_rect(), view.composer.get_global_rect(), view.chat_scroll.scroll_vertical, view.chat_scroll.get_v_scroll_bar().max_value, view.chat_scroll.get_v_scroll_bar().visible]


func scale_card_fonts(factor: float) -> void:
	for child in view._support_card.find_children("*", "Control", true, false):
		if child is Label or child is BaseButton:
			if not child.has_meta("fixture_font"):
				child.set_meta("fixture_font", child.get_theme_font_size("font_size"))
			child.add_theme_font_size_override("font_size", roundi(int(child.get_meta("fixture_font")) * factor))


func run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	await create_timer(0.5).timeout
	settings = EditorInterface.get_editor_settings()
	now = int(Time.get_unix_time_from_system())
	var restart := OS.get_environment("ORCA_SUPPORT_TEST_PHASE") == "restart"
	if restart:
		check(Reminder.new().state()["stopped"], "permanent opt-out survives a clean editor process restart")
	else:
		_test_schedule()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	root.size = Vector2i(Metrics.scaled_int(1200), Metrics.scaled_int(950))
	view = ChatScene.instantiate()
	view.set_script(FixtureChat)
	root.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	view.size = Metrics.scaled_vector(Vector2(300, 850))
	await settle()
	view.get_node("SupportIdleTimer").stop()
	client = Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	if restart:
		view._support_quiet_since = Time.get_ticks_msec() - view.SUPPORT_QUIET_MSEC
		view._check_support_reminder()
		check(not view._support_card.visible, "a new dock does not repeat an opted-out invitation")
	else:
		await _test_idle_and_layout()
		await _test_turn_lifecycle()
		eligible_idle()
		view._check_support_reminder()
		view._support_card.never_button.pressed.emit()
		check(view._support_reminder.state()["stopped"] and not view._support_card.visible, "Don't ask again permanently retires the card")
	view.queue_free()
	await settle()
	for failure in failures: printerr("support_reminder_editor_test: ", failure)
	print("support_reminder_editor_test: ", "PASS" if failures.is_empty() else "FAIL", " (", "restart" if restart else "exercise", ")")
	quit(0 if failures.is_empty() else 1)


func _test_schedule() -> void:
	var reminder := Reminder.new()
	settings.erase(Reminder.SETTING)
	check(not Reminder.due(reminder.state(), now), "fresh installation never asks")
	for turn in 10: reminder.record_use(now - 8 * Reminder.DAY_SECONDS)
	check(reminder.state()["turns"] == 10 and reminder.state()["active_days"] == 1 and not Reminder.due(reminder.state(), now), "ten same-day interactions are insufficient")
	reminder.record_use(now - 7 * Reminder.DAY_SECONDS)
	reminder.record_use(now - 6 * Reminder.DAY_SECONDS)
	check(not Reminder.due(reminder.state(), now - 2 * Reminder.DAY_SECONDS), "active-day threshold cannot bypass the seven-day wait")
	check(Reminder.due(reminder.state(), now) and reminder.mark_shown(now), "meaningful use permits one invitation")
	check(not reminder.mark_shown(now) and not Reminder.new().mark_shown(now), "loaded/new docks share the local cooldown")
	check(not Reminder.due(reminder.state(), now + Reminder.REMINDER_DELAY), "a follow-up requires further use, not just elapsed installation time")
	reminder.record_use(now + Reminder.DAY_SECONDS)
	check(not Reminder.due(reminder.state(), now + Reminder.REMINDER_DELAY - 1), "Not now or passive hiding waits a full sixty days")
	check(reminder.mark_shown(now + Reminder.REMINDER_DELAY), "only one later reminder is permitted")
	check(not Reminder.due(reminder.state(), now + 2 * Reminder.REMINDER_DELAY), "two total presentations are a lifetime cap")
	for bad in [{}, {"version": 2}, ready_state().merged({"stopped": "false"}, true), ready_state().merged({"turns": 10.0}, true)]:
		settings.set_setting(Reminder.SETTING, bad)
		reminder.record_use(now)
		check(reminder.state()["stopped"] and not reminder.mark_shown(now), "malformed preferences fail quiet")
	settings.set_setting(Reminder.SETTING, ready_state())
	check(not Reminder.due(reminder.state(), now - 10 * Reminder.DAY_SECONDS), "clock rollback never produces an early reminder")


func _test_idle_and_layout() -> void:
	eligible_idle()
	view._support_quiet_since = Time.get_ticks_msec()
	view._check_support_reminder()
	check(not view._support_card.visible, "eligibility still waits for thirty quiet seconds")
	view.prompt_input.text = "Keep my draft"
	blocked("a text draft suppresses the invitation")
	view.prompt_input.text = ""
	view._draft_script_paths = ["res://unread.gd"]
	blocked("attachments suppress it without reading source")
	view._draft_script_paths.clear()
	view.agent_controller._pending_change_id = "fixture-approval"
	blocked("a pending edit suppresses it even without a network request")
	view.agent_controller._pending_change_id = ""
	view.agent_controller._pending_work_mode_call_id = "fixture-mode"
	blocked("Plan-to-Work approval also suppresses it")
	view.agent_controller._pending_work_mode_call_id = ""
	view.main_content.hide()
	blocked("settings/history navigation never shows it")
	view.main_content.show()
	view._connection_overlay.show()
	blocked("onboarding takes priority")
	view._connection_overlay.hide()
	view._session_resumable = false
	blocked("view-only restored conversations never show it")
	view._session_resumable = true
	view.account_service.state = "pairing"
	blocked("account setup takes priority")
	view.account_service.state = "signed_out"
	eligible_idle()
	var composer_rect: Rect2 = view.composer.get_global_rect()
	var scroll: int = view.chat_scroll.scroll_vertical
	var original_layout := layout_snapshot()
	var session: Dictionary = view._session.duplicate(true)
	var history: Array = view.agent_controller.message_history.duplicate(true)
	view._check_support_reminder()
	await settle()
	check(view._support_card.visible and not view.prompt_input.has_focus(), "idle card appears without stealing focus")
	check(view.composer.get_global_rect().is_equal_approx(composer_rect) and view.chat_scroll.scroll_vertical == scroll, "card neither resizes the composer nor forces scroll")
	check(layout_snapshot() == original_layout, "showing the overlay preserves every original empty-state/feed/header/composer rectangle and scrollbar")
	check(not view.chat_feed.is_ancestor_of(view._support_card), "support content is entirely outside the conversation layout")
	check(view._support_card.global_position.y >= view.header.get_global_rect().end.y and view.chat_scroll.get_global_rect().encloses(view._support_card.get_global_rect()), "card is immediately visible below the header without scrolling")
	check(view._session == session and view.agent_controller.message_history == history, "invitation never enters history or model context")
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for factor in [1.0, 1.5, 2.0]:
			scale_card_fonts(factor)
			await settle()
			var card = view._support_card
			check(card.get_combined_minimum_size().x <= view.chat_scroll.size.x, "narrow card stays within dock at " + locale + "/" + str(factor))
			check(view._support_overlay_scroll.get_global_rect().position.y >= view.header.get_global_rect().end.y and view._support_overlay_scroll.get_global_rect().end.y <= view.composer.global_position.y, "overlay viewport remains between header and composer: " + locale)
			for button in [card.github_button, card.review_button, card.later_button, card.never_button, card.close_button]:
				check(button.size.x >= button.get_combined_minimum_size().x and card.get_global_rect().encloses(button.get_global_rect()), "full localized button caption fits: " + locale)
			check(card.get_global_rect().encloses(card.title_label.get_global_rect()), "wrapped heading stays inside overlay: " + locale)
		view.size.y = Metrics.scaled(450)
		await settle()
		check(view._support_overlay_scroll.get_global_rect().end.y <= view.composer.global_position.y and view._support_overlay_scroll.get_v_scroll_bar().visible, "short dock uses internal card scrolling instead of covering composer: " + locale)
		view.size.y = Metrics.scaled(850)
		scale_card_fonts(1.0)
		await settle()
	Localization.select_language("en")
	await settle()
	view._support_card.later_button.pressed.emit()
	await settle()
	check(layout_snapshot() == original_layout, "dismissal restores the untouched original empty-state layout")
	view._check_support_reminder()
	check(not view._support_card.visible and view._support_reminder.state()["shows"] == 1, "Not now consumes only one presentation and stays dismissed")
	eligible_idle()
	view._check_support_reminder()
	var escape := InputEventAction.new()
	escape.action = "ui_cancel"
	escape.pressed = true
	view._unhandled_key_input(escape)
	check(not view._support_card.visible and not view._support_overlay.visible, "Escape dismisses the overlay without changing focus")
	eligible_idle()
	view._check_support_reminder()
	view._support_card.close_button.pressed.emit()
	check(not view._support_overlay.visible and not view._support_reminder.state()["stopped"], "Close dismisses quietly without permanently opting out")
	eligible_idle()
	view._check_support_reminder()
	view.prompt_input.grab_focus()
	check(not view._support_card.visible, "focusing the composer hides an existing card immediately")
	view._support_presented = false
	view._support_quiet_since = Time.get_ticks_msec() - view.SUPPORT_QUIET_MSEC
	view._check_support_reminder()
	check(not view._support_card.visible, "even a quiet focused composer never receives the invitation")
	eligible_idle()
	view._check_support_reminder()
	var opened: Array = []
	view.support_browser_opener = func(url): opened.append(url)
	view._support_card.github_button.pressed.emit()
	check(opened == [Card.GITHUB] and view._support_reminder.state()["stopped"], "GitHub opens only on click and retires future reminders")
	eligible_idle()
	view._check_support_reminder()
	view._support_card.review_button.pressed.emit()
	check(opened == [Card.GITHUB, Card.STORE] and view._support_reminder.state()["stopped"], "review action opens the exact supplied Store URL")
	view._on_support_link_requested("https://example.invalid/")
	check(opened.size() == 2, "arbitrary browser destinations are rejected")


func _test_turn_lifecycle() -> void:
	eligible_idle()
	view._check_support_reminder()
	settings.set_setting(Reminder.SETTING, Reminder.initial_state())
	view.agent_controller.set_mode(0)
	view.prompt_input.text = "Inspect editor context"
	view._on_send_button_pressed()
	check(client.requests.size() == 1 and view._support_reminder.state()["turns"] == 1 and not view._support_card.visible, "accepted turn counts once and immediately hides a displayed card")
	blocked("active request never shows an eligible card")
	settings.set_setting(Reminder.SETTING, Reminder.initial_state().merged({"first_use": now, "last_use": now, "turns": 1, "active_days": 1}, true))
	var id: int = client.requests[-1]["options"]["lifecycle_request_id"]
	client.stream_started.emit(id)
	client.stream_delta.emit(id, "Inspecting…")
	check(not view._support_card.visible, "streaming retains idle suppression")
	client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "context", "type": "function", "function": {"name": "get_editor_context", "arguments": "{}"}}]})
	await settle()
	check(client.requests.size() == 2 and view._support_reminder.state()["turns"] == 1 and not view._support_card.visible, "tool continuation neither counts twice nor shows a reminder")
	client.complete({"role": "assistant", "content": "Done."})
	await settle()
	check(not view._request_active and not view._support_card.visible, "completion does not immediately display an invitation")
	view.prompt_input.text = "Explain whether Work is needed"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "mode", "type": "function", "function": {"name": "request_work_mode", "arguments": JSON.stringify({"reason": "Continue with reviewed edits."})}}]})
	await settle()
	check(view.agent_controller._pending_work_mode_call_id == "mode" and not view._support_card.visible, "actual mode approval suspension remains free of reminders")
	view.agent_controller.resolve_work_mode_request("mode", view._active_turn_id, false)
	await settle()
	client.complete({"role": "assistant", "content": "Remaining in Plan."})
	await settle()
	check(view._support_reminder.state()["turns"] == 2 and not view._request_active, "approval decision and follow-up count as one interaction")
	view.prompt_input.text = "Second interaction"
	view._on_send_button_pressed()
	client.fail()
	await settle()
	check(view._support_reminder.state()["turns"] == 3 and not view._support_card.visible, "errors count as use without a prompt during failure handling")
	view.prompt_input.text = "Third interaction"
	view._on_send_button_pressed()
	view._on_send_button_pressed()
	await settle()
	check(view._support_reminder.state()["turns"] == 4 and not view._request_active and not view._support_card.visible, "Stop remains functional and counts no extra interaction")
