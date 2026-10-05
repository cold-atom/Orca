extends SceneTree

const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

const WAIT_TIMEOUT_MS := 5000

var _failures := PackedStringArray()
var _fixture_directory := ""
var _script_path := ""
var _other_script_path := ""
var _scene_path := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	_fixture_directory = "res://.orca_editor_unsaved_test_%d" % Time.get_ticks_usec()
	_script_path = _fixture_directory.path_join("dirty_script.gd")
	_other_script_path = _fixture_directory.path_join("other_script.gd")
	_scene_path = _fixture_directory.path_join("dirty_scene.tscn")
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_directory)) == OK, "fixture directory should be created")
	_write(_script_path, "extends Node\n\nfunc saved_function() -> void:\n\tpass\n")
	_write(_other_script_path, "extends Node\n")
	_write(_scene_path, "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n")

	await _test_dirty_script()
	await _test_dirty_scene()
	await _cleanup_editor_state()
	_remove_tree(ProjectSettings.globalize_path(_fixture_directory))
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_fixture_directory)), "fixture directory should be removed")
	_finish()


func _test_dirty_script() -> void:
	var original := _read(_script_path)
	var proposal := Tools.prepare_file_patch("dirty-script", _script_path, original.sha256_text(), [{"start_line": 4, "end_line": 4, "replacement": "\tprint(\"applied\")"}])
	_expect(proposal.get("success", false), "a clean script proposal should be prepared before the editor buffer becomes dirty")
	var script := ResourceLoader.load(_script_path, "Script", ResourceLoader.CACHE_MODE_REPLACE) as Script
	_expect(script != null, "script fixture should load")
	if script == null:
		return
	EditorInterface.edit_script(script, 1, 1, true)
	var opened := await _wait_until(func():
		var current := EditorInterface.get_script_editor().get_current_script()
		return current != null and current.resource_path == _script_path and _current_code_edit() != null
	)
	_expect(opened, "script fixture should open in the built-in editor")
	var code_edit := _current_code_edit()
	if code_edit == null:
		return
	var unsaved_source := original + "\nfunc editor_only() -> int:\n\treturn 42\n"
	code_edit.text = unsaved_source
	var dirty := await _wait_until(func(): return _script_path in EditorInterface.get_script_editor().get_unsaved_files())
	_expect(dirty, "editing the CodeEdit should mark the script as unsaved")
	_expect(EditorContext.has_unsaved_file(_script_path), "EditorContext should detect the dirty script")
	var captured := EditorContext.capture()
	_expect(_script_path in captured.get("unsaved_scripts", []), "captured editor context should include the dirty script")
	var unsaved := EditorContext.get_unsaved_open_script(_script_path)
	_expect(unsaved.get("source") == unsaved_source, "EditorContext should return the exact unsaved editor source")
	var function_result := Tools.execute_tool("read_gdscript_function", {"filepath": _script_path, "function_name": "editor_only"})
	_expect(function_result.get("success", false), "focused function reading should accept exact unsaved editor source")
	_expect(function_result.get("data", {}).get("source_kind") == "editor", "focused function reading should identify editor provenance")
	_expect(not function_result.get("data", {}).has("disk_sha256"), "unsaved editor source must not expose a disk patch-base hash")
	var other_script := ResourceLoader.load(_other_script_path, "Script", ResourceLoader.CACHE_MODE_REPLACE) as Script
	EditorInterface.edit_script(other_script, 1, 1, true)
	_expect(await _wait_until(func(): return _current_script_path() == _other_script_path), "a second script should become active")
	var inactive_result := Tools.execute_tool("read_gdscript_function", {"filepath": _script_path, "function_name": "saved_function"})
	_expect(not inactive_result.get("success", true) and str(inactive_result.get("content", "")).contains("not the active script"), "a dirty non-current script must not fall back to stale disk source")
	EditorInterface.edit_script(script, 1, 1, true)
	_expect(await _wait_until(func(): return _current_script_path() == _script_path), "the dirty fixture should become active again")
	_expect(not Tools.prepare_file_patch("blocked", _script_path, original.sha256_text(), [{"start_line": 1, "end_line": 1, "replacement": "extends RefCounted"}]).get("success", true), "patch preparation should reject a dirty script")
	_expect(Tools.apply_file_edit(proposal).begins_with("Error:"), "patch application should reject a dirty script")
	var service := GameProcessService.new()
	var run_result := service.start_scene("current_scene", _scene_path)
	_expect(not run_result.get("success", true) and str(run_result.get("content", "")).contains("open scripts"), "game launch should reject any dirty script before starting a child process")
	service.free()

	EditorInterface.get_script_editor().close_file(_script_path)
	var closed := await _wait_until(func(): return _script_path not in EditorInterface.get_script_editor().get_unsaved_files())
	_expect(closed, "closing the fixture script should discard its dirty editor buffer")
	if not closed:
		return
	_expect(Tools.apply_file_edit(proposal).begins_with("Applied"), "the reviewed proposal should apply after the dirty buffer is closed")
	script = ResourceLoader.load(_script_path, "Script", ResourceLoader.CACHE_MODE_REPLACE) as Script
	EditorInterface.edit_script(script, 1, 1, true)
	opened = await _wait_until(func(): return _current_script_path() == _script_path and _current_code_edit() != null)
	_expect(opened, "the applied script should reopen")
	code_edit = _current_code_edit()
	if code_edit != null:
		code_edit.text += "\n# unsaved after apply\n"
		dirty = await _wait_until(func(): return _script_path in EditorInterface.get_script_editor().get_unsaved_files())
		_expect(dirty, "the applied script should become dirty for revert protection")
		_expect(Tools.revert_file_edit(proposal).begins_with("Error:"), "revert should reject a dirty script buffer")
	EditorInterface.get_script_editor().close_file(_script_path)
	closed = await _wait_until(func(): return _script_path not in EditorInterface.get_script_editor().get_unsaved_files())
	_expect(closed, "the dirty applied script should close before cleanup")
	if closed:
		_expect(Tools.revert_file_edit(proposal).begins_with("Reverted"), "revert should restore the fixture after its dirty buffer is closed")
		_expect(_read(_script_path) == original, "revert should restore the original script bytes")


func _test_dirty_scene() -> void:
	EditorInterface.open_scene_from_path(_scene_path)
	var opened := await _wait_until(func():
		var root := EditorInterface.get_edited_scene_root()
		return root != null and root.scene_file_path == _scene_path
	)
	_expect(opened, "scene fixture should open in the editor")
	if not opened:
		return
	EditorInterface.mark_scene_as_unsaved()
	var dirty := await _wait_until(func(): return _scene_path in EditorInterface.get_unsaved_scenes())
	_expect(dirty, "mark_scene_as_unsaved should dirty the fixture scene")
	_expect(EditorContext.has_unsaved_file(_scene_path), "EditorContext should detect the dirty scene")
	_expect(_scene_path in EditorContext.capture().get("unsaved_scenes", []), "captured editor context should include the dirty scene")
	var inspection := Tools.execute_tool("inspect_scene", {"filepath": _scene_path})
	_expect(not inspection.get("success", true), "saved-scene inspection should reject dirty editor state")
	var proposal := SceneProposal.prepare("dirty-scene", _read(_scene_path).sha256_text(), _scene_path, [{"operation": "add_node", "parent_path": ".", "node_name": "Child", "node_type": "Node"}])
	_expect(not proposal.get("success", true) and str(proposal.get("error", "")).contains("unsaved"), "structured scene proposals should reject dirty editor state")
	var service := GameProcessService.new()
	var run_result := service.start_current_scene()
	_expect(not run_result.get("success", true) and str(run_result.get("content", "")).contains("unsaved"), "running the current scene should reject dirty editor state")
	service.free()
	EditorInterface.save_scene()
	var clean := await _wait_until(func(): return _scene_path not in EditorInterface.get_unsaved_scenes())
	_expect(clean, "saving the unchanged fixture scene should clear its dirty state")
	EditorInterface.close_scene()
	await _wait_until(func(): return _scene_path not in EditorInterface.get_open_scenes())


func _cleanup_editor_state() -> void:
	if _script_path in EditorInterface.get_script_editor().get_unsaved_files() or _current_script_path() == _script_path:
		EditorInterface.get_script_editor().close_file(_script_path)
		await _wait_until(func(): return _script_path not in EditorInterface.get_script_editor().get_unsaved_files())
	if _scene_path in EditorInterface.get_unsaved_scenes():
		EditorInterface.save_scene()
		await _wait_until(func(): return _scene_path not in EditorInterface.get_unsaved_scenes())
	if _scene_path in EditorInterface.get_open_scenes():
		EditorInterface.close_scene()
		await _wait_until(func(): return _scene_path not in EditorInterface.get_open_scenes())
	EditorInterface.get_script_editor().close_file(_other_script_path)


func _current_script_path() -> String:
	var script := EditorInterface.get_script_editor().get_current_script()
	return script.resource_path if script != null else ""


func _current_code_edit() -> CodeEdit:
	var editor := EditorInterface.get_script_editor().get_current_editor()
	return editor.get_base_editor() as CodeEdit if editor != null else null


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return predicate.call()


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	_expect(file != null, "fixture should open for reading: " + path)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if directory.current_is_dir() and not directory.is_link(name):
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		name = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("editor_unsaved_state_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("editor_unsaved_state_test: ", failure)
	quit(1)
