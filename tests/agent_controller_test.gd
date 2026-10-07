extends SceneTree

const AgentController = preload("res://addons/orca/scripts/agent_controller.gd")
const ContextBudget = preload("res://addons/orca/scripts/context_budget.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")
const AgentCompatibilityProbe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const ToolLoopGuard = preload("res://addons/orca/scripts/tool_loop_guard.gd")

class FakeApiClient:
	extends Node
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	var requests: Array[Dictionary] = []
	var requesting := false
	var cancelled := false
	var synchronous_failure: Dictionary = {}

	func send_chat_completion(messages: Array, tools: Array, provider_config: Dictionary = {}, request_options: Dictionary = {}) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "provider_config": provider_config.duplicate(true), "request_options": request_options.duplicate(true)})
		requesting = true
		if not synchronous_failure.is_empty():
			requesting = false
			request_failed.emit(current_request_id(), synchronous_failure.duplicate(true))

	func is_requesting() -> bool:
		return requesting

	func cancel_request() -> void:
		cancelled = true
		requesting = false
		request_cancelled.emit(current_request_id())

	func last_request_may_have_usage() -> bool:
		return false

	func current_request_id() -> int:
		return int(requests[-1].get("request_options", {}).get("lifecycle_request_id", 0)) if not requests.is_empty() else 0

	func complete(response: Dictionary, request_id: int = -1) -> void:
		requesting = false
		request_completed.emit(current_request_id() if request_id < 0 else request_id, response)

	func fail(error: Dictionary, request_id: int = -1) -> void:
		requesting = false
		request_failed.emit(current_request_id() if request_id < 0 else request_id, error)


class FakeGameProcessService:
	extends RefCounted
	var starts := 0
	var stops := 0
	var run_id := 0
	var snapshot := {"run_id": 0, "sequence": 0, "state": "idle", "scene_path": "", "verification_status": "unverified", "diagnostics": [], "stdout": "", "stderr": ""}
	var terminal_on_observe := false
	var active := false
	var scripted_run_results: Array[Dictionary] = []
	var start_verifications: Array[Dictionary] = []
	var started_criteria_ids: Array[String] = []
	var observe_calls: Array[Dictionary] = []
	var verify_calls: Array[int] = []
	var operation_log: Array[String] = []
	var observed_runs: Dictionary = {}

	func start_current_scene(verification: Dictionary = {}) -> Dictionary:
		starts += 1
		active = true
		run_id += 1
		var criteria_id := JSON.stringify(verification).sha256_text() if not verification.is_empty() else ""
		start_verifications.append(verification.duplicate(true))
		started_criteria_ids.append(criteria_id)
		operation_log.append("start:%d" % run_id)
		snapshot = {"run_id": run_id, "sequence": 1, "state": "running", "scene_path": "res://main.tscn", "verification_status": "pending" if not verification.is_empty() else "unverified", "verification_configured": not verification.is_empty(), "diagnostics": [], "stdout": "", "stderr": "", "criteria_id": criteria_id}
		return {"success": true, "content": "started current", "outcome": "completed", "data": snapshot.duplicate(true)}

	func start_main_scene(verification: Dictionary = {}) -> Dictionary:
		return start_current_scene(verification)

	func stop_game() -> Dictionary:
		stops += 1
		operation_log.append("stop:%d" % run_id)
		active = false
		snapshot["state"] = "stopped"
		return {"success": true, "content": "stopped with final evidence", "outcome": "completed", "data": {"state": "stopped"}}

	func is_running() -> bool:
		return active

	func get_snapshot() -> Dictionary:
		return snapshot.duplicate(true)

	func observe_run(requested_run_id: int, after_sequence: int = -1) -> Dictionary:
		if requested_run_id != run_id:
			return {"success": false, "error": "unknown"}
		observe_calls.append({"run_id": requested_run_id, "after_sequence": after_sequence})
		if not scripted_run_results.is_empty() and requested_run_id <= scripted_run_results.size() and not observed_runs.has(requested_run_id):
			observed_runs[requested_run_id] = true
			operation_log.append("observe:%d" % requested_run_id)
			var scripted_snapshot: Dictionary = scripted_run_results[requested_run_id - 1].get("snapshot", {})
			for key in scripted_snapshot:
				snapshot[key] = scripted_snapshot[key]
			snapshot["run_id"] = requested_run_id
			if str(snapshot.get("state", "running")) not in ["running", "timeout_stop_failed", "shutdown_stop_failed"]:
				active = false
		if terminal_on_observe:
			snapshot["state"] = "exited"
			snapshot["sequence"] = int(snapshot.get("sequence", 0)) + 1
			snapshot["exit_code"] = 0
		return {"success": true, "snapshot": snapshot.duplicate(true), "changed_since": int(snapshot.get("sequence", 0)) > after_sequence}

	func criteria_id_for(verification: Dictionary) -> Dictionary:
		return {"success": true, "criteria_id": JSON.stringify(verification).sha256_text() if not verification.is_empty() else ""}

	func verify_run(requested_run_id: int) -> Dictionary:
		if requested_run_id != run_id:
			return {"success": false, "error": "unknown"}
		verify_calls.append(requested_run_id)
		operation_log.append("verify:%d" % requested_run_id)
		if not scripted_run_results.is_empty() and requested_run_id <= scripted_run_results.size():
			var verification: Dictionary = scripted_run_results[requested_run_id - 1].get("verification", {}).duplicate(true)
			verification["run_id"] = requested_run_id
			verification["criteria_id"] = str(snapshot.get("criteria_id", ""))
			return {"success": true, "verification": verification}
		return {"success": true, "verification": {"run_id": run_id, "status": str(snapshot.get("verification_status", "unverified")), "claim": "fixture", "checks": []}}


class FakeTools:
	extends RefCounted
	const MAX_WORK_MODE_REASON_CHARS := 240
	var prepare_calls := 0
	var promote_calls := 0
	var apply_calls := 0
	var revert_calls := 0
	var execute_calls := 0
	var changing_results := false
	var apply_result := "Applied changes to res://fixture.txt"
	var revert_result := "Reverted changes to res://fixture.txt"
	var execute_log: Array[Dictionary] = []
	var prepared_change_ids: Array[String] = []
	var applied_change_ids: Array[String] = []
	var enforce_patch_hashes := false
	var current_patch_hash := "old-hash"
	var patch_hash_serial := 0

	func get_tool_definitions(include_edit_tools: bool = true, include_work_mode_request: bool = false) -> Array:
		var definitions := [
			{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "inspect_scene", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "inspect_project_settings", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "observe_game_run", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "verify_game_run", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "update_tasks", "parameters": {"type": "object"}}}
		]
		if include_work_mode_request:
			definitions.append({"type": "function", "function": {"name": "request_work_mode", "parameters": {"type": "object"}}})
		if include_edit_tools:
			definitions.append({"type": "function", "function": {"name": "apply_patch", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "propose_input_map_changes", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "propose_main_scene_change", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "propose_project_settings_changes", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "propose_scene_changes", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "run_current_scene", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "run_main_scene", "parameters": {"type": "object"}}})
			definitions.append({"type": "function", "function": {"name": "stop_game", "parameters": {"type": "object"}}})
		return definitions

	func execute_tool(tool_name: String, _arguments: Dictionary, game_process_service = null) -> Dictionary:
		execute_calls += 1
		execute_log.append({"name": tool_name, "arguments": _arguments.duplicate(true)})
		if tool_name == "run_current_scene":
			return game_process_service.start_current_scene(_arguments.get("verification", {}))
		if tool_name == "run_main_scene":
			return game_process_service.start_main_scene(_arguments.get("verification", {}))
		if tool_name == "stop_game":
			return game_process_service.stop_game()
		if tool_name == "observe_game_run":
			var observed: Dictionary = game_process_service.observe_run(int(_arguments.get("run_id", 0)), int(_arguments.get("after_sequence", -1)))
			return {"success": observed.get("success", false), "content": "observed", "outcome": "completed" if observed.get("success", false) else "failed", "data": observed.get("snapshot", {})}
		if tool_name == "verify_game_run":
			var verified: Dictionary = game_process_service.verify_run(int(_arguments.get("run_id", 0)))
			return {"success": verified.get("success", false), "content": "Verification: " + JSON.stringify(verified.get("verification", {})), "outcome": "completed" if verified.get("success", false) else "failed", "data": verified.get("verification", {})}
		if tool_name == "update_tasks":
			var validation := TaskUtils.validate_tasks(_arguments.get("tasks", null))
			if not validation.get("success", false):
				return {"success": false, "content": "Error: " + str(validation.get("error", "invalid")), "outcome": "failed", "data": {}}
			return {"success": true, "content": "updated", "outcome": "completed", "data": {"tasks": validation.get("tasks", [])}}
		if tool_name == "read_file" and enforce_patch_hashes:
			return {"success": true, "content": "fixture sha256: " + current_patch_hash, "outcome": "completed", "data": {"sha256": current_patch_hash}}
		var suffix := " " + str(execute_calls) if changing_results else ""
		return {"success": true, "content": "executed " + tool_name + suffix, "outcome": "completed", "data": {}}

	func prepare_file_patch(change_id: String, filepath: String, _base_hash: String, edits: Array) -> Dictionary:
		prepare_calls += 1
		prepared_change_ids.append(change_id)
		if enforce_patch_hashes and _base_hash != current_patch_hash:
			return {"success": false, "error": "stale fixture hash"}
		patch_hash_serial += 1
		return {
			"success": true,
			"id": change_id,
			"filepath": filepath,
			"old_content": "old\n",
			"new_content": "new\n",
			"old_hash": current_patch_hash,
			"new_hash": "new-hash-%d" % patch_hash_serial,
			"existed": true,
			"edits": edits,
			"diff": {"additions": 1, "deletions": 1},
			"validation": {"valid": true},
			"status": "pending"
		}

	func prepare_reviewed_change(tool_name: String, change_id: String, arguments: Dictionary) -> Dictionary:
		if tool_name == "apply_patch":
			return prepare_file_patch(change_id, str(arguments.get("filepath", "")), str(arguments.get("base_hash", "")), arguments.get("edits", []))
		prepare_calls += 1
		if tool_name == "propose_scene_changes":
			var operations: Array = arguments.get("operations", [])
			if operations.size() == 1 and str(operations[0].get("operation", "")) in ["attach_script", "detach_script"]:
				return {
					"success": true, "id": change_id, "kind": "scene", "tool_name": tool_name,
					"approval_stage": "script_trust", "filepath": str(arguments.get("scene_path", "")),
					"existed": true, "old_content": "private old scene", "old_hash": "old-hash",
					"script_content": "private script", "trust_binding": "private trust",
					"operations": operations.duplicate(true),
					"scene_summary": {"operation": str(operations[0].get("operation", "")), "node_path": str(operations[0].get("node_path", "")), "script_path": str(operations[0].get("script_path", "")), "trust_review": true},
					"validation": {"valid": true}, "status": "pending"
				}
			return {
				"success": true,
				"id": change_id,
				"kind": "scene",
				"tool_name": tool_name,
				"filepath": str(arguments.get("scene_path", "")),
				"existed": false,
				"old_content": "",
				"new_content": "private scene bytes",
				"old_hash": "old-hash",
				"new_hash": "new-hash",
				"operations": arguments.get("operations", []).duplicate(true),
				"scene_summary": {"node_count": 1, "root_type": "Node2D", "root_name": "World"},
				"validation": {"valid": true},
				"status": "pending"
			}
		if tool_name == "propose_main_scene_change":
			return {
				"success": true,
				"id": change_id,
				"kind": "main_scene",
				"filepath": "res://project.godot",
				"old_content": "private old",
				"new_content": "private new",
				"old_hash": "old-hash",
				"new_hash": "new-hash",
				"old_value": null,
				"new_value": "uid://private",
				"old_scene_path": "",
				"new_scene_path": str(arguments.get("scene_path", "")),
				"validation": {"valid": true},
				"status": "pending"
			}
		if tool_name == "propose_project_settings_changes":
			return {
				"success": true,
				"id": change_id,
				"kind": "project_settings",
				"filepath": "res://project.godot",
				"old_content": "private old",
				"new_content": "private new",
				"old_hash": "old-hash",
				"new_hash": "new-hash",
				"old_values": {"display/window/size/viewport_width": 1152},
				"new_values": {"display/window/size/viewport_width": 1920},
				"setting_paths": ["display/window/size/viewport_width"],
				"review": [{"setting_path": "display/window/size/viewport_width", "label": "Viewport width", "type": "int", "before": 1152, "after": 1920}],
				"validation": {"valid": true},
				"status": "pending"
			}
		return {
			"success": true,
			"id": change_id,
			"kind": "input_map",
			"filepath": "res://project.godot",
			"old_hash": "old-hash",
			"new_hash": "new-hash",
			"review": [{"operation": "add", "action": "jump", "before": null, "after": {"deadzone": 0.5, "events": []}}],
			"action_names": ["jump"],
			"validation": {"valid": true},
			"status": "pending"
		}

	func apply_file_edit(proposal: Dictionary) -> String:
		apply_calls += 1
		applied_change_ids.append(str(proposal.get("id", "")))
		if enforce_patch_hashes:
			current_patch_hash = str(proposal.get("new_hash", current_patch_hash))
		if apply_result.begins_with("Cleanup required:"):
			proposal["cleanup_required"] = true
			proposal["exact_applied_state"] = true
		elif apply_result.begins_with("Recovery required:"):
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
		else:
			proposal["exact_applied_state"] = true
		return apply_result

	func apply_reviewed_change(proposal: Dictionary) -> String:
		return apply_file_edit(proposal)

	func promote_script_trust(proposal: Dictionary) -> Dictionary:
		promote_calls += 1
		var operation: Dictionary = proposal.get("operations", [])[0]
		return {
			"success": true, "id": str(proposal.get("id", "")), "kind": "scene", "tool_name": "propose_scene_changes",
			"approval_stage": "candidate", "filepath": str(proposal.get("filepath", "")), "existed": true,
			"old_content": "private old scene", "new_content": "private candidate scene", "old_hash": "old-hash", "new_hash": "new-hash",
			"script_content": "private script", "trust_binding": "private trust", "operations": [operation],
			"scene_summary": {"operation": str(operation.get("operation", "")), "node_path": str(operation.get("node_path", "")), "node_type": "Node2D", "script_base": "Node2D", "before_script": "", "after_script": str(operation.get("script_path", ""))},
			"validation": {"valid": true}, "status": "pending"
		}

	func revert_file_edit(proposal: Dictionary) -> String:
		revert_calls += 1
		if revert_result.begins_with("Recovery required:"):
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
		return revert_result

	func revert_reviewed_change(proposal: Dictionary) -> String:
		return revert_file_edit(proposal)


class GuidanceController:
	extends AgentController
	var instruction_result := {"success": true, "found": true, "wrapped_content": "WRAPPED EXACT GUIDANCE"}
	var skill_result := {
		"success": true,
		"skills": [{"name": "Fixture Skill", "description": "Catalog description", "slug": "fixture", "path": "res://skills/fixture/SKILL.md", "body": "SECRET SKILL BODY", "wrapped_body": "SECRET WRAPPER"}],
		"directory_count": 1,
		"scanned_directory_count": 1,
		"truncated": false,
		"skipped": []
	}

	func _load_project_instructions() -> Dictionary:
		return instruction_result.duplicate(true)

	func _discover_project_skills() -> Dictionary:
		return skill_result.duplicate(true)


var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_modes_and_plan_runtime_denial()
	await _test_work_mode_escalation()
	await _test_local_chat_tool_denial()
	await _test_request_workflow_state()
	await _test_request_ownership()
	await _test_support_request_metadata()
	await _test_reentrant_request_lifecycle()
	await _test_synchronous_tool_and_approval_boundaries()
	await _test_work_approval()
	await _test_mutation_recovery_classification()
	await _test_work_rejection_protocol()
	await _test_cancellation_protocol()
	await _test_task_state()
	await _test_task_context_refresh()
	await _test_scene_inspection_permission()
	await _test_project_settings_inspection_permission()
	await _test_input_map_approval_and_plan_denial()
	await _test_main_scene_approval_and_privacy()
	await _test_project_settings_approval_and_plan_denial()
	await _test_scene_creation_approval_and_privacy()
	await _test_scene_script_two_stage_approval()
	await _test_scene_script_second_stage_resolution()
	await _test_game_process_permissions()
	await _test_bounded_run_observation()
	await _test_long_task_run_fix_verify()
	await _test_tool_call_count_bound()
	await _test_tool_batch_barriers()
	await _test_malformed_tool_batch_regeneration()
	await _test_project_guidance_context()
	await _test_runtime_progress_normalization()
	await _test_loop_guard_duplicate_denial()
	await _test_loop_guard_cycle_final_response()
	await _test_loop_guard_empty_final_response()
	await _test_loop_guard_cancellation_and_progress()
	await _test_tool_round_cap_finalization()
	await _test_recoverable_provider_failure()
	await _test_applied_change_recovery_does_not_replay()
	await _test_incomplete_protocol_refuses_recovery()
	await _test_context_pressure_finalization()
	await _test_context_budget_integration()
	await _test_plan_revert_denial()
	_finish()


func _test_modes_and_plan_runtime_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(controller.get_mode() == AgentController.AgentMode.BUILD, "Work should be the default mode")
	_expect(_tool_names(controller._get_tool_definitions()).has("apply_patch"), "Work schema should include apply_patch")
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "switching to Plan should succeed while idle")
	_expect(not _tool_names(controller._get_tool_definitions()).has("apply_patch"), "Plan schema should omit apply_patch")
	controller._is_running = true
	_expect(not controller.set_mode(AgentController.AgentMode.BUILD), "mode changes should be blocked while running")
	controller._is_running = false
	var result: Dictionary = await controller._execute_tool_call(_patch_call("plan_call"))
	_expect(result.get("outcome") == "failed", "Plan runtime guard should reject apply_patch")
	_expect(str(result.get("result", "")).contains("unavailable in Plan mode"), "Plan denial should explain the mode restriction")
	_expect(tools.prepare_calls == 0, "Plan denial must happen before patch preparation")
	_expect(tools.apply_calls == 0, "Plan denial must never apply a patch")
	await _free_controller(controller)


func _test_work_mode_escalation() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "Work-mode escalation should start from Plan")
	_expect(_tool_names(controller._get_tool_definitions()).has("request_work_mode") and not _tool_names(controller._get_tool_definitions()).has("apply_patch"), "Plan should expose escalation without Work mutations")
	var requests: Array[Dictionary] = []
	controller.work_mode_requested.connect(func(turn_id: int, request: Dictionary):
		requests.append({"turn_id": turn_id, "request": request.duplicate(true)})
		controller.resolve_work_mode_request(str(request.get("call_id", "")), turn_id, true)
	)
	controller.send_user_message("Implement the feature")
	api.complete(_tool_response([_work_mode_call("mode_yes", "Implementation requires reviewed project changes.")]))
	await process_frame
	_expect(requests.size() == 1 and controller.get_mode() == AgentController.AgentMode.BUILD, "an exact approved request should switch the active turn to Work")
	_expect(api.requests.size() == 2 and _tool_names(api.requests[-1].get("tools", [])).has("apply_patch") and not _tool_names(api.requests[-1].get("tools", [])).has("request_work_mode"), "approval should continue automatically with a fresh Work request")
	_expect(_tool_result_count(controller.message_history, "mode_yes") == 1 and str(controller.message_history[0].get("content", "")).contains("You are in Work mode"), "approval should retain one protocol result and regenerate the authoritative Work prompt")
	api.fail({"message": "follow-up failure", "category": "connection", "phase": "receiving_response"})
	_expect(controller.last_failure_was_checkpointed() and not controller.is_busy(), "failure after approved escalation should retain a safe non-replayable recovery checkpoint")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	var mixed_requests := [0]
	controller.work_mode_requested.connect(func(_turn_id: int, _request: Dictionary): mixed_requests[0] += 1)
	controller.send_user_message("Try a mixed batch")
	api.complete(_tool_response([_work_mode_call("mode_mixed", "Work is needed."), _work_mode_call("mode_duplicate", "Ask again."), _patch_call("smuggled_patch")]))
	await process_frame
	_expect(controller.get_mode() == AgentController.AgentMode.PLAN and mixed_requests[0] == 0 and tools.prepare_calls == 0, "a mixed escalation batch must be rejected before a decision or mutation preparation")
	_expect(api.requests.size() == 2 and controller.is_busy(), "a mixed escalation batch should receive one fresh correction request")
	_expect(_tool_result_count(controller.message_history, "mode_mixed") == 0 and _tool_result_count(controller.message_history, "mode_duplicate") == 0 and _tool_result_count(controller.message_history, "smuggled_patch") == 0, "a rejected escalation batch must not enter tool protocol history")
	_expect(not JSON.stringify(controller.message_history).contains("mode_mixed") and not JSON.stringify(controller.message_history).contains("smuggled_patch"), "rejected Plan batch details must remain absent from retained history")
	controller.cancel_current_request()
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	controller.work_mode_requested.connect(func(turn_id: int, request: Dictionary):
		controller.resolve_work_mode_request("wrong-call", turn_id, true)
		_expect(controller.get_mode() == AgentController.AgentMode.PLAN and controller._pending_work_mode_call_id == str(request.get("call_id", "")), "mismatched decisions must leave the exact request pending")
		controller.resolve_work_mode_request(str(request.get("call_id", "")), turn_id, false)
	)
	controller.send_user_message("Remain in Plan")
	api.complete(_tool_response([_work_mode_call("mode_no", "Work would permit implementation.")]))
	await process_frame
	_expect(controller.get_mode() == AgentController.AgentMode.PLAN, "declining escalation should remain in Plan")
	_expect(api.requests.size() == 2 and not _tool_names(api.requests[-1].get("tools", [])).has("request_work_mode"), "a declined turn must not expose another escalation request")
	controller.cancel_current_request()
	var request_count := api.requests.size()
	_expect(controller.set_mode(AgentController.AgentMode.BUILD) and api.requests.size() == request_count, "after declining and ending the turn, the user may switch manually without replaying the task")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	var cancelled_turns: Array[int] = []
	controller.request_cancelled.connect(func(turn_id: int): cancelled_turns.append(turn_id))
	controller.work_mode_requested.connect(func(_turn_id: int, _request: Dictionary): controller.call_deferred("cancel_current_request"))
	controller.send_user_message("Cancel the choice")
	api.complete(_tool_response([_work_mode_call("mode_cancel", "Work is needed.")]))
	await process_frame
	await process_frame
	_expect(controller.get_mode() == AgentController.AgentMode.PLAN and not controller.is_busy() and cancelled_turns.size() == 1, "Stop during escalation should finish once and remain in Plan")
	_expect(_tool_result_count(controller.message_history, "mode_cancel") == 1, "cancelled escalation should retain exactly one matching tool result")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	var invalid: Dictionary = await controller._execute_tool_call(_work_mode_call("mode_invalid", "Reason"))
	_expect(invalid.get("outcome") == "failed" and str(invalid.get("result", "")).contains("only from an active Plan-mode response"), "Work mode must runtime-deny unsolicited escalation calls")
	controller.set_mode(AgentController.AgentMode.PLAN)
	invalid = await controller._execute_tool_call(_work_mode_call("mode_bad_reason", "bad\nreason"))
	_expect(invalid.get("outcome") == "failed" and controller.get_mode() == AgentController.AgentMode.PLAN, "malformed escalation reasons must fail without changing mode")
	await _free_controller(controller)


func _test_local_chat_tool_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	for local_config in [
		{"provider": "ollama", "base_url": "http://127.0.0.1:11434/v1", "api_key": "", "model": "fixture-local"},
		{"provider": "custom", "base_url": "http://localhost:1234/v1", "api_key": "fixture", "model": "fixture-local"},
		{"provider": "custom", "base_url": "https://compatible.example/v1", "confirmed_origin": "https://compatible.example:443", "api_key": "fixture", "model": "fixture-custom"},
		{"provider": "openai", "base_url": "http://127.0.0.1:18473/v1", "confirmed_origin": "http://127.0.0.1:18473", "api_key": "fixture", "model": "fixture-local"}
	]:
		controller._turn_provider_config = local_config
		_expect(controller._get_tool_definitions().is_empty(), "editable or overridden endpoints should start in Chat mode until compatibility opt-in")
	controller._turn_provider_config = {"provider": "custom", "base_url": "http://localhost:1234/v1", "api_key": "fixture", "model": "fixture-local"}
	var result: Dictionary = await controller._execute_tool_call({
		"id": "unsolicited_local_tool",
		"type": "function",
		"function": {"name": "read_file", "arguments": "{\"filepath\":\"res://project.godot\"}"}
	})
	_expect(result.get("outcome") == "failed" and str(result.get("result", "")).contains("Tools are disabled"), "unsolicited local tool calls should fail at runtime")
	_expect(tools.execute_calls == 0 and tools.prepare_calls == 0, "local Chat denial must occur before any tool side effect")
	var enabled_config := {"provider": "ollama", "base_url": "http://127.0.0.1:11434/v1", "api_key": "", "model": "fixture-local", "reasoning_effort": "default", "confirmed_origin": ""}
	var binding_result := AgentCompatibilityProbe.create_binding(enabled_config)
	var record: Dictionary = binding_result.get("binding", {}).duplicate(true)
	record["enabled"] = true
	enabled_config["agent_compatibility"] = record
	controller._turn_provider_config = enabled_config
	_expect(not controller._get_tool_definitions().is_empty(), "an exact passed and explicitly enabled local binding should expose normal mode tools")
	enabled_config["model"] = "different-model"
	controller._turn_provider_config = enabled_config
	_expect(controller._get_tool_definitions().is_empty(), "changing the exact model should invalidate local Agent opt-in")
	await _free_controller(controller)


func _test_request_workflow_state() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var states: Array[Dictionary] = []
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, details: Dictionary):
		states.append({"state": state, "details": details.duplicate(true)})
	)
	controller.send_user_message("Inspect the project")
	_expect(states.size() == 1 and states[0].get("state") == "thinking" and not bool(states[0].get("details", {}).get("follow_up", true)), "the initial provider request should expose a thinking workflow state")
	await _deliver_completion(controller, _tool_response([
		{"id": "workflow_read", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}
	]))
	_expect(states.size() >= 2 and states[-1].get("state") == "thinking" and bool(states[-1].get("details", {}).get("follow_up", false)), "a provider request after tools should expose a follow-up preparing state")
	await _free_controller(controller)


func _test_request_ownership() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var messages: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var cancellations: Array[int] = []
	var stream_text := [""]
	controller.message_received.connect(func(turn_id: int, _role: String, content: String): messages.append({"turn_id": turn_id, "content": content}))
	controller.error_occurred.connect(func(turn_id: int, message: String): errors.append({"turn_id": turn_id, "message": message}))
	controller.request_cancelled.connect(func(turn_id: int): cancellations.append(turn_id))
	controller.message_stream_delta.connect(func(_turn_id: int, content: String): stream_text[0] += content)

	controller.send_user_message("first")
	var first_turn: int = controller._active_turn_id
	var first_request := api.current_request_id()
	api.complete({"choices": [{"message": {"role": "assistant", "content": "first complete"}}]})
	controller.send_user_message("second")
	var second_turn: int = controller._active_turn_id
	var second_request := api.current_request_id()
	var history_size: int = controller.message_history.size()
	api.stream_delta.emit(first_request, "stale delta")
	api.request_completed.emit(first_request, {"choices": [{"message": {"role": "assistant", "content": "stale completion"}}]})
	api.request_failed.emit(first_request, {"message": "stale failure"})
	api.request_cancelled.emit(first_request)
	_expect(second_turn > first_turn and second_request > first_request, "new turns should own monotonic turn and provider request IDs")
	_expect(controller.is_busy() and controller.message_history.size() == history_size and stream_text[0].is_empty(), "stale stream and completion events must not mutate the newer turn")
	_expect(errors.is_empty() and cancellations.is_empty(), "stale failure and cancellation events must not terminate the newer turn")
	api.request_cancelled.emit(second_request)
	api.request_cancelled.emit(second_request)
	_expect(cancellations == [second_turn] and not controller.is_busy(), "matching cancellation should finish once before ownership is invalidated")
	await _free_controller(controller)


	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	var observed_turn_ids: Array[int] = []
	var terminal_messages: Array[Dictionary] = []
	controller.workflow_state_changed.connect(func(turn_id: int, _state: String, _details: Dictionary): observed_turn_ids.append(turn_id))
	controller.message_received.connect(func(turn_id: int, _role: String, content: String): terminal_messages.append({"turn_id": turn_id, "content": content}))
	controller.send_user_message("follow tools")
	var tool_turn: int = controller._active_turn_id
	var initial_request := api.current_request_id()
	api.complete(_tool_response([{"id": "owned_read", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}]))
	await process_frame
	var follow_up_request := api.current_request_id()
	_expect(follow_up_request > initial_request, "every tool follow-up should use a distinct provider request ID")
	_expect(observed_turn_ids.all(func(turn_id: int): return turn_id == tool_turn), "one turn ID should span initial and follow-up provider requests")
	api.complete({"choices": [{"message": {"role": "assistant", "content": "done"}}]})
	var completed_history: Array = controller.message_history.duplicate(true)
	var completed_usage: Dictionary = {
		"requests": controller._completed_requests,
		"input": controller._session_input_tokens,
		"output": controller._session_output_tokens,
		"cost": controller._session_cost_usd
	}
	var completed_message_count: int = terminal_messages.size()
	api.request_completed.emit(follow_up_request, {"choices": [{"message": {"role": "assistant", "content": "duplicate"}}]})
	api.request_failed.emit(follow_up_request, {"message": "duplicate failure"})
	api.request_cancelled.emit(follow_up_request)
	_expect(not controller.is_busy(), "duplicate terminal events must not reopen a completed turn")
	_expect(controller.message_history == completed_history, "duplicate terminal events must not mutate completed history")
	_expect(controller._completed_requests == completed_usage["requests"] and controller._session_input_tokens == completed_usage["input"] and controller._session_output_tokens == completed_usage["output"] and is_equal_approx(controller._session_cost_usd, completed_usage["cost"]), "duplicate terminal events must not mutate usage")
	_expect(terminal_messages.size() == completed_message_count, "duplicate terminal events must not emit another assistant message")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	api.synchronous_failure = {"message": "synchronous configuration failure", "category": "configuration"}
	var synchronous_errors: Array[Dictionary] = []
	controller.error_occurred.connect(func(turn_id: int, message: String): synchronous_errors.append({"turn_id": turn_id, "message": message}))
	controller.send_user_message("invalid config")
	var sent_request_id := int(api.requests[0].get("request_options", {}).get("lifecycle_request_id", 0))
	_expect(sent_request_id > 0 and controller._expected_provider_request_id == 0, "synchronous failures should be owned by the ID set before APIClient is called")
	_expect(synchronous_errors.size() == 1 and int(synchronous_errors[0].get("turn_id", 0)) > 0 and not controller.is_busy(), "an owned synchronous failure should terminate exactly its originating turn")
	await _free_controller(controller)


func _test_support_request_metadata() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	controller.send_user_message("private prompt")
	var initial: Dictionary = controller.support_request_metadata()
	_expect(initial.get("provider_type") == "openai" and initial.get("outcome") == "in_progress" and initial.get("stage") == "initial" and initial.get("interaction_mode") == "work", "support metadata should describe the request-time provider and initial Work request coarsely")
	initial["outcome"] = "tampered"
	_expect(controller.support_request_metadata().get("outcome") == "in_progress", "support metadata callers must receive a deep copy")
	var request_id := api.current_request_id()
	api.fail({"message": "private provider body", "category": "http", "phase": "receiving_response", "http_status": 429, "retryable": true, "response_started": true, "partial_response": false})
	var failed: Dictionary = controller.support_request_metadata()
	var serialized := JSON.stringify(failed)
	_expect(failed.get("outcome") == "failed" and failed.get("failure_category") == "http" and failed.get("http_status") == 429 and failed.get("retryable") == true, "matching failures should retain only coarse structured support fields")
	_expect(not serialized.contains("private provider body") and not serialized.contains("private prompt"), "support metadata must not retain provider errors or prompts")
	api.request_failed.emit(request_id, {"message": "stale secret", "category": "tls", "phase": "connecting"})
	_expect(controller.support_request_metadata() == failed, "stale terminal callbacks must not overwrite support metadata")

	controller.send_user_message("cancel me")
	controller.cancel_current_request()
	_expect(controller.support_request_metadata().get("outcome") == "cancelled", "matching cancellation should be represented without request content")
	controller.send_user_message("complete me")
	api.complete({"choices": [{"message": {"role": "assistant", "content": "done"}}]})
	_expect(controller.support_request_metadata().get("outcome") == "completed" and controller.support_request_metadata().get("response_started") == true, "matching completion should update the support outcome and response state")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.send_user_message("tool loop")
	api.complete(_tool_response([{"id": "support_read", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}]))
	await process_frame
	var follow_up: Dictionary = controller.support_request_metadata()
	_expect(follow_up.get("stage") == "follow_up" and follow_up.get("outcome") == "in_progress" and follow_up.get("tools_offered") == true, "tool continuation should replace the snapshot with a follow-up request stage")
	controller.cancel_current_request()
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.send_user_message("cancel after provider completion")
	api.complete(_tool_response([{"id": "support_approval", "type": "function", "function": {"name": "apply_patch", "arguments": "{\"filepath\":\"res://fixture.txt\",\"base_hash\":\"hash\",\"edits\":[]}"}}]))
	await process_frame
	controller.cancel_current_request()
	_expect(controller.support_request_metadata().get("outcome") == "completed", "turn cancellation after a completed provider tool response must not relabel that provider request as cancelled")
	await _free_controller(controller)


func _test_reentrant_request_lifecycle() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	controller.request_state_changed.connect(func(_turn_id: int, active: bool):
		if active:
			controller.cancel_current_request()
	)
	controller.send_user_message("cancel during activation")
	_expect(api.requests.is_empty() and controller.message_history.size() == 1 and not controller.is_busy(), "cancellation from the initial active-state signal must not append user history or launch transport")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary):
		if state == "thinking":
			controller.cancel_current_request()
	)
	controller.send_user_message("cancel during thinking")
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancellation from the thinking signal must not launch an orphan provider request")
	_expect(controller._active_turn_id == 0 and controller._expected_provider_request_id == 0, "thinking cancellation should invalidate turn and provider ownership")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller.send_user_message("prepare finalization")
	api.requests.clear()
	api.requesting = false
	controller._expected_provider_request_id = 0
	controller._loop_final_request = true
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary):
		if state == "finalizing":
			controller.cancel_current_request()
	)
	controller._send_current_request()
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancellation from the finalizing signal must not launch an orphan provider request")
	_expect(controller._active_turn_id == 0 and controller._expected_provider_request_id == 0, "finalizing cancellation should invalidate turn and provider ownership")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	var old_turn := [0]
	var started_new_turn := [false]
	var stream_turns: Array[int] = []
	controller.request_state_changed.connect(func(turn_id: int, active: bool):
		if not active and turn_id == old_turn[0] and not started_new_turn[0]:
			started_new_turn[0] = true
			controller.send_user_message("reentrant next turn")
	)
	controller.message_stream_delta.connect(func(turn_id: int, _content: String): stream_turns.append(turn_id))
	controller.send_user_message("old turn")
	old_turn[0] = controller._active_turn_id
	var old_request := api.current_request_id()
	api.complete({"choices": [{"message": {"role": "assistant", "content": "old complete"}}]})
	var new_turn: int = controller._active_turn_id
	var new_request := api.current_request_id()
	_expect(started_new_turn[0] and controller.is_busy() and new_turn > old_turn[0], "a request-state listener should be able to start a new turn after the old ownership is invalidated")
	_expect(new_request > old_request and controller._expected_provider_request_id == new_request, "old terminal emissions must preserve reentrant new-turn provider ownership")
	api.stream_delta.emit(new_request, "new delta")
	_expect(stream_turns == [new_turn], "reentrant new-turn stream events should retain the new turn ID")
	await _free_controller(controller)


func _test_synchronous_tool_and_approval_boundaries() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	controller.tool_execution_started.connect(func(_turn_id: int, _call_id: String, _tool_name: String, _arguments: Dictionary): controller.cancel_current_request())
	controller.send_user_message("cancel before tool side effect")
	api.complete(_tool_response([{"id": "cancel_before_execute", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}]))
	await process_frame
	_expect(tools.execute_calls == 0 and not controller.is_busy(), "synchronous cancellation from tool-start must prevent tool side effects and finish the turn")
	_expect(_tool_result_count(controller.message_history, "cancel_before_execute") == 1 and _protocol_is_valid(controller.message_history), "tool-start cancellation must retain one protocol-valid cancellation result")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	tools = fixture["tools"]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.resolve_edit(str(proposal.get("id", "")), turn_id, true))
	controller.send_user_message("approve synchronously")
	api.complete(_tool_response([_patch_call("sync_approval")]))
	await process_frame
	_expect(tools.apply_calls == 1 and controller._pending_change_id.is_empty(), "a synchronous approval must be consumed without losing the decision signal")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller._is_running = true
	controller._active_turn_id = 22
	controller._awaiting_edit_resolution = true
	controller._pending_change_id = "reused_id"
	controller._proposals["reused_id"] = {"id": "reused_id", "_origin_turn_id": 22, "kind": "file_patch", "filepath": "res://fixture.txt"}
	controller.resolve_edit("reused_id", 21, true)
	_expect(tools.apply_calls == 0 and controller._pending_change_id == "reused_id", "a stale approval with a reused provider call ID must not resolve a newer proposal")
	await _free_controller(controller)


func _test_work_approval() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var apply_count_at_proposal := [-1]
	var review_proposals := []
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		apply_count_at_proposal[0] = tools.apply_calls
		review_proposals.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
	)
	var result: Dictionary = await controller._execute_tool_call(_patch_call("approve_call"))
	_expect(apply_count_at_proposal[0] == 0, "approval proposal must be emitted before applying")
	_expect(tools.prepare_calls == 1, "Work approval should prepare one patch")
	_expect(tools.apply_calls == 1, "approved patch should apply exactly once")
	_expect(review_proposals.size() == 1 and review_proposals[0].get("old_content") == "old\n" and review_proposals[0].get("new_content") == "new\n", "file patch review must retain previous and proposed content for expanded diff")
	_expect(not review_proposals[0].has("old_hash") and not review_proposals[0].has("edits"), "file patch review should still redact hashes and edit instructions")
	_expect(result.get("outcome") == "applied", "approved patch should report applied")
	_expect(controller._pending_change_id.is_empty(), "approval should clear the pending change")
	_expect(controller._proposals.has("approve_call"), "applied proposals should remain available for guarded revert")
	controller.revert_edit("approve_call")
	_expect(not controller._proposals.has("approve_call"), "successfully reverted proposals should release private retained content")
	await _free_controller(controller)


func _test_mutation_recovery_classification() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	tools.apply_result = "Cleanup required: Applied the reviewed changes. Recovery copy: /private/backup"
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true))
	var cleanup_result: Dictionary = await controller._execute_tool_call(_patch_call("cleanup_apply"))
	_expect(cleanup_result.get("outcome") == "applied_recovery" and cleanup_result.get("execution", {}).get("success", false), "committed cleanup warnings should remain successful applied_recovery outcomes")
	_expect(controller._proposals.get("cleanup_apply", {}).get("cleanup_required", false) and not controller._proposals.get("cleanup_apply", {}).get("recovery_required", false), "cleanup-warning proposals should remain guarded and revertible without recovery bypass state")
	var cleanup_resolutions := []
	controller.edit_resolved.connect(func(_id: String, status: String, _message: String): cleanup_resolutions.append(status))
	controller.revert_edit("cleanup_apply")
	_expect(cleanup_resolutions.has("reverted"), "a committed cleanup-warning proposal should retain guarded Revert")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	tools.apply_result = "Recovery required: Replacement failed and the original could not be restored. Recovery copy: /private/recovery"
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true))
	var recovery_result: Dictionary = await controller._execute_tool_call(_patch_call("uncertain_apply"))
	var retained: Dictionary = controller._proposals.get("uncertain_apply", {})
	_expect(recovery_result.get("outcome") == "apply_recovery_required" and not recovery_result.get("execution", {}).get("success", true), "uncertain apply recovery must not be a successful or completed tool outcome")
	_expect(retained.get("status") == "apply_recovery_required" and retained.get("recovery_required", false) and not retained.get("exact_applied_state", true), "uncertain apply recovery should retain exact private proposal state")
	_expect(retained.get("old_content") == "old\n" and retained.get("new_content") == "new\n", "uncertain apply recovery must preserve private recovery bytes")
	var revert_calls_before := tools.revert_calls
	controller.revert_edit("uncertain_apply")
	_expect(tools.revert_calls == revert_calls_before, "uncertain apply recovery must not offer or execute unsafe Revert")

	controller._proposals["uncertain_revert"] = {"id": "uncertain_revert", "kind": "file_patch", "filepath": "res://fixture.txt", "old_content": "old", "new_content": "new", "status": "applied", "exact_applied_state": true}
	tools.revert_result = "Recovery required: Revert replacement failed. Recovery copy: /private/revert"
	var revert_resolutions := []
	controller.edit_resolved.connect(func(_id: String, status: String, message: String): revert_resolutions.append([status, message]))
	controller.revert_edit("uncertain_revert")
	_expect(revert_resolutions[-1][0] == "revert_recovery_required" and str(revert_resolutions[-1][1]).contains("/private/revert"), "uncertain revert recovery should have a distinct status and preserve its exact message")
	_expect(controller._proposals.get("uncertain_revert", {}).get("status") == "revert_recovery_required" and controller._proposals.get("uncertain_revert", {}).get("old_content") == "old", "uncertain revert recovery should retain private proposal state")
	await _free_controller(controller)


func _test_work_rejection_protocol() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var api: FakeApiClient = fixture["api"]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, false)
	)
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([_patch_call("reject_call")]))
	_expect(tools.apply_calls == 0, "rejected patch must not be applied")
	_expect(controller._proposals.is_empty(), "rejected proposals should release private retained content")
	_expect(api.requests.size() == 1, "rejected patch should continue the model loop once")
	if api.requests.size() == 1:
		_expect(api.requests[0].get("request_options", {}).get("allow_stream_options_retry") == false, "tool-result continuations must disable stream-options compatibility retries")
		var history: Array = api.requests[0].get("messages", [])
		_expect(_tool_result_count(history, "reject_call") == 1, "rejection should append exactly one matching tool result")
		_expect(_protocol_is_valid(history), "rejection continuation history should remain protocol-valid")
	await _free_controller(controller)


func _test_cancellation_protocol() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var api: FakeApiClient = fixture["api"]
	var cancelled_count := [0]
	controller.request_cancelled.connect(func(_turn_id: int): cancelled_count[0] += 1)
	controller.edit_proposed.connect(func(_turn_id: int, _proposal: Dictionary):
		controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([_patch_call("cancel_patch")]))
	_expect(cancelled_count[0] == 1, "cancelling a pending approval should emit request_cancelled once")
	_expect(not controller.is_busy(), "cancelling a pending approval should finish the request")
	_expect(tools.apply_calls == 0, "cancelled approval must not apply")
	_expect(tools.execute_calls == 0, "cancelling approval must not execute another tool")
	_expect(controller._proposals.is_empty(), "cancelled proposals should release private retained content")
	_expect(api.requests.is_empty(), "cancelled tool rounds must not send a follow-up request")
	_expect(_tool_result_count(controller.message_history, "cancel_patch") == 1, "cancelled proposal should receive one tool result")
	_expect(_protocol_is_valid(controller.message_history), "cancellation history should remain protocol-valid")
	await _free_controller(controller)


func _test_task_state() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "task state should be usable in Plan mode")
	_expect(_tool_names(controller._get_tool_definitions()).has("update_tasks"), "Plan mode should expose update_tasks")
	var emitted := []
	controller.tasks_changed.connect(func(tasks: Array): emitted.append(tasks.duplicate(true)))
	var tasks := [{"content": "Inspect", "status": "completed"}, {"content": "Plan", "status": "in_progress"}]
	var success: Dictionary = await controller._execute_tool_call({"id": "tasks_1", "type": "function", "function": {"name": "update_tasks", "arguments": JSON.stringify({"tasks": tasks})}})
	_expect(success.get("outcome") == "completed", "valid task updates should complete without approval")
	_expect(emitted.size() == 1 and emitted[0] == tasks, "successful task updates should emit normalized state")
	_expect(controller.snapshot_session_state().get("tasks") == tasks, "task state should be included in session snapshots")
	controller._add_turn_context()
	_expect(str(controller.message_history[-1].get("content", "")).contains("CURRENT ORCA TASK CHECKLIST"), "current tasks should be included in request-scoped context")
	controller._clear_turn_context()
	var invalid: Dictionary = await controller._execute_tool_call({"id": "tasks_2", "type": "function", "function": {"name": "update_tasks", "arguments": JSON.stringify({"tasks": [{"content": "One", "status": "in_progress"}, {"content": "Two", "status": "in_progress"}]})}})
	_expect(invalid.get("outcome") == "failed", "invalid task updates should fail")
	_expect(emitted.size() == 1, "failed task updates must not emit replacement state")
	_expect(controller.snapshot_session_state().get("tasks") == tasks, "failed task updates must preserve existing state")
	var restored: bool = controller.restore_session_state(AgentController.AgentMode.BUILD, [], {}, [{"content": "Restored", "status": "pending"}])
	_expect(restored, "valid persisted tasks should restore")
	_expect(controller.snapshot_session_state().get("tasks", [])[0].get("content") == "Restored", "restored task state should be retained")
	await _free_controller(controller)


func _test_task_context_refresh() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var old_tasks := [{"content": "Old task", "status": "in_progress"}]
	var new_tasks := [{"content": "New task", "status": "completed"}, {"content": "Continue", "status": "in_progress"}]
	controller._tasks.assign(old_tasks)
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._add_turn_context()
	controller.message_history.append({"role": "user", "content": "Maintain the checklist"})
	var invalid_tasks := [{"content": "One", "status": "in_progress"}, {"content": "Two", "status": "in_progress"}]
	await _deliver_completion(controller, _tool_response([_simple_tool_call("tasks_invalid_context", "update_tasks", {"tasks": invalid_tasks})]))
	_expect(controller._tasks == old_tasks and _task_context_count(controller.message_history) == 1, "a failed task update should preserve exactly one prior checklist context")
	_expect(_task_context_content(controller.message_history).contains("Old task") and not _task_context_content(controller.message_history).contains("One"), "failed task arguments must not replace model-facing checklist context")
	await _deliver_completion(controller, _tool_response([_simple_tool_call("tasks_refresh", "update_tasks", {"tasks": new_tasks})]))
	_expect(controller._tasks == new_tasks and _task_context_count(controller.message_history) == 1, "a successful task update should replace the checklist context without duplication")
	_expect(_task_context_content(controller.message_history).contains("New task") and not _task_context_content(controller.message_history).contains("Old task"), "the refreshed checklist should contain only current task state")
	_expect(_tool_result_index(controller.message_history, "tasks_refresh") == _assistant_call_index(controller.message_history, "tasks_refresh") + 1, "checklist refresh must not split the matching tool protocol group")
	_expect(_protocol_is_valid(controller.message_history), "task context refresh must preserve complete tool protocol")
	await _deliver_completion(controller, _tool_response([_simple_tool_call("tasks_clear", "update_tasks", {"tasks": []})]))
	_expect(controller._tasks.is_empty() and controller._task_context_message_index == -1 and _task_context_count(controller.message_history) == 0, "a successful empty task update should remove checklist context")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Checklist reconciled."}}]})
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller._tasks.assign(old_tasks)
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._add_turn_context()
	controller.message_history.append({"role": "user", "content": "Finish at the action boundary"})
	controller._tool_rounds = AgentController.MAX_TOOL_ROUNDS - 1
	await _deliver_completion(controller, _tool_response([_simple_tool_call("tasks_before_finalization", "update_tasks", {"tasks": new_tasks})]))
	_expect(api.requests.size() == 1 and api.requests[0].get("tools", [1]).is_empty(), "the boundary task update should enter no-tools finalization")
	if api.requests.size() == 1:
		var finalization_history: Array = api.requests[0].get("messages", [])
		_expect(_task_context_count(finalization_history) == 1 and _task_context_content(finalization_history).contains("New task"), "safe finalization should receive exactly one current checklist")
		_expect(not _task_context_content(finalization_history).contains("Old task"), "safe finalization must not receive stale checklist state")
		_expect(_protocol_is_valid(finalization_history), "checklist reconciliation before finalization must preserve tool protocol")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Finalized with the current checklist."}}]})
	_expect(controller._task_context_message_index == -1 and _task_context_count(controller.message_history) == 0, "terminal finalization should remove request-scoped checklist context")
	_expect(controller.snapshot_session_state().get("tasks") == new_tasks, "terminal cleanup must retain the durable current checklist")
	await _free_controller(controller)


func _test_scene_inspection_permission() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "scene inspection should be available from Plan mode")
	_expect(_tool_names(controller._get_tool_definitions()).has("inspect_scene"), "Plan schema should expose inspect_scene")
	var proposals := [0]
	controller.edit_proposed.connect(func(_turn_id: int, _proposal: Dictionary): proposals[0] += 1)
	var result: Dictionary = await controller._execute_tool_call({"id": "inspect_1", "type": "function", "function": {"name": "inspect_scene", "arguments": "{\"scene_path\":\"res://main.tscn\"}"}})
	_expect(result.get("outcome") == "completed", "inspect_scene should use the generic read-only execution path")
	_expect(tools.execute_calls == 1, "inspect_scene should execute exactly once")
	_expect(proposals[0] == 0, "inspect_scene must never enter edit approval")
	await _free_controller(controller)


func _test_project_settings_inspection_permission() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "project settings inspection should be available from Plan mode")
	_expect(_tool_names(controller._get_tool_definitions()).has("inspect_project_settings"), "Plan schema should expose inspect_project_settings")
	var proposals := [0]
	controller.edit_proposed.connect(func(_turn_id: int, _proposal: Dictionary): proposals[0] += 1)
	var result: Dictionary = await controller._execute_tool_call({"id": "settings_1", "type": "function", "function": {"name": "inspect_project_settings", "arguments": "{}"}})
	_expect(result.get("outcome") == "completed", "inspect_project_settings should use the generic read-only execution path")
	_expect(tools.execute_calls == 1, "inspect_project_settings should execute exactly once")
	_expect(proposals[0] == 0, "inspect_project_settings must never enter edit approval")
	await _free_controller(controller)


func _test_input_map_approval_and_plan_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(_tool_names(controller._get_tool_definitions()).has("propose_input_map_changes"), "Work schema should expose Input Map proposals")
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true))
	var call := {"id": "input_approve", "type": "function", "function": {"name": "propose_input_map_changes", "arguments": JSON.stringify({"base_hash": "hash", "changes": [{"operation": "upsert", "action": "jump", "events": []}]})}}
	var result: Dictionary = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "applied", "approved Input Map proposals should use the reviewed mutation path")
	_expect(tools.prepare_calls == 1 and tools.apply_calls == 1, "Input Map approval should prepare and apply exactly once")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	_expect(not _tool_names(controller._get_tool_definitions()).has("propose_input_map_changes"), "Plan schema should omit Input Map proposals")
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "failed" and str(result.get("result", "")).contains("unavailable in Plan mode"), "Plan runtime enforcement should reject Input Map proposals")
	_expect(tools.prepare_calls == 0 and tools.apply_calls == 0, "Plan denial must happen before Input Map preparation")
	await _free_controller(controller)


func _test_plan_revert_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	controller._proposals["applied"] = {"id": "applied", "kind": "file_patch", "filepath": "res://fixture.txt", "status": "applied", "exact_applied_state": true}
	controller.set_mode(AgentController.AgentMode.PLAN)
	var resolutions := []
	controller.edit_resolved.connect(func(_id: String, status: String, message: String): resolutions.append([status, message]))
	controller.revert_edit("applied")
	_expect(tools.apply_calls == 0, "Plan mode must not execute a revert mutation")
	_expect(resolutions.size() == 1 and resolutions[0][0] == "revert_failed", "Plan revert denial should be visible to the review card")
	await _free_controller(controller)


func _test_main_scene_approval_and_privacy() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(_tool_names(controller._get_tool_definitions()).has("propose_main_scene_change"), "Work schema should expose main scene proposals")
	var visible_proposals := []
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		visible_proposals.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
	)
	var call := {"id": "main_approve", "type": "function", "function": {"name": "propose_main_scene_change", "arguments": JSON.stringify({"base_hash": "hash", "scene_path": "res://main.tscn"})}}
	var result: Dictionary = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "applied", "approved main scene proposals should use the reviewed mutation path")
	_expect(tools.prepare_calls == 1 and tools.apply_calls == 1, "main scene approval should prepare and apply exactly once")
	_expect(visible_proposals.size() == 1 and not visible_proposals[0].has("old_content") and not visible_proposals[0].has("new_value") and not visible_proposals[0].has("old_hash"), "review listeners must not receive private proposal bytes, raw values, or hashes")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	_expect(not _tool_names(controller._get_tool_definitions()).has("propose_main_scene_change"), "Plan schema should omit main scene proposals")
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "failed", "Plan runtime enforcement should reject main scene proposals")
	_expect(tools.prepare_calls == 0 and tools.apply_calls == 0, "Plan denial must happen before main scene preparation")
	await _free_controller(controller)


func _test_project_settings_approval_and_plan_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	for tool_name in ["apply_patch", "propose_input_map_changes", "propose_main_scene_change", "propose_project_settings_changes", "propose_scene_changes"]:
		_expect(AgentController.REVIEWED_MUTATION_TOOLS.has(tool_name), "every Work mutation schema must have runtime reviewed routing: " + tool_name)
	_expect(_tool_names(controller._get_tool_definitions()).has("propose_project_settings_changes"), "Work schema should expose allowlisted ProjectSettings proposals")
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true))
	var call := {"id": "settings_approve", "type": "function", "function": {"name": "propose_project_settings_changes", "arguments": JSON.stringify({"base_hash": "hash", "changes": [{"setting_path": "display/window/size/viewport_width", "value": 1920}]})}}
	var result: Dictionary = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "applied", "approved ProjectSettings proposals should use the reviewed mutation path")
	_expect(tools.prepare_calls == 1 and tools.apply_calls == 1, "ProjectSettings approval should prepare and apply exactly once")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	_expect(not _tool_names(controller._get_tool_definitions()).has("propose_project_settings_changes"), "Plan schema should omit ProjectSettings proposals")
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "failed", "Plan runtime enforcement should reject ProjectSettings proposals")
	_expect(tools.prepare_calls == 0 and tools.apply_calls == 0, "Plan denial must happen before ProjectSettings preparation")
	await _free_controller(controller)


func _test_scene_creation_approval_and_privacy() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(_tool_names(controller._get_tool_definitions()).has("propose_scene_changes"), "Work schema should expose structured scene proposals")
	var visible := []
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		visible.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
	)
	var call := {"id": "scene_create", "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify({"scene_path": "res://world.tscn", "base_hash": "", "operations": [{"operation": "create_scene", "root_type": "Node2D", "root_name": "World"}]})}}
	var result: Dictionary = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "applied", "approved scene creation should use the reviewed mutation path")
	_expect(tools.prepare_calls == 1 and tools.apply_calls == 1, "scene creation approval should prepare and apply exactly once")
	_expect(visible.size() == 1 and visible[0].get("scene_summary", {}).get("root_type") == "Node2D", "scene review should retain the bounded root summary")
	_expect(not visible[0].has("old_content") and not visible[0].has("new_content") and not visible[0].has("operations") and not visible[0].has("new_hash"), "scene review must redact candidate bytes, operations, and hashes")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	_expect(not _tool_names(controller._get_tool_definitions()).has("propose_scene_changes"), "Plan schema should omit structured scene proposals")
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "failed" and str(result.get("result", "")).contains("unavailable in Plan mode"), "Plan runtime enforcement should reject structured scene proposals")
	_expect(tools.prepare_calls == 0 and tools.apply_calls == 0, "Plan denial must happen before scene proposal preparation")
	await _free_controller(controller)


func _test_scene_script_two_stage_approval() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var visible := []
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		visible.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
	)
	var call := {"id": "script_attach", "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify({"scene_path": "res://actor.tscn", "base_hash": "scene-hash", "operations": [{"operation": "attach_script", "node_path": ".", "script_path": "res://actor.gd", "script_hash": "script-hash"}]})}}
	var result: Dictionary = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "applied", "script attachment should complete only after trust and candidate approvals")
	_expect(tools.prepare_calls == 1 and tools.promote_calls == 1 and tools.apply_calls == 1, "two-stage script approval should prepare, promote, and apply exactly once")
	_expect(visible.size() == 2 and visible[0].get("approval_stage") == "script_trust" and visible[1].get("approval_stage") == "candidate", "script operations should emit trust then immutable candidate reviews")
	for proposal in visible:
		_expect(not proposal.has("old_content") and not proposal.has("new_content") and not proposal.has("operations") and not proposal.has("script_content") and not proposal.has("trust_binding"), "both script review stages must redact bytes, operations, and trust binding")
	_expect(controller._pending_change_id.is_empty(), "second script approval should clear pending state")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, false))
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "rejected" and tools.promote_calls == 0 and tools.apply_calls == 0, "rejecting preliminary script trust must not construct or apply a candidate")
	await _free_controller(controller)


func _test_scene_script_second_stage_resolution() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var api: FakeApiClient = fixture["api"]
	var stage := [0]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		stage[0] += 1
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, stage[0] == 1)
	)
	var call := {"id": "script_reject_final", "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify({"scene_path": "res://actor.tscn", "base_hash": "scene-hash", "operations": [{"operation": "attach_script", "node_path": ".", "script_path": "res://actor.gd", "script_hash": "script-hash"}]})}}
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([call]))
	_expect(stage[0] == 2 and tools.promote_calls == 1 and tools.apply_calls == 0, "rejecting the final script candidate should occur after exactly one trusted construction and before apply")
	_expect(api.requests.size() == 1 and _tool_result_count(api.requests[0].get("messages", []), "script_reject_final") == 1, "both script decisions should still produce exactly one protocol tool result")
	_expect(_protocol_is_valid(api.requests[0].get("messages", [])), "second-stage script rejection history should remain protocol-valid")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	api = fixture["api"]
	stage = [0]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		stage[0] += 1
		if stage[0] == 1:
			controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
		else:
			controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([call]))
	_expect(stage[0] == 2 and tools.promote_calls == 1 and tools.apply_calls == 0, "cancelling at final script review must not apply the candidate")
	_expect(_tool_result_count(controller.message_history, "script_reject_final") == 1 and _protocol_is_valid(controller.message_history), "second-stage cancellation should retain exactly one valid tool result")
	await _free_controller(controller)


func _test_game_process_permissions() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var game: FakeGameProcessService = fixture["game"]
	for tool_name in ["run_current_scene", "run_main_scene", "stop_game"]:
		_expect(AgentController.WORK_OPERATION_TOOLS.has(tool_name), "external process operation must have runtime Work routing: " + tool_name)
		_expect(_tool_names(controller._get_tool_definitions()).has(tool_name), "Work schema should expose " + tool_name)
	var run_result: Dictionary = await controller._execute_tool_call({"id": "run_game", "type": "function", "function": {"name": "run_current_scene", "arguments": "{}"}})
	var stop_result: Dictionary = await controller._execute_tool_call({"id": "stop_game", "type": "function", "function": {"name": "stop_game", "arguments": "{}"}})
	_expect(run_result.get("outcome") == "completed" and stop_result.get("outcome") == "completed", "Work process operations should use the immediate operational path")
	_expect(game.starts == 1 and game.stops == 1 and tools.prepare_calls == 0 and tools.apply_calls == 0, "run and stop must not enter file proposal routing")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	game = fixture["game"]
	controller.set_mode(AgentController.AgentMode.PLAN)
	_expect(_tool_names(controller._get_tool_definitions()).has("observe_game_run") and _tool_names(controller._get_tool_definitions()).has("verify_game_run"), "Plan should expose read-only run observation and verification")
	game.run_id = 1
	game.snapshot = {"run_id": 1, "sequence": 1, "state": "exited", "scene_path": "res://main.tscn", "verification_status": "unverified", "diagnostics": [], "stdout": "", "stderr": ""}
	var observed: Dictionary = await controller._execute_tool_call({"id": "observe_plan", "type": "function", "function": {"name": "observe_game_run", "arguments": "{\"run_id\":1}"}})
	_expect(observed.get("outcome") == "completed", "Plan should execute read-only game observation")
	for tool_name in ["run_current_scene", "run_main_scene", "stop_game"]:
		_expect(not _tool_names(controller._get_tool_definitions()).has(tool_name), "Plan schema should omit " + tool_name)
		var denied: Dictionary = await controller._execute_tool_call({"id": "deny_" + tool_name, "type": "function", "function": {"name": tool_name, "arguments": "{}"}})
		_expect(denied.get("outcome") == "failed" and str(denied.get("result", "")).contains("unavailable in Plan mode"), "Plan runtime guard should reject " + tool_name)
	_expect(game.starts == 0 and game.stops == 0 and tools.execute_calls == 1, "Plan denial must happen before process control while allowing the observation read")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	for index in range(4):
		var result: Dictionary = await controller._execute_tool_call({"id": "run_limit_" + str(index), "type": "function", "function": {"name": "run_current_scene", "arguments": "{}"}})
		_expect(result.get("outcome") == ("completed" if index < AgentController.MAX_RUN_ATTEMPTS_PER_TURN else "failed"), "per-turn run attempt limit should reject only the fourth launch")
	_expect(game.starts == AgentController.MAX_RUN_ATTEMPTS_PER_TURN, "run limit must reject before process service execution")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	var first_criteria := {"kind": "expected_exit", "expected_exit_code": 0}
	var changed_criteria := {"kind": "expected_exit", "expected_exit_code": 1}
	var first_run: Dictionary = await controller._execute_tool_call({"id": "criteria_1", "type": "function", "function": {"name": "run_current_scene", "arguments": JSON.stringify({"verification": first_criteria})}})
	var changed_run: Dictionary = await controller._execute_tool_call({"id": "criteria_2", "type": "function", "function": {"name": "run_current_scene", "arguments": JSON.stringify({"verification": changed_criteria})}})
	_expect(first_run.get("outcome") == "completed" and changed_run.get("outcome") == "failed" and str(changed_run.get("result", "")).contains("moving the goalposts"), "reruns in one turn must preserve predeclared verification criteria")
	_expect(game.starts == 1, "changed rerun criteria must fail before another process launch")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	first_run = await controller._execute_tool_call({"id": "unverified_1", "type": "function", "function": {"name": "run_current_scene", "arguments": "{}"}})
	changed_run = await controller._execute_tool_call({"id": "unverified_2", "type": "function", "function": {"name": "run_current_scene", "arguments": JSON.stringify({"verification": first_criteria})}})
	_expect(first_run.get("outcome") == "completed" and changed_run.get("outcome") == "failed", "a turn must not introduce verification criteria only after seeing an exploratory run")
	_expect(game.starts == 1, "late verification criteria must fail before another process launch")
	await _free_controller(controller)


func _test_bounded_run_observation() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var game: FakeGameProcessService = fixture["game"]
	var api: FakeApiClient = fixture["api"]
	game.terminal_on_observe = true
	var states := []
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary): states.append(state))
	controller._is_running = true
	var run_call := {"id": "observed_run", "type": "function", "function": {"name": "run_current_scene", "arguments": JSON.stringify({"verification": {"kind": "expected_exit", "expected_exit_code": 0}})}}
	await _deliver_completion(controller, _tool_response([run_call]))
	_expect(api.requests.size() == 1, "a completed bounded observation should trigger exactly one delayed model continuation")
	if api.requests.size() == 1:
		var history: Array = api.requests[0].get("messages", [])
		_expect(_tool_result_count(history, "observed_run") == 1 and _protocol_is_valid(history), "run observation must begin only after one matching tool result exists")
		_expect(history.any(func(message): return message.get("role") == "system" and str(message.get("content", "")).contains("ORCA GAME RUN OBSERVATION")), "the delayed continuation should contain bounded request-scoped runtime evidence")
	_expect(states.has("observing") and states.has("assessment_ready"), "controller should expose observing and assessment-ready workflow states")
	_expect(not JSON.stringify(controller.snapshot_session_state()).contains("ORCA GAME RUN OBSERVATION"), "runtime observation context must not persist in resumable session continuation")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	api = fixture["api"]
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary):
		if state == "observing":
			controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([run_call]))
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancelling during observation should suppress the delayed provider request")
	_expect(_tool_result_count(controller.message_history, "observed_run") == 1 and _protocol_is_valid(controller.message_history), "observation cancellation should preserve the completed run tool result")
	_expect(game.stops == 0, "cancelling model observation must not stop the independently owned game process")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	api = fixture["api"]
	game.terminal_on_observe = true
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary):
		if state == "assessment_ready":
			controller.cancel_current_request()
	)
	controller._is_running = true
	await _deliver_completion(controller, _tool_response([run_call]))
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancelling at assessment-ready must not send the delayed provider request")
	_expect(_tool_result_count(controller.message_history, "observed_run") == 1 and _protocol_is_valid(controller.message_history), "assessment-ready cancellation should preserve protocol-valid run history")
	await _free_controller(controller)


func _test_long_task_run_fix_verify() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	var game: FakeGameProcessService = fixture["game"]
	tools.enforce_patch_hashes = true
	var initial_tasks := [
		{"content": "Inspect the startup failure", "status": "in_progress"},
		{"content": "Apply reviewed fixes", "status": "pending"},
		{"content": "Verify clean startup", "status": "pending"},
	]
	var completed_tasks := [
		{"content": "Inspect the startup failure", "status": "completed"},
		{"content": "Apply reviewed fixes", "status": "completed"},
		{"content": "Verify clean startup", "status": "completed"},
	]
	var criteria := {"kind": "clean_startup", "claim": "Starts without runtime errors", "minimum_runtime_ms": 250, "require_no_runtime_errors": true}
	game.scripted_run_results = [
		{
			"snapshot": {"sequence": 2, "state": "running", "elapsed_ms": 300, "exit_code": null, "verification_status": "failed", "verification_configured": true, "stdout": "BOOT\n", "stderr": "SCRIPT ERROR: startup fixture failure\n", "diagnostics": [{"origin": "game", "severity": "error", "file": "res://fixture.gd", "line": 3, "message": "startup fixture failure"}], "output_truncated": false, "diagnostics_truncated": false, "dropped_bytes": 0},
			"verification": {"status": "failed", "scope": "startup_only", "claim": "Starts without runtime errors", "checks": [{"name": "minimum_runtime_ms", "status": "passed", "expected": 250, "observed": 300}, {"name": "runtime_errors", "status": "failed", "expected": 0, "observed": 1}]},
		},
		{
			"snapshot": {"sequence": 2, "state": "exited", "elapsed_ms": 300, "exit_code": 0, "verification_status": "passed", "verification_configured": true, "stdout": "READY\n", "stderr": "", "diagnostics": [], "output_truncated": false, "diagnostics_truncated": false, "dropped_bytes": 0},
			"verification": {"status": "passed", "scope": "startup_only", "claim": "Starts without runtime errors", "checks": [{"name": "minimum_runtime_ms", "status": "passed", "expected": 250, "observed": 300}, {"name": "runtime_errors", "status": "passed", "expected": 0, "observed": 0}]},
		},
	]
	var proposed_apply_counts: Array[int] = []
	var completed_executions: Dictionary = {}
	var task_emissions: Array = []
	var workflow_states: Array[String] = []
	var visible_messages: Array[String] = []
	var errors: Array[String] = []
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary):
		proposed_apply_counts.append(tools.apply_calls)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true)
	)
	controller.tool_execution_completed.connect(func(_turn_id: int, call_id: String, _tool_name: String, execution: Dictionary, _duration_ms: int): completed_executions[call_id] = execution.duplicate(true))
	controller.tasks_changed.connect(func(tasks: Array): task_emissions.append(tasks.duplicate(true)))
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, _details: Dictionary): workflow_states.append(state))
	controller.message_received.connect(func(_turn_id: int, _role: String, content: String): visible_messages.append(content))
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	_expect(controller.restore_session_state(AgentController.AgentMode.BUILD, [], {}, initial_tasks), "the long-task fixture should restore its initial checklist")
	controller.send_user_message("Fix and verify the startup failure")
	await _deliver_completion(controller, _tool_response([_simple_tool_call("inspect_source", "read_file", {"filepath": "res://fixture.gd"})]))
	await _deliver_completion(controller, _tool_response([_patch_call("fix_before_run")]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("run_first", "run_current_scene", {"verification": criteria})]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("verify_first", "verify_game_run", {"run_id": 1})]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("stop_first", "stop_game")]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("reread_after_failure", "read_file", {"filepath": "res://fixture.gd"})]))
	await _deliver_completion(controller, _tool_response([_patch_call_with_hash("fix_after_failure", "new-hash-1")]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("run_second", "run_current_scene", {"verification": criteria})]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("verify_second", "verify_game_run", {"run_id": 2})]))
	await _deliver_completion(controller, _tool_response([_simple_tool_call("tasks_complete", "update_tasks", {"tasks": completed_tasks})]))
	var final_text := "Applied both approved fixes. Run 1 failed the predeclared clean-startup criterion, and I stopped it. Run 2 passed the same startup-only criterion after the second fix. This does not verify visual or general gameplay behavior."
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": final_text}}]})

	_expect(api.requests.size() == 11 and controller._tool_rounds == 10, "the long task should complete ten tool rounds and one terminal provider request")
	var expected_ids := ["inspect_source", "fix_before_run", "run_first", "verify_first", "stop_first", "reread_after_failure", "fix_after_failure", "run_second", "verify_second", "tasks_complete"]
	for call_id in expected_ids:
		_expect(_tool_result_count(controller.message_history, call_id) == 1 and _tool_result_index(controller.message_history, call_id) == _assistant_call_index(controller.message_history, call_id) + 1, "the long task should retain one adjacent result for " + call_id)
	_expect(_protocol_is_valid(controller.message_history), "the complete long-task history should remain protocol-valid")
	_expect(tools.prepare_calls == 2 and tools.apply_calls == 2 and tools.prepared_change_ids == ["fix_before_run", "fix_after_failure"] and tools.applied_change_ids == ["fix_before_run", "fix_after_failure"], "both fixes should be prepared, reviewed, and applied exactly once")
	_expect(_tool_result_content(controller.message_history, "reread_after_failure").contains("new-hash-1") and str(_tool_call_arguments(controller.message_history, "fix_after_failure").get("base_hash", "")) == "new-hash-1", "the second patch must use the exact hash returned by the post-failure reread")
	_expect(proposed_apply_counts == [0, 1] and tools.revert_calls == 0, "each long-task proposal should appear before its own application without revert")
	_expect(game.operation_log == ["start:1", "observe:1", "verify:1", "stop:1", "start:2", "observe:2", "verify:2"], "run observation, verification, stop, fix, and rerun operations should occur in exact order")
	_expect(game.starts == 2 and game.stops == 1 and not game.active and game.verify_calls == [1, 2], "the failed first run should be stopped and the passing second run should exit naturally")
	_expect(game.start_verifications.size() == 2 and game.start_verifications.all(func(value): return value.get("kind") == "clean_startup" and float(value.get("minimum_runtime_ms", 0)) == 250.0) and game.started_criteria_ids.size() == 2 and game.started_criteria_ids[0] == game.started_criteria_ids[1], "both runs must use identical predeclared verification criteria")
	_expect(completed_executions.get("verify_first", {}).get("data", {}).get("status") == "failed" and completed_executions.get("verify_second", {}).get("data", {}).get("status") == "passed", "the model-visible verification sequence should fail first and pass after the second fix")
	_expect(workflow_states.count("observing") == 2 and workflow_states.count("assessment_ready") == 2 and not workflow_states.has("finalizing"), "both launches should receive one automatic observation without forced finalization")
	_expect(task_emissions == [completed_tasks] and controller.snapshot_session_state().get("tasks") == completed_tasks, "the long task should reconcile and persist one completed checklist")
	_expect(api.requests[8].get("messages", []).any(func(message): return str(message.get("content", "")).contains("ORCA ACTION BUDGET")), "the eighth tool round should add one early action-budget warning")
	_expect(_task_context_count(api.requests[10].get("messages", [])) == 1 and _task_context_content(api.requests[10].get("messages", [])).contains("completed"), "the final provider request should receive exactly one completed checklist")
	_expect(not controller.is_busy() and errors.is_empty() and visible_messages == [final_text], "the deterministic long task should end once with its scoped final response")
	_expect(controller._context_message_index == -1 and controller._task_context_message_index == -1 and controller._runtime_context_message_index == -1 and controller._round_budget_message_index == -1, "terminal completion should clear every long-task request-scoped context index")
	_expect(not JSON.stringify(controller.snapshot_session_state()).contains("ORCA GAME RUN OBSERVATION") and not JSON.stringify(controller.snapshot_session_state()).contains("ORCA ACTION BUDGET"), "runtime evidence and budget notices must not persist in resumable continuation")
	await _free_controller(controller)


func _test_tool_call_count_bound() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var errors := []
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	var calls := []
	for index in range(AgentController.MAX_TOOL_CALLS_PER_RESPONSE + 1):
		calls.append({"id": "many_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}})
	controller._is_running = true
	await _deliver_completion(controller, _tool_response(calls))
	_expect(tools.execute_calls == 0 and not controller.is_busy(), "oversized tool-call batches must fail before any tool side effect")
	_expect(errors.size() == 1 and str(errors[0]).contains("more than"), "oversized tool-call batches should report a bounded-response error")
	await _free_controller(controller)


func _test_tool_batch_barriers() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._reset_tool_batch_regeneration_state()
	controller.message_history.append({"role": "user", "content": "Inspect two independent resources"})
	var read_calls := [
		_simple_tool_call("read_batch_file", "read_file"),
		_simple_tool_call("read_batch_scene", "inspect_scene"),
	]
	await _deliver_completion(controller, _tool_response(read_calls))
	_expect(tools.execute_calls == 2, "independent read-only tools should remain batchable")
	_expect(api.requests.size() == 1, "an allowed read-only batch should continue with one provider request")
	_expect(_tool_result_count(controller.message_history, "read_batch_file") == 1 and _tool_result_count(controller.message_history, "read_batch_scene") == 1 and _protocol_is_valid(controller.message_history), "an allowed read-only batch should retain one protocol-valid result per call")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Inspection complete."}}]})
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	tools = fixture["tools"]
	var started_calls := [0]
	var batch_errors := []
	controller.tool_execution_started.connect(func(_turn_id: int, _call_id: String, _tool_name: String, _arguments: Dictionary): started_calls[0] += 1)
	controller.error_occurred.connect(func(_turn_id: int, message: String): batch_errors.append(message))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._reset_tool_batch_regeneration_state()
	controller.message_history.append({"role": "user", "content": "Change and inspect"})
	await _deliver_completion(controller, _tool_response([_patch_call("unsafe_batched_patch"), _simple_tool_call("unsafe_batched_read", "read_file")]))
	_expect(tools.prepare_calls == 0 and tools.execute_calls == 0 and started_calls[0] == 0, "a valid but unsafe mixed batch must be rejected before activity, reads, or mutation preparation")
	_expect(api.requests.size() == 1 and controller.is_busy(), "the first unsafe batch should receive one side-effect-free correction request")
	if api.requests.size() == 1:
		var retry_history: String = JSON.stringify(api.requests[0].get("messages", []))
		_expect(retry_history.contains(AgentController.TOOL_BATCH_CORRECTION_NOTICE), "unsafe batch correction should explain the singleton barrier")
		_expect(not retry_history.contains("unsafe_batched_patch") and not retry_history.contains("unsafe_batched_read"), "an unsafe batch must be absent from regenerated history")
	await _deliver_completion(controller, _tool_response([_simple_tool_call("unsafe_batched_tasks", "update_tasks"), _simple_tool_call("unsafe_second_read", "read_file")]))
	_expect(api.requests.size() == 1 and not controller.is_busy(), "a second unsafe batch must stop without another correction request")
	_expect(batch_errors.size() == 1 and str(batch_errors[0]).contains("No tool from either rejected batch was executed"), "repeated unsafe batches should end with an explicit atomic non-execution error")
	_expect(tools.prepare_calls == 0 and tools.execute_calls == 0 and started_calls[0] == 0, "repeated unsafe batches must remain side-effect-free")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	var batchable_tools := [
		"list_directory",
		"read_file",
		"search_files",
		"inspect_scene",
		"inspect_project_settings",
		"read_project_skill",
		"inspect_godot_api",
		"read_gdscript_function",
		"discover_dependencies",
		"get_editor_context",
		"get_diagnostics",
	]
	for tool_name in batchable_tools:
		var validation: Dictionary = controller._validate_tool_batch([_simple_tool_call("read_anchor_" + tool_name, "read_file"), _simple_tool_call("read_allowed_" + tool_name, tool_name)])
		_expect(validation.get("success", false), "%s should remain available in a multi-call read-only batch" % tool_name)
	var singleton_tools := [
		"request_work_mode",
		"update_tasks",
		"apply_patch",
		"propose_input_map_changes",
		"propose_main_scene_change",
		"propose_project_settings_changes",
		"propose_scene_changes",
		"run_current_scene",
		"run_main_scene",
		"stop_game",
		"observe_game_run",
		"verify_game_run",
		"future_unknown_tool",
	]
	for tool_name in singleton_tools:
		var singleton_call := _simple_tool_call("single_" + tool_name, tool_name)
		_expect(controller._validate_tool_batch([singleton_call]).get("success", false), "%s should be accepted when it is the only tool call" % tool_name)
		var validation: Dictionary = controller._validate_tool_batch([_simple_tool_call("read_before_" + tool_name, "read_file"), singleton_call])
		_expect(not validation.get("success", true) and validation.get("reason") == "singleton_required" and validation.get("tool_name") == tool_name, "%s should require a singleton batch" % tool_name)
	await _free_controller(controller)


func _test_malformed_tool_batch_regeneration() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	var started_calls := [0]
	controller.tool_execution_started.connect(func(_turn_id: int, _call_id: String, _tool_name: String, _arguments: Dictionary): started_calls[0] += 1)
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._reset_tool_batch_regeneration_state()
	controller.message_history.append({"role": "user", "content": "Inspect safely"})
	var malformed_call := {"id": "malformed_once", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":"}}
	await _deliver_completion(controller, _tool_response([malformed_call]))
	_expect(tools.execute_calls == 0 and started_calls[0] == 0, "a malformed tool batch must be rejected before tool activity or side effects")
	_expect(api.requests.size() == 1 and controller.is_busy(), "the first malformed batch should issue exactly one side-effect-free regeneration request")
	if api.requests.size() == 1:
		var retry_history: Array = api.requests[0].get("messages", [])
		var serialized_retry := JSON.stringify(retry_history)
		_expect(serialized_retry.contains(AgentController.TOOL_BATCH_CORRECTION_NOTICE), "the regeneration request should explain the rejected batch")
		_expect(not serialized_retry.contains("malformed_once") and not serialized_retry.contains("tool_calls") and not serialized_retry.contains("\"role\":\"tool\""), "the regeneration request must not replay malformed tool protocol")
		_expect(api.requests[0].get("request_options", {}).get("allow_stream_options_retry") == true, "a pre-execution regeneration may retain initial-request transport compatibility fallback")

	var valid_call := {"id": "valid_after_regeneration", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	await _deliver_completion(controller, _tool_response([valid_call]))
	_expect(tools.execute_calls == 1 and started_calls[0] == 1, "a valid regenerated batch should execute once")
	_expect(api.requests.size() == 2, "a valid regenerated batch should continue with one tool-result request")
	if api.requests.size() == 2:
		var continuation: Array = api.requests[1].get("messages", [])
		_expect(_tool_result_count(continuation, "valid_after_regeneration") == 1 and _protocol_is_valid(continuation), "the regenerated batch should produce one protocol-valid tool result")
		_expect(not JSON.stringify(continuation).contains("malformed_once"), "malformed provider output must remain absent from later continuation history")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Inspection complete."}}]})
	_expect(not controller.is_busy() and not JSON.stringify(controller.message_history).contains(AgentController.TOOL_BATCH_CORRECTION_NOTICE), "the temporary correction notice should be removed when the turn completes")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	tools = fixture["tools"]
	var errors := []
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._reset_tool_batch_regeneration_state()
	controller.message_history.append({"role": "user", "content": "Inspect safely"})
	await _deliver_completion(controller, _tool_response([malformed_call]))
	var non_object_call := {"id": "malformed_twice", "type": "function", "function": {"name": "read_file", "arguments": "[]"}}
	await _deliver_completion(controller, _tool_response([non_object_call]))
	_expect(tools.execute_calls == 0 and api.requests.size() == 1, "a second invalid batch must stop without execution or another regeneration")
	_expect(not controller.is_busy() and errors.size() == 1 and str(errors[0]).contains("No tool from either rejected batch was executed"), "repeated malformed batches should end with an explicit non-execution error")
	_expect(not JSON.stringify(controller.message_history).contains("malformed_once") and not JSON.stringify(controller.message_history).contains("malformed_twice"), "repeated malformed output must not enter retained conversation history")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	tools = fixture["tools"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._reset_tool_batch_regeneration_state()
	controller.message_history.append({"role": "user", "content": "Prepare and inspect"})
	await _deliver_completion(controller, _tool_response([_patch_call("valid_mutation_in_rejected_batch"), malformed_call]))
	_expect(tools.prepare_calls == 0 and tools.execute_calls == 0, "one malformed call must atomically reject a mixed batch before valid mutation or read calls execute")
	_expect(api.requests.size() == 1 and not JSON.stringify(api.requests[0].get("messages", [])).contains("valid_mutation_in_rejected_batch"), "mixed rejected batches must be regenerated from pre-tool history")
	controller.cancel_current_request()
	await _free_controller(controller)


func _test_project_guidance_context() -> void:
	var controller := GuidanceController.new()
	get_root().add_child(controller)
	await process_frame
	controller.set_api_client_for_testing(FakeApiClient.new())
	controller.tools_script = FakeTools.new()
	controller._tasks.assign([{"content": "Fixture task", "status": "pending"}])
	controller._add_turn_context()
	var context := str(controller.message_history[controller._context_message_index].get("content", ""))
	_expect(context.contains("WRAPPED EXACT GUIDANCE"), "turn context should include the service's exact wrapped AGENTS content")
	_expect(context.contains("Fixture Skill") and context.contains("Catalog description"), "turn context should include bounded skill catalog metadata")
	_expect(not context.contains("SECRET SKILL BODY") and not context.contains("SECRET WRAPPER") and not context.contains("wrapped_body"), "turn context must redact skill bodies and non-catalog fields")
	_expect(not context.contains(AgentController.TASK_CONTEXT_HEADING), "the immutable guidance context should not retain checklist state")
	_expect(controller._task_context_message_index == controller.message_history.size() - 1 and _task_context_count(controller.message_history) == 1, "tasks should use one separately tracked refreshable context message")
	controller._clear_turn_context()
	_expect(not JSON.stringify(controller.message_history).contains("WRAPPED EXACT GUIDANCE"), "request-scoped guidance should be removed when a turn ends")
	controller.instruction_result = {"success": false, "error": "root failed\n" + "x".repeat(1000)}
	controller.skill_result = {"success": false, "error": "catalog failed"}
	controller._add_turn_context()
	context = str(controller.message_history[controller._context_message_index].get("content", ""))
	_expect(context.contains("PROJECT GUIDANCE WARNING: root failed") and context.contains("PROJECT SKILL CATALOG WARNING: catalog failed"), "guidance service errors should become request context warnings instead of aborting")
	_expect(not context.contains("\nxxxxxxxx"), "guidance warnings should be normalized and bounded")
	controller._is_running = true
	controller._finish_cancelled()
	_expect(controller._context_message_index == -1 and controller._task_context_message_index == -1 and not JSON.stringify(controller.message_history).contains("root failed"), "cancellation should remove guidance and task context and reset their indexes")
	controller._add_turn_context()
	controller._is_running = true
	_deliver_failure(controller, {"message": "fixture failure"})
	_expect(controller._context_message_index == -1 and controller._tool_loop_guard == null, "request failure should remove guidance and reset loop state")
	await _free_controller(controller)


func _test_runtime_progress_normalization() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	controller._reset_turn_loop_state()
	var first := _runtime_observation_result(4200, 4, 2)
	var elapsed_only := _runtime_observation_result(9100, 4, 3)
	var advanced := _runtime_observation_result(9300, 5, 4)
	_expect(ToolLoopGuard.fingerprint(controller._tool_loop_view(first)) == ToolLoopGuard.fingerprint(controller._tool_loop_view(elapsed_only)), "elapsed time and observation cursors must not change runtime loop identity")
	_expect(ToolLoopGuard.fingerprint(controller._tool_loop_view(first)) != ToolLoopGuard.fingerprint(controller._tool_loop_view(advanced)), "a new runtime evidence sequence should change runtime loop identity")
	controller._record_tool_progress([first])
	var epoch: int = controller._tool_progress_epoch
	controller._record_tool_progress([elapsed_only])
	_expect(controller._tool_progress_epoch == epoch, "elapsed-only observations must not advance semantic progress")
	controller._record_tool_progress([advanced])
	_expect(controller._tool_progress_epoch == epoch + 1, "a new runtime sequence should advance semantic progress")
	var guard := ToolLoopGuard.new()
	guard.record_round([controller._tool_loop_view(first)], epoch)
	guard.record_round([controller._tool_loop_view(elapsed_only)], epoch)
	var trigger := guard.record_round([controller._tool_loop_view(_runtime_observation_result(15000, 4, 9))], epoch)
	_expect(trigger.get("triggered", false) and trigger.get("reason") == ToolLoopGuard.REASON_IDENTICAL_CALL_RESULT, "elapsed-only runtime polling should trigger identical-call finalization")
	await _free_controller(controller)


func _test_loop_guard_duplicate_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(3):
		await _deliver_completion(controller, _tool_response([{"id": "duplicate_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://same.gd\"}"}}]))
	_expect(api.requests.size() == 3, "three duplicate rounds should issue two normal continuations and exactly one forced final request")
	_expect(api.requests[-1].get("tools", [1]).is_empty(), "the loop guard's final request must expose tools=[]")
	_expect(controller._loop_final_request and controller._loop_notice_message_index >= 0, "duplicate detection should append one tracked request-scoped loop notice")
	_expect(controller._loop_final_trigger_reason == "identical_call_result", "duplicate detection should preserve its exact trigger reason")
	var visible_messages := []
	controller.message_received.connect(func(_turn_id: int, _role: String, content: String): visible_messages.append(content))
	var denied_response := _tool_response([
		{"id": "denied_a", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
		{"id": "denied_b", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	])
	denied_response["choices"][0]["message"]["content"] = "I completed the inspection before trying one more read."
	denied_response["choices"][0]["message"]["reasoning_content"] = "hidden reasoning must not render"
	await _deliver_completion(controller, denied_response)
	_expect(tools.execute_calls == 3, "tool calls emitted after the no-tools request must not execute")
	_expect(_tool_result_count(controller.message_history, "denied_a") == 1 and _tool_result_count(controller.message_history, "denied_b") == 1, "every denied final-request call should receive exactly one matching result")
	_expect(_protocol_is_valid(controller.message_history), "denied final-request calls should leave protocol-valid history")
	_expect(not controller.is_busy() and controller._loop_notice_message_index == -1, "denial should terminate safely and clear request-scoped loop state")
	_expect(visible_messages.size() == 1 and str(visible_messages[0]).contains("provider attempted another tool after Orca disabled tools"), "denied final tools should produce an accurate visible outcome")
	_expect(str(visible_messages[0]).contains("repetitive tool calls") and str(visible_messages[0]).contains("I completed the inspection"), "the denied-tool outcome should include the bounded trigger and useful provider text")
	_expect(not str(visible_messages[0]).contains("hidden reasoning"), "the denied-tool outcome must not expose provider reasoning fields")
	_expect(str(visible_messages[0]).contains("`continue` is not special") and str(visible_messages[0]).contains("re-inspect the current state"), "denied-tool continuation guidance should require an explicit new request")
	controller.send_user_message("Inspect a different file")
	_expect(controller._loop_final_trigger_reason.is_empty() and not controller._loop_final_request, "the next user turn should reset finalization trigger state")
	await _free_controller(controller)


func _test_loop_guard_cycle_final_response() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for round_index in range(3):
		await _deliver_completion(controller, _tool_response([
			{"id": "cycle_a_%d" % round_index, "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://a.gd\"}"}},
			{"id": "cycle_b_%d" % round_index, "type": "function", "function": {"name": "inspect_scene", "arguments": "{\"scene_path\":\"res://b.tscn\"}"}}
		]))
	_expect(api.requests.size() == 3 and api.requests[-1].get("tools", [1]).is_empty(), "an alternating cycle should also issue exactly one no-tools final request")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Stopped safely."}}]})
	_expect(not controller.is_busy() and not JSON.stringify(controller.message_history).contains(AgentController.LOOP_FINAL_NOTICE), "a valid forced-final answer should finish and remove the loop notice")
	_expect(str(controller.message_history[-1].get("content", "")).contains("`continue` is not special") and str(controller.message_history[-1].get("content", "")).contains("re-inspect the current state"), "a valid forced-final answer should receive explicit non-replay continuation guidance")
	await _free_controller(controller)


func _test_loop_guard_empty_final_response() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var states: Array[Dictionary] = []
	var visible_messages := []
	controller.workflow_state_changed.connect(func(_turn_id: int, state: String, details: Dictionary): states.append({"state": state, "details": details.duplicate(true)}))
	controller.message_received.connect(func(_turn_id: int, _role: String, content: String): visible_messages.append(content))
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(3):
		await _deliver_completion(controller, _tool_response([{"id": "empty_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	_expect(api.requests.size() == 3 and api.requests[-1].get("tools", [1]).is_empty(), "empty-finalization fixture should reach one no-tools request")
	_expect(states[-1].get("state") == "finalizing" and states[-1].get("details", {}).get("trigger_reason") == "identical_call_result", "forced finalization should expose its distinct state and trigger")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "  \n "}}]})
	_expect(visible_messages.size() == 1 and str(visible_messages[0]).contains("provider returned no summary"), "an empty no-tools response should produce a visible local fallback")
	_expect(str(visible_messages[0]).contains("Completed actions were kept") and str(visible_messages[0]).contains("A new request is needed"), "empty finalization should explain the retained work and required next request")
	_expect(controller.message_history[-1].get("content") == visible_messages[0], "the exact visible fallback should be retained in assistant history")
	_expect(not controller.is_busy(), "empty finalization fallback should end the request")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	visible_messages = []
	controller.message_received.connect(func(_turn_id: int, _role: String, content: String): visible_messages.append(content))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._begin_loop_finalization(ToolLoopGuard.REASON_NO_PROGRESS)
	_deliver_failure(controller, {"message": "The provider completed without visible assistant content or a valid tool call.", "category": "malformed_response"})
	_expect(visible_messages.size() == 1 and str(visible_messages[0]).contains("provider returned no summary"), "transport-level empty finalization rejection should use the visible local fallback")
	_expect(not controller.is_busy(), "transport-level empty finalization rejection should end the request")
	await _free_controller(controller)


func _test_loop_guard_cancellation_and_progress() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(3):
		await _deliver_completion(controller, _tool_response([{"id": "cancel_loop_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	api.requesting = true
	controller.cancel_current_request()
	_expect(api.cancelled and not controller.is_busy() and controller._tool_loop_guard == null and not controller._loop_final_request, "cancelling the forced-final request should reset every loop-guard field")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	tools.changing_results = true
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(4):
		await _deliver_completion(controller, _tool_response([{"id": "changing_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	_expect(api.requests.size() == 4 and not api.requests[-1].get("tools", []).is_empty(), "changed results for the same stable call should count as progress and avoid false loop finalization")
	_expect(not controller._loop_final_request, "stable result changes should keep the normal tool loop active")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(4):
		await _deliver_completion(controller, _tool_response([{"id": "distinct_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": JSON.stringify({"filepath": "res://file_%d.gd" % index})}}]))
	_expect(api.requests.size() == 4 and not api.requests[-1].get("tools", []).is_empty(), "distinct tool evidence should count as progress and avoid no-progress finalization")
	_expect(not controller._loop_final_request, "new stable tool invocations should keep the normal tool loop active")
	await _free_controller(controller)


func _test_tool_round_cap_finalization() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var game: FakeGameProcessService = fixture["game"]
	var errors := []
	var visible_messages := []
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	controller.message_received.connect(func(_turn_id: int, _role: String, content: String): visible_messages.append(content))
	controller._is_running = true
	controller._reset_turn_loop_state()
	game.active = true
	game.run_id = 7
	game.snapshot["run_id"] = 7
	controller._run_attempts = 1
	controller._turn_run_ids[7] = true
	game.snapshot["state"] = "running"
	for index in range(AgentController.MAX_TOOL_ROUNDS):
		await _deliver_completion(controller, _tool_response([{
			"id": "bounded_%d" % index,
			"type": "function",
			"function": {"name": "read_file", "arguments": JSON.stringify({"filepath": "res://bounded_%d.gd" % index})}
		}]))
	_expect(api.requests.size() == AgentController.MAX_TOOL_ROUNDS, "the hard tool-round boundary should request one final response instead of failing")
	_expect(JSON.stringify(api.requests[AgentController.ROUND_BUDGET_WARNING_THRESHOLD - 1].get("messages", [])).contains("ORCA ACTION BUDGET"), "long turns should receive an early remaining-round warning")
	_expect(api.requests[-1].get("tools", [1]).is_empty(), "the hard tool-round boundary must remove the tool schema")
	_expect(game.stops == 1 and not game.active, "the hard cap should spend one controller-owned cleanup slot on the exact active Orca process")
	_expect(JSON.stringify(api.requests[-1].get("messages", [])).contains("ORCA CONTROLLER CLEANUP BEFORE FINALIZATION"), "safe finalization should tell the provider about controller-owned process cleanup")
	_expect(controller._loop_final_trigger_reason == AgentController.LOOP_TRIGGER_ROUND_CAP, "the hard cap should remain distinct from repetitive/no-progress triggers")
	_expect(errors.is_empty() and controller.is_busy(), "reaching the tool-round boundary should remain active while awaiting the final response")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Bounded summary."}}]})
	_expect(not controller.is_busy() and errors.is_empty(), "a final answer at the tool-round boundary should complete without a system error")
	_expect(visible_messages.size() == 1 and str(visible_messages[0]).contains("Cleanup: Stopped the same-turn Orca-owned game process"), "the final user-visible result should retain a privacy-safe cleanup outcome")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	game.active = true
	game.run_id = 8
	game.snapshot["run_id"] = 8
	controller._run_attempts = 1
	controller._turn_run_ids[7] = true
	controller._begin_loop_finalization(AgentController.LOOP_TRIGGER_ROUND_CAP)
	_expect(game.stops == 0 and game.active, "finalization must not stop a newer Orca process whose exact run ID was not launched in the active turn")
	controller.cancel_current_request()
	await _free_controller(controller)


func _test_recoverable_provider_failure() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	var errors := []
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller.message_history.append({"role": "user", "content": "Inspect safely"})
	await _deliver_completion(controller, _tool_response([{
		"id": "recover_read",
		"type": "function",
		"function": {"name": "read_file", "arguments": "{\"filepath\":\"res://secret.gd\"}"}
	}]))
	_expect(api.requests.size() == 1 and tools.execute_calls == 1, "a completed recovery fixture tool should issue one follow-up")
	controller._current_stream_content = "private partial provider output"
	_deliver_failure(controller, {"message": "fixture disconnect", "partial_response": true})
	_expect(controller.last_failure_was_checkpointed(), "a complete tool round should become a recoverable checkpoint after provider failure")
	_expect(not controller.is_busy() and errors.size() == 1 and str(errors[0]).contains("`continue` is not special") and str(errors[0]).contains("re-inspect the current state"), "recoverable provider failure should finish idle with explicit continuation guidance")
	var serialized := JSON.stringify(controller.message_history)
	_expect(serialized.contains(AgentController.RECOVERY_CHECKPOINT_HEADING), "recovery history should contain the local checkpoint")
	_expect(not serialized.contains("recover_read") and not serialized.contains("executed read_file") and not serialized.contains("private partial provider output"), "recovery history must omit call IDs, raw results, and partial provider output")
	_expect(not serialized.contains("tool_calls") and not serialized.contains("\"role\":\"tool\""), "recovery history must collapse replayable tool protocol")
	var snapshot: Dictionary = controller.snapshot_session_state()
	_expect(snapshot.get("continuation", []).size() == 2 and str(snapshot.get("continuation", [])[1].get("content", "")).contains(AgentController.RECOVERY_CHECKPOINT_HEADING), "the sanitized checkpoint should survive ordinary continuation snapshots")
	await _free_controller(controller)


func _test_incomplete_protocol_refuses_recovery() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller._tool_rounds = 1
	controller._turn_tool_receipts.append({"name": "apply_patch", "outcome": "applied"})
	controller.message_history.append({"role": "user", "content": "Unsafe fixture"})
	controller.message_history.append({"role": "assistant", "content": "", "tool_calls": [{"id": "missing_result", "type": "function", "function": {"name": "apply_patch", "arguments": "{}"}}]})
	controller._finish_request_error("fixture malformed history")
	_expect(not controller.last_failure_was_checkpointed(), "a tool call without its exact result must refuse recovery")
	_expect(JSON.stringify(controller.message_history).contains("missing_result"), "unsafe protocol should remain in memory for inspection rather than being misrepresented as recovered")
	await _free_controller(controller)


func _test_context_pressure_finalization() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	ModelMetadata.set_runtime_metadata("openai", "orca-pressure-test", {"context_window": 4096})
	controller._turn_provider_config = {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "orca-pressure-test", "api_key": "test"}
	var call := _simple_tool_call("pressure_read", "read_file")
	var selected_history: Array = []
	for padding in range(0, 14000, 100):
		var history := [
			{"role": "system", "content": "system"},
			{"role": "user", "content": "current " + "x".repeat(padding)},
			{"role": "assistant", "content": "", "tool_calls": [call]},
			{"role": "tool", "tool_call_id": "pressure_read", "content": "read completed"},
		]
		var final_history: Array = history.duplicate(true)
		final_history.append({"role": "system", "content": AgentController.LOOP_FINAL_NOTICE})
		if not ContextBudget.prepare(history, controller._get_tool_definitions(), 4096).get("success", true) and ContextBudget.prepare(final_history, [], 4096).get("success", false):
			selected_history = history
			break
	_expect(not selected_history.is_empty(), "the controller fixture should find a tools-full/no-tools-fitting context range")
	controller.message_history = selected_history
	controller._is_running = true
	controller._turn_id_serial = 1
	controller._active_turn_id = 1
	controller._tool_rounds = 1
	controller._reset_turn_loop_state()
	controller._turn_tool_receipts.append({"name": "read_file", "outcome": "completed"})
	_expect(controller._send_current_request(), "context pressure after a complete tool round should send one safe finalization request")
	_expect(api.requests.size() == 1 and api.requests[0].get("tools", [1]).is_empty(), "context-pressure fallback should send no tool schemas")
	_expect(controller._loop_final_request and controller._loop_final_trigger_reason == AgentController.LOOP_TRIGGER_CONTEXT_PRESSURE, "context pressure should retain its distinct finalization trigger")
	_expect(controller.support_request_metadata().get("stage") == "safe_finalization" and not controller.support_request_metadata().get("tools_offered", true), "support state should identify no-tools context-pressure finalization")
	_expect(_tool_result_count(api.requests[0].get("messages", []), "pressure_read") == 1 and _protocol_is_valid(api.requests[0].get("messages", [])), "context-pressure finalization must retain one complete tool result without replay")
	await _deliver_completion(controller, {"choices": [{"message": {"role": "assistant", "content": "Safely summarized completed work."}}]})
	_expect(not controller.is_busy() and str(controller.message_history[-1].get("content", "")).contains("A new request is needed"), "the provider-assisted pressure finalization should complete with explicit continuation guidance")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	var game: FakeGameProcessService = fixture["game"]
	var errors := []
	controller.error_occurred.connect(func(_turn_id: int, message: String): errors.append(message))
	ModelMetadata.set_runtime_metadata("openai", "orca-pressure-local-test", {"context_window": 2048})
	controller._turn_provider_config = {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "orca-pressure-local-test", "api_key": "test"}
	controller.message_history = [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "Preserve completed state"},
		{"role": "assistant", "content": "", "tool_calls": [_simple_tool_call("pressure_too_large", "read_file")]},
		{"role": "tool", "tool_call_id": "pressure_too_large", "content": "private-result-" + "z".repeat(24000)},
	]
	controller._tasks.assign([{"content": "Inspect failure", "status": "completed"}, {"content": "Continue safely", "status": "in_progress"}])
	controller._is_running = true
	controller._turn_id_serial = 1
	controller._active_turn_id = 1
	controller._tool_rounds = 1
	controller._reset_turn_loop_state()
	controller._turn_tool_receipts.append({"name": "read_file", "outcome": "completed"})
	controller._run_attempts = 1
	game.active = true
	game.run_id = 9
	game.snapshot["run_id"] = 9
	controller._turn_run_ids[9] = true
	game.snapshot["state"] = "running"
	_expect(not controller._send_current_request(), "an active tool turn that cannot fit even without tools should stop locally")
	_expect(api.requests.is_empty() and game.stops == 1 and not game.active, "local pressure fallback should avoid transport and clean up only the same-turn owned run")
	_expect(controller.last_failure_was_checkpointed() and errors.size() == 1, "local pressure fallback should emit one resumable deterministic checkpoint")
	var rendered_error := str(errors[0]) if not errors.is_empty() else ""
	var serialized := JSON.stringify(controller.message_history)
	_expect(rendered_error.contains(AgentController.RECOVERY_CHECKPOINT_HEADING) and rendered_error.contains("[completed] \"Inspect failure\"") and rendered_error.contains("controller_owned_run_cleanup: completed"), "the visible local checkpoint should contain bounded receipts, tasks, and normalized cleanup state")
	_expect(not serialized.contains("pressure_too_large") and not serialized.contains("private-result") and not serialized.contains("tool_calls") and not serialized.contains("\"role\":\"tool\""), "local pressure recovery must collapse call IDs, raw results, and replayable protocol")
	_expect(controller.snapshot_session_state().get("tasks") == controller._tasks and controller.support_request_metadata().get("failure_category") == "context_budget", "local pressure recovery should preserve tasks separately and report a local budget failure")
	ModelMetadata.set_runtime_metadata("openai", "orca-pressure-local-test", {"context_window": 32768})
	controller.send_user_message("Continue the unfinished work after re-inspection")
	_expect(api.requests.size() == 1 and not JSON.stringify(api.requests[0].get("messages", [])).contains("pressure_too_large"), "a later explicit request should retain the checkpoint without replaying prior tools")
	controller.cancel_current_request()
	ModelMetadata.remove_runtime_metadata("openai", "orca-pressure-test")
	ModelMetadata.remove_runtime_metadata("openai", "orca-pressure-local-test")
	await _free_controller(controller)


func _test_applied_change_recovery_does_not_replay() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	controller.edit_proposed.connect(func(turn_id: int, proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), turn_id, true))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller.message_history.append({"role": "user", "content": "Apply once"})
	await _deliver_completion(controller, _tool_response([_patch_call("recover_patch")]))
	_expect(tools.apply_calls == 1, "the recovery fixture should apply its approved change exactly once")
	_deliver_failure(controller, {"message": "disconnect after apply"})
	_expect(controller.last_failure_was_checkpointed(), "an applied change with a complete tool result should be recoverable")
	_expect(tools.apply_calls == 1, "building a recovery checkpoint must never replay an applied change")
	var serialized := JSON.stringify(controller.message_history)
	_expect(serialized.contains("apply_patch: applied") and not serialized.contains("new-hash") and not serialized.contains("new\\n"), "applied-change recovery should retain only a bounded outcome without proposal data")
	await _free_controller(controller)


func _test_context_budget_integration() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	ModelMetadata.set_runtime_metadata("openai", "orca-budget-test", {"context_window": 4096})
	controller.message_history = [
		{"role": "system", "content": "system"},
		{"role": "user", "content": "old " + "x".repeat(9000)},
		{"role": "assistant", "content": "old answer"},
		{"role": "system", "content": "CURRENT GODOT EDITOR CONTEXT FOR THIS TURN:\nfixture"},
		{"role": "user", "content": "current request"},
		{"role": "system", "content": "ORCA GAME RUN OBSERVATION FOR THIS TURN:\nfixture"},
		{"role": "system", "content": AgentController.LOOP_FINAL_NOTICE}
	]
	controller._context_message_index = 3
	controller._runtime_context_message_index = 5
	controller._loop_notice_message_index = 6
	controller._turn_provider_config = {"provider": "openai", "base_url": "https://api.openai.com/v1", "model": "orca-budget-test", "api_key": "test"}
	controller._is_running = true
	_owned_request_id(controller)
	_expect(controller._send_current_request(), "the controller should send a request after safe compaction")
	_expect(api.requests.size() == 1, "context preparation should issue exactly one provider request")
	if api.requests.size() == 1:
		var sent: Array = api.requests[0].get("messages", [])
		_expect(sent.any(func(message): return message.get("content") == ContextBudget.COMPACTION_NOTICE), "the controller should send the compaction notice")
		_expect(not sent.any(func(message): return str(message.get("content", "")).begins_with("old ")), "the controller should omit the oldest completed turn")
		_expect(controller._context_message_index >= 0 and str(controller.message_history[controller._context_message_index].get("content", "")).contains("CURRENT GODOT EDITOR CONTEXT"), "compaction should remap the request-scoped context index")
		_expect(controller._runtime_context_message_index >= 0 and str(controller.message_history[controller._runtime_context_message_index].get("content", "")).contains("ORCA GAME RUN OBSERVATION"), "compaction should remap runtime context safely")
		_expect(controller._loop_notice_message_index >= 0 and str(controller.message_history[controller._loop_notice_message_index].get("content", "")) == AgentController.LOOP_FINAL_NOTICE, "compaction should remap the loop notice safely")
		var continuation: Array = controller.snapshot_session_state().get("continuation", [])
		_expect(not continuation.any(func(message): return str(message.get("content", "")).begins_with("old ")), "session continuation should persist only retained model context")
		_expect(not continuation.any(func(message): return message.get("content") == ContextBudget.COMPACTION_NOTICE), "the internal compaction notice should not enter persisted user/assistant continuation")
	ModelMetadata.remove_runtime_metadata("openai", "orca-budget-test")
	await _free_controller(controller)


func _owned_request_id(controller) -> int:
	if controller._active_turn_id <= 0:
		controller._turn_id_serial += 1
		controller._active_turn_id = controller._turn_id_serial
	if controller._expected_provider_request_id <= 0:
		controller._provider_request_id_serial += 1
		controller._expected_provider_request_id = controller._provider_request_id_serial
	return controller._expected_provider_request_id


func _deliver_completion(controller, response: Dictionary) -> void:
	await controller._on_api_request_completed(_owned_request_id(controller), response)


func _deliver_failure(controller, error: Dictionary) -> void:
	controller._on_api_request_failed(_owned_request_id(controller), error)


func _new_controller() -> Dictionary:
	var controller = AgentController.new()
	get_root().add_child(controller)
	await process_frame
	var fake_api := FakeApiClient.new()
	var fake_tools := FakeTools.new()
	var fake_game := FakeGameProcessService.new()
	controller.set_api_client_for_testing(fake_api)
	controller.tools_script = fake_tools
	controller.game_process_service = fake_game
	return {"controller": controller, "api": fake_api, "tools": fake_tools, "game": fake_game}


func _free_controller(controller) -> void:
	controller.queue_free()
	await process_frame


func _patch_call(id: String) -> Dictionary:
	return _patch_call_with_hash(id, "old-hash")


func _patch_call_with_hash(id: String, base_hash: String) -> Dictionary:
	return {
		"id": id,
		"type": "function",
		"function": {
			"name": "apply_patch",
			"arguments": JSON.stringify({
				"filepath": "res://fixture.txt",
				"base_hash": base_hash,
				"edits": [{"start_line": 1, "end_line": 1, "replacement": "new"}]
			})
		}
	}


func _work_mode_call(id: String, reason: String) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "request_work_mode", "arguments": JSON.stringify({"reason": reason})}}


func _simple_tool_call(id: String, tool_name: String, arguments: Dictionary = {}) -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": tool_name, "arguments": JSON.stringify(arguments)}}


func _tool_response(tool_calls: Array) -> Dictionary:
	return {
		"model": "test-model",
		"requested_model": "test-model",
		"requested_api_url": "https://example.invalid/v1/chat/completions",
		"usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
		"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": tool_calls}}]
	}


func _runtime_observation_result(elapsed_ms: int, sequence: int, after_sequence: int) -> Dictionary:
	var data := {
		"run_id": 7,
		"sequence": sequence,
		"state": "running",
		"elapsed_ms": elapsed_ms,
		"verification_status": "pending",
		"exit_code": null,
		"stdout": "",
		"stderr": "",
		"diagnostics": [],
		"output_truncated": false,
		"diagnostics_truncated": false,
		"dropped_bytes": 0,
		"changed_since": false,
	}
	return {
		"name": "observe_game_run",
		"arguments": {"run_id": 7, "after_sequence": after_sequence},
		"outcome": "completed",
		"result": "Run 7 snapshot %d: running\nElapsed: %d ms" % [sequence, elapsed_ms],
		"execution": {"success": true, "content": "observation", "outcome": "completed", "data": data},
	}


func _tool_names(definitions: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for definition in definitions:
		names.append(str(definition.get("function", {}).get("name", "")))
	return names


func _tool_result_count(history: Array, call_id: String) -> int:
	var count := 0
	for message in history:
		if typeof(message) == TYPE_DICTIONARY and message.get("role") == "tool" and message.get("tool_call_id") == call_id:
			count += 1
	return count


func _tool_result_index(history: Array, call_id: String) -> int:
	for index in range(history.size()):
		var message = history[index]
		if typeof(message) == TYPE_DICTIONARY and message.get("role") == "tool" and message.get("tool_call_id") == call_id:
			return index
	return -1


func _tool_result_content(history: Array, call_id: String) -> String:
	var index := _tool_result_index(history, call_id)
	return str(history[index].get("content", "")) if index >= 0 else ""


func _tool_call_arguments(history: Array, call_id: String) -> Dictionary:
	var index := _assistant_call_index(history, call_id)
	if index < 0:
		return {}
	for call_value in history[index].get("tool_calls", []):
		var call: Dictionary = call_value if call_value is Dictionary else {}
		if str(call.get("id", "")) != call_id:
			continue
		var function: Dictionary = call.get("function", {}) if typeof(call.get("function")) == TYPE_DICTIONARY else {}
		var json := JSON.new()
		if json.parse(str(function.get("arguments", "{}"))) == OK and typeof(json.get_data()) == TYPE_DICTIONARY:
			return json.get_data()
	return {}


func _task_context_count(history: Array) -> int:
	var count := 0
	for message in history:
		if typeof(message) == TYPE_DICTIONARY and message.get("role") == "system" and str(message.get("content", "")).begins_with(AgentController.TASK_CONTEXT_HEADING):
			count += 1
	return count


func _task_context_content(history: Array) -> String:
	for message in history:
		if typeof(message) == TYPE_DICTIONARY and message.get("role") == "system" and str(message.get("content", "")).begins_with(AgentController.TASK_CONTEXT_HEADING):
			return str(message.get("content", ""))
	return ""


func _assistant_call_index(history: Array, call_id: String) -> int:
	for index in range(history.size()):
		var message = history[index]
		if typeof(message) != TYPE_DICTIONARY or message.get("role") != "assistant":
			continue
		for call in message.get("tool_calls", []):
			if typeof(call) == TYPE_DICTIONARY and str(call.get("id", "")) == call_id:
				return index
	return -1


func _protocol_is_valid(history: Array) -> bool:
	var index := 0
	while index < history.size():
		var message = history[index]
		if typeof(message) != TYPE_DICTIONARY:
			return false
		if message.get("role") == "tool":
			return false
		var calls = message.get("tool_calls", []) if message.get("role") == "assistant" else []
		if typeof(calls) == TYPE_ARRAY and not calls.is_empty():
			var expected := PackedStringArray()
			for call in calls:
				var id := str(call.get("id", ""))
				if id.is_empty() or id in expected:
					return false
				expected.append(id)
			for offset in range(calls.size()):
				var result_index := index + 1 + offset
				if result_index >= history.size() or history[result_index].get("role") != "tool":
					return false
				var result_id := str(history[result_index].get("tool_call_id", ""))
				if result_id not in expected:
					return false
				expected.erase(result_id)
			if not expected.is_empty():
				return false
			index += calls.size()
		index += 1
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("agent_controller_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("agent_controller_test: ", failure)
	quit(1)
