@tool
extends SceneTree

const Settings = preload("res://addons/orca/scripts/settings_view.gd")
const Account = preload("res://addons/orca/scripts/account_service.gd")
const Helper = preload("res://addons/orca/scripts/native_helper_service.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FixtureHelper extends Helper:
	var installed := false
	var installs := 0
	func _ready() -> void:
		entry = {"size": 1024}
		call_deferred("_automatic_startup")
	func automatic_downloads_enabled() -> bool: return true
	func executable() -> String: return "/fixture/verified-helper" if installed else ""
	func _install_once() -> bool:
		installs += 1
		_set_state("downloading", "Preparing fixture helper…")
		await get_tree().create_timer(0.4).timeout
		installed = true
		_set_state("ready", "Verified fixture helper.")
		return true

class FixtureVault extends RefCounted:
	var helper
	func available() -> bool: return not helper.executable().is_empty()

class FixtureAccount extends Account:
	var calls := 0
	func _request(_path: String, _method: int, _body: Dictionary = {}, _token: String = "") -> Dictionary:
		calls += 1
		return {"success": false}

class FixtureModels extends Node:
	signal models_loaded(provider_id: String, models: Array, cached: bool)
	signal models_failed(provider_id: String, message: String)
	func fetch_models(_provider: String, _config: Dictionary, _force: bool = false) -> void: pass
	func cancel() -> void: pass

var failures := 0

func _init() -> void: call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _settle() -> void:
	for frame in 5: await process_frame

func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	root.size = Vector2i(UiMetrics.scaled_int(300), UiMetrics.scaled_int(800))
	var ordinary := Helper.new()
	root.add_child(ordinary)
	check(not ordinary.automatic_downloads_enabled(), "ordinary editor tests suppress real startup downloads")
	ordinary.queue_free()
	var helper := FixtureHelper.new()
	root.add_child(helper)
	var account := FixtureAccount.new()
	account._vault = FixtureVault.new()
	account._vault.helper = helper
	account.native_helper = helper
	root.add_child(account)
	var view := Settings.new()
	view.account_service = account
	root.add_child(view)
	view._model_service.free()
	view._model_service = FixtureModels.new()
	view.add_child(view._model_service)
	await _settle()
	check(helper.installs == 1 and account.calls == 0, "startup prepares in background without sign-in")
	check(account.status == "Sign in to use Orca-hosted models.", "background preparation has no visible download status")
	for name in ["NativeHelperInstall", "NativeHelperDisclosure", "NativeHelperProgress"]:
		check(view.find_child(name, true, false) == null, "no helper installation UI: " + name)
	view.open_account_setup()
	await _settle()
	check(account.state == "connecting" and account.status == "Preparing connection…" and account.calls == 0, "early sign-in waits in existing Account status")
	check(view.account_cancel_button.visible and not view._account_code_label.visible and not view.account_reopen_button.visible, "pending sign-in can cancel without an empty pairing code or browser action")
	view._show_section("system")
	check(helper.busy(), "BYOK/System navigation leaves background setup running")
	await create_timer(0.45).timeout
	check(helper.installs == 1 and helper.installed and account.calls == 0 and account.state == "signed_out", "cancelled sign-in never resumes after background completion")
	view.open_account_setup()
	await _settle()
	check(account.calls == 1 and helper.installs == 1, "normal sign-in reuses the ready helper")
	for font_size in [14, 21, 28]:
		view._account_status_label.add_theme_font_size_override("font_size", UiMetrics.scaled_int(font_size))
		await _settle()
		check(view._account_status_label.size.x <= root.size.x and view._account_status_label.size.y >= view._account_status_label.get_minimum_size().y, "inline Account status wraps at narrow larger fonts")
	view.queue_free()
	account.queue_free()
	helper.queue_free()
	await _settle()
	print("Native helper seamless startup UI tests: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
