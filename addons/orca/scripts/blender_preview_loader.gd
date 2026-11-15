@tool
extends RefCounted

## Display-only core glTF decoding. No ResourceLoader, GLTFDocument extensions,
## import scripts, scene instantiation, animation or source-controlled node types.
const Validator = preload("res://addons/orca/scripts/blender_asset_validator.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const MAX_VERTICES := 100000
const MAX_INDICES := 300000
const MAX_PIXELS := 16 * 1024 * 1024
const MAX_MSEC := 350

var _data: Dictionary
var _binary: PackedByteArray
var _deadline := 0
var _vertices := 0
var _indices := 0
var _pixels := 0
var _textures := {}
var _materials := {}
var _error := ""

static func decode(bytes: PackedByteArray) -> Dictionary:
	var reader := new()
	return reader._decode(bytes)

func _decode(bytes: PackedByteArray) -> Dictionary:
	_deadline = Time.get_ticks_msec() + MAX_MSEC
	var checked := Validator.inspect(bytes)
	if not checked.get("success", false): return checked
	var length := bytes.decode_u32(12)
	_data = JSON.parse_string(bytes.slice(20, 20 + length).get_string_from_utf8())
	_binary = bytes.slice(28 + length) if bytes.size() > 20 + length else PackedByteArray()
	var nodes: Array = _data.get("nodes", [])
	var parents := {}
	for index in nodes.size():
		for child in nodes[index].get("children", []): parents[int(child)] = index
	var roots: Array = []
	var scenes = _data.get("scenes", [])
	if not scenes is Array or scenes.size() > 256: return _failure()
	if not scenes.is_empty():
		var scene = _data.get("scene", 0)
		if not _index(scene, scenes.size()) or not scenes[int(scene)] is Dictionary or not scenes[int(scene)].get("nodes", []) is Array: return _failure()
		roots = scenes[int(scene)].get("nodes", [])
	else:
		for index in nodes.size():
			if not parents.has(index): roots.append(index)
	if roots.size() > 256: return _failure()
	var queue: Array = []
	for index in roots:
		if not _index(index, nodes.size()) or parents.has(int(index)): return _failure()
		queue.append([int(index), Transform3D.IDENTITY])
	var seen := {}
	var cache := {}
	var records: Array = []
	var bounds := AABB()
	var has_bounds := false
	var rendered_vertices := 0
	while not queue.is_empty():
		if _expired(): return _failure()
		var entry: Array = queue.pop_back()
		var index: int = entry[0]
		if seen.has(index): return _failure()
		seen[index] = true
		var node: Dictionary = nodes[index]
		var transform: Transform3D = entry[1] * _transform(node)
		if not _error.is_empty() or not transform.is_finite(): return _failure()
		for child in node.get("children", []): queue.append([int(child), transform])
		if not node.has("mesh"): continue
		var mesh_index = node["mesh"]
		if not _index(mesh_index, _data.get("meshes", []).size()): return _failure()
		if not cache.has(int(mesh_index)): cache[int(mesh_index)] = _mesh(_data["meshes"][int(mesh_index)])
		var mesh: ArrayMesh = cache[int(mesh_index)]
		if mesh == null or not _error.is_empty(): return _failure()
		for surface in mesh.get_surface_count(): rendered_vertices += mesh.surface_get_array_len(surface)
		if rendered_vertices > MAX_VERTICES: return _failure()
		var box: AABB = transform * mesh.get_aabb()
		if not box.position.is_finite() or not box.size.is_finite() or maxf(box.position.abs()[box.position.abs().max_axis_index()], box.size[box.size.max_axis_index()]) > 1000000: return _failure()
		bounds = bounds.merge(box) if has_bounds else box
		has_bounds = true
		records.append({"mesh": mesh, "transform": transform})
	if records.is_empty() or _expired(): return _failure()
	return {"success": true, "meshes": records, "bounds": bounds}

func _expired() -> bool:
	return Time.get_ticks_msec() > _deadline

func _failure() -> Dictionary:
	return {"success": false, "error": "This asset exceeds the supported core 3D preview format or budget. The rendered image remains available."}

static func _index(value, count: int) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and value == floorf(value) and value >= 0 and value < count

func _vector(value, count: int, fallback: Array) -> Array:
	if value == null: return fallback
	if not value is Array or value.size() != count:
		_error = "vector"
		return fallback
	for number in value:
		if typeof(number) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(number)) or absf(number) > 1000000:
			_error = "number"
			return fallback
	return value

func _transform(node: Dictionary) -> Transform3D:
	if node.has("matrix"):
		var m := _vector(node["matrix"], 16, [])
		if m.is_empty(): return Transform3D.IDENTITY
		if m[3] != 0 or m[7] != 0 or m[11] != 0 or m[15] != 1: _error = "matrix"
		return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[4], m[5], m[6]), Vector3(m[8], m[9], m[10])), Vector3(m[12], m[13], m[14]))
	var t := _vector(node.get("translation"), 3, [0, 0, 0])
	var r := _vector(node.get("rotation"), 4, [0, 0, 0, 1])
	var s := _vector(node.get("scale"), 3, [1, 1, 1])
	var quaternion := Quaternion(r[0], r[1], r[2], r[3])
	if quaternion.length_squared() < 0.000001:
		_error = "rotation"
		return Transform3D.IDENTITY
	return Transform3D(Basis(quaternion.normalized()).scaled_local(Vector3(s[0], s[1], s[2])), Vector3(t[0], t[1], t[2]))

func _accessor(index, components: int, indices: bool = false) -> PackedFloat64Array:
	var empty := PackedFloat64Array()
	var accessors: Array = _data.get("accessors", [])
	if not _index(index, accessors.size()): return empty
	var a: Dictionary = accessors[int(index)]
	if a.has("sparse") or a.get("type") != (["", "SCALAR", "VEC2", "VEC3", "VEC4"][components]): return empty
	var code: int = int(a["componentType"])
	if code not in ([5121, 5123, 5125] if indices else [5121, 5123, 5126]): return empty
	if typeof(a.get("normalized", false)) != TYPE_BOOL: return empty
	var count: int = int(a["count"])
	if count <= 0 or count > (MAX_INDICES if indices else MAX_VERTICES): return empty
	var views: Array = _data.get("bufferViews", [])
	if not _index(a.get("bufferView"), views.size()): return empty
	var view: Dictionary = views[int(a["bufferView"])]
	var size := 1 if code == 5121 else 2 if code == 5123 else 4
	var stride = view.get("byteStride", size * components)
	var offset = a.get("byteOffset", 0)
	if not _index(stride, 253) or stride < size * components or int(stride) % size != 0 or not _index(offset, int(view["byteLength"]) + 1) or int(offset) % size != 0: return empty
	if int(offset) + (count - 1) * int(stride) + size * components > int(view["byteLength"]): return empty
	var start := int(view.get("byteOffset", 0)) + int(offset)
	var values := PackedFloat64Array()
	values.resize(count * components)
	for item in count:
		if item % 1024 == 0 and _expired(): return empty
		for c in components:
			var at := start + item * int(stride) + c * size
			var number: float = _binary.decode_float(at) if code == 5126 else _binary[at] if code == 5121 else _binary.decode_u16(at) if code == 5123 else _binary.decode_u32(at)
			if not indices and a.get("normalized", false) and code != 5126: number /= 255.0 if code == 5121 else 65535.0
			if not is_finite(number) or (not indices and absf(number) > 1000000): return empty
			values[item * components + c] = number
	return values

func _mesh(value) -> ArrayMesh:
	if not value is Dictionary or not value.get("primitives") is Array or value["primitives"].is_empty() or value["primitives"].size() > 32: return null
	var mesh := ArrayMesh.new()
	for primitive in value["primitives"]:
		if _expired() or not primitive is Dictionary or primitive.get("mode", 4) != 4 or not primitive.get("attributes") is Dictionary: return null
		var attributes: Dictionary = primitive["attributes"]
		var positions := _accessor(attributes.get("POSITION"), 3)
		if positions.is_empty(): return null
		var count := positions.size() / 3
		_vertices += count
		if _vertices > MAX_VERTICES: return null
		var vertices := PackedVector3Array()
		vertices.resize(count)
		for index in count: vertices[index] = Vector3(positions[index * 3], positions[index * 3 + 1], positions[index * 3 + 2])
		var values := _accessor(primitive["indices"], 1, true) if primitive.has("indices") else PackedFloat64Array()
		if primitive.has("indices") and values.is_empty(): return null
		var index_count := values.size() if primitive.has("indices") else count
		_indices += index_count
		if index_count % 3 != 0 or _indices > MAX_INDICES: return null
		var indices := PackedInt32Array()
		indices.resize(index_count)
		for index in index_count:
			var original := index - 1 if index % 3 == 2 else index + 1 if index % 3 == 1 else index
			var target: int = int(values[original]) if primitive.has("indices") else original
			if target < 0 or target >= count: return null
			indices[index] = target
		var normals := PackedVector3Array()
		normals.resize(count)
		if attributes.has("NORMAL"):
			var numbers := _accessor(attributes["NORMAL"], 3)
			if numbers.size() != positions.size(): return null
			for index in count: normals[index] = Vector3(numbers[index * 3], numbers[index * 3 + 1], numbers[index * 3 + 2]).normalized()
		else:
			for index in range(0, index_count, 3):
				var a := indices[index]
				var b := indices[index + 1]
				var c := indices[index + 2]
				var normal := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
				normals[a] += normal
				normals[b] += normal
				normals[c] += normal
			for index in count: normals[index] = normals[index].normalized()
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		if attributes.has("TEXCOORD_0"):
			var uv := _accessor(attributes["TEXCOORD_0"], 2)
			if uv.size() != count * 2: return null
			var coordinates := PackedVector2Array()
			coordinates.resize(count)
			for index in count: coordinates[index] = Vector2(uv[index * 2], uv[index * 2 + 1])
			arrays[Mesh.ARRAY_TEX_UV] = coordinates
		var material := _material(primitive.get("material", -1))
		if material == null or _expired(): return null
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	return mesh

func _material(index) -> StandardMaterial3D:
	if _materials.has(index): return _materials[index]
	var value := {}
	if index != -1:
		if not _index(index, _data.get("materials", []).size()) or not _data["materials"][int(index)] is Dictionary: return null
		value = _data["materials"][int(index)]
	var pbr = value.get("pbrMetallicRoughness", {})
	if not pbr is Dictionary: return null
	var color := _vector(pbr.get("baseColorFactor"), 4, [0.72, 0.74, 0.78, 1])
	var numbers := _vector([pbr.get("metallicFactor", 1), pbr.get("roughnessFactor", 1)], 2, [0, 1])
	if not _error.is_empty(): return null
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color[0], color[1], color[2], color[3])
	material.metallic = clampf(numbers[0], 0, 1)
	material.roughness = clampf(numbers[1], 0, 1)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if value.get("doubleSided", false) == true else BaseMaterial3D.CULL_BACK
	if value.get("alphaMode") == "BLEND": material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if value.get("alphaMode") == "MASK":
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		var cutoff := _vector([value.get("alphaCutoff", 0.5)], 1, [0.5])
		material.alpha_scissor_threshold = clampf(cutoff[0], 0, 1)
	if pbr.has("baseColorTexture"):
		var info = pbr["baseColorTexture"]
		if not info is Dictionary or info.get("texCoord", 0) != 0: return null
		material.albedo_texture = _texture(info.get("index"))
		if material.albedo_texture == null: return null
	_materials[index] = material
	return material

func _texture(index) -> Texture2D:
	if _textures.has(index): return _textures[index]
	var textures = _data.get("textures", [])
	if not textures is Array or textures.size() > 32 or not _index(index, textures.size()) or not textures[int(index)] is Dictionary: return null
	var source = textures[int(index)].get("source")
	if not _index(source, _data.get("images", []).size()): return null
	var image_info: Dictionary = _data["images"][int(source)]
	var view: Dictionary = _data["bufferViews"][int(image_info["bufferView"])]
	var bytes := _binary.slice(int(view.get("byteOffset", 0)), int(view.get("byteOffset", 0) + view["byteLength"]))
	var size := Images._source_dimensions(bytes)
	_pixels += size.x * size.y
	if not Images._valid_dimensions(size) or _pixels > MAX_PIXELS or _expired(): return null
	var image := Image.new()
	var error := image.load_png_from_buffer(bytes) if image_info.get("mimeType") == "image/png" else image.load_jpg_from_buffer(bytes) if image_info.get("mimeType") == "image/jpeg" else ERR_INVALID_DATA
	if error != OK: return null
	if maxi(size.x, size.y) > 1024:
		var ratio := 1024.0 / maxi(size.x, size.y)
		image.resize(maxi(1, int(size.x * ratio)), maxi(1, int(size.y * ratio)), Image.INTERPOLATE_BILINEAR)
	var texture := ImageTexture.create_from_image(image)
	_textures[index] = texture
	return texture
