@tool
extends RefCounted

const MAX_SETTING_PATH_CHARS := 256
const MAX_INPUT_ACTIONS := 64
const MAX_INPUT_EVENTS_PER_ACTION := 12
const MAX_AUTOLOADS := 64
const MAX_PROPERTY_SCAN := 4096
const MAX_COLLECTION_ITEMS := 16
const MAX_VARIANT_DEPTH := 3
const MAX_STRING_CHARS := 256
const MAX_OUTPUT_BYTES := 64 * 1024

const WINDOW_SETTINGS := [
	"display/window/size/viewport_width",
	"display/window/size/viewport_height",
	"display/window/size/window_width_override",
	"display/window/size/window_height_override",
	"display/window/size/mode",
	"display/window/stretch/mode",
	"display/window/stretch/aspect",
	"display/window/handheld/orientation",
	"display/window/vsync/vsync_mode"
]
const RENDERING_SETTINGS := [
	"rendering/renderer/rendering_method",
	"rendering/renderer/rendering_method.mobile",
	"rendering/rendering_device/driver",
	"rendering/textures/default_filters/use_nearest_mipmap_filter"
]
const PHYSICS_SETTINGS := [
	"physics/common/physics_ticks_per_second",
	"physics/common/max_physics_steps_per_frame",
	"physics/2d/default_gravity",
	"physics/2d/default_gravity_vector",
	"physics/3d/default_gravity",
	"physics/3d/default_gravity_vector"
]
const APPLICATION_SETTINGS := [
	"application/config/name",
	"application/config/features",
	"application/config/icon",
	"application/run/main_scene"
]
const SENSITIVE_SEGMENTS := [
	"api_key",
	"apikey",
	"access_key",
	"auth_token",
	"client_secret",
	"credential",
	"password",
	"passwd",
	"private_key",
	"secret",
	"token"
]


static func inspect(setting_path: String = "") -> Dictionary:
	if setting_path.is_empty():
		return _inspect_summary()
	var validation_error := validate_setting_path(setting_path)
	if not validation_error.is_empty():
		return {"success": false, "error": validation_error}
	if not ProjectSettings.has_setting(setting_path):
		return {"success": false, "error": "Project setting does not exist: " + setting_path}
	var value = ProjectSettings.get_setting_with_override(setting_path)
	var setting := _typed_value(value)
	if setting_path.begins_with("input/"):
		if typeof(value) != TYPE_DICTIONARY:
			return {"success": false, "error": "Input action settings must contain Godot's action dictionary shape."}
		setting = {"type": "InputAction", "value": _input_action(setting_path)}
	elif setting_path.begins_with("autoload/") and not _is_valid_autoload_value(value):
		return {"success": false, "error": "Autoload settings must contain a bounded res:// resource path string."}
	var report := {
		"source": "effective_project_settings",
		"setting_path": setting_path,
		"setting": setting,
		"note": "The value is read from Godot's in-memory ProjectSettings state and may include editor overrides."
	}
	return {"success": true, "content": _serialize_explicit(report), "report": report}


static func validate_setting_path(setting_path: String) -> String:
	if setting_path.is_empty():
		return "setting_path cannot be empty when requesting one setting."
	if setting_path.length() > MAX_SETTING_PATH_CHARS:
		return "setting_path exceeds the 256 character limit."
	if setting_path.begins_with("/") or setting_path.ends_with("/") or setting_path.contains("//") or setting_path.contains(".."):
		return "setting_path is malformed."
	for character in setting_path:
		if character.unicode_at(0) < 32:
			return "setting_path contains control characters."
	if _is_sensitive_name(setting_path):
		return "This setting path may contain credentials or secrets and cannot be inspected."
	if setting_path not in APPLICATION_SETTINGS and setting_path not in WINDOW_SETTINGS and setting_path not in RENDERING_SETTINGS and setting_path not in PHYSICS_SETTINGS and not setting_path.begins_with("input/") and not setting_path.begins_with("autoload/"):
		return "Explicit reads are limited to allowlisted application, display/window, input, autoload, rendering, and physics settings."
	return ""


static func _inspect_summary() -> Dictionary:
	var reasons := PackedStringArray()
	var property_list := ProjectSettings.get_property_list()
	if property_list.size() > MAX_PROPERTY_SCAN:
		reasons.append("property_scan_limit")
	var input_names := PackedStringArray()
	var autoload_names := PackedStringArray()
	for index in range(mini(property_list.size(), MAX_PROPERTY_SCAN)):
		var property = property_list[index]
		if typeof(property) != TYPE_DICTIONARY:
			continue
		var name := str(property.get("name", ""))
		if _is_sensitive_name(name):
			_add_reason(reasons, "sensitive_path_omitted")
			continue
		if name.begins_with("input/"):
			input_names.append(name)
		elif name.begins_with("autoload/"):
			autoload_names.append(name)
	input_names.sort()
	autoload_names.sort()

	var actions: Array[Dictionary] = []
	for index in range(mini(input_names.size(), MAX_INPUT_ACTIONS)):
		actions.append(_input_action(input_names[index]))
	if input_names.size() > actions.size():
		_add_reason(reasons, "input_action_limit")

	var autoloads: Array[Dictionary] = []
	for index in range(mini(autoload_names.size(), MAX_AUTOLOADS)):
		var path := autoload_names[index]
		var value = ProjectSettings.get_setting_with_override(path)
		autoloads.append({
			"name": path.trim_prefix("autoload/"),
			"setting_path": path,
			"setting": _typed_value(value) if _is_valid_autoload_value(value) else {"type": type_string(typeof(value)), "value": {"redacted": true, "reason": "invalid_autoload_shape"}}
		})
	if autoload_names.size() > autoloads.size():
		_add_reason(reasons, "autoload_limit")

	var report := {
		"source": "effective_project_settings",
		"note": "Bounded overview of selected effective settings. This is not an enumeration of all project settings.",
		"application": _entries_for_paths(APPLICATION_SETTINGS.slice(0, 3)),
		"main_scene": _setting_entry("application/run/main_scene"),
		"window": _entries_for_paths(WINDOW_SETTINGS),
		"input_action_count": input_names.size(),
		"returned_input_action_count": actions.size(),
		"input_actions": actions,
		"autoload_count": autoload_names.size(),
		"returned_autoload_count": autoloads.size(),
		"autoloads": autoloads,
		"rendering": _entries_for_paths(RENDERING_SETTINGS),
		"physics": _entries_for_paths(PHYSICS_SETTINGS),
		"truncation": {"truncated": not reasons.is_empty(), "reasons": Array(reasons)}
	}
	var content := _fit_and_serialize(report)
	return {"success": true, "content": content, "report": report}


static func _input_action(path: String) -> Dictionary:
	var value = ProjectSettings.get_setting_with_override(path)
	var action := {"name": path.trim_prefix("input/"), "setting_path": path, "deadzone": 0.5, "events": [], "event_count": 0}
	if typeof(value) != TYPE_DICTIONARY:
		action["invalid_shape"] = true
		return action
	var deadzone = value.get("deadzone", 0.5)
	action["deadzone"] = deadzone if typeof(deadzone) in [TYPE_INT, TYPE_FLOAT] else {"redacted": true, "reason": "invalid_deadzone"}
	var raw_events = value.get("events", [])
	if typeof(raw_events) != TYPE_ARRAY:
		return action
	action["event_count"] = raw_events.size()
	var events: Array[Dictionary] = []
	for index in range(mini(raw_events.size(), MAX_INPUT_EVENTS_PER_ACTION)):
		var event = raw_events[index]
		if event is InputEvent:
			events.append({"type": event.get_class(), "text": _bounded_string(event.as_text()), "device": event.device})
		else:
			events.append({"type": type_string(typeof(event)), "redacted": true, "reason": "invalid_input_event"})
	action["events"] = events
	action["events_truncated"] = events.size() < raw_events.size()
	return action


static func _entries_for_paths(paths: Array) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for path in paths:
		if ProjectSettings.has_setting(path):
			entries.append(_setting_entry(path))
	return entries


static func _setting_entry(path: String) -> Dictionary:
	return {"setting_path": path, "setting": _typed_value(ProjectSettings.get_setting_with_override(path))}


static func _typed_value(value) -> Dictionary:
	return {"type": type_string(typeof(value)), "value": _summarize_variant(value, 0)}


static func _summarize_variant(value, depth: int):
	var value_type := typeof(value)
	match value_type:
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else str(value)
		TYPE_STRING:
			return _bounded_string(value)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return _bounded_string(str(value))
		TYPE_ARRAY:
			return _summarize_array(value, depth)
		TYPE_DICTIONARY:
			return _summarize_dictionary(value, depth)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			return _summarize_array(Array(value), depth)
		TYPE_OBJECT:
			if value is Resource:
				return {"class": value.get_class(), "path": _bounded_string(value.resource_path), "name": _bounded_string(value.resource_name)}
			return {"class": value.get_class() if value != null else ""}
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return {"type": type_string(value_type)}
		_:
			return _bounded_string(str(value))


static func _summarize_array(value: Array, depth: int) -> Dictionary:
	if depth >= MAX_VARIANT_DEPTH:
		return {"size": value.size(), "items": [], "truncated": true, "reason": "depth_limit"}
	var items: Array = []
	for index in range(mini(value.size(), MAX_COLLECTION_ITEMS)):
		items.append(_summarize_variant(value[index], depth + 1))
	return {"size": value.size(), "items": items, "truncated": items.size() < value.size()}


static func _summarize_dictionary(value: Dictionary, depth: int) -> Dictionary:
	if depth >= MAX_VARIANT_DEPTH:
		return {"size": value.size(), "entries": [], "truncated": true, "reason": "depth_limit"}
	var entries: Array[Dictionary] = []
	var keys := value.keys()
	for index in range(mini(keys.size(), MAX_COLLECTION_ITEMS)):
		var key = keys[index]
		entries.append({
			"key": _summarize_variant(key, depth + 1),
			"value": {"redacted": true} if _is_sensitive_name(str(key)) else _summarize_variant(value[key], depth + 1)
		})
	return {"size": value.size(), "entries": entries, "truncated": entries.size() < value.size()}


static func _fit_and_serialize(report: Dictionary) -> String:
	var content := JSON.stringify(report, "  ")
	while content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		var reduced := false
		var actions: Array = report.get("input_actions", [])
		for index in range(actions.size() - 1, -1, -1):
			if not actions[index].get("events", []).is_empty():
				actions[index]["events"] = []
				actions[index]["events_truncated"] = true
				reduced = true
				break
		if not reduced and not actions.is_empty():
			actions.pop_back()
			report["returned_input_action_count"] = actions.size()
			reduced = true
		if not reduced and not report.get("autoloads", []).is_empty():
			report["autoloads"].pop_back()
			report["returned_autoload_count"] = report["autoloads"].size()
			reduced = true
		if not reduced:
			for section in ["window", "physics", "rendering", "application"]:
				if not report.get(section, []).is_empty():
					report[section].pop_back()
					reduced = true
					break
		if not reduced and not report.get("main_scene", {}).is_empty():
			report["main_scene"] = {"truncated": true, "reason": "output_limit"}
			reduced = true
		_add_reason_to_report(report, "output_limit")
		content = JSON.stringify(report, "  ")
		if not reduced:
			break
	return content


static func _serialize_explicit(report: Dictionary) -> String:
	var content := JSON.stringify(report, "  ")
	if content.to_utf8_buffer().size() <= MAX_OUTPUT_BYTES:
		return content
	var setting: Dictionary = report.get("setting", {})
	report["setting"] = {
		"type": str(setting.get("type", "Variant")),
		"value": {"truncated": true, "reason": "output_limit"}
	}
	report["truncation"] = {"truncated": true, "reasons": ["output_limit"]}
	return JSON.stringify(report, "  ")


static func _bounded_string(value: String):
	if value.length() <= MAX_STRING_CHARS:
		return value
	return {"value": value.left(MAX_STRING_CHARS), "truncated": true, "original_characters": value.length()}


static func _is_sensitive_name(value: String) -> bool:
	var normalized := value.to_lower().replace("-", "_").replace(".", "_")
	for segment in SENSITIVE_SEGMENTS:
		if segment in normalized:
			return true
	return false


static func _is_valid_autoload_value(value) -> bool:
	if typeof(value) != TYPE_STRING or value.length() > 512 or value.contains("\n") or value.contains("\r"):
		return false
	var resource_path: String = value.trim_prefix("*")
	return resource_path.begins_with("res://") and resource_path.length() > "res://".length()


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
