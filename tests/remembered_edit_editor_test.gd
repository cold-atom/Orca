@tool
extends "res://tests/editor_test_case.gd"

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")

class FixtureChat extends "res://addons/orca/scripts/chat_window.gd":
	func _refresh_model_metadata() -> void: pass
	func _restore_active_session() -> void:
		session_store = Store.new("user://remembered_editor_fixture")
		super._restore_active_session()

var failures := PackedStringArray()
var view
var settings: EditorSettings
var phase := ""
var preference_key := ""
var fixture_path := "res://tests/remembered_edit_fixture.gd"

func _init() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message)

func _settle() -> void:
	for frame in 8: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame

func _confirm(remember: bool) -> void:
	view._edit_permission_remember.button_pressed = remember
	view._edit_permission_dialog.hide()
	view._edit_permission_dialog.confirmed.emit()

func _run() -> void:
	for frame in 60: await process_frame
	await _settle()
	phase = OS.get_environment("ORCA_REMEMBERED_EDIT_TEST_PHASE")
	settings = EditorInterface.get_editor_settings()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	preference_key = Config.PROJECT_SCRIPT_EDITS_PREFIX + ProjectSettings.globalize_path("res://").simplify_path().sha256_text()
	root.size = Vector2i(Metrics.scaled_int(1200), Metrics.scaled_int(900))
	view = ChatScene.instantiate()
	view.set_script(FixtureChat)
	root.add_child(view)
	view.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	view.size = Metrics.scaled_vector(Vector2(300, 800))
	await _settle()
	match phase:
		"enable": await _enable()
		"verify": await _verify()
		"other_project": _other_project()
		"revoke":
			check(view.agent_controller.auto_apply_enabled(), "restart reacquires the exact remembered default before revocation")
			check(view._edit_permission_status.is_visible_in_tree() and not view._edit_permission_button.visible, "remembered startup uses the compact header instead of an overlay")
			view._edit_permission_status.pressed.emit()
			check(not view.agent_controller.auto_apply_enabled() and not Config.project_script_edit_preference()["enabled"], "chip revocation clears runtime and saved authority")
		"verify_revoked":
			check(not view.agent_controller.auto_apply_enabled() and not Config.project_script_edit_preference()["enabled"], "revocation survives a separate clean editor restart")
		_: check(false, "unknown remembered-preference test phase")
	var store = view.session_store
	view._session = {}
	view._has_session_content = false
	view.queue_free()
	await _settle()
	store.delete_all_sessions()
	if FileAccess.file_exists(fixture_path):
		EditorInterface.get_script_editor().close_file(fixture_path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture_path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(fixture_path + ".uid"))
		EditorInterface.get_resource_filesystem().scan()
		await _settle()
	for failure in failures: push_error(failure)
	print("remembered_edit_editor_test: %d failures (%s)" % [failures.size(), phase])
	quit(0 if failures.is_empty() else 1)

func _enable() -> void:
	check(not view.agent_controller.auto_apply_enabled() and not Config.project_script_edit_preference()["enabled"], "fresh projects default to review")
	view._edit_permission_button.pressed.emit()
	check(not view._edit_permission_remember.button_pressed, "remembering is unchecked on the ordinary dialog")
	_confirm(false)
	check(view.agent_controller.auto_apply_enabled() and not Config.project_script_edit_preference()["enabled"], "unchecked confirmation grants only the current session")
	view._start_new_session()
	check(not view.agent_controller.auto_apply_enabled(), "session-only grants still clear on New Session")
	view._edit_permission_button.pressed.emit()
	view._edit_permission_remember.button_pressed = true
	view._edit_permission_dialog.hide()
	check(not Config.project_script_edit_preference()["enabled"], "checking/dismissing the dialog cannot save permission")
	view._edit_permission_button.pressed.emit()
	view._edit_permission_remember.button_pressed = true
	Config.set_project_script_edit_default(false)
	_confirm(true)
	check(not Config.project_script_edit_preference()["enabled"], "changed saved revision rejects stale confirmation even when the enabled state is unchanged")
	view._on_settings_button_pressed()
	view.settings_view._show_section("system")
	view.settings_view.script_edit_default_selector.item_selected.emit(1)
	check(view._edit_permission_dialog.visible and not Config.project_script_edit_preference()["enabled"], "Settings Auto apply requires the shared confirmation")
	view._edit_permission_dialog.hide()
	view.agent_controller.set_mode(0)
	view.settings_view.script_edit_default_selector.item_selected.emit(1)
	_confirm(true)
	check(Config.project_script_edit_preference()["enabled"] and not view.agent_controller.auto_apply_enabled(), "explicit Settings confirmation in Plan remembers future Work without enabling edits")
	view.agent_controller.set_mode(1)
	check(view.agent_controller.auto_apply_uses_project_default(), "explicit Work selection acquires fresh remembered authorization")
	view._on_settings_done()
	view._start_new_session()
	check(view.agent_controller.auto_apply_enabled() and view._edit_permission_status.is_visible_in_tree() and view._edit_permission_status.tooltip_text.contains("Remembered for this project") and not view._edit_permission_button.visible, "new Work conversations show the compact remembered default without a floating chip")
	var snapshot: Dictionary = view.agent_controller.snapshot_session_state()
	check(not JSON.stringify(snapshot).contains(Config.project_script_edit_preference()["revision"]), "conversation snapshots exclude saved edit authority")
	await _settle()

func _verify() -> void:
	check(view.agent_controller.auto_apply_uses_project_default(), "a separate editor process reloads the same-project preference")
	var original: Dictionary = settings.get_setting(preference_key).duplicate(true)
	for malformed in [true, {"enabled": true}, original.merged({"enabled": "true"}, true), original.merged({"project_root": "/another/project"}, true), original.merged({"revision": "invalid"}, true), original.merged({"extra": true}, true)]:
		settings.set_setting(preference_key, malformed)
		check(not Config.project_script_edit_preference()["enabled"] and not view.agent_controller.auto_apply_enabled(), "malformed/mismatched preferences cannot authorize runtime edits")
	settings.set_setting(preference_key, original)
	var saved: Dictionary = view._session.duplicate(true)
	saved["mode"] = 1
	saved["clean"] = true
	saved["resumable"] = true
	check(view.session_store.save_session(saved).get("success", false), "restoration fixture is durably registered before History selects it")
	check(view._restore_session(saved) and view.agent_controller.auto_apply_enabled(), "resumable Work restoration reacquires only the user-owned project preference")
	saved["resumable"] = false
	check(view._restore_session(saved) and not view.agent_controller.auto_apply_enabled(), "view-only Work history never activates the remembered default")
	check(not view.agent_controller.set_auto_apply_enabled(true), "view-only controller state denies direct grant attempts")
	saved["mode"] = 0
	saved["resumable"] = true
	check(view._restore_session(saved) and not view.agent_controller.auto_apply_enabled(), "Plan history never activates automatic edits")
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	for approved in [false, true]:
		view.prompt_input.text = "Request Work for the fixture"
		view._on_send_button_pressed()
		client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "request-work", "type": "function", "function": {"name": "request_work_mode", "arguments": JSON.stringify({"reason": "Continue the requested edit in Work."})}}]})
		check(not view.agent_controller.auto_apply_enabled(), "a model Work request cannot itself activate a remembered grant")
		view.agent_controller.resolve_work_mode_request("request-work", view.agent_controller._active_turn_id, approved)
		check(view.agent_controller.auto_apply_enabled() == approved, "only exact user approval of Work may activate the remembered default")
		client.complete({"role": "assistant", "content": "Mode decision completed."})
	view._start_new_session()
	var file := FileAccess.open(fixture_path, FileAccess.WRITE)
	file.store_string(Component.OLD)
	file.close()
	view.agent_controller.script_change_writer = func(_record): return false
	view.prompt_input.text = "Synthetic failed checkpoint"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("failed-checkpoint")]})
	client.complete({"role": "assistant", "content": "Checkpoint failed."})
	await _settle()
	check(FileAccess.get_file_as_string(fixture_path) == Component.OLD and not view.agent_controller.auto_apply_enabled() and Config.project_script_edit_preference()["enabled"], "checkpoint failure preserves disk and pauses the current grant without discarding the saved preference")
	view._sync_edit_permission_ui()
	check(not view.agent_controller.auto_apply_enabled(), "ordinary UI refresh cannot silently reacquire a paused default")
	view._start_new_session()
	check(view.agent_controller.auto_apply_enabled(), "an explicit new session may acquire fresh authorization after a failed checkpoint")
	view.agent_controller.script_change_writer = func(_record):
		Config.set_project_script_edit_default(true)
		return true
	view.prompt_input.text = "Synthetic changed preference during checkpoint"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("changed-revision")]})
	client.complete({"role": "assistant", "content": "Preference changed."})
	check(FileAccess.get_file_as_string(fixture_path) == Component.OLD and not view.agent_controller.auto_apply_enabled(), "saved-revision drift during checkpoint prevents the pending automatic write")
	check(client.requests.back()["messages"][0]["content"].contains("Review edits is active"), "saved-revision drift refreshes permission in the next provider continuation")
	check(view.agent_controller.message_history.filter(func(message): return message.get("tool_call_id") == "changed-revision" and message.get("role") == "tool").size() == 1, "preference drift retains exactly one matching tool receipt")
	view._start_new_session()
	check(view.agent_controller.auto_apply_enabled(), "fresh sessions bind the current saved revision")
	view._on_settings_button_pressed()
	view.settings_view._show_section("system")
	view.settings_view.script_edit_default_selector.item_selected.emit(0)
	check(not view.agent_controller.auto_apply_enabled() and not Config.project_script_edit_preference()["enabled"], "Settings Review edits clears saved and current grants")
	view._on_settings_done()
	view.agent_controller.script_change_writer = view._checkpoint_script_change
	view.prompt_input.text = "Remember while reviewing the first script edit"
	view._on_send_button_pressed()
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch("pending-remember")]})
	check(view.agent_controller._pending_change_id == "pending-remember" and FileAccess.get_file_as_string(fixture_path) == Component.OLD, "review remains suspended before remembered pending-proposal confirmation")
	view._edit_permission_status.pressed.emit()
	_confirm(true)
	check(view.agent_controller.auto_apply_uses_project_default() and FileAccess.get_file_as_string(fixture_path) == Component.NEW, "remembered confirmation applies the exact pending script through durable checkpointing")
	client.complete({"role": "assistant", "content": "Applied the fixture."})
	await _settle()

func _other_project() -> void:
	check(not Config.project_script_edit_preference()["enabled"] and not view.agent_controller.auto_apply_enabled(), "the same user configuration grants nothing to a different project")
	var original_root := OS.get_environment("ORCA_REMEMBERED_PROJECT_ROOT")
	var record = settings.get_setting(Config.PROJECT_SCRIPT_EDITS_PREFIX + original_root.sha256_text())
	settings.set_setting(preference_key, record)
	check(not Config.project_script_edit_preference()["enabled"], "copied preference records cannot authorize another project root")
	settings.erase(preference_key)

func _patch(id: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "apply_patch", "arguments": JSON.stringify({"filepath": fixture_path, "base_hash": Component.OLD.sha256_text(), "edits": [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}]})}}
