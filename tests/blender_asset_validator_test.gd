extends SceneTree

const Validator = preload("res://addons/orca/scripts/blender_asset_validator.gd")
const Preview = preload("res://addons/orca/scripts/blender_preview_loader.gd")
var failures := 0

func _init() -> void:
	var valid := {"asset": {"version": "2.0"}, "nodes": [{"name": "Asset"}]}
	check(Validator.inspect(glb(valid))["success"], "bounded self-contained GLB")
	for bad in [{"asset": "wrong"}, {"asset": {"version": "2.0"}, "buffers": [{"uri": "../../secret.bin"}]}, {"asset": {"version": "2.0"}, "nodes": [{"children": [0]}]}, {"asset": {"version": "2.0"}, "nodes": [{"children": [1]}, {"children": [0]}]}, {"asset": {"version": "2.0"}, "extensionsRequired": ["arbitrary_extension"]}, {"asset": {"version": "2.0"}, "accessors": [{"count": 9000000}]}]:
		check(not Validator.inspect(glb(bad))["success"], "deny unsupported/cyclic/external GLB " + str(bad))
	var broken := glb(valid)
	broken.encode_u32(8, 123)
	check(not Validator.inspect(broken)["success"], "chunk length integrity")
	var data := {"asset": {"version": "2.0"}, "buffers": [{"byteLength": 36}], "bufferViews": [{"byteLength": 36}], "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}}]}], "nodes": [{"mesh": 0, "translation": [2, 3, 4], "extras": {"script": "res://untrusted.gd"}}]}
	var binary := PackedByteArray()
	binary.resize(36)
	binary.encode_float(12, 1)
	binary.encode_float(28, 1)
	var preview := Preview.decode(glb_binary(data, binary))
	check(preview.get("success", false) and preview["meshes"][0]["mesh"] is ArrayMesh, "core preview builds only native mesh/material records")
	var bounds: AABB = preview["bounds"]
	check(bounds.position == Vector3(2, 3, 4) and bounds.size.is_equal_approx(Vector3(1, 1, 0.00001)), "native ArrayMesh flat-axis padding and hierarchy bounds")
	var rotated := data.duplicate(true)
	rotated["nodes"][0]["rotation"] = [0, 0, sqrt(0.5), sqrt(0.5)]
	rotated["nodes"][0]["scale"] = [2, 3, 1]
	var rotated_preview := Preview.decode(glb_binary(rotated, binary))
	var trs: Transform3D = rotated_preview["meshes"][0]["transform"]
	check((trs * Vector3(1, 0, 0)).is_equal_approx(Vector3(2, 5, 4)), "glTF local nonuniform scale precedes rotation, preserving modeled proportions")
	for field in ["byteOffset", "count"]:
		var malformed := data.duplicate(true)
		malformed["accessors"][0][field] = 999999
		check(not Preview.decode(glb_binary(malformed, binary))["success"], "preview denies accessor escape/work budget")
	var bad_node := data.duplicate(true)
	bad_node["nodes"][0]["translation"] = ["bad", 0, 0]
	check(not Preview.decode(glb_binary(bad_node, binary))["success"], "preview refuses malformed native transforms")
	var nonfinite := binary.duplicate()
	nonfinite.encode_float(0, INF)
	check(not Preview.decode(glb_binary(data, nonfinite))["success"], "preview refuses nonfinite vertex data")
	print("blender_asset_validator_test: %d failures" % failures)
	quit(1 if failures else 0)

func glb(data: Dictionary) -> PackedByteArray:
	var source := JSON.stringify(data).to_utf8_buffer()
	while source.size() % 4: source.append(32)
	var bytes := PackedByteArray()
	bytes.resize(20)
	bytes.encode_u32(0, 0x46546c67)
	bytes.encode_u32(4, 2)
	bytes.encode_u32(8, 20 + source.size())
	bytes.encode_u32(12, source.size())
	bytes.encode_u32(16, 0x4e4f534a)
	bytes.append_array(source)
	return bytes

func glb_binary(data: Dictionary, binary: PackedByteArray) -> PackedByteArray:
	var bytes := glb(data)
	var chunk := PackedByteArray()
	chunk.resize(8)
	chunk.encode_u32(0, binary.size())
	chunk.encode_u32(4, 0x004e4942)
	bytes.append_array(chunk)
	bytes.append_array(binary)
	bytes.encode_u32(8, bytes.size())
	return bytes

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		printerr(message)
