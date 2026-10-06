extends SceneTree

const Tools = preload("res://addons/orca/scripts/tools.gd")
const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")
const DIAGNOSTIC_SCRIPT_PATH := "res://tests/fixtures/game_process_child.gd"
const FUNCTION_FIXTURE := "res://tests/fixtures/gdscript_function_reader_fixture.gd"
const DEPENDENCY_FIXTURE := "res://tests/fixtures/dependency_inspector_root.tres"

class FakeGameProcessService:
	extends RefCounted
	var last_verification: Dictionary = {}

	func start_current_scene(verification: Dictionary = {}) -> Dictionary:
		last_verification = verification.duplicate(true)
		return {"success": true, "content": "started", "outcome": "completed", "data": {"run_id": 4, "sequence": 1, "criteria_id": "criteria"}}

	func start_main_scene(verification: Dictionary = {}) -> Dictionary:
		return start_current_scene(verification)

	func get_snapshot() -> Dictionary:
		return {"run_id": 4, "sequence": 3, "state": "exited", "scene_path": "res://main.tscn", "exit_code": 3, "stdout": "runtime stdout", "stderr": "runtime stderr", "diagnostics": [{"origin": "game", "severity": "error", "file": "res://tests/fixtures/game_process_child.gd", "line": 2, "message": "failure"}], "output_truncated": true, "diagnostics_truncated": false, "dropped_bytes": 4, "verification_status": "failed"}

	func observe_run(run_id: int, after_sequence: int = -1) -> Dictionary:
		return {"success": run_id == 4, "error": "unknown run", "snapshot": get_snapshot(), "changed_since": after_sequence < 3}

	func verify_run(run_id: int) -> Dictionary:
		return {"success": run_id == 4, "error": "unknown run", "verification": {"run_id": 4, "status": "failed", "claim": "fixture", "scope": "process_exit", "checks": [{"name": "expected_exit_code", "status": "failed", "expected": 0, "observed": 3}], "message": "failed"}}

var _failures := PackedStringArray()
var _fixture_path := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_path = "res://.orca_tools_test_%d" % Time.get_ticks_usec()
	var fixture_absolute := ProjectSettings.globalize_path(_fixture_path)
	_expect(DirAccess.make_dir_recursive_absolute(fixture_absolute) == OK, "fixture directory should be created")
	_test_tool_permissions()
	_test_read_only_intelligence_tools()
	_test_task_tool()
	_test_path_boundaries()
	_test_symlink_boundary(fixture_absolute)
	_test_patch_lifecycle()
	_test_gdscript_patch_lifecycle()
	_expect(not _has_replacement_artifacts(fixture_absolute), "tool tests should leave no temporary or backup artifacts")
	_remove_tree(fixture_absolute)
	_finish()


func _test_tool_permissions() -> void:
	var plan_names := _tool_names(Tools.get_tool_definitions(false))
	_expect(not plan_names.has("apply_patch"), "read-only tool definitions must omit apply_patch")
	_expect(not plan_names.has("propose_input_map_changes"), "read-only tool definitions must omit Input Map mutation proposals")
	_expect(not plan_names.has("propose_main_scene_change"), "read-only tool definitions must omit main scene mutation proposals")
	_expect(not plan_names.has("propose_project_settings_changes"), "read-only tool definitions must omit ProjectSettings mutation proposals")
	_expect(not plan_names.has("propose_scene_changes"), "read-only tool definitions must omit structured scene proposals")
	for operation_name in ["run_current_scene", "run_main_scene", "stop_game"]:
		_expect(not plan_names.has(operation_name), "Plan tool definitions must omit external process operation " + operation_name)
	_expect(plan_names.count("update_tasks") == 1, "Plan tool definitions should include update_tasks exactly once")
	_expect(plan_names.count("inspect_scene") == 1, "Plan tool definitions should include inspect_scene exactly once")
	_expect(plan_names.count("inspect_project_settings") == 1, "Plan tool definitions should include inspect_project_settings exactly once")
	for tool_name in ["read_project_skill", "inspect_godot_api", "read_gdscript_function", "discover_dependencies"]:
		_expect(plan_names.count(tool_name) == 1, "Plan tool definitions should include read-only intelligence tool " + tool_name + " exactly once")
	_expect(plan_names.count("observe_game_run") == 1 and plan_names.count("verify_game_run") == 1, "Plan should expose read-only run observation and verification")
	var work_names := _tool_names(Tools.get_tool_definitions(true))
	_expect(work_names.count("apply_patch") == 1, "Work tool definitions should include apply_patch exactly once")
	_expect(work_names.count("propose_input_map_changes") == 1, "Work tool definitions should include propose_input_map_changes exactly once")
	_expect(work_names.count("propose_main_scene_change") == 1, "Work tool definitions should include propose_main_scene_change exactly once")
	_expect(work_names.count("propose_project_settings_changes") == 1, "Work tool definitions should include propose_project_settings_changes exactly once")
	_expect(work_names.count("propose_scene_changes") == 1, "Work tool definitions should include propose_scene_changes exactly once")
	for operation_name in ["run_current_scene", "run_main_scene", "stop_game"]:
		_expect(work_names.count(operation_name) == 1, "Work tool definitions should include " + operation_name + " exactly once")
		var operation_definition := _tool_definition(Tools.get_tool_definitions(true), operation_name)
		var parameters: Dictionary = operation_definition.get("function", {}).get("parameters", {})
		if operation_name == "stop_game":
			_expect(parameters.get("additionalProperties") == false and parameters.get("properties", {}).is_empty(), "stop_game should accept no model-controlled process arguments")
		else:
			_expect(parameters.get("additionalProperties") == false and parameters.get("properties", {}).keys() == ["verification"], operation_name + " should accept only bounded declarative verification criteria")
	var scene_definition := _tool_definition(Tools.get_tool_definitions(true), "propose_scene_changes")
	var operation_enum: Array = scene_definition.get("function", {}).get("parameters", {}).get("properties", {}).get("operations", {}).get("items", {}).get("properties", {}).get("operation", {}).get("enum", [])
	for operation_name in ["create_scene", "add_node", "set_property", "rename_node", "remove_node", "reparent_node", "attach_script", "detach_script", "instantiate_child_scene", "connect_signal", "disconnect_signal"]:
		_expect(operation_name in operation_enum, "structured scene schema should expose " + operation_name)
	var operation_properties: Dictionary = scene_definition.get("function", {}).get("parameters", {}).get("properties", {}).get("operations", {}).get("items", {}).get("properties", {})
	_expect(operation_properties.has("script_path") and operation_properties.has("script_hash"), "script scene operations should expose exact path and hash inputs")
	_expect(work_names.count("update_tasks") == 1, "Work tool definitions should include update_tasks exactly once")
	_expect(work_names.count("inspect_scene") == 1, "Work tool definitions should include inspect_scene exactly once")
	_expect(work_names.count("inspect_project_settings") == 1, "Work tool definitions should include inspect_project_settings exactly once")
	for tool_name in ["read_project_skill", "inspect_godot_api", "read_gdscript_function", "discover_dependencies"]:
		_expect(work_names.count(tool_name) == 1, "Work tool definitions should include read-only intelligence tool " + tool_name + " exactly once")
		var parameters: Dictionary = _tool_definition(Tools.get_tool_definitions(true), tool_name).get("function", {}).get("parameters", {})
		_expect(parameters.get("additionalProperties") == false, tool_name + " should reject unknown schema fields")
	_expect(work_names.count("observe_game_run") == 1 and work_names.count("verify_game_run") == 1, "Work should expose read-only run observation and verification")
	var dependency_parameters: Dictionary = _tool_definition(Tools.get_tool_definitions(false), "discover_dependencies").get("function", {}).get("parameters", {})
	_expect(dependency_parameters.get("required", []) == ["filepath", "direction"], "dependency limits should be optional in the schema")
	var api_properties: Dictionary = _tool_definition(Tools.get_tool_definitions(false), "inspect_godot_api").get("function", {}).get("parameters", {}).get("properties", {})
	_expect(api_properties.keys() == ["class_name", "member_name", "member_kind", "include_inherited"], "Godot API schema should mirror the service arguments")
	var direct: Dictionary = Tools.execute_tool("apply_patch", {})
	_expect(not direct.get("success", true), "apply_patch must not execute through the generic dispatcher")
	_expect(str(direct.get("content", "")).contains("reviewed"), "direct apply_patch denial should explain the review requirement")
	var direct_scene: Dictionary = Tools.execute_tool("propose_scene_changes", {})
	_expect(not direct_scene.get("success", true) and str(direct_scene.get("content", "")).contains("reviewed"), "structured scene mutations must not execute through the generic dispatcher")
	for operation_name in ["run_current_scene", "run_main_scene", "stop_game"]:
		var unavailable: Dictionary = Tools.execute_tool(operation_name, {})
		_expect(not unavailable.get("success", true) and str(unavailable.get("content", "")).contains("unavailable"), operation_name + " should fail safely without the owned process service")
	var diagnostics := Tools.execute_tool("get_diagnostics", {}, FakeGameProcessService.new())
	_expect(diagnostics.get("success", false) and str(diagnostics.get("content", "")).contains("Orca run 4: exited res://main.tscn") and str(diagnostics.get("content", "")).contains("runtime stderr"), "diagnostics should include bounded Orca-owned process state and output")
	_expect(diagnostics.get("data", {}).get("open_path") == DIAGNOSTIC_SCRIPT_PATH and diagnostics.get("data", {}).get("open_line") == 2, "game diagnostics should expose safe project navigation metadata")
	var observation := Tools.execute_tool("observe_game_run", {"run_id": 4, "after_sequence": 2}, FakeGameProcessService.new())
	_expect(observation.get("success", false) and str(observation.get("content", "")).contains("Run 4 snapshot 3") and observation.get("data", {}).get("changed_since"), "observe_game_run should return bounded exact-run evidence")
	var verification := Tools.execute_tool("verify_game_run", {"run_id": 4}, FakeGameProcessService.new())
	_expect(verification.get("success", false) and verification.get("data", {}).get("status") == "failed", "verify_game_run should preserve objective verdict states")
	var fake_run := FakeGameProcessService.new()
	var criteria := {"kind": "clean_startup", "minimum_runtime_ms": 500}
	var run_result := Tools.execute_tool("run_current_scene", {"verification": criteria}, fake_run)
	_expect(run_result.get("success", false) and fake_run.last_verification == criteria, "run tools should pass only declarative verification metadata to the process service")
	_expect(not Tools.execute_tool("run_current_scene", {"executable": "/bin/sh"}, fake_run).get("success", true), "run tools must reject arbitrary process arguments")
	_expect(not Tools.execute_tool("observe_game_run", {"run_id": 4, "timeout": 10}, fake_run).get("success", true), "observation tools must reject waiting or timeout arguments")


func _test_read_only_intelligence_tools() -> void:
	var skills_root := "res://skills"
	var skill_directory := skills_root.path_join("orca-tools-test")
	var created_skills_root := not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(skills_root))
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(skill_directory)) == OK, "tool skill fixture directory should be created")
	_write(skill_directory.path_join("SKILL.md"), "---\nname: Tools Fixture\ndescription: Tool integration fixture\n---\nUse bounded reads.\n")
	var skill := Tools.execute_tool("read_project_skill", {"name": "Tools Fixture"})
	_expect(skill.get("success", false) and skill.get("outcome") == "completed", "read_project_skill should execute as a read-only tool")
	_expect(str(skill.get("content", "")).contains("BEGIN PROJECT SKILL BODY"), "project skill content should retain its safety wrapper")
	_expect(skill.get("data", {}).get("open_path") == skill_directory.path_join("SKILL.md"), "project skill results should include bounded navigation")
	_expect(not Tools.execute_tool("read_project_skill", {"name": "tools fixture"}).get("success", true), "project skill names should match exactly")
	_expect(not Tools.execute_tool("read_project_skill", {"name": "Tools Fixture", "extra": true}).get("success", true), "project skill execution should reject unknown fields")
	_remove_tree(ProjectSettings.globalize_path(skill_directory))
	if created_skills_root:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(skills_root))

	var api := Tools.execute_tool("inspect_godot_api", {"class_name": "Node", "member_name": "add_child", "member_kind": "method"})
	_expect(api.get("success", false) and api.get("outcome") == "completed", "inspect_godot_api should execute in the generic read-only dispatcher")
	_expect(api.get("data", {}).get("help_topic") == "class_method:Node:add_child", "exact API inspection should expose bounded member help navigation")
	_expect(not Tools.execute_tool("inspect_godot_api", {"class_name": "Node", "extra": true}).get("success", true), "Godot API execution should reject unknown fields")

	var function_result := Tools.execute_tool("read_gdscript_function", {"filepath": FUNCTION_FIXTURE, "function_name": "documented"})
	_expect(function_result.get("success", false) and function_result.get("data", {}).get("source_kind") == "disk", "function reads should use saved disk source when no unsaved open snapshot is available")
	_expect(str(function_result.get("data", {}).get("disk_sha256", "")).length() == 64, "saved function reads should retain a disk hash")
	_expect(function_result.get("data", {}).get("open_path") == FUNCTION_FIXTURE and int(function_result.get("data", {}).get("open_line", 0)) > 0, "function reads should include bounded source navigation")
	_expect(not Tools.execute_tool("read_gdscript_function", {"filepath": FUNCTION_FIXTURE, "function_name": "documented", "extra": true}).get("success", true), "function execution should reject unknown fields")

	var dependencies := Tools.execute_tool("discover_dependencies", {"filepath": DEPENDENCY_FIXTURE, "direction": "forward"})
	_expect(dependencies.get("success", false) and dependencies.get("data", {}).get("max_depth") == 1 and dependencies.get("data", {}).get("max_results") == 100, "dependency execution should apply optional defaults")
	_expect(dependencies.get("data", {}).get("open_path") == DEPENDENCY_FIXTURE, "dependency results should include bounded target navigation")
	_expect(not Tools.execute_tool("discover_dependencies", {"filepath": DEPENDENCY_FIXTURE, "direction": "forward", "extra": true}).get("success", true), "dependency execution should reject unknown fields")


func _test_task_tool() -> void:
	var valid_tasks := [
		{"content": "Inspect project", "status": "completed", "ignored": "discard"},
		{"content": "Implement feature", "status": "in_progress"},
		{"content": "Run tests", "status": "pending"}
	]
	var valid: Dictionary = Tools.execute_tool("update_tasks", {"tasks": valid_tasks})
	_expect(valid.get("success", false), "a valid task checklist should be accepted")
	_expect(valid.get("data", {}).get("tasks", []).size() == 3, "valid task order should be retained")
	_expect(not valid.get("data", {}).get("tasks", [])[0].has("ignored"), "unknown task fields should not survive normalization")
	for invalid_tasks in [
		null,
		["invalid"],
		[{"content": "", "status": "pending"}],
		[{"content": "Task", "status": "unknown"}],
		[{"content": "One", "status": "in_progress"}, {"content": "Two", "status": "in_progress"}],
		[{"content": "x".repeat(TaskUtils.MAX_CONTENT_CHARS + 1), "status": "pending"}]
	]:
		_expect(not Tools.execute_tool("update_tasks", {"tasks": invalid_tasks}).get("success", true), "invalid task checklists should be rejected atomically")
	var too_many := []
	for index in range(TaskUtils.MAX_TASKS + 1):
		too_many.append({"content": "Task %d" % index, "status": "pending"})
	_expect(not Tools.execute_tool("update_tasks", {"tasks": too_many}).get("success", true), "task count should be bounded")
	var cleared: Dictionary = Tools.execute_tool("update_tasks", {"tasks": []})
	_expect(cleared.get("success", false) and cleared.get("data", {}).get("tasks", []).is_empty(), "an empty task list should clear the checklist")


func _test_path_boundaries() -> void:
	for invalid_path in ["/tmp/file.txt", "user://file.txt", "res://../outside.txt", "res://foo/../../outside.txt"]:
		_expect(not Tools._validate_path(invalid_path, false).is_empty(), "path should be rejected: " + invalid_path)
	for protected_path in ["res://addons/orca", "res://addons/orca/", "res://addons/orca/scripts/tools.gd"]:
		_expect(Tools._validate_path(protected_path, false).contains("Orca"), "Orca plugin path should be protected: " + protected_path)
	_expect(Tools._validate_path("res://", false).is_empty(), "project root should be readable")
	_expect(not Tools._validate_path("res://", true).is_empty(), "project root must not be writable as a file")
	_expect(Tools._validate_path("res://addons/orca_example/file.txt", true).is_empty(), "similarly named directories should not be blocked")
	_expect(Tools._validate_path("res://tests/../project.godot", false).is_empty(), "normalized in-project paths should be allowed")
	_expect(Tools._canonical_project_path("res://tests/../project.godot") == "res://project.godot", "accepted in-project aliases should canonicalize before safety checks")
	var protected_read: Dictionary = Tools.execute_tool("read_file", {"filepath": "res://addons/orca/scripts/tools.gd"})
	_expect(not protected_read.get("success", true), "public read_file should enforce plugin protection")
	var protected_list: Dictionary = Tools.execute_tool("list_directory", {"path": "res://addons/orca"})
	_expect(not protected_list.get("success", true), "public list_directory should enforce plugin protection")
	var protected_patch: Dictionary = Tools.prepare_file_patch("protected", "res://addons/orca/blocked.txt", "", [{"start_line": 1, "end_line": 0, "replacement": "blocked"}])
	_expect(not protected_patch.get("success", true), "patch preparation should enforce plugin protection")


func _test_symlink_boundary(fixture_absolute: String) -> void:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "macOS"]:
		print("tools_test: symlink boundary skipped on ", OS.get_name())
		return
	var target_absolute := fixture_absolute.path_join("target")
	_expect(DirAccess.make_dir_recursive_absolute(target_absolute) == OK, "symlink target should be created")
	var link_absolute := fixture_absolute.path_join("link")
	var exit_code := OS.execute("ln", PackedStringArray(["-s", target_absolute, link_absolute]))
	_expect(exit_code == 0, "symlink fixture should be created")
	if exit_code == 0:
		var error := Tools._validate_path(_fixture_path.path_join("link/file.txt"), true)
		_expect(error.contains("symbolic"), "paths traversing a symlink should be rejected")


func _test_patch_lifecycle() -> void:
	var existing_path := _fixture_path.path_join("existing.txt")
	_write(existing_path, "one\ntwo\n")
	var original := _read(existing_path)
	var proposal: Dictionary = Tools.prepare_file_patch("existing", existing_path, original.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "TWO"}])
	_expect(proposal.get("success", false), "existing-file proposal should succeed")
	_expect(_read(existing_path) == original, "preparing a proposal must not modify the file")
	_expect(proposal.get("old_content") == original, "proposal should retain reviewed old content")
	_expect(proposal.get("new_content") == "one\nTWO\n", "proposal should retain materialized new content")
	_expect(proposal.get("status") == "pending", "proposal should start pending")
	_expect(proposal.get("old_hash") == original.sha256_text(), "proposal should retain the old hash")
	_expect(proposal.get("new_hash") == str(proposal.get("new_content", "")).sha256_text(), "proposal should retain the new hash")
	var alias_proposal: Dictionary = Tools.prepare_file_patch("alias", _fixture_path.path_join("nested/../existing.txt"), original.sha256_text(), [{"start_line": 1, "end_line": 1, "replacement": "ONE"}])
	_expect(alias_proposal.get("success", false) and alias_proposal.get("filepath") == existing_path, "patch proposals should retain the canonical path used by editor-state and write checks")
	var stale := Tools.prepare_file_patch("stale", existing_path, "wrong-hash", [{"start_line": 1, "end_line": 1, "replacement": "ONE"}])
	_expect(not stale.get("success", true), "stale base hashes should be rejected")

	_write(existing_path, "independent\n")
	var conflict_result: String = Tools.apply_file_edit(proposal)
	_expect(conflict_result.begins_with("Error:"), "application should reject independently changed content")
	_expect(_read(existing_path) == "independent\n", "failed application must preserve independent content")

	_write(existing_path, original)
	var fresh: Dictionary = Tools.prepare_file_patch("fresh", existing_path, original.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "TWO"}])
	_expect(Tools.apply_file_edit(fresh).begins_with("Applied"), "fresh proposal should apply")
	_expect(_read(existing_path) == "one\nTWO\n", "application should write reviewed content")
	_expect(Tools.revert_file_edit(fresh).begins_with("Reverted"), "unchanged applied content should revert")
	_expect(_read(existing_path) == original, "revert should restore original content")

	var conflict_revert: Dictionary = Tools.prepare_file_patch("revert_conflict", existing_path, original.sha256_text(), [{"start_line": 1, "end_line": 1, "replacement": "ONE"}])
	_expect(Tools.apply_file_edit(conflict_revert).begins_with("Applied"), "revert conflict fixture should apply")
	_write(existing_path, "newer user content\n")
	_expect(Tools.revert_file_edit(conflict_revert).begins_with("Error:"), "revert should reject independently changed content")
	_expect(_read(existing_path) == "newer user content\n", "blocked revert must preserve independent content")

	var new_path := _fixture_path.path_join("created.txt")
	var bad_new: Dictionary = Tools.prepare_file_patch("bad_new", new_path, "not-empty", [{"start_line": 1, "end_line": 0, "replacement": "created"}])
	_expect(not bad_new.get("success", true), "new files should reject non-empty base hashes")
	var new_proposal: Dictionary = Tools.prepare_file_patch("new", new_path, "", [{"start_line": 1, "end_line": 0, "replacement": "created"}])
	_expect(new_proposal.get("success", false), "new-file proposal should accept an empty base hash")
	_expect(not FileAccess.file_exists(new_path), "preparing a new-file proposal must not create it")
	_expect(Tools.apply_file_edit(new_proposal).begins_with("Applied"), "new-file proposal should apply")
	_expect(_read(new_path) == "created", "new-file application should write reviewed content")
	_expect(Tools.revert_file_edit(new_proposal).begins_with("Reverted"), "new-file proposal should revert")
	_expect(not FileAccess.file_exists(new_path), "reverting a created file should remove it")


func _test_gdscript_patch_lifecycle() -> void:
	var script_path := _fixture_path.path_join("mutation_fixture.gd")
	var original := "extends Node\n\nvar value := 1\n\nfunc read_value() -> int:\n\treturn value\n"
	_write(script_path, original)
	var duplicate_class: Dictionary = Tools.prepare_file_patch("duplicate_class", script_path, original.sha256_text(), [{"start_line": 4, "end_line": 3, "replacement": "var value := 2\n"}])
	_expect(not duplicate_class.get("success", true), "a real .gd patch with a duplicate class variable should be rejected before review")
	_expect(not duplicate_class.get("diagnostics", []).is_empty(), "rejected duplicate class variable patches should return diagnostics")
	_expect(_read(script_path) == original, "invalid class-variable candidates must not modify the real .gd file")

	var duplicate_local: Dictionary = Tools.prepare_file_patch("duplicate_local", script_path, original.sha256_text(), [{"start_line": 6, "end_line": 6, "replacement": "\tvar local := value\n\tvar local := value + 1\n\treturn local"}])
	_expect(not duplicate_local.get("success", true), "a real .gd patch with a duplicate local variable should be rejected before review")
	_expect(not duplicate_local.get("diagnostics", []).is_empty(), "rejected duplicate local variable patches should return diagnostics")
	_expect(_read(script_path) == original, "invalid local-variable candidates must not modify the real .gd file")

	var valid: Dictionary = Tools.prepare_file_patch("valid_script", script_path, original.sha256_text(), [{"start_line": 3, "end_line": 3, "replacement": "var value := 2"}])
	_expect(valid.get("success", false), "a valid real .gd candidate should be prepared for review")
	_expect(Tools.apply_file_edit(valid).begins_with("Applied"), "a valid reviewed real .gd candidate should apply")
	_expect(_read(script_path) == str(valid.get("new_content", "")), "the applied real .gd file should equal the reviewed candidate")

	_expect(Tools.revert_file_edit(valid).begins_with("Reverted"), "the valid real .gd patch should revert")
	var tampered_content := valid.duplicate(true)
	tampered_content["new_content"] = str(tampered_content["new_content"]) + "\n"
	_expect(Tools.apply_file_edit(tampered_content).contains("reviewed hashes"), "apply should reject retained candidate content that disagrees with its hash")
	_expect(_read(script_path) == original, "tampered retained candidate content must not be written")
	var remapped_content := valid.duplicate(true)
	remapped_content["new_content"] = str(remapped_content["new_content"]) + "\n"
	remapped_content["new_hash"] = str(remapped_content["new_content"]).sha256_text()
	_expect(Tools.apply_file_edit(remapped_content).contains("canonical edits and review diff"), "apply should reject rehashed content that disagrees with the reviewed edits and diff")
	_expect(_read(script_path) == original, "rehashed unreviewed candidate content must not be written")

	var tampered_canonical := valid.duplicate(true)
	tampered_canonical["filepath"] = _fixture_path.path_join("nested/../mutation_fixture.gd")
	_expect(Tools.apply_file_edit(tampered_canonical).contains("canonical proposal fields"), "apply should reject a noncanonical retained filepath")
	_expect(_read(script_path) == original, "noncanonical retained proposal fields must not be written")


func _tool_names(definitions: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for definition in definitions:
		names.append(str(definition.get("function", {}).get("name", "")))
	return names


func _tool_definition(definitions: Array, name: String) -> Dictionary:
	for definition in definitions:
		if str(definition.get("function", {}).get("name", "")) == name:
			return definition
	return {}


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture file should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	_expect(file != null, "fixture file should open for reading: " + path)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _has_replacement_artifacts(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return false
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name.contains(".orca_tmp_") or name.contains(".orca_backup_"):
			directory.list_dir_end()
			return true
		name = directory.get_next()
	directory.list_dir_end()
	return false


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if directory.current_is_dir() and not directory.is_link(name):
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		name = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("tools_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("tools_test: ", failure)
	quit(1)
