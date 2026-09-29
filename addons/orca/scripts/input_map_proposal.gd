@tool
extends RefCounted

const MAX_PROJECT_FILE_BYTES := 2 * 1024 * 1024
const MAX_CHANGES := 16
const MAX_ACTION_NAME_CHARS := 64
const MAX_EVENTS_PER_ACTION := 16
const MAX_INPUT_ACTIONS := 256
const PROJECT_PATH := "res://project.godot"
const EVENT_TYPES := ["key", "mouse_button", "joypad_button", "joypad_motion"]


static func prepare(change_id: String, base_hash: String, raw_changes, check_live: bool = true, filepath: String = PROJECT_PATH) -> Dictionary:
	if typeof(raw_changes) != TYPE_ARRAY:
		return _failure("changes must be an array.")
	if raw_changes.is_empty() or raw_changes.size() > MAX_CHANGES:
		return _failure("changes must contain between 1 and %d items." % MAX_CHANGES)
	var read_result := _read_project_file(filepath)
	if not read_result.get("success", false):
		return read_result
	var old_content: String = read_result["content"]
	if _has_mixed_line_endings(old_content):
		return _failure("project.godot uses mixed LF and CRLF line endings. Normalize it before proposing Input Map changes so unrelated bytes remain untouched.")
	if base_hash != old_content.sha256_text():
		return _failure("base_hash does not match project.godot. Read it again before proposing Input Map changes.")
	var old_config_result := _parse_config(old_content)
	if not old_config_result.get("success", false):
		return old_config_result
	var old_config: ConfigFile = old_config_result["config"]
	var normalized_result := _normalize_changes(raw_changes)
	if not normalized_result.get("success", false):
		return normalized_result
	var changes: Array = normalized_result["changes"]
	var action_names := PackedStringArray()
	for change in changes:
		action_names.append(change["action"])
	if check_live:
		var live_error := validate_live_against_config(old_config, action_names)
		if not live_error.is_empty():
			return _failure(live_error)

	var old_values := {}
	var new_values := {}
	var review: Array[Dictionary] = []
	for change in changes:
		var action: String = change["action"]
		var existed := old_config.has_section_key("input", action)
		var old_value = old_config.get_value("input", action) if existed else null
		old_values[action] = old_value
		var before: Variant = _summarize_action(old_value) if existed else null
		if change["operation"] == "remove":
			new_values[action] = null
			review.append({"operation": "remove", "action": action, "before": before, "after": null})
		else:
			var new_value := _build_action_value(change)
			new_values[action] = new_value
			review.append({"operation": "add" if not existed else "update", "action": action, "before": before, "after": _summarize_action(new_value)})

	var materialized := _materialize_changes(old_content, changes, new_values)
	if not materialized.get("success", false):
		return materialized
	var new_content: String = materialized["content"]
	var candidate_result := _parse_config(new_content)
	if not candidate_result.get("success", false):
		return _failure("The proposed project.godot did not pass ConfigFile validation.")
	var candidate_config_check: ConfigFile = candidate_result["config"]
	var verify_error := _verify_requested_values(candidate_config_check, new_values)
	if not verify_error.is_empty():
		return _failure(verify_error)
	var unrelated_error := _verify_unrelated_actions(old_config, candidate_config_check, action_names)
	if not unrelated_error.is_empty():
		return _failure(unrelated_error)
	return {
		"success": true,
		"id": change_id,
		"kind": "input_map",
		"tool_name": "propose_input_map_changes",
		"filepath": filepath,
		"existed": true,
		"old_content": old_content,
		"new_content": new_content,
		"old_hash": old_content.sha256_text(),
		"new_hash": new_content.sha256_text(),
		"changes": changes,
		"action_names": Array(action_names),
		"old_values": old_values,
		"new_values": new_values,
		"review": review,
		"validation": {"valid": true, "message": "Parsed and verified project.godot Input Map state."},
		"status": "pending",
		"no_changes": new_content == old_content
	}


static func validate_current(proposal: Dictionary, expect_new: bool) -> String:
	if str(proposal.get("filepath", "")) != PROJECT_PATH:
		return "Input Map proposals are restricted to res://project.godot."
	var read_result := _read_project_file(PROJECT_PATH)
	if not read_result.get("success", false):
		return str(read_result.get("error", "Could not read project.godot."))
	var content: String = read_result["content"]
	var expected_hash := str(proposal.get("new_hash" if expect_new else "old_hash", ""))
	if content.sha256_text() != expected_hash:
		return "project.godot changed after this proposal was prepared. Review a fresh proposal."
	var config_result := _parse_config(content)
	if not config_result.get("success", false):
		return str(config_result.get("error", "project.godot is not valid."))
	var values: Dictionary = proposal.get("new_values" if expect_new else "old_values", {})
	var verify_error := _verify_requested_values(config_result["config"], values)
	if not verify_error.is_empty():
		return verify_error
	if expect_new and proposal.get("recovery_required", false):
		return ""
	return validate_live_against_config(config_result["config"], PackedStringArray(proposal.get("action_names", [])))


static func validate_candidate(proposal: Dictionary) -> String:
	if str(proposal.get("old_content", "")).sha256_text() != str(proposal.get("old_hash", "")):
		return "The retained original project.godot bytes no longer match the reviewed base hash."
	if str(proposal.get("new_content", "")).sha256_text() != str(proposal.get("new_hash", "")):
		return "The retained Input Map candidate no longer matches the reviewed hash."
	var candidate_result := _parse_config(str(proposal.get("new_content", "")))
	if not candidate_result.get("success", false):
		return "The retained Input Map candidate is no longer valid project.godot content."
	return _verify_requested_values(candidate_result["config"], proposal.get("new_values", {}))


static func sync_live(values: Dictionary) -> String:
	for action in values:
		var path := "input/" + str(action)
		ProjectSettings.set_setting(path, values[action])
	InputMap.load_from_project_settings()
	for action in values:
		var value = values[action]
		if value == null:
			if InputMap.has_action(str(action)):
				return "InputMap still contains removed action '%s'." % action
		elif not InputMap.has_action(str(action)):
			return "InputMap did not load action '%s'." % action
		elif JSON.stringify(_summarize_input_map_action(str(action))) != JSON.stringify(_summarize_action(value)):
			return "InputMap loaded a different value for action '%s'." % action
	return ""


static func sync_live_from_content(content: String, action_names: Array) -> String:
	var config_result := _parse_config(content)
	if not config_result.get("success", false):
		return str(config_result.get("error", "Could not parse the current project.godot."))
	var config: ConfigFile = config_result["config"]
	var values := {}
	for action in action_names:
		values[action] = config.get_value("input", action) if config.has_section_key("input", action) else null
	return sync_live(values)


static func validate_live_against_config(config: ConfigFile, action_names: PackedStringArray) -> String:
	for action in action_names:
		var disk_has := config.has_section_key("input", action)
		var live_path := "input/" + action
		var live_has := ProjectSettings.has_setting(live_path)
		if disk_has != live_has:
			return "The live Input Map state for '%s' differs from project.godot. Save or close Project Settings and retry." % action
		if disk_has:
			var disk_summary: Variant = _summarize_action(config.get_value("input", action))
			var live_summary: Variant = _summarize_action(ProjectSettings.get_setting(live_path))
			if JSON.stringify(disk_summary) != JSON.stringify(live_summary):
				return "The live Input Map state for '%s' differs from project.godot. Save or close Project Settings and retry." % action
	return ""


static func _normalize_changes(raw_changes: Array) -> Dictionary:
	var changes: Array[Dictionary] = []
	var seen := {}
	for index in range(raw_changes.size()):
		var raw = raw_changes[index]
		if typeof(raw) != TYPE_DICTIONARY:
			return _failure("changes[%d] must be an object." % index)
		for key in raw:
			if str(key) not in ["operation", "action", "deadzone", "events"]:
				return _failure("Unknown field in changes[%d]: %s" % [index, key])
		if typeof(raw.get("operation")) != TYPE_STRING or str(raw.get("operation")) not in ["upsert", "remove"]:
			return _failure("changes[%d].operation must be upsert or remove." % index)
		if typeof(raw.get("action")) != TYPE_STRING:
			return _failure("changes[%d].action must be a string." % index)
		var action := str(raw["action"])
		if not _valid_action_name(action):
			return _failure("Action names must be 1-%d characters using letters, numbers, underscore, period, or hyphen." % MAX_ACTION_NAME_CHARS)
		if seen.has(action):
			return _failure("Each Input Map action may appear only once per proposal: " + action)
		seen[action] = true
		var normalized := {"operation": str(raw["operation"]), "action": action}
		if normalized["operation"] == "remove":
			if raw.has("deadzone") or raw.has("events"):
				return _failure("Remove operations accept only operation and action.")
		else:
			var deadzone = raw.get("deadzone", 0.5)
			if typeof(deadzone) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(deadzone)) or float(deadzone) < 0.0 or float(deadzone) > 1.0:
				return _failure("changes[%d].deadzone must be between 0 and 1." % index)
			var events = raw.get("events", [])
			if typeof(events) != TYPE_ARRAY or events.size() > MAX_EVENTS_PER_ACTION:
				return _failure("changes[%d].events must contain at most %d events." % [index, MAX_EVENTS_PER_ACTION])
			var normalized_events: Array[Dictionary] = []
			for event_index in range(events.size()):
				var event_result := _normalize_event(events[event_index], index, event_index)
				if not event_result.get("success", false):
					return event_result
				normalized_events.append(event_result["event"])
			normalized["deadzone"] = float(deadzone)
			normalized["events"] = normalized_events
		changes.append(normalized)
	return {"success": true, "changes": changes}


static func _normalize_event(raw, change_index: int, event_index: int) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return _failure("changes[%d].events[%d] must be an object." % [change_index, event_index])
	var type = raw.get("type")
	if typeof(type) != TYPE_STRING or str(type) not in EVENT_TYPES:
		return _failure("Unsupported event type at changes[%d].events[%d]." % [change_index, event_index])
	var allowed := ["type", "device"]
	if type == "key":
		allowed.append_array(["keycode", "physical_keycode", "unicode", "ctrl", "alt", "shift", "meta"])
	elif type == "mouse_button":
		allowed.append_array(["button_index", "ctrl", "alt", "shift", "meta"])
	elif type == "joypad_button":
		allowed.append("button_index")
	else:
		allowed.append_array(["axis", "axis_value"])
	for key in raw:
		if str(key) not in allowed:
			return _failure("Unknown event field at changes[%d].events[%d]: %s" % [change_index, event_index, key])
	var event := {"type": str(type), "device": int(raw.get("device", -1))}
	if typeof(raw.get("device", -1)) != TYPE_INT or event["device"] < -1 or event["device"] > 31:
		return _failure("Event device must be an integer from -1 to 31.")
	if type == "key":
		for field in ["keycode", "physical_keycode", "unicode"]:
			if typeof(raw.get(field, 0)) != TYPE_INT or int(raw.get(field, 0)) < 0:
				return _failure("Key event %s must be a non-negative integer." % field)
			event[field] = int(raw.get(field, 0))
		if event["unicode"] > 0x10FFFF or (event["unicode"] >= 0xD800 and event["unicode"] <= 0xDFFF):
			return _failure("Key event unicode must be a valid Unicode scalar value.")
		if event["keycode"] == 0 and event["physical_keycode"] == 0 and event["unicode"] == 0:
			return _failure("Key events require keycode, physical_keycode, or unicode.")
		for field in ["ctrl", "alt", "shift", "meta"]:
			if typeof(raw.get(field, false)) != TYPE_BOOL:
				return _failure("Key modifier %s must be a boolean." % field)
			event[field] = bool(raw.get(field, false))
	elif type in ["mouse_button", "joypad_button"]:
		if typeof(raw.get("button_index")) != TYPE_INT:
			return _failure("Button events require integer button_index.")
		event["button_index"] = int(raw["button_index"])
		var maximum := 9 if type == "mouse_button" else JOY_BUTTON_MAX - 1
		if event["button_index"] < (1 if type == "mouse_button" else 0) or event["button_index"] > maximum:
			return _failure("button_index is outside the supported range.")
		if type == "mouse_button":
			for field in ["ctrl", "alt", "shift", "meta"]:
				if typeof(raw.get(field, false)) != TYPE_BOOL:
					return _failure("Mouse modifier %s must be a boolean." % field)
				event[field] = bool(raw.get(field, false))
	else:
		if typeof(raw.get("axis")) != TYPE_INT or int(raw.get("axis")) < 0 or int(raw.get("axis")) >= JOY_AXIS_MAX:
			return _failure("Joypad motion axis is outside Godot's supported range.")
		if typeof(raw.get("axis_value")) not in [TYPE_INT, TYPE_FLOAT] or float(raw.get("axis_value")) not in [-1.0, 1.0]:
			return _failure("Joypad motion axis_value must be -1 or 1.")
		event["axis"] = int(raw["axis"])
		event["axis_value"] = float(raw["axis_value"])
	return {"success": true, "event": event}


static func _build_action_value(change: Dictionary) -> Dictionary:
	var events: Array = []
	for specification in change.get("events", []):
		events.append(_build_event(specification))
	return {"deadzone": float(change.get("deadzone", 0.5)), "events": events}


static func _build_event(specification: Dictionary) -> InputEvent:
	var event: InputEvent
	match specification["type"]:
		"key":
			var key := InputEventKey.new()
			key.keycode = specification["keycode"]
			key.physical_keycode = specification["physical_keycode"]
			key.unicode = specification["unicode"]
			_set_modifiers(key, specification)
			event = key
		"mouse_button":
			var mouse := InputEventMouseButton.new()
			mouse.button_index = specification["button_index"]
			_set_modifiers(mouse, specification)
			event = mouse
		"joypad_button":
			var button := InputEventJoypadButton.new()
			button.button_index = specification["button_index"]
			event = button
		_:
			var motion := InputEventJoypadMotion.new()
			motion.axis = specification["axis"]
			motion.axis_value = specification["axis_value"]
			event = motion
	event.device = specification["device"]
	return event


static func _set_modifiers(event: InputEventWithModifiers, specification: Dictionary) -> void:
	event.ctrl_pressed = specification.get("ctrl", false)
	event.alt_pressed = specification.get("alt", false)
	event.shift_pressed = specification.get("shift", false)
	event.meta_pressed = specification.get("meta", false)


static func _summarize_action(value):
	if typeof(value) != TYPE_DICTIONARY:
		return {"valid": false, "type": type_string(typeof(value))}
	var events: Array = []
	var raw_events = value.get("events", [])
	if typeof(raw_events) == TYPE_ARRAY:
		for event in raw_events:
			events.append(_summarize_event(event))
	return {"deadzone": snappedf(float(value.get("deadzone", 0.5)), 0.000001), "events": events}


static func _summarize_event(event) -> Dictionary:
	if event is InputEventKey:
		return {"type": "key", "class": event.get_class(), "device": event.device, "keycode": event.keycode, "physical_keycode": event.physical_keycode, "key_label": event.key_label, "unicode": event.unicode, "location": event.location, "ctrl": event.ctrl_pressed, "alt": event.alt_pressed, "shift": event.shift_pressed, "meta": event.meta_pressed, "serialized_hash": var_to_str(event).sha256_text()}
	if event is InputEventMouseButton:
		return {"type": "mouse_button", "class": event.get_class(), "device": event.device, "button_index": event.button_index, "double_click": event.double_click, "ctrl": event.ctrl_pressed, "alt": event.alt_pressed, "shift": event.shift_pressed, "meta": event.meta_pressed, "serialized_hash": var_to_str(event).sha256_text()}
	if event is InputEventJoypadButton:
		return {"type": "joypad_button", "class": event.get_class(), "device": event.device, "button_index": event.button_index, "serialized_hash": var_to_str(event).sha256_text()}
	if event is InputEventJoypadMotion:
		return {"type": "joypad_motion", "class": event.get_class(), "device": event.device, "axis": event.axis, "axis_value": snappedf(event.axis_value, 0.000001), "serialized_hash": var_to_str(event).sha256_text()}
	return {"type": "unsupported", "class": event.get_class() if event is Object else type_string(typeof(event)), "display": event.as_text().left(160) if event is InputEvent else "", "serialized_hash": var_to_str(event).sha256_text()}


static func _summarize_input_map_action(action: String) -> Dictionary:
	var events: Array = []
	for event in InputMap.action_get_events(action):
		events.append(_summarize_event(event))
	return {"deadzone": snappedf(InputMap.action_get_deadzone(action), 0.000001), "events": events}


static func _verify_requested_values(config: ConfigFile, values: Dictionary) -> String:
	for action in values:
		var expected = values[action]
		var exists := config.has_section_key("input", action)
		if expected == null:
			if exists:
				return "Candidate still contains removed action '%s'." % action
		elif not exists or JSON.stringify(_summarize_action(config.get_value("input", action))) != JSON.stringify(_summarize_action(expected)):
			return "Candidate Input Map value did not verify for action '%s'." % action
	return ""


static func _verify_unrelated_actions(old_config: ConfigFile, new_config: ConfigFile, affected: PackedStringArray) -> String:
	var old_keys: PackedStringArray = old_config.get_section_keys("input") if old_config.has_section("input") else PackedStringArray()
	var new_keys: PackedStringArray = new_config.get_section_keys("input") if new_config.has_section("input") else PackedStringArray()
	if old_keys.size() > MAX_INPUT_ACTIONS or new_keys.size() > MAX_INPUT_ACTIONS:
		return "Input Map exceeds the %d action validation limit." % MAX_INPUT_ACTIONS
	for action in old_keys:
		if action in affected:
			continue
		if action not in new_keys or JSON.stringify(_summarize_action(old_config.get_value("input", action))) != JSON.stringify(_summarize_action(new_config.get_value("input", action))):
			return "Candidate changed unrelated Input Map action '%s'." % action
	for action in new_keys:
		if action not in affected and action not in old_keys:
			return "Candidate added unrelated Input Map action '%s'." % action
	return ""


static func _read_project_file(filepath: String) -> Dictionary:
	if not FileAccess.file_exists(filepath):
		return _failure("project.godot does not exist.")
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		return _failure("Could not read project.godot.")
	if file.get_length() > MAX_PROJECT_FILE_BYTES:
		file.close()
		return _failure("project.godot exceeds the 2 MB proposal limit.")
	var content := file.get_as_text()
	file.close()
	return {"success": true, "content": content}


static func _parse_config(content: String) -> Dictionary:
	var config := ConfigFile.new()
	var error := config.parse(content)
	if error != OK:
		return _failure("project.godot could not be parsed as configuration data (error %d)." % error)
	return {"success": true, "config": config}


static func _materialize_changes(content: String, changes: Array, values: Dictionary) -> Dictionary:
	var result := content
	for change in changes:
		var action: String = change["action"]
		var assignment := "" if values[action] == null else _serialize_action_assignment(action, values[action])
		var replacement := _replace_input_entry(result, action, assignment)
		if not replacement.get("success", false):
			return replacement
		result = replacement["content"]
	return {"success": true, "content": result}


static func _serialize_action_assignment(action: String, value) -> String:
	var config := ConfigFile.new()
	config.set_value("input", action, value)
	var lines := config.encode_to_text().replace("\r\n", "\n").split("\n", true)
	var assignment := PackedStringArray()
	var found_section := false
	for line in lines:
		if line.strip_edges() == "[input]":
			found_section = true
		elif found_section and not line.is_empty():
			assignment.append(line)
	return "\n".join(assignment)


static func _replace_input_entry(content: String, action: String, assignment: String) -> Dictionary:
	var crlf := content.contains("\r\n")
	var normalized := content.replace("\r\n", "\n")
	var lines := normalized.split("\n", true)
	var section_start := -1
	var section_end := lines.size()
	for index in range(lines.size()):
		var stripped := lines[index].strip_edges()
		if stripped == "[input]":
			section_start = index
		elif section_start >= 0 and stripped.begins_with("[") and stripped.ends_with("]"):
			section_end = index
			break
	if section_start < 0:
		if assignment.is_empty():
			return {"success": true, "content": content}
		if not lines.is_empty() and not lines[-1].is_empty():
			lines.append("")
		lines.append("[input]")
		lines.append("")
		lines.append_array(assignment.split("\n", true))
		lines.append("")
	else:
		var entry_start := -1
		var entry_end := -1
		for index in range(section_start + 1, section_end):
			if _line_assigns_action(lines[index], action):
				entry_start = index
				entry_end = _input_entry_end(lines, index, section_end)
				break
		if entry_start < 0 and assignment.is_empty():
			return {"success": true, "content": content}
		if entry_start >= 0:
			if entry_end <= entry_start:
				return _failure("Could not locate the complete serialized value for Input Map action '%s'." % action)
			for index in range(entry_end - 1, entry_start - 1, -1):
				lines.remove_at(index)
			section_end -= entry_end - entry_start
			for index in range(assignment.split("\n", true).size() - 1, -1, -1):
				lines.insert(entry_start, assignment.split("\n", true)[index])
		elif not assignment.is_empty():
			var insert_at := section_end
			while insert_at > section_start + 1 and lines[insert_at - 1].is_empty():
				insert_at -= 1
			lines.insert(insert_at, "")
			for index in range(assignment.split("\n", true).size() - 1, -1, -1):
				lines.insert(insert_at, assignment.split("\n", true)[index])
	var result := "\n".join(lines)
	return {"success": true, "content": result.replace("\n", "\r\n") if crlf else result}


static func _input_entry_end(lines: PackedStringArray, start: int, section_end: int) -> int:
	var balance := 0
	var saw_container := false
	var in_string := false
	var escaped := false
	for line_index in range(start, section_end):
		for character in lines[line_index]:
			if escaped:
				escaped = false
				continue
			if character == "\\" and in_string:
				escaped = true
				continue
			if character == "\"":
				in_string = not in_string
				continue
			if in_string:
				continue
			if character in ["{", "["]:
				balance += 1
				saw_container = true
			elif character in ["}", "]"]:
				balance -= 1
		if (saw_container and balance == 0) or (not saw_container and line_index == start):
			return line_index + 1
	return -1


static func _line_assigns_action(line: String, action: String) -> bool:
	var stripped := line.strip_edges()
	if stripped.begins_with(";") or stripped.begins_with("#"):
		return false
	var equals := stripped.find("=")
	return equals >= 0 and stripped.left(equals).strip_edges() == action


static func _has_mixed_line_endings(content: String) -> bool:
	return content.contains("\r\n") and content.replace("\r\n", "").contains("\n")


static func _valid_action_name(action: String) -> bool:
	if action.is_empty() or action.length() > MAX_ACTION_NAME_CHARS:
		return false
	for character in action:
		var code := character.unicode_at(0)
		if not ((code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or character in ["_", ".", "-"]):
			return false
	return true


static func _failure(error: String) -> Dictionary:
	return {"success": false, "error": error}
