extends SceneTree

const InputMapProposal = preload("res://addons/orca/scripts/input_map_proposal.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

var _failures := PackedStringArray()
var _fixture_path := ""
var _original_project_content := ""
var _project_was_modified := false
var _live_action := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	OS.set_environment("ORCA_TEST_FAULT_INJECTION", "1")
	_fixture_path = "res://.orca_input_map_test_%d.godot" % Time.get_ticks_usec()
	_test_candidate_generation()
	_test_validation()
	_test_reviewed_apply_and_revert()
	_cleanup()
	OS.unset_environment("ORCA_TEST_FAULT_INJECTION")
	_finish()


func _test_candidate_generation() -> void:
	var untouched := "untouched={\n\"deadzone\": 0.75,\n\"events\": []\n}\n; preserve this Input Map comment exactly\n"
	var content := "config_version=5\n\n[application]\n\nconfig/name=\"Fixture\"\n\n[input]\n\nexisting={\n\"deadzone\": 0.5,\n\"events\": []\n}\n\n" + untouched + "\n[rendering]\n\nrenderer/rendering_method=\"mobile\"\n"
	_write(_fixture_path, content)
	var changes := [
		{"operation": "upsert", "action": "jump", "deadzone": 0.25, "events": [{"type": "key", "physical_keycode": KEY_SPACE}]},
		{"operation": "remove", "action": "existing"}
	]
	var proposal: Dictionary = InputMapProposal.prepare("fixture", content.sha256_text(), changes, false, _fixture_path)
	_expect(proposal.get("success", false), "valid bounded Input Map changes should prepare")
	_expect(_read(_fixture_path) == content, "proposal preparation must not mutate the source file")
	_expect(proposal.get("kind") == "input_map", "prepared proposals should identify their structured kind")
	_expect(proposal.get("review", []).size() == 2, "structured review should retain each requested action")
	var candidate := ConfigFile.new()
	_expect(candidate.parse(str(proposal.get("new_content", ""))) == OK, "candidate project configuration should parse")
	_expect(candidate.has_section_key("input", "jump"), "candidate should add the requested action")
	_expect(not candidate.has_section_key("input", "existing"), "candidate should remove the requested action")
	_expect(candidate.get_value("application", "config/name") == "Fixture", "unrelated project settings should remain semantically unchanged")
	_expect(str(proposal.get("new_content", "")).contains("[rendering]"), "unrelated source sections should remain present")
	_expect(str(proposal.get("new_content", "")).contains(untouched), "unrelated Input Map bytes and comments should remain exact")


func _test_validation() -> void:
	var content := _read(_fixture_path)
	var valid_event := {"type": "key", "keycode": KEY_A}
	for changes in [
		[],
		[{"operation": "unknown", "action": "jump"}],
		[{"operation": "upsert", "action": "bad action", "events": []}],
		[{"operation": "upsert", "action": "jump", "deadzone": 2.0, "events": []}],
		[{"operation": "upsert", "action": "jump", "events": [{"type": "shell", "command": "bad"}]}],
		[{"operation": "upsert", "action": "jump", "events": [{"type": "joypad_button", "button_index": JOY_BUTTON_MAX}]}],
		[{"operation": "upsert", "action": "jump", "events": [{"type": "joypad_motion", "axis": JOY_AXIS_MAX, "axis_value": 1}]}],
		[{"operation": "upsert", "action": "jump", "events": [{"type": "key", "unicode": 0xD800}]}],
		[{"operation": "upsert", "action": "jump", "events": [valid_event]}, {"operation": "remove", "action": "jump"}]
	]:
		_expect(not InputMapProposal.prepare("invalid", content.sha256_text(), changes, false, _fixture_path).get("success", true), "invalid Input Map proposal arguments should be rejected")
	_expect(not InputMapProposal.prepare("stale", "wrong-hash", [{"operation": "upsert", "action": "jump", "events": [valid_event]}], false, _fixture_path).get("success", true), "stale project hashes should be rejected")
	var no_op: Dictionary = InputMapProposal.prepare("noop", content.sha256_text(), [{"operation": "remove", "action": "missing"}], false, _fixture_path)
	_expect(no_op.get("success", false) and no_op.get("no_changes", false), "semantic no-op removals should not enter approval")
	var direct: Dictionary = Tools.execute_tool("propose_input_map_changes", {})
	_expect(not direct.get("success", true) and str(direct.get("content", "")).contains("reviewed"), "structured mutations must not execute through the generic dispatcher")
	var spaced := content.replace("existing={", "existing = {")
	_write(_fixture_path, spaced)
	var spaced_remove: Dictionary = InputMapProposal.prepare("spaced", spaced.sha256_text(), [{"operation": "remove", "action": "existing"}], false, _fixture_path)
	_expect(spaced_remove.get("success", false) and not str(spaced_remove.get("new_content", "")).contains("existing ="), "targeted replacement should accept whitespace around assignment operators")
	var mixed := content.replace("config_version=5\n", "config_version=5\r\n")
	_write(_fixture_path, mixed)
	_expect(not InputMapProposal.prepare("mixed", mixed.sha256_text(), [{"operation": "remove", "action": "existing"}], false, _fixture_path).get("success", true), "mixed line endings should be rejected rather than normalizing unrelated bytes")
	_write(_fixture_path, content)


func _test_reviewed_apply_and_revert() -> void:
	_original_project_content = _read(InputMapProposal.PROJECT_PATH)
	var action := "orca_test_action_%d" % Time.get_ticks_usec()
	_live_action = action
	var arguments := {
		"base_hash": _original_project_content.sha256_text(),
		"changes": [{"operation": "upsert", "action": action, "deadzone": 0.4, "events": [{"type": "key", "physical_keycode": KEY_F12}]}]
	}
	var proposal: Dictionary = Tools.prepare_reviewed_change("propose_input_map_changes", "live", arguments)
	_expect(proposal.get("success", false), "a fresh project-bound proposal should prepare")
	if not proposal.get("success", false):
		return
	_write(InputMapProposal.PROJECT_PATH, _original_project_content + "\n")
	_expect(Tools.apply_reviewed_change(proposal).contains("changed after"), "application should reject project.godot changed after proposal preparation")
	_write(InputMapProposal.PROJECT_PATH, _original_project_content)
	var tampered: Dictionary = proposal.duplicate(true)
	tampered["new_content"] = str(tampered["new_content"]) + "\n[unauthorized]\nvalue=true\n"
	_expect(Tools.apply_reviewed_change(tampered).contains("reviewed hash"), "application should reject candidate bytes changed after review")
	_expect(_read(InputMapProposal.PROJECT_PATH) == _original_project_content, "rejected tampering must not modify project.godot")
	Tools._set_replacement_test_faults({"backup_cleanup_failure": 1})
	var applied := Tools.apply_reviewed_change(proposal)
	if not applied.begins_with("Cleanup required:"):
		print("input_map_proposal_test apply result: ", applied)
	_project_was_modified = applied.begins_with("Cleanup required:") and applied.contains("Applied")
	_expect(_project_was_modified, "a committed Input Map change with a cleanup warning should not be reported as an ordinary failure")
	_expect(proposal.get("cleanup_required", false) and not proposal.get("recovery_required", false), "Input Map cleanup warnings must not bypass typed conflict validation")
	_cleanup_reported_recovery_copy(applied)
	proposal.erase("cleanup_required")
	proposal.erase("cleanup_warnings")
	Tools._clear_replacement_test_faults()
	_expect(InputMap.has_action(action), "application should synchronize the live InputMap singleton")
	_expect(_read(InputMapProposal.PROJECT_PATH).sha256_text() == proposal.get("new_hash"), "application should write the exact reviewed candidate")
	var tampered_revert: Dictionary = proposal.duplicate(true)
	tampered_revert["old_content"] = str(tampered_revert["old_content"]) + "\n"
	_expect(Tools.revert_reviewed_change(tampered_revert).contains("reviewed base hash"), "revert should reject altered retained original bytes")
	var reverted := Tools.revert_reviewed_change(proposal)
	_expect(reverted.begins_with("Reverted"), "an unchanged applied Input Map proposal should revert")
	if reverted.begins_with("Reverted"):
		_project_was_modified = false
	_expect(_read(InputMapProposal.PROJECT_PATH) == _original_project_content, "revert should restore exact original project.godot bytes")
	_expect(not InputMap.has_action(action), "revert should synchronize removal from the live InputMap singleton")
	var mismatch_action := "orca_live_only_%d" % Time.get_ticks_usec()
	ProjectSettings.set_setting("input/" + mismatch_action, {"deadzone": 0.5, "events": []})
	InputMap.load_from_project_settings()
	var mismatch: Dictionary = Tools.prepare_reviewed_change("propose_input_map_changes", "mismatch", {"base_hash": _original_project_content.sha256_text(), "changes": [{"operation": "upsert", "action": mismatch_action, "events": []}]})
	_expect(not mismatch.get("success", true) and str(mismatch.get("error", "")).contains("differs"), "live affected-action state that differs from disk should block preparation")
	ProjectSettings.set_setting("input/" + mismatch_action, null)
	InputMap.load_from_project_settings()


func _cleanup() -> void:
	Tools._clear_replacement_test_faults()
	if _project_was_modified and not _original_project_content.is_empty():
		_write(InputMapProposal.PROJECT_PATH, _original_project_content)
		ProjectSettings.set_setting("input/" + _live_action, null)
		InputMap.load_from_project_settings()
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
		print("input_map_proposal_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("input_map_proposal_test: ", failure)
	quit(1)
