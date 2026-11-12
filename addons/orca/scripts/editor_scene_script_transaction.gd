@tool
extends RefCounted

## Memory-only, reviewed current-scene script operation. Undo operations reference
## native nodes/resources, never this coordinator or a dock that may be unloaded.
const Contract = preload("res://addons/orca/scripts/scene_proposal.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const DependencyInspector = preload("res://addons/orca/scripts/dependency_inspector.gd")

var _root: WeakRef
var _node: WeakRef
var _proposal: Dictionary
var _script: GDScript
var _before: Dictionary
var _after: Dictionary
var _properties: Dictionary = {}
var _history_id := -1
var _version := 0
var _action_index := -1
var _action_name := ""
var _applied := false


func prepare(proposal: Dictionary) -> String:
	_proposal = proposal.duplicate(true)
	_root = proposal.get("_editor_root")
	var error := _check_identity(true)
	if not error.is_empty(): return error
	var operation: Dictionary = _proposal["operations"][0]
	var validated := Contract._validate_script_operation(operation)
	if not validated.get("success", false): return str(validated.get("error", "Script validation failed."))
	_script = validated["script"]
	if _script.is_tool(): return "Open-scene attachment currently supports non-@tool scripts only. No editor change was made."
	var target := (_root.get_ref() as Node).get_node_or_null(NodePath(operation["node_path"]))
	if target == null: return "The target node no longer exists."
	_node = weakref(target)
	var attaching: bool = operation["operation"] == "attach_script"
	if (attaching and target.get_script() != null) or (not attaching and not _matches_script(target.get_script())):
		return "The live script attachment differs from the reviewed saved scene."
	var descriptors := _script.get_script_property_list()
	if descriptors.size() > Contract.MAX_MUTATION_PROPERTIES: return "The script property list exceeds the editor attachment limit."
	if not attaching:
		for property in descriptors:
			if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0: continue
			var name := str(property.get("name", ""))
			var value = target.get(name)
			if typeof(value) not in [TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_COLOR, TYPE_RECT2] or (typeof(value) in [TYPE_STRING, TYPE_STRING_NAME] and str(value).length() > 4096):
				return "The attachment has unsupported exported state; use Godot's normal attachment controls."
			_properties[name] = value
	var before := _content_snapshot(false)
	var after := _content_snapshot(true)
	if not before.get("success", false) or not after.get("success", false): return "The reviewed scene snapshots could not be verified."
	_before = before["snapshot"]
	_after = after["snapshot"]
	var live := _live_snapshot()
	if not live.get("success", false): return str(live.get("error", "Live scene inspection failed."))
	if live["snapshot"] != _before: return "The live scene differs from its saved baseline. Save it and prepare a fresh proposal."
	var manager := EditorInterface.get_editor_undo_redo()
	_history_id = manager.get_object_history_id(_root.get_ref())
	if _history_id <= 0: return "Godot did not provide an isolated scene Undo history."
	var history := manager.get_history_undo_redo(_history_id)
	_version = history.get_version()
	_action_index = history.get_current_action()
	return _check_identity(true)


func apply(proposal: Dictionary, authorization: Callable) -> String:
	if not authorization.is_valid() or not authorization.call(): return "Error: Apply requires the current Work-mode original-proposal approval."
	if _applied or not _same_proposal(proposal): return "Error: The editor attachment proposal is stale."
	var error := _check_identity(true)
	if not error.is_empty(): return "Conflict: " + error
	error = Contract.validate_candidate(proposal)
	if not error.is_empty(): return "Error: " + error
	# Revalidation can execute trusted code. Recheck live identity, history,
	# saved bytes, source, permissions and dirty state after it returns.
	error = _check_identity(true)
	if not error.is_empty(): return "Conflict: " + error
	if not _history_matches(): return "Conflict: The scene Undo history changed during review."
	var live := _live_snapshot()
	if not live.get("success", false) or live.get("snapshot") != _before: return "Conflict: The live scene changed during review."
	error = _check_identity(true)
	if not error.is_empty(): return "Conflict: " + error
	if not _history_matches(): return "Conflict: The scene Undo history changed during validation."
	if not authorization.is_valid() or not authorization.call(): return "Error: The original scene approval is no longer active."
	_commit(false)
	_applied = true
	live = _live_snapshot()
	if not live.get("success", false) or live.get("snapshot") != _after or not _history_matches():
		return "Recovery required: The editor operation completed but its final state could not be verified. Keep the scene open and inspect Godot's Undo history. No file was saved."
	return "Applied in editor: " + str(_proposal["filepath"]) + ". Normal Godot Undo is available. Save pending: save this scene before running or verifying it. No scene file was written or game launched."


func revert(authorization: Callable) -> String:
	if not authorization.is_valid() or not authorization.call(): return "Error: Revert requires current Work-mode user authorization."
	if not _applied: return "Conflict: This editor attachment was not applied."
	var error := _check_identity(false)
	if not error.is_empty(): return "Conflict: " + error
	if not _history_matches(): return "Conflict: The scene Undo history changed. Use Godot's Undo, or request a fresh attachment/detachment proposal."
	var live := _live_snapshot()
	if not live.get("success", false) or live.get("snapshot") != _after: return "Conflict: The live scene changed after the attachment."
	var disk := Contract._read_scene_file(str(_proposal["filepath"]))
	if not disk.get("success", false): return "Conflict: The saved scene is unavailable."
	if str(disk["content"]).sha256_text() != _proposal["old_hash"]:
		var saved := _safe_saved_snapshot(str(disk["content"]))
		if not saved.get("success", false) or saved.get("snapshot") != _after: return "Conflict: The saved scene changed independently."
	error = _check_identity(false)
	if not error.is_empty(): return "Conflict: " + error
	if not _history_matches() or not authorization.is_valid() or not authorization.call(): return "Conflict: Revert authorization or Undo state changed."
	_commit(true)
	live = _live_snapshot()
	if not live.get("success", false) or live.get("snapshot") != _before or not _history_matches():
		return "Recovery required: The inverse editor action could not be verified. Inspect Godot's Undo history; no file was saved."
	return "Reverted in editor: " + str(_proposal["filepath"]) + ". Save pending: saving the scene persists this inverse action. Normal Godot Undo remains available."


func observe() -> Dictionary:
	# Event-driven evidence only; never a save, edit, or authorization source.
	if not _applied: return {}
	if not _check_identity(false).is_empty():
		return {"status": "editor_changed", "message": "Editor scene identity or script state changed. Inspect the current scene before further edits."}
	var live := _live_snapshot()
	if not live.get("success", false): return {"status": "editor_changed", "message": "The current editor state could not be verified."}
	if live.get("snapshot") == _before:
		return {"status": "undone_editor", "message": "The attachment is undone in the editor. Disk state is separate; save the scene to persist editor changes."}
	if live.get("snapshot") != _after:
		return {"status": "editor_changed", "message": "The scene has additional editor changes. Use native Undo or prepare a fresh proposal."}
	if EditorContext.has_unsaved_file(str(_proposal["filepath"])):
		return {"status": "applied_editor", "message": "The reviewed change is present in the editor. Save pending; startup has not been verified."}
	var disk := Contract._read_scene_file(str(_proposal["filepath"]))
	if disk.get("success", false):
		var hash: String = str(disk["content"]).sha256_text()
		if hash == _proposal["new_hash"]:
			return {"status": "saved_editor", "message": "Observed the exact reviewed bytes in the saved scene and the attachment in the editor. Startup has not been verified."}
		if hash != _proposal["old_hash"]:
			# Native saves can assign different resource IDs/UIDs. Observation must
			# never load/compile that file (it also runs when the user is in Plan).
			# A later explicit Work-mode inverse independently validates semantics.
			return {"status": "save_observed_editor", "message": "Godot reports the scene saved, and the reviewed attachment remains in the editor. Saved serialization differs from the candidate and has not been independently verified. Startup remains unverified."}
	return {"status": "editor_changed", "message": "The saved scene no longer matches the reviewed editor change."}


func _commit(inverse: bool) -> void:
	var target := _node.get_ref() as Node
	var attaching: bool = _proposal["operations"][0]["operation"] == "attach_script"
	var set_script: bool = attaching != inverse
	var manager := EditorInterface.get_editor_undo_redo()
	_action_name = ("Orca revert script " if inverse else "Orca attach/detach script ") + Crypto.new().generate_random_bytes(8).hex_encode()
	manager.create_action(_action_name, UndoRedo.MERGE_DISABLE, _root.get_ref(), false, true)
	manager.add_do_method(target, &"set_script", _script if set_script else null)
	manager.add_undo_method(target, &"set_script", null if set_script else _script)
	for name in _properties:
		if set_script: manager.add_do_property(target, name, _properties[name])
		else: manager.add_undo_property(target, name, _properties[name])
	manager.commit_action()
	if not is_instance_valid(_root.get_ref()) or _root.get_ref() != EditorInterface.get_edited_scene_root(): return
	var history := manager.get_history_undo_redo(_history_id)
	_version = history.get_version()
	_action_index = history.get_current_action()


func _check_identity(require_clean: bool) -> String:
	if not Engine.is_editor_hint() or _root == null or not is_instance_valid(_root.get_ref()) or _root.get_ref() != EditorInterface.get_edited_scene_root():
		return "The reviewed scene must remain the current open tab. Prepare a fresh proposal if it was reopened."
	var path := str(_proposal.get("filepath", ""))
	if (_root.get_ref() as Node).is_queued_for_deletion(): return "The reviewed scene is closing."
	if str(ClassDB.class_get_property(_root.get_ref(), "scene_file_path")) != path: return "The scene path changed."
	for source in [path, str(_proposal["operations"][0]["script_path"])]:
		var error := DependencyInspector._validate_project_file(source)
		if not error.is_empty(): return error
	if require_clean and EditorContext.has_unsaved_file(path): return "The scene has unsaved changes. Save it and prepare a fresh proposal."
	var script_path: String = _proposal["operations"][0]["script_path"]
	if EditorContext.has_unsaved_file(script_path): return "The reviewed script has unsaved changes."
	var script := Contract._read_script_file(script_path)
	if not script.get("success", false) or str(script.get("content", "")).sha256_text() != _proposal["operations"][0]["script_hash"]: return "The reviewed script changed."
	if _script != null and not _matches_script(_script): return "The retained script resource changed."
	if require_clean:
		var disk := Contract._read_scene_file(path)
		if not disk.get("success", false) or str(disk.get("content", "")).sha256_text() != _proposal["old_hash"]: return "The saved scene changed."
	if _node != null and (not is_instance_valid(_node.get_ref()) or (_root.get_ref() as Node).get_node_or_null(NodePath(_proposal["operations"][0]["node_path"])) != _node.get_ref()): return "The reviewed node identity changed."
	if _node != null and (_node.get_ref() as Node).is_queued_for_deletion(): return "The reviewed node is being removed."
	if EditorInterface.get_editor_undo_redo().is_committing_action(): return "Another editor Undo action is committing."
	return ""


func _history_matches() -> bool:
	var manager := EditorInterface.get_editor_undo_redo()
	if manager.get_object_history_id(_root.get_ref()) != _history_id: return false
	var history := manager.get_history_undo_redo(_history_id)
	return history.get_version() == _version and history.get_current_action() == _action_index and (_action_name.is_empty() or history.get_current_action_name() == _action_name)


func _same_proposal(proposal: Dictionary) -> bool:
	for key in ["id", "kind", "filepath", "old_content", "new_content", "old_hash", "new_hash", "operations", "trust_binding", "candidate_binding", "application_strategy"]:
		if proposal.get(key) != _proposal.get(key): return false
	return true


func _matches_script(script) -> bool:
	return script is GDScript and script.resource_path == _proposal["operations"][0]["script_path"] and script.source_code.sha256_text() == _proposal["operations"][0]["script_hash"] and not script.is_tool()


func _live_snapshot() -> Dictionary:
	if _root == null or not is_instance_valid(_root.get_ref()) or (_root.get_ref() as Node).is_queued_for_deletion(): return {"success": false, "error": "The scene was closed or is closing."}
	var pending: Array[Node] = [_root.get_ref()]
	var visited := 0
	while not pending.is_empty():
		var node := pending.pop_back() as Node
		if ClassDB.class_get_api_type(node.get_class()) != ClassDB.API_CORE: return {"success": false, "error": "Live editor attachment supports native core nodes only."}
		visited += 1
		if visited + pending.size() > Contract.MAX_MUTATION_NODES: return {"success": false, "error": "Live scene exceeds the node limit."}
		if node.get_script() != null and not _matches_script(node.get_script()): return {"success": false, "error": "Live scene contains an unreviewed script."}
		if node.get_child_count() + visited + pending.size() > Contract.MAX_MUTATION_NODES: return {"success": false, "error": "Live scene exceeds the node limit."}
		pending.append_array(node.get_children())
	var packed := PackedScene.new()
	if packed.pack(_root.get_ref()) != OK: return {"success": false, "error": "Could not inspect the live scene."}
	return _normalized(Contract._snapshot_state(packed.get_state(), [_proposal["operations"][0]["script_path"]]))


func _content_snapshot(candidate: bool) -> Dictionary:
	return _normalized(Contract._snapshot_content(_proposal["new_content" if candidate else "old_content"], Contract._operation_dependencies(_proposal["operations"][0], candidate)))


func _safe_saved_snapshot(content: String) -> Dictionary:
	return _normalized(Contract._snapshot_content(content, Contract._operation_dependencies(_proposal["operations"][0], true)))


func _normalized(result: Dictionary) -> Dictionary:
	if not result.get("success", false): return result
	for node in result["snapshot"]["nodes"]:
		for property in node["properties"]:
			if property["name"] == "script" and property["value"] != null:
				if not _matches_script(property["value"]): return {"success": false, "error": "Script identity changed during validation."}
				property["value"] = property["value"].resource_path
		node["properties"].sort_custom(func(a, b): return a["name"] < b["name"])
	return result
