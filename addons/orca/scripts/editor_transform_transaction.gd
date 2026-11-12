@tool
extends "res://addons/orca/scripts/editor_scene_transaction.gd"

## Target-bound transforms in an already-open scene. Preparation/revalidation
## read text and public native state only, never pack/load scene resources.
const SavedTransform = preload("res://addons/orca/scripts/saved_scene_transform.gd")
const MAX_LIVE_NODES := 512
const MAX_LIVE_SCRIPT_BYTES := 4 * 1024 * 1024
var _baseline: Dictionary = {}
var _scene_hashes: Dictionary = {}
var _unrelated_signature := ""
var _target_identity: Dictionary = {}
var _observed_saved_hash := ""


func _prepare_property(operation: Dictionary) -> String:
	var target := (_root.get_ref() as Node).get_node_or_null(NodePath(operation["node_path"]))
	if not target is Node2D or operation["property_name"] not in NODE2D_PROPERTIES: return "This editor strategy supports native Node2D position/rotation/scale/skew only."
	if target != _root.get_ref() and ClassDB.class_get_property(target, "owner") != _root.get_ref(): return "Internal instance nodes need an editable-instance workflow. Select the instance root or a local node."
	_node = weakref(target)
	_before_value = ClassDB.class_get_property(target, operation["property_name"])
	_after_value = Contract._decode_typed_value(operation["value"])["value"]
	if _proposal.get("editor_baseline") != "live" or Contract._encode_typed_value(_before_value) != _proposal["scene_summary"]["before"]: return "The live transform differs from the reviewed value. Prepare a fresh proposal."
	var saved := SavedTransform.inspect(_proposal["filepath"], operation["node_path"], _proposal["old_content"])
	if not saved.get("success", false): return str(saved.get("error", "Saved transform validation failed."))
	_target_identity = _saved_identity(saved)
	if _target_identity.is_empty() or not _target_matches_saved(): return "The live target no longer matches its saved node/instance identity. Save it before requesting this transform."
	_scene_hashes = saved["hashes"].duplicate()
	_scene_hashes.erase(_proposal["filepath"])
	_unrelated_signature = SavedTransform.signature(saved["source"], operation["node_path"], operation["property_name"])
	var live := _live_snapshot()
	if not live.get("success", false): return str(live.get("error", "Native scene inspection failed."))
	_baseline = live["snapshot"].duplicate(true)
	return ""


func _check_identity(require_baseline: bool) -> String:
	# Dirty native transforms have a separately bound live baseline. Disk mutation,
	# script attachment and Control transactions still use the parent's clean gate.
	var error := super._check_identity(false)
	if not error.is_empty(): return error
	if require_baseline:
		var disk := Contract._read_scene_file(_proposal["filepath"])
		if not disk.get("success", false) or str(disk.get("content", "")).sha256_text() != _proposal["old_hash"]: return "The saved scene changed during review. Prepare a fresh proposal."
	for path in _scene_hashes:
		error = DependencyInspector._validate_project_file(path)
		if not error.is_empty(): return error
		if EditorContext.has_unsaved_file(path): return "An instance source has unsaved changes: " + path
		var file := Contract._read_scene_file(path)
		if not file.get("success", false) or str(file.get("content", "")).sha256_text() != _scene_hashes[path]: return "An instance source changed during review: " + path
	return ""


func _live_snapshot() -> Dictionary:
	if _root == null or not is_instance_valid(_root.get_ref()) or _node == null or not is_instance_valid(_node.get_ref()): return {"success": false, "error": "The reviewed scene/node is unavailable."}
	var pending: Array[Node] = [_root.get_ref()]
	var nodes: Array = []
	var script_hashes := {}
	var script_bytes := 0
	var deadline := Time.get_ticks_msec() + SavedTransform.TIMEOUT_MS
	while not pending.is_empty():
		if Time.get_ticks_msec() >= deadline: return {"success": false, "error": "Live transform validation reached its time bound."}
		var node := pending.pop_back() as Node
		if node.is_queued_for_deletion() or ClassDB.class_get_api_type(node.get_class()) != ClassDB.API_CORE: return {"success": false, "error": "Native transforms require stable core-native scene nodes."}
		if nodes.size() + pending.size() + node.get_child_count(false) >= MAX_LIVE_NODES: return {"success": false, "error": "Live transform validation exceeds the 512-node bound."}
		var script := node.get_script()
		var script_path := ""
		if script != null:
			if not script is GDScript or script.is_tool(): return {"success": false, "error": "Scenes containing @tool or unsupported script languages need a separate execution-trust workflow."}
			var current: GDScript = script
			var depth := 0
			while current != null:
				if Time.get_ticks_msec() >= deadline: return {"success": false, "error": "Script identity validation reached its time bound."}
				depth += 1
				if depth > 16 or current.is_tool(): return {"success": false, "error": "Script inheritance/tool state is unsupported for native transform editing."}
				var path := str(ClassDB.class_get_property(current, "resource_path"))
				if script_path.is_empty(): script_path = path
				var error := DependencyInspector._validate_project_file(path)
				if not error.is_empty() or EditorContext.has_unsaved_file(path): return {"success": false, "error": "The attached script must be saved and inside the project boundary: " + path}
				if not script_hashes.has(path):
					if script_hashes.size() >= 64: return {"success": false, "error": "Live script identity validation exceeds its 64-source bound."}
					var source := Contract._read_script_file(path)
					if not source.get("success", false): return source
					script_bytes += str(source["content"]).to_utf8_buffer().size()
					if script_bytes > MAX_LIVE_SCRIPT_BYTES: return {"success": false, "error": "Live script identity validation exceeds its 4 MiB bound."}
					script_hashes[path] = str(source["content"]).sha256_text()
				if str(ClassDB.class_get_property(current, "source_code")).sha256_text() != script_hashes[path]: return {"success": false, "error": "The live script resource differs from saved source: " + path}
				current = current.get_base_script()
		var owner: Node = ClassDB.class_get_property(node, "owner")
		var instance_path := str(ClassDB.class_get_property(node, "scene_file_path"))
		if not instance_path.is_empty() and not DependencyInspector._validate_project_file(instance_path).is_empty(): return {"success": false, "error": "A live scene instance is outside the project boundary."}
		var record := {"id": node.get_instance_id(), "parent": node.get_parent().get_instance_id() if node != _root.get_ref() else 0, "owner": owner.get_instance_id() if owner != null else 0, "name": str(ClassDB.class_get_property(node, "name")), "type": node.get_class(), "script": script_path, "instance": instance_path, "values": {}}
		if node is Node2D:
			for property in NODE2D_PROPERTIES: record["values"][property] = ClassDB.class_get_property(node, property)
		nodes.append(record)
		pending.append_array(node.get_children(false))
	return {"success": true, "snapshot": {"nodes": nodes, "scripts": script_hashes}}


func _content_snapshot(candidate: bool) -> Dictionary:
	var snapshot := _baseline.duplicate(true)
	if candidate:
		for record in snapshot["nodes"]:
			if record["id"] == _node.get_ref().get_instance_id(): record["values"][_proposal["operations"][0]["property_name"]] = _after_value
	return {"success": true, "snapshot": snapshot}


func _safe_saved_snapshot(content: String) -> Dictionary:
	return _snapshot_from_saved(SavedTransform.inspect(_proposal["filepath"], _proposal["operations"][0]["node_path"], content), content.sha256_text() == _observed_saved_hash)


func _snapshot_from_saved(saved: Dictionary, observed_save: bool = false) -> Dictionary:
	if not saved.get("success", false): return saved
	var operation: Dictionary = _proposal["operations"][0]
	var sources: Dictionary = saved["hashes"].duplicate()
	sources.erase(_proposal["filepath"])
	if sources != _scene_hashes or _saved_identity(saved) != _target_identity: return {"success": false, "error": "Saved target provenance changed."}
	if not observed_save and SavedTransform.signature(saved["source"], operation["node_path"], operation["property_name"]) != _unrelated_signature: return {"success": false, "error": "Unrelated saved scene records changed without a matching editor-save receipt."}
	var snapshot := _baseline.duplicate(true)
	for record in snapshot["nodes"]:
		if record["id"] == _node.get_ref().get_instance_id():
			if record["script"] != saved["script_path"]: return {"success": false, "error": "Live/saved script attachment identity differs."}
			record["values"] = saved["values"].duplicate()
	return {"success": true, "snapshot": snapshot}


func _saved_identity(saved: Dictionary) -> Dictionary:
	var fields: Dictionary = saved.get("source", {}).get("nodes", {}).get(_proposal["operations"][0]["node_path"], {}).get("fields", {})
	if fields.is_empty(): return {}
	var instance := ""
	if fields.has("instance"):
		var reference := SavedTransform._external(fields["instance"], saved["source"])
		if not reference.get("success", false): return {}
		instance = reference["reference"]["path"]
	return {"name": fields["name"], "type": saved["node_type"], "script": saved["script_path"], "instance": instance, "origin_scene": saved["origin_scene"], "origin_node": saved["origin_node"]}


func _target_matches_saved() -> bool:
	var target := _node.get_ref() as Node
	var script := target.get_script()
	var script_path := str(ClassDB.class_get_property(script, "resource_path")) if script != null else ""
	var instance_path := str(ClassDB.class_get_property(target, "scene_file_path"))
	return str(ClassDB.class_get_property(target, "name")) == _target_identity["name"] and target.get_class() == _target_identity["type"] and script_path == _target_identity["script"] and (target == _root.get_ref() or instance_path == _target_identity["instance"])


static func capture_save_receipt(path: String) -> Dictionary:
	# Called synchronously from the public EditorPlugin.scene_saved signal. A
	# bounded hash/identity receipt is evidence only, never an Apply/Revert grant.
	if not Engine.is_editor_hint() or not DependencyInspector._validate_project_file(path).is_empty(): return {}
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null or str(ClassDB.class_get_property(scene, "scene_file_path")) != path: return {}
	var manager := EditorInterface.get_editor_undo_redo()
	var history_id := manager.get_object_history_id(scene)
	if history_id <= 0 or manager.is_committing_action(): return {}
	var history := manager.get_history_undo_redo(history_id)
	var file := Contract._read_scene_file(path)
	if not file.get("success", false): return {}
	return {"path": path, "hash": str(file["content"]).sha256_text(), "root": weakref(scene), "history": weakref(history), "version": history.get_version(), "index": history.get_current_action(), "count": history.get_history_count(), "action": history.get_current_action_name()}


func record_saved_state(receipt: Dictionary) -> void:
	if not _applied or not _check_identity(false).is_empty() or not _history_matches(): return
	if receipt.get("path") != _proposal["filepath"] or not receipt.get("root") is WeakRef or receipt["root"].get_ref() != _root.get_ref(): return
	var history := EditorInterface.get_editor_undo_redo().get_history_undo_redo(_history_id)
	if not receipt.get("history") is WeakRef or receipt["history"].get_ref() != history: return
	if receipt.get("version") != _version or receipt.get("index") != _action_index or receipt.get("count") != _history_count or receipt.get("action") != _action_name: return
	var live := _live_snapshot()
	if not live.get("success", false) or live.get("snapshot") != _after: return
	var file := Contract._read_scene_file(_proposal["filepath"])
	if not file.get("success", false) or str(file["content"]).sha256_text() != receipt.get("hash"): return
	var saved := _snapshot_from_saved(SavedTransform.inspect(_proposal["filepath"], _proposal["operations"][0]["node_path"], file["content"]), true)
	if saved.get("success", false) and saved.get("snapshot") == _after:
		_observed_saved_hash = receipt["hash"]


func observe() -> Dictionary:
	if not _applied: return {}
	if not _check_identity(false).is_empty(): return {"status": "editor_changed", "message": "Editor scene identity or source state changed. Inspect the current scene before further edits."}
	var live := _live_snapshot()
	if not live.get("success", false): return {"status": "editor_changed", "message": "The current editor state could not be verified."}
	if live.get("snapshot") == _before: return {"status": "undone_editor", "message": "The reviewed transform is undone in the editor. Earlier unsaved edits are preserved; disk state is separate."}
	if live.get("snapshot") != _after: return {"status": "editor_changed", "message": "The scene has additional editor changes. Use native Undo or prepare a fresh scene proposal."}
	if EditorContext.has_unsaved_file(_proposal["filepath"]): return {"status": "applied_editor", "message": "The reviewed transform is present in the editor with earlier edits preserved. Save pending; startup has not been verified."}
	var disk := Contract._read_scene_file(_proposal["filepath"])
	if disk.get("success", false):
		var saved := _safe_saved_snapshot(disk["content"])
		if saved.get("success", false) and saved.get("snapshot") == _after:
			return {"status": "save_observed_editor", "message": "Observed the reviewed transform in the saved scene and current editor. Other scene/resource state and startup have not been independently verified."}
	return {"status": "editor_changed", "message": "The saved scene has no matching transform/save evidence. Use native Undo or request a fresh proposal."}
