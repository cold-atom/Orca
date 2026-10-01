@tool
extends RefCounted

const MAX_DEPTH := 3
const MAX_RESULTS := 100
const MAX_SCAN_FILES := 500
const MAX_SCAN_DIRECTORIES := 256
const MAX_SCAN_NODES := 100
const MAX_SCAN_EDGES := 200
const SCAN_TIMEOUT_MS := 2500
const MAX_OUTPUT_BYTES := 96 * 1024

const DIRECTIONS := ["forward", "reverse"]
const ARGUMENTS := ["filepath", "direction", "max_depth", "max_results"]


static func inspect(arguments: Dictionary) -> Dictionary:
	var argument_error := _validate_arguments(arguments)
	if not argument_error.is_empty():
		return _failure(argument_error)
	var filepath := _canonical_res_path(arguments["filepath"])
	var path_error := _validate_project_file(filepath)
	if not path_error.is_empty():
		return _failure(path_error)
	var direction: String = arguments["direction"]
	var max_depth := clampi(int(arguments.get("max_depth", 1)), 1, MAX_DEPTH)
	var max_results := clampi(int(arguments.get("max_results", MAX_RESULTS)), 1, MAX_RESULTS)
	var report := _inspect_forward(filepath, max_depth, max_results) if direction == "forward" else _inspect_reverse(filepath, max_depth, max_results)
	report["filepath"] = filepath
	report["direction"] = direction
	report["max_depth"] = max_depth
	report["max_results"] = max_results
	report["source"] = "resource_loader_serialized_dependencies"
	report["note"] = "Reports dependencies serialized and recognized by ResourceLoader. It does not load or instantiate resources, and it cannot discover dynamic load() calls, arbitrary code references, runtime-created resources, or editor state that has not been saved."
	var content := _fit_and_serialize(report)
	return {"success": true, "content": content, "report": report}


static func _validate_arguments(arguments: Dictionary) -> String:
	for key in arguments:
		if typeof(key) != TYPE_STRING or key not in ARGUMENTS:
			return "Unknown dependency inspection argument: " + str(key)
	if typeof(arguments.get("filepath")) != TYPE_STRING or str(arguments.get("filepath", "")).is_empty():
		return "filepath must be a non-empty String."
	if typeof(arguments.get("direction")) != TYPE_STRING or str(arguments.get("direction", "")) not in DIRECTIONS:
		return "direction must be either forward or reverse."
	if arguments.has("max_depth") and typeof(arguments["max_depth"]) != TYPE_INT:
		return "max_depth must be an integer."
	if arguments.has("max_results") and typeof(arguments["max_results"]) != TYPE_INT:
		return "max_results must be an integer."
	return ""


static func _inspect_forward(filepath: String, max_depth: int, max_results: int) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	var reasons := PackedStringArray()
	var visited := {filepath: true}
	var queue: Array = [{"path": filepath, "depth": 0}]
	var queue_index := 0
	while queue_index < queue.size() and nodes.size() < max_results:
		var current: Dictionary = queue[queue_index]
		queue_index += 1
		var depth := int(current["depth"])
		if depth >= max_depth:
			continue
		var source_path := str(current["path"])
		for dependency_path in _direct_dependencies(source_path, reasons):
			if not visited.has(dependency_path) and nodes.size() >= max_results:
				_add_reason(reasons, "result_limit")
				break
			if edges.size() >= MAX_SCAN_EDGES:
				_add_reason(reasons, "edge_limit")
				break
			edges.append({"from": source_path, "to": dependency_path})
			if visited.has(dependency_path):
				continue
			visited[dependency_path] = true
			nodes.append({"path": dependency_path, "depth": depth + 1})
			queue.append({"path": dependency_path, "depth": depth + 1})
	if nodes.size() >= max_results and queue_index < queue.size():
		_add_reason(reasons, "result_limit")
	return _report(nodes, edges, reasons, {})


static func _inspect_reverse(filepath: String, max_depth: int, max_results: int) -> Dictionary:
	var scan := _scan_reverse_index(filepath)
	var reverse_index: Dictionary = scan["reverse_index"]
	var nodes: Array = []
	var edges: Array = []
	var reasons: PackedStringArray = scan["reasons"]
	var visited := {filepath: true}
	var queue: Array = [{"path": filepath, "depth": 0}]
	var queue_index := 0
	while queue_index < queue.size() and nodes.size() < mini(max_results, MAX_SCAN_NODES):
		var current: Dictionary = queue[queue_index]
		queue_index += 1
		var depth := int(current["depth"])
		if depth >= max_depth:
			continue
		var dependency_path := str(current["path"])
		var dependents: Array = reverse_index.get(dependency_path, [])
		for source_path in dependents:
			if not visited.has(source_path) and (nodes.size() >= max_results or nodes.size() >= MAX_SCAN_NODES):
				_add_reason(reasons, "result_limit" if nodes.size() >= max_results else "node_limit")
				break
			if edges.size() >= MAX_SCAN_EDGES:
				_add_reason(reasons, "edge_limit")
				break
			edges.append({"from": source_path, "to": dependency_path})
			if visited.has(source_path):
				continue
			visited[source_path] = true
			nodes.append({"path": source_path, "depth": depth + 1})
			queue.append({"path": source_path, "depth": depth + 1})
	if nodes.size() >= max_results and queue_index < queue.size():
		_add_reason(reasons, "result_limit")
	var scan_stats := {
		"files_scanned": scan["files_scanned"],
		"directories_scanned": scan["directories_scanned"],
		"graph_nodes_scanned": scan["nodes_scanned"],
		"serialized_edges_scanned": scan["edges_scanned"],
		"elapsed_ms": Time.get_ticks_msec() - int(scan["started_at_ms"])
	}
	return _report(nodes, edges, reasons, scan_stats)


static func _scan_reverse_index(filepath: String) -> Dictionary:
	var started_at_ms := Time.get_ticks_msec()
	var deadline := started_at_ms + SCAN_TIMEOUT_MS
	var reasons := PackedStringArray()
	var reverse_index := {}
	var files_scanned := 0
	var directories_scanned := 0
	var edges_scanned := 0
	var scanned_nodes := {filepath: true}
	var queue := ["res://"]
	var queue_index := 0
	var extensions := Array(ResourceLoader.get_recognized_extensions_for_type(""))
	for index in range(extensions.size()):
		extensions[index] = str(extensions[index]).to_lower()
	while queue_index < queue.size():
		if Time.get_ticks_msec() >= deadline:
			_add_reason(reasons, "time_limit")
			break
		if directories_scanned >= MAX_SCAN_DIRECTORIES:
			_add_reason(reasons, "directory_limit")
			break
		var directory_path := str(queue[queue_index])
		queue_index += 1
		var directory := DirAccess.open(directory_path)
		if directory == null:
			continue
		directories_scanned += 1
		var child_directories := Array(directory.get_directories())
		child_directories.sort()
		for child_name in child_directories:
			if child_name == ".godot" or directory.is_link(child_name):
				continue
			var child_path := directory_path.path_join(child_name)
			if _is_protected_path(child_path):
				continue
			queue.append(child_path)
		var files := Array(directory.get_files())
		files.sort()
		for file_name in files:
			if Time.get_ticks_msec() >= deadline:
				_add_reason(reasons, "time_limit")
				break
			if files_scanned >= MAX_SCAN_FILES:
				_add_reason(reasons, "file_limit")
				break
			if directory.is_link(file_name):
				continue
			files_scanned += 1
			if str(file_name).get_extension().to_lower() not in extensions:
				continue
			var source_path := _canonical_res_path(directory_path.path_join(file_name))
			if source_path.is_empty() or _is_protected_path(source_path):
				continue
			var dependencies := _direct_dependencies(source_path, reasons)
			for dependency_path in dependencies:
				if edges_scanned >= MAX_SCAN_EDGES:
					_add_reason(reasons, "edge_scan_limit")
					break
				var new_node_count := int(not scanned_nodes.has(source_path)) + int(not scanned_nodes.has(dependency_path))
				if scanned_nodes.size() + new_node_count > MAX_SCAN_NODES:
					_add_reason(reasons, "node_scan_limit")
					break
				scanned_nodes[source_path] = true
				scanned_nodes[dependency_path] = true
				edges_scanned += 1
				var dependents: Array = reverse_index.get(dependency_path, [])
				dependents.append(source_path)
				reverse_index[dependency_path] = dependents
			if reasons.has("edge_scan_limit") or reasons.has("node_scan_limit"):
				break
		if reasons.has("time_limit") or reasons.has("file_limit") or reasons.has("edge_scan_limit") or reasons.has("node_scan_limit"):
			break
	for dependency_path in reverse_index:
		var dependents: Array = reverse_index[dependency_path]
		dependents.sort()
		reverse_index[dependency_path] = dependents
	return {
		"reverse_index": reverse_index,
		"reasons": reasons,
		"files_scanned": files_scanned,
		"directories_scanned": directories_scanned,
		"nodes_scanned": scanned_nodes.size(),
		"edges_scanned": edges_scanned,
		"started_at_ms": started_at_ms
	}


static func _direct_dependencies(filepath: String, reasons: PackedStringArray) -> Array:
	var paths: Array = []
	for dependency in ResourceLoader.get_dependencies(filepath):
		var dependency_path := _normalize_dependency_descriptor(str(dependency))
		if dependency_path.is_empty() or not _validate_project_file(dependency_path).is_empty():
			_add_reason(reasons, "unsafe_or_unresolved_dependency_omitted")
			continue
		if dependency_path not in paths:
			paths.append(dependency_path)
	paths.sort()
	return paths


static func _normalize_dependency_descriptor(descriptor: String) -> String:
	var fallback := ""
	for raw_part in descriptor.split("::", false):
		var part := str(raw_part)
		if part.begins_with("uid://"):
			var uid := ResourceUID.text_to_id(part)
			if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
				var uid_path := _canonical_res_path(ResourceUID.get_id_path(uid))
				if not uid_path.is_empty():
					return uid_path
		elif part.begins_with("res://") and fallback.is_empty():
			fallback = _canonical_res_path(part)
	return fallback


static func _validate_project_file(filepath: String) -> String:
	if filepath.is_empty() or not filepath.begins_with("res://") or _canonical_res_path(filepath) != filepath:
		return "filepath must resolve to a canonical path inside res://."
	if _is_protected_path(filepath):
		return "Orca cannot inspect its own res://addons/orca/ directory."
	var relative := filepath.trim_prefix("res://")
	var current := ProjectSettings.globalize_path("res://").simplify_path()
	for component in relative.split("/", false):
		var parent := DirAccess.open(current)
		if parent != null and parent.is_link(component):
			return "Dependency paths containing symbolic links are blocked."
		current = current.path_join(component)
	if not FileAccess.file_exists(filepath):
		return "Resource file does not exist: " + filepath
	return ""


static func _canonical_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return ""
	var canonical := ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())
	return canonical if canonical == "res://" or canonical.begins_with("res://") else ""


static func _is_protected_path(path: String) -> bool:
	var relative := path.trim_prefix("res://").trim_suffix("/")
	return relative == "addons/orca" or relative.begins_with("addons/orca/")


static func _report(nodes: Array, edges: Array, reasons: PackedStringArray, scan: Dictionary) -> Dictionary:
	return {
		"nodes": nodes,
		"edges": edges,
		"returned_node_count": nodes.size(),
		"returned_edge_count": edges.size(),
		"scan": scan,
		"truncation": {"truncated": not reasons.is_empty(), "reasons": Array(reasons)}
	}


static func _fit_and_serialize(report: Dictionary) -> String:
	var content := JSON.stringify(report, "  ")
	while content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		var reduced := false
		var edges: Array = report.get("edges", [])
		var nodes: Array = report.get("nodes", [])
		if not edges.is_empty():
			edges.pop_back()
			report["returned_edge_count"] = edges.size()
			reduced = true
		elif not nodes.is_empty():
			nodes.pop_back()
			report["returned_node_count"] = nodes.size()
			reduced = true
		_add_reason_to_report(report, "output_limit")
		content = JSON.stringify(report, "  ")
		if not reduced:
			break
	return content


static func _add_reason(reasons: PackedStringArray, reason: String) -> void:
	if not reasons.has(reason):
		reasons.append(reason)


static func _add_reason_to_report(report: Dictionary, reason: String) -> void:
	var truncation: Dictionary = report.get("truncation", {})
	var reasons: Array = truncation.get("reasons", [])
	if reason not in reasons:
		reasons.append(reason)
	truncation["truncated"] = true
	truncation["reasons"] = reasons
	report["truncation"] = truncation


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error": message}
