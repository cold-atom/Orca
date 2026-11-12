@tool
extends RefCounted

## Bounded text-only provenance for native Node2D transforms. Never load a scene,
## script, texture or resource. Unrelated property expressions remain opaque text.
const Boundary = preload("res://addons/orca/scripts/dependency_inspector.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const MAX_FILE_BYTES := 2 * 1024 * 1024
const MAX_TOTAL_BYTES := 4 * 1024 * 1024
const MAX_FILES := 16
const MAX_SECTIONS := 4096
const MAX_PROPERTIES := 32768
const MAX_DEPTH := 8
const TIMEOUT_MS := 250
const PROPERTIES := ["position", "rotation", "scale", "skew"]


static func inspect(path: String, node_path: String, content: String = "") -> Dictionary:
	var state := {"deadline": Time.get_ticks_msec() + TIMEOUT_MS, "bytes": 0, "files": {}, "hashes": {}}
	var source := _source(path, state, content)
	if not source.get("success", false): return source
	var result := _resolve(source, node_path, state, [], 0)
	if not result.get("success", false): return result
	result["hashes"] = state["hashes"].duplicate()
	result["source"] = source
	return result


static func candidate(source: Dictionary, node_path: String, property: String, value) -> Dictionary:
	if not source.get("nodes", {}).has(node_path): return _error("The target must have a local node/instance record in the current scene. Internal instance nodes need a separate editable-instance workflow.")
	var record: Dictionary = source["nodes"][node_path]
	var lines: PackedStringArray = source["lines"].duplicate()
	var text := "Vector2(%s, %s)" % [str(value.x), str(value.y)] if value is Vector2 else str(value)
	if record["property_lines"].has(property):
		lines[record["property_lines"][property]] = property + " = " + text
	else:
		lines.insert(int(record["line"]) + 1, property + " = " + text)
	var content := "\n".join(lines)
	if content.to_utf8_buffer().size() > MAX_FILE_BYTES: return _error("The proposed scene exceeds the 2 MiB bound.")
	return {"success": true, "content": content}


static func _source(path: String, state: Dictionary, supplied: String = "") -> Dictionary:
	if Time.get_ticks_msec() >= state["deadline"]: return _error("Saved transform inspection reached its time limit.")
	var error := Boundary._validate_project_file(path)
	if not error.is_empty(): return _error(error)
	if supplied.is_empty() and EditorContext.has_unsaved_file(path): return _error("The transform source has unsaved changes. Save it before preparing an editor proposal: " + path)
	if state["files"].has(path): return state["files"][path]
	if state["files"].size() >= MAX_FILES: return _error("Transform provenance exceeds the 16-file bound.")
	var content := supplied
	if content.is_empty():
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null: return _error("The saved transform source is unavailable: " + path)
		var size := file.get_length()
		if size > MAX_FILE_BYTES or state["bytes"] + size > MAX_TOTAL_BYTES: return _error("Transform source exceeds its 2 MiB/file or 4 MiB total bound.")
		var bytes := file.get_buffer(size)
		file.close()
		content = bytes.get_string_from_utf8()
		if bytes.size() != size or bytes.has(0) or content.to_utf8_buffer() != bytes: return _error("Transform source must be bounded valid UTF-8 text.")
	if content.to_utf8_buffer().size() > MAX_FILE_BYTES or state["bytes"] + content.to_utf8_buffer().size() > MAX_TOTAL_BYTES: return _error("Transform source exceeds its byte bound.")
	state["bytes"] += content.to_utf8_buffer().size()
	var parsed := _parse(content, state)
	if not parsed.get("success", false): return parsed
	parsed["path"] = path
	state["files"][path] = parsed
	state["hashes"][path] = content.sha256_text()
	return parsed


static func _parse(content: String, state: Dictionary) -> Dictionary:
	var lines := content.split("\n", true)
	var header := RegEx.new()
	header.compile("^\\[([a-z_]+)(?:\\s+(.*))?\\]$")
	var assignment := RegEx.new()
	assignment.compile('^((?:"(?:[^"\\\\]|\\\\.)*")|(?:[^\\s=]+))\\s*=\\s*(.*)$')
	var nodes := {}
	var external := {}
	var records: Array = []
	var sections := 0
	var properties := 0
	var current := {}
	var pending_property := ""
	var delimiters: Array = []
	var tokens := RegEx.new()
	tokens.compile('"(?:[^"\\\\]|\\\\.)*"|[()\\[\\]{}"]')
	var token_count := 0
	var first := true
	for index in lines.size():
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Saved transform parsing reached its time limit.")
		var line := lines[index].strip_edges()
		if line.is_empty() or line.begins_with(";") or line.begins_with("#"): continue
		var matched := header.search(line) if line.begins_with("[") and delimiters.is_empty() else null
		if matched != null:
			sections += 1
			if sections > MAX_SECTIONS or line.length() > 8192: return _error("Scene section/header scan exceeds its bound.")
			var kind := matched.get_string(1)
			if kind not in ["gd_scene", "ext_resource", "sub_resource", "node", "connection", "editable"]: return _error("Unsupported saved scene section.")
			if first and kind != "gd_scene": return _error("A transform source must start with a gd_scene header.")
			first = false
			var attributes := _attributes(matched.get_string(2))
			if not attributes.get("success", false): return attributes
			var fields: Dictionary = attributes["fields"]
			current = {"kind": kind, "fields": fields, "properties": {}, "property_lines": {}, "line": index}
			records.append(current)
			pending_property = ""
			if kind == "ext_resource":
				for field in ["id", "type", "path"]:
					if typeof(fields.get(field)) != TYPE_STRING or fields[field].is_empty() or fields[field].length() > 512: return _error("An external reference has invalid identity fields.")
				if external.has(fields["id"]): return _error("Duplicate external resource identity.")
				var boundary := Boundary._validate_project_file(fields["path"])
				if not boundary.is_empty(): return _error(boundary)
				if fields.has("uid"):
					var id := ResourceUID.text_to_id(fields["uid"])
					if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id) and ResourceUID.get_id_path(id) != fields["path"]: return _error("A saved resource UID resolves outside its declared project path.")
				external[fields["id"]] = fields
			if kind == "node":
				if typeof(fields.get("name")) != TYPE_STRING or fields["name"].is_empty() or fields["name"].length() > 128 or fields["name"].contains("/"): return _error("A saved node has invalid identity fields.")
				var parent := str(fields.get("parent", ""))
				if not parent.is_empty() and not _node_path(parent): return _error("A saved node has an unsupported parent path.")
				var path: String = "." if parent.is_empty() else "./" + fields["name"] if parent == "." else "./" + parent.trim_prefix("./") + "/" + fields["name"]
				if nodes.has(path): return _error("Duplicate saved node path.")
				nodes[path] = current
			continue
		var property_match := assignment.search(line)
		if property_match != null:
			properties += 1
			if properties > MAX_PROPERTIES: return _error("Saved property scan exceeds its bound.")
			var name := property_match.get_string(1)
			if name.begins_with('"'):
				var decoded := JSON.new()
				if decoded.parse(name) != OK or not decoded.data is String: return _error("Invalid quoted property identity.")
				name = decoded.data
			if current.is_empty() or current["properties"].has(name): return _error("Missing section or duplicate saved property.")
			pending_property = name
			current["properties"][name] = property_match.get_string(2)
			current["property_lines"][name] = index
		elif not pending_property.is_empty():
			current["properties"][pending_property] += "\n" + line
		else: return _error("Unsupported saved scene syntax.")
		var raw := property_match.get_string(2) if property_match != null else line
		var cursor := 0
		var token := tokens.search(raw, cursor)
		while token != null:
			token_count += 1
			if token_count > 65536 or Time.get_ticks_msec() >= state["deadline"]: return _error("Saved expression structure exceeds its work/time bound.")
			var value := token.get_string()
			if value == '"': return _error("Multiline or unterminated literal strings are unsupported for transform provenance.")
			if value in ["(", "[", "{"]:
				delimiters.append(value)
				if delimiters.size() > 16: return _error("Saved expression nesting exceeds its bound.")
			elif value in [")", "]", "}"]:
				var expected: String = {"(": ")", "[": "]", "{": "}"}.get(delimiters.back(), "") if not delimiters.is_empty() else ""
				if expected != value: return _error("Saved expression delimiters are malformed.")
				delimiters.pop_back()
			cursor = token.get_end()
			token = tokens.search(raw, cursor)
	if not delimiters.is_empty(): return _error("Saved expression delimiters are incomplete.")
	if first or not nodes.has("."): return _error("The saved scene has no root node.")
	return {"success": true, "nodes": nodes, "external": external, "lines": lines, "records": records}


static func signature(source: Dictionary, node_path: String, property: String) -> String:
	# Text identity for everything outside the one approved override. Resource
	# expressions are never evaluated. Native saves may add UID/load-count metadata.
	var records: Array = []
	for record in source["records"]:
		var fields: Dictionary = record["fields"].duplicate()
		if record["kind"] in ["gd_scene", "ext_resource"]: fields.erase("uid")
		if record["kind"] == "gd_scene": fields.erase("load_steps")
		var properties: Dictionary = record["properties"].duplicate()
		if record == source["nodes"].get(node_path): properties.erase(property)
		var sorted_fields: Array = []
		var keys: Array = fields.keys()
		keys.sort()
		for key in keys: sorted_fields.append([key, fields[key]])
		var sorted_properties: Array = []
		keys = properties.keys()
		keys.sort()
		for key in keys: sorted_properties.append([key, str(properties[key]).strip_edges()])
		records.append([record["kind"], sorted_fields, sorted_properties])
	return JSON.stringify(records).sha256_text()


static func _attributes(text: String) -> Dictionary:
	var field := RegEx.new()
	field.compile("^([a-z_][a-z_0-9]*)\\s*=\\s*")
	var fields := {}
	var remaining := text.strip_edges()
	while not remaining.is_empty():
		if fields.size() >= 32: return _error("Scene header attribute count exceeds its bound.")
		var matched := field.search(remaining)
		if matched == null: return _error("Malformed saved scene header attributes.")
		var name := matched.get_string(1)
		if fields.has(name): return _error("Duplicate saved scene header attribute.")
		remaining = remaining.substr(matched.get_end())
		var cursor := 0
		var quoted := false
		var depth := 0
		while cursor < remaining.length():
			var character := remaining.substr(cursor, 1)
			if quoted:
				if character == "\\": cursor += 2; continue
				if character == '"': quoted = false
			elif character == '"': quoted = true
			elif character in ["(", "[", "{"]: depth += 1
			elif character in [")", "]", "}"]: depth -= 1
			elif character in [" ", "\t"] and depth == 0: break
			if depth < 0 or depth > 16: return _error("Unsupported scene header nesting.")
			cursor += 1
		if quoted or depth != 0 or cursor == 0: return _error("Unterminated scene header value.")
		var raw := remaining.left(cursor)
		if raw.begins_with('"'):
			var json := JSON.new()
			if json.parse(raw) != OK or not json.data is String: return _error("Malformed scene header string.")
			fields[name] = json.data
		else:
			if name in ["name", "type", "parent", "owner", "id", "path", "uid"]: return _error("Saved identity attributes must be quoted strings.")
			fields[name] = raw
		remaining = remaining.substr(cursor).strip_edges()
	return {"success": true, "fields": fields}


static func _resolve(source: Dictionary, path: String, state: Dictionary, visited: Array, depth: int) -> Dictionary:
	if depth > MAX_DEPTH or Time.get_ticks_msec() >= state["deadline"]: return _error("Instance transform provenance exceeds its depth/time bound.")
	var identity := str(source["path"]) + ":" + path
	if identity in visited: return _error("Cyclic scene instance provenance.")
	visited = visited.duplicate()
	visited.append(identity)
	var record: Dictionary = source["nodes"].get(path, {})
	var fields: Dictionary = record.get("fields", {})
	if fields.has("type") and fields.has("instance"): return _error("A saved target cannot declare both a native type and a scene instance.")
	if fields.has("instance_placeholder"): return _error("Scene instance placeholders are unsupported for transform editing.")
	var result := {}
	if fields.has("type"):
		var type_name := str(fields["type"])
		if not ClassDB.class_exists(type_name) or ClassDB.class_get_api_type(type_name) != ClassDB.API_CORE or not ClassDB.is_parent_class(type_name, "Node2D"): return _error("The saved target is not a core-native Node2D.")
		result = {"success": true, "node_type": type_name, "values": {"position": Vector2.ZERO, "rotation": 0.0, "scale": Vector2.ONE, "skew": 0.0}, "script_path": "", "origin_scene": source["path"], "origin_node": path}
	else:
		var ancestor := path
		var instance := {}
		while true:
			var node: Dictionary = source["nodes"].get(ancestor, {})
			if node.get("fields", {}).has("instance"):
				instance = node
				break
			if ancestor == ".": break
			ancestor = ancestor.get_base_dir()
			if ancestor == "" or ancestor == "./": ancestor = "."
		if instance.is_empty(): return _error("The target has no resolvable local or instance provenance.")
		var dependency := _external(instance["fields"]["instance"], source)
		if not dependency.get("success", false): return dependency
		if dependency["reference"]["type"] != "PackedScene" or str(dependency["reference"]["path"]).get_extension() != "tscn": return _error("Instance provenance requires a saved text PackedScene.")
		var child := _source(dependency["reference"]["path"], state)
		if not child.get("success", false): return child
		var relative := "." if path == ancestor else path if ancestor == "." else "./" + path.trim_prefix(ancestor + "/")
		result = _resolve(child, relative, state, visited, depth + 1)
		if not result.get("success", false): return result
	var stored: Dictionary = record.get("properties", {})
	for alias in ["transform", "global_transform", "global_position", "global_rotation", "global_scale"]:
		if stored.has(alias): return _error("The target uses a serialized transform alias; canonical position/rotation/scale/skew are required.")
	for name in PROPERTIES:
		if stored.has(name):
			var decoded := _value(stored[name], name in ["position", "scale"])
			if not decoded.get("success", false): return decoded
			result["values"][name] = decoded["value"]
	if stored.has("script"):
		if str(stored["script"]).strip_edges() == "null": result["script_path"] = ""
		else:
			var script := _external(stored["script"], source)
			if not script.get("success", false): return script
			if script["reference"]["type"] != "Script" or str(script["reference"]["path"]).get_extension() != "gd": return _error("Native transform editing currently supports GDScript attachments only.")
			result["script_path"] = script["reference"]["path"]
	return result


static func _external(expression: String, source: Dictionary) -> Dictionary:
	var reference := RegEx.new()
	reference.compile('^ExtResource\\("([^"\\\\]{1,128})"\\)$')
	var matched := reference.search(expression.strip_edges())
	if matched == null or not source["external"].has(matched.get_string(1)): return _error("The saved instance/script reference is unresolved.")
	var entry: Dictionary = source["external"][matched.get_string(1)]
	if entry.has("uid"):
		var id := ResourceUID.text_to_id(entry["uid"])
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id) and ResourceUID.get_id_path(id) != entry["path"]: return _error("The saved reference UID resolves to a different project path.")
	return {"success": true, "reference": entry}


static func _value(raw: String, vector: bool) -> Dictionary:
	if raw.length() > 256 or raw.contains("\n"): return _error("A native transform requires one bounded canonical numeric line.")
	var number := "[-+]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?"
	var expression := RegEx.new()
	expression.compile("^\\s*Vector2\\(\\s*(" + number + ")\\s*,\\s*(" + number + ")\\s*\\)\\s*$" if vector else "^\\s*(" + number + ")\\s*$")
	var matched := expression.search(raw)
	if matched == null: return _error("The saved transform is not an exact native numeric literal.")
	var value = Vector2(float(matched.get_string(1)), float(matched.get_string(2))) if vector else PackedFloat32Array([float(matched.get_string(1))])[0]
	if (vector and not value.is_finite()) or (not vector and not is_finite(value)): return _error("The saved transform contains non-finite components.")
	return {"success": true, "value": value}


static func _node_path(path: String) -> bool:
	if path == ".": return true
	if path.length() > 512 or path.begins_with("/") or path.contains(":") or path.contains("%") or path.contains("\\"): return false
	for part in path.trim_prefix("./").split("/", true):
		if part.is_empty() or part in [".", ".."]: return false
	return true


static func _error(message: String) -> Dictionary: return {"success": false, "error": message}
