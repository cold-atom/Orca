@tool
extends SceneTree

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Providers = preload("res://addons/orca/scripts/provider_registry.gd")
const Account = preload("res://addons/orca/scripts/account_service.gd")
const Cloud = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FixtureAccount extends Account:
	var pairings := 0
	var cancellations := 0
	func _ready() -> void: pass
	func refresh_account() -> void: pass
	func begin_pairing() -> void:
		pairings += 1
		state = "pairing"
		pairing_code = "FIXTURE"
		changed.emit()
	func cancel_pairing() -> void:
		cancellations += 1
		state = "signed_out"
		pairing_code = ""
		changed.emit()

class MemoryStore extends RefCounted:
	var saves := 0
	func image_storage_error(_session: Dictionary, _images: Array) -> String: return ""
	func create_session(mode: int, provider: String, model: String) -> Dictionary:
		return {"id": "onboarding-fixture", "mode": mode, "provider": provider, "model": model, "events": []}
	func save_session(session: Dictionary) -> Dictionary:
		saves += 1
		return {"success": true, "session": session.duplicate(true)}
	func set_active_session(_id: String) -> bool: return true

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	var source_reads := 0
	func _restore_active_session() -> void:
		session_store = MemoryStore.new()
		_session = session_store.create_session(agent_controller.get_mode(), Config.get_provider(), Config.get_model())
	func _refresh_model_metadata() -> void: pass
	func _prepare_script_references() -> Dictionary:
		source_reads += 1
		return {"success": true, "references": []}

class FixtureModels extends Node:
	signal models_loaded(provider_id: String, models: Array, cached: bool)
	signal models_failed(provider_id: String, message: String)
	func fetch_models(_provider: String, _config: Dictionary, _force: bool = false) -> void: pass
	func cancel() -> void: pass

class FixtureClient extends Node:
	signal request_completed(id: int, response: Dictionary)
	signal request_failed(id: int, error: Dictionary)
	signal request_cancelled(id: int)
	signal stream_started(id: int)
	signal stream_delta(id: int, content: String)
	var requests := 0
	func send_chat_completion(_messages: Array, _tools: Array, _profile: Dictionary, _options: Dictionary) -> void: requests += 1
	func is_requesting() -> bool: return false
	func last_request_may_have_usage() -> bool: return false
	func cancel_request() -> void: pass

var failures := 0
var originals := {}
var editor: EditorSettings

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	create_timer(45).timeout.connect(func(): _restore_preferences(); push_error("Onboarding fixture timed out"); quit(1))
	check(Engine.is_editor_hint(), "onboarding fixture runs in the real editor")
	for frame in 60:
		await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await process_frame
	await create_timer(1.0).timeout
	editor = EditorInterface.get_editor_settings()
	_remember(Config.SETTING_PROVIDER)
	for provider in Providers.PROVIDER_IDS:
		for field in ["api_key", "model", "reasoning_effort", "base_url", "api_mode", "continuation_style", "image_input_override", "response_start_timeout_seconds", "stream_inactivity_timeout_seconds", "custom_timeouts_enabled"]:
			_remember("orca/providers/%s/%s" % [provider, field])
		editor.set_setting("orca/providers/%s/api_key" % provider, "")
		editor.set_setting("orca/providers/%s/model" % provider, "")
	editor.set_setting(Config.SETTING_PROVIDER, "openai")
	editor.set_setting("orca/providers/openai/model", "gpt-4o")
	root.size = Vector2i(UiMetrics.scaled_int(300), UiMetrics.scaled_int(800))
	var account := FixtureAccount.new()
	root.add_child(account)
	var chat = ChatScene.instantiate()
	chat.set_script(FixtureChat)
	chat.account_service = account
	root.add_child(chat)
	await _settle()
	var models := FixtureModels.new()
	chat.settings_view._model_service.queue_free()
	chat.settings_view._model_service = models
	chat.settings_view.add_child(models)
	var client := FixtureClient.new()
	chat.agent_controller.set_api_client_for_testing(client)
	check(not chat._connection_overlay.visible and not chat._connection_first_open_checked, "constructing the dock does not consume first-visible-open intent")
	await _normal_empty_state_checks(chat)
	var normal_layout := _normal_layout_snapshot(chat)
	chat.hide()
	chat.notify_dock_opened()
	await _settle()
	check(not chat._connection_first_open_checked, "hidden plugin startup never consumes first-open intent")
	account.state = "restoring"
	chat.show()
	chat.notify_dock_opened()
	await _settle()
	check(not chat._connection_overlay.visible and not chat._connection_first_open_checked, "first-open overlay waits for account restoration")
	account.state = "signed_out"
	account._startup_restore_pending = true
	editor.set_setting("orca/providers/orca_cloud/model", "fixture-returning-model")
	account.changed.emit()
	await _settle()
	check(not chat._connection_overlay.visible and not chat._connection_first_open_checked, "returning Cloud onboarding waits for background-helper restoration")
	editor.set_setting("orca/providers/orca_cloud/model", "")
	account.changed.emit()
	await _settle()
	check(chat._connection_overlay.visible and chat._connection_setup_card.title_label.text == "Get started with Orca", "first visible unconfigured open shows a separate connection overlay")
	account._startup_restore_pending = false
	check(chat.prompt_input.editable and account.pairings == 0 and client.requests == 0, "overlay leaves composer available and starts no pairing or inference")
	check(chat.empty_state.visible and not chat.chat_feed.is_ancestor_of(chat._connection_setup_card) and normal_layout == _normal_layout_snapshot(chat), "overlay does not resize or replace the original empty state/feed/composer")
	await _layout_checks(chat._connection_setup_card, chat)
	chat._connection_setup_card.later_button.pressed.emit()
	chat.hide()
	chat.show()
	chat.notify_dock_opened()
	await _settle()
	check(not chat._connection_overlay.visible, "Set up later remains dismissed through dock reopening")
	root.size.y = UiMetrics.scaled_int(450)
	await _settle()
	chat._show_connection_setup(chat.agent_controller.connection_setup())
	await _settle()
	check(chat._connection_overlay.get_global_rect().is_equal_approx(chat.chat_scroll.get_global_rect()) and not chat._connection_overlay.get_global_rect().intersects(chat.composer.get_global_rect()), "short-dock overlay remains confined above the composer")
	chat._connection_setup_card.close_button.pressed.emit()
	check(not chat._connection_overlay.visible, "close button dismisses setup")
	root.size.y = UiMetrics.scaled_int(800)
	await _settle()
	chat.prompt_input.text = "Keep this request and selection"
	chat.prompt_input.select(0, 5, 0, 12)
	var pixels := Image.create(16, 16, false, Image.FORMAT_RGB8)
	pixels.fill(Color.RED)
	chat._draft_images = [Images.prepare_image(pixels)["image"]]
	chat._draft_script_paths = ["res://not_read_before_setup.gd"]
	var before: Dictionary = chat._session.duplicate(true)
	chat._on_send_button_pressed()
	var card = chat._connection_setup_card
	chat._on_send_button_pressed()
	check(card != null and card == chat._connection_setup_card and chat._connection_overlay.visible and chat.empty_state.visible, "repeated Send reuses one independent overlay without altering the empty state")
	check(chat.prompt_input.text == "Keep this request and selection" and chat.prompt_input.get_selected_text() == "this re", "setup preserves exact draft and selection")
	check(chat._draft_images.size() == 1 and chat._draft_script_paths.size() == 1 and chat.source_reads == 0, "setup retains attachments before referenced source reads")
	check(chat._session == before and chat.session_store.saves == 0 and chat.agent_controller.message_history.size() == 1 and client.requests == 0 and not chat._request_active, "setup creates no session events, writes, history or request")
	await _layout_checks(card, chat)
	var escape := InputEventAction.new()
	escape.action = "ui_cancel"
	escape.pressed = true
	chat._unhandled_key_input(escape)
	check(not chat._connection_overlay.visible and chat.prompt_input.has_selection(), "Escape closes setup and preserves composer selection")
	chat._on_send_button_pressed()
	card.provider_button.pressed.emit()
	await _settle()
	check(chat.settings_view.settings_scroll.visible and not chat.main_content.visible and chat.settings_view.provider_selector.has_focus(), "BYOK opens provider selection at the top of Settings")
	chat.settings_view._on_done_pressed()
	await _settle()
	check(chat.prompt_input.text == "Keep this request and selection" and not chat._connection_overlay.visible, "unfinished provider setup returns to the retained draft without reopening the overlay")
	chat._on_send_button_pressed()
	card.account_button.pressed.emit()
	check(chat.settings_view.account_scroll.visible and account.pairings == 1 and chat.settings_view.account_cancel_button.visible, "account action starts pairing once with existing progress/cancel UI")
	chat.settings_view.open_account_setup()
	check(account.pairings == 1, "reopening pending pairing never starts another connection")
	chat.settings_view.account_cancel_button.pressed.emit()
	chat.settings_view._on_done_pressed()
	check(account.cancellations == 1 and chat.prompt_input.has_selection(), "pairing cancellation returns without changing the draft selection")
	account.state = "restoring"
	account.changed.emit()
	chat._on_send_button_pressed()
	check(chat.empty_title.text == "Work with Orca" and card.account_button.disabled and chat.agent_controller.connection_setup()["status"] == "restoring", "restoration feedback stays in the overlay without modifying the normal empty state")
	card.account_button.pressed.emit()
	check(account.pairings == 1, "disabled restoring action cannot begin pairing")
	account.state = "signed_out"
	account.changed.emit()
	# Existing provider profiles suppress first-run welcome even if another
	# selected profile still needs setup.
	editor.set_setting("orca/providers/deepseek/api_key", "synthetic-only")
	editor.set_setting("orca/providers/deepseek/model", "deepseek-chat")
	chat._refresh_connection_setup()
	check(chat.empty_title.text == "Work with Orca" and chat._connection_overlay.visible, "existing users retain normal empty state and selected-profile setup guidance")
	await _normal_empty_state_checks(chat)
	editor.set_setting("orca/providers/deepseek/api_key", "")
	editor.set_setting(Config.SETTING_PROVIDER, "ollama")
	chat._sync_model_ui()
	check(chat.agent_controller.connection_setup()["status"] == "model" and card.model_button.get_parent().visible and not card.account_button.get_parent().visible, "keyless local setup requests a model, not credentials")
	card.model_button.pressed.emit()
	await _settle()
	check(chat.settings_view.settings_scroll.visible and chat.settings_view.model_search.has_focus(), "missing-model action opens focused model selection")
	chat._on_settings_done()
	editor.set_setting("orca/providers/ollama/model", "local-fixture")
	chat._sync_model_ui()
	check(chat.agent_controller.connection_setup()["status"] == "ready" and not chat._connection_overlay.visible and chat.empty_state.visible, "configured keyless local provider closes setup without changing the empty state")
	await _normal_empty_state_checks(chat)
	check(normal_layout == _normal_layout_snapshot(chat), "provider changes and overlay dismissal preserve the original layout exactly")
	# Sign-in selects the managed model through the existing Settings consumer.
	editor.set_setting(Config.SETTING_PROVIDER, "orca_cloud")
	chat._sync_model_ui()
	chat._on_send_button_pressed()
	chat._connection_setup_card.account_button.pressed.emit()
	account.account = {"id": "fixture", "display_name": "Developer"}
	account._tokens = {"session_id": "fixture", "access_token": "fixture", "refresh_token": "fixture"}
	account.models = Cloud.normalize_catalog({"data": [{"id": "managed-fixture", "name": "Managed", "context_window": 65536, "max_output_tokens": 8192, "effort": {"supported_levels": ["default"], "default_level": "default"}, "orca": {"protocol": "chat_completions", "tools": true, "continuation_style": "standard", "capability_version": "fixture-v1", "availability": "available", "recommendation": "recommended", "access": {"allowed": true}, "agent": {"status": "operator_verified", "capability_version": "fixture-v1", "tool_contract": "orca-tools-v1"}, "context_budget": {"version": "utf8-conservative-v2", "text_bytes_per_token": 3, "message_overhead": 32, "tool_overhead": 64, "image_tokens": 16384, "opaque_reasoning_bytes": false}}}]})
	account.state = "connected"
	account.changed.emit()
	account.signed_in.emit()
	await _settle()
	check(Config.get_provider() == "orca_cloud" and Config.get_model() == "managed-fixture" and not chat._connection_overlay.visible, "successful signup uses automatic managed selection and closes setup")
	chat.settings_view._on_done_pressed()
	check(chat.prompt_input.has_selection() and chat._draft_images.size() == 1 and chat._draft_script_paths.size() == 1 and client.requests == 0, "successful setup preserves attachments/selection and never automatically sends")
	account.models[0]["allowed"] = false
	account.changed.emit()
	check(chat.agent_controller.connection_setup()["status"] == "model", "locked hosted model is model selection rather than a false ready state")
	chat._on_connection_provider_requested()
	await _settle()
	check(chat.settings_view._current_provider == "openai" and chat.settings_view.api_key_input.get_parent().visible and Config.get_provider() == "orca_cloud", "BYOK from Cloud shows credential entry without switching the active provider before Done")
	chat.settings_view.api_key_input.text = "synthetic-onboarding-key"
	chat.settings_view._on_done_pressed()
	check(Config.get_provider() == "openai" and Config.get_api_key() == "synthetic-onboarding-key" and chat.agent_controller.connection_setup()["status"] == "ready" and client.requests == 0, "BYOK Done saves the chosen provider and returns without sending the draft")
	# A configured request proceeds normally only after another explicit Send.
	editor.set_setting(Config.SETTING_PROVIDER, "ollama")
	chat._draft_images.clear()
	chat._draft_script_paths.clear()
	chat._sync_model_ui()
	chat._on_send_button_pressed()
	check(client.requests == 1 and chat.source_reads == 1 and chat.prompt_input.text.is_empty(), "explicit Send after configuration starts exactly one normal turn")
	chat.agent_controller._pending_change_id = "fixture-approval"
	chat._on_connection_provider_requested()
	check(not chat.settings_view.visible, "setup navigation retains active-turn/approval lockout")
	chat.agent_controller._pending_change_id = ""
	chat.agent_controller.cancel_current_request()
	# A second dock demonstrates configured first-open suppression independently
	# of dismissal state on the first dock.
	var configured = ChatScene.instantiate()
	configured.set_script(FixtureChat)
	configured.account_service = account
	root.add_child(configured)
	await _settle()
	configured.notify_dock_opened()
	await _settle()
	check(not configured._connection_overlay.visible and configured._connection_first_open_checked, "configured users never receive an automatic first-open overlay")
	await _normal_empty_state_checks(configured)
	configured.queue_free()
	chat.queue_free()
	await create_timer(1.0).timeout
	account.queue_free()
	await process_frame
	_restore_preferences()
	while EditorInterface.get_resource_filesystem().is_scanning():
		await process_frame
	await create_timer(1.0).timeout
	print("Onboarding editor: " + ("PASS" if failures == 0 else "FAIL") + " (scale %.2f)" % UiMetrics.editor_scale())
	quit(0 if failures == 0 else 1)

func _layout_checks(panel, chat) -> void:
	for multiplier in [1.0, 1.5, 2.0]:
		for label in panel.find_children("*", "Label", true, false):
			if not label.has_meta("baseline"):
				label.set_meta("baseline", label.get_theme_font_size("font_size"))
			label.add_theme_font_size_override("font_size", roundi(label.get_meta("baseline") * multiplier))
		await _settle()
		check(chat.get_combined_minimum_size().x <= UiMetrics.scaled(300), "onboarding fits 300px dock at %.1fx fonts" % multiplier)
		check(chat._connection_overlay.get_global_rect().is_equal_approx(chat.chat_scroll.get_global_rect()), "overlay tracks the conversation rectangle")
		check(panel.size.x <= chat._connection_overlay.size.x - UiMetrics.scaled(24) + 1, "setup card remains contained at larger fonts")
		check(not chat._connection_overlay.get_global_rect().intersects(chat.composer.get_global_rect()), "overlay never covers the composer")
		var heading_bounds: Rect2 = panel.get_global_rect().grow(1)
		check(heading_bounds.encloses(panel.title_label.get_global_rect()) and heading_bounds.encloses(panel.close_button.get_global_rect()), "heading and close control remain inside the card")
		for button in [panel.account_button, panel.provider_button, panel.model_button]:
			if not button.get_parent().visible:
				continue
			var rect: Rect2 = button.get_global_rect().grow(0.5)
			for label in button.get_parent().find_children("*", "Label", true, false):
				if not label.visible:
					continue
				check(rect.encloses(label.get_global_rect()), "wrapped setup text stays inside clickable row at %.1fx fonts" % multiplier)
	for label in panel.find_children("*", "Label", true, false):
		label.add_theme_font_size_override("font_size", int(label.get_meta("baseline")))
	await _settle()

func _normal_empty_state_checks(chat) -> void:
	await _settle()
	check(chat.empty_title.text == "Work with Orca" and chat.empty_title.autowrap_mode == TextServer.AUTOWRAP_OFF, "normal title retains the original unwrapped composition")
	check(chat.empty_title.get_theme_font_size("font_size") == chat._body_font_size + 10 and chat.empty_logo.custom_minimum_size == UiMetrics.scaled_vector(Vector2(60, 60)), "normal title typography and logo size retain the original theme")
	check(chat.empty_content.custom_minimum_size.x == 0 and chat.empty_content.get_child_count() == 4, "onboarding adds no children or width overrides to the normal empty state")
	var title_width: float = chat.empty_title.get_theme_font("font").get_string_size(chat.empty_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, chat.empty_title.get_theme_font_size("font_size")).x
	check(chat.empty_title.size.x + 1 >= title_width and chat.empty_content.size.x >= title_width, "configured state cannot collapse to the logo's narrow minimum width")
	check(chat.empty_content.size.x <= chat.chat_scroll.size.x and chat.empty_description.get_line_count() <= 6, "normal description wraps into balanced lines rather than one-word vertical text")

func _normal_layout_snapshot(chat) -> Array:
	return [chat.empty_logo.get_global_rect(), chat.empty_title.get_global_rect(), chat.empty_description.get_global_rect(), chat.empty_mode_hint.get_global_rect(), chat.chat_scroll.get_global_rect(), chat.composer.get_global_rect()]

func _settle() -> void:
	for frame in 5:
		await process_frame

func _remember(key: String) -> void:
	originals[key] = {"exists": editor.has_setting(key), "value": editor.get_setting(key) if editor.has_setting(key) else null}

func _restore_preferences() -> void:
	if editor == null:
		return
	for key in originals:
		editor.set_setting(key, originals[key]["value"] if originals[key]["exists"] else null)
	originals.clear()

func _finalize() -> void:
	_restore_preferences()
