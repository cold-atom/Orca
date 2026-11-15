@tool
extends RefCounted

## Exact current-scene native addition, with ordinary Undo and save pending.
## Deliberately clean/scriptless Node3D only; never save/reload the user's scene.
const Context = preload("res://addons/orca/scripts/editor_context.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
var _root: WeakRef
var _scene_path := ""
var _scene_hash := ""
var _asset_path := ""
var _asset_hash := ""
var _history: WeakRef
var _history_id := -1
var _version := 0
var _invalidated := false
var _applied := false

func prepare(asset_path: String, asset_hash: String) -> Dictionary:
	if not Engine.is_editor_hint(): return _error("Scene placement requires the Godot editor.")
	var root := EditorInterface.get_edited_scene_root()
	if not root is Node3D or ClassDB.class_get_property(root, "script") != null: return _error("Open a saved, clean, scriptless Node3D scene for asset placement.")
	_scene_path = str(ClassDB.class_get_property(root, "scene_file_path"))
	if _scene_path.is_empty() or not Tools._validate_path(_scene_path, true).is_empty() or Context.has_unsaved_file(_scene_path): return _error("Save the current scene before preparing asset placement.")
	var pending: Array[Node] = [root]
	var count := 0
	while not pending.is_empty():
		var node := pending.pop_back() as Node
		count += 1
		if count > 256 or ClassDB.class_get_property(node, "script") != null: return _error("Asset placement requires a bounded scriptless current scene.")
		for child in node.get_children(): pending.append(child)
	_root = weakref(root)
	_scene_hash = FileAccess.get_sha256(_scene_path)
	_asset_path = asset_path
	_asset_hash = asset_hash
	var manager := EditorInterface.get_editor_undo_redo()
	_history_id = manager.get_object_history_id(root)
	if _history_id <= 0: return _error("No isolated scene Undo history is available.")
	var history := manager.get_history_undo_redo(_history_id)
	_history = weakref(history)
	_version = history.get_version()
	history.version_changed.connect(_changed)
	return {"success": true, "summary": {"asset": asset_path, "asset_hash": asset_hash, "scene": _scene_path, "scene_hash": _scene_hash, "parent": ".", "save_pending": true}}

func _changed() -> void:
	_invalidated = true

func _matches() -> bool:
	return not _applied and not _invalidated and _root != null and is_instance_valid(_root.get_ref()) and EditorInterface.get_edited_scene_root() == _root.get_ref() and not Context.has_unsaved_file(_scene_path) and FileAccess.get_sha256(_scene_path) == _scene_hash and Tools._validate_path(_asset_path, false).is_empty() and FileAccess.get_sha256(_asset_path) == _asset_hash and _history != null and is_instance_valid(_history.get_ref()) and _history.get_ref().get_version() == _version

func cancel() -> void:
	_invalidated = true
	_release()

func apply(authorized: Callable) -> Dictionary:
	if not authorized.is_valid() or not authorized.call() or not _matches(): return _error("The original scene-placement review is stale or no longer authorized.")
	var packed := ResourceLoader.load(_asset_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null or not _matches(): return _error("The imported asset is unavailable or changed during loading.")
	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if instance == null: return _error("The imported asset could not be instantiated.")
	var pending: Array[Node] = [instance]
	var count := 0
	while not pending.is_empty():
		var node := pending.pop_back() as Node
		count += 1
		if count > 256 or ClassDB.class_get_property(node, "script") != null:
			instance.free()
			return _error("Only bounded scriptless imported assets can be placed.")
		for child in node.get_children(): pending.append(child)
	if not _matches() or not authorized.call():
		instance.free()
		return _error("The scene changed during placement preparation.")
	var root := _root.get_ref() as Node
	instance.name = _asset_path.get_file().get_basename().validate_node_name()
	var manager := EditorInterface.get_editor_undo_redo()
	if manager.is_committing_action():
		instance.free()
		return _error("Another editor action is committing.")
	_release()
	manager.create_action("Place Blender asset", UndoRedo.MERGE_DISABLE, root)
	manager.add_do_method(root, "add_child", instance, true)
	manager.add_do_method(instance, "set_owner", root)
	manager.add_do_reference(instance)
	manager.add_undo_method(root, "remove_child", instance)
	manager.commit_action()
	_applied = true
	return {"success": true, "outcome": "completed", "content": "Applied in editor: Blender asset placed in " + _scene_path + ". Save pending. Native Godot Undo is available; no scene file was saved or reloaded.", "data": {"history_summary": "Reviewed Blender asset placed in editor; scene save pending.", "save_pending": true, "editor_only": true}}

func _release() -> void:
	if _history != null and is_instance_valid(_history.get_ref()):
		var history := _history.get_ref() as UndoRedo
		if history.version_changed.is_connected(_changed): history.version_changed.disconnect(_changed)
	_history = null

static func _error(message: String) -> Dictionary:
	return {"success": false, "outcome": "failed", "error": message, "content": message, "data": {"history_summary": "Blender scene placement did not complete."}}
