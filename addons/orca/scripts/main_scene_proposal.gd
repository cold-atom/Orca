@tool
extends RefCounted

const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")

const PROJECT_PATH := "res://project.godot"
const SETTING_PATH := "application/run/main_scene"
const SECTION := "application"
const KEY := "run/main_scene"
const MAX_PROJECT_FILE_BYTES := 2 * 1024 * 1024
const MAX_SCENE_FILE_BYTES := 2 * 1024 * 1024


static func prepare(change_id: String, base_hash: String, scene_path: String, check_live: bool = true, filepath: String = PROJECT_PATH) -> Dictionary:
	var canonical_path := _canonical_res_path(scene_path)
	var scene_error := validate_scene(canonical_path)
	if not scene_error.is_empty():
		return _failure(scene_error)
	var read_result := _read_project_file(filepath)
	if not read_result.get("success", false):
		return read_result
	var old_content: String = read_result["content"]
	if _has_mixed_line_endings(old_content):
		return _failure("project.godot uses mixed LF and CRLF line endings. Normalize it before proposing a main scene change.")
	if base_hash != old_content.sha256_text():
		return _failure("base_hash does not match project.godot. Read it again before proposing a main scene change.")
	var old_config_result := _parse_config(old_content)
	if not old_config_result.get("success", false):
		return old_config_result
	var old_config: ConfigFile = old_config_result["config"]
	var old_exists := old_config.has_section_key(SECTION, KEY)
	var old_value = old_config.get_value(SECTION, KEY) if old_exists else null
	var old_scene_path := resolve_setting_value(old_value)
	var old_scene_display := old_scene_path if not old_scene_path.is_empty() else _unresolved_display(old_value)
	if check_live:
		var live_error := validate_live_against_config(old_config)
		if not live_error.is_empty():
			return _failure(live_error)
	if not old_scene_path.is_empty() and old_scene_path == canonical_path:
		return {
			"success": true,
			"id": change_id,
			"kind": "main_scene",
			"filepath": filepath,
			"old_content": old_content,
			"new_content": old_content,
			"old_hash": old_content.sha256_text(),
			"new_hash": old_content.sha256_text(),
			"old_value": old_value,
			"new_value": old_value,
			"old_scene_path": old_scene_path,
			"old_scene_display": old_scene_display,
			"new_scene_path": canonical_path,
			"status": "pending",
			"no_changes": true
		}
	var new_value := _preferred_setting_value(canonical_path)
	var assignment := _serialize_assignment(new_value)
	var materialized := _replace_setting(old_content, assignment)
	if not materialized.get("success", false):
		return materialized
	var new_content: String = materialized["content"]
	var candidate_result := _parse_config(new_content)
	if not candidate_result.get("success", false):
		return _failure("The proposed project.godot did not pass ConfigFile validation.")
	var candidate: ConfigFile = candidate_result["config"]
	if not candidate.has_section_key(SECTION, KEY) or resolve_setting_value(candidate.get_value(SECTION, KEY)) != canonical_path:
		return _failure("The proposed main scene value did not verify after serialization.")
	return {
		"success": true,
		"id": change_id,
		"kind": "main_scene",
		"tool_name": "propose_main_scene_change",
		"filepath": filepath,
		"existed": true,
		"old_content": old_content,
		"new_content": new_content,
		"old_hash": old_content.sha256_text(),
		"new_hash": new_content.sha256_text(),
		"old_value": old_value,
		"new_value": new_value,
		"old_scene_path": old_scene_path,
		"old_scene_display": old_scene_display,
		"new_scene_path": canonical_path,
		"validation": {"valid": true, "message": "Loaded the saved target as a PackedScene and verified project.godot."},
		"status": "pending",
		"no_changes": new_content == old_content
	}


static func validate_current(proposal: Dictionary, expect_new: bool) -> String:
	if str(proposal.get("filepath", "")) != PROJECT_PATH:
		return "Main scene proposals are restricted to res://project.godot."
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
	var expected_path := str(proposal.get("new_scene_path" if expect_new else "old_scene_path", ""))
	var expected_value = proposal.get("new_value" if expect_new else "old_value")
	var value_error := _verify_value(config_result["config"], expected_value, expected_path)
	if not value_error.is_empty():
		return value_error
	if expect_new and proposal.get("recovery_required", false):
		return ""
	return validate_live_against_config(config_result["config"])


static func validate_candidate(proposal: Dictionary, validate_target: bool = true) -> String:
	if str(proposal.get("old_content", "")).sha256_text() != str(proposal.get("old_hash", "")):
		return "The retained original project.godot bytes no longer match the reviewed base hash."
	if str(proposal.get("new_content", "")).sha256_text() != str(proposal.get("new_hash", "")):
		return "The retained main scene candidate no longer matches the reviewed hash."
	var scene_path := str(proposal.get("new_scene_path", ""))
	if validate_target:
		var scene_error := validate_scene(scene_path)
		if not scene_error.is_empty():
			return scene_error
	var config_result := _parse_config(str(proposal.get("new_content", "")))
	if not config_result.get("success", false):
		return "The retained main scene candidate is no longer valid project.godot content."
	var new_error := _verify_value(config_result["config"], proposal.get("new_value"), scene_path)
	if not new_error.is_empty():
		return new_error
	var old_config_result := _parse_config(str(proposal.get("old_content", "")))
	if not old_config_result.get("success", false):
		return "The retained original project.godot is no longer valid configuration content."
	return _verify_value(old_config_result["config"], proposal.get("old_value"), str(proposal.get("old_scene_path", "")))


static func validate_scene(scene_path: String) -> String:
	if scene_path.is_empty() or not scene_path.begins_with("res://"):
		return "scene_path must be a saved res:// path."
	if scene_path.get_extension().to_lower() != "tscn":
		return "The main scene proposal accepts saved .tscn scenes only."
	if not FileAccess.file_exists(scene_path):
		return "Scene does not exist at path: " + scene_path
	var file := FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		return "Could not read the proposed main scene."
	var size := file.get_length()
	file.close()
	if size > MAX_SCENE_FILE_BYTES:
		return "The proposed main scene exceeds the 2 MB validation limit."
	if EditorContext.has_unsaved_file(scene_path):
		return "The proposed main scene has unsaved editor changes. Save it before setting it as the project main scene."
	var packed = ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if not packed is PackedScene or packed.get_state() == null:
		return "The proposed target could not be loaded as a valid PackedScene."
	return ""


static func validate_live_against_config(config: ConfigFile) -> String:
	var disk_value = config.get_value(SECTION, KEY) if config.has_section_key(SECTION, KEY) else null
	var live_value = ProjectSettings.get_setting(SETTING_PATH, null)
	if not _setting_values_equivalent(disk_value, live_value):
		return "The live main scene setting differs from project.godot. Save or close Project Settings and retry."
	return ""


static func sync_live(value, expected_path: String) -> String:
	ProjectSettings.set_setting(SETTING_PATH, value)
	var live_value = ProjectSettings.get_setting(SETTING_PATH, null)
	if _empty_setting(value):
		if not _empty_setting(live_value):
			return "ProjectSettings still contains a main scene after it should have been cleared."
	elif expected_path.is_empty():
		if live_value != value:
			return "ProjectSettings did not restore the unresolved previous main scene value."
	elif resolve_setting_value(live_value) != expected_path:
		return "ProjectSettings loaded a different main scene than the reviewed value."
	return ""


static func sync_live_from_content(content: String) -> String:
	var config_result := _parse_config(content)
	if not config_result.get("success", false):
		return str(config_result.get("error", "Could not parse the current project.godot."))
	var config: ConfigFile = config_result["config"]
	var value = config.get_value(SECTION, KEY) if config.has_section_key(SECTION, KEY) else null
	return sync_live(value, resolve_setting_value(value))


static func resolve_setting_value(value) -> String:
	if typeof(value) not in [TYPE_STRING, TYPE_STRING_NAME]:
		return ""
	var text := str(value)
	if text.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(text)
		if uid == ResourceUID.INVALID_ID or not ResourceUID.has_id(uid):
			return ""
		text = ResourceUID.get_id_path(uid)
	if not text.begins_with("res://"):
		return ""
	return _canonical_res_path(text)


static func _preferred_setting_value(scene_path: String) -> String:
	var uid := ResourceLoader.get_resource_uid(scene_path)
	if uid != ResourceUID.INVALID_ID and ResourceUID.has_id(uid):
		var uid_text := ResourceUID.id_to_text(uid)
		if resolve_setting_value(uid_text) == scene_path:
			return uid_text
	return scene_path


static func _verify_value(config: ConfigFile, expected_value, expected_path: String) -> String:
	var exists := config.has_section_key(SECTION, KEY)
	if _empty_setting(expected_value):
		if exists and not _empty_setting(config.get_value(SECTION, KEY)):
			return "project.godot still contains an unexpected main scene value."
		return ""
	if not exists:
		return "project.godot no longer contains the reviewed main scene setting."
	var actual = config.get_value(SECTION, KEY)
	if expected_path.is_empty():
		if actual != expected_value:
			return "The unresolved main scene setting changed after review."
	elif resolve_setting_value(actual) != expected_path:
		return "The main scene setting no longer resolves to the reviewed scene."
	return ""


static func _setting_values_equivalent(left, right) -> bool:
	if _empty_setting(left) and _empty_setting(right):
		return true
	var left_path := resolve_setting_value(left)
	var right_path := resolve_setting_value(right)
	if not left_path.is_empty() or not right_path.is_empty():
		return left_path == right_path
	return left == right


static func _empty_setting(value) -> bool:
	return value == null or (typeof(value) in [TYPE_STRING, TYPE_STRING_NAME] and str(value).is_empty())


static func _serialize_assignment(value: String) -> String:
	var config := ConfigFile.new()
	config.set_value(SECTION, KEY, value)
	for line in config.encode_to_text().replace("\r\n", "\n").split("\n", true):
		if _line_assigns_key(line):
			return line
	return ""


static func _replace_setting(content: String, assignment: String) -> Dictionary:
	if assignment.is_empty():
		return _failure("Could not serialize the proposed main scene setting.")
	var crlf := content.contains("\r\n")
	var lines := content.replace("\r\n", "\n").split("\n", true)
	var section_start := -1
	var section_end := lines.size()
	for index in range(lines.size()):
		var stripped := lines[index].strip_edges()
		if stripped == "[" + SECTION + "]":
			section_start = index
		elif section_start >= 0 and stripped.begins_with("[") and stripped.ends_with("]"):
			section_end = index
			break
	if section_start < 0:
		if not lines.is_empty() and not lines[-1].is_empty():
			lines.append("")
		lines.append("[" + SECTION + "]")
		lines.append("")
		lines.append(assignment)
		lines.append("")
	else:
		var key_index := -1
		for index in range(section_start + 1, section_end):
			if _line_assigns_key(lines[index]):
				key_index = index
				break
		if key_index >= 0:
			lines[key_index] = assignment
		else:
			var insert_at := section_end
			while insert_at > section_start + 1 and lines[insert_at - 1].is_empty():
				insert_at -= 1
			lines.insert(insert_at, assignment)
			lines.insert(insert_at, "")
	var result := "\n".join(lines)
	return {"success": true, "content": result.replace("\n", "\r\n") if crlf else result}


static func _line_assigns_key(line: String) -> bool:
	var stripped := line.strip_edges()
	if stripped.begins_with(";") or stripped.begins_with("#"):
		return false
	var equals := stripped.find("=")
	return equals >= 0 and stripped.left(equals).strip_edges() == KEY


static func _canonical_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return ""
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())


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


static func _unresolved_display(value) -> String:
	if _empty_setting(value):
		return ""
	return ("Unresolved setting: " + str(value)).left(256)


static func _failure(error: String) -> Dictionary:
	return {"success": false, "error": error}
