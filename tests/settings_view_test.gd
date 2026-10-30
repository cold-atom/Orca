extends SceneTree

const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")

class FakeModelService extends Node:
	var fetches: Array[Dictionary] = []
	var cancellations := 0

	func fetch_models(provider_id: String, config: Dictionary) -> void:
		fetches.append({"provider": provider_id, "config": config.duplicate(true)})

	func cancel() -> void:
		cancellations += 1

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	get_root().size = Vector2i(300, 700)
	var view := SettingsView.new()
	get_root().add_child(view)
	await process_frame
	await process_frame

	_expect(view.settings_scroll.visible and not view.about_scroll.visible, "provider settings should be the default section")
	_expect(view.provider_tab_button.button_pressed and not view.about_tab_button.button_pressed, "the Provider tab should be selected by default")
	for button in [view.provider_tab_button, view.system_tab_button, view.about_tab_button]:
		_expect(button.icon != null and button.text.is_empty() and not button.tooltip_text.is_empty(), "section navigation should use labeled icon buttons")
	view.system_tab_button.emit_signal("pressed")
	await process_frame
	_expect(view.system_scroll.visible and not view.settings_scroll.visible and not view.about_scroll.visible, "System should replace the other sections")
	_expect(view.system_tab_button.button_pressed and not view.provider_tab_button.button_pressed and not view.about_tab_button.button_pressed, "only System should be selected")
	_expect(view.language_selector.item_count == 1 and view.language_selector.get_item_text(0) == "English" and view.language_selector.selected == 0 and view.language_selector.disabled, "language should display English without offering unsupported choices")
	_expect(view.system_scroll.is_ancestor_of(view.update_panel) and view.update_panel.get_parent() == view.language_selector.get_parent() and view.update_panel.get_index() > view.language_selector.get_index(), "General Settings should own plugin updates below Language")
	_expect(view.find_children("PluginUpdates", "", true, false).size() == 1, "Settings should create exactly one update card")
	_expect(view.get_combined_minimum_size().x <= 300.0, "System should fit the 300 px dock width")
	view.about_tab_button.emit_signal("pressed")
	await process_frame
	_expect(not view.settings_scroll.visible and not view.system_scroll.visible and view.about_scroll.visible, "the About tab should replace other settings")
	_expect(view.about_tab_button.button_pressed, "the About tab should show its selected state")
	_expect(not view.about_scroll.is_ancestor_of(view.update_panel), "About should not contain update controls")
	_expect(view.about_version_label.text == "Version 1.4.1", "the About page should read the release version from plugin.cfg")
	var compatibility := view.find_child("AboutCompatibility", true, false) as Label
	var license := view.find_child("AboutLicense", true, false) as Label
	var logo := view.find_child("AboutLogo", true, false) as TextureRect
	var support_description := view.find_child("SupportReportDescription", true, false) as Label
	var copy_report := view.find_child("CopySupportReport", true, false) as Button
	_expect(compatibility != null and compatibility.text == "Godot 4.7.2", "the About page should state supported Godot compatibility")
	_expect(license != null and license.text.contains("MIT License"), "the About page should state the plugin license")
	_expect(logo != null and logo.texture != null, "the About page should display the Orca mark")
	_expect(support_description != null and support_description.text.contains("strict-allowlist") and support_description.text.contains("excludes credentials"), "the About page should disclose the diagnostic report's privacy boundary")
	_expect(copy_report != null, "the About page should expose the privacy-safe diagnostic copy action")
	for link in [
		["AboutDocsLink", "https://www.aiorca.dev/docs/"],
		["AboutWebsiteLink", "https://www.aiorca.dev/"],
		["AboutGitHubLink", "https://github.com/cold-atom/Orca"],
		["AboutIssuesLink", "https://github.com/cold-atom/Orca/issues"],
		["AboutDiscussionsLink", "https://github.com/cold-atom/Orca/discussions"],
	]:
		var button := view.find_child(link[0], true, false) as Button
		_expect(button != null and button.tooltip_text.contains(link[1]) and not button.accessibility_name.is_empty(), "About should expose named browser links with exact destinations")
		if button != null:
			var connections := button.pressed.get_connections()
			_expect(connections.size() == 1 and connections[0]["callable"].get_bound_arguments() == [link[1]], "each About action should open its exact static URL only on click")
	view.set_support_request_metadata({"provider_type": "openai", "outcome": "failed", "interaction_mode": "work", "stage": "initial", "tools_offered": true, "failure_category": "timeout", "transport_phase": "receiving_response", "message": "PRIVATE_ERROR_SENTINEL", "base_url": "https://private.example"})
	var report_text: String = view.diagnostic_report_text()
	_expect(report_text.contains("\"orca_version\": \"1.4.1\"") and report_text.contains("\"failure_category\": \"timeout\""), "the About action should generate versioned coarse request diagnostics")
	_expect(not report_text.contains("PRIVATE_ERROR_SENTINEL") and not report_text.contains("private.example"), "the About report must not serialize unknown request or endpoint fields")
	view._on_copy_support_report_pressed()
	_expect(view.support_report_status.text == "Copied diagnostic report.", "copying diagnostics should provide visible confirmation")
	_expect(view.get_combined_minimum_size().x <= 300.0, "the Settings and About pages should fit the 300 px dock width")

	view.provider_tab_button.emit_signal("pressed")
	await process_frame
	_expect(view.settings_scroll.visible and not view.about_scroll.visible, "the Provider tab should restore provider settings")
	var provider_ids := PackedStringArray()
	for index in range(view.provider_selector.item_count):
		provider_ids.append(str(view.provider_selector.get_item_metadata(index)))
	for provider_id in ["ollama", "lmstudio", "local_openai"]:
		_expect(provider_ids.count(provider_id) == 1, provider_id + " should appear once as a first-class provider")
	view._model_service.queue_free()
	var fake_models := FakeModelService.new()
	view._model_service = fake_models
	view.add_child(fake_models)
	view.model_selector.add_item("Previous provider model")
	view._load_provider("ollama")
	_expect(view.model_selector.item_count == 0, "switching providers should clear models from the previous provider")
	_expect(view.custom_url_input.visible and view.custom_url_input.text == "http://127.0.0.1:11434/v1", "Ollama should expose its editable conventional endpoint")
	_expect(view.api_key_label.text.contains("optional") and view.api_key_input.placeholder_text.contains("Optional"), "local authentication should be presented as optional")
	_expect(view.model_search.visible and view.model_selector.visible and view.refresh_button.visible, "local profiles should expose model discovery")
	_expect(view.custom_model_input.visible, "local profiles should retain manual model entry as a fallback")
	_expect(view.agent_probe_button.visible and view.agent_enable_toggle.visible, "editable providers should expose compatibility controls")
	_expect(view.agent_enable_toggle.disabled and not view.agent_enable_toggle.button_pressed, "Agent opt-in should remain disabled before a matching probe pass")
	_expect(view._agent_probe != null and not view._agent_probe.is_running(), "compatibility probing must never start automatically")
	_expect(view.agent_probe_button.text == "Test & Enable Agent tools" and view.agent_probe_button.tooltip_text.contains("only if it passes"), "the explicit check action should disclose automatic enablement on success")
	_expect(view.agent_warning_label.text.contains("enables Agent tools when it passes"), "the existing help should explain the combined action")
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure"]:
		view._load_provider(provider_id)
		await process_frame
		_expect(view.get_combined_minimum_size().x <= 300.0, provider_id + " settings should fit the 300 px dock with editable-endpoint controls visible")
	view._load_provider("azure")
	_expect(view.api_mode_selector.visible and view._selected_api_mode == "responses" and view.custom_model_input.placeholder_text.contains("deployment"), "Foundry should default to Responses and exact deployment names")
	_expect(view.continuation_selector.visible and view.continuation_selector.tooltip_text.contains("Chat or Responses"), "DeepSeek compatibility must be explicitly available for both Azure protocols")
	_expect(view.effort_selector.visible and view._current_form_config().get("api_mode") == "responses", "manual Azure deployments should expose explicit reasoning settings")
	view._on_api_mode_selected(1)
	view._on_continuation_selected(1)
	_expect(view.continuation_selector.visible and view._current_form_config().get("continuation_style") == "deepseek" and view._current_form_config().get("api_mode") == "chat_completions", "Azure Chat should permit explicit DeepSeek continuation")
	view._set_efforts([], "none")
	_expect(view._current_form_config().get("reasoning_effort") == "none", "explicit None must survive manual-model refresh and probe snapshots")
	view._on_manual_model_changed("custom-deployment-name")
	_expect(view._selected_effort == "none" and view._selected_api_mode == "chat_completions" and view._continuation_style == "deepseek", "editing deployment names must preserve explicit request options")
	view._load_provider("ollama")
	view.custom_model_input.text = "manual-embed-model"
	view._on_manual_model_changed("manual-embed-model")
	_expect(view._selected_model == "manual-embed-model", "manual Model ID should remain an unrestricted discovery override")
	view._on_models_loaded("ollama", [{"id": "chat-model", "name": "Chat Model"}], false)
	var listed_ids := PackedStringArray()
	for item_index in range(view.model_selector.item_count):
		listed_ids.append(str(view.model_selector.get_item_metadata(item_index)))
	_expect("manual-embed-model" in listed_ids, "a current manual model omitted by discovery should remain selectable")
	view._selected_model = ""
	view._on_models_loaded("ollama", [{"id": "first-chat", "name": "First Chat"}, {"id": "second-chat", "name": "Second Chat"}], false)
	_expect(view.model_selector.item_count == 2 and view._current_models.size() == 2, "selecting the first discovered model must not trigger the manual override handler or clear the list")
	_expect(fake_models.fetches.is_empty(), "opening local settings should not contact an endpoint without an explicit Refresh action")
	view._refresh_models()
	_expect(fake_models.fetches.size() == 1 and fake_models.fetches[0].get("config", {}).get("api_key") == "", "explicit local model discovery should permit an empty API key")
	view._current_models = [{"id": "stale", "name": "Stale"}]
	view.model_selector.add_item("Stale")
	view._on_custom_url_changed("http://127.0.0.1:11435/v1")
	_expect(view._current_models.is_empty() and view.model_selector.item_count == 0, "changing endpoints should clear models from the previous server")
	view.custom_url_input.text = "http://192.168.1.20:11434/v1"
	view._refresh_models()
	_expect(view._trust_dialog.visible and fake_models.fetches.size() == 1, "unconfirmed LAN discovery should open consent without contacting the endpoint")
	view.custom_url_input.text = "http://192.168.1.21:11434/v1"
	view._on_endpoint_trust_confirmed()
	_expect(fake_models.fetches.size() == 1 and view.status_label.text.contains("changed"), "confirmation must not authorize endpoint text changed while the dialog was open")
	view.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("settings_view_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("settings_view_test: ", failure)
	quit(1)
