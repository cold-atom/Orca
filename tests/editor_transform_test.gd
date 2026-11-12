@tool
extends "res://tests/editor_test_case.gd"

const Tools = preload("res://addons/orca/scripts/tools.gd")
const Reader = preload("res://addons/orca/scripts/saved_scene_transform.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const GAME := "res://tests/fixtures/editor_transform_game.tscn"
const COIN := "res://tests/fixtures/editor_transform_coin.tscn"
var failures: Array[String] = []
var view
var client

class StopAfterTransform extends RefCounted:
	var controller
	func get_tool_definitions(edit: bool, switch: bool) -> Array: return Tools.get_tool_definitions(edit, switch)
	func prepare_reviewed_change(name: String, id: String, arguments: Dictionary) -> Dictionary: return Tools.prepare_reviewed_change(name, id, arguments)
	func apply_reviewed_change(proposal: Dictionary) -> String:
		var result := Tools.apply_reviewed_change(proposal)
		controller.cancel_current_request()
		return result

func _ready() -> void: call_deferred("_run")
func _settle() -> void:
	for frame in 12: await process_frame
func _check(value: bool, message: String) -> void:
	if not value: failures.append(message)
func _arguments(path: String, property: String, value: Dictionary) -> Dictionary:
	return {"scene_path": GAME, "base_hash": FileAccess.get_file_as_string(GAME).sha256_text(), "operations": [{"operation": "set_property", "node_path": path, "property_name": property, "value": value}]}
func _call(id: String, args: Dictionary) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify(args)}}

func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	EditorInterface.open_scene_from_path(GAME)
	await _settle()
	var root_scene := EditorInterface.get_edited_scene_root()
	var coin := root_scene.get_node("Coins/Coin2") as Node2D
	var other := root_scene.get_node("Coins/Coin") as Node2D
	EditorInterface.save_scene_as(GAME, false)
	await _settle()
	var baseline := FileAccess.get_file_as_string(GAME)
	var coin_bytes := FileAccess.get_file_as_string(COIN)
	var parsed := Reader.inspect(GAME, "./Coins/Coin2")
	_check(parsed.get("success", false) and parsed.get("values", {}).get("position") == Vector2(91, 108), "saved instance overrides must resolve without loading: " + str(parsed.get("error", "")))
	for invalid in ['[gd_scene format=3]\n[node name="Game" name="Other" type="Node2D"]\n', '[gd_scene format=3]\n[node name="Game" type="Node2D"]\nposition = Object(GDScript)\n', '[gd_scene format=3]\n[node name="Game" type="Node2D"]\nposition = Vector2(1, 2)\nposition = Vector2(3, 4)\n', '[gd_scene format=3]\n[node name="Game" type="Node2D"]\nmetadata/text = "fake\n[node name="Other" type="Node2D"]\n"\n']:
		_check(not Reader.inspect(GAME, ".", invalid).get("success", true), "malformed/executable/duplicate target literals must fail without loading")
	var args := _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 120, "y": 80})
	await _test_conflicts(root_scene, coin, args)
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "coin", args)
	_check(proposal.get("success", false), "a scripted coin instance in a resource/signal scene must prepare: " + str(proposal.get("error", "")))
	if proposal.get("success", false):
		_check(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "native instance Apply requires exact runtime authorization")
		var tampered := proposal.duplicate(true)
		tampered["scene_summary"]["after"]["x"] = 500
		tampered["_editor_authorization"] = func(): return true
		_check(Tools.apply_reviewed_change(tampered).begins_with("Error:"), "review metadata must remain immutable")
	view = ChatScene.instantiate()
	root.add_child(view)
	await _settle()
	view._on_new_session_pressed()
	client = Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.agent_controller.set_mode(0)
	view.agent_controller.send_user_message("Inspect Coin2")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("plan", args)]})
	await _settle()
	_check(not view._change_cards.has("plan") and coin.get_position() == Vector2(91, 108), "Plan must deny instanced transform mutation")
	client.complete({"role": "assistant", "content": "Read-only."})
	await _settle()
	view.agent_controller.set_mode(1)
	view.agent_controller.set_auto_apply_enabled(true)
	view.agent_controller.send_user_message("Move Coin2, keeping the scene open")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("move", args)]})
	await _settle()
	var card = view._change_cards.get("move")
	_check(card != null and card._apply_button.text == "Apply in editor" and coin.get_position() == Vector2(91, 108), "script Auto apply must still wait for native instance review")
	if card != null:
		for locale in ["en", "zh_CN", "es", "ja", "ko"]:
			Localization.select_language(locale)
			await _settle()
			_check(card._find_details(card).text.contains(COIN), "native instance review must preserve origin source in every locale")
		Localization.select_language("en")
		card._apply_button.pressed.emit()
		await _settle()
		_check(coin.get_position() == Vector2(120, 80) and EditorInterface.get_edited_scene_root() == root_scene, "Apply must move Coin2 while keeping Game open")
		_check(other.get_position() == Vector2(51, 103) and FileAccess.get_file_as_string(COIN) == coin_bytes, "shared coin source/other instances must remain intact")
		_check(FileAccess.get_file_as_string(GAME) == baseline and GAME in EditorInterface.get_unsaved_scenes(), "Apply must leave Game save pending")
		_check(coin.get("interceptions") == 0, "native transform writes must not dispatch project getters/setters/method overrides")
		client.complete({"role": "assistant", "content": "Moved in editor; save Game."})
		await _settle()
		await _shortcut(false)
		_check(coin.get_position() == Vector2(91, 108), "native Undo must restore Coin2")
		await _shortcut(true)
		_check(coin.get_position() == Vector2(120, 80), "native Redo must restore the approved override")
		EditorInterface.save_scene_as(GAME, false)
		await _settle()
		view.agent_controller.revert_edit("move")
		await _settle()
		_check(coin.get_position() == Vector2(91, 108), "saved instance transform must support explicit inverse Revert")
		await _shortcut(false)
		_check(coin.get_position() == Vector2(120, 80), "inverse action must itself support native Undo")
		view.queue_free()
		view = null
		await _settle()
		await _shortcut(true)
		_check(coin.get_position() == Vector2(91, 108), "native actions must survive dock teardown")
		EditorInterface.save_scene_as(GAME, false)
		await _settle()
	_check(not Tools.prepare_reviewed_change("propose_scene_changes", "internal", _arguments("./Coins/Coin2/Sprite2D", "position", {"type": "Vector2", "x": 2, "y": 3})).get("success", true), "internal non-editable instance nodes require a separate contract")
	for entry in [[".", "position", {"type": "Vector2", "x": 10, "y": 15}], ["./LocalActor", "rotation", {"type": "float", "value": 0.1}], ["./Coins/Coin2", "scale", {"type": "Vector2", "x": 1.5, "y": 2}], ["./Coins/Coin2", "skew", {"type": "float", "value": 0.25}]]:
		var change := Tools.prepare_reviewed_change("propose_scene_changes", "native", _arguments(entry[0], entry[1], entry[2]))
		_check(change.get("success", false), "scripted root/local/instance transforms must prepare: " + str(change.get("error", "")))
		if not change.get("success", false): continue
		change["_editor_authorization"] = func(): return true
		_check(Tools.apply_reviewed_change(change).begins_with("Applied in editor:"), "native scripted transform must apply")
		_check(Tools.revert_reviewed_change(change).begins_with("Reverted in editor:"), "save-pending native transform must support explicit inverse")
		EditorInterface.save_scene_as(GAME, false)
		await _settle()
	await _test_unsaved_workflow(root_scene, coin, other)
	await _test_disk_proposal_routing()
	await _test_source_changes()
	if view != null: view.queue_free()
	await _settle()
	for failure in failures: print("FAIL: ", failure)
	print("editor_transform_test: PASS" if failures.is_empty() else "editor_transform_test: FAIL")
	quit(0 if failures.is_empty() else 1)

func _test_conflicts(scene: Node, target: Node2D, args: Dictionary) -> void:
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "conflicts", args)
	_check(proposal.get("success", false), "conflict fixture must prepare")
	if not proposal.get("success", false): return
	proposal["_editor_authorization"] = func(): return true
	target.set_position(Vector2(90, 100))
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "unmarked native transform drift must fail")
	target.set_position(Vector2(91, 108))
	var manager := EditorInterface.get_editor_undo_redo()
	manager.create_action("Newer user move", UndoRedo.MERGE_DISABLE, scene)
	manager.add_do_property(target, "position", Vector2(92, 109))
	manager.add_undo_property(target, "position", Vector2(91, 108))
	manager.commit_action()
	var dirty := Tools.prepare_reviewed_change("propose_scene_changes", "dirty", args)
	_check(dirty.get("success", false) and dirty.get("scene_summary", {}).get("before") == {"type": "Vector2", "x": 92.0, "y": 109.0}, "dirty game scenes must review the actual live transform")
	await _shortcut(false)
	EditorInterface.save_scene_as(GAME, false)
	await _settle()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "Undo cannot revive a stale instance review")
	var local := scene.get_node("LocalActor")
	var original = local.get_script()
	var tool := GDScript.new()
	tool.source_code = "@tool\nextends Node2D\n"
	tool.reload()
	local.set_script(tool)
	var denied := Tools.prepare_reviewed_change("propose_scene_changes", "tool", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 120, "y": 80}))
	_check(not denied.get("success", true) and str(denied.get("error", "")).contains("@tool"), "unrelated live @tool nodes require a separate trust contract")
	local.set_script(original)


func _test_unsaved_workflow(scene: Node2D, target: Node2D, other: Node2D) -> void:
	var disk_before := FileAccess.get_file_as_string(GAME)
	var shared_before := FileAccess.get_file_as_string(COIN)
	var original_position := target.get_position()
	var original_other := other.get_position()
	var original_modulate: Color = ClassDB.class_get_property(scene, "modulate")
	var manager := EditorInterface.get_editor_undo_redo()
	manager.create_action("Earlier unsaved user edits", UndoRedo.MERGE_DISABLE, scene)
	for entry in [[target, "position", Vector2(87, 106), original_position], [other, "position", Vector2(55, 105), original_other], [scene, "modulate", Color(0.75, 0.8, 0.9, 1), original_modulate]]:
		manager.add_do_property(entry[0], entry[1], entry[2])
		manager.add_undo_property(entry[0], entry[1], entry[3])
	manager.commit_action()
	await _settle()
	_check(GAME in EditorInterface.get_unsaved_scenes(), "live baseline fixture must begin with actual unsaved native edits")
	var structural := Tools.prepare_reviewed_change("propose_scene_changes", "dirty_add", {"scene_path": GAME, "base_hash": disk_before.sha256_text(), "operations": [{"operation": "add_node", "parent_path": ".", "node_name": "NewChild", "node_type": "Node2D"}]})
	_check(not structural.get("success", true) and str(structural.get("error", "")).contains("unsaved"), "structural changes must retain the dirty-scene guard")
	var no_op := Tools.prepare_reviewed_change("propose_scene_changes", "same_live", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 87, "y": 106}))
	_check(no_op.get("success", false) and no_op.get("no_changes", false), "no-op detection must use the live value even when disk differs")
	var disk_value := Tools.prepare_reviewed_change("propose_scene_changes", "different_live", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": original_position.x, "y": original_position.y}))
	_check(disk_value.get("success", false) and not disk_value.get("no_changes", true), "requesting the saved value must still propose a change when the live value differs")
	if disk_value.get("success", false):
		disk_value["_editor_authorization"] = func(): return true
		_check(Tools.apply_reviewed_change(disk_value).begins_with("Applied in editor:") and target.get_position() == original_position, "a zero-disk-diff proposal must still apply the reviewed live change")
		await _shortcut(false)
		_check(target.get_position() == Vector2(87, 106), "Undo must restore the user's unsaved value rather than the saved projection")
		await _shortcut(true)
		_check(Tools.revert_reviewed_change(disk_value).begins_with("Reverted in editor:") and target.get_position() == Vector2(87, 106), "inverse of a zero-disk-diff proposal must also restore the unsaved value")
	var new_node := Node2D.new()
	new_node.name = "NewUnsavedTarget"
	scene.add_child(new_node)
	new_node.owner = scene
	_check(not Tools.prepare_reviewed_change("propose_scene_changes", "new_target", _arguments("./NewUnsavedTarget", "position", {"type": "Vector2", "x": 1, "y": 2})).get("success", true), "new targets still need saved provenance")
	scene.remove_child(new_node)
	new_node.free()
	view = ChatScene.instantiate()
	root.add_child(view)
	await _settle()
	view._on_new_session_pressed()
	# The real public editor save signal, as wired by Orca's production plugin.
	if view._new_session_dialog.visible:
		view._new_session_dialog.hide()
		view._new_session_dialog.confirmed.emit()
	await _settle()
	(get_parent() as EditorPlugin).scene_saved.connect(view.agent_controller.record_editor_scene_save)
	client = Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view.agent_controller.set_mode(0)
	view.agent_controller.send_user_message("Inspect the unsaved selection")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("dirty_plan", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 120, "y": 80}))]})
	await _settle()
	_check(not view._change_cards.has("dirty_plan") and target.get_position() == Vector2(87, 106) and _receipt_count("dirty_plan") == 1, "Plan must deny dirty-scene transforms with one matching receipt")
	client.complete({"role": "assistant", "content": "Inspected only."})
	await _settle()
	view.agent_controller.set_mode(1)
	view.agent_controller.set_auto_apply_enabled(true)
	_check(view.agent_controller._get_system_prompt().contains("Do not ask to save before or between these transforms"), "Work guidance must route unsaved transforms instead of asking to save")
	for action in ["dirty_reject", "dirty_cancel", "dirty_first"]:
		view.agent_controller.send_user_message("Move selected Coin2 to (120, 80), keeping my unsaved edits")
		client.complete({"role": "assistant", "content": "", "tool_calls": [_call(action, _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 120, "y": 80}))]})
		await _settle()
		var card = view._change_cards.get(action)
		_check(card != null and target.get_position() == Vector2(87, 106), "dirty native edits must wait for exact Apply, including under Auto apply")
		if card == null: return
		_check(card._proposal.get("editor_baseline") == "live" and card._proposal.get("scene_summary", {}).get("before") == {"type": "Vector2", "x": 87.0, "y": 106.0}, "review must show the unsaved position, not the saved one")
		if action == "dirty_reject":
			card._reject_button.pressed.emit()
			client.complete({"role": "assistant", "content": "Rejected."})
			await _settle()
			_check(_receipt_count(action) == 1 and target.get_position() == Vector2(87, 106), "Reject must preserve dirty state and close the call")
			continue
		if action == "dirty_cancel":
			view.agent_controller.cancel_current_request()
			await _settle()
			card._apply_button.pressed.emit()
			_check(_receipt_count(action) == 1 and target.get_position() == Vector2(87, 106), "Stop/stale clicks must preserve earlier unsaved edits")
			continue
		var forged: Dictionary = view.agent_controller._proposals[action].duplicate(true)
		forged["scene_summary"]["before"] = {"type": "Vector2", "x": original_position.x, "y": original_position.y}
		forged["_editor_authorization"] = func(): return true
		_check(Tools.apply_reviewed_change(forged).begins_with("Error:"), "the live review baseline must be immutable")
		var details: Label = card._find_details(card)
		var font := details.get_theme_font_size("font_size")
		for locale in ["en", "zh_CN", "es", "ja", "ko"]:
			Localization.select_language(locale)
			for multiplier in [1.0, 1.5, 2.0]:
				details.add_theme_font_size_override("font_size", roundi(font * multiplier))
				card.size = Vector2(UiMetrics.scaled(264), 0)
				await _settle()
				_check(details.text.contains("87") and details.text.contains("106") and details.text.contains(COIN) and details.get_visible_line_count() == details.get_line_count() and card.get_combined_minimum_size().x <= UiMetrics.scaled(300), "live-baseline review must fit narrow translated layouts and retain original values")
		Localization.select_language("en")
		details.add_theme_font_size_override("font_size", font)
		card._apply_button.pressed.emit()
		await _settle()
		_check(target.get_position() == Vector2(120, 80) and _receipt_count(action) == 1, "first unsaved transform must apply once")
	# A real follow-up tool round in the same active turn, with no save in between.
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("dirty_second", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 140, "y": 90}))]})
	await _settle()
	var second = view._change_cards.get("dirty_second")
	_check(second != null and second._proposal.get("scene_summary", {}).get("before") == {"type": "Vector2", "x": 120.0, "y": 80.0}, "second tool round must review the first unsaved result")
	if second == null: return
	var stop := StopAfterTransform.new()
	stop.controller = view.agent_controller
	view.agent_controller.tools_script = stop
	second._apply_button.pressed.emit()
	await _settle()
	view.agent_controller.tools_script = Tools
	_check(not view.agent_controller.is_busy() and target.get_position() == Vector2(140, 90) and _receipt_count("dirty_second") == 1, "Stop after commit must retain the true unsaved result and one receipt")
	_check(FileAccess.get_file_as_string(GAME) == disk_before and FileAccess.get_file_as_string(COIN) == shared_before and other.get_position() == Vector2(55, 105) and ClassDB.class_get_property(scene, "modulate") == Color(0.75, 0.8, 0.9, 1), "consecutive transforms must preserve unrelated unsaved native edits, other instances and every saved byte")
	await _shortcut(false)
	_check(target.get_position() == Vector2(120, 80), "Undo must restore the preceding unsaved Orca value, got " + str(target.get_position()) + " (" + manager.get_history_undo_redo(manager.get_object_history_id(scene)).get_current_action_name() + ")")
	await _shortcut(true)
	_check(target.get_position() == Vector2(140, 90), "Redo must restore the second unsaved transform")
	view.agent_controller.revert_edit("dirty_second")
	await _settle()
	_check(target.get_position() == Vector2(120, 80), "Revert without saving must restore the immediate live baseline")
	var first: Dictionary = view.agent_controller._proposals["dirty_first"]
	first["_editor_authorization"] = func(): return true
	_check(Tools.revert_reviewed_change(first).begins_with("Conflict:"), "an earlier card must not rewind newer actions after a second move/inverse")
	first.erase("_editor_authorization")
	view.agent_controller.send_user_message("Move Coin2 to (160, 100)")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_call("dirty_saved", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 160, "y": 100}))]})
	await _settle()
	var saved_card = view._change_cards.get("dirty_saved")
	_check(saved_card != null, "follow-up user turn must also accept an unsaved scene")
	if saved_card == null: return
	saved_card._apply_button.pressed.emit()
	await _settle()
	var retained: Dictionary = view.agent_controller._proposals["dirty_saved"]
	var transaction = retained["_editor_transaction"]
	EditorInterface.save_scene_as(GAME, false)
	await _settle()
	var saved_bytes := FileAccess.get_file_as_string(GAME)
	_check(saved_bytes != disk_before and view.agent_controller._editor_save_receipts.has(GAME), "a public native save during continuation must retain bounded save evidence")
	_check(transaction._observed_saved_hash.is_empty(), "save evidence must wait for bounded transaction validation while a turn is active")
	retained["_editor_authorization"] = func(): return true
	_check(Tools.revert_reviewed_change(retained).begins_with("Conflict:"), "unrelated saved edits need a matching validated native-save receipt")
	retained.erase("_editor_authorization")
	client.complete({"role": "assistant", "content": "Moved in editor."})
	await _settle()
	_check(transaction._observed_saved_hash == saved_bytes.sha256_text() and saved_card._status_label.text == "Save observed", "validated save receipt must bind all actual saved bytes without claiming whole-scene verification")
	var external := FileAccess.open(GAME, FileAccess.WRITE)
	external.store_string(saved_bytes + "\nmetadata/external_change = 1\n")
	external.close()
	retained["_editor_authorization"] = func(): return true
	_check(Tools.revert_reviewed_change(retained).begins_with("Conflict:") and target.get_position() == Vector2(160, 100), "later unrelated disk changes must not inherit a previous save receipt")
	retained.erase("_editor_authorization")
	external = FileAccess.open(GAME, FileAccess.WRITE)
	external.store_string(saved_bytes)
	external.close()
	view.agent_controller.revert_edit("dirty_saved")
	await _settle()
	_check(target.get_position() == Vector2(120, 80) and other.get_position() == Vector2(55, 105) and ClassDB.class_get_property(scene, "modulate") == Color(0.75, 0.8, 0.9, 1) and FileAccess.get_file_as_string(GAME) == saved_bytes, "Revert after Save must restore the live baseline and preserve earlier edits and disk")
	var stale := Tools.prepare_reviewed_change("propose_scene_changes", "save_during_review", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 180, "y": 110}))
	_check(stale.get("success", false), "save-during-review fixture must prepare")
	EditorInterface.save_scene_as(GAME, false)
	await _settle()
	stale["_editor_authorization"] = func(): return true
	_check(Tools.apply_reviewed_change(stale).begins_with("Conflict:"), "saving changed scene bytes during review must require fresh provenance")
	view.agent_controller.start_new_session()
	_check(view.agent_controller._editor_save_receipts.is_empty() and view.agent_controller._proposals.is_empty() and not view.agent_controller.snapshot_session_state().has("_editor_save_receipts"), "New Session must discard live transaction/save evidence, never persist authorization")
	view.queue_free()
	view = null
	await _settle()
	await _shortcut(false)
	_check(target.get_position() == Vector2(160, 100), "native inverse Undo must survive session and dock teardown")
	await _shortcut(true)
	# Restore only this disposable fixture's earlier manual edits for later cases.
	manager.create_action("Fixture cleanup", UndoRedo.MERGE_DISABLE, scene)
	for entry in [[target, "position", original_position], [other, "position", original_other], [scene, "modulate", original_modulate]]:
		manager.add_do_property(entry[0], entry[1], entry[2])
		manager.add_undo_property(entry[0], entry[1], ClassDB.class_get_property(entry[0], entry[1]))
	manager.commit_action()
	EditorInterface.save_scene_as(GAME, false)
	await _settle()


func _receipt_count(id: String) -> int:
	var count := 0
	for message in view.agent_controller.message_history:
		if message.get("role") == "tool" and message.get("tool_call_id") == id: count += 1
	return count

func _test_disk_proposal_routing() -> void:
	var path := "res://tests/fixtures/editor_transform_disk.tscn"
	var bytes := '[gd_scene format=3]\n\n[node name="Disk" type="Node2D"]\n'
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(bytes)
	file.close()
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "disk", {"scene_path": path, "base_hash": bytes.sha256_text(), "operations": [{"operation": "set_property", "node_path": ".", "property_name": "position", "value": {"type": "Vector2", "x": 5, "y": 6}}]})
	_check(proposal.get("success", false), "closed-scene disk proposal must prepare")
	EditorInterface.open_scene_from_path(path)
	await _settle()
	var result := Tools.apply_reviewed_change(proposal)
	_check(result.contains("fresh current-scene proposal") and FileAccess.get_file_as_string(path) == bytes, "opening a disk proposal's scene must request fresh native review without changing strategy or disk")
	var refreshed := Tools.prepare_reviewed_change("propose_scene_changes", "fresh", {"scene_path": path, "base_hash": bytes.sha256_text(), "operations": proposal.get("operations", [])})
	_check(refreshed.get("success", false) and refreshed.get("editor_validation") == "native_transform", "fresh proposal in an open saved scene must route to native editor strategy")
	EditorInterface.open_scene_from_path(GAME)
	await _settle()

func _test_source_changes() -> void:
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "source_conflict", _arguments("./Coins/Coin2", "position", {"type": "Vector2", "x": 120, "y": 80}))
	_check(proposal.get("success", false), "instance source-conflict fixture must prepare")
	if not proposal.get("success", false): return
	proposal["_editor_authorization"] = func(): return true
	var bytes := FileAccess.get_file_as_string(COIN)
	var file := FileAccess.open(COIN, FileAccess.WRITE)
	file.store_string(bytes + "\n# independent instance change\n")
	file.close()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "changed shared instance bytes must invalidate the reviewed native override")
	file = FileAccess.open(COIN, FileAccess.WRITE)
	file.store_string(bytes)
	file.close()
	EditorInterface.reload_scene_from_path(GAME) # disposable fixture cleanup only
	await _settle()
	_check(Tools.apply_reviewed_change(proposal).begins_with("Conflict:"), "reopened scene identity must not revive old review")

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
