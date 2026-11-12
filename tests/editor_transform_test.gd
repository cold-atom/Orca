@tool
extends "res://tests/editor_test_case.gd"

const Tools = preload("res://addons/orca/scripts/tools.gd")
const Reader = preload("res://addons/orca/scripts/saved_scene_transform.gd")
const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const GAME := "res://tests/fixtures/editor_transform_game.tscn"
const COIN := "res://tests/fixtures/editor_transform_coin.tscn"
var failures: Array[String] = []
var view
var client

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
	_check(not Tools.prepare_reviewed_change("propose_scene_changes", "dirty", args).get("success", true), "unsaved game scenes must still require saving")
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
