extends SceneTree

const Config = preload("res://addons/orca/scripts/config.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")
const RequestTimeouts = preload("res://addons/orca/scripts/request_timeouts.gd")

class FakeProbe extends Node:
	signal probe_step_changed(step: int)
	signal probe_passed(binding: Dictionary)
	signal probe_failed(binding: Dictionary, message: String)
	signal probe_cancelled
	var running := false
	var starts := 0
	var reject_start := false
	var binding: Dictionary = {}

	func start_probe(config: Dictionary) -> bool:
		starts += 1
		if reject_start:
			return false
		running = true
		binding = Probe.create_binding(config).get("binding", {}).duplicate(true)
		probe_step_changed.emit(1)
		return true

	func is_running() -> bool:
		return running

	func cancel() -> void:
		running = false
		probe_cancelled.emit()

	func pass_check() -> void:
		running = false
		probe_passed.emit(binding.duplicate(true))

	func fail_check() -> void:
		running = false
		probe_failed.emit(binding.duplicate(true), "synthetic check failure")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var settings := EditorInterface.get_editor_settings()
	var keys := PackedStringArray([Config.SETTING_PROVIDER, Config.SETTING_PROVIDER_MODEL_CACHE])
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure", "openai", "gemini", "deepseek", "orca_cloud"]:
		for field in ["api_key", "model", "reasoning_effort", "base_url", "confirmed_origin", "agent_compatibility", "api_mode", "continuation_style", RequestTimeouts.RESPONSE_START_FIELD, RequestTimeouts.INACTIVITY_FIELD, RequestTimeouts.CUSTOM_ENABLED_FIELD]:
			keys.append(Config._provider_setting(provider_id, field))
	var original := {}
	for key in keys:
		original[key] = settings.get_setting(key) if settings.has_setting(key) else null
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure", "orca_cloud"]:
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.RESPONSE_START_FIELD), null)
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.INACTIVITY_FIELD), null)
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.CUSTOM_ENABLED_FIELD), null)
	for provider_id in ["openai", "gemini", "deepseek"]:
		settings.set_setting(Config._provider_setting(provider_id, "api_key"), "")
	settings.set_setting(Config.SETTING_PROVIDER, "ollama")

	Config.save_provider_profile("ollama", "", "qwen-fixture", "default", "http://127.0.0.1:11434/v1")
	Config.save_provider_profile("lmstudio", "lm-secret", "llama-fixture", "low", "http://127.0.0.1:1234/v1")
	Config.save_provider_profile("local_openai", "", "custom-fixture", "default", "http://127.0.0.1:18080/v1")
	var ollama := Config.get_provider_config("ollama")
	_expect(Config.save_provider_profile("azure", "synthetic-key", "custom-gpt-deployment", "high", "http://127.0.0.1:18473/foundry", "responses"), "Azure Responses profile should save")
	var azure := Config.get_provider_config("azure")
	_expect(azure.get("api_mode") == "responses" and azure.get("model") == "custom-gpt-deployment" and azure.get("reasoning_effort") == "high", "Azure API and exact deployment options should persist independently")
	_expect(not Config.save_provider_profile("azure", "replacement", "wrong", "none", "http://127.0.0.1:18473/foundry", "invalid"), "invalid transport must reject the whole settings update")
	_expect(Config.get_provider_config("azure") == azure, "invalid transport must not overwrite credential or deployment settings")
	_expect(Config.save_provider_profile("azure", "synthetic-key", "DeepSeek-V4-Pro", "default", "http://127.0.0.1:18473/foundry", "chat_completions", "deepseek"), "Azure DeepSeek continuation style should save")
	_expect(Config.get_provider_config("azure").get("continuation_style") == "deepseek", "Azure DeepSeek continuation style should restore")
	var lmstudio := Config.get_provider_config("lmstudio")
	var local := Config.get_provider_config("local_openai")
	_expect(ollama.get("api_key") == "" and ollama.get("model") == "qwen-fixture" and ollama.get("base_url") == "http://127.0.0.1:11434/v1", "Ollama should persist an isolated keyless profile")
	_expect(lmstudio.get("api_key") == "lm-secret" and lmstudio.get("model") == "llama-fixture" and lmstudio.get("base_url") == "http://127.0.0.1:1234/v1", "LM Studio should persist an isolated optionally authenticated profile")
	_expect(local.get("model") == "custom-fixture" and local.get("base_url") == "http://127.0.0.1:18080/v1", "generic local settings should persist an independent editable endpoint")
	Config.set_confirmed_origin("ollama", "http://192.168.1.20:11434")
	_expect(Config.get_confirmed_origin("ollama") == "http://192.168.1.20:11434" and Config.get_confirmed_origin("lmstudio") != "http://192.168.1.20:11434", "endpoint trust should persist per provider")
	_expect(EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11434/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", false), "persisted exact-origin trust should authorize that provider")
	_expect(not EndpointPolicy.authorize_profile("ollama", {"base_url": "http://192.168.1.20:11435/v1", "confirmed_origin": Config.get_confirmed_origin("ollama")}).get("success", true), "changing the trusted port should require confirmation again")
	var before_invalid := Config.get_provider_config("ollama")
	_expect(not Config.save_provider_profile("ollama", "replacement-secret", "replacement-model", "high", "not a URL"), "invalid endpoint drafts should fail atomically")
	_expect(Config.get_provider_config("ollama") == before_invalid, "invalid endpoint drafts must not pair new credentials with the previous endpoint")
	var binding_result := preload("res://addons/orca/scripts/agent_compatibility_probe.gd").create_binding(Config.get_provider_config("ollama"))
	_expect(binding_result.get("success", false) and Config.record_agent_probe_pass(binding_result.get("binding", {})), "a successful probe binding should persist")
	var disabled_status := Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama"))
	_expect(disabled_status.get("passed", false) and not disabled_status.get("enabled", true), "recording a pass alone must remain disabled without user enablement intent")
	_expect(Config.set_agent_enabled("ollama", Config.get_provider_config("ollama"), true), "explicit opt-in should enable an exact passed binding")
	_expect(Config.agent_compatibility_status("ollama", Config.get_provider_config("ollama")).get("enabled", false), "matching enabled state should be returned to request snapshots")
	var changed_model := Config.get_provider_config("ollama")
	changed_model["model"] = "different-case-sensitive-model"
	_expect(not Config.agent_compatibility_status("ollama", changed_model).get("enabled", true), "model changes should invalidate persisted Agent compatibility")
	var cache_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	var oversized_models := []
	for index in range(Config.MAX_CACHED_PROVIDER_MODELS + 20):
		oversized_models.append({"id": "model-%d" % index})
	settings.set_setting(Config.SETTING_PROVIDER_MODEL_CACHE, {cache_key: {"fetched_at": "invalid", "models": oversized_models, "oversized_extra": "x".repeat(10000)}})
	var bounded_cache := Config.get_cached_provider_models("ollama", "http://127.0.0.1:11434/api/tags", "empty")
	_expect(bounded_cache.keys().size() == 2 and bounded_cache.get("fetched_at") == 0.0 and bounded_cache.get("models", []).size() == Config.MAX_CACHED_PROVIDER_MODELS, "provider cache envelopes should retain only bounded models and a type-checked timestamp")
	await _test_one_click_enablement()
	await _test_timeout_settings(settings)

	for key in keys:
		settings.set_setting(key, original[key])
	_finish()


func _test_one_click_enablement() -> void:
	var view := SettingsView.new()
	get_root().add_child(view)
	await process_frame
	view._agent_probe.queue_free()
	var fake := FakeProbe.new()
	view._agent_probe = fake
	view.add_child(fake)
	fake.probe_step_changed.connect(view._on_probe_step_changed)
	fake.probe_passed.connect(view._on_probe_passed)
	fake.probe_failed.connect(view._on_probe_failed)
	fake.probe_cancelled.connect(view._on_probe_cancelled)
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure"]:
		Config.save_provider_profile(provider_id, "synthetic-key", "synthetic-model", "default", "http://127.0.0.1:18473/v1")
		Config.clear_agent_compatibility(provider_id)
		view._load_provider(provider_id)
		view.agent_probe_button.pressed.emit()
		_expect(fake.running and not view.agent_enable_toggle.button_pressed and view.agent_enable_toggle.disabled, "tools should stay off while checking " + provider_id)
		fake.pass_check()
		var passed_binding := fake.binding.duplicate(true)
		_expect(view.agent_enable_toggle.button_pressed and not view.agent_enable_toggle.disabled and Config.agent_compatibility_status(provider_id, Config.get_provider_config(provider_id)).get("enabled", false), "one click and an exact pass should enable and persist tools for " + provider_id)
		_expect(view._agent_enable_intent.is_empty(), "success must consume the memory-only enablement intent")
		view._on_agent_enable_toggled(false)
		view._load_provider(provider_id)
		fake.probe_passed.emit(passed_binding)
		_expect(not view.agent_enable_toggle.button_pressed and not Config.agent_compatibility_status(provider_id, Config.get_provider_config(provider_id)).get("enabled", true), "reopening or duplicate success must preserve manual opt-out")
		view.agent_probe_button.pressed.emit()
		fake.fail_check()
		_expect(not view.agent_enable_toggle.button_pressed and view.agent_enable_toggle.disabled and view._agent_enable_intent.is_empty(), "failure must not enable tools")
		view.agent_probe_button.pressed.emit()
		fake.cancel()
		fake.probe_passed.emit(fake.binding)
		_expect(not view.agent_enable_toggle.button_pressed and view._agent_enable_intent.is_empty(), "cancellation and late success must not enable tools")
		view.agent_probe_button.pressed.emit()
		var stale := fake.binding.duplicate(true)
		view.custom_model_input.text = "changed-model"
		view.custom_model_input.text_changed.emit("changed-model")
		fake.probe_passed.emit(stale)
		_expect(not view.agent_enable_toggle.button_pressed and Config.get_agent_compatibility(provider_id).is_empty(), "model drift must invalidate automatic enablement")

	view._load_provider("azure")
	fake.reject_start = true
	view.agent_probe_button.pressed.emit()
	_expect(view._agent_enable_intent.is_empty() and not view.agent_enable_toggle.button_pressed and not view.done_button.disabled, "a rejected start must discard intent and restore controls")
	fake.reject_start = false
	view.custom_timeouts_toggle.button_pressed = true
	view.agent_probe_button.pressed.emit()
	var timeout_stale := fake.binding.duplicate(true)
	view.response_start_timeout_input.value = 90
	fake.probe_passed.emit(timeout_stale)
	_expect(not fake.running and not view.agent_enable_toggle.button_pressed and view._agent_enable_intent.is_empty(), "editing timeout values must cancel a running check and reject late enablement")
	view.agent_probe_button.pressed.emit()
	timeout_stale = fake.binding.duplicate(true)
	view.stream_inactivity_timeout_input.get_line_edit().text_changed.emit("120")
	fake.probe_passed.emit(timeout_stale)
	_expect(not fake.running and not view.agent_enable_toggle.button_pressed, "typed timeout edits must invalidate probe intent before their SpinBox value commits")
	view.agent_probe_button.pressed.emit()
	timeout_stale = fake.binding.duplicate(true)
	view.custom_timeouts_toggle.button_pressed = false
	fake.probe_passed.emit(timeout_stale)
	_expect(not fake.running and view._agent_enable_intent.is_empty() and not view.agent_enable_toggle.button_pressed, "turning custom timing off during a check must cancel pending enablement and reject late success")
	view.custom_timeouts_toggle.button_pressed = true
	view.agent_probe_button.pressed.emit()
	var mismatched := fake.binding.duplicate(true)
	mismatched["model"] = "wrong-result-model"
	fake.running = false
	fake.probe_passed.emit(mismatched)
	_expect(Config.get_agent_compatibility("azure").is_empty() and not view.agent_enable_toggle.button_pressed, "an unmatched returned binding must not authorize tools even while intent is pending")
	view.agent_probe_button.pressed.emit()
	var stale := fake.binding.duplicate(true)
	view.api_key_input.text = "changed-synthetic-key"
	view.api_key_input.text_changed.emit("changed-synthetic-key")
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed and Config.get_agent_compatibility("azure").is_empty(), "credential changes must cancel enablement intent")
	view.agent_probe_button.pressed.emit()
	stale = fake.binding.duplicate(true)
	view._on_api_mode_selected(1)
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed, "API changes must not accept a prior pass")
	view.agent_probe_button.pressed.emit()
	stale = fake.binding.duplicate(true)
	view._on_continuation_selected(1)
	fake.probe_passed.emit(stale)
	_expect(not view.agent_enable_toggle.button_pressed, "continuation-style changes must not accept a prior pass")
	view.agent_probe_button.pressed.emit()
	fake.pass_check()
	view._save_current_profile()
	view._load_provider("custom")
	view._load_provider("azure")
	_expect(view._selected_api_mode == "chat_completions" and view._continuation_style == "deepseek" and view.agent_enable_toggle.button_pressed, "switching providers must retain the exact enabled Azure API/style profile")

	view.custom_url_input.text = "http://192.0.2.1:18473/v1"
	view.custom_url_input.text_changed.emit(view.custom_url_input.text)
	Config.set_confirmed_origin("azure", "")
	var starts := fake.starts
	view.agent_probe_button.pressed.emit()
	_expect(view._trust_dialog.visible and fake.starts == starts, "origin confirmation must precede the check and enablement")
	view.custom_model_input.text = "changed-while-confirming"
	view.custom_model_input.text_changed.emit("changed-while-confirming")
	view._trust_dialog.hide()
	view._on_endpoint_trust_confirmed()
	_expect(fake.starts == starts and not view.agent_enable_toggle.button_pressed, "profile edits during origin confirmation must discard enablement intent")
	Config.set_confirmed_origin("azure", "")
	view.agent_probe_button.pressed.emit()
	view._trust_dialog.hide()
	view._on_endpoint_trust_cancelled()
	_expect(view._agent_enable_intent.is_empty() and fake.starts == starts, "cancelled origin confirmation must discard enablement intent")
	view.agent_probe_button.pressed.emit()
	view._trust_dialog.hide()
	view._on_endpoint_trust_confirmed()
	fake.pass_check()
	_expect(fake.starts == starts + 1 and view.agent_enable_toggle.button_pressed, "unchanged explicit intent should survive origin confirmation and enable only on pass")
	view.queue_free()
	await process_frame


func _test_timeout_settings(settings: EditorSettings) -> void:
	for provider_id in ["ollama", "lmstudio", "local_openai", "custom", "azure", "openai", "gemini", "deepseek", "orca_cloud"]:
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.RESPONSE_START_FIELD), null)
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.INACTIVITY_FIELD), null)
		settings.set_setting(Config._provider_setting(provider_id, RequestTimeouts.CUSTOM_ENABLED_FIELD), null)
	var view := SettingsView.new()
	get_root().add_child(view)
	await process_frame
	view._load_provider("ollama")
	_expect(view.request_timeouts_section.visible and view.response_start_timeout_input.value == 300 and view.stream_inactivity_timeout_input.value == 60, "existing local profiles should acquire generous startup defaults without migration")
	_expect(not view._custom_timeouts_row.visible and view._timeout_fields.visible and not view._timeout_summary.visible, "local response controls must remain directly available without an opt-in switch")
	view.response_start_timeout_input.get_line_edit().text = "420"
	view.stream_inactivity_timeout_input.get_line_edit().text = "120"
	view._save_current_profile()
	_expect(Config.get_request_timeouts("ollama") == {RequestTimeouts.RESPONSE_START_FIELD: 420, RequestTimeouts.INACTIVITY_FIELD: 120, RequestTimeouts.CUSTOM_ENABLED_FIELD: true}, "typed timeout values must save even before pressing Enter")
	view._load_provider("lmstudio")
	_expect(view.response_start_timeout_input.value == 300 and view.stream_inactivity_timeout_input.value == 60, "local timeout preferences must remain isolated per provider")
	view._load_provider("azure")
	_expect(view.response_start_timeout_input.value == 30 and view.stream_inactivity_timeout_input.value == 60, "remote/BYOK profiles should retain existing defaults")
	_expect(view._custom_timeouts_row.visible and not view.custom_timeouts_toggle.button_pressed and not view._timeout_fields.visible and view._timeout_summary.visible, "hosted customization must start off with a compact default summary")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	view.find_child("CustomTimeoutsLabel", true, false).gui_input.emit(click)
	_expect(view.custom_timeouts_toggle.button_pressed and view._timeout_fields.visible and not view._timeout_summary.visible, "clicking the switch label must enable custom timing and reveal its controls")
	view.response_start_timeout_input.get_line_edit().text = "180"
	view.stream_inactivity_timeout_input.get_line_edit().text = "90"
	view._on_done_pressed()
	_expect(Config.get_active_provider_config().get(RequestTimeouts.RESPONSE_START_FIELD) == 180 and Config.get_active_provider_config().get(RequestTimeouts.INACTIVITY_FIELD) == 90 and Config.get_active_provider_config().get(RequestTimeouts.CUSTOM_ENABLED_FIELD) == true, "Done must commit typed values and opt-in into active request snapshots")
	view.response_start_timeout_input.get_line_edit().text = "240"
	view.custom_timeouts_toggle.button_pressed = false
	view._save_current_profile()
	view._load_provider("azure")
	var saved := Config.get_provider_config("azure")
	_expect(saved.get(RequestTimeouts.CUSTOM_ENABLED_FIELD) == false and saved.get(RequestTimeouts.RESPONSE_START_FIELD) == 240 and saved.get(RequestTimeouts.INACTIVITY_FIELD) == 90 and not view._timeout_fields.visible, "turning off must commit and retain typed custom values through restoration")
	_expect(RequestTimeouts.resolve(saved).get("response_start_ms") == 30000 and RequestTimeouts.probe_timeout_seconds(saved) == 45.0, "off must actually restore the original transport and probe policy")
	view.custom_timeouts_toggle.button_pressed = true
	_expect(view.response_start_timeout_input.value == 240 and view.stream_inactivity_timeout_input.value == 90, "turning back on must restore the retained values")
	view._save_current_profile()
	for provider_id in ["openai", "gemini", "deepseek"]:
		view._load_provider(provider_id)
		_expect(not view.custom_timeouts_toggle.button_pressed and not view._timeout_fields.visible and view._timeout_summary.visible, "hosted opt-in must remain isolated from Azure: " + provider_id)
		_expect(not view._timeout_description.text.contains("model loading"), "hosted help must not describe local loading")
	view._load_provider("azure")
	_expect(view.custom_timeouts_toggle.button_pressed and view.response_start_timeout_input.value == 240, "provider switching must retain the hosted override state and values")
	settings.set_setting(Config._provider_setting("azure", RequestTimeouts.CUSTOM_ENABLED_FIELD), null)
	_expect(Config.get_request_timeouts("azure")[RequestTimeouts.CUSTOM_ENABLED_FIELD], "pre-toggle non-default preferences must preserve the earlier candidate's override")
	settings.set_setting(Config._provider_setting("azure", RequestTimeouts.CUSTOM_ENABLED_FIELD), false)
	_expect(not Config.get_request_timeouts("azure")[RequestTimeouts.CUSTOM_ENABLED_FIELD], "explicit off must win over non-default stored values")
	settings.set_setting(Config._provider_setting("azure", RequestTimeouts.CUSTOM_ENABLED_FIELD), "bad")
	_expect(not Config.get_request_timeouts("azure")[RequestTimeouts.CUSTOM_ENABLED_FIELD], "corrupt persisted opt-in flags must fall back to built-in timing")
	settings.set_setting(Config._provider_setting("azure", RequestTimeouts.CUSTOM_ENABLED_FIELD), false)
	view._load_provider("ollama")
	_expect(view.response_start_timeout_input.value == 420 and view.stream_inactivity_timeout_input.value == 120, "reopening a provider should restore its saved controls")
	var before := Config.get_provider_config("ollama")
	_expect(not Config.save_provider_config("ollama", "replacement", "replacement", "high", "http://127.0.0.1:11434/v1", "chat_completions", "standard", {RequestTimeouts.RESPONSE_START_FIELD: 0}), "disabled timeout must reject an entire settings update")
	_expect(Config.get_provider_config("ollama") == before and Config.get_provider() == "azure", "invalid timeout save must preserve credentials, model, preferences, and selected provider")
	settings.set_setting(Config._provider_setting("ollama", RequestTimeouts.RESPONSE_START_FIELD), INF)
	settings.set_setting(Config._provider_setting("ollama", RequestTimeouts.INACTIVITY_FIELD), "bad")
	_expect(Config.get_request_timeouts("ollama") == RequestTimeouts.defaults("ollama"), "corrupt persisted settings must fall back to finite defaults")
	settings.set_setting(Config._provider_setting("orca_cloud", RequestTimeouts.RESPONSE_START_FIELD), 600)
	settings.set_setting(Config._provider_setting("orca_cloud", RequestTimeouts.INACTIVITY_FIELD), 600)
	settings.set_setting(Config._provider_setting("orca_cloud", RequestTimeouts.CUSTOM_ENABLED_FIELD), true)
	view._load_provider("orca_cloud")
	_expect(not view.request_timeouts_section.visible and Config.get_request_timeouts("orca_cloud") == RequestTimeouts.defaults("orca_cloud"), "managed settings must hide editable timing and ignore stored overrides")
	_expect(not view.request_timeouts_margin.visible, "managed profiles must hide the whole card and its exterior spacing")
	view.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("provider_settings_editor_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("provider_settings_editor_test: ", failure)
	quit(1)
