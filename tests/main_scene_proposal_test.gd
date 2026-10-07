extends SceneTree

const MainSceneProposal = preload("res://addons/orca/scripts/main_scene_proposal.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const SCENE_PATH := "res://tests/fixtures/inspect_scene_fixture.tscn"

var _failures := PackedStringArray()
var _fixture_path := ""
var _original_project_content := ""
var _project_was_modified := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	OS.set_environment("ORCA_TEST_FAULT_INJECTION", "1")
	_fixture_path = "res://.orca_main_scene_test_%d.godot" % Time.get_ticks_usec()
	_test_candidate_generation()
	_test_validation_and_no_op()
	_test_reviewed_apply_and_revert()
	_cleanup()
	OS.unset_environment("ORCA_TEST_FAULT_INJECTION")
	_finish()


func _test_candidate_generation() -> void:
	var preserved := "; preserve this comment exactly\nconfig/name=\"Fixture\"\n"
	var content := "config_version=5\n\n[application]\n\n" + preserved + "\n[rendering]\n\nrenderer/rendering_method=\"mobile\"\n"
	_write(_fixture_path, content)
	var proposal: Dictionary = MainSceneProposal.prepare("fixture", content.sha256_text(), SCENE_PATH, false, _fixture_path)
	_expect(proposal.get("success", false), "a valid saved PackedScene should prepare as the main scene")
	_expect(_read(_fixture_path) == content, "main scene preparation must not mutate project.godot")
	_expect(proposal.get("kind") == "main_scene", "the proposal should retain its structured kind")
	_expect(proposal.get("old_scene_path", "").is_empty() and proposal.get("new_scene_path") == SCENE_PATH, "review data should retain previous and proposed scene identities")
	_expect(str(proposal.get("new_content", "")).contains(preserved), "unrelated application bytes and comments should remain exact")
	var candidate := ConfigFile.new()
	_expect(candidate.parse(str(proposal.get("new_content", ""))) == OK, "the candidate should remain valid project configuration")
	_expect(MainSceneProposal.resolve_setting_value(candidate.get_value("application", "run/main_scene")) == SCENE_PATH, "the serialized setting should resolve to the requested scene")


func _test_validation_and_no_op() -> void:
	var content := _read(_fixture_path)
	for scene_path in ["res://missing.tscn", "res://project.godot", "res://addons/orca/scenes/chat_window.tscn", "/tmp/outside.tscn"]:
		var result: Dictionary = Tools.prepare_reviewed_change("propose_main_scene_change", "invalid", {"base_hash": content.sha256_text(), "scene_path": scene_path})
		_expect(not result.get("success", true), "invalid or protected main scene targets should fail: " + scene_path)
	_expect(not MainSceneProposal.prepare("stale", "wrong-hash", SCENE_PATH, false, _fixture_path).get("success", true), "stale project hashes should be rejected")
	var mixed := content.replace("config_version=5\n", "config_version=5\r\n")
	_write(_fixture_path, mixed)
	_expect(not MainSceneProposal.prepare("mixed", mixed.sha256_text(), SCENE_PATH, false, _fixture_path).get("success", true), "mixed line endings should be rejected")
	var configured := "config_version=5\n\n[application]\n\nrun/main_scene = \"%s\"\n" % SCENE_PATH
	_write(_fixture_path, configured)
	var no_op: Dictionary = MainSceneProposal.prepare("noop", configured.sha256_text(), SCENE_PATH, false, _fixture_path)
	_expect(no_op.get("success", false) and no_op.get("no_changes", false), "equivalent existing scene paths should skip approval without reformatting")
	var unresolved_value := "uid://aaaaaaaaaaaaa"
	var unresolved := "config_version=5\n\n[application]\n\nrun/main_scene=\"%s\"\n" % unresolved_value
	_write(_fixture_path, unresolved)
	var replace_unresolved: Dictionary = MainSceneProposal.prepare("unresolved", unresolved.sha256_text(), SCENE_PATH, false, _fixture_path)
	_expect(replace_unresolved.get("success", false) and str(replace_unresolved.get("old_scene_display", "")).contains("Unresolved setting"), "broken existing main scene values should be disclosed in review rather than shown as unconfigured")
	_expect(MainSceneProposal.sync_live(unresolved_value, "").is_empty(), "unresolved previous values should remain restorable")
	ProjectSettings.set_setting(MainSceneProposal.SETTING_PATH, null)
	_write(_fixture_path, content)
	var direct: Dictionary = Tools.execute_tool("propose_main_scene_change", {})
	_expect(not direct.get("success", true) and str(direct.get("content", "")).contains("reviewed"), "main scene mutation must not execute through the generic dispatcher")


func _test_reviewed_apply_and_revert() -> void:
	_original_project_content = _read(MainSceneProposal.PROJECT_PATH)
	var proposal: Dictionary = Tools.prepare_reviewed_change("propose_main_scene_change", "live", {"base_hash": _original_project_content.sha256_text(), "scene_path": SCENE_PATH})
	_expect(proposal.get("success", false), "a fresh project-bound main scene proposal should prepare")
	if not proposal.get("success", false):
		return
	_write(MainSceneProposal.PROJECT_PATH, _original_project_content + "\n")
	_expect(Tools.apply_reviewed_change(proposal).contains("changed after"), "application should reject project.godot changed after main scene review")
	_write(MainSceneProposal.PROJECT_PATH, _original_project_content)
	var tampered: Dictionary = proposal.duplicate(true)
	tampered["new_content"] = str(tampered["new_content"]) + "\n[unauthorized]\nvalue=true\n"
	_expect(Tools.apply_reviewed_change(tampered).contains("reviewed hash"), "application should reject main scene candidate bytes changed after review")
	Tools._set_replacement_test_faults({"backup_cleanup_failure": 1})
	var applied := Tools.apply_reviewed_change(proposal)
	_project_was_modified = applied.begins_with("Cleanup required:") and applied.contains("Applied")
	_expect(_project_was_modified, "a committed main-scene change with a cleanup warning should not be reported as an ordinary failure")
	_expect(proposal.get("cleanup_required", false) and not proposal.get("recovery_required", false), "main-scene cleanup warnings must not bypass typed conflict validation")
	_cleanup_reported_recovery_copy(applied)
	proposal.erase("cleanup_required")
	proposal.erase("cleanup_warnings")
	Tools._clear_replacement_test_faults()
	_expect(MainSceneProposal.resolve_setting_value(ProjectSettings.get_setting(MainSceneProposal.SETTING_PATH, null)) == SCENE_PATH, "application should synchronize live ProjectSettings")
	_expect(_read(MainSceneProposal.PROJECT_PATH).sha256_text() == proposal.get("new_hash"), "application should write the exact reviewed candidate")
	var tampered_revert: Dictionary = proposal.duplicate(true)
	tampered_revert["old_content"] = str(tampered_revert["old_content"]) + "\n"
	_expect(Tools.revert_reviewed_change(tampered_revert).contains("reviewed base hash"), "revert should reject altered retained original project bytes")
	var tampered_old_value: Dictionary = proposal.duplicate(true)
	tampered_old_value["old_value"] = SCENE_PATH
	tampered_old_value["old_scene_path"] = SCENE_PATH
	_expect(Tools.revert_reviewed_change(tampered_old_value).begins_with("Error:"), "revert should derive the previous main scene from the reviewed original bytes")
	var reverted := Tools.revert_reviewed_change(proposal)
	_expect(reverted.begins_with("Reverted"), "an unchanged applied main scene proposal should revert")
	if reverted.begins_with("Reverted"):
		_project_was_modified = false
	_expect(_read(MainSceneProposal.PROJECT_PATH) == _original_project_content, "revert should restore exact original project.godot bytes")
	_expect(MainSceneProposal.resolve_setting_value(ProjectSettings.get_setting(MainSceneProposal.SETTING_PATH, null)).is_empty(), "revert should restore the previous live main scene state")


func _cleanup() -> void:
	Tools._clear_replacement_test_faults()
	if _project_was_modified and not _original_project_content.is_empty():
		_write(MainSceneProposal.PROJECT_PATH, _original_project_content)
		ProjectSettings.set_setting(MainSceneProposal.SETTING_PATH, null)
	if FileAccess.file_exists(_fixture_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_fixture_path))


func _cleanup_reported_recovery_copy(result: String) -> void:
	var marker := "Recovery copy: "
	var marker_index := result.find(marker)
	if marker_index >= 0:
		DirAccess.remove_absolute(result.substr(marker_index + marker.length()))


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
		print("main_scene_proposal_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("main_scene_proposal_test: ", failure)
	quit(1)
