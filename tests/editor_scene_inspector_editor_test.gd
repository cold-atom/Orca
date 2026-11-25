@tool
extends "res://tests/editor_test_case.gd"

const Tools = preload("res://addons/orca/scripts/tools.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const Inspector = preload("res://addons/orca/scripts/editor_scene_inspector.gd")
const ComponentTest = preload("res://tests/editor_scene_inspector_test.gd")

var _failures := PackedStringArray()
var _fixture_directory := ""
var _scene_path := ""
var _other_path := ""
var _review_path := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this suite requires --editor")
	# The test plugin starts before startup scanning has completed.
	# Let the real editor finish acquisition before opening/removing fixtures.
	for _frame in range(8):
		await process_frame
	var filesystem := EditorInterface.get_resource_filesystem()
	_expect(await _wait_until(func(): return not filesystem.is_scanning()), "editor startup filesystem scan should finish")
	await create_timer(0.25).timeout
	var thread := Thread.new()
	_expect(thread.start(func(): return Tools.execute_tool("inspect_editor_scene", {"scope": "scene"})) == OK, "off-thread guard fixture should start")
	var off_thread: Dictionary = thread.wait_to_finish()
	_expect(not off_thread.get("success", true) and str(off_thread.get("content", "")).contains("main thread"), "off-thread requests must fail before touching EditorInterface")
	_fixture_directory = "res://.orca_editor_scene_test_%d" % Time.get_ticks_usec()
	_scene_path = _fixture_directory.path_join("live_menu.tscn")
	_other_path = _fixture_directory.path_join("other.tscn")
	_review_path = _fixture_directory.path_join("review_menu.tscn")
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_directory)) == OK, "fixture directory should be created")
	_write(_scene_path, "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://tests/fixtures/editor_scene_getter_fixture.gd\" id=\"1\"]\n\n[node name=\"Menu\" type=\"Control\"]\nlayout_mode = 3\noffset_right = 800.0\noffset_bottom = 600.0\n\n[node name=\"Panel\" type=\"Control\" parent=\".\"]\nlayout_mode = 0\noffset_right = 200.0\noffset_bottom = 100.0\nscript = ExtResource(\"1\")\n\n[node name=\"Row\" type=\"HBoxContainer\" parent=\".\"]\nlayout_mode = 0\noffset_top = 200.0\noffset_right = 600.0\noffset_bottom = 300.0\n\n[node name=\"Button\" type=\"Button\" parent=\"Row\"]\nlayout_mode = 2\ntext = \"Play\"\n\n[node name=\"Player\" type=\"Node2D\" parent=\".\"]\nposition = Vector2(4, 5)\n\n[node name=\"World\" type=\"Node3D\" parent=\".\"]\nposition = Vector3(1, 2, 3)\n")
	_write(_other_path, "[gd_scene format=3]\n\n[node name=\"Other\" type=\"Node\"]\n")
	await _test_live_editor_snapshot()
	await _close_fixture(_scene_path)
	await _close_fixture(_other_path)
	await _test_menu_review_workflow()
	await _close_fixture(_review_path)
	_remove_tree(ProjectSettings.globalize_path(_fixture_directory))
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_fixture_directory)), "all fixture files must be removed")
	await create_timer(0.5).timeout
	_expect(await _wait_until(func(): return not filesystem.is_scanning()), "editor filesystem work must finish before teardown")
	_finish()


func _test_live_editor_snapshot() -> void:
	EditorInterface.open_scene_from_path(_scene_path)
	if not await _wait_until(func(): return _current_path() == _scene_path):
		_expect(false, "fixture scene should become current")
		return
	await _settle_editor()
	var root: Node = EditorInterface.get_edited_scene_root()
	var panel := root.get_node("Panel") as Control
	var player := root.get_node("Player") as Node2D
	var world := root.get_node("World") as Node3D
	var original := _read(_scene_path)
	var added := Control.new()
	added.name = "UnsavedPanel"
	root.add_child(added)
	added.owner = root
	panel.set_anchor(SIDE_RIGHT, 1.0)
	panel.set_offset(SIDE_RIGHT, -20.0)
	player.position = Vector2(20, 40)
	world.position = Vector3(10, 20, 30)
	EditorInterface.mark_scene_as_unsaved()
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(panel)
	selection.add_node(player)
	# Selecting Node3D opens Godot's 3D workspace, whose preview textures are
	# unavailable in the dummy headless renderer. Inspect it by subtree instead.
	_expect(await _wait_until(func(): return _scene_path in EditorInterface.get_unsaved_scenes() and selection.get_selected_nodes().size() == 2), "dirty state and selection should be established through public editor APIs")
	await _settle_editor()
	var selected_before := selection.get_selected_nodes()
	var dirty_before := EditorInterface.get_unsaved_scenes()
	var open_before := EditorInterface.get_open_scenes()
	var calls_before := int(panel.get("inspection_calls"))
	var result := Tools.execute_tool("inspect_editor_scene", {"scene_path": _scene_path})
	_expect(result.get("success", false) and result.get("outcome") == "completed", "live inspection must succeed for an unsaved editor scene")
	_expect(JSON.parse_string(str(result.get("model_content", ""))) == JSON.parse_string(str(result.get("content", ""))), "compact live model output must preserve every native value, resource reference and provenance field")
	var report := _report(result)
	_expect(report.get("source") == "editor_scene" and report.get("scene_path") == _scene_path and report.get("unsaved_changes") == true, "model output must identify the exact live dirty scene")
	_expect(report.get("returned_node_count") == 2, "default scope must inspect the actual selected nodes")
	_expect(ComponentTest.property_value(ComponentTest.node_record(report, "Panel"), "anchor_right") == 1.0 and ComponentTest.property_value(ComponentTest.node_record(report, "Panel"), "offset_right") == -20.0, "live layout reads must include unsaved anchors and offsets")
	_expect(ComponentTest.property_value(ComponentTest.node_record(report, "Player"), "position") == [20.0, 40.0], "unsaved 2D transforms must be read from editor nodes")
	_expect(int(panel.get("inspection_calls")) == calls_before, "the actual editor tool must not invoke project getter/minimum-size/property-list callbacks")
	_expect(selection.get_selected_nodes() == selected_before and EditorInterface.get_unsaved_scenes() == dirty_before and EditorInterface.get_open_scenes() == open_before, "inspection must leave selection, dirty state, and open scenes unchanged")
	_expect(_read(_scene_path) == original and root.get_child_count() == 5, "inspection must not write project bytes, remove nodes, or instantiate additional scene nodes")
	_expect(result.get("data", {}).keys().size() == 5 and not result.get("data", {}).has("nodes") and not result.get("data", {}).has("open_path"), "UI metadata must contain only coarse source/scope/count/state, never raw live snapshots or stale navigation")
	var wire_args := JSON.new()
	wire_args.parse(JSON.stringify({"scene_path": _scene_path, "max_nodes": 1, "max_properties_per_node": 1}))
	var wire_report := _report(Tools.execute_tool("inspect_editor_scene", wire_args.get_data()))
	_expect(wire_report.get("returned_node_count") == 1 and wire_report.get("returned_property_count") == 1, "decoded provider JSON must preserve integer limit semantics in the actual editor dispatcher")
	var hierarchy := _report(Tools.execute_tool("inspect_editor_scene", {"scope": "scene", "scene_path": _scene_path}))
	_expect(not ComponentTest.node_record(hierarchy, "UnsavedPanel").is_empty(), "scene scope must include a node added without saving")
	var world_report := _report(Tools.execute_tool("inspect_editor_scene", {"scope": "subtree", "node_path": "World", "scene_path": _scene_path}))
	_expect(ComponentTest.property_value(ComponentTest.node_record(world_report, "World"), "position") == [10.0, 20.0, 30.0], "unsaved 3D transforms must be read from actual editor nodes")
	var row := _report(Tools.execute_tool("inspect_editor_scene", {"scope": "subtree", "node_path": "Row", "scene_path": _scene_path}))
	_expect(row.get("returned_node_count") == 2 and ComponentTest.node_record(row, "Row/Button").get("layout_context", {}).get("parent_is_container") == true, "subtree inspection must provide native Container context for layout diagnosis")
	_expect(not Tools.execute_tool("inspect_editor_scene", {"scope": "subtree", "node_path": "Missing"}).get("success", true), "missing nodes must fail visibly without changing editor state")
	_expect(not Tools.execute_tool("inspect_scene", {"scene_path": _scene_path}).get("success", true), "saved-scene inspection must retain its dirty-state guard")
	_expect(not Tools.prepare_file_patch("live-is-not-base", _scene_path, original.sha256_text(), [{"start_line": 1, "end_line": 1, "replacement": "[gd_scene format=3]"}]).get("success", true), "successful live inspection must not weaken unsaved file mutation guards")
	EditorInterface.open_scene_from_path(_other_path)
	_expect(await _wait_until(func(): return _current_path() == _other_path), "second fixture should become active")
	await _settle_editor()
	_expect(not Tools.execute_tool("inspect_editor_scene", {"scope": "scene", "scene_path": _scene_path}).get("success", true), "expected scene identity must reject a switched editor scene")
	var fresh := _report(Tools.execute_tool("inspect_editor_scene", {"scope": "scene", "scene_path": _other_path}))
	_expect(fresh.get("scene_path") == _other_path and fresh.get("unsaved_changes") == false and fresh.get("returned_node_count") == 1, "a new call must acquire fresh current scene state without cached node references")
	selection.clear()
	_expect(not Tools.execute_tool("inspect_editor_scene", {}).get("success", true), "empty selection should suggest scene scope rather than silently inspecting unrelated nodes")


func _test_menu_review_workflow() -> void:
	# A dependency-free menu normalized by Godot gives the reviewed scene path
	# a stable saved base without unrelated serialization drift.
	var root := Control.new()
	root.name = "Menu"
	root.size = Vector2(800, 600)
	var panel := Control.new()
	panel.name = "Panel"
	panel.size = Vector2(200, 100)
	root.add_child(panel)
	panel.owner = root
	var packed := PackedScene.new()
	_expect(packed.pack(root) == OK and ResourceSaver.save(packed, _review_path) == OK, "review fixture should be saved in Godot's canonical representation")
	root.free()
	EditorInterface.open_scene_from_path(_review_path)
	if not await _wait_until(func(): return _current_path() == _review_path):
		_expect(false, "review menu should open")
		return
	await _settle_editor()
	root = EditorInterface.get_edited_scene_root() as Control
	panel = root.get_node("Panel") as Control
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(panel)
	var initial := _report(Tools.execute_tool("inspect_editor_scene", {"scene_path": _review_path}))
	var record := ComponentTest.node_record(initial, "Panel")
	_expect(ComponentTest.property_value(record, "anchor_right") == 0.0 and ComponentTest.property_value(record, "size") == [200.0, 100.0] and record.get("layout_context", {}).get("parent_size") == [800.0, 600.0], "menu diagnosis must expose the fixed-width panel and larger parent")
	panel.set_anchor(SIDE_RIGHT, 1.0)
	panel.set_offset(SIDE_RIGHT, 0.0)
	EditorInterface.mark_scene_as_unsaved()
	var dirty := _report(Tools.execute_tool("inspect_editor_scene", {"scene_path": _review_path}))
	_expect(dirty.get("unsaved_changes") == true and ComponentTest.property_value(ComponentTest.node_record(dirty, "Panel"), "anchor_right") == 1.0, "layout diagnosis must work before the edited menu is saved")
	EditorInterface.save_scene_as(_review_path, false)
	_expect(await _wait_until(func(): return _review_path not in EditorInterface.get_unsaved_scenes()), "only the fixture menu should be saved for reviewed mutation")
	await _close_fixture(_review_path)
	var original := _read(_review_path)
	var read := Tools.execute_tool("read_file", {"filepath": _review_path})
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "menu-inset", {"scene_path": _review_path, "base_hash": read.get("data", {}).get("sha256", ""), "operations": [{"operation": "set_property", "node_path": "./Panel", "property_name": "offset_right", "value": {"type": "float", "value": -40.0}}]})
	_expect(proposal.get("success", false), "saved menu should produce a normal hash-bound reviewed inset proposal: " + str(proposal.get("error", "")))
	if not proposal.get("success", false):
		return
	_expect(_read(_review_path) == original, "preparing the menu correction must not write anything")
	# The harness explicitly exercises Apply; no model or automatic approval is involved.
	_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "approved fixture correction should apply through the existing validated backend")
	await _settle_editor()
	EditorInterface.open_scene_from_path(_review_path)
	_expect(await _wait_until(func(): return _current_path() == _review_path), "applied menu should reopen")
	await _settle_editor()
	var applied := _report(Tools.execute_tool("inspect_editor_scene", {"scope": "subtree", "node_path": "Panel", "scene_path": _review_path}))
	_expect(ComponentTest.property_value(ComponentTest.node_record(applied, "Panel"), "offset_right") == -40.0, "fresh live inspection must reflect the approved saved correction")
	await _close_fixture(_review_path)
	_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted") and _read(_review_path) == original, "menu correction should retain exact-byte guarded revert")


func _report(result: Dictionary) -> Dictionary:
	_expect(result.get("success", false), "editor tool should succeed: " + str(result.get("content", "")))
	var report = JSON.parse_string(str(result.get("content", "")))
	_expect(report is Dictionary, "editor result should contain whole JSON")
	return report if report is Dictionary else {}


func _current_path() -> String:
	var root: Node = EditorInterface.get_edited_scene_root()
	return root.scene_file_path if root != null else ""


func _close_fixture(path: String) -> void:
	if path not in EditorInterface.get_open_scenes():
		return
	EditorInterface.open_scene_from_path(path)
	if not await _wait_until(func(): return _current_path() == path):
		_expect(false, "fixture must become active before closing")
		return
	await _settle_editor()
	if path in EditorInterface.get_unsaved_scenes():
		EditorInterface.save_scene_as(path, false)
		_expect(await _wait_until(func(): return path not in EditorInterface.get_unsaved_scenes()), "only an owned dirty fixture should be saved for cleanup")
	EditorInterface.get_selection().clear()
	EditorInterface.edit_node(null)
	await _settle_editor()
	EditorInterface.close_scene()
	_expect(await _wait_until(func(): return path not in EditorInterface.get_open_scenes()), "fixture scene should close")
	await _settle_editor()


func _settle_editor() -> void:
	for _frame in range(8):
		await process_frame


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture file should open for writing")
	if file != null:
		file.store_string(content)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for name in directory.get_files():
		DirAccess.remove_absolute(path.path_join(name))
	for name in directory.get_directories():
		_remove_tree(path.path_join(name))
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("editor_scene_inspector_editor_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("editor_scene_inspector_editor_test: ", failure)
	quit(1)
