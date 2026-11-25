@tool
extends "res://tests/editor_test_case.gd"

const Settings = preload("res://addons/orca/scripts/settings_view.gd")
const Account = preload("res://addons/orca/scripts/account_service.gd")
const Cloud = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
var failures := 0

class FixtureAccount:
	extends Account
	func _ready() -> void: pass
	func refresh_account() -> void: pass

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	if not Engine.is_editor_hint():
		quit(1)
		return
	var editor := EditorInterface.get_editor_settings()
	var originals := {}
	for key in [Config.SETTING_PROVIDER, "orca/providers/orca_cloud/model", "orca/providers/orca_cloud/reasoning_effort", "orca/providers/orca_cloud/api_key", "orca/providers/orca_cloud/api_mode", "orca/providers/orca_cloud/continuation_style", "orca/providers/orca_cloud/base_url"]:
		originals[key] = {"exists": editor.has_setting(key), "value": editor.get_setting(key) if editor.has_setting(key) else null}
	editor.set_setting("orca/providers/orca_cloud/reasoning_effort", "high")
	editor.set_setting("orca/providers/orca_cloud/base_url", "http://127.0.0.1:8000/v1")
	check(Config.get_provider_config("orca_cloud")["base_url"] == "https://cloud.aiorca.dev/v1", "managed configuration ignores a saved development origin after cutover")
	var account := FixtureAccount.new()
	account.account = {"id": "fixture-only", "display_name": "Developer", "allowance": {"available_units": 5000000, "reserved_units": 0}}
	account._tokens = {"session_id": "fixture-session", "access_token": "fixture-access", "refresh_token": "fixture-refresh"}
	account.state = "connected"
	var data := []
	for allowed in [true, false]:
		data.append({"id": "managed-ready-fixture" if allowed else "managed-locked-fixture", "name": "Managed model", "context_window": 32768, "max_output_tokens": 8192, "effort": {"supported_levels": ["high"], "default_level": "high"}, "orca": {"protocol": "chat_completions", "tools": true, "continuation_style": "standard", "capability_version": "fixture-v1", "availability": "available", "recommendation": "recommended", "access": {"allowed": allowed}, "agent": {"status": "operator_verified", "capability_version": "fixture-v1", "tool_contract": "orca-tools-v1"}, "context_budget": {"version": "utf8-conservative-v2", "text_bytes_per_token": 3, "message_overhead": 32, "tool_overhead": 64, "image_tokens": 16384, "opaque_reasoning_bytes": false}}})
	account.models = Cloud.normalize_catalog({"data": data})
	root.add_child(account)
	var view := Settings.new()
	view.account_service = account
	root.add_child(view)
	account.signed_in.emit()
	for frame in 4:
		await process_frame
	check(Config.get_provider() == "orca_cloud" and Config.get_model() == "managed-ready-fixture", "sign-in activates an included recommended model without setup")
	check(Config.get_api_url() == "https://cloud.aiorca.dev/v1" and Config.get_active_provider_config()["base_url"] == Cloud.BASE_URL, "active managed configuration uses production with stale saved settings")
	check(Config.get_reasoning_effort() == "default" and Config.get_api_key("orca_cloud").is_empty(), "managed defaults override stale effort and never save account credentials")
	_check_managed_controls_hidden(view, "sign-in")
	check(not view.effort_selector.visible and not view.effort_label.visible, "managed models have no reasoning configuration")
	check(view.model_selector.is_item_disabled(1) and not view.model_selector.is_item_disabled(0), "model choices follow account entitlement")
	view._on_agent_probe_pressed()
	check(not view._agent_probe.is_running(), "hidden managed probe cannot be started")
	view._select_provider("custom")
	check(view.agent_heading_label.visible and view.agent_probe_button.visible and view.agent_enable_toggle.visible, "editable providers retain compatibility controls")
	view._select_provider("orca_cloud")
	_check_managed_controls_hidden(view, "switching back from an editable provider")
	account.changed.emit()
	_check_managed_controls_hidden(view, "catalog refresh")
	account.state = "signed_out"
	account.changed.emit()
	_check_managed_controls_hidden(view, "signed-out account")
	account.state = "connected"
	account.changed.emit()
	var chat = ChatScene.instantiate()
	chat.account_service = account
	chat.set_anchors_preset(Control.PRESET_TOP_LEFT)
	chat.size = Vector2(300, 800)
	root.add_child(chat)
	for frame in 4:
		await process_frame
	check(chat.image_button.disabled and not chat._image_intake_error(1).is_empty(), "text-only hosted catalog disables image intake")
	account.models[0]["image_input"] = true
	account.changed.emit()
	check(not chat.image_button.disabled and chat._image_intake_error(1).is_empty(), "hosted catalog refresh enables the selected vision model without a probe")
	var pixels := Image.create(32, 24, false, Image.FORMAT_RGB8)
	pixels.fill(Color.RED)
	var prepared := Images.prepare_image(pixels, "Managed fixture.png")
	check(chat._accept_prepared_images([prepared["image"]]) and chat._draft_images.size() == 1, "hosted vision model accepts a prepared image in the real composer")
	account.models[0]["image_input"] = false
	account.changed.emit()
	check(chat.image_button.disabled and chat._draft_images.size() == 1, "capability loss disables new intake while retaining the draft image")
	chat.free()
	view.free()
	account.free()
	for key in originals:
		editor.set_setting(key, originals[key]["value"] if originals[key]["exists"] else null)
	print("Managed settings editor: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _check_managed_controls_hidden(view, stage: String) -> void:
	check(not view.agent_heading_label.visible and not view.agent_status_label.visible and not view.agent_probe_button.visible and not view.agent_enable_toggle.visible and not view.agent_warning_label.visible, "managed models have no compatibility controls after " + stage)
