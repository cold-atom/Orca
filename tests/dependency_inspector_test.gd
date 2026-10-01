extends SceneTree

const DependencyInspector = preload("res://addons/orca/scripts/dependency_inspector.gd")
const ROOT := "res://tests/fixtures/dependency_inspector_root.tres"
const BRANCH_A := "res://tests/fixtures/dependency_inspector_branch_a.tres"
const BRANCH_B := "res://tests/fixtures/dependency_inspector_branch_b.tres"
const LEAF := "res://tests/fixtures/dependency_inspector_leaf.tres"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_forward_bfs()
	_test_reverse_bfs()
	_test_bounds_and_serialization()
	_test_descriptor_normalization()
	_test_rejections()
	_finish()


func _test_forward_bfs() -> void:
	var result: Dictionary = DependencyInspector.inspect(_args(ROOT, "forward", 3, 100))
	_expect(result.get("success", false), "forward dependency inspection should succeed")
	var report: Dictionary = result.get("report", {})
	_expect(_paths(report.get("nodes", [])) == [BRANCH_A, BRANCH_B, LEAF], "forward traversal should be deterministic breadth-first order")
	_expect(_depths(report.get("nodes", [])) == [1, 1, 2], "forward traversal should report shortest BFS depths")
	_expect(report.get("source") == "resource_loader_serialized_dependencies", "the report should identify serialized ResourceLoader semantics")
	_expect(str(report.get("note", "")).contains("dynamic load()"), "the report should state what serialized dependency discovery omits")
	_expect(_has_edge(report.get("edges", []), ROOT, BRANCH_A), "the root-to-branch serialized edge should be retained")
	_expect(_has_edge(report.get("edges", []), BRANCH_B, LEAF), "transitive serialized edges should be retained")


func _test_reverse_bfs() -> void:
	var result: Dictionary = DependencyInspector.inspect(_args(LEAF, "reverse", 3, 100))
	_expect(result.get("success", false), "reverse dependency inspection should succeed")
	var report: Dictionary = result.get("report", {})
	_expect(_paths(report.get("nodes", [])) == [BRANCH_A, BRANCH_B, ROOT], "reverse traversal should return deterministic direct then transitive dependents")
	_expect(_depths(report.get("nodes", [])) == [1, 1, 2], "reverse traversal should report shortest BFS depths")
	_expect(_has_edge(report.get("edges", []), BRANCH_A, LEAF), "reverse results should preserve the real serialized edge direction")
	var scan: Dictionary = report.get("scan", {})
	_expect(int(scan.get("files_scanned", 0)) <= DependencyInspector.MAX_SCAN_FILES, "reverse file scans must be hard bounded")
	_expect(int(scan.get("directories_scanned", 0)) <= DependencyInspector.MAX_SCAN_DIRECTORIES, "reverse directory scans must be hard bounded")
	_expect(int(scan.get("graph_nodes_scanned", 0)) <= DependencyInspector.MAX_SCAN_NODES, "reverse graph indexing must be hard bounded")
	_expect(int(scan.get("serialized_edges_scanned", 0)) <= DependencyInspector.MAX_SCAN_EDGES, "reverse edge scans must be hard bounded")
	_expect(int(scan.get("elapsed_ms", 0)) >= 0, "reverse reports should expose scan timing")


func _test_bounds_and_serialization() -> void:
	var defaults: Dictionary = DependencyInspector.inspect({"filepath": ROOT, "direction": "forward"})
	_expect(defaults.get("success", false), "dependency limits should be optional")
	_expect(defaults.get("report", {}).get("max_depth") == 1 and defaults.get("report", {}).get("max_results") == 100, "optional dependency limits should default to 1 and 100")
	var shallow: Dictionary = DependencyInspector.inspect(_args(ROOT, "forward", 0, 999))
	var report: Dictionary = shallow.get("report", {})
	_expect(report.get("max_depth") == 1 and report.get("max_results") == 100, "requested limits should clamp to documented bounds")
	_expect(_paths(report.get("nodes", [])) == [BRANCH_A, BRANCH_B], "the clamped depth should prevent transitive traversal")
	var limited: Dictionary = DependencyInspector.inspect(_args(ROOT, "forward", 3, 1))
	var limited_report: Dictionary = limited.get("report", {})
	_expect(limited_report.get("returned_node_count") == 1, "max_results should bound returned dependency nodes")
	_expect(limited_report.get("truncation", {}).get("reasons", []).has("result_limit"), "result truncation should expose its reason")
	var content := str(limited.get("content", ""))
	_expect(content.to_utf8_buffer().size() <= DependencyInspector.MAX_OUTPUT_BYTES, "dependency output must remain within 96 KiB")
	_expect(JSON.parse_string(content) is Dictionary, "bounded dependency output should remain whole valid JSON")


func _test_descriptor_normalization() -> void:
	var fallback := DependencyInspector._normalize_dependency_descriptor("uid://not-a-valid-id::Resource::" + LEAF)
	_expect(fallback == LEAF, "an unresolved UID descriptor should use its res:// fallback")
	var uid := ResourceLoader.get_resource_uid(LEAF)
	_expect(uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid), "the UID fixture should be registered")
	if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
		var normalized := DependencyInspector._normalize_dependency_descriptor(ResourceUID.id_to_text(uid) + "::Resource::" + BRANCH_A)
		_expect(normalized == LEAF, "a resolvable UID should take precedence over a descriptor fallback")


func _test_rejections() -> void:
	for arguments in [
		{"filepath": ROOT, "max_depth": 1},
		{"filepath": ROOT, "direction": "sideways", "max_depth": 1, "max_results": 10},
		{"filepath": 42, "direction": "forward", "max_depth": 1, "max_results": 10},
		{"filepath": ROOT, "direction": "forward", "max_depth": 1.0, "max_results": 10},
		{"filepath": ROOT, "direction": "forward", "max_depth": 1, "max_results": 10, "extra": true},
		{"filepath": "/tmp/outside.tres", "direction": "forward", "max_depth": 1, "max_results": 10},
		{"filepath": "res://addons/orca/plugin.cfg", "direction": "forward", "max_depth": 1, "max_results": 10},
		{"filepath": "res://tests/fixtures/missing.tres", "direction": "forward", "max_depth": 1, "max_results": 10}
	]:
		_expect(not DependencyInspector.inspect(arguments).get("success", true), "invalid dependency inspector arguments or paths should fail")


func _args(filepath: String, direction: String, max_depth: int, max_results: int) -> Dictionary:
	return {"filepath": filepath, "direction": direction, "max_depth": max_depth, "max_results": max_results}


func _paths(nodes: Array) -> Array:
	var result := []
	for node in nodes:
		result.append(str(node.get("path", "")))
	return result


func _depths(nodes: Array) -> Array:
	var result := []
	for node in nodes:
		result.append(int(node.get("depth", -1)))
	return result


func _has_edge(edges: Array, source: String, dependency: String) -> bool:
	for edge in edges:
		if edge.get("from") == source and edge.get("to") == dependency:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("dependency_inspector_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("dependency_inspector_test: ", failure)
	quit(1)
