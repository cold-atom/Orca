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
var _target_script := ""


func _prepare_property(operation: Dictionary) -> String:
	var target := (_root.get_ref() as Node).get_node_or_null(NodePath(operation["node_path"]))
	if not target is Node2D or operation["property_name"] not in NODE2D_PROPERTIES: return "This editor strategy supports native Node2D position/rotation/scale/skew only."
	if target != _root.get_ref() and ClassDB.class_get_property(target, "owner") != _root.get_ref(): return "Internal instance nodes need an editable-instance workflow. Select the instance root or a local node."
	_node = weakref(target)
	_before_value = ClassDB.class_get_property(target, operation["property_name"])
	_after_value = Contract._decode_typed_value(operation["value"])["value"]
	if Contract._encode_typed_value(_before_value) != _proposal["scene_summary"]["before"]: return "The live transform differs from the saved target. Save and prepare a fresh proposal."
	var saved := SavedTransform.inspect(_proposal["filepath"], operation["node_path"], _proposal["old_content"])
	if not saved.get("success", false): return str(saved.get("error", "Saved transform validation failed."))
	_scene_hashes = saved["hashes"].duplicate()
	_scene_hashes.erase(_proposal["filepath"])
	_target_script = saved["script_path"]
	_unrelated_signature = SavedTransform.signature(saved["source"], operation["node_path"], operation["property_name"])
	var live := _live_snapshot()
	if not live.get("success", false): return str(live.get("error", "Native scene inspection failed."))
	_baseline = live["snapshot"].duplicate(true)
	return ""


func _check_identity(require_clean: bool) -> String:
	var error := super._check_identity(require_clean)
	if not error.is_empty(): return error
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
	var saved := SavedTransform.inspect(_proposal["filepath"], _proposal["operations"][0]["node_path"], _proposal["new_content" if candidate else "old_content"])
	return _snapshot_from_saved(saved)


func _safe_saved_snapshot(content: String) -> Dictionary:
	return _snapshot_from_saved(SavedTransform.inspect(_proposal["filepath"], _proposal["operations"][0]["node_path"], content))


func _snapshot_from_saved(saved: Dictionary) -> Dictionary:
	if not saved.get("success", false): return saved
	var operation: Dictionary = _proposal["operations"][0]
	var sources: Dictionary = saved["hashes"].duplicate()
	sources.erase(_proposal["filepath"])
	if sources != _scene_hashes or saved["script_path"] != _target_script or saved["node_type"] != _node.get_ref().get_class(): return {"success": false, "error": "Saved target provenance changed."}
	if SavedTransform.signature(saved["source"], operation["node_path"], operation["property_name"]) != _unrelated_signature: return {"success": false, "error": "Unrelated saved scene records changed."}
	var snapshot := _baseline.duplicate(true)
	for record in snapshot["nodes"]:
		if record["id"] == _node.get_ref().get_instance_id():
			if record["script"] != saved["script_path"]: return {"success": false, "error": "Live/saved script attachment identity differs."}
			record["values"] = saved["values"].duplicate()
	return {"success": true, "snapshot": snapshot}
