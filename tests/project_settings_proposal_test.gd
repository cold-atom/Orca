extends SceneTree

const ProjectSettingsProposal = preload("res://addons/orca/scripts/project_settings_proposal.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

var _failures := PackedStringArray()
var _fixture_path := ""
var _original_project_content := ""
var _project_was_modified := false
var _old_live_values := {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_path = "res://.orca_project_settings_test_%d.godot" % Time.get_ticks_usec()
	_test_candidate_generation()
	_test_validation_and_defaults()
	_test_reviewed_apply_and_revert()
	_cleanup()
	_finish()


func _test_candidate_generation() -> void:
	var preserved := "; preserve display comment exactly\nwindow/vsync/vsync_mode=1\n"
	var content := "config_version=5\n\n[application]\n\nconfig/name=\"Fixture\"\n\n[display]\n\n" + preserved + "\n[rendering]\n\nrenderer/rendering_method=\"mobile\"\n"
	_write(_fixture_path, content)
	var changes := [
		{"setting_path": "display/window/size/viewport_width", "value": 1920},
		{"setting_path": "display/window/size/viewport_height", "value": 1080}
	]
	var proposal: Dictionary = ProjectSettingsProposal.prepare("fixture", content.sha256_text(), changes, false, _fixture_path)
	_expect(proposal.get("success", false), "valid allowlisted display settings should prepare atomically")
	_expect(_read(_fixture_path) == content, "ProjectSettings preparation must not mutate the source file")
	_expect(proposal.get("review", []).size() == 2, "structured review should retain every changed setting")
	_expect(str(proposal.get("new_content", "")).contains(preserved), "unrelated display bytes and comments should remain exact")
	var candidate := ConfigFile.new()
	_expect(candidate.parse(str(proposal.get("new_content", ""))) == OK, "the candidate should remain valid project configuration")
	_expect(candidate.get_value("display", "window/size/viewport_width") == 1920 and candidate.get_value("display", "window/size/viewport_height") == 1080, "the candidate should contain both requested dimensions")


func _test_validation_and_defaults() -> void:
	var content := _read(_fixture_path)
	for changes in [
		[],
		[{"setting_path": "rendering/renderer/rendering_method", "value": "gl_compatibility"}],
		[{"setting_path": "display/window/size/viewport_width", "value": 1920.0}],
		[{"setting_path": "display/window/size/viewport_width", "value": 0}],
		[{"setting_path": "display/window/size/viewport_height", "value": 4321}],
		[{"setting_path": "display/window/stretch/mode", "value": "invalid"}],
		[{"setting_path": "display/window/stretch/aspect", "value": true}],
		[{"setting_path": "display/window/size/viewport_width", "value": 1280}, {"setting_path": "display/window/size/viewport_width", "value": 1920}]
	]:
		_expect(not ProjectSettingsProposal.prepare("invalid", content.sha256_text(), changes, false, _fixture_path).get("success", true), "invalid or non-allowlisted settings should fail")
	_expect(not ProjectSettingsProposal.prepare("stale", "wrong-hash", [{"setting_path": "display/window/size/viewport_width", "value": 1280}], false, _fixture_path).get("success", true), "stale project hashes should fail")
	var no_op: Dictionary = ProjectSettingsProposal.prepare("noop", content.sha256_text(), [{"setting_path": "display/window/size/viewport_width", "value": 1152}], false, _fixture_path)
	_expect(no_op.get("success", false) and no_op.get("no_changes", false), "an absent setting equal to its built-in default should skip approval")
	var direct: Dictionary = Tools.execute_tool("propose_project_settings_changes", {})
	_expect(not direct.get("success", true) and str(direct.get("content", "")).contains("reviewed"), "ProjectSettings mutations must not execute through the generic dispatcher")


func _test_reviewed_apply_and_revert() -> void:
	_original_project_content = _read(ProjectSettingsProposal.PROJECT_PATH)
	var changes := [
		{"setting_path": "display/window/size/viewport_width", "value": 1600},
		{"setting_path": "display/window/size/viewport_height", "value": 900}
	]
	for change in changes:
		_old_live_values[change["setting_path"]] = ProjectSettings.get_setting(change["setting_path"], ProjectSettingsProposal.SETTING_SPECS[change["setting_path"]]["default"])
	var proposal: Dictionary = Tools.prepare_reviewed_change("propose_project_settings_changes", "live", {"base_hash": _original_project_content.sha256_text(), "changes": changes})
	_expect(proposal.get("success", false), "a fresh project-bound ProjectSettings proposal should prepare")
	if not proposal.get("success", false):
		return
	_write(ProjectSettingsProposal.PROJECT_PATH, _original_project_content + "\n")
	_expect(Tools.apply_reviewed_change(proposal).contains("changed after"), "application should reject project.godot changed after settings review")
	_write(ProjectSettingsProposal.PROJECT_PATH, _original_project_content)
	var tampered: Dictionary = proposal.duplicate(true)
	tampered["new_content"] = str(tampered["new_content"]) + "\n[unauthorized]\nvalue=true\n"
	_expect(Tools.apply_reviewed_change(tampered).contains("reviewed hash"), "application should reject settings candidate bytes changed after review")
	var tampered_values: Dictionary = proposal.duplicate(true)
	tampered_values["new_values"]["rendering/renderer/rendering_method"] = "gl_compatibility"
	_expect(Tools.apply_reviewed_change(tampered_values).contains("non-allowlisted"), "application should reject unauthorized retained setting metadata")
	var tampered_old: Dictionary = proposal.duplicate(true)
	tampered_old["old_values"]["display/window/size/viewport_width"] = 1200
	_expect(Tools.apply_reviewed_change(tampered_old).contains("previous value"), "application should re-derive retained previous values from reviewed bytes")
	var omitted_path: Dictionary = proposal.duplicate(true)
	omitted_path["old_values"].erase("display/window/size/viewport_height")
	omitted_path["new_values"].erase("display/window/size/viewport_height")
	omitted_path["setting_paths"].erase("display/window/size/viewport_height")
	_expect(Tools.apply_reviewed_change(omitted_path).contains("complete allowlisted"), "application should require metadata for every allowlisted setting changed in the candidate")
	var applied := Tools.apply_reviewed_change(proposal)
	_project_was_modified = applied.begins_with("Applied")
	_expect(_project_was_modified, "an approved fresh ProjectSettings proposal should apply")
	_expect(ProjectSettings.get_setting("display/window/size/viewport_width") == 1600 and ProjectSettings.get_setting("display/window/size/viewport_height") == 900, "application should synchronize every live setting")
	_expect(_read(ProjectSettingsProposal.PROJECT_PATH).sha256_text() == proposal.get("new_hash"), "application should write the exact reviewed candidate")
	var reverted := Tools.revert_reviewed_change(proposal)
	_expect(reverted.begins_with("Reverted"), "an unchanged applied ProjectSettings proposal should revert")
	if reverted.begins_with("Reverted"):
		_project_was_modified = false
	_expect(_read(ProjectSettingsProposal.PROJECT_PATH) == _original_project_content, "revert should restore exact original project.godot bytes")
	for path in _old_live_values:
		_expect(ProjectSettings.get_setting(path) == _old_live_values[path], "revert should restore the previous live value for " + path)


func _cleanup() -> void:
	if _project_was_modified and not _original_project_content.is_empty():
		_write(ProjectSettingsProposal.PROJECT_PATH, _original_project_content)
	for path in _old_live_values:
		ProjectSettings.set_setting(path, _old_live_values[path])
	if FileAccess.file_exists(_fixture_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path))


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "test file should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	_expect(file != null, "test file should open for reading: " + path)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("project_settings_proposal_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("project_settings_proposal_test: ", failure)
	quit(1)
