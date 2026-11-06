@tool
extends RefCounted

# Saved animation extraction only. Never load the scene, scripts, or arbitrary
# resources: decode allowlisted Variant literals into a fresh native Animation.
const SceneInspector = preload("res://addons/orca/scripts/scene_inspector.gd")
const MAX_SOURCE_BYTES := 2 * 1024 * 1024
const MAX_TOTAL_BYTES := 4 * 1024 * 1024
const MAX_FILES := 16
const MAX_SECTIONS := 4096
const MAX_PROPERTIES := 32768
const MAX_VALUE_NODES := 128
const MAX_ANIMATIONS := 64
const MAX_TRACKS := 128
const MAX_KEYS := 200
const MAX_KEY_SCAN := 8192
const MAX_OUTPUT_BYTES := 64 * 1024
const TIMEOUT_MS := 250
const TRACK_TYPES := ["value", "position_3d", "rotation_3d", "scale_3d", "blend_shape", "method", "bezier", "audio", "animation"]
const LITERAL_TYPES := ["true", "false", "null", "Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Rect2", "Rect2i", "Color", "Quaternion", "Basis", "Transform2D", "Transform3D", "Plane", "AABB", "NodePath", "StringName", "PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedVector4Array", "PackedColorArray"]
const ARGUMENTS := ["scene_path", "player_path", "animation_name", "track_index", "start_time", "end_time", "max_keys"]


static func validate_arguments(arguments: Dictionary) -> String:
	for field in arguments:
		if field not in ARGUMENTS:
			return "Unknown animation inspection argument."
	if typeof(arguments.get("scene_path")) != TYPE_STRING or arguments["scene_path"].is_empty():
		return "scene_path must identify a saved .tscn scene."
	for field in ["player_path", "animation_name"]:
		if arguments.has(field) and (typeof(arguments[field]) != TYPE_STRING or arguments[field].is_empty() or arguments[field].length() > 512 or arguments[field].contains("\n") or arguments[field].contains("\r") or arguments[field].to_utf8_buffer().has(0)):
			return field + " must be a bounded non-empty string."
	if arguments.has("player_path") and not SceneInspector.valid_node_path(arguments["player_path"]):
		return "player_path must be a scene-relative node path."
	for field in ["track_index", "max_keys", "start_time", "end_time"]:
		if not arguments.has(field):
			continue
		var value = arguments[field]
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) < 0 or float(value) > 1000000:
			return field + " must be a finite nonnegative number."
		if field in ["track_index", "max_keys"] and (float(value) != floorf(float(value)) or (field == "track_index" and float(value) >= MAX_TRACKS) or (field == "max_keys" and (float(value) < 1 or float(value) > MAX_KEYS))):
			return field + " is outside its integer bounds."
	if arguments.has("track_index") or arguments.has("start_time") or arguments.has("end_time"):
		if not arguments.has("animation_name"):
			return "Select animation_name before narrowing tracks or key times."
	if arguments.has("end_time") and float(arguments["end_time"]) < float(arguments.get("start_time", 0)):
		return "end_time must not precede start_time."
	return ""


static func history_arguments(arguments: Dictionary) -> Dictionary:
	var result := {}
	for field in ARGUMENTS:
		var value = arguments.get(field)
		if field in ["scene_path", "player_path", "animation_name"] and typeof(value) == TYPE_STRING:
			result[field] = value.left(512)
		elif field in ["track_index", "max_keys", "start_time", "end_time"] and typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) >= 0 and float(value) <= 1000000:
			if field in ["start_time", "end_time"]: result[field] = float(value)
			elif float(value) == floorf(float(value)):
				result[field] = int(clampf(float(value), 0 if field == "track_index" else 1, MAX_TRACKS - 1 if field == "track_index" else MAX_KEYS))
	return result


static func inspect(arguments: Dictionary, validate_path: Callable, dirty_paths: Array = []) -> Dictionary:
	var error := validate_arguments(arguments)
	if not error.is_empty():
		return _error(error)
	var path: String = arguments["scene_path"]
	if path.get_extension() != "tscn":
		return _error("Animation inspection accepts saved .tscn scenes only.")
	var state := {"deadline": Time.get_ticks_msec() + TIMEOUT_MS, "bytes": 0, "files": {}, "reasons": [], "dirty_paths": dirty_paths, "validator": validate_path}
	var parsed := _read_source(path, state)
	if not parsed.get("success", false):
		return parsed
	var sections: Array = parsed["sections"]
	var resources: Dictionary = parsed["resources"]
	var nodes := {}
	var players: Array = []
	var has_instances := false
	for section in sections:
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation inspection reached its time limit.")
		if section["kind"] != "node":
			continue
		var fields: Dictionary = section["fields"]
		var node_path := _node_path(fields)
		nodes[node_path] = str(fields.get("type", ""))
		has_instances = has_instances or fields.has("instance") or not fields.has("type")
	for section in sections:
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation inspection reached its time limit.")
		if section["kind"] != "node": continue
		var fields: Dictionary = section["fields"]
		if fields.get("type") != "AnimationPlayer":
			continue
		var node_path := _node_path(fields)
		if arguments.has("player_path") and node_path != str(arguments["player_path"]).trim_prefix("./"):
			continue
		var properties: Dictionary = section["properties"]
		var record := {"player_path": node_path, "autoplay": "", "root_node": "..", "animations": []}
		for scalar in ["autoplay", "root_node"]:
			if properties.has(scalar):
				var literal := _literal(properties[scalar])
				if not literal.get("success", false): return literal
				record[scalar] = str(literal["value"])
		var libraries := {}
		if properties.has("libraries"):
			var mapping := _reference_map(properties["libraries"])
			if not mapping.get("success", false): return mapping
			libraries = mapping["value"]
		for property in properties:
			if str(property).begins_with("libraries/"):
				libraries[str(property).trim_prefix("libraries/")] = str(properties[property]).strip_edges()
		for library_name in libraries:
			var library := _resource(str(libraries[library_name]), resources, parsed, state)
			if not library.get("success", false): return library
			if library["section"]["fields"].get("type") != "AnimationLibrary" or library["section"]["properties"].has("script"):
				return _error("The selected library is not a native saved AnimationLibrary.")
			var mapping := _reference_map(library["section"]["properties"].get("_data", "{}"))
			if not mapping.get("success", false): return mapping
			for name in mapping["value"]:
				if record["animations"].size() >= MAX_ANIMATIONS:
					_reason(state, "animation_limit")
					break
				var qualified := str(name) if str(library_name).is_empty() else str(library_name) + "/" + str(name)
				if arguments.has("animation_name") and qualified != arguments["animation_name"]:
					continue
				var resource := _resource(str(mapping["value"][name]), library["source"]["resources"], library["source"], state)
				if not resource.get("success", false): return resource
				var decoded := _decode_animation(resource["section"], state, arguments.has("animation_name"), int(arguments.get("track_index", -1)))
				if not decoded.get("success", false): return decoded
				var animation: Animation = decoded["animation"]
				var summary := {"name": qualified, "length": animation.length, "loop_mode": animation.loop_mode, "step": animation.step, "track_count": animation.get_track_count()}
				if arguments.has("animation_name"):
					var tracks := _tracks(animation, record, nodes, has_instances, arguments, state)
					if not tracks.get("success", false): return tracks
					summary["tracks"] = tracks["tracks"]
				record["animations"].append(summary)
		players.append(record)
		if players.size() >= MAX_ANIMATIONS:
			_reason(state, "player_limit")
			break
	if arguments.has("player_path") and players.is_empty():
		return _error("player_path is not a locally serialized AnimationPlayer in this scene. Inspect the child scene for instanced players.")
	if arguments.has("animation_name"):
		var matches := 0
		for player in players: matches += player["animations"].size()
		if matches != 1:
			return _error("animation_name must match exactly one qualified animation. Use the overview to choose its name and player_path.")
	var report := {"source": "saved_animation_source", "scene_path": path, "players": players, "files_read": state["files"].size(), "source_bytes": state["bytes"], "truncation": {"truncated": not state["reasons"].is_empty(), "reasons": state["reasons"]}, "note": "Saved locally serialized AnimationPlayers and native Animation/AnimationLibrary data only. Scenes, scripts and other resources are never loaded or instantiated. No playback, runtime state, AnimationTree state, inherited/instanced expansion or patch hash. Track target evidence covers serialized node paths, not runtime creation or semantic property validity."}
	var content := JSON.stringify(report, "  ")
	if content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		return _error("Animation output exceeds 64 KiB. Select a player/animation/track, narrower time range, or fewer keys.")
	return {"success": true, "content": content, "report": report}


static func _read_source(path: String, state: Dictionary) -> Dictionary:
	if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation inspection reached its time limit. Narrow the scene or animation.")
	var validator: Callable = state["validator"]
	if not path.begins_with("res://") or path.length() > 512 or ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path()) != path or not validator.is_valid() or not validator.call(path, false).is_empty():
		return _error("Animation source is outside the canonical project/path boundary.")
	if path in state["dirty_paths"]: return _error("The animation source has unsaved editor changes. Save it before inspecting saved animation data.")
	if state["files"].has(path): return state["files"][path]
	if state["files"].size() >= MAX_FILES: return _error("Animation dependencies exceed the 16-file limit.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return _error("Animation source does not exist or cannot be read: " + path)
	var size := file.get_length()
	if size > MAX_SOURCE_BYTES or state["bytes"] + size > MAX_TOTAL_BYTES: return _error("Animation source exceeds its 2 MiB file / 4 MiB total limit.")
	var bytes := file.get_buffer(size)
	file.close()
	if bytes.size() != size or bytes.has(0): return _error("Animation source is not bounded UTF-8 text.")
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes: return _error("Animation source is not valid UTF-8.")
	state["bytes"] += size
	var header := RegEx.new()
	header.compile("^\\[(gd_scene|gd_resource|ext_resource|sub_resource|resource|node|connection|editable)(?: (.*))?\\]$")
	var attribute := RegEx.new()
	attribute.compile('([a-z_]+)=("(?:[^"\\\\]|\\\\.)*"|[^ ]+)')
	var property_pattern := RegEx.new()
	property_pattern.compile('^[^"\\[\\]{}\\s][^"\\[\\]{}=]* = ')
	var sections: Array = []
	var current := {}
	var property := ""
	var resources := {}
	var external := {}
	var property_count := 0
	for line in text.split("\n", true):
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation source parsing reached its time limit.")
		if line.begins_with("[") and line.length() > 4096: return _error("Saved animation section header exceeds its size limit.")
		var match := header.search(line.strip_edges()) if line.begins_with("[") else null
		if line.begins_with("[") and match == null and property.is_empty(): return _error("Unsupported saved animation section header.")
		if match != null:
			if sections.size() >= MAX_SECTIONS: return _error("Animation source exceeds the section scan limit.")
			var fields := {}
			for item in attribute.search_all(match.get_string(2)):
				var raw := item.get_string(2)
				fields[item.get_string(1)] = JSON.parse_string(raw) if raw.begins_with('"') else raw
			var kind := match.get_string(1)
			for field in ["type", "id"] if kind in ["sub_resource", "ext_resource"] else ["name"] if kind == "node" else []:
				if typeof(fields.get(field)) != TYPE_STRING or fields[field].is_empty() or fields[field].length() > 512: return _error("Saved animation section lacks bounded native identity fields.")
			if kind == "node" and (str(fields["name"]).contains("/") or (fields.has("parent") and (typeof(fields["parent"]) != TYPE_STRING or not SceneInspector.valid_node_path(fields["parent"])))): return _error("Saved node identity is malformed.")
			if kind == "sub_resource" and resources.has(fields["id"]): return _error("Duplicate animation sub-resource identity.")
			if kind == "ext_resource" and external.has(fields["id"]): return _error("Duplicate animation external-resource identity.")
			current = {"kind": match.get_string(1), "fields": fields, "properties": {}}
			if current["kind"] == "resource" and not sections.is_empty():
				fields["type"] = sections[0]["fields"].get("type", "")
			sections.append(current)
			property = ""
			if current["kind"] == "sub_resource": resources[str(fields.get("id", ""))] = current
			if current["kind"] == "ext_resource":
				var dependency := str(fields.get("path", ""))
				if not dependency.begins_with("res://") or dependency.length() > 512 or dependency.to_utf8_buffer().has(0) or not validator.call(dependency, false).is_empty(): return _error("Animation scene contains an unsafe external resource path.")
				external[str(fields.get("id", ""))] = fields
			continue
		if current.is_empty() or line.strip_edges().is_empty() or line.begins_with(";"): continue
		var equal := line.find(" = ") if property_pattern.search(line) != null else -1
		if equal > 0:
			property_count += 1
			if property_count > MAX_PROPERTIES: return _error("Saved animation source exceeds the property scan limit.")
			property = line.left(equal)
			if current["properties"].has(property): return _error("Duplicate saved animation property.")
			current["properties"][property] = line.substr(equal + 3)
		elif not property.is_empty(): current["properties"][property] += "\n" + line
	if sections.is_empty() or sections[0]["kind"] not in ["gd_scene", "gd_resource"]: return _error("Animation source lacks a saved scene/resource header.")
	# Native libraries saved as .tres use [resource], handled explicitly below.
	var result := {"success": true, "path": path, "sections": sections, "resources": resources, "external": external}
	state["files"][path] = result
	return result


static func _resource(reference: String, resources: Dictionary, source: Dictionary, state: Dictionary) -> Dictionary:
	if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation dependency inspection reached its time limit.")
	var expression := RegEx.new()
	expression.compile('^(SubResource|ExtResource)\\("([^"\\\\]+)"\\)$')
	var match := expression.search(reference.strip_edges())
	if match == null: return _error("Animation libraries must reference native saved resources.")
	var id := match.get_string(2)
	if match.get_string(1) == "SubResource":
		if not resources.has(id): return _error("Animation sub-resource reference is missing.")
		return {"success": true, "section": resources[id], "source": source}
	if not source["external"].has(id): return _error("Animation external resource reference is missing.")
	var external: Dictionary = source["external"][id]
	if external.get("type") not in ["Animation", "AnimationLibrary"] or str(external.get("path", "")).get_extension() != "tres": return _error("Only text native Animation/AnimationLibrary dependencies are supported.")
	var parsed := _read_source(external["path"], state)
	if not parsed.get("success", false): return parsed
	for section in parsed["sections"]:
		if section["kind"] == "resource": return {"success": true, "section": section, "source": parsed}
	return _error("External animation resource has no native resource body.")


static func _reference_map(raw: String) -> Dictionary:
	if raw.to_utf8_buffer().size() > 64 * 1024: return _error("Animation resource map exceeds its 64 KiB limit.")
	raw = raw.strip_edges()
	if not raw.begins_with("{") or not raw.ends_with("}"): return _error("Animation resource map must be a dictionary.")
	var body := raw.substr(1, raw.length() - 2)
	var expression := RegEx.new()
	expression.compile('&?("(?:[^"\\\\]|\\\\.)*")\\s*:\\s*((?:SubResource|ExtResource)\\("(?:[^"\\\\]|\\\\.)*"\\))')
	var matches := expression.search_all(body)
	if matches.size() > MAX_ANIMATIONS: return _error("Animation resource map exceeds its reference count limit.")
	if matches.is_empty() and not body.strip_edges().is_empty(): return _error("Animation resource map contains no valid resource entries.")
	var mapping := {}
	var cursor := 0
	for index in range(matches.size()):
		var match: RegExMatch = matches[index]
		var gap := body.substr(cursor, match.get_start() - cursor).strip_edges()
		if gap != ("" if index == 0 else ","): return _error("Animation resource map contains an unsupported entry.")
		var key = JSON.parse_string(match.get_string(1))
		if typeof(key) != TYPE_STRING or key.length() > 128 or mapping.has(key): return _error("Animation resource map contains a duplicate or invalid name.")
		mapping[key] = match.get_string(2)
		cursor = match.get_end()
	if body.substr(cursor).strip_edges() not in ["", ","]: return _error("Animation resource map contains a non-resource value.")
	return {"success": true, "value": mapping}


static func _literal(raw: String) -> Dictionary:
	if raw.to_utf8_buffer().size() > 64 * 1024: return _error("An animation literal exceeds the 64 KiB decode limit. Large packed tracks are unsupported.")
	# VariantParser can construct Objects. Admit only explicit non-object literal
	# constructors, skipping quoted content so labels remain original data.
	var cursor := 0
	var nesting := 0
	while cursor < raw.length():
		var character := raw.substr(cursor, 1)
		if character == '"':
			cursor += 1
			var closed := false
			while cursor < raw.length():
				if raw.substr(cursor, 1) == "\\": cursor += 2
				elif raw.substr(cursor, 1) == '"':
					cursor += 1
					closed = true
					break
				else: cursor += 1
			if not closed: return _error("Unterminated animation literal string.")
			continue
		if character in ["(", "[", "{"]:
			nesting += 1
			if nesting > 16: return _error("Animation literals exceed the nesting limit.")
		elif character in [")", "]", "}"]: nesting -= 1
		if character.is_valid_identifier() and not character.is_valid_int():
			var start := cursor
			while cursor < raw.length() and (raw.substr(cursor, 1).is_valid_identifier() or raw.substr(cursor, 1).is_valid_int()): cursor += 1
			var word := raw.substr(start, cursor - start)
			if word not in LITERAL_TYPES and word not in ["e", "E"]: return _error("Animation data contains an unsupported executable or resource literal.")
			continue
		cursor += 1
	if nesting != 0: return _error("Animation literal delimiters are incomplete.")
	var config := ConfigFile.new()
	if config.parse("[animation]\nvalue = " + raw) != OK: return _error("Animation data could not be decoded as a native Variant literal.")
	return {"success": true, "value": config.get_value("animation", "value")}


static func _decode_animation(section: Dictionary, state: Dictionary, decode_keys: bool = true, selected_track: int = -1) -> Dictionary:
	if section["fields"].get("type") != "Animation" or section["properties"].has("script"): return _error("Only unscripted native Animation resources are supported.")
	var properties: Dictionary = section["properties"]
	if properties.has("compression"): return _error("Compressed animation tracks are not supported by saved-source inspection.")
	var animation := Animation.new()
	for scalar in ["length", "step", "loop_mode"]:
		if not properties.has(scalar): continue
		var literal := _literal(properties[scalar])
		if not literal.get("success", false): return literal
		var value = literal["value"]
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)) or float(value) < 0 or float(value) > 1000000: return _error("Invalid animation scalar.")
		if scalar == "loop_mode" and (float(value) != floorf(float(value)) or float(value) > 2): return _error("Invalid animation loop mode.")
		animation.set(scalar, value)
	for track in range(MAX_TRACKS):
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation decoding reached its time limit.")
		var prefix := "tracks/%d/" % track
		if not properties.has(prefix + "type"): break
		var type := _literal(properties[prefix + "type"])
		if not type.get("success", false): return type
		var track_type := TRACK_TYPES.find(type["value"]) if typeof(type["value"]) == TYPE_STRING else -1
		if typeof(type["value"]) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(type["value"])) and float(type["value"]) == floorf(float(type["value"])) and float(type["value"]) >= 0 and float(type["value"]) < TRACK_TYPES.size(): track_type = int(type["value"])
		if track_type < 0: return _error("Unsupported animation track type.")
		animation.add_track(track_type)
		for field in ["path", "interp", "loop_wrap", "enabled", "imported", "keys"]:
			if not properties.has(prefix + field): continue
			if field == "keys" and (not decode_keys or (selected_track >= 0 and selected_track != track)): continue
			var literal := _literal(properties[prefix + field])
			if not literal.get("success", false): return literal
			var value = literal["value"]
			if field == "path" and typeof(value) != TYPE_NODE_PATH: return _error("Track path must be a NodePath.")
			if field in ["loop_wrap", "enabled", "imported"] and typeof(value) != TYPE_BOOL: return _error("Track flags must be booleans.")
			if field == "interp" and (typeof(value) not in [TYPE_INT, TYPE_FLOAT] or float(value) != floorf(float(value)) or float(value) < 0 or float(value) > 4): return _error("Track interpolation must be a supported integer.")
			if field == "keys" and typeof(value) not in [TYPE_DICTIONARY, TYPE_PACKED_FLOAT32_ARRAY]: return _error("Track keys must be a native serialized key dictionary or packed floats.")
			if field == "keys":
				var key_error := _key_data_error(value, track_type)
				if not key_error.is_empty(): return _error(key_error)
			animation.set(prefix + field, value)
		if animation.track_get_key_count(track) > MAX_KEY_SCAN: return _error("Animation track exceeds the 8192-key scan limit.")
	if properties.has("tracks/%d/type" % MAX_TRACKS): return _error("Animation exceeds the 128-track limit.")
	for property in properties:
		if Time.get_ticks_msec() >= state["deadline"]: return _error("Animation property inspection reached its time limit.")
		if str(property).begins_with("tracks/"):
			var index_text := str(property).get_slice("/", 1)
			if not index_text.is_valid_int() or int(index_text) < 0 or int(index_text) >= animation.get_track_count(): return _error("Saved animation tracks are incomplete or noncontiguous.")
			if str(property).get_slice("/", 2) not in ["type", "path", "interp", "loop_wrap", "enabled", "imported", "keys"]: return _error("Saved animation contains an unsupported track field.")
	return {"success": true, "animation": animation}


static func _key_data_error(value, track_type: int) -> String:
	if typeof(value) == TYPE_PACKED_FLOAT32_ARRAY:
		var stride := 6 if track_type == 2 else 3 if track_type == 4 else 5
		if track_type not in [1, 2, 3, 4] or value.size() % stride != 0 or value.size() / stride > MAX_KEY_SCAN: return "Packed animation keys have an unsupported shape."
		for number in value:
			if not is_finite(number): return "Animation key data contains non-finite values."
		return ""
	if track_type == 6:
		if typeof(value.get("times")) != TYPE_PACKED_FLOAT32_ARRAY or typeof(value.get("points")) != TYPE_PACKED_FLOAT32_ARRAY or typeof(value.get("handle_modes")) != TYPE_PACKED_INT32_ARRAY: return "Bezier keys require native times, points and handle modes."
		var count: int = value["times"].size()
		if count > MAX_KEY_SCAN or value["points"].size() != count * 5 or value["handle_modes"].size() != count: return "Bezier key arrays have mismatched lengths."
		var previous := -1.0
		for time in value["times"]:
			if not is_finite(time) or time < 0 or time < previous: return "Bezier key times are not finite and sorted."
			previous = time
		for point in value["points"]:
			if not is_finite(point): return "Bezier key data contains non-finite values."
		for mode in value["handle_modes"]:
			if mode < 0 or mode > 3: return "Bezier handle mode is unsupported."
		return ""
	if track_type == 8:
		if typeof(value.get("times")) != TYPE_PACKED_FLOAT32_ARRAY or typeof(value.get("clips")) != TYPE_PACKED_STRING_ARRAY: return "Animation keys require native times and clip names."
		if value["times"].size() > MAX_KEY_SCAN or value["times"].size() != value["clips"].size(): return "Animation clip arrays have mismatched lengths."
		var previous := -1.0
		for time in value["times"]:
			if not is_finite(time) or time < 0 or time < previous: return "Animation clip times are not finite and sorted."
			previous = time
		return ""
	if typeof(value.get("times")) != TYPE_PACKED_FLOAT32_ARRAY or typeof(value.get("transitions")) != TYPE_PACKED_FLOAT32_ARRAY or not value.has("values"): return "Animation key dictionaries require native times, transitions and values."
	var times: PackedFloat32Array = value["times"]
	var transitions: PackedFloat32Array = value["transitions"]
	if times.size() > MAX_KEY_SCAN or times.size() != transitions.size(): return "Animation key arrays exceed bounds or have mismatched lengths."
	var previous := -1.0
	for index in range(times.size()):
		if not is_finite(times[index]) or times[index] < 0 or times[index] < previous or not is_finite(transitions[index]): return "Animation key times/transitions are not finite and sorted."
		previous = times[index]
	var values = value["values"]
	if typeof(values) not in [TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY]: return "Animation key values use an unsupported collection."
	if values.size() != times.size() * (5 if track_type == 6 else 1): return "Animation key values and times have mismatched lengths."
	if value.has("update") and (typeof(value["update"]) not in [TYPE_INT, TYPE_FLOAT] or float(value["update"]) != floorf(float(value["update"])) or float(value["update"]) < 0 or float(value["update"]) > 2): return "Animation update mode is unsupported."
	return ""


static func _tracks(animation: Animation, player: Dictionary, nodes: Dictionary, has_instances: bool, arguments: Dictionary, state: Dictionary) -> Dictionary:
	if arguments.has("track_index") and int(arguments["track_index"]) >= animation.get_track_count(): return _error("track_index does not exist in this animation.")
	var tracks: Array = []
	var remaining := int(arguments.get("max_keys", MAX_KEYS))
	var scanned := 0
	var output_bytes := 2048
	for track in range(animation.get_track_count()):
		if arguments.has("track_index") and track != int(arguments["track_index"]): continue
		var path: NodePath = animation.track_get_path(track)
		var target := _resolve_target(str(player["player_path"]), str(player["root_node"]), str(path.get_concatenated_names()))
		var status := "serialized_node" if nodes.has(target) else "not_locally_serialized" if has_instances else "not_found_in_saved_scene"
		if target.is_empty() or str(path.get_concatenated_names()).begins_with("/") or str(path.get_concatenated_names()).contains("%") or str(player["root_node"]).begins_with("/") or str(player["root_node"]).contains("%") or str(player["root_node"]).contains(":"):
			status = "unresolved_path"
			target = ""
		var record := {"index": track, "type": TRACK_TYPES[animation.track_get_type(track)], "path": str(path), "target_node_path": target, "target_status": status, "enabled": animation.track_is_enabled(track), "interpolation": animation.track_get_interpolation_type(track), "key_count": animation.track_get_key_count(track), "keys": []}
		output_bytes += JSON.stringify(record).to_utf8_buffer().size() * 2
		if output_bytes > MAX_OUTPUT_BYTES: return _error("Animation track metadata exceeds the output limit. Select track_index.")
		for key in range(animation.track_get_key_count(track)):
			if scanned >= MAX_KEY_SCAN or Time.get_ticks_msec() >= state["deadline"]:
				_reason(state, "key_scan_limit" if scanned >= MAX_KEY_SCAN else "time_limit")
				break
			scanned += 1
			var time := animation.track_get_key_time(track, key)
			if time < float(arguments.get("start_time", 0)) or time > float(arguments.get("end_time", 1000000)): continue
			if remaining <= 0:
				_reason(state, "key_limit")
				continue
			var key_record := {"index": key, "time": time, "transition": animation.track_get_key_transition(track, key), "value": _key_value(animation.track_get_key_value(track, key), 0, {"remaining": MAX_VALUE_NODES})}
			output_bytes += JSON.stringify(key_record).to_utf8_buffer().size() * 2
			if output_bytes > MAX_OUTPUT_BYTES: return _error("Animation key output exceeds its limit. Narrow the track/time range or max_keys.")
			record["keys"].append(key_record)
			remaining -= 1
		tracks.append(record)
	return {"success": true, "tracks": tracks}


static func _key_value(value, depth: int, budget: Dictionary):
	if budget["remaining"] <= 0 or depth >= SceneInspector.MAX_VARIANT_DEPTH:
		return {"type": type_string(typeof(value)), "truncated": true, "reason": "value_node_limit"}
	budget["remaining"] -= 1
	if typeof(value) == TYPE_ARRAY:
		var items: Array = []
		for index in range(mini(value.size(), SceneInspector.MAX_COLLECTION_ITEMS)):
			if budget["remaining"] <= 0: break
			items.append(_key_value(value[index], depth + 1, budget))
		return {"type": "Array", "size": value.size(), "items": items, "truncated": items.size() < value.size()}
	if typeof(value) == TYPE_DICTIONARY:
		var entries: Array = []
		for key in value:
			if entries.size() >= SceneInspector.MAX_COLLECTION_ITEMS or budget["remaining"] <= 1: break
			entries.append({"key": _key_value(key, depth + 1, budget), "value": _key_value(value[key], depth + 1, budget)})
		return {"type": "Dictionary", "size": value.size(), "entries": entries, "truncated": entries.size() < value.size()}
	return SceneInspector._summarize_variant(value, depth)


static func _resolve_target(player: String, root: String, target: String) -> String:
	var parts: Array = [] if player == "." else Array(player.split("/"))
	for component in (root + "/" + target).split("/", false):
		if component == ".": continue
		if component == "..":
			if parts.is_empty(): return ""
			parts.pop_back()
		else: parts.append(component)
	return "." if parts.is_empty() else "/".join(parts)


static func _node_path(fields: Dictionary) -> String:
	if not fields.has("parent"): return "."
	var parent := str(fields["parent"]).trim_prefix("./")
	return str(fields["name"]) if parent == "." else parent.path_join(str(fields["name"]))


static func _reason(state: Dictionary, reason: String) -> void:
	if reason not in state["reasons"]: state["reasons"].append(reason)


static func _error(message: String) -> Dictionary:
	return {"success": false, "error": message}
