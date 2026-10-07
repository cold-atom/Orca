extends SceneTree

const AgentController = preload("res://addons/orca/scripts/agent_controller.gd")
const ContextBudget = preload("res://addons/orca/scripts/context_budget.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")
const AgentCompatibilityProbe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const ToolLoopGuard = preload("res://addons/orca/scripts/tool_loop_guard.gd")

class FakeApiClient:
	extends RefCounted
	var requests: Array[Dictionary] = []
	var requesting := false
	var cancelled := false

	func send_chat_completion(messages: Array, tools: Array, provider_config: Dictionary = {}, request_options: Dictionary = {}) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "provider_config": provider_config.duplicate(true), "request_options": request_options.duplicate(true)})

	func is_requesting() -> bool:
		return requesting

	func cancel_request() -> void:
		cancelled = true
		requesting = false

	func last_request_may_have_usage() -> bool:
		return false


class FakeGameProcessService:
	extends RefCounted
	var starts := 0
	var stops := 0
	var run_id := 0
	var snapshot := {"run_id": 0, "sequence": 0, "state": "idle", "scene_path": "", "verification_status": "unverified", "diagnostics": [], "stdout": "", "stderr": ""}
	var terminal_on_observe := false

	func start_current_scene(verification: Dictionary = {}) -> Dictionary:
		starts += 1
		run_id += 1
		snapshot = {"run_id": run_id, "sequence": 1, "state": "running", "scene_path": "res://main.tscn", "verification_status": "pending" if not verification.is_empty() else "unverified", "diagnostics": [], "stdout": "", "stderr": "", "criteria_id": JSON.stringify(verification).sha256_text() if not verification.is_empty() else ""}
		return {"success": true, "content": "started current", "outcome": "completed", "data": snapshot.duplicate(true)}

	func start_main_scene(verification: Dictionary = {}) -> Dictionary:
		return start_current_scene(verification)

	func stop_game() -> Dictionary:
		stops += 1
		return {"success": true, "content": "stopped", "outcome": "completed", "data": {"state": "stopped"}}

	func get_snapshot() -> Dictionary:
		return snapshot.duplicate(true)

	func observe_run(requested_run_id: int, after_sequence: int = -1) -> Dictionary:
		if requested_run_id != run_id:
			return {"success": false, "error": "unknown"}
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
		return {"success": true, "verification": {"run_id": run_id, "status": str(snapshot.get("verification_status", "unverified")), "claim": "fixture", "checks": []}}


class FakeTools:
	extends RefCounted
	var prepare_calls := 0
	var promote_calls := 0
	var apply_calls := 0
	var execute_calls := 0
	var changing_results := false

	func get_tool_definitions(include_edit_tools: bool = true) -> Array:
		var definitions := [
			{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "inspect_scene", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "inspect_project_settings", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "observe_game_run", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "verify_game_run", "parameters": {"type": "object"}}},
			{"type": "function", "function": {"name": "update_tasks", "parameters": {"type": "object"}}}
		]
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
			return {"success": verified.get("success", false), "content": "verified", "outcome": "completed" if verified.get("success", false) else "failed", "data": verified.get("verification", {})}
		if tool_name == "update_tasks":
			var validation := TaskUtils.validate_tasks(_arguments.get("tasks", null))
			if not validation.get("success", false):
				return {"success": false, "content": "Error: " + str(validation.get("error", "invalid")), "outcome": "failed", "data": {}}
			return {"success": true, "content": "updated", "outcome": "completed", "data": {"tasks": validation.get("tasks", [])}}
		var suffix := " " + str(execute_calls) if changing_results else ""
		return {"success": true, "content": "executed " + tool_name + suffix, "outcome": "completed", "data": {}}

	func prepare_file_patch(change_id: String, filepath: String, _base_hash: String, edits: Array) -> Dictionary:
		prepare_calls += 1
		return {
			"success": true,
			"id": change_id,
			"filepath": filepath,
			"old_content": "old\n",
			"new_content": "new\n",
			"old_hash": "old-hash",
			"new_hash": "new-hash",
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

	func apply_file_edit(_proposal: Dictionary) -> String:
		apply_calls += 1
		return "Applied changes to res://fixture.txt"

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

	func revert_file_edit(_proposal: Dictionary) -> String:
		return "Reverted changes to res://fixture.txt"

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
	await _test_local_chat_tool_denial()
	await _test_request_workflow_state()
	await _test_work_approval()
	await _test_work_rejection_protocol()
	await _test_cancellation_protocol()
	await _test_task_state()
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
	await _test_tool_call_count_bound()
	await _test_project_guidance_context()
	await _test_loop_guard_duplicate_denial()
	await _test_loop_guard_cycle_final_response()
	await _test_loop_guard_empty_final_response()
	await _test_loop_guard_cancellation_and_progress()
	await _test_tool_round_cap_finalization()
	await _test_recoverable_provider_failure()
	await _test_applied_change_recovery_does_not_replay()
	await _test_incomplete_protocol_refuses_recovery()
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
	controller.workflow_state_changed.connect(func(state: String, details: Dictionary):
		states.append({"state": state, "details": details.duplicate(true)})
	)
	controller.send_user_message("Inspect the project")
	_expect(states.size() == 1 and states[0].get("state") == "thinking" and not bool(states[0].get("details", {}).get("follow_up", true)), "the initial provider request should expose a thinking workflow state")
	await controller._on_api_request_completed(_tool_response([
		{"id": "workflow_read", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}
	]))
	_expect(states.size() >= 2 and states[-1].get("state") == "thinking" and bool(states[-1].get("details", {}).get("follow_up", false)), "a provider request after tools should expose a follow-up preparing state")
	await _free_controller(controller)


func _test_work_approval() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var apply_count_at_proposal := [-1]
	var review_proposals := []
	controller.edit_proposed.connect(func(proposal: Dictionary):
		apply_count_at_proposal[0] = tools.apply_calls
		review_proposals.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true)
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


func _test_work_rejection_protocol() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var api: FakeApiClient = fixture["api"]
	controller.edit_proposed.connect(func(proposal: Dictionary):
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), false)
	)
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([_patch_call("reject_call")]))
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
	controller.request_cancelled.connect(func(): cancelled_count[0] += 1)
	controller.edit_proposed.connect(func(_proposal: Dictionary):
		controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([
		_patch_call("cancel_patch"),
		{"id": "cancel_read", "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://fixture.txt\"}"}}
	]))
	_expect(cancelled_count[0] == 1, "cancelling a pending approval should emit request_cancelled once")
	_expect(not controller.is_busy(), "cancelling a pending approval should finish the request")
	_expect(tools.apply_calls == 0, "cancelled approval must not apply")
	_expect(tools.execute_calls == 0, "remaining tools must not execute after cancellation")
	_expect(controller._proposals.is_empty(), "cancelled proposals should release private retained content")
	_expect(api.requests.is_empty(), "cancelled tool rounds must not send a follow-up request")
	_expect(_tool_result_count(controller.message_history, "cancel_patch") == 1, "cancelled proposal should receive one tool result")
	_expect(_tool_result_count(controller.message_history, "cancel_read") == 1, "unexecuted remaining call should receive one cancellation result")
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


func _test_scene_inspection_permission() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	_expect(controller.set_mode(AgentController.AgentMode.PLAN), "scene inspection should be available from Plan mode")
	_expect(_tool_names(controller._get_tool_definitions()).has("inspect_scene"), "Plan schema should expose inspect_scene")
	var proposals := [0]
	controller.edit_proposed.connect(func(_proposal: Dictionary): proposals[0] += 1)
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
	controller.edit_proposed.connect(func(_proposal: Dictionary): proposals[0] += 1)
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
	controller.edit_proposed.connect(func(proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true))
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
	controller._proposals["applied"] = {"id": "applied", "kind": "file_patch", "filepath": "res://fixture.txt", "status": "applied"}
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
	controller.edit_proposed.connect(func(proposal: Dictionary):
		visible_proposals.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true)
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
	controller.edit_proposed.connect(func(proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true))
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
	controller.edit_proposed.connect(func(proposal: Dictionary):
		visible.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true)
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
	controller.edit_proposed.connect(func(proposal: Dictionary):
		visible.append(proposal)
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true)
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
	controller.edit_proposed.connect(func(proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), false))
	result = await controller._execute_tool_call(call)
	_expect(result.get("outcome") == "rejected" and tools.promote_calls == 0 and tools.apply_calls == 0, "rejecting preliminary script trust must not construct or apply a candidate")
	await _free_controller(controller)


func _test_scene_script_second_stage_resolution() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var api: FakeApiClient = fixture["api"]
	var stage := [0]
	controller.edit_proposed.connect(func(proposal: Dictionary):
		stage[0] += 1
		controller.call_deferred("resolve_edit", str(proposal.get("id", "")), stage[0] == 1)
	)
	var call := {"id": "script_reject_final", "type": "function", "function": {"name": "propose_scene_changes", "arguments": JSON.stringify({"scene_path": "res://actor.tscn", "base_hash": "scene-hash", "operations": [{"operation": "attach_script", "node_path": ".", "script_path": "res://actor.gd", "script_hash": "script-hash"}]})}}
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([call]))
	_expect(stage[0] == 2 and tools.promote_calls == 1 and tools.apply_calls == 0, "rejecting the final script candidate should occur after exactly one trusted construction and before apply")
	_expect(api.requests.size() == 1 and _tool_result_count(api.requests[0].get("messages", []), "script_reject_final") == 1, "both script decisions should still produce exactly one protocol tool result")
	_expect(_protocol_is_valid(api.requests[0].get("messages", [])), "second-stage script rejection history should remain protocol-valid")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	tools = fixture["tools"]
	api = fixture["api"]
	stage = [0]
	controller.edit_proposed.connect(func(proposal: Dictionary):
		stage[0] += 1
		if stage[0] == 1:
			controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true)
		else:
			controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([call]))
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
	controller.workflow_state_changed.connect(func(state: String, _details: Dictionary): states.append(state))
	controller._is_running = true
	var run_call := {"id": "observed_run", "type": "function", "function": {"name": "run_current_scene", "arguments": JSON.stringify({"verification": {"kind": "expected_exit", "expected_exit_code": 0}})}}
	await controller._on_api_request_completed(_tool_response([run_call]))
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
	controller.workflow_state_changed.connect(func(state: String, _details: Dictionary):
		if state == "observing":
			controller.call_deferred("cancel_current_request")
	)
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([run_call]))
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancelling during observation should suppress the delayed provider request")
	_expect(_tool_result_count(controller.message_history, "observed_run") == 1 and _protocol_is_valid(controller.message_history), "observation cancellation should preserve the completed run tool result")
	_expect(game.stops == 0, "cancelling model observation must not stop the independently owned game process")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	game = fixture["game"]
	api = fixture["api"]
	game.terminal_on_observe = true
	controller.workflow_state_changed.connect(func(state: String, _details: Dictionary):
		if state == "assessment_ready":
			controller.cancel_current_request()
	)
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response([run_call]))
	_expect(api.requests.is_empty() and not controller.is_busy(), "cancelling at assessment-ready must not send the delayed provider request")
	_expect(_tool_result_count(controller.message_history, "observed_run") == 1 and _protocol_is_valid(controller.message_history), "assessment-ready cancellation should preserve protocol-valid run history")
	await _free_controller(controller)


func _test_tool_call_count_bound() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	var errors := []
	controller.error_occurred.connect(func(message: String): errors.append(message))
	var calls := []
	for index in range(AgentController.MAX_TOOL_CALLS_PER_RESPONSE + 1):
		calls.append({"id": "many_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}})
	controller._is_running = true
	await controller._on_api_request_completed(_tool_response(calls))
	_expect(tools.execute_calls == 0 and not controller.is_busy(), "oversized tool-call batches must fail before any tool side effect")
	_expect(errors.size() == 1 and str(errors[0]).contains("more than"), "oversized tool-call batches should report a bounded-response error")
	await _free_controller(controller)


func _test_project_guidance_context() -> void:
	var controller := GuidanceController.new()
	get_root().add_child(controller)
	await process_frame
	controller.api_client = FakeApiClient.new()
	controller.tools_script = FakeTools.new()
	controller._tasks.assign([{"content": "Fixture task", "status": "pending"}])
	controller._add_turn_context()
	var context := str(controller.message_history[-1].get("content", ""))
	_expect(context.contains("WRAPPED EXACT GUIDANCE"), "turn context should include the service's exact wrapped AGENTS content")
	_expect(context.contains("Fixture Skill") and context.contains("Catalog description"), "turn context should include bounded skill catalog metadata")
	_expect(not context.contains("SECRET SKILL BODY") and not context.contains("SECRET WRAPPER") and not context.contains("wrapped_body"), "turn context must redact skill bodies and non-catalog fields")
	_expect(context.contains("CURRENT GODOT EDITOR CONTEXT") and context.contains("CURRENT ORCA TASK CHECKLIST"), "guidance should share the single existing editor/task context message")
	_expect(controller._context_message_index == controller.message_history.size() - 1, "guidance should use one tracked request-scoped message")
	controller._clear_turn_context()
	_expect(not JSON.stringify(controller.message_history).contains("WRAPPED EXACT GUIDANCE"), "request-scoped guidance should be removed when a turn ends")
	controller.instruction_result = {"success": false, "error": "root failed\n" + "x".repeat(1000)}
	controller.skill_result = {"success": false, "error": "catalog failed"}
	controller._add_turn_context()
	context = str(controller.message_history[-1].get("content", ""))
	_expect(context.contains("PROJECT GUIDANCE WARNING: root failed") and context.contains("PROJECT SKILL CATALOG WARNING: catalog failed"), "guidance service errors should become request context warnings instead of aborting")
	_expect(not context.contains("\nxxxxxxxx"), "guidance warnings should be normalized and bounded")
	controller._is_running = true
	controller._finish_cancelled()
	_expect(controller._context_message_index == -1 and not JSON.stringify(controller.message_history).contains("root failed"), "cancellation should remove guidance and reset its index")
	controller._add_turn_context()
	controller._is_running = true
	controller._on_api_request_failed({"message": "fixture failure"})
	_expect(controller._context_message_index == -1 and controller._tool_loop_guard == null, "request failure should remove guidance and reset loop state")
	await _free_controller(controller)


func _test_loop_guard_duplicate_denial() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(3):
		await controller._on_api_request_completed(_tool_response([{"id": "duplicate_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://same.gd\"}"}}]))
	_expect(api.requests.size() == 3, "three duplicate rounds should issue two normal continuations and exactly one forced final request")
	_expect(api.requests[-1].get("tools", [1]).is_empty(), "the loop guard's final request must expose tools=[]")
	_expect(controller._loop_final_request and controller._loop_notice_message_index >= 0, "duplicate detection should append one tracked request-scoped loop notice")
	_expect(controller._loop_final_trigger_reason == "identical_call_result", "duplicate detection should preserve its exact trigger reason")
	var visible_messages := []
	controller.message_received.connect(func(_role: String, content: String): visible_messages.append(content))
	var denied_response := _tool_response([
		{"id": "denied_a", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
		{"id": "denied_b", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
	])
	denied_response["choices"][0]["message"]["content"] = "I completed the inspection before trying one more read."
	denied_response["choices"][0]["message"]["reasoning_content"] = "hidden reasoning must not render"
	await controller._on_api_request_completed(denied_response)
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
		await controller._on_api_request_completed(_tool_response([
			{"id": "cycle_a_%d" % round_index, "type": "function", "function": {"name": "read_file", "arguments": "{\"filepath\":\"res://a.gd\"}"}},
			{"id": "cycle_b_%d" % round_index, "type": "function", "function": {"name": "inspect_scene", "arguments": "{\"scene_path\":\"res://b.tscn\"}"}}
		]))
	_expect(api.requests.size() == 3 and api.requests[-1].get("tools", [1]).is_empty(), "an alternating cycle should also issue exactly one no-tools final request")
	await controller._on_api_request_completed({"choices": [{"message": {"role": "assistant", "content": "Stopped safely."}}]})
	_expect(not controller.is_busy() and not JSON.stringify(controller.message_history).contains(AgentController.LOOP_FINAL_NOTICE), "a valid forced-final answer should finish and remove the loop notice")
	_expect(str(controller.message_history[-1].get("content", "")).contains("`continue` is not special") and str(controller.message_history[-1].get("content", "")).contains("re-inspect the current state"), "a valid forced-final answer should receive explicit non-replay continuation guidance")
	await _free_controller(controller)


func _test_loop_guard_empty_final_response() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var states: Array[Dictionary] = []
	var visible_messages := []
	controller.workflow_state_changed.connect(func(state: String, details: Dictionary): states.append({"state": state, "details": details.duplicate(true)}))
	controller.message_received.connect(func(_role: String, content: String): visible_messages.append(content))
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(3):
		await controller._on_api_request_completed(_tool_response([{"id": "empty_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	_expect(api.requests.size() == 3 and api.requests[-1].get("tools", [1]).is_empty(), "empty-finalization fixture should reach one no-tools request")
	_expect(states[-1].get("state") == "finalizing" and states[-1].get("details", {}).get("trigger_reason") == "identical_call_result", "forced finalization should expose its distinct state and trigger")
	await controller._on_api_request_completed({"choices": [{"message": {"role": "assistant", "content": "  \n "}}]})
	_expect(visible_messages.size() == 1 and str(visible_messages[0]).contains("provider returned no summary"), "an empty no-tools response should produce a visible local fallback")
	_expect(str(visible_messages[0]).contains("Completed actions were kept") and str(visible_messages[0]).contains("A new request is needed"), "empty finalization should explain the retained work and required next request")
	_expect(controller.message_history[-1].get("content") == visible_messages[0], "the exact visible fallback should be retained in assistant history")
	_expect(not controller.is_busy(), "empty finalization fallback should end the request")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	visible_messages = []
	controller.message_received.connect(func(_role: String, content: String): visible_messages.append(content))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._begin_loop_finalization(ToolLoopGuard.REASON_NO_PROGRESS)
	controller._on_api_request_failed({"message": "The provider completed without visible assistant content or a valid tool call.", "category": "malformed_response"})
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
		await controller._on_api_request_completed(_tool_response([{"id": "cancel_loop_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	api.requesting = true
	controller.cancel_current_request()
	controller._on_api_request_cancelled()
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
		await controller._on_api_request_completed(_tool_response([{"id": "changing_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]))
	_expect(api.requests.size() == 4 and not api.requests[-1].get("tools", []).is_empty(), "changed results for the same stable call should count as progress and avoid false loop finalization")
	_expect(not controller._loop_final_request, "stable result changes should keep the normal tool loop active")
	await _free_controller(controller)

	fixture = await _new_controller()
	controller = fixture["controller"]
	api = fixture["api"]
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(4):
		await controller._on_api_request_completed(_tool_response([{"id": "distinct_%d" % index, "type": "function", "function": {"name": "read_file", "arguments": JSON.stringify({"filepath": "res://file_%d.gd" % index})}}]))
	_expect(api.requests.size() == 4 and not api.requests[-1].get("tools", []).is_empty(), "distinct tool evidence should count as progress and avoid no-progress finalization")
	_expect(not controller._loop_final_request, "new stable tool invocations should keep the normal tool loop active")
	await _free_controller(controller)


func _test_tool_round_cap_finalization() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var errors := []
	controller.error_occurred.connect(func(message: String): errors.append(message))
	controller._is_running = true
	controller._reset_turn_loop_state()
	for index in range(AgentController.MAX_TOOL_ROUNDS):
		await controller._on_api_request_completed(_tool_response([{
			"id": "bounded_%d" % index,
			"type": "function",
			"function": {"name": "read_file", "arguments": JSON.stringify({"filepath": "res://bounded_%d.gd" % index})}
		}]))
	_expect(api.requests.size() == AgentController.MAX_TOOL_ROUNDS, "the hard tool-round boundary should request one final response instead of failing")
	_expect(api.requests[-1].get("tools", [1]).is_empty(), "the hard tool-round boundary must remove the tool schema")
	_expect(controller._loop_final_trigger_reason == AgentController.LOOP_TRIGGER_ROUND_CAP, "the hard cap should remain distinct from repetitive/no-progress triggers")
	_expect(errors.is_empty() and controller.is_busy(), "reaching the tool-round boundary should remain active while awaiting the final response")
	await controller._on_api_request_completed({"choices": [{"message": {"role": "assistant", "content": "Bounded summary."}}]})
	_expect(not controller.is_busy() and errors.is_empty(), "a final answer at the tool-round boundary should complete without a system error")
	await _free_controller(controller)


func _test_recoverable_provider_failure() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var api: FakeApiClient = fixture["api"]
	var tools: FakeTools = fixture["tools"]
	var errors := []
	controller.error_occurred.connect(func(message: String): errors.append(message))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller.message_history.append({"role": "user", "content": "Inspect safely"})
	await controller._on_api_request_completed(_tool_response([{
		"id": "recover_read",
		"type": "function",
		"function": {"name": "read_file", "arguments": "{\"filepath\":\"res://secret.gd\"}"}
	}]))
	_expect(api.requests.size() == 1 and tools.execute_calls == 1, "a completed recovery fixture tool should issue one follow-up")
	controller._current_stream_content = "private partial provider output"
	controller._on_api_request_failed({"message": "fixture disconnect", "partial_response": true})
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


func _test_applied_change_recovery_does_not_replay() -> void:
	var fixture := await _new_controller()
	var controller = fixture["controller"]
	var tools: FakeTools = fixture["tools"]
	controller.edit_proposed.connect(func(proposal: Dictionary): controller.call_deferred("resolve_edit", str(proposal.get("id", "")), true))
	controller._is_running = true
	controller._reset_turn_loop_state()
	controller._reset_turn_recovery_state()
	controller.message_history.append({"role": "user", "content": "Apply once"})
	await controller._on_api_request_completed(_tool_response([_patch_call("recover_patch")]))
	_expect(tools.apply_calls == 1, "the recovery fixture should apply its approved change exactly once")
	controller._on_api_request_failed({"message": "disconnect after apply"})
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


func _new_controller() -> Dictionary:
	var controller = AgentController.new()
	get_root().add_child(controller)
	await process_frame
	var fake_api := FakeApiClient.new()
	var fake_tools := FakeTools.new()
	var fake_game := FakeGameProcessService.new()
	controller.api_client = fake_api
	controller.tools_script = fake_tools
	controller.game_process_service = fake_game
	return {"controller": controller, "api": fake_api, "tools": fake_tools, "game": fake_game}


func _free_controller(controller) -> void:
	controller.queue_free()
	await process_frame


func _patch_call(id: String) -> Dictionary:
	return {
		"id": id,
		"type": "function",
		"function": {
			"name": "apply_patch",
			"arguments": JSON.stringify({
				"filepath": "res://fixture.txt",
				"base_hash": "old-hash",
				"edits": [{"start_line": 1, "end_line": 1, "replacement": "new"}]
			})
		}
	}


func _tool_response(tool_calls: Array) -> Dictionary:
	return {
		"model": "test-model",
		"requested_model": "test-model",
		"requested_api_url": "https://example.invalid/v1/chat/completions",
		"usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
		"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": tool_calls}}]
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
