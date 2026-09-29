@tool
extends RefCounted

const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")

const MAX_SCENE_FILE_BYTES := 2 * 1024 * 1024
const MAX_ROOT_NAME_CHARS := 128
const MAX_MUTATION_NODES := 60
const MAX_MUTATION_PROPERTIES := 240
const MAX_MUTATION_CONNECTIONS := 100
const ALLOWED_ROOT_TYPES := ["Node", "Node2D", "Node3D", "Control"]
const SCRATCH_DIRECTORY := "user://orca/tmp"
const SCRATCH_MAX_AGE_SECONDS := 3600


static func prepare(change_id: String, base_hash: String, scene_path: String, operations) -> Dictionary:
	var operation_result := _normalize_operations(operations)
	if not operation_result.get("success", false):
		return operation_result
	var operation: Dictionary = operation_result["operation"]
	var canonical_path := _canonical_res_path(scene_path)
	var creating := str(operation.get("operation", "")) == "create_scene"
	var target_error := validate_target(canonical_path, not creating)
	if not target_error.is_empty():
		return _failure(target_error)
	if EditorContext.has_unsaved_file(canonical_path):
		return _failure("The target scene has unsaved editor state. Save or close it before proposing changes.")
	if not creating and EditorContext.is_scene_open(canonical_path):
		return _failure("The target scene is open in the editor. Close it before proposing structured changes so an in-memory copy cannot overwrite the approved result.")

	var old_content := ""
	var candidate_result: Dictionary
	if creating:
		if not base_hash.is_empty():
			return _failure("A new scene must use an empty base_hash.")
		candidate_result = _build_create_candidate(operation)
	else:
		var read_result := _read_scene_file(canonical_path)
		if not read_result.get("success", false):
			return read_result
		old_content = read_result["content"]
		if base_hash != old_content.sha256_text():
			return _failure("base_hash does not match the saved scene. Read it again before proposing changes.")
		if str(operation.get("operation", "")) in ["attach_script", "detach_script"]:
			return _prepare_script_trust(change_id, canonical_path, old_content, operation)
		if str(operation.get("operation", "")) == "instantiate_child_scene" and str(operation.get("child_scene_path", "")) == canonical_path:
			return _failure("A scene cannot instantiate itself as a child.")
		candidate_result = _build_existing_candidate(old_content, operation)
	if not candidate_result.get("success", false):
		return candidate_result
	var new_content: String = candidate_result["content"]
	return {
		"success": true,
		"id": change_id,
		"kind": "scene",
		"tool_name": "propose_scene_changes",
		"filepath": canonical_path,
		"existed": not creating,
		"old_content": old_content,
		"new_content": new_content,
		"old_hash": old_content.sha256_text(),
		"new_hash": new_content.sha256_text(),
		"operations": [operation],
		"scene_summary": candidate_result["summary"],
		"validation": {"valid": true, "message": "Packed, saved, and reloaded the complete proposed scene as a PackedScene."},
		"status": "pending",
		"no_changes": bool(candidate_result.get("no_changes", false))
	}


static func promote_script_trust(proposal: Dictionary) -> Dictionary:
	if str(proposal.get("kind", "")) != "scene" or str(proposal.get("tool_name", "")) != "propose_scene_changes" or str(proposal.get("approval_stage", "")) != "script_trust":
		return _failure("The retained proposal is not a pending script trust review.")
	var operation_result := _normalize_operations(proposal.get("operations"))
	if not operation_result.get("success", false):
		return operation_result
	var operation: Dictionary = operation_result["operation"]
	if str(operation.get("operation", "")) not in ["attach_script", "detach_script"]:
		return _failure("The retained trust review does not contain a script operation.")
	var scene_path := str(proposal.get("filepath", ""))
	var target_error := validate_target(scene_path, true)
	if not target_error.is_empty():
		return _failure(target_error)
	if EditorContext.has_unsaved_file(scene_path) or EditorContext.is_scene_open(scene_path):
		return _failure("The target scene became open or unsaved before trusted candidate construction.")
	var current_scene := _read_scene_file(scene_path)
	if not current_scene.get("success", false) or str(current_scene.get("content", "")).sha256_text() != str(proposal.get("old_hash", "")):
		return _failure("The scene changed after script execution trust was requested.")
	var script_result := _read_script_file(str(operation.get("script_path", "")))
	if not script_result.get("success", false):
		return script_result
	var script_content := str(script_result.get("content", ""))
	if script_content.sha256_text() != str(operation.get("script_hash", "")) or script_content != str(proposal.get("script_content", "")):
		return _failure("The script changed after script execution trust was requested.")
	if str(proposal.get("trust_binding", "")) != _script_trust_binding(scene_path, str(proposal.get("old_hash", "")), operation):
		return _failure("The retained script trust binding no longer matches the reviewed scene, script, and operation.")
	var candidate_result := _build_existing_candidate(str(current_scene.get("content", "")), operation)
	if not candidate_result.get("success", false):
		return candidate_result
	var new_content := str(candidate_result.get("content", ""))
	var new_hash := new_content.sha256_text()
	return {
		"success": true,
		"id": str(proposal.get("id", "")),
		"kind": "scene",
		"tool_name": "propose_scene_changes",
		"approval_stage": "candidate",
		"filepath": scene_path,
		"existed": true,
		"old_content": str(current_scene.get("content", "")),
		"new_content": new_content,
		"old_hash": str(proposal.get("old_hash", "")),
		"new_hash": new_hash,
		"script_content": script_content,
		"trust_binding": str(proposal.get("trust_binding", "")),
		"candidate_binding": _script_candidate_binding(str(proposal.get("trust_binding", "")), new_hash),
		"operations": [operation],
		"scene_summary": candidate_result["summary"],
		"validation": {"valid": true, "message": "Trusted script loaded; packed, saved, and reloaded the complete proposed scene."},
		"status": "pending",
		"no_changes": bool(candidate_result.get("no_changes", false))
	}


static func _prepare_script_trust(change_id: String, scene_path: String, old_content: String, operation: Dictionary) -> Dictionary:
	var script_path := str(operation.get("script_path", ""))
	if EditorContext.has_unsaved_file(script_path):
		return _failure("The reviewed script has unsaved editor changes. Save it before requesting script execution trust.")
	var script_result := _read_script_file(script_path)
	if not script_result.get("success", false):
		return script_result
	var script_content := str(script_result.get("content", ""))
	if script_content.sha256_text() != str(operation.get("script_hash", "")):
		return _failure("script_hash does not match the saved script. Read it again before proposing this change.")
	return {
		"success": true,
		"id": change_id,
		"kind": "scene",
		"tool_name": "propose_scene_changes",
		"approval_stage": "script_trust",
		"filepath": scene_path,
		"existed": true,
		"old_content": old_content,
		"old_hash": old_content.sha256_text(),
		"script_content": script_content,
		"trust_binding": _script_trust_binding(scene_path, old_content.sha256_text(), operation),
		"operations": [operation],
		"scene_summary": {"operation": str(operation.get("operation", "")), "node_path": str(operation.get("node_path", "")), "script_path": script_path, "trust_review": true},
		"validation": {"valid": true, "message": "Hash-bound intent validated without loading the scene or compiling the script. Approval may execute script initialization while constructing and revalidating the candidate."},
		"status": "pending"
	}


static func validate_target(scene_path: String, expect_exists: bool) -> String:
	if scene_path.is_empty() or not scene_path.begins_with("res://") or _canonical_res_path(scene_path) != scene_path:
		return "scene_path must be a canonical res:// path."
	if scene_path.get_extension().to_lower() != "tscn":
		return "Structured scene changes accept .tscn targets only."
	var absolute_path := ProjectSettings.globalize_path(scene_path)
	var file_exists := FileAccess.file_exists(scene_path)
	var directory_exists := DirAccess.dir_exists_absolute(absolute_path)
	if expect_exists:
		if not file_exists:
			return "The saved scene no longer exists at " + scene_path
		if directory_exists:
			return "The scene target is unexpectedly a directory."
	else:
		if file_exists or directory_exists:
			return "A file or directory already exists at " + scene_path
		if not DirAccess.dir_exists_absolute(absolute_path.get_base_dir()):
			return "The destination directory must already exist before proposing a scene."
	return ""


static func validate_current(proposal: Dictionary, expect_new: bool) -> String:
	var scene_path := str(proposal.get("filepath", ""))
	var existed := bool(proposal.get("existed", false))
	var should_exist := existed or expect_new
	var target_error := validate_target(scene_path, should_exist)
	if not target_error.is_empty():
		return target_error
	if not should_exist:
		return ""
	var read_result := _read_scene_file(scene_path)
	if not read_result.get("success", false):
		return str(read_result.get("error", "Could not read the saved scene."))
	var content: String = read_result["content"]
	var expected_hash := str(proposal.get("new_hash" if expect_new else "old_hash", ""))
	if content.sha256_text() != expected_hash:
		return "The scene changed after this proposal was prepared. Review a fresh proposal."
	if expect_new:
		return _validate_proposal_contents(proposal, false)
	var operation_result := _normalize_operations(proposal.get("operations"))
	if not operation_result.get("success", false):
		return str(operation_result.get("error", "The retained scene operation is invalid."))
	var operation: Dictionary = operation_result["operation"]
	if str(operation.get("operation", "")) in ["attach_script", "detach_script"]:
		var trust_error := _validate_script_trust_fields(proposal, operation)
		if not trust_error.is_empty():
			return trust_error
		if not _operation_dependencies(operation, expect_new).is_empty():
			var script_result := _validate_script_operation(operation)
			if not script_result.get("success", false):
				return str(script_result.get("error", "The reviewed script is no longer valid."))
	return _preflight_content(content, _operation_dependencies(operation, expect_new))


static func validate_candidate(proposal: Dictionary) -> String:
	if str(proposal.get("kind", "")) != "scene" or str(proposal.get("tool_name", "")) != "propose_scene_changes":
		return "The retained proposal is not a structured scene proposal."
	var old_content := str(proposal.get("old_content", ""))
	var new_content := str(proposal.get("new_content", ""))
	if old_content.sha256_text() != str(proposal.get("old_hash", "")):
		return "The retained original scene no longer matches the reviewed base hash."
	if new_content.sha256_text() != str(proposal.get("new_hash", "")):
		return "The retained scene candidate no longer matches the reviewed hash."
	return _validate_proposal_contents(proposal, true)


static func validate_revert_candidate(proposal: Dictionary) -> String:
	if str(proposal.get("kind", "")) != "scene" or str(proposal.get("tool_name", "")) != "propose_scene_changes":
		return "The retained proposal is not a structured scene proposal."
	var old_content := str(proposal.get("old_content", ""))
	var new_content := str(proposal.get("new_content", ""))
	if old_content.sha256_text() != str(proposal.get("old_hash", "")) or new_content.sha256_text() != str(proposal.get("new_hash", "")):
		return "The retained scene bytes no longer match their reviewed hashes."
	var operation_result := _normalize_operations(proposal.get("operations"))
	if not operation_result.get("success", false):
		return str(operation_result.get("error", "The retained scene operation is invalid."))
	var operation: Dictionary = operation_result["operation"]
	var operation_name := str(operation.get("operation", ""))
	if operation_name in ["attach_script", "detach_script"]:
		var trust_error := _validate_script_trust_fields(proposal, operation)
		if not trust_error.is_empty():
			return trust_error
		var current_script_scene := _read_scene_file(str(proposal.get("filepath", "")))
		if not current_script_scene.get("success", false) or str(current_script_scene.get("content", "")).sha256_text() != str(proposal.get("new_hash", "")):
			return "The scene changed after Orca applied it."
		if operation_name == "attach_script":
			return ""
		return validate_candidate(proposal)
	if operation_name != "instantiate_child_scene":
		return validate_candidate(proposal)
	var summary: Dictionary = proposal.get("scene_summary", {})
	var instance: Dictionary = summary.get("instance", {})
	if str(summary.get("operation", "")) != "instantiate_child_scene" or str(instance.get("scene_path", "")) != str(operation.get("child_scene_path", "")) or str(instance.get("name", "")) != str(operation.get("node_name", "")):
		return "The retained child-instance summary no longer matches its operation."
	var current := _read_scene_file(str(proposal.get("filepath", "")))
	if not current.get("success", false) or str(current.get("content", "")).sha256_text() != str(proposal.get("new_hash", "")):
		return "The scene changed after Orca applied it."
	return ""


static func _validate_proposal_contents(proposal: Dictionary, rebuild: bool) -> String:
	var operation_result := _normalize_operations(proposal.get("operations"))
	if not operation_result.get("success", false):
		return str(operation_result.get("error", "The retained scene operation is invalid."))
	var operation: Dictionary = operation_result["operation"]
	var operation_name := str(operation.get("operation", ""))
	var existed := bool(proposal.get("existed", false))
	if (operation_name == "create_scene") == existed:
		return "The retained scene existence state does not match its operation."
	var old_content := str(proposal.get("old_content", ""))
	var new_content := str(proposal.get("new_content", ""))
	var validation: Dictionary
	if operation_name == "create_scene":
		if not old_content.is_empty():
			return "A create_scene proposal cannot retain an existing scene."
		validation = _snapshot_content(new_content)
		if not validation.get("success", false):
			return str(validation.get("error", "The retained scene candidate is invalid."))
		var summary := _create_summary(operation)
		if proposal.get("scene_summary") != summary or not _matches_create_snapshot(validation["snapshot"], summary):
			return "The retained scene no longer matches the reviewed root summary."
		if rebuild:
			var rebuilt_create := _build_create_candidate(operation)
			if not rebuilt_create.get("success", false) or rebuilt_create.get("summary") != summary:
				return "The reviewed create_scene operation could not be packed again."
		return ""

	var child_result := _validate_child_scene_operation(operation)
	if not child_result.get("success", false):
		return str(child_result.get("error", "The reviewed child scene is no longer valid."))
	if operation_name == "instantiate_child_scene" and str(operation.get("child_scene_path", "")) == str(proposal.get("filepath", "")):
		return "A scene cannot instantiate itself as a child."
	if operation_name in ["attach_script", "detach_script"]:
		var trust_error := _validate_script_trust_fields(proposal, operation)
		if not trust_error.is_empty():
			return trust_error
		var script_result := _validate_script_operation(operation)
		if not script_result.get("success", false):
			return str(script_result.get("error", "The reviewed script is no longer valid."))
	var old_dependencies := _operation_dependencies(operation, false)
	var new_dependencies := _operation_dependencies(operation, true)
	var old_result := _snapshot_content(old_content, old_dependencies)
	if not old_result.get("success", false):
		return str(old_result.get("error", "The retained original scene is invalid."))
	var new_result := _snapshot_content(new_content, new_dependencies)
	if not new_result.get("success", false):
		return str(new_result.get("error", "The retained scene candidate is invalid."))
	var summary: Dictionary = proposal.get("scene_summary", {})
	if operation_name == "set_property":
		var old_effective := _effective_property(old_content, str(operation.get("node_path", "")), str(operation.get("property_name", "")))
		var new_effective := _effective_property(new_content, str(operation.get("node_path", "")), str(operation.get("property_name", "")))
		var decoded_value := _decode_typed_value(operation.get("value", {}))
		if not old_effective.get("success", false) or not new_effective.get("success", false) or not decoded_value.get("success", false):
			return "The reviewed property value could not be revalidated."
		if new_effective.get("value") != decoded_value.get("value") or summary.get("before") != _encode_typed_value(old_effective.get("value")):
			return "The retained scene does not contain the exact reviewed effective property value."
	var semantic_error := _validate_existing_snapshots(old_result["snapshot"], new_result["snapshot"], operation, summary)
	if not semantic_error.is_empty():
		return semantic_error
	if rebuild:
		var rebuilt_existing := _build_existing_candidate(old_content, operation)
		if not rebuilt_existing.get("success", false) or rebuilt_existing.get("summary") != summary:
			return "The reviewed structured scene operation could not be packed again."
		var rebuilt_snapshot := _snapshot_content(str(rebuilt_existing.get("content", "")), new_dependencies)
		if not rebuilt_snapshot.get("success", false) or rebuilt_snapshot.get("snapshot") != new_result.get("snapshot"):
			return "Rebuilding the reviewed operation no longer produces the same complete scene semantics."
	return ""


static func _normalize_operations(operations) -> Dictionary:
	if typeof(operations) != TYPE_ARRAY or operations.size() != 1:
		return _failure("operations must contain exactly one scene operation.")
	var raw = operations[0]
	if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("operation")) != TYPE_STRING:
		return _failure("The scene operation must be an object with an operation string.")
	var operation_name := str(raw.get("operation"))
	if operation_name == "create_scene":
		for key in raw:
			if str(key) not in ["operation", "root_type", "root_name"]:
				return _failure("Unknown create_scene field: " + str(key))
		if typeof(raw.get("root_type")) != TYPE_STRING or typeof(raw.get("root_name")) != TYPE_STRING:
			return _failure("root_type and root_name must be strings.")
		var root_type := str(raw["root_type"])
		var root_name := str(raw["root_name"])
		var create_error := _validate_node_identity(root_type, root_name)
		if not create_error.is_empty():
			return _failure(create_error)
		return {"success": true, "operation": {"operation": operation_name, "root_type": root_type, "root_name": root_name}}
	if operation_name == "add_node":
		for key in raw:
			if str(key) not in ["operation", "parent_path", "node_type", "node_name"]:
				return _failure("Unknown add_node field: " + str(key))
		if typeof(raw.get("parent_path")) != TYPE_STRING or typeof(raw.get("node_type")) != TYPE_STRING or typeof(raw.get("node_name")) != TYPE_STRING:
			return _failure("parent_path, node_type, and node_name must be strings.")
		var parent_path := str(raw["parent_path"])
		var node_type := str(raw["node_type"])
		var node_name := str(raw["node_name"])
		var identity_error := _validate_node_identity(node_type, node_name)
		if not identity_error.is_empty():
			return _failure(identity_error)
		var path_error := _validate_parent_path(parent_path)
		if not path_error.is_empty():
			return _failure(path_error)
		return {"success": true, "operation": {"operation": operation_name, "parent_path": parent_path, "node_type": node_type, "node_name": node_name}}
	if operation_name == "set_property":
		for key in raw:
			if str(key) not in ["operation", "node_path", "property_name", "value"]:
				return _failure("Unknown set_property field: " + str(key))
		if typeof(raw.get("node_path")) != TYPE_STRING or typeof(raw.get("property_name")) != TYPE_STRING or typeof(raw.get("value")) != TYPE_DICTIONARY:
			return _failure("set_property requires string node_path/property_name and a typed value object.")
		var property_path_error := _validate_parent_path(str(raw["node_path"]))
		if not property_path_error.is_empty():
			return _failure(property_path_error.replace("parent_path", "node_path"))
		var property_name := str(raw["property_name"])
		if property_name.is_empty() or property_name.length() > 128 or property_name in ["script", "owner", "name", "scene_file_path", "unique_name_in_owner"]:
			return _failure("property_name is empty, too long, or reserved for a dedicated scene operation.")
		var wire_result := _decode_typed_value(raw["value"])
		if not wire_result.get("success", false):
			return wire_result
		return {"success": true, "operation": {"operation": operation_name, "node_path": str(raw["node_path"]), "property_name": property_name, "value": raw["value"].duplicate(true)}}
	if operation_name == "rename_node":
		for key in raw:
			if str(key) not in ["operation", "node_path", "new_name"]:
				return _failure("Unknown rename_node field: " + str(key))
		if typeof(raw.get("node_path")) != TYPE_STRING or typeof(raw.get("new_name")) != TYPE_STRING:
			return _failure("rename_node requires string node_path and new_name.")
		var rename_path_error := _validate_parent_path(str(raw["node_path"]))
		if not rename_path_error.is_empty():
			return _failure(rename_path_error.replace("parent_path", "node_path"))
		var rename_error := _validate_node_identity("Node", str(raw["new_name"]))
		if not rename_error.is_empty():
			return _failure(rename_error.replace("node type must be one of: Node, Node2D, Node3D, Control", "Invalid node name"))
		return {"success": true, "operation": {"operation": operation_name, "node_path": str(raw["node_path"]), "new_name": str(raw["new_name"])}}
	if operation_name == "remove_node":
		for key in raw:
			if str(key) not in ["operation", "node_path"]:
				return _failure("Unknown remove_node field: " + str(key))
		if typeof(raw.get("node_path")) != TYPE_STRING:
			return _failure("remove_node requires a string node_path.")
		var remove_path_error := _validate_parent_path(str(raw["node_path"]))
		if not remove_path_error.is_empty() or str(raw["node_path"]) == ".":
			return _failure("remove_node requires a canonical non-root node_path.")
		return {"success": true, "operation": {"operation": operation_name, "node_path": str(raw["node_path"])}}
	if operation_name == "reparent_node":
		for key in raw:
			if str(key) not in ["operation", "node_path", "new_parent_path"]:
				return _failure("Unknown reparent_node field: " + str(key))
		if typeof(raw.get("node_path")) != TYPE_STRING or typeof(raw.get("new_parent_path")) != TYPE_STRING:
			return _failure("reparent_node requires string node_path and new_parent_path.")
		var reparent_path_error := _validate_parent_path(str(raw["node_path"]))
		var new_parent_error := _validate_parent_path(str(raw["new_parent_path"]))
		if not reparent_path_error.is_empty() or not new_parent_error.is_empty() or str(raw["node_path"]) == ".":
			return _failure("reparent_node requires canonical non-root node_path and canonical new_parent_path.")
		return {"success": true, "operation": {"operation": operation_name, "node_path": str(raw["node_path"]), "new_parent_path": str(raw["new_parent_path"])}}
	if operation_name in ["attach_script", "detach_script"]:
		for key in raw:
			if str(key) not in ["operation", "node_path", "script_path", "script_hash"]:
				return _failure("Unknown " + operation_name + " field: " + str(key))
		for field in ["node_path", "script_path", "script_hash"]:
			if typeof(raw.get(field)) != TYPE_STRING:
				return _failure(operation_name + " requires string node_path, script_path, and script_hash.")
		var script_node_error := _validate_parent_path(str(raw["node_path"]))
		if not script_node_error.is_empty():
			return _failure(script_node_error.replace("parent_path", "node_path"))
		var script_path := _canonical_res_path(str(raw["script_path"]))
		if script_path.is_empty() or script_path != str(raw["script_path"]) or script_path.get_extension().to_lower() != "gd":
			return _failure("script_path must be a canonical res:// path ending in .gd.")
		var script_hash := str(raw["script_hash"])
		if script_hash.length() != 64 or not script_hash.is_valid_hex_number(false):
			return _failure("script_hash must be the exact lowercase SHA-256 returned by read_file.")
		return {"success": true, "operation": {"operation": operation_name, "node_path": str(raw["node_path"]), "script_path": script_path, "script_hash": script_hash.to_lower()}}
	if operation_name == "instantiate_child_scene":
		for key in raw:
			if str(key) not in ["operation", "parent_path", "child_scene_path", "child_hash", "node_name"]:
				return _failure("Unknown instantiate_child_scene field: " + str(key))
		if typeof(raw.get("parent_path")) != TYPE_STRING or typeof(raw.get("child_scene_path")) != TYPE_STRING or typeof(raw.get("child_hash")) != TYPE_STRING or typeof(raw.get("node_name")) != TYPE_STRING:
			return _failure("instantiate_child_scene requires string parent_path, child_scene_path, child_hash, and node_name.")
		var child_parent_error := _validate_parent_path(str(raw["parent_path"]))
		if not child_parent_error.is_empty():
			return _failure(child_parent_error)
		var child_name_error := _validate_node_identity("Node", str(raw["node_name"]))
		if not child_name_error.is_empty():
			return _failure(child_name_error)
		var child_path := _canonical_res_path(str(raw["child_scene_path"]))
		if child_path.is_empty() or child_path != str(raw["child_scene_path"]) or child_path.get_extension().to_lower() != "tscn":
			return _failure("child_scene_path must be a canonical res:// path ending in .tscn.")
		return {"success": true, "operation": {"operation": operation_name, "parent_path": str(raw["parent_path"]), "child_scene_path": child_path, "child_hash": str(raw["child_hash"]), "node_name": str(raw["node_name"])}}
	if operation_name in ["connect_signal", "disconnect_signal"]:
		var allowed := ["operation", "source_path", "signal_name", "target_path", "method_name"]
		if operation_name == "connect_signal":
			allowed.append_array(["deferred", "one_shot"])
		for key in raw:
			if str(key) not in allowed:
				return _failure("Unknown " + operation_name + " field: " + str(key))
		for field in ["source_path", "signal_name", "target_path", "method_name"]:
			if typeof(raw.get(field)) != TYPE_STRING:
				return _failure(operation_name + " requires string " + field + ".")
		for path_field in ["source_path", "target_path"]:
			var endpoint_error := _validate_parent_path(str(raw[path_field]))
			if not endpoint_error.is_empty():
				return _failure(endpoint_error.replace("parent_path", path_field))
		for identifier_field in ["signal_name", "method_name"]:
			var identifier := str(raw[identifier_field])
			if identifier.is_empty() or identifier.length() > 128 or not identifier.is_valid_identifier():
				return _failure(identifier_field + " must be a valid identifier of at most 128 characters.")
		if operation_name == "connect_signal":
			for bool_field in ["deferred", "one_shot"]:
				if raw.has(bool_field) and typeof(raw[bool_field]) != TYPE_BOOL:
					return _failure(bool_field + " must be a boolean.")
			return {"success": true, "operation": {"operation": operation_name, "source_path": str(raw["source_path"]), "signal_name": str(raw["signal_name"]), "target_path": str(raw["target_path"]), "method_name": str(raw["method_name"]), "deferred": bool(raw.get("deferred", false)), "one_shot": bool(raw.get("one_shot", false))}}
		return {"success": true, "operation": {"operation": operation_name, "source_path": str(raw["source_path"]), "signal_name": str(raw["signal_name"]), "target_path": str(raw["target_path"]), "method_name": str(raw["method_name"])}}
	return _failure("Unsupported structured scene operation: " + operation_name)


static func _validate_node_identity(node_type: String, node_name: String) -> String:
	if node_type not in ALLOWED_ROOT_TYPES:
		return "node type must be one of: " + ", ".join(ALLOWED_ROOT_TYPES)
	if not ClassDB.class_exists(node_type) or not ClassDB.can_instantiate(node_type):
		return "The requested node type cannot be instantiated."
	if node_type != "Node" and not ClassDB.is_parent_class(node_type, "Node"):
		return "The requested type is not a Node."
	if node_name.is_empty() or node_name.length() > MAX_ROOT_NAME_CHARS:
		return "node name must contain 1-%d characters." % MAX_ROOT_NAME_CHARS
	if node_name != node_name.strip_edges() or node_name in [".", ".."]:
		return "node name cannot have surrounding whitespace or use a reserved path name."
	for forbidden in [".", ":", "@", "/", "\"", "%"]:
		if node_name.contains(forbidden):
			return "node name contains characters that Godot would silently replace."
	for character in node_name:
		if character.unicode_at(0) < 32 or character.unicode_at(0) == 127:
			return "node name cannot contain control characters."
	return ""


static func _validate_parent_path(parent_path: String) -> String:
	if parent_path == ".":
		return ""
	if not parent_path.begins_with("./") or parent_path.ends_with("/") or parent_path.contains("//") or parent_path.contains(":") or parent_path.contains("%"):
		return "parent_path must be '.' or a canonical saved node path beginning with './'."
	for segment in parent_path.trim_prefix("./").split("/"):
		if segment.is_empty() or segment in [".", ".."]:
			return "parent_path cannot contain empty, current, or parent segments."
	return ""


static func _build_create_candidate(operation: Dictionary) -> Dictionary:
	var root = _instantiate_native_node(str(operation.get("root_type", "")), str(operation.get("root_name", "")))
	if not root is Node:
		return _failure("The requested root type did not instantiate as a Node.")
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	root.free()
	if pack_error != OK:
		return _failure("Could not pack the proposed scene (error %d)." % pack_error)
	var summary := _create_summary(operation)
	var serialized := _serialize_packed_scene(packed)
	if not serialized.get("success", false):
		return serialized
	var snapshot_result := _snapshot_content(serialized["content"])
	if not snapshot_result.get("success", false) or not _matches_create_snapshot(snapshot_result.get("snapshot", {}), summary):
		return _failure("The serialized scene root does not match the reviewed type and name.")
	serialized["summary"] = summary
	return serialized


static func _build_existing_candidate(old_content: String, operation: Dictionary) -> Dictionary:
	if str(operation.get("operation", "")) == "add_node":
		return _build_add_candidate(old_content, operation)
	var child_result := _validate_child_scene_operation(operation)
	if not child_result.get("success", false):
		return child_result
	var script_result := _validate_script_operation(operation)
	if not script_result.get("success", false):
		return script_result
	var old_dependencies := _operation_dependencies(operation, false)
	var new_dependencies := _operation_dependencies(operation, true)
	var source_result := _load_content(old_content, old_dependencies)
	if not source_result.get("success", false):
		return source_result
	var packed: PackedScene = source_result["packed"]
	var old_snapshot_result := _snapshot_state(packed.get_state(), old_dependencies)
	if not old_snapshot_result.get("success", false):
		return old_snapshot_result
	var old_snapshot: Dictionary = old_snapshot_result["snapshot"]
	var root = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if not root is Node:
		return _failure("Could not instantiate the saved scene for structured mutation.")
	var mutation_resource = script_result.get("script") if str(operation.get("operation", "")) in ["attach_script", "detach_script"] else child_result.get("packed")
	var mutation_result := _apply_simple_mutation(root, old_snapshot, operation, mutation_resource)
	if not mutation_result.get("success", false):
		root.free()
		return mutation_result
	var new_packed := PackedScene.new()
	var pack_error := new_packed.pack(root)
	root.free()
	if pack_error != OK:
		return _failure("Could not pack the modified scene (error %d)." % pack_error)
	var serialized := _serialize_packed_scene(new_packed)
	if not serialized.get("success", false):
		return serialized
	var new_snapshot_result := _snapshot_content(serialized["content"], new_dependencies)
	if not new_snapshot_result.get("success", false):
		return new_snapshot_result
	var summary: Dictionary = mutation_result["summary"]
	var semantic_error := _validate_existing_snapshots(old_snapshot, new_snapshot_result["snapshot"], operation, summary)
	if not semantic_error.is_empty():
		return _failure(semantic_error)
	serialized["summary"] = summary
	serialized["no_changes"] = bool(mutation_result.get("no_changes", false))
	return serialized


static func _apply_simple_mutation(root: Node, old_snapshot: Dictionary, operation: Dictionary, validated_resource = null) -> Dictionary:
	var operation_name := str(operation.get("operation", ""))
	if operation_name == "instantiate_child_scene":
		return _apply_child_instance(root, old_snapshot, operation, validated_resource)
	if operation_name in ["connect_signal", "disconnect_signal"]:
		return _apply_signal_mutation(root, old_snapshot, operation)
	var node_path := str(operation.get("node_path", ""))
	var node: Node = root if node_path == "." else root.get_node_or_null(NodePath(node_path))
	if node == null or _node_record_by_path(old_snapshot.get("nodes", []), node_path).is_empty():
		return _failure("node_path does not identify a saved local node.")
	if operation_name in ["rename_node", "remove_node", "reparent_node"]:
		var structural_error := _validate_structural_scene(old_snapshot, node_path)
		if not structural_error.is_empty():
			return _failure(structural_error)
	if operation_name in ["attach_script", "detach_script"]:
		return _apply_script_mutation(node, old_snapshot, operation, validated_resource)
	if operation_name == "set_property":
		var property_name := str(operation.get("property_name", ""))
		var property_info := _property_info(node, property_name)
		if property_info.is_empty() or (int(property_info.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0 or (int(property_info.get("usage", 0)) & PROPERTY_USAGE_READ_ONLY) != 0:
			return _failure("The property is missing, read-only, or not serialized by PackedScene.")
		var decoded := _decode_typed_value(operation.get("value", {}))
		if not decoded.get("success", false):
			return decoded
		var value = decoded["value"]
		if typeof(value) != int(property_info.get("type", TYPE_NIL)):
			return _failure("The typed value does not match the Godot property Variant type " + type_string(int(property_info.get("type", TYPE_NIL))) + ".")
		var before = node.get(property_name)
		node.set(property_name, value)
		var after = node.get(property_name)
		if typeof(after) != typeof(value) or after != value:
			return _failure("Godot did not retain the exact reviewed property value.")
		return {"success": true, "no_changes": before == after, "summary": {"operation": operation_name, "node_path": node_path, "node_type": node.get_class(), "property_name": property_name, "before": _encode_typed_value(before), "after": operation.get("value", {}).duplicate(true), "node_count": int(old_snapshot.get("node_count", 0))}}
	if operation_name == "rename_node":
		var new_name := str(operation.get("new_name", ""))
		if node.get_parent() != null and node.get_parent().has_node(NodePath(new_name)):
			return _failure("The node's parent already contains a child named " + new_name)
		var old_name := str(node.name)
		node.name = new_name
		if str(node.name) != new_name:
			return _failure("Godot did not retain the reviewed node name.")
		var new_path := "." if node == root else _replace_leaf_name(node_path, new_name)
		return {"success": true, "no_changes": old_name == new_name, "summary": {"operation": operation_name, "old_path": node_path, "new_path": new_path, "old_name": old_name, "new_name": new_name, "node_type": node.get_class(), "node_count": int(old_snapshot.get("node_count", 0))}}
	if operation_name == "remove_node":
		if node.get_child_count() > 0:
			return _failure("The initial remove_node operation accepts leaf nodes only.")
		var removed := {"path": node_path, "name": str(node.name), "type": node.get_class(), "parent_path": str(_node_record_by_path(old_snapshot.get("nodes", []), node_path).get("parent_path", ""))}
		node.get_parent().remove_child(node)
		node.free()
		return {"success": true, "summary": {"operation": operation_name, "removed_node": removed, "before_node_count": int(old_snapshot.get("node_count", 0)), "after_node_count": int(old_snapshot.get("node_count", 0)) - 1}}
	if operation_name == "reparent_node":
		if node.get_child_count() > 0:
			return _failure("The initial reparent_node operation accepts leaf nodes only.")
		var new_parent_path := str(operation.get("new_parent_path", ""))
		var new_parent: Node = root if new_parent_path == "." else root.get_node_or_null(NodePath(new_parent_path))
		if new_parent == null or _node_record_by_path(old_snapshot.get("nodes", []), new_parent_path).is_empty():
			return _failure("new_parent_path does not identify a saved local node.")
		if node.get_parent() == new_parent:
			return _failure("The node already has the reviewed parent.")
		if new_parent.has_node(NodePath(str(node.name))):
			return _failure("The new parent already contains a child with the moved node's name.")
		var old_parent_path := str(_node_record_by_path(old_snapshot.get("nodes", []), node_path).get("parent_path", ""))
		node.owner = null
		node.reparent(new_parent, false)
		node.owner = root
		if node.get_parent() != new_parent:
			return _failure("Godot did not retain the reviewed new parent.")
		var new_path := ("./" + str(node.name)) if new_parent_path == "." else new_parent_path + "/" + str(node.name)
		return {"success": true, "summary": {"operation": operation_name, "old_path": node_path, "new_path": new_path, "old_parent_path": old_parent_path, "new_parent_path": new_parent_path, "node_name": str(node.name), "node_type": node.get_class(), "node_count": int(old_snapshot.get("node_count", 0))}}
	return _failure("Unsupported existing-scene operation: " + operation_name)


static func _apply_child_instance(root: Node, old_snapshot: Dictionary, operation: Dictionary, validated_resource) -> Dictionary:
	if not validated_resource is PackedScene:
		return _failure("The reviewed child could not be loaded as a PackedScene.")
	var parent_path := str(operation.get("parent_path", ""))
	var parent: Node = root if parent_path == "." else root.get_node_or_null(NodePath(parent_path))
	if parent == null or _node_record_by_path(old_snapshot.get("nodes", []), parent_path).is_empty():
		return _failure("parent_path does not identify a saved local node.")
	var node_name := str(operation.get("node_name", ""))
	if parent.has_node(NodePath(node_name)):
		return _failure("The parent already contains a child named " + node_name)
	var child = validated_resource.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if not child is Node:
		return _failure("The reviewed child scene could not be instantiated.")
	child.name = node_name
	parent.add_child(child)
	child.owner = root
	if child.get_parent() != parent or child.owner != root or str(child.name) != node_name:
		return _failure("The child instance did not retain its reviewed parent, owner, and name.")
	var instance_path := ("./" + node_name) if parent_path == "." else parent_path + "/" + node_name
	return {"success": true, "summary": {"operation": "instantiate_child_scene", "before_node_count": int(old_snapshot.get("node_count", 0)), "after_node_count": int(old_snapshot.get("node_count", 0)) + 1, "instance": {"path": instance_path, "parent_path": parent_path, "name": node_name, "scene_path": str(operation.get("child_scene_path", "")), "owner_path": "."}}}


static func _apply_script_mutation(node: Node, old_snapshot: Dictionary, operation: Dictionary, validated_resource) -> Dictionary:
	if not validated_resource is GDScript:
		return _failure("The exact reviewed script could not be loaded as GDScript.")
	var script: GDScript = validated_resource
	var operation_name := str(operation.get("operation", ""))
	var script_path := str(operation.get("script_path", ""))
	var current = node.get_script()
	if operation_name == "attach_script":
		if current != null:
			return _failure("attach_script requires a target node without an attached script.")
		var base_type := str(script.get_instance_base_type())
		if base_type.is_empty() or not ClassDB.class_exists(base_type) or not node.is_class(base_type):
			return _failure("The reviewed script's native base type is incompatible with the target node.")
		node.set_script(script)
		if node.get_script() != script:
			return _failure("Godot did not retain the exact reviewed script on the target node.")
		return {"success": true, "summary": {"operation": operation_name, "node_path": str(operation.get("node_path", "")), "node_type": node.get_class(), "script_base": base_type, "before_script": "", "after_script": script_path, "node_count": int(old_snapshot.get("node_count", 0))}}
	if not current is GDScript or _canonical_res_path(current.resource_path) != script_path:
		return _failure("detach_script requires the exact reviewed script on the target node.")
	var detached_base := str((current as GDScript).get_instance_base_type())
	node.set_script(null)
	if node.get_script() != null:
		return _failure("Godot did not detach the reviewed script from the target node.")
	return {"success": true, "summary": {"operation": operation_name, "node_path": str(operation.get("node_path", "")), "node_type": node.get_class(), "script_base": detached_base, "before_script": script_path, "after_script": "", "node_count": int(old_snapshot.get("node_count", 0))}}


static func _apply_signal_mutation(root: Node, old_snapshot: Dictionary, operation: Dictionary) -> Dictionary:
	var source_path := str(operation.get("source_path", ""))
	var target_path := str(operation.get("target_path", ""))
	if _node_record_by_path(old_snapshot.get("nodes", []), source_path).is_empty() or _node_record_by_path(old_snapshot.get("nodes", []), target_path).is_empty():
		return _failure("Signal endpoints must identify saved local nodes.")
	var source: Node = root if source_path == "." else root.get_node_or_null(NodePath(source_path))
	var target: Node = root if target_path == "." else root.get_node_or_null(NodePath(target_path))
	if source == null or target == null:
		return _failure("The reviewed signal endpoints could not be resolved.")
	var signal_name := str(operation.get("signal_name", ""))
	var method_name := str(operation.get("method_name", ""))
	if not source.has_signal(signal_name) or not target.has_method(method_name):
		return _failure("The source signal or target method does not exist.")
	if not _signal_signature_compatible(source, signal_name, target, method_name):
		return _failure("The source signal arguments are incompatible with the target method.")
	var callable := Callable(target, method_name)
	var operation_name := str(operation.get("operation", ""))
	var expected := _connection_from_operation(operation)
	if operation_name == "connect_signal":
		if source.is_connected(signal_name, callable):
			return _failure("The reviewed signal connection already exists.")
		var connect_error := source.connect(signal_name, callable, int(expected.get("flags", Object.CONNECT_PERSIST)))
		if connect_error != OK or not source.is_connected(signal_name, callable):
			return _failure("Godot could not create the reviewed persistent signal connection.")
		return {"success": true, "summary": {"operation": operation_name, "connection": expected, "before_connection_count": old_snapshot.get("connections", []).size(), "after_connection_count": old_snapshot.get("connections", []).size() + 1}}
	var matches := _matching_connections(old_snapshot.get("connections", []), expected, true)
	if matches.size() != 1:
		return _failure("disconnect_signal requires exactly one matching bindless persistent connection.")
	source.disconnect(signal_name, callable)
	if source.is_connected(signal_name, callable):
		return _failure("Godot did not disconnect the reviewed signal connection.")
	return {"success": true, "summary": {"operation": operation_name, "connection": matches[0], "before_connection_count": old_snapshot.get("connections", []).size(), "after_connection_count": old_snapshot.get("connections", []).size() - 1}}


static func _validate_structural_scene(snapshot: Dictionary, target_path: String) -> String:
	if not snapshot.get("connections", []).is_empty():
		return "Rename, remove, and reparent initially require a scene without saved signal connections."
	for record in snapshot.get("nodes", []):
		for property in record.get("properties", []):
			if typeof(property.get("value")) == TYPE_NODE_PATH:
				return "Rename, remove, and reparent initially require a scene without serialized NodePath properties."
	if target_path != ".":
		for record in snapshot.get("nodes", []):
			if str(record.get("path", "")).begins_with(target_path + "/"):
				return "The initial structural operations accept leaf nodes only."
	return ""


static func _build_add_candidate(old_content: String, operation: Dictionary) -> Dictionary:
	var source_result := _load_content(old_content)
	if not source_result.get("success", false):
		return source_result
	var packed: PackedScene = source_result["packed"]
	var old_snapshot_result := _snapshot_state(packed.get_state())
	if not old_snapshot_result.get("success", false):
		return old_snapshot_result
	var old_snapshot: Dictionary = old_snapshot_result["snapshot"]
	var parent_path := str(operation.get("parent_path", ""))
	if _node_record_by_path(old_snapshot.get("nodes", []), parent_path).is_empty():
		return _failure("parent_path does not identify a saved node in the scene.")
	var root = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if not root is Node:
		return _failure("Could not instantiate the scriptless saved scene for structured mutation.")
	var parent: Node = root if parent_path == "." else root.get_node_or_null(NodePath(parent_path))
	if parent == null:
		root.free()
		return _failure("The reviewed parent path could not be resolved in the instantiated scene.")
	var node_name := str(operation.get("node_name", ""))
	if parent.has_node(NodePath(node_name)):
		root.free()
		return _failure("The parent already contains a child named " + node_name)
	var added = _instantiate_native_node(str(operation.get("node_type", "")), node_name)
	if not added is Node:
		root.free()
		return _failure("The requested node type did not instantiate as a Node.")
	parent.add_child(added)
	added.owner = root
	if added.get_parent() != parent or added.owner != root or str(added.name) != node_name:
		root.free()
		return _failure("The added node did not retain its reviewed parent, owner, and name.")
	var new_packed := PackedScene.new()
	var pack_error := new_packed.pack(root)
	root.free()
	if pack_error != OK:
		return _failure("Could not pack the modified scene (error %d)." % pack_error)
	var added_path := ("./" + node_name) if parent_path == "." else parent_path + "/" + node_name
	var summary := {
		"operation": "add_node",
		"before_node_count": int(old_snapshot.get("node_count", 0)),
		"after_node_count": int(old_snapshot.get("node_count", 0)) + 1,
		"root_type": str(old_snapshot.get("root_type", "")),
		"root_name": str(old_snapshot.get("root_name", "")),
		"added_node": {"path": added_path, "parent_path": parent_path, "type": str(operation.get("node_type", "")), "name": node_name, "owner_path": "."}
	}
	var serialized := _serialize_packed_scene(new_packed)
	if not serialized.get("success", false):
		return serialized
	var candidate_snapshot_result := _snapshot_content(serialized["content"])
	if not candidate_snapshot_result.get("success", false):
		return candidate_snapshot_result
	var serialized_added := _node_record_by_path(candidate_snapshot_result.get("snapshot", {}).get("nodes", []), added_path)
	if serialized_added.is_empty():
		return _failure("The added node was not present after scene serialization.")
	summary["added_node"]["sibling_index"] = int(serialized_added.get("sibling_index", -1))
	summary["added_node"]["serialized_property_count"] = serialized_added.get("properties", []).size()
	var semantic_error := _validate_add_snapshots(old_snapshot, candidate_snapshot_result["snapshot"], operation, summary)
	if not semantic_error.is_empty():
		return _failure(semantic_error)
	serialized["summary"] = summary
	return serialized


static func _instantiate_native_node(node_type: String, node_name: String):
	var object = ClassDB.instantiate(node_type)
	if not object is Node:
		if object != null and object is Object:
			object.free()
		return null
	var node: Node = object
	node.name = node_name
	if str(node.name) != node_name:
		node.free()
		return null
	return node


static func _serialize_packed_scene(packed: PackedScene) -> Dictionary:
	var scratch_error := _prepare_scratch_directory()
	if not scratch_error.is_empty():
		return _failure(scratch_error)
	var scratch_path := _new_scratch_path("scene")
	var save_error := ResourceSaver.save(packed, scratch_path, ResourceSaver.FLAG_OMIT_EDITOR_PROPERTIES)
	if save_error != OK:
		_remove_scratch(scratch_path)
		return _failure("Could not serialize the proposed PackedScene (error %d)." % save_error)
	var read_result := _read_scene_file(scratch_path)
	_remove_scratch(scratch_path)
	return read_result


static func _snapshot_content(content: String, allowed_dependencies: Array = []) -> Dictionary:
	var loaded := _load_content(content, allowed_dependencies)
	if not loaded.get("success", false):
		return loaded
	return _snapshot_state((loaded["packed"] as PackedScene).get_state(), allowed_dependencies)


static func _load_content(content: String, allowed_dependencies: Array = []) -> Dictionary:
	if content.to_utf8_buffer().size() > MAX_SCENE_FILE_BYTES:
		return _failure("The retained scene exceeds the 2 MB limit.")
	var scratch_error := _prepare_scratch_directory()
	if not scratch_error.is_empty():
		return _failure(scratch_error)
	var scratch_path := _new_scratch_path("candidate")
	var file := FileAccess.open(scratch_path, FileAccess.WRITE)
	if file == null:
		return _failure("Could not create a scene-validation scratch file.")
	file.store_string(content)
	file.close()
	var dependency_error := _serialized_dependency_error(content, scratch_path, allowed_dependencies)
	if not dependency_error.is_empty():
		_remove_scratch(scratch_path)
		return _failure(dependency_error)
	var packed = ResourceLoader.load(scratch_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	_remove_scratch(scratch_path)
	if not packed is PackedScene or not packed.can_instantiate() or packed.get_state() == null:
		return _failure("The proposed bytes could not be reloaded as a valid PackedScene.")
	var preflight := _preflight_state(packed.get_state(), allowed_dependencies)
	if not preflight.is_empty():
		return _failure(preflight)
	return {"success": true, "packed": packed}


static func _preflight_content(content: String, allowed_dependencies: Array = []) -> String:
	var result := _snapshot_content(content, allowed_dependencies)
	return "" if result.get("success", false) else str(result.get("error", "The scene is not safe for structured mutation."))


static func _preflight_state(state: SceneState, allowed_dependencies: Array = []) -> String:
	if state.get_base_scene_state() != null:
		return "Inherited scenes are not supported by the initial add_node operation."
	if state.get_node_count() < 1 or state.get_node_count() > MAX_MUTATION_NODES:
		return "The scene must contain 1-%d local nodes for structured mutation." % MAX_MUTATION_NODES
	if state.get_connection_count() > MAX_MUTATION_CONNECTIONS:
		return "The scene exceeds the %d-connection mutation limit." % MAX_MUTATION_CONNECTIONS
	var property_total := 0
	for node_index in range(state.get_node_count()):
		if state.is_node_instance_placeholder(node_index):
			return "Scene instance placeholders are not supported by structured mutation."
		var instance: PackedScene = state.get_node_instance(node_index)
		if instance != null:
			if _canonical_res_path(instance.resource_path) not in allowed_dependencies:
				return "The scene contains a child instance outside the operation's reviewed dependency set."
		else:
			var existing_type := str(state.get_node_type(node_index))
			if not ClassDB.class_exists(existing_type) or ClassDB.class_get_api_type(existing_type) != ClassDB.API_CORE or (existing_type != "Node" and not ClassDB.is_parent_class(existing_type, "Node")):
				return "Only native Godot core Node types are supported by structured mutation."
		property_total += state.get_node_property_count(node_index)
		if property_total > MAX_MUTATION_PROPERTIES:
			return "The scene exceeds the %d-property mutation limit." % MAX_MUTATION_PROPERTIES
		for property_index in range(state.get_node_property_count(node_index)):
			var property_name := str(state.get_node_property_name(node_index, property_index))
			var value = state.get_node_property_value(node_index, property_index)
			if property_name == "script" and value != null:
				if not value is GDScript or _canonical_res_path(value.resource_path) not in allowed_dependencies:
					return "The scene contains a script outside the operation's reviewed dependency set."
				continue
			if _variant_has_unsafe_object(value, 0):
				return "Scenes with serialized Resource or executable object properties are not supported by the initial add_node operation."
	for connection_index in range(state.get_connection_count()):
		if _variant_has_unsafe_object(state.get_connection_binds(connection_index), 0):
			return "Signal binds containing Resource or executable object values are not supported."
	return ""


static func _snapshot_state(state: SceneState, allowed_dependencies: Array = []) -> Dictionary:
	var preflight := _preflight_state(state, allowed_dependencies)
	if not preflight.is_empty():
		return _failure(preflight)
	var nodes: Array = []
	for node_index in range(state.get_node_count()):
		var properties: Array = []
		for property_index in range(state.get_node_property_count(node_index)):
			var property_name := str(state.get_node_property_name(node_index, property_index))
			var property_value = state.get_node_property_value(node_index, property_index)
			properties.append({"name": property_name, "value": property_value})
		nodes.append({
			"path": str(state.get_node_path(node_index)),
			"parent_path": str(state.get_node_path(node_index, true)),
			"name": str(state.get_node_name(node_index)),
			"type": str(state.get_node_type(node_index)),
			"owner_path": str(state.get_node_owner_path(node_index)),
			"sibling_index": state.get_node_index(node_index),
			"instance_scene": _canonical_res_path(state.get_node_instance(node_index).resource_path) if state.get_node_instance(node_index) != null else "",
			"groups": Array(state.get_node_groups(node_index)),
			"properties": properties
		})
	var connections: Array = []
	for connection_index in range(state.get_connection_count()):
		connections.append({
			"source": _canonical_connection_path(str(state.get_connection_source(connection_index))),
			"signal": str(state.get_connection_signal(connection_index)),
			"target": _canonical_connection_path(str(state.get_connection_target(connection_index))),
			"method": str(state.get_connection_method(connection_index)),
			"flags": state.get_connection_flags(connection_index),
			"unbinds": state.get_connection_unbinds(connection_index),
			"binds": state.get_connection_binds(connection_index)
		})
	return {"success": true, "snapshot": {"node_count": nodes.size(), "root_type": str(state.get_node_type(0)), "root_name": str(state.get_node_name(0)), "nodes": nodes, "connections": connections}}


static func _validate_existing_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	match str(operation.get("operation", "")):
		"add_node":
			return _validate_add_snapshots(old_snapshot, new_snapshot, operation, summary)
		"set_property":
			return _validate_property_snapshots(old_snapshot, new_snapshot, operation, summary)
		"rename_node":
			return _validate_rename_snapshots(old_snapshot, new_snapshot, operation, summary)
		"remove_node":
			return _validate_remove_snapshots(old_snapshot, new_snapshot, operation, summary)
		"reparent_node":
			return _validate_reparent_snapshots(old_snapshot, new_snapshot, operation, summary)
		"instantiate_child_scene":
			return _validate_instance_snapshots(old_snapshot, new_snapshot, operation, summary)
		"attach_script", "detach_script":
			return _validate_script_snapshots(old_snapshot, new_snapshot, operation, summary)
		"connect_signal", "disconnect_signal":
			return _validate_signal_snapshots(old_snapshot, new_snapshot, operation, summary)
	return "Unsupported retained existing-scene operation."


static func _validate_script_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "The script operation changed scene structure or connections."
	var node_path := str(operation.get("node_path", ""))
	var script_path := str(operation.get("script_path", ""))
	var attaching := str(operation.get("operation", "")) == "attach_script"
	var old_nodes: Array = old_snapshot.get("nodes", []).duplicate(true)
	var new_nodes: Array = new_snapshot.get("nodes", []).duplicate(true)
	var old_target := _node_record_by_path(old_nodes, node_path)
	var new_target := _node_record_by_path(new_nodes, node_path)
	if old_target.is_empty() or new_target.is_empty():
		return "The script target is missing from the retained scene."
	var old_script := _record_script_path(old_target)
	var new_script := _record_script_path(new_target)
	if (attaching and (not old_script.is_empty() or new_script != script_path)) or (not attaching and (old_script != script_path or not new_script.is_empty())):
		return "The candidate does not contain the exact reviewed script attachment transition."
	if _script_property_count(old_snapshot.get("nodes", [])) != (0 if attaching else 1) or _script_property_count(new_snapshot.get("nodes", [])) != (1 if attaching else 0):
		return "The initial script operation requires exactly one reviewed script attachment and no other scripts."
	for record in [old_target, new_target]:
		var filtered: Array = []
		for property in record.get("properties", []):
			if str(property.get("name", "")) != "script":
				filtered.append(property)
		record["properties"] = filtered
	if old_nodes != new_nodes:
		return "The script operation changed unrelated nodes or serialized properties."
	if str(summary.get("operation", "")) != str(operation.get("operation", "")) or str(summary.get("node_path", "")) != node_path or str(summary.get("before_script", "")) != old_script or str(summary.get("after_script", "")) != new_script:
		return "The retained script review summary no longer matches its operation."
	return ""


static func _validate_add_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) + 1:
		return "The add_node candidate does not contain exactly one additional node."
	var added: Dictionary = summary.get("added_node", {})
	var expected_path := ("./" + str(operation.get("node_name", ""))) if str(operation.get("parent_path", "")) == "." else str(operation.get("parent_path", "")) + "/" + str(operation.get("node_name", ""))
	if str(added.get("path", "")) != expected_path or str(added.get("parent_path", "")) != str(operation.get("parent_path", "")) or str(added.get("type", "")) != str(operation.get("node_type", "")) or str(added.get("name", "")) != str(operation.get("node_name", "")):
		return "The retained add_node summary no longer matches its operation."
	if int(summary.get("before_node_count", 0)) != int(old_snapshot.get("node_count", 0)) or int(summary.get("after_node_count", 0)) != int(new_snapshot.get("node_count", 0)) or str(summary.get("root_type", "")) != str(old_snapshot.get("root_type", "")) or str(summary.get("root_name", "")) != str(old_snapshot.get("root_name", "")):
		return "The retained scene counts or root identity no longer match the proposal."
	var added_record := _node_record_by_path(new_snapshot.get("nodes", []), expected_path)
	if added_record.is_empty() or str(added_record.get("parent_path", "")) != str(added.get("parent_path", "")) or str(added_record.get("type", "")) != str(added.get("type", "")) or str(added_record.get("name", "")) != str(added.get("name", "")) or str(added_record.get("owner_path", "")) != "." or int(added_record.get("sibling_index", -1)) != int(added.get("sibling_index", -2)) or added_record.get("properties", []).size() != int(added.get("serialized_property_count", -1)):
		return "The serialized added node does not match its reviewed path, owner, type, name, index, and property count."
	var remaining_nodes: Array = []
	for record in new_snapshot.get("nodes", []):
		if str(record.get("path", "")) != expected_path:
			remaining_nodes.append(record)
	if remaining_nodes != old_snapshot.get("nodes", []) or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "The add_node candidate changed unrelated scene nodes, properties, groups, order, or connections."
	return ""


static func _validate_property_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "set_property changed scene structure or connections."
	var node_path := str(operation.get("node_path", ""))
	var property_name := str(operation.get("property_name", ""))
	if str(summary.get("operation", "")) != "set_property" or str(summary.get("node_path", "")) != node_path or str(summary.get("property_name", "")) != property_name or summary.get("after") != operation.get("value"):
		return "The retained property review summary no longer matches its operation."
	var old_nodes: Array = old_snapshot.get("nodes", []).duplicate(true)
	var new_nodes: Array = new_snapshot.get("nodes", []).duplicate(true)
	for records in [old_nodes, new_nodes]:
		var record := _node_record_by_path(records, node_path)
		if record.is_empty():
			return "The property target is missing from the retained scene."
		var filtered: Array = []
		for property in record.get("properties", []):
			if str(property.get("name", "")) != property_name:
				filtered.append(property)
		record["properties"] = filtered
	if old_nodes != new_nodes:
		return "set_property changed unrelated nodes or serialized properties."
	return ""


static func _validate_rename_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "rename_node changed node or connection counts."
	var old_path := str(operation.get("node_path", ""))
	var new_path := "." if old_path == "." else _replace_leaf_name(old_path, str(operation.get("new_name", "")))
	if str(summary.get("old_path", "")) != old_path or str(summary.get("new_path", "")) != new_path or str(summary.get("new_name", "")) != str(operation.get("new_name", "")):
		return "The retained rename summary no longer matches its operation."
	var old_target := _node_record_by_path(old_snapshot.get("nodes", []), old_path).duplicate(true)
	var new_target := _node_record_by_path(new_snapshot.get("nodes", []), new_path)
	if old_target.is_empty() or new_target.is_empty():
		return "The renamed node is missing from the candidate."
	old_target["path"] = new_path
	old_target["name"] = str(operation.get("new_name", ""))
	if old_target != new_target:
		return "rename_node changed more than the reviewed node name and path."
	if _without_node(old_snapshot.get("nodes", []), old_path) != _without_node(new_snapshot.get("nodes", []), new_path):
		return "rename_node changed unrelated scene nodes."
	return ""


static func _validate_remove_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	var path := str(operation.get("node_path", ""))
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) - 1 or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "remove_node did not remove exactly one unconnected node."
	if str(summary.get("operation", "")) != "remove_node" or str(summary.get("removed_node", {}).get("path", "")) != path:
		return "The retained removal summary no longer matches its operation."
	if _without_node(old_snapshot.get("nodes", []), path) != new_snapshot.get("nodes", []):
		return "remove_node changed unrelated scene nodes."
	return ""


static func _validate_reparent_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "reparent_node changed node or connection counts."
	var old_path := str(operation.get("node_path", ""))
	var new_parent := str(operation.get("new_parent_path", ""))
	var old_target := _node_record_by_path(old_snapshot.get("nodes", []), old_path).duplicate(true)
	var new_path := ("./" + str(old_target.get("name", ""))) if new_parent == "." else new_parent + "/" + str(old_target.get("name", ""))
	var new_target := _node_record_by_path(new_snapshot.get("nodes", []), new_path)
	if old_target.is_empty() or new_target.is_empty() or str(summary.get("old_path", "")) != old_path or str(summary.get("new_path", "")) != new_path:
		return "The retained reparent summary no longer matches its operation."
	old_target["path"] = new_path
	old_target["parent_path"] = new_parent
	if old_target != new_target:
		return "reparent_node changed more than the reviewed parent and path."
	if _without_node(old_snapshot.get("nodes", []), old_path) != _without_node(new_snapshot.get("nodes", []), new_path):
		return "reparent_node changed unrelated scene nodes."
	return ""


static func _validate_instance_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if int(new_snapshot.get("node_count", 0)) != int(old_snapshot.get("node_count", 0)) + 1 or new_snapshot.get("connections", []) != old_snapshot.get("connections", []):
		return "instantiate_child_scene did not add exactly one local instance record."
	var instance: Dictionary = summary.get("instance", {})
	var parent_path := str(operation.get("parent_path", ""))
	var expected_path := ("./" + str(operation.get("node_name", ""))) if parent_path == "." else parent_path + "/" + str(operation.get("node_name", ""))
	if str(summary.get("operation", "")) != "instantiate_child_scene" or str(instance.get("path", "")) != expected_path or str(instance.get("parent_path", "")) != parent_path or str(instance.get("name", "")) != str(operation.get("node_name", "")) or str(instance.get("scene_path", "")) != str(operation.get("child_scene_path", "")):
		return "The retained child-instance summary no longer matches its operation."
	var record := _node_record_by_path(new_snapshot.get("nodes", []), expected_path)
	if record.is_empty() or str(record.get("instance_scene", "")) != str(operation.get("child_scene_path", "")) or str(record.get("owner_path", "")) != "." or str(record.get("parent_path", "")) != parent_path or str(record.get("name", "")) != str(operation.get("node_name", "")):
		return "The serialized child instance does not match its reviewed scene, path, owner, and name."
	if _without_node(new_snapshot.get("nodes", []), expected_path) != old_snapshot.get("nodes", []):
		return "instantiate_child_scene changed unrelated parent-scene records."
	return ""


static func _validate_signal_snapshots(old_snapshot: Dictionary, new_snapshot: Dictionary, operation: Dictionary, summary: Dictionary) -> String:
	if new_snapshot.get("nodes", []) != old_snapshot.get("nodes", []):
		return "The signal operation changed scene nodes or properties."
	var connecting := str(operation.get("operation", "")) == "connect_signal"
	var old_connections: Array = old_snapshot.get("connections", [])
	var new_connections: Array = new_snapshot.get("connections", [])
	if new_connections.size() != old_connections.size() + (1 if connecting else -1):
		return "The signal operation changed an unexpected number of connections."
	var reviewed: Dictionary = summary.get("connection", {})
	if str(summary.get("operation", "")) != str(operation.get("operation", "")):
		return "The retained signal summary no longer matches its operation."
	var expected := _connection_from_operation(operation)
	if connecting:
		if reviewed != expected or not _connection_multiset_equal(_without_connection_once(new_connections, expected), old_connections):
			return "connect_signal changed more than the reviewed persistent connection."
	else:
		if _matching_connections(old_connections, reviewed, true).size() != 1 or not _connection_multiset_equal(_without_connection_once(old_connections, reviewed), new_connections):
			return "disconnect_signal changed more than the reviewed persistent connection."
	return ""


static func _matches_create_snapshot(snapshot: Dictionary, summary: Dictionary) -> bool:
	return int(snapshot.get("node_count", 0)) == 1 and str(snapshot.get("root_type", "")) == str(summary.get("root_type", "")) and str(snapshot.get("root_name", "")) == str(summary.get("root_name", "")) and snapshot.get("connections", []).is_empty()


static func _create_summary(operation: Dictionary) -> Dictionary:
	return {"operation": "create_scene", "node_count": 1, "root_type": str(operation.get("root_type", "")), "root_name": str(operation.get("root_name", ""))}


static func _node_record_by_path(nodes: Array, path: String) -> Dictionary:
	for node in nodes:
		if typeof(node) == TYPE_DICTIONARY and str(node.get("path", "")) == path:
			return node
	return {}


static func _without_node(nodes: Array, path: String) -> Array:
	var result: Array = []
	for node in nodes:
		if str(node.get("path", "")) != path:
			result.append(node)
	return result


static func _replace_leaf_name(path: String, name: String) -> String:
	return path.get_base_dir().path_join(name) if path.contains("/") else "./" + name


static func _canonical_connection_path(path: String) -> String:
	if path.is_empty() or path == ".":
		return "."
	return path if path.begins_with("./") else "./" + path


static func _connection_from_operation(operation: Dictionary) -> Dictionary:
	var flags := Object.CONNECT_PERSIST
	if str(operation.get("operation", "")) == "connect_signal":
		if bool(operation.get("deferred", false)):
			flags |= Object.CONNECT_DEFERRED
		if bool(operation.get("one_shot", false)):
			flags |= Object.CONNECT_ONE_SHOT
	return {"source": str(operation.get("source_path", "")), "signal": str(operation.get("signal_name", "")), "target": str(operation.get("target_path", "")), "method": str(operation.get("method_name", "")), "flags": flags, "unbinds": 0, "binds": []}


static func _matching_connections(connections: Array, expected: Dictionary, require_supported: bool) -> Array:
	var matches: Array = []
	for connection in connections:
		if str(connection.get("source", "")) != str(expected.get("source", "")) or str(connection.get("signal", "")) != str(expected.get("signal", "")) or str(connection.get("target", "")) != str(expected.get("target", "")) or str(connection.get("method", "")) != str(expected.get("method", "")):
			continue
		if require_supported:
			var allowed_flags := Object.CONNECT_PERSIST | Object.CONNECT_DEFERRED | Object.CONNECT_ONE_SHOT
			if not connection.get("binds", []).is_empty() or int(connection.get("unbinds", 0)) != 0 or (int(connection.get("flags", 0)) & ~allowed_flags) != 0 or (int(connection.get("flags", 0)) & Object.CONNECT_PERSIST) == 0:
				continue
		matches.append(connection)
	return matches


static func _without_connection_once(connections: Array, target: Dictionary) -> Array:
	var result: Array = []
	var removed := false
	for connection in connections:
		if not removed and connection == target:
			removed = true
			continue
		result.append(connection)
	return result


static func _connection_multiset_equal(left: Array, right: Array) -> bool:
	if left.size() != right.size():
		return false
	var remaining := right.duplicate(true)
	for connection in left:
		var index := remaining.find(connection)
		if index < 0:
			return false
		remaining.remove_at(index)
	return remaining.is_empty()


static func _signal_signature_compatible(source: Node, signal_name: String, target: Node, method_name: String) -> bool:
	var signal_arg_count := -1
	var signal_args: Array = []
	for info in source.get_signal_list():
		if str(info.get("name", "")) == signal_name:
			signal_arg_count = info.get("args", []).size()
			signal_args = info.get("args", [])
			break
	if signal_arg_count < 0:
		return false
	for info in target.get_method_list():
		if str(info.get("name", "")) == method_name:
			var maximum: int = info.get("args", []).size()
			var minimum: int = maximum - info.get("default_args", []).size()
			if signal_arg_count < minimum or signal_arg_count > maximum:
				return false
			var method_args: Array = info.get("args", [])
			for index in range(signal_arg_count):
				var signal_type := int(signal_args[index].get("type", TYPE_NIL))
				var method_type := int(method_args[index].get("type", TYPE_NIL))
				if signal_type != TYPE_NIL and method_type != TYPE_NIL and signal_type != method_type:
					return false
				if signal_type == TYPE_OBJECT and method_type == TYPE_OBJECT:
					var signal_class := str(signal_args[index].get("class_name", ""))
					var method_class := str(method_args[index].get("class_name", ""))
					if not signal_class.is_empty() and not method_class.is_empty() and signal_class != method_class and (not ClassDB.class_exists(signal_class) or not ClassDB.class_exists(method_class) or not ClassDB.is_parent_class(signal_class, method_class)):
						return false
			return true
	return false


static func _property_info(node: Node, property_name: String) -> Dictionary:
	for info in node.get_property_list():
		if str(info.get("name", "")) == property_name:
			return info
	return {}


static func _effective_property(content: String, node_path: String, property_name: String) -> Dictionary:
	var loaded := _load_content(content)
	if not loaded.get("success", false):
		return loaded
	var root = (loaded["packed"] as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if not root is Node:
		return _failure("Could not instantiate the scene for property validation.")
	var node: Node = root if node_path == "." else root.get_node_or_null(NodePath(node_path))
	if node == null or _property_info(node, property_name).is_empty():
		root.free()
		return _failure("The property target could not be revalidated.")
	var value = node.get(property_name)
	root.free()
	return {"success": true, "value": value}


static func _decode_typed_value(wire) -> Dictionary:
	if typeof(wire) != TYPE_DICTIONARY or typeof(wire.get("type")) != TYPE_STRING:
		return _failure("A typed property value must be an object with a type string.")
	var type_name := str(wire.get("type", ""))
	var allowed_fields := ["type"]
	var value
	match type_name:
		"bool":
			allowed_fields.append("value")
			if typeof(wire.get("value")) != TYPE_BOOL:
				return _failure("A bool property value requires a boolean value field.")
			value = wire["value"]
		"int":
			allowed_fields.append("value")
			if typeof(wire.get("value")) != TYPE_INT:
				return _failure("An int property value requires an integer value field.")
			value = wire["value"]
		"float":
			allowed_fields.append("value")
			if typeof(wire.get("value")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(wire.get("value"))):
				return _failure("A float property value requires a finite numeric value field.")
			value = float(wire["value"])
		"String":
			allowed_fields.append("value")
			if typeof(wire.get("value")) != TYPE_STRING or str(wire.get("value")).length() > 4096:
				return _failure("A String property value requires a string of at most 4096 characters.")
			value = str(wire["value"])
		"StringName":
			allowed_fields.append("value")
			if typeof(wire.get("value")) != TYPE_STRING or str(wire.get("value")).length() > 256:
				return _failure("A StringName property value requires a string of at most 256 characters.")
			value = StringName(str(wire["value"]))
		"Vector2", "Vector2i":
			allowed_fields.append_array(["x", "y"])
			if not _wire_has_numbers(wire, ["x", "y"], type_name.ends_with("i")):
				return _failure(type_name + " requires finite x and y fields of the exact numeric kind.")
			value = Vector2i(int(wire["x"]), int(wire["y"])) if type_name == "Vector2i" else Vector2(float(wire["x"]), float(wire["y"]))
		"Vector3", "Vector3i":
			allowed_fields.append_array(["x", "y", "z"])
			if not _wire_has_numbers(wire, ["x", "y", "z"], type_name.ends_with("i")):
				return _failure(type_name + " requires finite x, y, and z fields of the exact numeric kind.")
			value = Vector3i(int(wire["x"]), int(wire["y"]), int(wire["z"])) if type_name == "Vector3i" else Vector3(float(wire["x"]), float(wire["y"]), float(wire["z"]))
		"Color":
			allowed_fields.append_array(["r", "g", "b", "a"])
			if not _wire_has_numbers(wire, ["r", "g", "b", "a"], false):
				return _failure("Color requires finite r, g, b, and a fields.")
			value = Color(float(wire["r"]), float(wire["g"]), float(wire["b"]), float(wire["a"]))
		"Rect2":
			allowed_fields.append_array(["x", "y", "width", "height"])
			if not _wire_has_numbers(wire, ["x", "y", "width", "height"], false):
				return _failure("Rect2 requires finite x, y, width, and height fields.")
			value = Rect2(float(wire["x"]), float(wire["y"]), float(wire["width"]), float(wire["height"]))
		_:
			return _failure("Unsupported typed property value: " + type_name)
	for key in wire:
		if str(key) not in allowed_fields:
			return _failure("Unknown " + type_name + " value field: " + str(key))
	return {"success": true, "value": value}


static func _wire_has_numbers(wire: Dictionary, fields: Array, require_int: bool) -> bool:
	for field in fields:
		if not wire.has(field):
			return false
		if require_int:
			if typeof(wire[field]) != TYPE_INT:
				return false
		elif typeof(wire[field]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(wire[field])):
			return false
	return true


static func _encode_typed_value(value) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"type": "bool", "value": value}
		TYPE_INT:
			return {"type": "int", "value": value}
		TYPE_FLOAT:
			return {"type": "float", "value": value}
		TYPE_STRING:
			return {"type": "String", "value": value}
		TYPE_STRING_NAME:
			return {"type": "StringName", "value": str(value)}
		TYPE_VECTOR2:
			return {"type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR2I:
			return {"type": "Vector2i", "x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR3I:
			return {"type": "Vector3i", "x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_RECT2:
			return {"type": "Rect2", "x": value.position.x, "y": value.position.y, "width": value.size.x, "height": value.size.y}
	return {"type": type_string(typeof(value)), "unsupported": true}


static func _variant_has_unsafe_object(value, depth: int) -> bool:
	if depth > 6:
		return true
	match typeof(value):
		TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return value != null
		TYPE_ARRAY:
			for item in value:
				if _variant_has_unsafe_object(item, depth + 1):
					return true
		TYPE_DICTIONARY:
			for key in value:
				if _variant_has_unsafe_object(key, depth + 1) or _variant_has_unsafe_object(value[key], depth + 1):
					return true
	return false


static func _serialized_dependency_error(content: String, scratch_path: String, allowed_dependencies: Array = []) -> String:
	for line in content.replace("\r\n", "\n").split("\n"):
		if line.strip_edges().begins_with("[sub_resource"):
			return "Scenes with built-in subresources are not supported because loading their resource types is not sandboxed."
	var observed: Array = []
	for dependency in ResourceLoader.get_dependencies(scratch_path):
		var descriptor := str(dependency)
		var lower := descriptor.to_lower()
		var dependency_path := _dependency_path(descriptor)
		if dependency_path.is_empty():
			return "The scene contains an unresolved external dependency."
		observed.append(dependency_path)
		if dependency_path not in allowed_dependencies:
			if dependency_path.get_extension().to_lower() in ["gd", "cs", "gdextension"]:
				return "The scene contains a script dependency outside the operation's reviewed dependency set."
			if dependency_path.get_extension().to_lower() in ["tscn", "scn"]:
				return "The scene contains child-scene dependencies outside the operation's reviewed dependency set."
			return "The scene contains an external Resource dependency outside the operation's reviewed dependency set."
		if lower.ends_with(".gdextension") or dependency_path.get_extension().to_lower() not in ["gd", "tscn"]:
			return "The scene contains an unsupported external dependency type."
	var expected := allowed_dependencies.duplicate()
	observed.sort()
	expected.sort()
	if observed != expected:
		return "The scene dependency set no longer matches the reviewed operation."
	return ""


static func _operation_dependencies(operation: Dictionary, candidate: bool) -> Array:
	var operation_name := str(operation.get("operation", ""))
	if operation_name == "instantiate_child_scene" and candidate:
		return [str(operation.get("child_scene_path", ""))]
	if operation_name == "attach_script" and candidate:
		return [str(operation.get("script_path", ""))]
	if operation_name == "detach_script" and not candidate:
		return [str(operation.get("script_path", ""))]
	return []


static func _validate_script_operation(operation: Dictionary) -> Dictionary:
	if str(operation.get("operation", "")) not in ["attach_script", "detach_script"]:
		return {"success": true, "script": null}
	var script_path := str(operation.get("script_path", ""))
	if EditorContext.has_unsaved_file(script_path):
		return _failure("The reviewed script has unsaved editor changes.")
	var read_result := _read_script_file(script_path)
	if not read_result.get("success", false):
		return read_result
	var script_content := str(read_result.get("content", ""))
	if script_content.sha256_text() != str(operation.get("script_hash", "")):
		return _failure("The reviewed script changed after trust was granted.")
	var dependencies := ResourceLoader.get_dependencies(script_path)
	if not dependencies.is_empty():
		return _failure("The initial script operation accepts dependency-free GDScript files only.")
	var validation := DiagnosticsService.validate_source(script_path, script_content)
	if not validation.get("valid", false):
		var failure := _failure(str(validation.get("message", "GDScript validation failed.")))
		failure["diagnostics"] = validation.get("diagnostics", [])
		return failure
	var loaded = ResourceLoader.load(script_path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var confirmed := _read_script_file(script_path)
	if not confirmed.get("success", false) or str(confirmed.get("content", "")).sha256_text() != str(operation.get("script_hash", "")):
		return _failure("The script changed while its trusted code was being loaded.")
	if not loaded is GDScript or _canonical_res_path(loaded.resource_path) != script_path:
		return _failure("The exact reviewed path could not be loaded as GDScript.")
	var base_type := str((loaded as GDScript).get_instance_base_type())
	if base_type.is_empty() or not ClassDB.class_exists(base_type) or (base_type != "Node" and not ClassDB.is_parent_class(base_type, "Node")):
		return _failure("The reviewed script must extend a native Godot Node type directly or indirectly.")
	return {"success": true, "script": loaded}


static func _validate_script_trust_fields(proposal: Dictionary, operation: Dictionary) -> String:
	if str(proposal.get("approval_stage", "")) != "candidate":
		return "The script candidate has not completed preliminary execution trust review."
	var scene_path := str(proposal.get("filepath", ""))
	if str(proposal.get("trust_binding", "")) != _script_trust_binding(scene_path, str(proposal.get("old_hash", "")), operation):
		return "The script execution trust binding no longer matches the reviewed operation."
	var script_content := str(proposal.get("script_content", ""))
	if script_content.sha256_text() != str(operation.get("script_hash", "")):
		return "The retained trusted script bytes no longer match the reviewed hash."
	if str(proposal.get("candidate_binding", "")) != _script_candidate_binding(str(proposal.get("trust_binding", "")), str(proposal.get("new_hash", ""))):
		return "The retained script candidate hash no longer matches its trust binding."
	return ""


static func _script_trust_binding(scene_path: String, scene_hash: String, operation: Dictionary) -> String:
	return (scene_path + "\n" + scene_hash + "\n" + JSON.stringify(operation)).sha256_text()


static func _script_candidate_binding(trust_binding: String, candidate_hash: String) -> String:
	return (trust_binding + "\n" + candidate_hash).sha256_text()


static func _record_script_path(record: Dictionary) -> String:
	for property in record.get("properties", []):
		if str(property.get("name", "")) == "script":
			var value = property.get("value")
			if value is GDScript:
				return _canonical_res_path(value.resource_path)
	return ""


static func _script_property_count(nodes: Array) -> int:
	var count := 0
	for record in nodes:
		if not _record_script_path(record).is_empty():
			count += 1
	return count


static func _dependency_path(descriptor: String) -> String:
	var parts := descriptor.split("::", false)
	for index in range(parts.size() - 1, -1, -1):
		var part := str(parts[index])
		if part.begins_with("res://"):
			return _canonical_res_path(part)
		if part.begins_with("uid://"):
			var uid := ResourceUID.text_to_id(part)
			if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
				return _canonical_res_path(ResourceUID.get_id_path(uid))
	return ""


static func _validate_child_scene_operation(operation: Dictionary) -> Dictionary:
	if str(operation.get("operation", "")) != "instantiate_child_scene":
		return {"success": true, "packed": null}
	var child_path := str(operation.get("child_scene_path", ""))
	if child_path.is_empty() or not FileAccess.file_exists(child_path):
		return _failure("The reviewed child scene does not exist.")
	if EditorContext.has_unsaved_file(child_path):
		return _failure("The reviewed child scene has unsaved editor changes.")
	var read_result := _read_scene_file(child_path)
	if not read_result.get("success", false):
		return read_result
	var content := str(read_result.get("content", ""))
	if content.sha256_text() != str(operation.get("child_hash", "")):
		return _failure("child_hash does not match the reviewed child scene. Read it again before proposing this change.")
	var loaded := _load_content(content)
	if not loaded.get("success", false):
		return _failure("The child scene is not safe for structured instantiation: " + str(loaded.get("error", "Unknown error.")))
	var direct_dependency_error := _serialized_dependency_error(content, child_path)
	if not direct_dependency_error.is_empty():
		return _failure("The canonical child scene failed dependency validation: " + direct_dependency_error)
	var confirmed := _read_scene_file(child_path)
	if not confirmed.get("success", false) or str(confirmed.get("content", "")).sha256_text() != str(operation.get("child_hash", "")):
		return _failure("The child scene changed while it was being validated.")
	var packed = ResourceLoader.load(child_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	if not packed is PackedScene:
		return _failure("The reviewed child scene could not be loaded from its canonical project path.")
	var scratch_snapshot := _snapshot_state((loaded["packed"] as PackedScene).get_state())
	var canonical_snapshot := _snapshot_state(packed.get_state())
	if not scratch_snapshot.get("success", false) or not canonical_snapshot.get("success", false) or scratch_snapshot.get("snapshot") != canonical_snapshot.get("snapshot"):
		return _failure("The canonical child scene does not match the exact validated bytes.")
	return {"success": true, "packed": packed}


static func _read_scene_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("Could not read the proposed scene bytes.")
	if file.get_length() > MAX_SCENE_FILE_BYTES:
		file.close()
		return _failure("The proposed scene exceeds the 2 MB limit.")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var content := bytes.get_string_from_utf8()
	if content.to_utf8_buffer() != bytes:
		return _failure("The proposed scene is not valid UTF-8.")
	return {"success": true, "content": content}


static func _read_script_file(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return _failure("The reviewed script does not exist.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("Could not read the reviewed script bytes.")
	if file.get_length() > MAX_SCENE_FILE_BYTES:
		file.close()
		return _failure("The reviewed script exceeds the 2 MB limit.")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var content := bytes.get_string_from_utf8()
	if content.to_utf8_buffer() != bytes:
		return _failure("The reviewed script is not valid UTF-8.")
	return {"success": true, "content": content}


static func _canonical_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return ""
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())


static func _remove_scratch(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _prepare_scratch_directory() -> String:
	var absolute_directory := ProjectSettings.globalize_path(SCRATCH_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		return "Could not create Orca's scene-validation scratch directory."
	var directory := DirAccess.open(SCRATCH_DIRECTORY)
	if directory == null:
		return "Could not inspect Orca's scene-validation scratch directory."
	var cutoff := int(Time.get_unix_time_from_system()) - SCRATCH_MAX_AGE_SECONDS
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if not directory.current_is_dir() and name.get_extension().to_lower() == "tscn" and (name.begins_with("scene_") or name.begins_with("candidate_")):
			var path := SCRATCH_DIRECTORY.path_join(name)
			if int(FileAccess.get_modified_time(path)) < cutoff:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		name = directory.get_next()
	directory.list_dir_end()
	return ""


static func cleanup_stale_scratch(max_age_seconds: int = SCRATCH_MAX_AGE_SECONDS) -> void:
	var directory := DirAccess.open(SCRATCH_DIRECTORY)
	if directory == null:
		return
	var cutoff := int(Time.get_unix_time_from_system()) - maxi(0, max_age_seconds)
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if not directory.current_is_dir() and name.get_extension().to_lower() == "tscn" and (name.begins_with("scene_") or name.begins_with("candidate_")):
			var path := SCRATCH_DIRECTORY.path_join(name)
			if int(FileAccess.get_modified_time(path)) <= cutoff:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		name = directory.get_next()
	directory.list_dir_end()


static func _new_scratch_path(prefix: String) -> String:
	var random_suffix := Crypto.new().generate_random_bytes(12).hex_encode()
	return SCRATCH_DIRECTORY.path_join("%s_%d_%d_%s.tscn" % [prefix, OS.get_process_id(), Time.get_ticks_usec(), random_suffix])


static func _failure(error: String) -> Dictionary:
	return {"success": false, "error": error}
