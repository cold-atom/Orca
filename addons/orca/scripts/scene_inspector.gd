@tool
extends RefCounted

const MAX_NODES := 120
const MAX_PROPERTIES_PER_NODE := 24
const MAX_TOTAL_PROPERTIES := 500
const MAX_GROUPS_PER_NODE := 32
const MAX_CONNECTIONS := 100
const MAX_CONNECTION_BINDS := 16
const MAX_COLLECTION_ITEMS := 16
const MAX_VARIANT_DEPTH := 4
const MAX_STRING_CHARS := 256
const MAX_OUTPUT_BYTES := 128 * 1024


static func inspect(filepath: String, include_properties: bool, requested_nodes: int, requested_properties: int) -> Dictionary:
	var packed = ResourceLoader.load(filepath, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not packed is PackedScene:
		return {"success": false, "error": "The resource could not be loaded as a PackedScene."}
	var state: SceneState = packed.get_state()
	if state == null:
		return {"success": false, "error": "The scene did not provide readable SceneState data."}
	var node_limit := clampi(requested_nodes, 1, MAX_NODES)
	var property_limit := clampi(requested_properties, 0, MAX_PROPERTIES_PER_NODE)
	var reasons := PackedStringArray()
	var total_nodes := state.get_node_count()
	var total_properties := 0
	var returned_properties := 0
	var nodes: Array[Dictionary] = []
	for node_index in range(mini(total_nodes, node_limit)):
		var property_count := state.get_node_property_count(node_index)
		total_properties += property_count
		var groups: PackedStringArray = state.get_node_groups(node_index)
		var group_values: Array = []
		for group_index in range(mini(groups.size(), MAX_GROUPS_PER_NODE)):
			group_values.append(str(groups[group_index]))
		if groups.size() > MAX_GROUPS_PER_NODE:
			_add_reason(reasons, "group_limit")
		var node := {
			"path": str(state.get_node_path(node_index)),
			"parent_path": str(state.get_node_path(node_index, true)),
			"name": str(state.get_node_name(node_index)),
			"type": str(state.get_node_type(node_index)),
			"owner_path": str(state.get_node_owner_path(node_index)),
			"sibling_index": state.get_node_index(node_index),
			"groups": group_values,
			"instance_scene": "",
			"instance_placeholder": "",
			"serialized_property_count": property_count,
			"returned_property_count": 0
		}
		var instance: PackedScene = state.get_node_instance(node_index)
		if instance != null:
			node["instance_scene"] = instance.resource_path
		if state.is_node_instance_placeholder(node_index):
			node["instance_placeholder"] = state.get_node_instance_placeholder(node_index)
		if include_properties:
			var properties: Array[Dictionary] = []
			var available_total := MAX_TOTAL_PROPERTIES - returned_properties
			var returned_for_node := mini(property_count, mini(property_limit, maxi(0, available_total)))
			for property_index in range(returned_for_node):
				properties.append({
					"name": str(state.get_node_property_name(node_index, property_index)),
					"value": _summarize_variant(state.get_node_property_value(node_index, property_index), 0)
				})
			returned_properties += returned_for_node
			node["properties"] = properties
			node["returned_property_count"] = properties.size()
			if returned_for_node < property_count:
				_add_reason(reasons, "property_limit")
		nodes.append(node)
	if total_nodes > nodes.size():
		_add_reason(reasons, "node_limit")

	var total_connections := state.get_connection_count()
	var connections: Array[Dictionary] = []
	for connection_index in range(mini(total_connections, MAX_CONNECTIONS)):
		var raw_binds: Array = state.get_connection_binds(connection_index)
		var binds: Array = []
		for bind_index in range(mini(raw_binds.size(), MAX_CONNECTION_BINDS)):
			binds.append(_summarize_variant(raw_binds[bind_index], 0))
		if raw_binds.size() > MAX_CONNECTION_BINDS:
			_add_reason(reasons, "connection_bind_limit")
		connections.append({
			"source": str(state.get_connection_source(connection_index)),
			"signal": str(state.get_connection_signal(connection_index)),
			"target": str(state.get_connection_target(connection_index)),
			"method": str(state.get_connection_method(connection_index)),
			"flags": state.get_connection_flags(connection_index),
			"unbinds": state.get_connection_unbinds(connection_index),
			"binds": binds
		})
	if total_connections > connections.size():
		_add_reason(reasons, "connection_limit")

	var base_scene := ""
	var base_state: SceneState = state.get_base_scene_state()
	if base_state != null:
		base_scene = base_state.get_path()
	var report := {
		"scene_path": filepath,
		"source": "saved_scene_state",
		"note": "Read from PackedScene/SceneState without instantiating nodes. Properties are serialized exported or overridden values, not all runtime defaults.",
		"base_scene": base_scene,
		"include_properties": include_properties,
		"scene_node_count": total_nodes,
		"returned_node_count": nodes.size(),
		"inspected_serialized_property_count": total_properties,
		"returned_property_count": returned_properties,
		"scene_connection_count": total_connections,
		"returned_connection_count": connections.size(),
		"nodes": nodes,
		"connections": connections,
		"truncation": {"truncated": not reasons.is_empty(), "reasons": Array(reasons)}
	}
	var content := _fit_and_serialize(report)
	return {"success": true, "content": content, "report": report}


static func _fit_and_serialize(report: Dictionary) -> String:
	var content := JSON.stringify(report, "  ")
	while content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		var reduced := false
		var nodes: Array = report.get("nodes", [])
		for node_index in range(nodes.size() - 1, -1, -1):
			var node: Dictionary = nodes[node_index]
			if not node.get("properties", []).is_empty():
				report["returned_property_count"] = maxi(0, int(report.get("returned_property_count", 0)) - node.get("properties", []).size())
				node["properties"] = []
				node["returned_property_count"] = 0
				nodes[node_index] = node
				reduced = true
				break
		if not reduced and not report.get("connections", []).is_empty():
			report["connections"].pop_back()
			report["returned_connection_count"] = report["connections"].size()
			reduced = true
		if not reduced and nodes.size() > 1:
			var removed: Dictionary = nodes.pop_back()
			report["returned_property_count"] = maxi(0, int(report.get("returned_property_count", 0)) - int(removed.get("returned_property_count", 0)))
			report["returned_node_count"] = nodes.size()
			reduced = true
		_add_reason_to_report(report, "output_limit")
		content = JSON.stringify(report, "  ")
		if not reduced:
			break
	return content


static func _summarize_variant(value, depth: int):
	var value_type := typeof(value)
	match value_type:
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else {"type": "float", "value": str(value)}
		TYPE_STRING:
			return _bounded_string(value)
		TYPE_STRING_NAME:
			return {"type": "StringName", "value": _bounded_string(str(value))}
		TYPE_NODE_PATH:
			return {"type": "NodePath", "value": _bounded_string(str(value))}
		TYPE_ARRAY:
			return _summarize_array(value, "Array", depth)
		TYPE_DICTIONARY:
			return _summarize_dictionary(value, depth)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return _summarize_array(Array(value), type_string(value_type), depth)
		TYPE_OBJECT:
			if value is Resource:
				return {"type": "Resource", "class": value.get_class(), "path": value.resource_path, "name": value.resource_name}
			return {"type": "Object", "class": value.get_class() if value != null else ""}
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return {"type": type_string(value_type)}
		_:
			return {"type": type_string(value_type), "value": _bounded_string(str(value))}


static func _summarize_array(value: Array, type_name: String, depth: int) -> Dictionary:
	if depth >= MAX_VARIANT_DEPTH:
		return {"type": type_name, "size": value.size(), "items": [], "truncated": true, "reason": "depth_limit"}
	var items: Array = []
	for index in range(mini(value.size(), MAX_COLLECTION_ITEMS)):
		items.append(_summarize_variant(value[index], depth + 1))
	return {"type": type_name, "size": value.size(), "items": items, "truncated": items.size() < value.size()}


static func _summarize_dictionary(value: Dictionary, depth: int) -> Dictionary:
	if depth >= MAX_VARIANT_DEPTH:
		return {"type": "Dictionary", "size": value.size(), "entries": [], "truncated": true, "reason": "depth_limit"}
	var entries: Array = []
	var keys := value.keys()
	for index in range(mini(keys.size(), MAX_COLLECTION_ITEMS)):
		entries.append({"key": _summarize_variant(keys[index], depth + 1), "value": _summarize_variant(value[keys[index]], depth + 1)})
	return {"type": "Dictionary", "size": value.size(), "entries": entries, "truncated": entries.size() < value.size()}


static func _bounded_string(value: String):
	if value.length() <= MAX_STRING_CHARS:
		return value
	return {"type": "String", "value": value.left(MAX_STRING_CHARS), "truncated": true, "original_characters": value.length()}


static func _add_reason(reasons: PackedStringArray, reason: String) -> void:
	if reason not in reasons:
		reasons.append(reason)


static func _add_reason_to_report(report: Dictionary, reason: String) -> void:
	var truncation: Dictionary = report.get("truncation", {})
	var reasons: Array = truncation.get("reasons", [])
	if reason not in reasons:
		reasons.append(reason)
	truncation["truncated"] = true
	truncation["reasons"] = reasons
	report["truncation"] = truncation
