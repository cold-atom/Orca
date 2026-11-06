extends SceneTree

const Inspector = preload("res://addons/orca/scripts/animation_inspector.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const FIXTURE := "res://tests/fixtures/animation_inspector_fixture.tscn"
var failures: Array[String] = []


func _init() -> void: call_deferred("run")


func check(value: bool, message: String) -> void:
	if not value: failures.append(message)


func run() -> void:
	var original := FileAccess.get_file_as_bytes(FIXTURE)
	var overview := Inspector.inspect({"scene_path": FIXTURE}, Tools._validate_path)
	check(overview.get("success", false), "saved native animation overview succeeds: " + str(overview.get("error", "")))
	if overview.get("success", false):
		var player: Dictionary = overview["report"]["players"][0]
		check(player["autoplay"] == "walk" and player["animations"][0]["track_count"] == 2, "overview retains autoplay and track count")
		check(not player["animations"][0].has("tracks"), "overview omits key data")
	var detail := Tools.execute_tool("inspect_animation", {"scene_path": FIXTURE, "animation_name": "walk", "max_keys": 2})
	check(detail.get("success", false), "tool dispatcher exposes read-only animation inspection: " + str(detail.get("content", "")))
	if detail.get("success", false):
		var report: Dictionary = JSON.parse_string(detail["content"])
		var tracks: Array = report["players"][0]["animations"][0]["tracks"]
		check(tracks[0]["target_status"] == "serialized_node" and tracks[1]["target_status"] == "not_found_in_saved_scene", "targets reflect saved node evidence")
		check(tracks[0]["keys"].size() == 2 and tracks[1]["keys"].is_empty() and report["truncation"]["reasons"].has("key_limit"), "key output budget is shared across tracks")
		check(tracks[0]["keys"][1]["value"]["type"] == "Vector2", "key values retain Godot type")
		check(JSON.parse_string(detail["model_content"]) == report, "model/UI report values agree")
	var window := Inspector.inspect(JSON.parse_string(JSON.stringify({"scene_path": FIXTURE, "animation_name": "walk", "track_index": 0, "start_time": 0.4, "end_time": 0.6})), Tools._validate_path)
	check(window.get("success", false), "provider-decoded numeric track/time arguments are accepted")
	if window.get("success", false):
		var keys: Array = window["report"]["players"][0]["animations"][0]["tracks"][0]["keys"]
		check(keys.size() == 1 and is_equal_approx(float(keys[0]["time"]), 0.5), "selected time window returns only matching key")
	for args in [{"scene_path": FIXTURE, "track_index": 0}, {"scene_path": FIXTURE, "animation_name": "unknown"}, {"scene_path": FIXTURE, "player_path": "../Other"}, {"scene_path": FIXTURE, "max_keys": true}, {"scene_path": FIXTURE, "max_keys": 201}, {"scene_path": FIXTURE, "start_time": NAN}, {"scene_path": FIXTURE, "source": "untrusted"}, {"scene_path": "res://addons/orca/scenes/chat_window.tscn"}, {"scene_path": "user://external.tscn"}]:
		check(not Inspector.inspect(args, Tools._validate_path).get("success", true), "malformed/unsafe animation inputs fail")
	check(not Inspector.inspect({"scene_path": FIXTURE}, Tools._validate_path, [FIXTURE]).get("success", true), "dirty scene input is rejected")
	for literal in ['Object(Node,"name":"unsafe")', 'Resource("unsafe")', 'Callable()', 'ExtResource("script")', '[[[[[[[[[[[[[[[[[0]]]]]]]]]]]]]]]]]']:
		check(not Inspector._literal(literal).get("success", true), "executable/resource/deep literal is rejected before parsing")
	check(Inspector._literal('"Object(Node)"').get("value") == "Object(Node)", "original quoted text is data")
	check(FileAccess.get_file_as_bytes(FIXTURE) == original, "inspection never changes saved bytes")
	_test_native_saved_formats()
	_test_script_isolation()
	_test_dependencies_and_scene_order()
	for failure in failures: printerr("animation_inspector_test: ", failure)
	print("animation_inspector_test: ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_native_saved_formats() -> void:
	var path := "res://.orca_animation_native_%d.tres" % Time.get_ticks_usec()
	var animation := Animation.new()
	for type in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D, Animation.TYPE_BEZIER, Animation.TYPE_BLEND_SHAPE, Animation.TYPE_METHOD, Animation.TYPE_ANIMATION]:
		var track := animation.add_track(type)
		animation.track_set_path(track, NodePath("Sprite2D:position"))
		match type:
			Animation.TYPE_POSITION_3D: animation.position_track_insert_key(track, 0.5, Vector3(1, 2, 3))
			Animation.TYPE_ROTATION_3D: animation.rotation_track_insert_key(track, 0.5, Quaternion.IDENTITY)
			Animation.TYPE_SCALE_3D: animation.scale_track_insert_key(track, 0.5, Vector3.ONE)
			Animation.TYPE_BEZIER: animation.bezier_track_insert_key(track, 0.5, 1.0)
			Animation.TYPE_BLEND_SHAPE: animation.blend_shape_track_insert_key(track, 0.5, 0.8)
			Animation.TYPE_METHOD: animation.track_insert_key(track, 0.5, {"method": "fixture_unused", "args": [1, 2]})
			Animation.TYPE_ANIMATION: animation.animation_track_insert_key(track, 0.5, "walk")
	check(ResourceSaver.save(animation, path) == OK, "native animation serialization fixture saves")
	var state := {"deadline": Time.get_ticks_msec() + 1000, "bytes": 0, "files": {}, "reasons": [], "dirty_paths": [], "validator": Tools._validate_path}
	var source := Inspector._read_source(path, state)
	check(source.get("success", false), "native standalone source is parsed")
	if source.get("success", false):
		var decoded := Inspector._decode_animation(source["sections"][-1], state)
		check(decoded.get("success", false), "actual Godot-generated 3D/bezier/blend keys decode: " + str(decoded.get("error", "")))
		if decoded.get("success", false):
			check(decoded["animation"].get_track_count() == animation.get_track_count(), "native track formats retain track count")
			for track in range(animation.get_track_count()):
				check(decoded["animation"].track_get_key_value(track, 0) == animation.track_get_key_value(track, 0), "decoded values agree with the native source")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_script_isolation() -> void:
	var prefix := "res://.orca_animation_isolation_%d" % Time.get_ticks_usec()
	var script_path := prefix + ".gd"
	var scene_path := prefix + ".tscn"
	var sentinel := prefix + ".sentinel"
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string('extends Node\nstatic func _static_init():\n\tFileAccess.open("%s", FileAccess.WRITE).store_string("executed")\n' % sentinel)
	file.close()
	file = FileAccess.open(scene_path, FileAccess.WRITE)
	var source := FileAccess.get_file_as_string(FIXTURE).replace('[gd_scene load_steps=3 format=3]', '[gd_scene load_steps=4 format=3]\n[ext_resource type="Script" path="%s" id="script"]' % script_path).replace('[node name="Character" type="Node2D"]', '[node name="Character" type="Node2D"]\nscript = ExtResource("script")')
	file.store_string(source)
	file.close()
	var result := Inspector.inspect({"scene_path": scene_path}, Tools._validate_path)
	check(result.get("success", false) and not FileAccess.file_exists(sentinel), "animation inspection never loads the scene's static initializer")
	for path in [script_path, scene_path, sentinel]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_dependencies_and_scene_order() -> void:
	var prefix := "res://.orca_animation_dependencies_%d" % Time.get_ticks_usec()
	var animation_path := prefix + "_animation.tres"
	var library_path := prefix + "_library.tres"
	var scene_path := prefix + ".tscn"
	var original := FileAccess.get_file_as_string(FIXTURE)
	var start := original.find('[sub_resource type="Animation"')
	start = original.find("\n", start) + 1
	var end := original.find('[sub_resource type="AnimationLibrary"')
	_write(animation_path, '[gd_resource type="Animation" format=3]\n[resource]\n' + original.substr(start, end - start))
	_write(library_path, '[gd_resource type="AnimationLibrary" format=3]\n[ext_resource type="Animation" path="%s" id="animation"]\n[resource]\n_data = { &"walk": ExtResource("animation") }\n' % animation_path)
	var source := original.replace('[gd_scene load_steps=3 format=3]', '[gd_scene load_steps=4 format=3]\n[ext_resource type="AnimationLibrary" path="%s" id="external"]' % library_path).replace('&"": SubResource("AnimationLibrary_fixture")', '&"external": ExtResource("external")')
	_write(scene_path, source)
	var result := Inspector.inspect({"scene_path": scene_path, "animation_name": "external/walk", "track_index": 0}, Tools._validate_path)
	check(result.get("success", false), "external native library/animation dependencies are followed: " + str(result.get("error", "")))
	if result.get("success", false): check(result["report"]["files_read"] == 3 and result["report"]["players"][0]["animations"][0]["tracks"][0]["keys"].size() == 3, "external native source retains keys and source provenance")
	check(not Inspector.inspect({"scene_path": scene_path}, Tools._validate_path, [library_path]).get("success", true), "dirty source dependency is rejected")
	var reordered := original.replace('[node name="Sprite2D" type="Sprite2D" parent="."]\n\n', "") + '\n[node name="Sprite2D" type="Sprite2D" parent="."]\n'
	_write(scene_path, reordered)
	result = Inspector.inspect({"scene_path": scene_path, "animation_name": "walk"}, Tools._validate_path)
	check(result.get("success", false) and result["report"]["players"][0]["animations"][0]["tracks"][0]["target_status"] == "serialized_node", "targets after the player section remain resolvable")
	var with_instance := reordered.replace('[gd_scene load_steps=3 format=3]', '[gd_scene load_steps=4 format=3]\n[ext_resource type="PackedScene" path="res://tests/fixtures/inspect_scene_child.tscn" id="child"]') + '\n[node name="Instance" parent="." instance=ExtResource("child")]\n[editable path="Instance"]\n'
	_write(scene_path, with_instance)
	result = Inspector.inspect({"scene_path": scene_path, "animation_name": "walk"}, Tools._validate_path)
	check(result.get("success", false) and result["report"]["players"][0]["animations"][0]["tracks"][1]["target_status"] == "not_locally_serialized", "later instance provenance prevents false missing-target certainty")
	var malformed := {"kind": "sub_resource", "fields": {"type": "Animation"}, "properties": {"tracks/0/type": '"value"', "tracks/0/keys": '{"times": PackedFloat32Array(0), "transitions": PackedFloat32Array(1), "values": []}'}}
	check(not Inspector._decode_animation(malformed, {"deadline": Time.get_ticks_msec() + 1000}).get("success", true), "mismatched native key arrays fail before native setters")
	for raw in ['{,}', '{"walk": "__orca_reference_0", "other": SubResource("real")}', '{"walk": SubResource("real"), "walk": SubResource("real")}', '{"walk": Object(Node)}']:
		check(not Inspector._reference_map(raw).get("success", true), "malformed/reference-looking values cannot masquerade as native library entries")
	check(not Inspector._reference_map('"x"'.repeat(33000)).get("success", true), "oversized maps fail before reference enumeration/replacement work")
	var many := "{"
	for index in range(65): many += ('"a%d": SubResource("real"),' % index)
	many += "}"
	check(not Inspector._reference_map(many).get("success", true), "resource map work is bounded independently of its result size")
	var wide: Array = []
	for index in range(16): wide.append(range(64))
	var bounded_value = Inspector._key_value(wide, 0, {"remaining": 8})
	check(JSON.stringify(bounded_value).contains('"truncated":true'), "nested key presentation stops at an independent value-work budget")
	for path in [animation_path, library_path, scene_path]: DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	check(file != null, "fixture opens for writing")
	if file != null:
		file.store_string(content)
		file.close()
