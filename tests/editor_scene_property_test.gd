@tool
extends "res://tests/editor_test_case.gd"

const Tools = preload("res://addons/orca/scripts/tools.gd")
const Contract = preload("res://addons/orca/scripts/scene_proposal.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const SceneCard = preload("res://addons/orca/scripts/scene_change_card.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const SCENE := "res://tests/fixtures/editor_property_scene.tscn"
const OTHER := "res://tests/fixtures/editor_attach_other.tscn"

class StopAfterEditorApply extends RefCounted:
	var controller
	func get_tool_definitions(edit: bool, switch: bool) -> Array: return Tools.get_tool_definitions(edit, switch)
	func prepare_reviewed_change(name: String, id: String, arguments: Dictionary) -> Dictionary: return Tools.prepare_reviewed_change(name, id, arguments)
	func apply_reviewed_change(proposal: Dictionary) -> String:
		var result := Tools.apply_reviewed_change(proposal)
		controller.cancel_current_request()
		return result

var failures: Array[String] = []
var scene: Node
var manager: EditorUndoRedoManager
var history: UndoRedo
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
	scene = EditorInterface.get_edited_scene_root()
	manager = EditorInterface.get_editor_undo_redo()
	history = manager.get_history_undo_redo(manager.get_object_history_id(scene))
	manager.create_action("Earlier user move", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(scene, "position", Vector2(3, 4))
	manager.add_undo_property(scene, "position", Vector2.ZERO)
	manager.commit_action()
	_check(not _prepare("dirty", "./Actor", "position", _vector(10, 20)).get("success", true), "dirty initial scene must fail")
	await _save()
	_test_nonexecuting_preflight()
	await _test_conflicts()
	await _test_controller()
	await _test_stop_after_application()
	await _test_supported_properties()
	await _test_disk_and_identity_conflicts()
	if view != null:
		view.queue_free()
		await _settle()
	await _save()
	for failure in failures: print("FAIL: ", failure)
	print("editor_scene_property_test: PASS" if failures.is_empty() else "editor_scene_property_test: FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_nonexecuting_preflight() -> void:
	var native := '[gd_scene format=3]\n[node name="Root" type="Node"]\n'
	_check(Contract.preflight_editor_property_content(native).is_empty(), "native Node root must be accepted")
	for content in [
		native + 'metadata/state = Object(GDScript)\n',
		native + '[ext_resource type="Script" path="res://unknown.gd" id="1"]\n',
		native + '[sub_resource type="GDScript" id="1"]\n',
		'[gd_scene format=3]\n[node name="Root" type="UnreviewedGlobalClass"]\n',
		'[gd_scene format=3]\n[node name="Root" type="Node" type = "UnreviewedGlobalClass"]\n',
		'[gd_scene format=3]\n[node name="Root" type="Node"\n type="UnreviewedGlobalClass"]\n',
		native + '[connection signal="ready" from="." to="." method="queue_free"]\n',
	]:
		_check(not Contract.preflight_editor_property_content(content).is_empty(), "executable/reference/ambiguous syntax must fail before any load")
	var oversized: Array = []
	oversized.resize(Contract.MAX_VARIANT_WORK_ITEMS + 1)
	_check(Contract._variant_has_unsafe_object(oversized, 0), "serialized collection scan work must be bounded independently of returned records")


func _test_conflicts() -> void:
	var target := scene.get_node("Actor") as Node2D
	var count := history.get_history_count()
	var proposal := _prepare("conflict", "./Actor", "position", _vector(10, 20))
	_check(proposal.get("success", false), "property fixture must prepare: " + str(proposal.get("error", "")))
	if not proposal.get("success", false): return
	_check(proposal.get("application_strategy") == "editor_current" and proposal.get("approval_stage") != "script_trust", "native property must use exact Apply without script trust")
	_check(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "direct property Apply must require runtime approval")
	proposal["_editor_authorization"] = func(): return false
	_check(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "revoked authorization must fail")
	proposal["_editor_authorization"] = func(): return true
	target.position = Vector2(99, 100)
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "unmarked live property drift must fail")
	target.position = Vector2.ZERO
	var unowned := Node2D.new()
	scene.add_child(unowned)
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "unowned live nodes must not disappear from parity checks")
	scene.remove_child(unowned)
	unowned.free()
	var tampered := proposal.duplicate(true)
	tampered["scene_summary"]["after"] = _vector(999, 1000)
	_check(Tools.apply_reviewed_change(tampered).begins_with("Error:"), "review summary must remain immutable")
	var allowed_calls := [0]
	proposal["_editor_authorization"] = func():
		allowed_calls[0] += 1
		return allowed_calls[0] == 1
	_check(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "authorization must be rechecked after validation")
	proposal["_editor_authorization"] = func(): return true
	EditorInterface.open_scene_from_path(OTHER)
	await _settle()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "Apply must fail if the scene tab changed")
	var background := _prepare("background", "./Actor", "position", _vector(10, 20))
	_check(not background.get("success", true) and str(background.get("error", "")).contains("active tab"), "background target must request a tab switch")
	EditorInterface.open_scene_from_path(SCENE)
	await _settle()
	manager.create_action("Intervening edit", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(target, "position", Vector2(1, 2))
	manager.add_undo_property(target, "position", Vector2.ZERO)
	manager.commit_action()
	await _save()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "a newer saved edit must invalidate a reviewed proposal")
	await _shortcut(false)
	await _save()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "Undo to identical bytes must not revive stale history authority")
	_check(target.position == Vector2.ZERO and count <= history.get_history_count(), "denials must preserve current state and earlier Undo")
	var redo_review := _prepare("redo_branch", "./Actor", "position", _vector(10, 20))
	_check(redo_review.get("success", false), "redo-branch fixture must prepare")
	if redo_review.get("success", false):
		redo_review["_editor_authorization"] = func(): return true
		var branch_count := history.get_history_count()
		manager.create_action("Intervening edit", UndoRedo.MERGE_DISABLE, scene)
		manager.add_do_property(target, "position", Vector2(5, 6))
		manager.add_undo_property(target, "position", Vector2.ZERO)
		manager.commit_action()
		await _shortcut(false)
		await _save()
		_check(history.get_history_count() == branch_count and Tools.apply_reviewed_change(redo_review).begins_with("Conflict:"), "replacement of a same-sized redo branch must permanently invalidate pending review")
	for args in [
		_arguments("./Canvas/Box/Managed", "offset_right", _float(200)),
		_arguments("./Actor", "rotation", {"type": "String", "value": "bad"}),
		_arguments("./Actor", "scale", _vector(0, 1)),
		_arguments("./Actor", "position", _vector(1000001, 0)),
		_arguments("./Canvas/Panel", "anchor_right", _float(2)),
		_arguments("./Canvas/Panel", "position", _vector(2, 3)),
		_arguments("./Actor", "visible", {"type": "bool", "value": false}),
	]:
		_check(not Tools.prepare_reviewed_change("propose_scene_changes", "unsupported", args).get("success", true), "unsupported/Container/type/range property must fail")
	# Existing @tool source must be rejected without invoking project getters.
	var script := GDScript.new()
	script.source_code = '@tool\nextends Node2D\nvar accesses := 0\nfunc _get(property):\n\taccesses += 1\n\treturn null\n'
	_check(script.reload() == OK, "getter-isolation fixture must compile")
	target.set_script(script)
	var rejected := _prepare("live_script", "./Actor", "position", _vector(10, 20))
	_check(not rejected.get("success", true) and target.get("accesses") == 0, "unmarked live script must be rejected without custom getters")
	target.set_script(null)


func _test_controller() -> void:
	view = ChatScene.instantiate()
	root.add_child(view)
	await _settle()
	view._on_new_session_pressed()
	client = Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.agent_controller.set_mode(0)
	view.agent_controller.send_user_message("Inspect only")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("plan", _arguments("./Actor", "position", _vector(10, 20)))]})
	await _settle()
	_check(not view._change_cards.has("plan") and scene.get_node("Actor").position == Vector2.ZERO, "Plan must deny property mutation")
	client.complete({"role": "assistant", "content": "Plan remains read-only."})
	await _settle()
	view.agent_controller.set_mode(1)
	_check(view.agent_controller.set_auto_apply_enabled(true), "test must enable bounded script Auto apply")
	for action in ["reject", "cancel", "apply"]:
		view.agent_controller.send_user_message("Move the actor")
		client.complete({"role": "assistant", "content": "", "tool_calls": [_call(action, _arguments("./Actor", "position", _vector(10, 20)))]})
		await _settle()
		var card = view._change_cards.get(action)
		_check(card != null and card._apply_button.visible and card._apply_button.text == "Apply in editor", "Auto apply must still suspend for exact native property review")
		if card == null: return
		_check(scene.get_node("Actor").position == Vector2.ZERO, "review must not mutate the live scene")
		if action == "cancel":
			view.agent_controller.cancel_current_request()
			await _settle()
			card._apply_button.pressed.emit()
			_check(scene.get_node("Actor").position == Vector2.ZERO, "a stale cancelled Apply must not mutate")
			_check(_receipt_count(action) == 1, "Stop must close the exact tool call once")
			continue
		if action == "reject":
			card._reject_button.pressed.emit()
			await _settle()
			_check(scene.get_node("Actor").position == Vector2.ZERO, "Reject must preserve state")
			client.complete({"role": "assistant", "content": "Rejected."})
			await _settle()
			continue
		await _test_localized_review(card)
		var baseline := FileAccess.get_file_as_string(SCENE)
		var count := history.get_history_count()
		var action_index := history.get_current_action()
		card._apply_button.pressed.emit()
		await _settle()
		_check(scene.get_node("Actor").position == Vector2(10, 20) and EditorInterface.get_edited_scene_root() == scene, "Apply must change the exact native property and keep the scene open")
		_check(FileAccess.get_file_as_string(SCENE) == baseline and SCENE in EditorInterface.get_unsaved_scenes(), "Apply must leave disk unchanged and mark save pending")
		_check(history.get_current_action() == action_index + 1 and history.get_history_count() <= count + 1, "Apply must add exactly one Undo action while dropping only a pre-existing redo branch")
		_check(_receipt_count(action) == 1, "Apply must produce exactly one matching tool receipt")
		var retained: Dictionary = view.agent_controller._proposals[action]
		_check(not view.agent_controller._proposal_for_review(retained).has("_editor_transaction"), "live transaction must not enter review/history")
		client.complete({"role": "assistant", "content": "Moved in editor; save before running."})
		await _settle()
		await _shortcut(false)
		_check(scene.get_node("Actor").position == Vector2.ZERO, "native Undo must restore the previous value")
		await _shortcut(true)
		_check(scene.get_node("Actor").position == Vector2(10, 20), "native Redo must restore the approved value")
		await _save()
		view.agent_controller.queue_editor_scene_refresh()
		await _settle()
		_check(card._status_label.text in ["Saved", "Save observed"] and card._status_label.get_parent()._note.text.to_lower().contains("not verified"), "save observation must remain distinct from runtime verification")
		view.agent_controller.set_mode(0)
		view.agent_controller.revert_edit(action)
		_check(scene.get_node("Actor").position == Vector2(10, 20), "Plan must deny inverse Revert")
		view.agent_controller.set_mode(1)
		view.agent_controller.revert_edit(action)
		await _settle()
		_check(scene.get_node("Actor").position == Vector2.ZERO and FileAccess.get_file_as_string(SCENE) != baseline, "Revert must add an inverse editor action and preserve saved disk")
		await _shortcut(false)
		_check(scene.get_node("Actor").position == Vector2(10, 20), "inverse Revert must itself be undoable")
		view._on_new_session_pressed()
		view._new_session_dialog.hide()
		view._new_session_dialog.confirmed.emit()
		await _settle()
		_check(view.agent_controller._proposals.is_empty(), "New Session must release transaction authority")
		await _shortcut(true)
		_check(scene.get_node("Actor").position == Vector2.ZERO, "native Redo must survive released session authority")
		await _save()


func _test_supported_properties() -> void:
	for entry in [
		["./Actor", "position", _vector(30, 40)],
		["./Actor", "rotation", _float(0.5)],
		["./Actor", "rotation", _float(0.1)],
		["./Actor", "scale", _vector(2, 3)],
		["./Actor", "scale", _vector(2.1, 3.2)],
		["./Actor", "skew", _float(0.25)],
		["./Canvas/Panel", "anchor_left", _float(0.25)],
		["./Canvas/Panel", "anchor_left", _float(0.1)],
		["./Canvas/Panel", "anchor_top", _float(0.25)],
		["./Canvas/Panel", "anchor_right", _float(0.75)],
		["./Canvas/Panel", "anchor_bottom", _float(0.75)],
		["./Canvas/Panel", "offset_left", _float(40)],
		["./Canvas/Panel", "offset_left", _float(20.1)],
		["./Canvas/Panel", "offset_top", _float(50)],
		["./Canvas/Panel", "offset_right", _float(-40)],
		["./Canvas/Panel", "offset_bottom", _float(-50)],
	]:
		var target: Node = scene.get_node(NodePath(entry[0]))
		var before = ClassDB.class_get_property(target, entry[1])
		var proposal := _prepare("native", entry[0], entry[1], entry[2])
		_check(proposal.get("success", false), "supported property must prepare " + entry[1] + ": " + str(proposal.get("error", "")))
		if not proposal.get("success", false): continue
		if entry[1].begins_with("anchor_"):
			_check(proposal["scene_summary"].has("derived_anchors_preset"), "anchor review must include exact derived preset metadata")
			var tampered := proposal.duplicate(true)
			tampered["scene_summary"]["derived_anchors_preset"]["after"] = {"type": "int", "value": 999}
			_check(not Contract.validate_candidate(tampered).is_empty(), "unreviewed derived preset transition must be rejected")
			if entry[1] == "anchor_left" and entry[2] == _float(0.25):
				var card := SceneCard.new()
				root.add_child(card)
				card.configure(view.agent_controller._proposal_for_review(proposal))
				await _test_localized_review(card)
				card.queue_free()
				await _settle()
		var after = Contract._decode_typed_value(proposal["operations"][0]["value"])["value"]
		if entry[1] == "rotation" and entry[2] == _float(0.1):
			_check(proposal.get("requested_value") == entry[2] and proposal["scene_summary"]["after"] != entry[2], "ordinary decimals must preserve the request and explicitly review native precision")
			var invalid_request := proposal.duplicate(true)
			invalid_request["requested_value"] = _float(999)
			_check(not Contract.validate_candidate(invalid_request).is_empty(), "native precision must remain bound to the original requested value")
			var precision_card := SceneCard.new()
			root.add_child(precision_card)
			precision_card.configure(view.agent_controller._proposal_for_review(proposal))
			await _test_localized_review(precision_card)
			precision_card.queue_free()
			await _settle()
		proposal["_editor_authorization"] = func(): return true
		var result := Tools.apply_reviewed_change(proposal)
		_check(result.begins_with("Applied in editor:"), "native property Apply " + entry[1] + ": " + result)
		await _settle()
		_check(ClassDB.class_get_property(target, entry[1]) == after, "approved value must survive deferred editor layout: " + entry[1])
		_check(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "duplicate Apply must be denied")
		await _shortcut(false)
		_check(ClassDB.class_get_property(target, entry[1]) == before, "native Undo must restore " + entry[1])
		await _shortcut(true)
		_check(ClassDB.class_get_property(target, entry[1]) == after, "native Redo must restore " + entry[1])
		await _save()
		_check(Tools.revert_reviewed_change(proposal).begins_with("Reverted in editor:"), "saved property must support conflict-checked inverse: " + entry[1])
		await _save()
	# Native actions retain only native targets/values, independent of the dock.
	view.queue_free()
	view = null
	await _settle()
	await _shortcut(false)
	_check(scene.get_node("Canvas/Panel").offset_bottom == -50, "Undo must survive dock teardown")
	await _shortcut(true)
	await _save()


func _test_stop_after_application() -> void:
	var wrapper := StopAfterEditorApply.new()
	wrapper.controller = view.agent_controller
	view.agent_controller.tools_script = wrapper
	view.agent_controller.send_user_message("Move the actor, then stop")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("stop_after_apply", _arguments("./Actor", "position", _vector(20, 30)))]})
	await _settle()
	var card = view._change_cards.get("stop_after_apply")
	_check(card != null, "Stop-after-application fixture must reach review")
	if card == null: return
	card._apply_button.pressed.emit()
	await _settle()
	_check(not view.agent_controller.is_busy() and scene.get_node("Actor").position == Vector2(20, 30), "Stop during completed commit must preserve the true applied editor state")
	_check(_receipt_count("stop_after_apply") == 1, "Stop after editor application must retain one matching receipt")
	_check(view.agent_controller._proposals.get("stop_after_apply", {}).get("status") == "applied_editor", "Stop must retain editor save-pending recovery authority")
	view.agent_controller.tools_script = Tools
	view.agent_controller.revert_edit("stop_after_apply")
	await _settle()
	_check(scene.get_node("Actor").position == Vector2.ZERO, "stopped editor operation must remain explicitly revertible")
	await _save()


func _test_disk_and_identity_conflicts() -> void:
	var proposal := _prepare("stale_root", "./Actor", "position", _vector(30, 40))
	_check(proposal.get("success", false), "identity-conflict fixture must prepare")
	if not proposal.get("success", false): return
	proposal["_editor_authorization"] = func(): return true
	_check(Tools.apply_reviewed_change(proposal).begins_with("Applied in editor:"), "Revert conflict fixture must apply")
	var target := scene.get_node("Actor") as Node2D
	target.rotation = 0.25
	_check(Tools.revert_reviewed_change(proposal).begins_with("Conflict:") and target.position == Vector2(30, 40), "inverse must not overwrite unrelated live changes")
	target.rotation = 0.0
	manager.create_action("Newer user edit", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(target, "rotation", 0.5)
	manager.add_undo_property(target, "rotation", 0.0)
	manager.commit_action()
	_check(Tools.revert_reviewed_change(proposal).begins_with("Conflict:"), "inverse must not rewind newer native actions")
	await _shortcut(false)
	_check(Tools.revert_reviewed_change(proposal).begins_with("Conflict:"), "inverse must preserve a newer redo branch")
	await _shortcut(false)
	await _save()
	proposal = _prepare("stale_root", "./Actor", "position", _vector(30, 40))
	_check(proposal.get("success", false), "saved-byte conflict fixture must prepare")
	if not proposal.get("success", false): return
	proposal["_editor_authorization"] = func(): return true
	var baseline := FileAccess.get_file_as_string(SCENE)
	var file := FileAccess.open(SCENE, FileAccess.WRITE)
	file.store_string(baseline + "\n# independent edit\n")
	file.close()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "saved-byte drift must block Apply")
	file = FileAccess.open(SCENE, FileAccess.WRITE)
	file.store_string(baseline)
	file.close()
	EditorInterface.reload_scene_from_path(SCENE) # disposable fixture only
	await _settle()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "reopened scene identity must not revive approval")
	scene = EditorInterface.get_edited_scene_root()


func _test_localized_review(card: Control) -> void:
	var property_name: String = card._proposal.get("scene_summary", {}).get("property_name", "")
	var controls: Array = [card._title_label, card._status_label, card._apply_button, card._reject_button, card._validation_label, card._find_details(card)]
	var fonts: Array = []
	for control in controls: fonts.append(control.get_theme_font_size("font_size"))
	for locale in ["en", "zh_CN", "es", "ja", "ko"]:
		Localization.select_language(locale)
		for multiplier in [1.0, 1.5, 2.0]:
			for index in controls.size(): controls[index].add_theme_font_size_override("font_size", roundi(fonts[index] * multiplier))
			card.size = Vector2(UiMetrics.scaled(264), 0)
			await _settle()
			var details: Label = card._find_details(card)
			_check(details.text.contains(property_name) and details.text.contains(SCENE), "review must preserve property/path identities in " + locale)
			_check(not details.text.contains("Script trust"), "native property review must not imply script execution approval")
			_check(card.get_combined_minimum_size().x <= UiMetrics.scaled(300) and details.get_visible_line_count() == details.get_line_count(), "complete native property review must fit the narrow dock at scaled fonts")
			if card._proposal.get("scene_summary", {}).has("derived_anchors_preset"):
				_check(details.text.contains("anchors_preset") and details.text.contains("15"), "localized anchor review must retain the exact derived preset identity/values")
			if card._proposal.has("requested_value"):
				_check(details.text.contains(JSON.stringify(card._proposal["requested_value"])), "native precision disclosure must retain the original requested typed value")
	Localization.select_language("en")
	for index in controls.size(): controls[index].add_theme_font_size_override("font_size", fonts[index])
	await _settle()


func _receipt_count(id: String) -> int:
	var count := 0
	for message in view.agent_controller.message_history:
		if message.get("role") == "tool" and message.get("tool_call_id") == id: count += 1
	return count


func _save() -> void:
	EditorInterface.save_scene_as(SCENE, false)
	await _settle()


func _arguments(node_path: String, property: String, value: Dictionary) -> Dictionary:
	return {"scene_path": SCENE, "base_hash": FileAccess.get_file_as_string(SCENE).sha256_text(), "operations": [{"operation": "set_property", "node_path": node_path, "property_name": property, "value": value}]}


func _prepare(id: String, node_path: String, property: String, value: Dictionary) -> Dictionary:
	return Tools.prepare_reviewed_change("propose_scene_changes", id, _arguments(node_path, property, value))


func _call(id: String, arguments: Dictionary) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify(arguments)}}


func _vector(x: float, y: float) -> Dictionary: return {"type": "Vector2", "x": x, "y": y}
func _float(value: float) -> Dictionary: return {"type": "float", "value": value}
func _check(value: bool, message: String) -> void:
	if not value: failures.append(message)


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
