@tool
extends RefCounted

## Only self-contained, bounded GLB is accepted. No external buffers, images,
## scripts, native loader extensions, or exporter-selected project paths.
const MAX_BYTES := 16 * 1024 * 1024
const MAX_JSON := 1024 * 1024
const LIGHTS := "KHR_lights_punctual"

static func inspect(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20 or bytes.size() > MAX_BYTES or bytes.decode_u32(0) != 0x46546c67 or bytes.decode_u32(4) != 2 or bytes.decode_u32(8) != bytes.size():
		return _error("Invalid or oversized GLB header.")
	var json_length := bytes.decode_u32(12)
	if json_length == 0 or json_length > MAX_JSON or json_length % 4 != 0 or 20 + json_length > bytes.size() or bytes.decode_u32(16) != 0x4e4f534a:
		return _error("Invalid GLB JSON chunk.")
	var source := bytes.slice(20, 20 + json_length)
	if not preload("res://addons/orca/scripts/mcp_stdio_client.gd")._valid_utf8(source): return _error("Invalid GLB UTF-8.")
	if not preload("res://addons/orca/scripts/mcp_stdio_client.gd")._bounded_json(source.get_string_from_utf8()): return _error("GLB JSON nesting exceeds its budget.")
	var parser := JSON.new()
	if parser.parse(source.get_string_from_utf8()) != OK or typeof(parser.data) != TYPE_DICTIONARY: return _error("Invalid GLB document.")
	var data: Dictionary = parser.data
	if typeof(data.get("asset")) != TYPE_DICTIONARY or data["asset"].get("version") != "2.0": return _error("Only glTF 2.0 is supported.")
	var offset := 20 + json_length
	var binary := PackedByteArray()
	if offset < bytes.size():
		if offset + 8 > bytes.size() or bytes.decode_u32(offset + 4) != 0x004e4942 or bytes.decode_u32(offset) % 4 != 0 or offset + 8 + bytes.decode_u32(offset) != bytes.size(): return _error("Invalid GLB binary chunk.")
		binary = bytes.slice(offset + 8)
	var queue: Array = [data]
	var visited := 0
	var light_blocks := 0
	while not queue.is_empty():
		var value = queue.pop_back()
		visited += 1
		if visited > 50000: return _error("GLB structure exceeds its budget.")
		if value is Dictionary:
			if value.has("uri"): return _error("External or data-URI assets are unsupported; use embedded GLB buffers/images.")
			if value.get("extensions") is Dictionary and value["extensions"].has(LIGHTS): light_blocks += 1
			queue.append_array(value.values())
		elif value is Array: queue.append_array(value)
		elif typeof(value) == TYPE_FLOAT and not is_finite(value): return _error("GLB numbers must be finite.")
	for limits in [["nodes", 256], ["meshes", 128], ["materials", 128], ["skins", 16], ["animations", 64], ["images", 16], ["buffers", 1], ["accessors", 2048], ["bufferViews", 2048]]:
		if typeof(data.get(limits[0], [])) != TYPE_ARRAY or data.get(limits[0], []).size() > limits[1]: return _error("GLB record count exceeds its budget.")
	var counts := 0
	for accessor in data.get("accessors", []):
		if typeof(accessor) != TYPE_DICTIONARY or typeof(accessor.get("count")) not in [TYPE_INT, TYPE_FLOAT] or accessor["count"] != floorf(accessor["count"]) or accessor["count"] < 0 or accessor["count"] > 600000: return _error("Invalid or oversized GLB accessor.")
		counts += int(accessor["count"])
		if counts > 2000000: return _error("GLB accessor work exceeds its budget.")
		var component = accessor.get("componentType")
		if typeof(component) not in [TYPE_INT, TYPE_FLOAT] or component != floorf(component) or int(component) not in [5120, 5121, 5122, 5123, 5125, 5126] or accessor.get("type") not in ["SCALAR", "VEC2", "VEC3", "VEC4", "MAT2", "MAT3", "MAT4"]: return _error("Unsupported GLB accessor type.")
	for view in data.get("bufferViews", []):
		if typeof(view) != TYPE_DICTIONARY: return _error("Invalid GLB buffer view.")
		var start = view.get("byteOffset", 0)
		var length = view.get("byteLength", -1)
		if typeof(start) not in [TYPE_INT, TYPE_FLOAT] or typeof(length) not in [TYPE_INT, TYPE_FLOAT] or start != floorf(start) or length != floorf(length) or start < 0 or length < 0 or start + length > binary.size(): return _error("GLB buffer view escapes the binary chunk.")
		if view.get("buffer", 0) != 0: return _error("GLB references an unsupported buffer.")
	var nodes: Array = data.get("nodes", [])
	var parents := {}
	for index in nodes.size():
		if typeof(nodes[index]) != TYPE_DICTIONARY or typeof(nodes[index].get("children", [])) != TYPE_ARRAY: return _error("Invalid GLB node hierarchy.")
		for child in nodes[index].get("children", []):
			if typeof(child) not in [TYPE_INT, TYPE_FLOAT] or child != floorf(child) or child < 0 or child >= nodes.size() or parents.has(int(child)): return _error("Invalid or multiply parented GLB node.")
			parents[int(child)] = index
	for index in nodes.size():
		var cursor := index
		var seen := {}
		while parents.has(cursor):
			if seen.has(cursor): return _error("Cyclic GLB nodes are unsupported.")
			seen[cursor] = true
			cursor = parents[cursor]
	for image in data.get("images", []):
		if typeof(image) != TYPE_DICTIONARY or typeof(image.get("bufferView")) not in [TYPE_INT, TYPE_FLOAT] or image["bufferView"] != floorf(image["bufferView"]) or image["bufferView"] < 0 or image["bufferView"] >= data.get("bufferViews", []).size(): return _error("Invalid embedded GLB image.")
		var view: Dictionary = data["bufferViews"][int(image["bufferView"])]
		var dimensions := preload("res://addons/orca/scripts/image_attachments.gd")._source_dimensions(binary.slice(int(view.get("byteOffset", 0)), int(view.get("byteOffset", 0) + view["byteLength"])))
		if not preload("res://addons/orca/scripts/image_attachments.gd")._valid_dimensions(dimensions): return _error("GLB image exceeds supported image dimensions.")
	var required = data.get("extensionsRequired", [])
	if not required is Array or required.size() > 32: return _error("Malformed or oversized required glTF extension list.")
	var unknown := PackedStringArray()
	var seen_extensions := {}
	for extension in required:
		if typeof(extension) != TYPE_STRING or extension.length() > 64 or not extension.is_valid_ascii_identifier() or seen_extensions.has(extension): return _error("Invalid required glTF extension identifier.")
		seen_extensions[extension] = true
		if extension != LIGHTS: unknown.append(extension)
	if not unknown.is_empty():
		return _error("Unsupported required glTF extensions: %s%s. No import artifact was registered. Use core glTF equivalents for those features." % [", ".join(unknown.slice(0, 4)), " (+%d more)" % (unknown.size() - 4) if unknown.size() > 4 else ""])
	if light_blocks > 0 or seen_extensions.has(LIGHTS):
		var error := _lights_error(data, nodes, light_blocks)
		if not error.is_empty(): return _error(LIGHTS + ": " + error)
	return {"success": true, "summary": {"bytes": bytes.size(), "nodes": data.get("nodes", []).size(), "meshes": data.get("meshes", []).size(), "materials": data.get("materials", []).size(), "skins": data.get("skins", []).size(), "animations": data.get("animations", []).size(), "images": data.get("images", []).size()}}

# The built-in Godot importer supports these native lights. Validate precisely
# their root definitions and node references, without invoking any importer here.
static func _lights_error(data: Dictionary, nodes: Array, blocks: int) -> String:
	var used = data.get("extensionsUsed")
	var root = data.get("extensions")
	if not used is Array or used.size() > 32 or not used.has(LIGHTS) or not root is Dictionary: return "Missing extension declaration or root light table."
	var table = root.get(LIGHTS)
	if not table is Dictionary or table.size() != 1 or not table.get("lights") is Array: return "Invalid root light table."
	var lights: Array = table["lights"]
	if lights.is_empty() or lights.size() > 128: return "Invalid light count."
	for light in lights:
		if not light is Dictionary or light.get("type") not in ["point", "spot", "directional"] or light.keys().any(func(key): return key not in ["name", "type", "color", "intensity", "range", "spot"]): return "Unsupported light definition."
		if light.has("name") and (typeof(light["name"]) != TYPE_STRING or light["name"].length() > 256): return "Invalid light name."
		var color = light.get("color", [1, 1, 1])
		if not color is Array or color.size() != 3 or color.any(func(channel): return not _number_in(channel, 0, 1)): return "Invalid light color."
		if not _number_in(light.get("intensity", 1), 0, 1e9) or (light.has("range") and (not _number_in(light["range"], 0, 1e6) or light["range"] <= 0)): return "Light intensity or range exceeds supported bounds."
		if light.has("spot") or light["type"] == "spot":
			var spot = light.get("spot", {})
			if light["type"] != "spot" or not spot is Dictionary or spot.keys().any(func(key): return key not in ["innerConeAngle", "outerConeAngle"]): return "Invalid spot parameters."
			var inner = spot.get("innerConeAngle", 0)
			var outer = spot.get("outerConeAngle", PI / 4)
			if not _number_in(inner, 0, PI / 2) or not _number_in(outer, 0, PI / 2) or inner >= outer: return "Invalid spot cone angles."
	var accounted := 1 # root table
	for node in nodes:
		var extensions = node.get("extensions", {})
		if not extensions is Dictionary: return "Invalid node extensions."
		if not extensions.has(LIGHTS): continue
		var reference = extensions[LIGHTS]
		if not reference is Dictionary or reference.size() != 1: return "Invalid node light reference."
		var index = reference.get("light")
		if not _number_in(index, 0, lights.size() - 1) or index != floorf(index): return "Invalid node light index."
		accounted += 1
	return "Unexpected light extension location." if accounted != blocks else ""

static func _number_in(value: Variant, low: float, high: float) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and value >= low and value <= high

static func _error(message: String) -> Dictionary:
	return {"success": false, "error": message}
