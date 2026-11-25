@tool
extends "res://tests/editor_test_case.gd"

const Settings = preload("res://addons/orca/scripts/settings_view.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const Qwen = preload("res://addons/orca/scripts/providers/qwen_provider.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
var failures := PackedStringArray()

class Discovery extends Node:
	var requests: Array = []
	func cancel() -> void: pass
	func fetch_models(provider: String, config: Dictionary) -> void: requests.append({"provider": provider, "config": config.duplicate(true)})


class ProbeFixture extends Node:
	signal probe_step_changed(step: int)
	signal probe_passed(binding: Dictionary)
	signal probe_failed(binding: Dictionary, message: String)
	signal probe_cancelled
	var running := false
	var starts := 0
	var binding := {}
	func is_running() -> bool: return running
	func start_probe(config: Dictionary) -> bool:
		starts += 1
		binding = Probe.create_binding(config).get("binding", {})
		running = not binding.is_empty()
		return running
	func cancel() -> void:
		running = false
		probe_cancelled.emit()
	func pass_check() -> void:
		running = false
		probe_passed.emit(binding.duplicate(true))


func _init() -> void: call_deferred("run")


func run() -> void:
	for frame in 30: await process_frame
	var view := Settings.new()
	view.size = Metrics.scaled_vector(Vector2(300, 680))
	get_root().add_child(view)
	await process_frame
	view._model_service.queue_free()
	var discovery := Discovery.new()
	view.add_child(discovery)
	view._model_service = discovery
	view._agent_probe.queue_free()
	var probe := ProbeFixture.new()
	view.add_child(probe)
	view._agent_probe = probe
	probe.probe_passed.connect(view._on_probe_passed)
	probe.probe_failed.connect(view._on_probe_failed)
	probe.probe_cancelled.connect(view._on_probe_cancelled)
	if OS.get_environment("ORCA_PROVIDER_EDITOR_PHASE") == "restart":
		view._load_provider("qwen")
		_expect(view.api_key_input.text == "synthetic-qwen-key" and view.qwen_region_selector.get_selected_metadata() == "us-east-1" and view.qwen_workspace_input.text == "llm-editor-fixture" and view._selected_effort == "on", "Qwen profile survives an actual editor restart")
		view._load_provider("anthropic")
		_expect(view.api_key_input.text == "synthetic-anthropic-key" and view._selected_api_mode == "anthropic_messages" and view._selected_effort == "high", "native profile survives an actual editor restart")
		_expect(not view.agent_probe_button.visible and not view.agent_enable_toggle.button_pressed and Config.get_provider_config("anthropic").get("official_agent_enabled") == false and probe.starts == 0, "official opt-out survives restart without a probe or automatic enablement")
		await _finish(view)
		return
	view._load_provider("qwen")
	_expect(view.qwen_endpoint_fields.visible and view.custom_model_input.visible and not view.agent_probe_button.visible and not view.custom_url_input.editable, "fixed official Qwen setup does not require a probe")
	_expect(view._selected_model == "qwen3-coder-plus", "new Qwen profile uses the coding default")
	view.qwen_region_selector.select(1)
	view._on_qwen_region_selected(1)
	_expect(view.custom_url_input.text.is_empty(), "Virginia cannot inherit the Singapore endpoint")
	view.qwen_workspace_input.text = "llm-editor-fixture"
	view._on_qwen_workspace_changed(view.qwen_workspace_input.text)
	_expect(view.custom_url_input.text == Qwen.endpoint("us-east-1", "llm-editor-fixture"), "workspace generates the exact regional endpoint")
	_expect(view._provider_key_url().contains("/us-east-1/"), "Get an API key follows the selected region")
	_expect(discovery.requests.is_empty(), "region/workspace edits never contact an endpoint")
	view.api_key_input.text = "synthetic-qwen-key"
	view._on_manual_model_changed("qwen-plus")
	view._selected_effort = "on"
	view._save_current_profile()
	var saved := Config.get_provider_config("qwen")
	_expect(saved.get("base_url") == view.custom_url_input.text and saved.get("reasoning_effort") == "on", "Qwen profile is persisted independently")
	view._load_provider("openai")
	_expect(not view.qwen_endpoint_fields.visible and view.api_key_input.text != "synthetic-qwen-key", "switching providers preserves credential isolation")
	view._load_provider("qwen")
	_expect(view.qwen_region_selector.get_selected_metadata() == "us-east-1" and view.qwen_workspace_input.text == "llm-editor-fixture" and view._selected_effort == "on", "endpoint-derived region and thinking restore")
	view.custom_url_input.text = "http://127.0.0.1:18473/custom-qwen"
	view._on_custom_url_changed(view.custom_url_input.text)
	_expect(view.qwen_region_selector.get_selected_metadata() == "" and not view.qwen_workspace_input.editable, "custom URLs remain custom without rewriting")
	view._load_provider("anthropic")
	_expect(view._selected_api_mode == "anthropic_messages" and not view.agent_probe_button.visible and view.custom_model_input.visible and not view.qwen_endpoint_fields.visible, "supported canonical Anthropic exposes native setup with automatic readiness")
	view.api_key_input.text = "synthetic-anthropic-key"
	view._selected_effort = "high"
	view._save_current_profile()
	var native := Config.get_provider_config("anthropic")
	_expect(native.get("api_mode") == "anthropic_messages" and native.get("api_key") == "synthetic-anthropic-key", "native profile persists its protocol independently")
	_expect(not Config.save_provider_profile("anthropic", "replacement", "wrong", "off", "", "chat_completions"), "invalid native API mode cannot overwrite the profile")
	_expect(Config.get_provider_config("anthropic") == native, "invalid save preserves existing credentials and options")
	view._load_provider("qwen")
	view._load_provider("anthropic")
	_expect(view.api_key_input.text == "synthetic-anthropic-key" and view._selected_effort == "high", "native settings restore across switches")
	view._on_manual_model_changed("claude-opus-5-5")
	_expect(not "off" in preload("res://addons/orca/scripts/providers/anthropic_provider.gd").efforts_for_model(view._selected_model), "unsupported native Off options are excluded")
	view._load_provider("qwen")
	for provider in ["qwen", "anthropic"]:
		view._load_provider(provider)
		for locale in Localization.LOCALES:
			Localization.select_language(locale)
			for scale in [1.0, 1.5, 2.0]:
				for control in [view.qwen_region_selector, view.provider_setup_help, view.qwen_workspace_input]:
					control.add_theme_font_size_override("font_size", int(13 * scale))
				for frame in 8: await process_frame
				_expect(view.get_combined_minimum_size().x <= Metrics.scaled(300), "narrow provider layout: " + provider + " " + locale + " " + str(view.get_combined_minimum_size()))
	Localization.select_language("en")
	await _test_readiness(view, discovery, probe)
	await _finish(view)


func _test_readiness(view, discovery, probe) -> void:
	var controller := Controller.new()
	for index in [0, 2, 3]:
		view._load_provider("qwen")
		view.qwen_workspace_input.text = ""
		view.qwen_region_selector.select(index)
		view._on_qwen_region_selected(index)
		view.api_key_input.text = "synthetic-qwen-key"
		view._on_manual_model_changed("qwen-plus")
		view._selected_effort = "on"
		view._sync_agent_compatibility()
		var base: String = view.custom_url_input.text
		_expect(not view.custom_url_input.editable and not view.agent_probe_button.visible and view.agent_enable_toggle.button_pressed and controller._profile_allows_tools(view._current_form_config()), "official UI and runtime agree on regional readiness")
		view._refresh_models()
		_expect(not view._trust_dialog.visible and discovery.requests[-1]["config"]["base_url"] == base, "official regional discovery preserves the selected endpoint without a trust task")
		view._on_done_pressed()
		_expect(Config.get_api_url() == base and Config.get_active_provider_config().get("base_url") == base, "Done and active snapshots preserve each official region")
		_expect(Config.get_agent_compatibility("qwen").is_empty() and probe.starts == 0, "official readiness never creates a fabricated probe pass")
		view._on_agent_enable_toggled(false)
		view._selected_effort = "off"
		view._sync_agent_compatibility()
		_expect(not view.agent_enable_toggle.button_pressed and not controller._profile_allows_tools(view._current_form_config()), "official opt-out survives supported thinking changes")
		view._on_agent_enable_toggled(true)
		var exact: Dictionary = Probe.create_binding(view._current_form_config())["binding"]
		Config.record_agent_probe_pass(exact)
		view._sync_agent_compatibility()
		_expect(not view.agent_enable_toggle.button_pressed, "historical disabled passes never silently re-enable official tools")
		view._on_agent_enable_toggled(true)
		_expect(view.agent_enable_toggle.button_pressed, "explicit official toggle can re-enable an old opted-out profile")
		Config.clear_agent_compatibility("qwen")
	# A workspace still needs consent and the existing one-use, project-free probe.
	view.qwen_region_selector.select(1)
	view._on_qwen_region_selected(1)
	view.qwen_workspace_input.text = "llm-editor-fixture"
	view._on_qwen_workspace_changed(view.qwen_workspace_input.text)
	view._selected_effort = "on"
	view._sync_agent_compatibility()
	var starts: int = probe.starts
	view._on_agent_probe_pressed()
	_expect(view._trust_dialog.visible and probe.starts == starts, "workspace consent precedes the probe")
	view._trust_dialog.hide()
	view._on_endpoint_trust_cancelled()
	_expect(view._agent_enable_intent.is_empty() and probe.starts == starts, "cancelled workspace consent makes no request")
	view._on_agent_probe_pressed()
	view._trust_dialog.hide()
	view._on_endpoint_trust_confirmed()
	_expect(probe.running and not view.agent_enable_toggle.button_pressed, "workspace tools remain disabled while checking")
	probe.pass_check()
	_expect(view.agent_enable_toggle.button_pressed and controller._profile_allows_tools(view._current_form_config()), "exact consent and matching pass enable workspace tools")
	view._on_agent_enable_toggled(false)
	probe.probe_passed.emit(probe.binding)
	_expect(not view.agent_enable_toggle.button_pressed, "duplicate callbacks preserve workspace opt-out")
	for change in ["model", "credential", "effort", "endpoint", "cancel", "failure"]:
		view._selected_model = "qwen-plus"
		view.api_key_input.text = "synthetic-qwen-key"
		view._selected_effort = "on"
		view._set_qwen_endpoint("us-east-1", "llm-editor-fixture")
		view._on_agent_probe_pressed()
		var stale: Dictionary = probe.binding.duplicate(true)
		if change == "model": view._on_manual_model_changed("qwen-flash")
		elif change == "credential": view.api_key_input.text = "changed-key"
		elif change == "effort": view._on_effort_selected(0)
		elif change == "endpoint": view._set_qwen_endpoint("us-east-1", "changed-workspace")
		elif change == "failure":
			probe.running = false
			probe.probe_failed.emit(stale, "synthetic failure")
		else: probe.cancel()
		probe.probe_passed.emit(stale)
		_expect(not view.agent_enable_toggle.button_pressed and view._agent_enable_intent.is_empty(), "workspace drift/cancel/failure cannot accept late enablement: " + change)
	view._selected_model = "qwen-plus"
	view.api_key_input.text = "synthetic-qwen-key"
	view._selected_effort = "on"
	view._set_qwen_endpoint("us-east-1", "llm-editor-fixture")
	view._save_current_profile()
	view._load_provider("anthropic")
	view._on_manual_model_changed("claude-sonnet-4-6")
	view._selected_effort = "high"
	view._sync_agent_compatibility()
	_expect(not view.agent_probe_button.visible and view.agent_enable_toggle.button_pressed, "canonical native readiness does not require a stored check")
	view._on_manual_model_changed("claude-unverified-manual")
	_expect(view.agent_probe_button.visible and not view.agent_enable_toggle.button_pressed and not controller._profile_allows_tools(view._current_form_config()), "unknown native IDs retain accurate probe guidance")
	view._on_manual_model_changed("claude-sonnet-4-6")
	view._selected_effort = "high"
	view._on_agent_enable_toggled(false)
	view._save_current_profile()
	view._load_provider("anthropic")
	_expect(not view.agent_enable_toggle.button_pressed and not controller._profile_allows_tools(view._current_form_config()), "reopening native settings preserves official opt-out")
	for provider in ["qwen", "anthropic"]:
		view._load_provider(provider)
		for locale in Localization.LOCALES:
			Localization.select_language(locale)
			for scale in [1.0, 1.5, 2.0]:
				for control in [view.agent_status_label, view.agent_enable_toggle, view.agent_probe_button, view.endpoint_status_label]: control.add_theme_font_size_override("font_size", int(13 * scale))
				for frame in 6: await process_frame
				_expect(view.get_combined_minimum_size().x <= Metrics.scaled(300), "localized readiness fits narrow provider layout: " + provider + " " + locale)
	Localization.select_language("en")
	controller.free()


func _finish(view: Control) -> void:
	view.queue_free()
	for frame in 10: await process_frame
	for failure in failures: printerr(failure)
	print("provider_adapter_editor_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
