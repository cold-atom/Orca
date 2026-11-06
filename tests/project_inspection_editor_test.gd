@tool
extends "res://tests/editor_test_case.gd"

const Context = preload("res://addons/orca/scripts/editor_context.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const Group = preload("res://addons/orca/scripts/tool_activity_group.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const SCENE := "res://tests/fixtures/project_inspection_editor_scene.tscn"
const ANIMATION := "res://tests/fixtures/animation_inspector_fixture.tscn"

class Client extends Node:
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	var requests: Array = []
	var requesting := false
	func send_chat_completion(messages, tools, profile, options) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "profile": profile.duplicate(true), "options": options.duplicate(true)})
		requesting = true
	func is_requesting() -> bool: return requesting
	func last_request_may_have_usage() -> bool: return false
	func cancel_request() -> void:
		requesting = false
		request_cancelled.emit(int(requests[-1]["options"]["lifecycle_request_id"]))
	func complete(message: Dictionary) -> void:
		requesting = false
		request_completed.emit(int(requests[-1]["options"]["lifecycle_request_id"]), {"choices": [{"message": message, "finish_reason": "tool_calls"}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})

class Spy extends Resource:
	var unexpected_reads := 0
	func _get_property_list() -> Array[Dictionary]:
		unexpected_reads += 1
		return []
	func _get(_property: StringName):
		unexpected_reads += 1
		return null
	func _to_string() -> String:
		unexpected_reads += 1
		return "private"

var failures: Array[String] = []


func _init() -> void: call_deferred("run")


func check(value: bool, message: String) -> void:
	if not value: failures.append(message)


func settle() -> void:
	for frame in 12: await process_frame


func run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	await create_timer(0.5).timeout
	EditorInterface.open_scene_from_path(SCENE)
	await settle()
	var scene: Node = EditorInterface.get_edited_scene_root()
	check(scene != null and scene.scene_file_path == SCENE, "fixture is an actual current editor scene")
	var timer := scene.get_node("Timer")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(timer)
	await settle()
	var resource := Animation.new()
	resource.resource_name = "Settings"
	EditorInterface.inspect_object(resource)
	await settle()
	var snapshot := Context.capture()
	check(snapshot["inspector_target"]["class"] == "Animation" and snapshot["inspector_target"]["name"] == "Settings", "Inspector target differs correctly from selected scene node: " + JSON.stringify(snapshot["inspector_target"]))
	check(snapshot["selected_nodes"][0]["path"] == "Timer", "Inspector acquisition preserves selection")
	var spy := Spy.new()
	spy.resource_name = "Original identity"
	var before := spy.unexpected_reads
	check(Context.inspector_target(spy, scene)["name"] == "Original identity" and spy.unexpected_reads == before, "identity reads avoid script getters, enumeration and stringification")
	var blocked := Animation.new()
	blocked.resource_path = "res://addons/orca/scenes/chat_window.tscn::animation"
	check(not Context.inspector_target(blocked, scene).get("available", true), "Inspector identity confines embedded-resource owners")
	check(Context.inspector_target(timer, scene)["path"] == "Timer", "scene-node Inspector targets use scene-relative paths")
	var external := Node.new()
	check(not Context.inspector_target(external, scene).get("available", true), "nodes outside the current scene are omitted")
	external.free()
	var saved := FileAccess.get_file_as_bytes(SCENE)
	EditorInterface.mark_scene_as_unsaved()
	check(not Tools.execute_tool("inspect_scene", {"scene_path": SCENE, "scope": "node", "node_path": "Timer"}).get("success", true), "focused disk inspection rejects actual editor dirty state")
	check(not Tools.execute_tool("inspect_animation", {"scene_path": SCENE}).get("success", true), "animation inspection rejects actual editor dirty state")
	check(FileAccess.get_file_as_bytes(SCENE) == saved, "denied disk inspection preserves saved scene bytes")
	await _test_request_snapshot(resource)
	await _test_navigation_layout()
	EditorInterface.inspect_object(null)
	await settle()
	for failure in failures: printerr("project_inspection_editor_test: ", failure)
	print("project_inspection_editor_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_request_snapshot(resource: Animation) -> void:
	var settings := EditorInterface.get_editor_settings()
	# Use the production Config keys in the isolated runner configuration.
	var config = preload("res://addons/orca/scripts/config.gd")
	settings.set_setting(config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-fixture-only")
	EditorInterface.inspect_object(resource)
	await settle()
	var controller := Controller.new()
	root.add_child(controller)
	var client := Client.new()
	controller.set_api_client_for_testing(client)
	check(controller.send_user_message("Inspect the walk animation"), "real controller accepts the isolated configured request")
	check(client.requests.size() == 1 and JSON.stringify(client.requests[0]["messages"]).contains("editor_inspector_identity"), "request includes bounded Inspector identity")
	var other := Animation.new()
	other.resource_name = "LaterInspectorIdentity"
	EditorInterface.inspect_object(other)
	await settle()
	client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "animation", "type": "function", "function": {"name": "inspect_animation", "arguments": JSON.stringify({"scene_path": ANIMATION, "animation_name": "walk", "max_keys": 2})}}]})
	await settle()
	check(client.requests.size() == 2, "animation tool completes and issues a follow-up")
	if client.requests.size() == 2:
		var history := JSON.stringify(client.requests[1]["messages"])
		check(history.contains("Settings") and not history.contains("LaterInspectorIdentity"), "Inspector context stays fixed through tool continuation")
		check(history.contains("saved_animation_source"), "matching animation receipt reaches the model")
	controller.cancel_current_request()
	await settle()
	check(not controller.is_busy() and not JSON.stringify(controller.snapshot_session_state()).contains("editor_inspector_identity"), "Stop cleans request-scoped Inspector context from persistence")
	controller.queue_free()
	await settle()


func _test_navigation_layout() -> void:
	var host := PanelContainer.new()
	host.position = Metrics.scaled_vector(Vector2(150, 100))
	host.size = Metrics.scaled_vector(Vector2(300, 800))
	root.add_child(host)
	var group := Group.new()
	host.add_child(group)
	await settle()
	var card = group.add_tool("search", "search_files", {"query": "Settings"})
	group.complete_tool("search", {"outcome": "completed", "content": "Raw original search evidence", "data": {"truncated": true, "matches": [{"filepath": SCENE, "line": 25, "column": 1, "preview": "Settings"}, {"filepath": SCENE, "line": 20, "column": 2, "preview": "Timer"}]}}, 5)
	var opened := []
	group.open_requested.connect(func(path, line, column): opened.append([path, line, column]))
	group.set_expanded(true)
	card._toggle_details()
	var animation = group.add_tool("animation", "inspect_animation", {"scene_path": ANIMATION, "animation_name": "walk"})
	group.complete_tool("animation", Tools.execute_tool("inspect_animation", {"scene_path": ANIMATION}), 10)
	var base: int = card._header_button.get_theme_font_size("font_size")
	for locale in Localization.LOCALES:
		check(Localization.select_language(locale), "select locale " + locale)
		for multiplier in [1.0, 1.5, 2.0]:
			_scale_fonts(group, roundi(base * multiplier))
			await settle()
			check(host.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "search/animation activity fits 300 units: %s %.1fx" % [locale, multiplier])
			check(card._match_list.get_child(0).text.contains("Settings") and card._details.text == "Raw original search evidence", "localization preserves raw matching/source evidence")
			check(card._match_summary.visible and card._match_scroll.visible, "search counts and bounded rows stay visible")
	card._match_list.get_child(1).pressed.emit()
	check(opened == [[SCENE, 20, 2]], "actual native result action emits its own location")
	group.complete_tool("search", {"outcome": "completed", "content": "Historical summary", "data": {}}, 1)
	check(card._match_list.get_child_count() == 0 and not card._open_button.visible, "restored search has no stale navigation")
	Localization.select_language("en")
	host.queue_free()
	await settle()


func _scale_fonts(node: Node, size: int) -> void:
	if node is Control: node.add_theme_font_size_override("font_size", size)
	for child in node.get_children(): _scale_fonts(child, size)
