@tool
extends "res://tests/editor_test_case.gd"

const Tools = preload("res://addons/orca/scripts/tools.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const SCENE := "res://tests/fixtures/editor_attach_scene.tscn"
const SCRIPT := "res://tests/fixtures/editor_attach_script.gd"
var failures: Array[String] = []
var view
var client


func _ready() -> void: call_deferred("_run")


func _settle() -> void:
	for frame in 10: await process_frame


func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	EditorInterface.open_scene_from_path(SCENE)
	await _settle()
	var scene := EditorInterface.get_edited_scene_root()
	var target := scene.get_node("Menu")
	var manager := EditorInterface.get_editor_undo_redo()
	manager.create_action("Earlier user move", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(scene, "position", Vector2(3, 4))
	manager.add_undo_property(scene, "position", Vector2.ZERO)
	manager.commit_action()
	_check(not Tools.prepare_reviewed_change("propose_scene_changes", "dirty", _arguments("attach_script")).get("success", true), "unsaved scenes must be rejected before trust")
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()
	var baseline := FileAccess.get_file_as_string(SCENE)
	var history := manager.get_history_undo_redo(manager.get_object_history_id(scene))
	var earlier_count := history.get_history_count()
	await _test_conflicts(scene, target, baseline, history)
	view = ChatScene.instantiate()
	root.add_child(view)
	await _settle()
	view._on_new_session_pressed()
	client = Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.agent_controller.set_mode(0)
	view.agent_controller.send_user_message("Inspect only")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("plan_denied", "attach_script")]})
	await _settle()
	_check(target.get_script() == null and view._change_cards.get("plan_denied") == null, "Plan must deny the editor mutation before a proposal")
	client.complete({"role": "assistant", "content": "Plan remains read-only."})
	await _settle()
	view.agent_controller.set_mode(1)
	view.agent_controller.send_user_message("Attach the menu script")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("attach_live", "attach_script")]})
	await _settle()
	var card = view._change_cards.get("attach_live")
	_check(card != null and card._apply_button.text == "Trust and Prepare", "open current scene must reach explicit execution trust")
	if card == null:
		print(JSON.stringify(view.agent_controller.message_history))
		await _finish()
		return
	_check(target.get_script() == null and history.get_history_count() == earlier_count, "trust preparation must neither attach nor alter Undo")
	card._apply_button.pressed.emit()
	await _settle()
	_check(card._apply_button.text == "Apply in editor" and card._apply_button.visible, "trusted candidate must offer a separate editor-only approval: " + card._status_label.tooltip_text)
	if not card._apply_button.visible:
		await _finish()
		return
	_check(target.get_script() == null, "trust alone must not attach")
	card._apply_button.pressed.emit()
	await _settle()
	_check(target.get_script() != null and EditorInterface.get_edited_scene_root() == scene, "Apply must attach without closing or replacing Main")
	_check(FileAccess.get_file_as_string(SCENE) == baseline, "Apply must not save the scene")
	_check(SCENE in EditorInterface.get_unsaved_scenes(), "native attachment must mark the scene unsaved")
	_check(history.get_history_count() == earlier_count + 1, "attachment must add one action and preserve earlier Undo")
	_check(card._status_label.text in ["Save pending", "Unsaved"] and card._status_label.get_parent()._note.text.contains("Applied in editor"), "editor-only success and required save must be explicit")
	var retained: Dictionary = view.agent_controller._proposals["attach_live"]
	_check(not view.agent_controller._proposal_for_review(retained).has("_editor_transaction") and not view.agent_controller._proposal_for_review(retained).has("_editor_root"), "live objects must never enter review or persisted history")
	retained["_editor_authorization"] = func(): return true
	_check(Tools.apply_reviewed_change(retained).begins_with("Error:"), "duplicate Apply must never add a second editor action")
	retained.erase("_editor_authorization")
	_check(str(client.requests[-1]["messages"][-1]["content"]).contains("Applied in editor"), "one matching tool receipt must distinguish editor application from saving")
	client.complete({"role": "assistant", "content": "Attached in the editor; save Main before running."})
	await _settle()
	await _shortcut(false)
	_check(target.get_script() == null, "native Undo must remove the attachment")
	await _shortcut(true)
	_check(target.get_script() != null, "native Redo must restore the attachment")
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()
	view.agent_controller.queue_editor_scene_refresh()
	await _settle()
	_check(card._status_label.text in ["Saved", "Save observed"] and card._status_label.get_parent()._note.text.to_lower().contains("not verified"), "save observation must distinguish persistence evidence from verification")
	manager.create_action("Later user move", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(target, "position", Vector2(9, 10))
	manager.add_undo_property(target, "position", Vector2.ZERO)
	manager.commit_action()
	_check(retained["_editor_transaction"].revert(func(): return true).begins_with("Conflict:"), "Revert must not rewind or overwrite intervening edits")
	await _shortcut(false)
	await _shortcut(false)
	_check(target.get_script() == null and SCENE in EditorInterface.get_unsaved_scenes(), "Undo after Save must affect editor state and leave disk separate")
	await _shortcut(true)
	view.agent_controller.queue_editor_scene_refresh()
	await _settle()
	view.agent_controller.revert_edit("attach_live")
	await _settle()
	_check(target.get_script() == null and FileAccess.get_file_as_string(SCENE) != baseline, "explicit Revert must be an inverse editor action, never overwrite disk")
	await _shortcut(false)
	_check(target.get_script() != null, "the inverse Revert action must itself support native Undo")
	# New Session releases Orca receipts, but the native history remains usable.
	view._on_new_session_pressed()
	view._new_session_dialog.hide()
	view._new_session_dialog.confirmed.emit()
	await _settle()
	_check(view.agent_controller._proposals.is_empty(), "New Session must release editor transaction authority")
	await _shortcut(true)
	_check(target.get_script() == null, "native Redo must survive New Session")
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()
	# Fresh detach uses the same two-stage production controller path.
	await _attach_for_detach(target)
	await _test_disk_conflict()
	await _finish()


func _test_conflicts(scene: Node, target: Node, baseline: String, history: UndoRedo) -> void:
	var count := history.get_history_count()
	EditorInterface.open_scene_from_path("res://tests/fixtures/editor_attach_other.tscn")
	await _settle()
	var background := Tools.prepare_reviewed_change("propose_scene_changes", "background", _arguments("attach_script"))
	_check(not background.get("success", true) and str(background.get("error", "")).contains("active tab"), "background target must request a tab switch without closing it")
	EditorInterface.open_scene_from_path(SCENE)
	await _settle()
	var tool_args := _arguments("attach_script")
	tool_args["operations"][0]["script_path"] = "res://tests/fixtures/editor_attach_tool.gd"
	tool_args["operations"][0]["script_hash"] = FileAccess.get_file_as_string(tool_args["operations"][0]["script_path"]).sha256_text()
	var tool_trust := Tools.prepare_reviewed_change("propose_scene_changes", "tool_script", tool_args)
	var tool_candidate := Tools.promote_script_trust(tool_trust)
	_check(not tool_candidate.get("success", true) and str(tool_candidate.get("error", "")).contains("non-@tool"), "live @tool attachment must fail before changing the editor")
	var trust := Tools.prepare_reviewed_change("propose_scene_changes", "conflict", _arguments("attach_script"))
	var prepared := Tools.promote_script_trust(trust)
	_check(prepared.get("success", false), "conflict fixture must prepare: " + str(prepared.get("error", "")))
	if not prepared.get("success", false): return
	_check(Tools.apply_reviewed_change(prepared).begins_with("Error:"), "an editor transaction must require current runtime approval")
	prepared["_editor_authorization"] = func(): return true
	target.position = Vector2(40, 50)
	_check(Tools.apply_reviewed_change(prepared).begins_with("Conflict:"), "unmarked live changes must not be overwritten")
	target.position = Vector2.ZERO
	var tampered := prepared.duplicate(true)
	tampered["new_hash"] = "changed"
	_check(Tools.apply_reviewed_change(tampered).begins_with("Error:"), "the immutable candidate must remain bound to its editor transaction")
	_check(history.get_history_count() == count and target.get_script() == null, "failed preflight must preserve script and Undo history")
	var raw_patch := Tools.prepare_file_patch("raw_script", SCENE, baseline.sha256_text(), [{"start_line": 1, "end_line": 1, "replacement": "[gd_scene format=3]\nscript = ExtResource(\"script\")"}])
	_check(not raw_patch.get("success", true) and str(raw_patch.get("error", "")).contains("execution-trust"), "raw scene patch preparation cannot bypass script trust")
	_check(EditorInterface.get_edited_scene_root() == scene, "conflicts must not close or reload Main")
	await _settle()


func _test_disk_conflict() -> void:
	var baseline := FileAccess.get_file_as_string(SCENE)
	var trust := Tools.prepare_reviewed_change("propose_scene_changes", "disk_conflict", _arguments("detach_script"))
	var prepared := Tools.promote_script_trust(trust)
	_check(prepared.get("success", false), "disk conflict fixture must prepare")
	if not prepared.get("success", false): return
	prepared["_editor_authorization"] = func(): return true
	var file := FileAccess.open(SCENE, FileAccess.WRITE)
	file.store_string(baseline + "\n# independent edit\n")
	file.close()
	_check(Tools.apply_reviewed_change(prepared).begins_with("Conflict:"), "saved hash drift must block editor application")
	file = FileAccess.open(SCENE, FileAccess.WRITE)
	file.store_string(baseline)
	file.close()
	# External writes intentionally change the timestamp. Resynchronize this
	# disposable fixture through the public reload API only after Undo assertions;
	# otherwise the next graphical focus event can open Godot's reload dialog.
	EditorInterface.reload_scene_from_path(SCENE)
	await _settle()


func _attach_for_detach(target: Node) -> void:
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "detach_fixture_attach", _arguments("attach_script"))
	proposal = Tools.promote_script_trust(proposal)
	_check(proposal.get("success", false), "fresh editor attachment must prepare: " + str(proposal.get("error", "")))
	if not proposal.get("success", false): return
	proposal["_editor_authorization"] = func(): return true
	var result := Tools.apply_reviewed_change(proposal)
	_check(result.begins_with("Applied in editor:"), "fresh attachment: " + result)
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()
	view.agent_controller.send_user_message("Detach the menu script")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("detach_live", "detach_script")]})
	await _settle()
	var card = view._change_cards.get("detach_live")
	_check(card != null, "detach must prepare against the saved open scene")
	if card == null: return
	card._apply_button.pressed.emit()
	await _settle()
	_check(card._apply_button.visible, "detach candidate must validate: " + card._status_label.tooltip_text)
	if not card._apply_button.visible: return
	card._apply_button.pressed.emit()
	await _settle()
	_check(target.get_script() == null, "reviewed detach must remove script in editor")
	client.complete({"role": "assistant", "content": "Detached in editor."})
	await _settle()
	await _shortcut(false)
	_check(target.get_script() != null and target.get("speed") == 12.0, "detach Undo must restore script properties")
	# The coordinator and its dock can be released while native actions survive.
	view.queue_free()
	view = null
	await _settle()
	await _shortcut(true)
	_check(target.get_script() == null, "native actions must survive dock/controller teardown")
	await _shortcut(false)
	_check(target.get_script() != null, "native Undo must not call a released Orca coordinator")
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()


func _arguments(operation: String) -> Dictionary:
	return {"scene_path": SCENE, "base_hash": FileAccess.get_file_as_string(SCENE).sha256_text(), "operations": [{"operation": operation, "node_path": "./Menu", "script_path": SCRIPT, "script_hash": FileAccess.get_file_as_string(SCRIPT).sha256_text()}]}


func _call(id: String, operation: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify(_arguments(operation))}}


func _shortcut(redo: bool) -> void:
	var viewport := EditorInterface.get_base_control().get_viewport()
	var focused := viewport.gui_get_focus_owner()
	if focused != null: focused.release_focus()
	var key := InputEventKey.new()
	key.keycode = KEY_Z
	key.ctrl_pressed = true
	key.shift_pressed = redo
	key.pressed = true
	viewport.push_input(key)
	key = key.duplicate()
	key.pressed = false
	viewport.push_input(key)
	await _settle()


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)


func _finish() -> void:
	if view != null:
		if view.agent_controller.is_busy(): view.agent_controller.cancel_current_request()
		view.queue_free()
	await _settle()
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()
	for failure in failures: print("FAIL: ", failure)
	print("editor_scene_script_test: PASS" if failures.is_empty() else "editor_scene_script_test: FAIL")
	quit(0 if failures.is_empty() else 1)
