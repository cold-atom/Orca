@tool
extends RefCounted

const PROJECT_PATH := "res://project.godot"
const MAX_PROJECT_FILE_BYTES := 2 * 1024 * 1024
const MAX_CHANGES := 6
const SETTING_SPECS := {
	"display/window/size/viewport_width": {"type": TYPE_INT, "default": 1152, "minimum": 1, "maximum": 7680, "label": "Viewport width"},
	"display/window/size/viewport_height": {"type": TYPE_INT, "default": 648, "minimum": 1, "maximum": 4320, "label": "Viewport height"},
	"display/window/size/window_width_override": {"type": TYPE_INT, "default": 0, "minimum": 0, "maximum": 7680, "label": "Window width override"},
	"display/window/size/window_height_override": {"type": TYPE_INT, "default": 0, "minimum": 0, "maximum": 4320, "label": "Window height override"},
	"display/window/stretch/mode": {"type": TYPE_STRING, "default": "disabled", "values": ["disabled", "canvas_items", "viewport"], "label": "Stretch mode"},
	"display/window/stretch/aspect": {"type": TYPE_STRING, "default": "keep", "values": ["ignore", "keep", "keep_width", "keep_height", "expand"], "label": "Stretch aspect"}
}


static func prepare(change_id: String, base_hash: String, raw_changes, check_live: bool = true, filepath: String = PROJECT_PATH) -> Dictionary:
	var normalized_result := _normalize_changes(raw_changes)
	if not normalized_result.get("success", false):
		return normalized_result
	var read_result := _read_project_file(filepath)
	if not read_result.get("success", false):
		return read_result
	var old_content: String = read_result["content"]
	if _has_mixed_line_endings(old_content):
		return _failure("project.godot uses mixed LF and CRLF line endings. Normalize it before proposing ProjectSettings changes.")
	if base_hash != old_content.sha256_text():
		return _failure("base_hash does not match project.godot. Read it again before proposing ProjectSettings changes.")
	var old_config_result := _parse_config(old_content)
	if not old_config_result.get("success", false):
		return old_config_result
	var old_config: ConfigFile = old_config_result["config"]
	var normalized_changes: Array = normalized_result["changes"]
	var requested_paths := PackedStringArray()
	for change in normalized_changes:
		requested_paths.append(change["setting_path"])
	if check_live:
		var live_error := validate_live_against_config(old_config, requested_paths)
		if not live_error.is_empty():
			return _failure(live_error)

	var changes: Array[Dictionary] = []
	var old_values := {}
	var new_values := {}
	var review: Array[Dictionary] = []
	for change in normalized_changes:
		var path: String = change["setting_path"]
		var old_value = _effective_disk_value(old_config, path)
		if _values_equal(old_value, change["value"]):
			continue
		changes.append(change)
		old_values[path] = old_value
		new_values[path] = change["value"]
		var spec: Dictionary = SETTING_SPECS[path]
		review.append({"setting_path": path, "label": spec["label"], "type": type_string(spec["type"]), "before": old_value, "after": change["value"]})
	if changes.is_empty():
		return {"success": true, "id": change_id, "kind": "project_settings", "filepath": filepath, "old_content": old_content, "new_content": old_content, "old_hash": old_content.sha256_text(), "new_hash": old_content.sha256_text(), "status": "pending", "no_changes": true}

	var materialized := _materialize_changes(old_content, changes)
	if not materialized.get("success", false):
		return materialized
	var new_content: String = materialized["content"]
	var candidate_result := _parse_config(new_content)
	if not candidate_result.get("success", false):
		return _failure("The proposed project.godot did not pass ConfigFile validation.")
	var verify_error := _verify_values(candidate_result["config"], new_values)
	if not verify_error.is_empty():
		return _failure(verify_error)
	return {
		"success": true,
		"id": change_id,
		"kind": "project_settings",
		"tool_name": "propose_project_settings_changes",
		"filepath": filepath,
		"existed": true,
		"old_content": old_content,
		"new_content": new_content,
		"old_hash": old_content.sha256_text(),
		"new_hash": new_content.sha256_text(),
		"setting_paths": old_values.keys(),
		"old_values": old_values,
		"new_values": new_values,
		"review": review,
		"validation": {"valid": true, "message": "Validated allowlisted typed settings and parsed the candidate project.godot."},
		"status": "pending",
		"no_changes": false
	}


static func validate_current(proposal: Dictionary, expect_new: bool) -> String:
	var metadata_error := _validate_proposal_metadata(proposal)
	if not metadata_error.is_empty():
		return metadata_error
	if str(proposal.get("filepath", "")) != PROJECT_PATH:
		return "ProjectSettings proposals are restricted to res://project.godot."
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
	var verify_error := _verify_effective_values(config_result["config"], values)
	if not verify_error.is_empty():
		return verify_error
	if expect_new and proposal.get("recovery_required", false):
		return ""
	return validate_live_against_config(config_result["config"], PackedStringArray(proposal.get("setting_paths", [])))


static func validate_candidate(proposal: Dictionary) -> String:
	if str(proposal.get("old_content", "")).sha256_text() != str(proposal.get("old_hash", "")):
		return "The retained original project.godot bytes no longer match the reviewed base hash."
	if str(proposal.get("new_content", "")).sha256_text() != str(proposal.get("new_hash", "")):
		return "The retained ProjectSettings candidate no longer matches the reviewed hash."
	return _validate_proposal_metadata(proposal)


static func validate_live_against_config(config: ConfigFile, setting_paths: PackedStringArray) -> String:
	for path in setting_paths:
		var disk_value = _effective_disk_value(config, path)
		var live_value = ProjectSettings.get_setting(path, null)
		if not _values_equal(disk_value, live_value):
			return "The live value for '%s' differs from project.godot. Save or close Project Settings, remove an active override, or reload the project before retrying." % path
	return ""


static func sync_live(values: Dictionary) -> String:
	var values_error := _validate_retained_values(values)
	if not values_error.is_empty():
		return values_error
	for path in values:
		ProjectSettings.set_setting(path, values[path])
	for path in values:
		var live_value = ProjectSettings.get_setting(path, null)
		if not _values_equal(live_value, values[path]):
			return "ProjectSettings loaded a different value for '%s'." % path
	return ""


static func sync_live_from_content(content: String, setting_paths: Array) -> String:
	var config_result := _parse_config(content)
	if not config_result.get("success", false):
		return str(config_result.get("error", "Could not parse the current project.godot."))
	var values := {}
	for path in setting_paths:
		values[path] = _effective_disk_value(config_result["config"], path)
	return sync_live(values)


static func _normalize_changes(raw_changes) -> Dictionary:
	if typeof(raw_changes) != TYPE_ARRAY:
		return _failure("changes must be an array.")
	if raw_changes.is_empty() or raw_changes.size() > MAX_CHANGES:
		return _failure("changes must contain between 1 and %d items." % MAX_CHANGES)
	var changes: Array[Dictionary] = []
	var seen := {}
	for index in range(raw_changes.size()):
		var raw = raw_changes[index]
		if typeof(raw) != TYPE_DICTIONARY:
			return _failure("changes[%d] must be an object." % index)
		for key in raw:
			if str(key) not in ["setting_path", "value"]:
				return _failure("Unknown field in changes[%d]: %s" % [index, key])
		if typeof(raw.get("setting_path")) != TYPE_STRING or not raw.has("value"):
			return _failure("Each change requires string setting_path and value.")
		var path := str(raw["setting_path"])
		if not SETTING_SPECS.has(path):
			return _failure("Setting is not in the low-risk mutation allowlist: " + path)
		if seen.has(path):
			return _failure("Each setting may appear only once per proposal: " + path)
		seen[path] = true
		var value = raw["value"]
		var spec: Dictionary = SETTING_SPECS[path]
		if typeof(value) != int(spec["type"]):
			return _failure("%s requires %s, not %s." % [path, type_string(spec["type"]), type_string(typeof(value))])
		if spec["type"] == TYPE_INT and (value < spec["minimum"] or value > spec["maximum"]):
			return _failure("%s must be between %s and %s." % [path, spec["minimum"], spec["maximum"]])
		if spec["type"] == TYPE_STRING and value not in spec["values"]:
			return _failure("%s must be one of: %s." % [path, ", ".join(spec["values"])])
		changes.append({"setting_path": path, "value": value})
	return {"success": true, "changes": changes}


static func _validate_proposal_metadata(proposal: Dictionary) -> String:
	var old_values = proposal.get("old_values")
	var new_values = proposal.get("new_values")
	var setting_paths = proposal.get("setting_paths")
	if typeof(old_values) != TYPE_DICTIONARY or typeof(new_values) != TYPE_DICTIONARY or typeof(setting_paths) != TYPE_ARRAY:
		return "The retained ProjectSettings proposal metadata is malformed."
	var old_error := _validate_retained_values(old_values)
	if not old_error.is_empty():
		return old_error
	var new_error := _validate_retained_values(new_values)
	if not new_error.is_empty():
		return new_error
	var expected_paths := PackedStringArray()
	for path in new_values:
		expected_paths.append(str(path))
	expected_paths.sort()
	var retained_paths := PackedStringArray()
	for path in setting_paths:
		if typeof(path) != TYPE_STRING:
			return "The retained ProjectSettings path list is malformed."
		retained_paths.append(path)
	retained_paths.sort()
	if retained_paths != expected_paths or old_values.size() != new_values.size():
		return "The retained ProjectSettings paths no longer match the reviewed values."
	for path in expected_paths:
		if not old_values.has(path):
			return "The retained previous ProjectSettings values are incomplete."
	var old_config_result := _parse_config(str(proposal.get("old_content", "")))
	var new_config_result := _parse_config(str(proposal.get("new_content", "")))
	if not old_config_result.get("success", false) or not new_config_result.get("success", false):
		return "The retained ProjectSettings source or candidate is not valid project.godot content."
	var old_config: ConfigFile = old_config_result["config"]
	for path in expected_paths:
		if not _values_equal(_effective_disk_value(old_config, path), old_values[path]):
			return "The retained previous value no longer matches the reviewed project.godot for '%s'." % path
	var new_config: ConfigFile = new_config_result["config"]
	var new_values_error := _verify_values(new_config, new_values)
	if not new_values_error.is_empty():
		return new_values_error
	var actual_delta := PackedStringArray()
	for path in SETTING_SPECS:
		if not _values_equal(_effective_disk_value(old_config, path), _effective_disk_value(new_config, path)):
			actual_delta.append(path)
	actual_delta.sort()
	if actual_delta != expected_paths:
		return "The retained setting list does not match the complete allowlisted project.godot change set."
	return ""


static func _validate_retained_values(values: Dictionary) -> String:
	if values.is_empty() or values.size() > MAX_CHANGES:
		return "The retained ProjectSettings value set is outside the allowed size."
	for path in values:
		if typeof(path) != TYPE_STRING or not SETTING_SPECS.has(path):
			return "The retained proposal contains a non-allowlisted setting."
		var spec: Dictionary = SETTING_SPECS[path]
		var value = values[path]
		if typeof(value) != int(spec["type"]):
			return "The retained value has the wrong type for '%s'." % path
		if spec["type"] == TYPE_INT and (value < spec["minimum"] or value > spec["maximum"]):
			return "The retained value is outside Orca's safety bounds for '%s'." % path
		if spec["type"] == TYPE_STRING and value not in spec["values"]:
			return "The retained value is outside the allowed enum for '%s'." % path
	return ""


static func _materialize_changes(content: String, changes: Array) -> Dictionary:
	var result := content
	for change in changes:
		var replacement := _replace_setting(result, change["setting_path"], _serialize_assignment(change["setting_path"], change["value"]))
		if not replacement.get("success", false):
			return replacement
		result = replacement["content"]
	return {"success": true, "content": result}


static func _replace_setting(content: String, path: String, assignment: String) -> Dictionary:
	if assignment.is_empty():
		return _failure("Could not serialize setting: " + path)
	var slash := path.find("/")
	var section := path.left(slash)
	var key := path.substr(slash + 1)
	var crlf := content.contains("\r\n")
	var lines := content.replace("\r\n", "\n").split("\n", true)
	var section_start := -1
	var section_end := lines.size()
	for index in range(lines.size()):
		var stripped := lines[index].strip_edges()
		if stripped == "[" + section + "]":
			section_start = index
		elif section_start >= 0 and stripped.begins_with("[") and stripped.ends_with("]"):
			section_end = index
			break
	if section_start < 0:
		if not lines.is_empty() and not lines[-1].is_empty():
			lines.append("")
		lines.append("[" + section + "]")
		lines.append("")
		lines.append(assignment)
		lines.append("")
	else:
		var matches := PackedInt32Array()
		for index in range(section_start + 1, section_end):
			if _line_assigns_key(lines[index], key):
				matches.append(index)
		if matches.size() > 1:
			return _failure("project.godot contains duplicate assignments for " + path)
		if matches.size() == 1:
			lines[matches[0]] = assignment
		else:
			var insert_at := section_end
			while insert_at > section_start + 1 and lines[insert_at - 1].is_empty():
				insert_at -= 1
			lines.insert(insert_at, assignment)
			lines.insert(insert_at, "")
	var rendered := "\n".join(lines)
	return {"success": true, "content": rendered.replace("\n", "\r\n") if crlf else rendered}


static func _serialize_assignment(path: String, value) -> String:
	var slash := path.find("/")
	var section := path.left(slash)
	var key := path.substr(slash + 1)
	var config := ConfigFile.new()
	config.set_value(section, key, value)
	for line in config.encode_to_text().replace("\r\n", "\n").split("\n", true):
		if _line_assigns_key(line, key):
			return line
	return ""


static func _effective_disk_value(config: ConfigFile, path: String):
	var slash := path.find("/")
	var section := path.left(slash)
	var key := path.substr(slash + 1)
	return config.get_value(section, key) if config.has_section_key(section, key) else SETTING_SPECS[path]["default"]


static func _verify_values(config: ConfigFile, values: Dictionary) -> String:
	for path in values:
		var slash := str(path).find("/")
		var section := str(path).left(slash)
		var key := str(path).substr(slash + 1)
		if not config.has_section_key(section, key) or not _values_equal(config.get_value(section, key), values[path]):
			return "Candidate value did not verify for setting '%s'." % path
	return ""


static func _verify_effective_values(config: ConfigFile, values: Dictionary) -> String:
	for path in values:
		if not _values_equal(_effective_disk_value(config, path), values[path]):
			return "Effective project setting changed after review: " + str(path)
	return ""


static func _values_equal(left, right) -> bool:
	return typeof(left) == typeof(right) and left == right


static func _line_assigns_key(line: String, key: String) -> bool:
	var stripped := line.strip_edges()
	if stripped.begins_with(";") or stripped.begins_with("#"):
		return false
	var equals := stripped.find("=")
	return equals >= 0 and stripped.left(equals).strip_edges() == key


static func _read_project_file(filepath: String) -> Dictionary:
	if not FileAccess.file_exists(filepath):
		return _failure("project.godot does not exist.")
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		return _failure("Could not read project.godot.")
	if file.get_length() > MAX_PROJECT_FILE_BYTES:
		file.close()
		return _failure("project.godot exceeds the 2 MB proposal limit.")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var content := bytes.get_string_from_utf8()
	if content.to_utf8_buffer() != bytes:
		return _failure("project.godot is not valid UTF-8 and cannot be changed without altering unrelated bytes.")
	return {"success": true, "content": content}


static func _parse_config(content: String) -> Dictionary:
	var config := ConfigFile.new()
	var error := config.parse(content)
	if error != OK:
		return _failure("project.godot could not be parsed as configuration data (error %d)." % error)
	return {"success": true, "config": config}


static func _has_mixed_line_endings(content: String) -> bool:
	return content.contains("\r\n") and content.replace("\r\n", "").contains("\n")


static func _failure(error: String) -> Dictionary:
	return {"success": false, "error": error}
