@tool
extends "res://tests/editor_test_case.gd"

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const ChangeCard = preload("res://addons/orca/scripts/change_card.gd")
const SceneCard = preload("res://addons/orca/scripts/scene_change_card.gd")
const OLD := "extends Node\nconst VALUE = 1\n"
const NEW := "extends Node\nconst VALUE = 2\n"

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	func _refresh_model_metadata() -> void: pass
	func _restore_active_session() -> void:
		_session = session_store.create_session(1, "openai", "gpt-4o-mini")

class Client extends Node:
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	var requests: Array = []
	var requesting := false
	func send_chat_completion(messages: Array, tools: Array, profile: Dictionary, options: Dictionary) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "profile": profile.duplicate(true), "options": options.duplicate(true)})
		requesting = true
	func is_requesting() -> bool: return requesting
	func last_request_may_have_usage() -> bool: return false
	func complete(message: Dictionary) -> void:
		requesting = false
		request_completed.emit(int(requests[-1]["options"]["lifecycle_request_id"]), {"choices": [{"message": message, "finish_reason": "tool_calls" if message.has("tool_calls") else "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
	func cancel_request() -> void:
		requesting = false
		request_cancelled.emit(int(requests[-1]["options"]["lifecycle_request_id"]))

class Discovery extends Node:
	func cancel() -> void: pass
	func fetch_models(_provider: String, _profile: Dictionary) -> void: pass

var failures: Array[String] = []
var view
var client: Client
var path := "res://tests/localization_fixture.gd"


func _init() -> void: call_deferred("_run")


func check(value: bool, description: String) -> void:
	if not value: failures.append(description)


func settle() -> void:
	for frame in 10: await process_frame


func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	await create_timer(0.5).timeout
	root.size = Vector2i(Metrics.scaled_int(1200), Metrics.scaled_int(950))
	var phase := OS.get_environment("ORCA_LOCALIZATION_TEST_PHASE")
	var expected_locale := "ko" if phase == "restart_ko" else "ja" if phase == "restart" else "en"
	check(Config.get_ui_language() == expected_locale, "language is English initially and persists after a clean editor restart")
	check(Localization.language() == Config.get_ui_language(), "plugin startup loads the saved Orca language")
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	view = ChatScene.instantiate()
	view.set_script(FixtureChat)
	root.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	view.size = Metrics.scaled_vector(Vector2(300, 850))
	await settle()
	client = Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.settings_view._model_service.cancel()
	view.settings_view._model_service.queue_free()
	view.settings_view._model_service = Discovery.new()
	view.settings_view.add_child(view.settings_view._model_service)
	if phase in ["restart", "restart_ko"]:
		var index: int = Localization.LOCALES.find(expected_locale)
		check(view.settings_view.language_selector.selected == index and view.settings_view.language_selector.get_item_text(index) == Localization.LANGUAGE_NAMES[index], "saved selection is restored in a new editor process: " + expected_locale)
		check(view.settings_view.done_button.atr(view.settings_view.done_button.text) == {"ja": "完了", "ko": "완료"}[expected_locale], "newly constructed controls render the saved language")
		check(Localization.select_language("ko" if phase == "restart" else "en"), "save the next restart language")
		await finish(phase)
		return
	var editor_locale := TranslationServer.get_tool_locale()
	var project_locale := TranslationServer.get_locale()
	var project_bytes := FileAccess.get_file_as_bytes("res://project.godot")
	var key := Config.get_api_key()
	var permission := Config.project_script_edit_preference().duplicate(true)
	view.prompt_input.text = "Settings\nKeep this draft"
	view.prompt_input.select(0, 0, 0, 8)
	var picture := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	picture.fill(Color.WHITE)
	view._draft_images = [preload("res://addons/orca/scripts/image_attachments.gd").prepare_image(picture)["image"]]
	view._draft_script_paths = [path]
	view._refresh_attachment_tray()
	view._refresh_script_reference_tray()
	var user_label: RichTextLabel = view._add_message("User", "Settings", Color.WHITE, "user")
	var answer: RichTextLabel = view._add_message("Orca", "Settings", Color.WHITE, "assistant")
	var notice: RichTextLabel = view._add_message("History", "Response stopped.", Color.WHITE, "status")
	var long_notice: RichTextLabel = view._add_message("History", "This interrupted or truncated session is view-only. Start a new chat to continue.", Color.WHITE, "status")
	view.task_list_panel.set_tasks([{"content": "Settings", "status": "in_progress"}])
	var card := ChangeCard.new()
	view.chat_feed.add_child(card)
	card.configure({"id": "presentation", "filepath": path, "existed": true, "old_content": OLD, "new_content": NEW, "validation": {"message": "Passed"}})
	var proposal := card._proposal.duplicate(true)
	card._show_expanded_diff()
	var expanded: Window
	for child in card.get_children():
		if child is Window: expanded = child
	await settle()
	view.settings_view.show()
	view.main_content.hide()
	view.settings_view._show_section("system")
	for locale in ["zh_CN", "es", "ja", "ko", "en"]:
		var index: int = Localization.LOCALES.find(locale)
		view.settings_view.language_selector.select(index)
		view.settings_view.language_selector.item_selected.emit(index)
		await settle()
		check(Localization.language() == locale and Config.get_ui_language() == locale, "native selector applies and saves " + locale)
		check(view.settings_view.done_button.atr("Done") == {"en": "Done", "zh_CN": "完成", "es": "Listo", "ja": "完了", "ko": "완료"}[locale], "native controls use Orca's domain for " + locale)
		check(TranslationServer.get_locale() == project_locale and TranslationServer.get_tool_locale() == editor_locale, "switching does not change project or editor locale")
		check(view.prompt_input.text == "Settings\nKeep this draft" and view.prompt_input.get_selected_text() == "Settings", "draft text and selection survive switching")
		check(view._draft_images.size() == 1 and view._draft_script_paths == [path], "image and script drafts survive switching")
		check(user_label.get_parsed_text().ends_with("Settings") and answer.get_parsed_text().ends_with("Settings"), "user and assistant text are not translated even when equal to a catalog key")
		check(view.task_list_panel.get_tasks()[0]["content"] == "Settings", "model-generated task content remains canonical")
		check(notice.get_parsed_text().contains(Localization.message("Response stopped.")), "Orca-owned notices refresh without rewriting history")
		check(long_notice.custom_minimum_size.y >= ceilf(long_notice.get_content_height()), "translated multi-line notices refit their height without clipping")
		check(card._proposal == proposal and card._apply_button.visible and expanded.visible, "open review and proposal identity survive switching without authorization")
		check(card._title_label.text.contains(path.get_file()) and card._path_label.text == path and card._title_label.tooltip_text == path and card._validation_label.text.contains(Localization.message("Passed")), "formatted review labels refresh and preserve basename/full path")
		check(not view.agent_controller.auto_apply_enabled() and Config.project_script_edit_preference() == permission, "language selection cannot grant or remember edit permission")
		for multiplier in [1.0, 1.5, 2.0]:
			_fonts(view.settings_view, multiplier)
			await settle()
			check(view.settings_view.size.x <= Metrics.scaled(300) + 1 and view.settings_view.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "Settings fit a real 300-unit dock at %s %.1fx fonts (minimum %.1f)" % [locale, multiplier, view.settings_view.get_combined_minimum_size().x / Metrics.editor_scale()])
			check(view.settings_view.system_scroll.get_global_rect().grow(1).encloses(view.settings_view.language_selector.get_global_rect()), "language selector remains inside its scroller")
	_fonts(view.settings_view, 1.0)
	card._dismiss_expanded_diff(expanded)
	view.settings_view.hide()
	view.main_content.show()
	check(FileAccess.get_file_as_bytes("res://project.godot") == project_bytes and Config.get_api_key() == key, "switching preserves project bytes and provider credentials")
	check(Localization.message("No translation for this sentinel") == "No translation for this sentinel", "missing translations fall back to source English")
	check(not Localization.select_language("../unexpected") and not Config.set_ui_language("zh_TW"), "only supported exact locale choices are accepted")
	# Identity text may equal an old English UI fallback; explicitly clear its
	# binding rather than inferring from whether the rendered bytes changed.
	Localization.select_language("en")
	settings.set_setting("orca/providers/openai/model", "")
	view._sync_model_ui()
	settings.set_setting("orca/providers/openai/model", "No model")
	view._sync_model_ui()
	Localization.select_language("es")
	check(view.model_label.text == "No model" and not view.model_label.can_auto_translate(), "a real model named like the previous UI fallback retains its exact identity")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	view._sync_model_ui()
	settings.set_setting(Config.SETTING_UI_LANGUAGE, {"language": "es"})
	check(Config.get_ui_language() == "en", "malformed saved language falls back to English")
	Localization.select_language("zh_CN")
	await _presentation_surfaces()
	await _turn_and_permissions()
	Localization.select_language("ja")
	await finish(phase)


func _presentation_surfaces() -> void:
	view.settings_view._current_provider = "orca_cloud"
	view.settings_view._selected_model = "Settings"
	view.settings_view._on_models_loaded("orca_cloud", [{"id": "Settings", "name": "Settings", "allowed": true, "availability": "available", "context_window": 65536}, {"id": "other", "name": "other", "allowed": false, "availability": "available"}], false)
	var popup: PopupMenu = view.settings_view.model_selector.get_popup()
	for locale in ["es", "zh_CN", "ja", "ko", "en"]:
		Localization.select_language(locale)
		await settle()
		check(not view.settings_view.model_selector.can_auto_translate() and popup.get_item_text(0) == "Settings", "model names are never translated as interface keys")
		check(popup.get_item_text(1) == Localization.message("%s — subscription required") % "other", "subscription captions refresh without changing model identity")
		check(view.settings_view._selected_model == "Settings" and view.settings_view.model_selector.get_item_metadata(0) == "Settings", "translation never changes selected model or metadata")
		check(view.settings_view.metadata_label.text.begins_with(Localization.message("Context: %s").split("%s")[0]), "model metadata refreshes its translated template")
	view.settings_view._on_models_loaded("orca_cloud", [{"id": "Settings", "name": "Settings", "allowed": true, "availability": "available"}, {"id": "changed", "name": "other — subscription required", "allowed": true, "availability": "available"}], false)
	Localization.select_language("es")
	check(popup.get_item_text(1) == "other — subscription required", "repopulated model choices cannot retain an obsolete caption binding")
	view.settings_view._select_provider("azure")
	view.settings_view.show()
	view.main_content.hide()
	for locale in ["es", "zh_CN", "ja", "ko", "en"]:
		Localization.select_language(locale)
		for section in ["provider", "about", "system"]:
			view.settings_view._show_section(section)
			for multiplier in [1.0, 1.5, 2.0]:
				_fonts(view.settings_view, multiplier)
				await settle()
				check(view.settings_view.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "%s Settings fit at %s %.1fx fonts (%.1f units)" % [section, locale, multiplier, view.settings_view.get_combined_minimum_size().x / Metrics.editor_scale()])
				if view.settings_view.get_combined_minimum_size().x > Metrics.scaled(300) + 1:
					_report_wide_controls(view.settings_view)
				if section == "about":
					for name in ["AboutDocsLink", "AboutWebsiteLink", "AboutGitHubLink", "AboutIssuesLink", "AboutDiscussionsLink"]:
						var link: Button = view.settings_view.find_child(name, true, false)
						for label in link.get_parent().find_children("*", "Label", true, false):
							check(link.get_parent().get_global_rect().grow(1).encloses(label.get_global_rect()), "translated About text stays in its clickable background")
				if multiplier == 1.0:
					_capture_preview(locale + "-" + section)
	_fonts(view.settings_view, 1.0)
	view.settings_view.hide()
	view.main_content.show()
	var scene := SceneCard.new()
	view.chat_feed.add_child(scene)
	scene.configure({"id": "scene", "filepath": "res://target.tscn", "approval_stage": "script_trust", "validation": {"message": "Passed"}, "scene_summary": {"operation": "attach_script", "node_path": "Settings", "script_path": path}})
	var history = view.history_view
	history.set_sessions([{"id": "historical", "title": "Settings", "last_prompt": "Settings", "mode": 0, "model": "Settings", "changed_file_count": 2, "clean": false}], "")
	var group = preload("res://addons/orca/scripts/tool_activity_group.gd").new()
	view.chat_feed.add_child(group)
	var activity = group.add_tool("api", "inspect_godot_api", {"class_name": "Node"})
	group.complete_tool("api", {"outcome": "completed", "content": "Settings", "data": {"help_topic": "class_name:Node"}}, 1200)
	group.set_expanded(true)
	activity._toggle_details()
	var subtree = preload("res://addons/orca/scripts/tool_activity_card.gd").new()
	view.chat_feed.add_child(subtree)
	subtree.configure("inspect_editor_scene", {"scope": "subtree", "node_path": "Selected nodes"})
	for locale in ["es", "zh_CN", "ja", "ko", "en"]:
		Localization.select_language(locale)
		for multiplier in [1.0, 1.5, 2.0]:
			_fonts(scene, multiplier)
			_fonts(group, multiplier)
			_fonts(history, multiplier)
			await settle()
			check(scene.get_combined_minimum_size().x <= Metrics.scaled(280) + 1 and group.get_combined_minimum_size().x <= Metrics.scaled(280) + 1 and history.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "review/activity/History fit translated larger-font layouts (%s %.1fx; scene %.1f, activity %.1f, history %.1f)" % [locale, multiplier, scene.get_combined_minimum_size().x / Metrics.editor_scale(), group.get_combined_minimum_size().x / Metrics.editor_scale(), history.get_combined_minimum_size().x / Metrics.editor_scale()])
		check(scene._find_details(scene).text.contains("Settings") and scene._find_details(scene).text.contains(path) and scene._apply_button.visible, "translated execution-trust review preserves exact node/script identities and approval")
		check(activity._details.text == "Settings" and not activity._details.can_auto_translate(), "raw diagnostic/tool evidence is not translated")
		check(activity._header_button.text.contains(Localization.message("Inspect Godot API")), "tool activity heading refreshes")
		check(subtree._header_button.text.ends_with("  Selected nodes"), "a subtree path equal to a scope caption is still an original path")
	Localization.select_language("zh_CN")


func _turn_and_permissions() -> void:
	view._draft_images.clear()
	view._draft_script_paths.clear()
	view.agent_controller.set_mode(0)
	var connection := func(_id: int, active: bool):
		if active: Localization.select_language("es")
	view.agent_controller.request_state_changed.connect(connection, CONNECT_ONE_SHOT)
	check(view.agent_controller.send_user_message("请检查项目"), "start a Chinese Plan turn")
	check(_language_count(client.requests[-1]["messages"], "Simplified Chinese") == 1, "language is captured before reentrant request-start signals")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("mode", "request_work_mode", {"reason": "Implement the requested change"})]})
	var turn_id: int = view.agent_controller._active_turn_id
	Localization.select_language("en")
	check(view.agent_controller.get_mode() == 0, "language switching cannot approve a pending Work transition")
	view.agent_controller.resolve_work_mode_request("mode", turn_id, true)
	await settle()
	check(view.agent_controller.get_mode() == 1 and _language_count(client.requests[-1]["messages"], "Simplified Chinese") == 1, "approved Plan-to-Work continuation retains the turn language")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(OLD)
	file.close()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("patch", "apply_patch", {"filepath": path, "base_hash": OLD.sha256_text(), "edits": [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}]})]})
	await settle()
	check(FileAccess.get_file_as_string(path) == OLD and view.agent_controller._pending_change_id == "patch", "Work patch still waits for original-proposal approval")
	var pending = view._change_cards.get("patch")
	check(pending != null, "pending change has a real review card")
	Localization.select_language("ko")
	check(FileAccess.get_file_as_string(path) == OLD and view.agent_controller._pending_change_id == "patch", "switching language cannot resolve the suspended patch")
	if pending != null: pending._apply_button.pressed.emit()
	await settle()
	check(FileAccess.get_file_as_string(path) == NEW, "translated review action applies through normal validation and approval")
	check(_language_count(client.requests[-1]["messages"], "Simplified Chinese") == 1, "tool follow-up keeps the original response language")
	var receipts: Array = client.requests[-1]["messages"].filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == "patch")
	check(receipts.size() == 1 and str(receipts[0].get("content", "")).contains("Applied"), "locale switching preserves exactly one original English protocol receipt")
	client.complete({"role": "assistant", "content": "修改完成。"})
	await settle()
	check(_language_count(view.agent_controller.message_history, "Simplified Chinese") == 0 and not JSON.stringify(view.agent_controller.snapshot_session_state()).contains("RESPONSE LANGUAGE"), "turn language is removed from canonical and persisted continuation")
	if pending != null: pending._revert_button.pressed.emit()
	await settle()
	check(FileAccess.get_file_as_string(path) == OLD, "translated Revert restores original bytes")
	for locale in ["ja", "ko"]:
		var language: String = {"ja": "Japanese", "ko": "Korean"}[locale]
		var prompt: String = {"ja": "次のタスク", "ko": "다음 작업"}[locale]
		var call_id: String = "read-" + locale
		Localization.select_language(locale)
		check(view.agent_controller.send_user_message(prompt), "start a turn: " + language)
		check(_language_count(client.requests[-1]["messages"], language) == 1, "next turn captures the selected language: " + language)
		Localization.select_language("es")
		client.complete({"role": "assistant", "content": "", "tool_calls": [_call(call_id, "read_file", {"filepath": path})]})
		await settle()
		check(_language_count(client.requests[-1]["messages"], language) == 1 and _language_count(client.requests[-1]["messages"], "Spanish") == 0, "tool continuation retains its turn language after a live switch: " + language)
		var read_receipts: Array = client.requests[-1]["messages"].filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == call_id)
		check(read_receipts.size() == 1 and str(read_receipts[0].get("content", "")).contains("1 | extends Node") and str(read_receipts[0].get("content", "")).contains("2 | const VALUE = 1") and str(read_receipts[0].get("content", "")).contains("SHA-256: " + OLD.sha256_text()), "turn preserves a matching original-source tool receipt: " + language)
		view.agent_controller.cancel_current_request()
		await settle()
		check(not view.agent_controller.is_busy() and _language_count(view.agent_controller.message_history, language) == 0 and not JSON.stringify(view.agent_controller.snapshot_session_state()).contains("RESPONSE LANGUAGE"), "cancellation cleans up response-language context: " + language)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".uid"))


func _language_count(messages: Array, language: String) -> int:
	return messages.filter(func(message): return message.get("role") == "system" and str(message.get("content", "")).contains("RESPONSE LANGUAGE:") and str(message.get("content", "")).contains("use " + language + ".")).size()


func _call(id: String, name: String, arguments: Dictionary) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": name, "arguments": JSON.stringify(arguments)}}


func _fonts(node: Node, multiplier: float) -> void:
	if node is Control and (node is Label or node is BaseButton):
		if not node.has_meta("fixture_font"):
			node.set_meta("fixture_font", node.get_theme_font_size("font_size"))
		node.add_theme_font_size_override("font_size", roundi(int(node.get_meta("fixture_font")) * multiplier))
	for child in node.get_children(): _fonts(child, multiplier)


func _report_wide_controls(node: Node) -> void:
	if node is Control and node.is_visible_in_tree() and node.get_combined_minimum_size().x > Metrics.scaled(300) + 1:
		print("Wide translated control: ", node.get_path(), " ", node.get_combined_minimum_size().x / Metrics.editor_scale())
	for child in node.get_children(): _report_wide_controls(child)


func _capture_preview(name: String) -> void:
	var folder := OS.get_environment("ORCA_TRANSLATION_PREVIEW_DIR")
	if DisplayServer.get_name() == "headless" or folder.is_empty() or not DirAccess.dir_exists_absolute(folder):
		return
	var image := root.get_texture().get_image()
	image.get_region(Rect2i(view.get_global_rect())).save_png(folder.path_join(name + ".png"))


func finish(phase: String) -> void:
	view._session = {}
	view._has_session_content = false
	view.queue_free()
	await settle()
	for failure in failures: printerr("localization_editor_test: " + failure)
	print("localization_editor_test: %d failures (%s)" % [failures.size(), phase])
	quit(0 if failures.is_empty() else 1)
