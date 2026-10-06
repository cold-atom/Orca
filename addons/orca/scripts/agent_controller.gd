@tool
extends Node

signal message_received(role: String, content: String)
signal error_occurred(message: String)
signal tool_execution_started(call_id: String, tool_name: String, arguments: Dictionary)
signal tool_execution_completed(call_id: String, tool_name: String, execution: Dictionary, duration_ms: int)
signal edit_proposed(proposal: Dictionary)
signal edit_resolved(change_id: String, status: String, message: String)
signal message_stream_started
signal message_stream_delta(content: String)
signal request_state_changed(is_busy: bool)
signal request_cancelled
signal edit_decision_received(resolution: Dictionary)
signal mode_changed(mode: int)
signal session_usage_changed(summary: Dictionary)
signal model_metadata_requested(model: String, api_url: String)
signal tasks_changed(tasks: Array)
signal workflow_state_changed(state: String, details: Dictionary)

const MAX_TOOL_ROUNDS := 12
const MAX_TOOL_CALLS_PER_RESPONSE := 16
const MAX_RUN_ATTEMPTS_PER_TURN := 3
const OBSERVATION_SETTLE_MS := 1500
const OBSERVATION_MAX_WAIT_MS := 5000
const REVIEWED_MUTATION_TOOLS := {
	"apply_patch": true,
	"propose_input_map_changes": true,
	"propose_main_scene_change": true,
	"propose_project_settings_changes": true,
	"propose_scene_changes": true
}
const WORK_OPERATION_TOOLS := {
	"run_current_scene": true,
	"run_main_scene": true,
	"stop_game": true
}
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const ContextBudget = preload("res://addons/orca/scripts/context_budget.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const ProjectInstructions = preload("res://addons/orca/scripts/project_instructions.gd")
const ProjectSkills = preload("res://addons/orca/scripts/project_skills.gd")
const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const ToolLoopGuardScript = preload("res://addons/orca/scripts/tool_loop_guard.gd")
const LOOP_FINAL_NOTICE := "ORCA TOOL LOOP NOTICE: Stop using tools for this turn. Give the user a concise final response that summarizes completed work, unresolved items, and the safest next step. Do not request or describe additional tool calls."
const RECOVERY_CHECKPOINT_HEADING := "ORCA RECOVERY CHECKPOINT"
const MAX_RECOVERY_RECEIPTS := MAX_TOOL_ROUNDS * MAX_TOOL_CALLS_PER_RESPONSE
const MAX_GUIDANCE_WARNING_CHARS := 240
const LOOP_TRIGGER_ROUND_CAP := "round_cap"
const MAX_FINAL_PROVIDER_TEXT_CHARS := 1200

enum AgentMode {
	PLAN,
	BUILD
}

var api_client
var tools_script
var game_process_service
var message_history: Array = []
var _is_running := false
var _current_stream_content := ""
var _cancel_requested := false
var _pending_change_id := ""
var _proposals: Dictionary = {}
var _tool_rounds := 0
var _mode: AgentMode = AgentMode.BUILD
var _context_message_index := -1
var _runtime_context_message_index := -1
var _pending_run_observation: Dictionary = {}
var _observation_generation := 0
var _run_attempts := 0
var _baseline_criteria_id := ""
var _baseline_criteria_initialized := false
var _session_input_tokens := 0
var _session_output_tokens := 0
var _session_cached_tokens := 0
var _latest_context_tokens := 0
var _session_cost_usd := 0.0
var _usage_complete := true
var _cost_complete := true
var _completed_requests := 0
var _last_usage_model := ""
var _last_configured_model := ""
var _last_api_url := ""
var _cost_records: Array[Dictionary] = []
var _all_costs_available := true
var _cost_estimated := false
var _restored_cost_usd := 0.0
var _restored_cost_available := true
var _restored_cost_estimated := false
var _restored_context_limit := 0
var _turn_provider_config: Dictionary = {}
var _tasks: Array[Dictionary] = []
var _tool_loop_guard
var _tool_progress_epoch := 0
var _tool_progress_fingerprints: Dictionary = {}
var _loop_final_request := false
var _loop_final_trigger_reason := ""
var _loop_notice_message_index := -1
var _turn_tool_receipts: Array[Dictionary] = []
var _last_failure_checkpointed := false

func _ready() -> void:
	api_client = preload("res://addons/orca/scripts/api_client.gd").new()
	# The streaming client awaits process frames, so it must be in the active scene tree.
	add_child(api_client)
	api_client.request_completed.connect(_on_api_request_completed)
	api_client.request_failed.connect(_on_api_request_failed)
	api_client.request_cancelled.connect(_on_api_request_cancelled)
	api_client.stream_started.connect(_on_stream_started)
	api_client.stream_delta.connect(_on_stream_delta)
	
	tools_script = preload("res://addons/orca/scripts/tools.gd")
	
	_init_system_prompt()
	_reset_session_usage()

func _init_system_prompt() -> void:
	message_history = []
	message_history.append({
		"role": "system",
		"content": _get_system_prompt()
	})

func send_user_message(text: String) -> void:
	if _is_running:
		return
	_is_running = true
	_cancel_requested = false
	_tool_rounds = 0
	_reset_turn_loop_state()
	_reset_turn_recovery_state()
	_run_attempts = 0
	_baseline_criteria_id = ""
	_baseline_criteria_initialized = false
	_pending_run_observation.clear()
	_turn_provider_config = Config.get_active_provider_config()
	request_state_changed.emit(true)
	_add_turn_context()
	message_history.append({
		"role": "user",
		"content": text
	})
	_send_current_request()

func _add_turn_context() -> void:
	var sections := PackedStringArray()
	if not _turn_allows_tools():
		sections.append("LOCAL CHAT MODE: Project tools are disabled for this provider until this exact endpoint and model pass Orca's future Agent compatibility flow. Answer conversationally and do not request or claim tool actions.")
	var instruction_result := _load_project_instructions()
	if bool(instruction_result.get("success", false)):
		if bool(instruction_result.get("found", false)) and not str(instruction_result.get("wrapped_content", "")).is_empty():
			sections.append(str(instruction_result["wrapped_content"]))
	else:
		sections.append("PROJECT GUIDANCE WARNING: " + _bounded_context_warning(str(instruction_result.get("error", "Project instructions could not be loaded."))))
	var skill_result := _discover_project_skills()
	if bool(skill_result.get("success", false)):
		var catalog: Array[Dictionary] = []
		for raw_skill in skill_result.get("skills", []):
			if typeof(raw_skill) != TYPE_DICTIONARY:
				continue
			var skill: Dictionary = raw_skill
			catalog.append({
				"name": str(skill.get("name", "")),
				"description": str(skill.get("description", "")),
				"slug": str(skill.get("slug", "")),
				"path": str(skill.get("path", "")),
			})
		if not catalog.is_empty():
			sections.append("AVAILABLE PROJECT SKILLS (metadata only; use read_project_skill with one exact name to load a body):\n" + JSON.stringify(catalog, "  "))
	else:
		sections.append("PROJECT SKILL CATALOG WARNING: " + _bounded_context_warning(str(skill_result.get("error", "Project skills could not be discovered."))))
	var editor_context := EditorContext.capture()
	if not editor_context.is_empty() or not _tasks.is_empty():
		sections.append("CURRENT GODOT EDITOR CONTEXT FOR THIS TURN:\n" + EditorContext.format_for_model(editor_context))
	if not _tasks.is_empty():
		sections.append("CURRENT ORCA TASK CHECKLIST:\n" + JSON.stringify(_tasks, "  "))
	if not sections.is_empty():
		_context_message_index = message_history.size()
		message_history.append({
			"role": "system",
			"content": "\n\n".join(sections)
		})


func _load_project_instructions() -> Dictionary:
	return ProjectInstructions.load_project_instructions()


func _discover_project_skills() -> Dictionary:
	return ProjectSkills.discover_skills()


func _bounded_context_warning(message: String) -> String:
	var normalized := " ".join(message.replace("\r", "\n").replace("\t", " ").split("\n", false)).strip_edges()
	return normalized.left(MAX_GUIDANCE_WARNING_CHARS)

func is_busy() -> bool:
	return _is_running


func start_new_session() -> bool:
	if _is_running or not _pending_change_id.is_empty() or api_client.is_requesting():
		return false
	_init_system_prompt()
	_proposals.clear()
	_pending_change_id = ""
	_context_message_index = -1
	_runtime_context_message_index = -1
	_tool_rounds = 0
	_reset_turn_loop_state()
	_reset_turn_recovery_state()
	_run_attempts = 0
	_baseline_criteria_id = ""
	_baseline_criteria_initialized = false
	_pending_run_observation.clear()
	_cancel_requested = false
	_current_stream_content = ""
	_reset_session_usage()
	_tasks.clear()
	return true


func refresh_session_usage() -> void:
	_recalculate_session_cost()
	_emit_session_usage(_last_usage_model)


func snapshot_session_state() -> Dictionary:
	var continuation: Array = []
	for message in message_history:
		if typeof(message) != TYPE_DICTIONARY:
			continue
		var role := str(message.get("role", ""))
		if role not in ["user", "assistant"] or message.has("tool_calls"):
			continue
		var content = message.get("content", "")
		if typeof(content) == TYPE_STRING:
			continuation.append({"role": role, "content": content})
	return {
		"mode": _mode,
		"continuation": continuation,
		"usage": _session_usage_summary(_last_usage_model),
		"tasks": _tasks.duplicate(true)
	}


func restore_session_state(mode: int, continuation: Array, usage: Dictionary, tasks: Array = []) -> bool:
	if _is_running or not _pending_change_id.is_empty() or api_client.is_requesting():
		return false
	var task_validation := TaskUtils.validate_tasks(tasks)
	if mode not in [AgentMode.PLAN, AgentMode.BUILD] or not _valid_continuation(continuation) or not task_validation.get("success", false):
		return false
	_mode = mode as AgentMode
	_init_system_prompt()
	for message in continuation:
		message_history.append(message.duplicate(true))
	_proposals.clear()
	_pending_change_id = ""
	_context_message_index = -1
	_runtime_context_message_index = -1
	_tool_rounds = 0
	_reset_turn_loop_state()
	_reset_turn_recovery_state()
	_run_attempts = 0
	_baseline_criteria_id = ""
	_baseline_criteria_initialized = false
	_pending_run_observation.clear()
	_cancel_requested = false
	_current_stream_content = ""
	_restore_session_usage(usage)
	_tasks.assign(task_validation.get("tasks", []))
	mode_changed.emit(_mode)
	return true

func get_mode() -> int:
	return _mode

func set_mode(mode: int) -> bool:
	if _is_running or mode not in [AgentMode.PLAN, AgentMode.BUILD]:
		return false
	if _mode == mode:
		return true
	_mode = mode as AgentMode
	if not message_history.is_empty() and message_history[0].get("role") == "system":
		message_history[0]["content"] = _get_system_prompt()
	message_history.append({
		"role": "system",
		"content": _get_mode_transition_prompt()
	})
	mode_changed.emit(_mode)
	return true

func cancel_current_request() -> void:
	if not _is_running:
		return
	_cancel_requested = true
	_observation_generation += 1
	if not _pending_change_id.is_empty():
		_cancel_pending_edit()
	elif api_client.is_requesting():
		api_client.cancel_request()
	else:
		_finish_cancelled()

func resolve_edit(change_id: String, approved: bool) -> void:
	if change_id != _pending_change_id or not _proposals.has(change_id):
		return
	var proposal: Dictionary = _proposals[change_id]
	var status := "rejected"
	var result: String = "The user rejected the proposed changes to " + str(proposal.get("filepath", "the file")) + "."
	var success := false
	if approved:
		if _mode != AgentMode.BUILD:
			result = "Error: File changes cannot be applied while Orca is in Plan mode."
			status = "failed"
		elif str(proposal.get("approval_stage", "")) == "script_trust":
			var promoted: Dictionary = tools_script.promote_script_trust(proposal)
			if not promoted.get("success", false):
				result = "Error: " + str(promoted.get("error", "Could not construct the trusted script candidate."))
				for diagnostic in promoted.get("diagnostics", []):
					result += "\n%s:%d: %s" % [diagnostic.get("file", ""), diagnostic.get("line", 0), diagnostic.get("message", "")]
				status = "failed"
			else:
				_proposals[change_id] = promoted.duplicate(true)
				edit_proposed.emit(_proposal_for_review(promoted))
				return
		else:
			result = tools_script.apply_reviewed_change(proposal)
			status = "failed" if result.begins_with("Error:") or result.begins_with("Conflict:") else "apply_recovery_required" if result.begins_with("Recovery required:") else "applied_recovery" if result.begins_with("Cleanup required:") else "applied"
			success = status in ["applied", "applied_recovery"]
	proposal["status"] = status
	if status in ["applied", "applied_recovery", "apply_recovery_required"]:
		_proposals[change_id] = proposal
	else:
		_proposals.erase(change_id)
	_pending_change_id = ""
	edit_resolved.emit(change_id, status, result)
	edit_decision_received.emit({"change_id": change_id, "result": result, "success": success, "outcome": status})

func revert_edit(change_id: String) -> void:
	if not _proposals.has(change_id):
		return
	var proposal: Dictionary = _proposals[change_id]
	if proposal.get("status") not in ["applied", "applied_recovery"]:
		return
	if _mode != AgentMode.BUILD:
		edit_resolved.emit(change_id, "revert_failed", "Error: Project changes cannot be reverted while Orca is in Plan mode.")
		return
	if not proposal.get("exact_applied_state", false):
		edit_resolved.emit(change_id, "revert_failed", "Error: Revert is unavailable because the exact applied candidate state has not been proven.")
		return
	var result: String = tools_script.revert_reviewed_change(proposal)
	var status := "conflict" if result.begins_with("Conflict:") else "revert_failed" if result.begins_with("Error:") else "revert_recovery_required" if result.begins_with("Recovery required:") else "reverted_recovery" if result.begins_with("Cleanup required:") else "reverted"
	if status in ["reverted", "reverted_recovery"]:
		proposal["status"] = status
		_proposals.erase(change_id)
	else:
		proposal["status"] = status
		_proposals[change_id] = proposal
	edit_resolved.emit(change_id, status, result)

func _cancel_pending_edit() -> void:
	if _pending_change_id.is_empty() or not _proposals.has(_pending_change_id):
		return
	var change_id := _pending_change_id
	var proposal: Dictionary = _proposals[change_id]
	proposal["status"] = "cancelled"
	_proposals.erase(change_id)
	_pending_change_id = ""
	var result := "The proposed edit was cancelled before a decision was made."
	edit_resolved.emit(change_id, "cancelled", result)
	edit_decision_received.emit({"change_id": change_id, "result": result, "success": false, "outcome": "cancelled"})

func _on_api_request_completed(response: Dictionary) -> void:
	_record_request_usage(response)
	if response.has("choices") and typeof(response.get("choices")) == TYPE_ARRAY and response.choices.size() > 0 and typeof(response.choices[0]) == TYPE_DICTIONARY and typeof(response.choices[0].get("message")) == TYPE_DICTIONARY:
		var choice = response.choices[0]
		var message = choice.message
		
		# Build assistant message for history
		var assistant_message = {
			"role": "assistant",
			"content": message.get("content", "") if message.get("content") != null else ""
		}
		for continuation_field in ["reasoning_content", "reasoning", "reasoning_details"]:
			if message.has(continuation_field):
				assistant_message[continuation_field] = message[continuation_field]
		
		if message.has("tool_calls") and typeof(message.tool_calls) == TYPE_ARRAY and not message.tool_calls.is_empty():
			if message.tool_calls.size() > MAX_TOOL_CALLS_PER_RESPONSE:
				_finish_request_error("The provider returned more than %d tool calls in one response." % MAX_TOOL_CALLS_PER_RESPONSE)
				return
			if _loop_final_request:
				_finish_denied_loop_calls(assistant_message, message.tool_calls)
				return
			_tool_rounds += 1
			if _tool_rounds > MAX_TOOL_ROUNDS:
				_loop_final_trigger_reason = LOOP_TRIGGER_ROUND_CAP
				_finish_denied_loop_calls(assistant_message, message.tool_calls)
				return
			assistant_message["tool_calls"] = message.tool_calls
			message_history.append(assistant_message)
			var round_results: Array = []

			for tool_index in range(message.tool_calls.size()):
				var tool_call: Dictionary = message.tool_calls[tool_index]
				var tool_result: Dictionary = await _execute_tool_call(tool_call)
				round_results.append(tool_result)
				message_history.append({
					"role": "tool",
					"tool_call_id": tool_result["call_id"],
					"content": tool_result["result"]
				})
				_record_recovery_receipt(tool_result)
				if _cancel_requested:
					for remaining_index in range(tool_index + 1, message.tool_calls.size()):
						var remaining_call: Dictionary = message.tool_calls[remaining_index]
						message_history.append({
							"role": "tool",
							"tool_call_id": str(remaining_call.get("id", "")),
							"content": "The tool call was cancelled before execution."
						})
					_finish_cancelled()
					return

			if not _pending_run_observation.is_empty():
				var observed := await _begin_bounded_run_observation()
				if not observed or not _is_running or _cancel_requested:
					return
			if _tool_loop_guard == null:
				_reset_turn_loop_state()
			_record_tool_progress(round_results)
			var loop_result: Dictionary = _tool_loop_guard.record_round(round_results, _tool_progress_epoch)
			if bool(loop_result.get("triggered", false)):
				_begin_loop_finalization(str(loop_result.get("reason", "no_progress")))
			elif _tool_rounds >= MAX_TOOL_ROUNDS:
				_begin_loop_finalization(LOOP_TRIGGER_ROUND_CAP)
			else:
				_send_current_request()
		else:
			if _loop_final_request:
				if not _has_meaningful_content(str(assistant_message.get("content", ""))):
					assistant_message["content"] = _empty_finalization_fallback()
				else:
					assistant_message["content"] = str(assistant_message.get("content", "")).strip_edges() + "\n\n" + _continuation_guidance()
			message_history.append(assistant_message)
			var content = assistant_message.get("content", "")
			if typeof(content) != TYPE_STRING:
				content = str(content)
			_clear_turn_context()
			_reset_turn_recovery_state()
			_set_running(false)
			workflow_state_changed.emit("idle", {})
			message_received.emit("assistant", content)
	else:
		_finish_request_error("Unexpected API response format.")

func _execute_tool_call(tool_call: Dictionary) -> Dictionary:
	var call_id := str(tool_call.get("id", "tool_" + str(Time.get_ticks_usec())))
	var function = tool_call.get("function", {})
	var function_name := str(function.get("name", "")) if typeof(function) == TYPE_DICTIONARY else ""
	var arguments_str := str(function.get("arguments", "{}")) if typeof(function) == TYPE_DICTIONARY else "{}"
	var arguments: Dictionary = {}
	var result := ""
	var outcome := "completed"
	var execution: Dictionary = {}
	var started_at := Time.get_ticks_msec()
	if not _turn_allows_tools():
		result = "Error: Tools are disabled for this local provider. Continue in Chat mode without requesting project actions."
		outcome = "failed"

	var json := JSON.new()
	if result.is_empty():
		if json.parse(arguments_str) != OK:
			result = "Error: Tool arguments were not valid JSON."
			outcome = "failed"
		else:
			var parsed_arguments = json.get_data()
			if typeof(parsed_arguments) != TYPE_DICTIONARY:
				result = "Error: Tool arguments must be a JSON object."
				outcome = "failed"
			else:
				arguments = parsed_arguments

	tool_execution_started.emit(call_id, function_name, arguments)
	if result.is_empty() and function_name in ["run_current_scene", "run_main_scene"]:
		if _run_attempts >= MAX_RUN_ATTEMPTS_PER_TURN:
			result = "Error: Orca reached the limit of %d game runs in this user turn. Start a new turn before running again." % MAX_RUN_ATTEMPTS_PER_TURN
			outcome = "failed"
		elif game_process_service != null and game_process_service.has_method("criteria_id_for"):
			var criteria_result: Dictionary = game_process_service.criteria_id_for(arguments.get("verification", {}))
			if not criteria_result.get("success", false):
				result = "Error: " + str(criteria_result.get("error", "Invalid verification criteria."))
				outcome = "failed"
			else:
				var requested_criteria := str(criteria_result.get("criteria_id", ""))
				if _baseline_criteria_initialized and requested_criteria != _baseline_criteria_id:
					result = "Error: A rerun in this turn must preserve the original verification criteria instead of moving the goalposts."
					outcome = "failed"
	if result.is_empty() and REVIEWED_MUTATION_TOOLS.has(function_name) and _mode != AgentMode.BUILD:
		result = "Error: %s is unavailable in Plan mode. Switch to Work mode to propose changes." % function_name
		outcome = "failed"
	elif result.is_empty() and WORK_OPERATION_TOOLS.has(function_name) and _mode != AgentMode.BUILD:
		result = "Error: %s is unavailable in Plan mode. Switch to Work mode to control an Orca-owned game process." % function_name
		outcome = "failed"
	elif result.is_empty() and REVIEWED_MUTATION_TOOLS.has(function_name):
		var proposal: Dictionary = tools_script.prepare_reviewed_change(function_name, call_id, arguments)
		if not proposal.get("success", false):
			result = "Error: " + str(proposal.get("error", "Could not prepare the reviewed change."))
			var diagnostics: Array = proposal.get("diagnostics", [])
			for diagnostic in diagnostics:
				result += "\n%s:%d: %s" % [diagnostic.get("file", ""), diagnostic.get("line", 0), diagnostic.get("message", "")]
			execution["data"] = {"diagnostics": diagnostics}
			outcome = "failed"
		elif proposal.get("no_changes", false) or (proposal.get("kind", "file_patch") == "file_patch" and proposal.get("diff", {}).get("additions", 0) == 0 and proposal.get("diff", {}).get("deletions", 0) == 0):
			result = "No changes were needed for " + str(proposal.get("filepath", "the target")) + "."
		else:
			_proposals[call_id] = proposal.duplicate(true)
			_pending_change_id = call_id
			edit_proposed.emit(_proposal_for_review(proposal))
			var resolution: Dictionary = await edit_decision_received
			if str(resolution.get("change_id", "")) != call_id:
				result = "Error: The change decision did not match the pending proposal."
				outcome = "failed"
			else:
				result = resolution.get("result", "Error: The edit decision was interrupted.")
				outcome = resolution.get("outcome", "failed")
	elif result.is_empty():
		execution = tools_script.execute_tool(function_name, arguments, game_process_service)
		result = execution.get("content", "Error: Tool execution returned no result.")
		outcome = execution.get("outcome", "failed")
		if function_name in ["run_current_scene", "run_main_scene"] and execution.get("success", false):
			_run_attempts += 1
			var run_data: Dictionary = execution.get("data", {})
			var criteria_id := str(run_data.get("criteria_id", ""))
			if not _baseline_criteria_initialized:
				_baseline_criteria_id = criteria_id
				_baseline_criteria_initialized = true
			_pending_run_observation = {"run_id": int(run_data.get("run_id", 0)), "sequence": int(run_data.get("sequence", 0))}
		elif function_name == "stop_game" and execution.get("success", false):
			_pending_run_observation.clear()
		if function_name == "update_tasks" and execution.get("success", false):
			_tasks.assign(TaskUtils.sanitize_tasks(execution.get("data", {}).get("tasks", [])))
			tasks_changed.emit(_tasks.duplicate(true))

	if execution.is_empty():
		execution = {"success": outcome in ["completed", "applied", "applied_recovery"], "content": result, "outcome": outcome, "data": {}}
	else:
		execution["success"] = outcome in ["completed", "applied", "applied_recovery"]
		execution["content"] = result
		execution["outcome"] = outcome
	tool_execution_completed.emit(call_id, function_name, execution, Time.get_ticks_msec() - started_at)
	return {"call_id": call_id, "name": function_name, "arguments": arguments, "result": result, "outcome": outcome, "execution": execution}


func _begin_bounded_run_observation() -> bool:
	if _pending_run_observation.is_empty() or game_process_service == null or not game_process_service.has_method("observe_run"):
		if not _pending_run_observation.is_empty():
			_append_runtime_context({"run_id": int(_pending_run_observation.get("run_id", 0)), "state": "observation_failed", "message": "The game process service could not provide a bounded observation."}, true)
		_pending_run_observation.clear()
		return true
	_observation_generation += 1
	var generation := _observation_generation
	var run_id := int(_pending_run_observation.get("run_id", 0))
	var initial_sequence := int(_pending_run_observation.get("sequence", 0))
	var started_at := Time.get_ticks_msec()
	workflow_state_changed.emit("observing", {"run_id": run_id})
	var observation: Dictionary = {}
	while _is_running and not _cancel_requested and generation == _observation_generation:
		observation = game_process_service.observe_run(run_id, initial_sequence)
		if not observation.get("success", false):
			break
		var snapshot: Dictionary = observation.get("snapshot", {})
		var waited := Time.get_ticks_msec() - started_at
		var terminal := str(snapshot.get("state", "")) not in ["running", "timeout_stop_failed", "shutdown_stop_failed"]
		var meaningful_change := bool(observation.get("changed_since", false))
		var verification_ready := str(snapshot.get("verification_status", "unverified")) in ["passed", "failed", "inconclusive", "unverified"]
		if terminal or (waited >= OBSERVATION_SETTLE_MS and (meaningful_change or verification_ready)) or waited >= OBSERVATION_MAX_WAIT_MS:
			break
		await get_tree().process_frame
	if not _is_running or _cancel_requested or generation != _observation_generation:
		return false
	_pending_run_observation.clear()
	if observation.get("success", false):
		_append_runtime_context(observation.get("snapshot", {}), bool(observation.get("changed_since", true)))
	else:
		_append_runtime_context({"run_id": run_id, "state": "observation_failed", "message": str(observation.get("error", "The bounded game observation failed."))}, true)
	workflow_state_changed.emit("assessment_ready", {"run_id": run_id})
	return _is_running and not _cancel_requested and generation == _observation_generation


func _append_runtime_context(snapshot: Dictionary, changed_since: bool) -> void:
	if _runtime_context_message_index >= 0 and _runtime_context_message_index < message_history.size():
		message_history.remove_at(_runtime_context_message_index)
	_runtime_context_message_index = message_history.size()
	var bounded := snapshot.duplicate(true)
	bounded.erase("verification")
	message_history.append({"role": "system", "content": "ORCA GAME RUN OBSERVATION FOR THIS TURN:\n" + JSON.stringify({"changed_since_launch": changed_since, "snapshot": bounded}, "  ") + "\nThis is bounded process evidence, not proof of gameplay correctness. Use verify_game_run only for criteria declared before launch. Do not repeatedly poll an unchanged run."})


func _proposal_for_review(proposal: Dictionary) -> Dictionary:
	var review_copy := proposal.duplicate(true)
	for field in ["old_values", "new_values", "old_value", "new_value", "old_hash", "new_hash", "changes", "edits", "operations", "script_content", "trust_binding", "candidate_binding"]:
		review_copy.erase(field)
	if proposal.get("kind", "file_patch") != "file_patch":
		review_copy.erase("old_content")
		review_copy.erase("new_content")
	return review_copy

func _reset_turn_loop_state() -> void:
	_tool_loop_guard = ToolLoopGuardScript.new()
	_tool_progress_epoch = 0
	_tool_progress_fingerprints.clear()
	_loop_final_request = false
	_loop_final_trigger_reason = ""
	_loop_notice_message_index = -1


func _clear_turn_loop_state() -> void:
	_tool_loop_guard = null
	_tool_progress_epoch = 0
	_tool_progress_fingerprints.clear()
	_loop_final_request = false
	_loop_final_trigger_reason = ""
	_loop_notice_message_index = -1


func _reset_turn_recovery_state() -> void:
	_turn_tool_receipts.clear()
	_last_failure_checkpointed = false


func last_failure_was_checkpointed() -> bool:
	return _last_failure_checkpointed


func _record_recovery_receipt(tool_result: Dictionary) -> void:
	if _turn_tool_receipts.size() >= MAX_RECOVERY_RECEIPTS:
		return
	_turn_tool_receipts.append({
		"name": str(tool_result.get("name", "unknown")).left(80),
		"outcome": str(tool_result.get("outcome", "completed")).left(32),
	})


func _checkpoint_failed_tool_turn() -> bool:
	if _turn_tool_receipts.is_empty() or not _pending_change_id.is_empty():
		return false
	var user_index := -1
	for index in range(message_history.size() - 1, 0, -1):
		if typeof(message_history[index]) == TYPE_DICTIONARY and str(message_history[index].get("role", "")) == "user":
			user_index = index
			break
	if user_index < 0 or not _active_tool_protocol_is_complete(user_index + 1):
		return false
	for index in range(message_history.size() - 1, user_index, -1):
		message_history.remove_at(index)
	message_history.append({"role": "assistant", "content": _format_recovery_checkpoint()})
	return true


func _active_tool_protocol_is_complete(start: int) -> bool:
	if start < 0 or start >= message_history.size():
		return false
	var cursor := start
	var batch_count := 0
	var all_call_ids: Dictionary = {}
	while cursor < message_history.size():
		var assistant = message_history[cursor]
		if typeof(assistant) != TYPE_DICTIONARY or str(assistant.get("role", "")) != "assistant":
			return false
		var calls = assistant.get("tool_calls", [])
		if typeof(calls) != TYPE_ARRAY or calls.is_empty():
			return false
		var expected_ids: Dictionary = {}
		for call_value in calls:
			if typeof(call_value) != TYPE_DICTIONARY:
				return false
			var call: Dictionary = call_value
			var call_id := str(call.get("id", "")).strip_edges()
			var function = call.get("function", {})
			if call_id.is_empty() or expected_ids.has(call_id) or all_call_ids.has(call_id) or typeof(function) != TYPE_DICTIONARY or str(function.get("name", "")).strip_edges().is_empty():
				return false
			expected_ids[call_id] = true
			all_call_ids[call_id] = true
		cursor += 1
		var seen_results: Dictionary = {}
		for _result_index in range(calls.size()):
			if cursor >= message_history.size():
				return false
			var tool_message = message_history[cursor]
			if typeof(tool_message) != TYPE_DICTIONARY or str(tool_message.get("role", "")) != "tool":
				return false
			var result_id := str(tool_message.get("tool_call_id", "")).strip_edges()
			if not expected_ids.has(result_id) or seen_results.has(result_id) or typeof(tool_message.get("content")) != TYPE_STRING:
				return false
			seen_results[result_id] = true
			cursor += 1
		if seen_results.size() != expected_ids.size():
			return false
		batch_count += 1
	return batch_count > 0


func _format_recovery_checkpoint() -> String:
	var lines := PackedStringArray([
		RECOVERY_CHECKPOINT_HEADING + ":",
		"The provider response was interrupted after these tool actions completed. This is local historical state; do not replay these actions automatically.",
	])
	for receipt in _turn_tool_receipts:
		lines.append("- %s: %s" % [str(receipt.get("name", "unknown")), str(receipt.get("outcome", "completed"))])
	lines.append(_continuation_guidance() + " Obtain normal approval before any new mutation or external operation.")
	return "\n".join(lines)


func _record_tool_progress(round_results: Array) -> void:
	for result_value in round_results:
		var result: Dictionary = result_value if result_value is Dictionary else {}
		var fingerprint := ToolLoopGuardScript.fingerprint({
			"arguments": result.get("arguments", {}),
			"name": result.get("name", ""),
			"outcome": result.get("outcome", ""),
			"result": result.get("result", ""),
		})
		if not _tool_progress_fingerprints.has(fingerprint):
			_tool_progress_fingerprints[fingerprint] = true
			_tool_progress_epoch += 1


func _begin_loop_finalization(trigger_reason: String) -> void:
	if _loop_final_request:
		return
	_loop_final_request = true
	_loop_final_trigger_reason = trigger_reason.left(64)
	_loop_notice_message_index = message_history.size()
	message_history.append({"role": "system", "content": LOOP_FINAL_NOTICE})
	_send_current_request()


func _finish_denied_loop_calls(assistant_message: Dictionary, tool_calls: Array) -> void:
	assistant_message["tool_calls"] = tool_calls
	message_history.append(assistant_message)
	for tool_call_value in tool_calls:
		var tool_call: Dictionary = tool_call_value if tool_call_value is Dictionary else {}
		message_history.append({
			"role": "tool",
			"tool_call_id": str(tool_call.get("id", "")),
			"content": "The tool call was denied because the provider attempted another tool after Orca disabled tools for safe finalization. No action was executed."
		})
	var final_content := "The provider attempted another tool after Orca disabled tools for safe finalization (%s). No additional action was executed. Completed actions were kept." % _loop_trigger_description()
	var provider_text := _bounded_visible_provider_text(str(assistant_message.get("content", "")))
	if not provider_text.is_empty():
		final_content += "\n\nProvider text before the denied tool call:\n" + provider_text
	final_content += "\n\n" + _continuation_guidance()
	message_history.append({"role": "assistant", "content": final_content})
	_clear_turn_context()
	_reset_turn_recovery_state()
	_set_running(false)
	workflow_state_changed.emit("idle", {})
	message_received.emit("assistant", final_content)


func _empty_finalization_fallback() -> String:
	return "Orca finalized safely (%s), but the provider returned no summary. Completed actions were kept. %s" % [_loop_trigger_description(), _continuation_guidance()]


func _continuation_guidance() -> String:
	return "A new request is needed for unfinished work. `continue` is not special: describe the unfinished work so Orca can re-inspect the current state. Completed actions will not be replayed automatically."


func _loop_trigger_description() -> String:
	match _loop_final_trigger_reason:
		ToolLoopGuardScript.REASON_IDENTICAL_CALL_RESULT:
			return "repetitive tool calls"
		ToolLoopGuardScript.REASON_ALTERNATING_CALL_CYCLE:
			return "repeating tool-call cycle"
		ToolLoopGuardScript.REASON_IDENTICAL_ROUND:
			return "repetitive tool rounds"
		ToolLoopGuardScript.REASON_NO_PROGRESS:
			return "no tool progress"
		LOOP_TRIGGER_ROUND_CAP:
			return "%d-round tool limit" % MAX_TOOL_ROUNDS
	return "tool-loop safety trigger"


func _has_meaningful_content(content: String) -> bool:
	return not content.strip_edges().is_empty()


func _bounded_visible_provider_text(content: String) -> String:
	return content.strip_edges().left(MAX_FINAL_PROVIDER_TEXT_CHARS)


func _on_api_request_failed(error: Dictionary) -> void:
	var error_message := str(error.get("message", "The API request failed."))
	var phase := str(error.get("phase", ""))
	var category := str(error.get("category", "unknown"))
	print("Orca API request failed [", category, "/", phase, "]: ", error_message)
	if api_client.last_request_may_have_usage():
		_latest_context_tokens = 0
		_usage_complete = false
		_cost_complete = false
		_emit_session_usage(_last_usage_model)
	if _loop_final_request and category == "malformed_response" and error_message.contains("without visible assistant content or a valid tool call"):
		var final_content := _empty_finalization_fallback()
		_current_stream_content = ""
		message_history.append({"role": "assistant", "content": final_content})
		_clear_turn_context()
		_reset_turn_recovery_state()
		_set_running(false)
		workflow_state_changed.emit("idle", {})
		message_received.emit("assistant", final_content)
		return
	var user_message := error_message
	if bool(error.get("partial_response", false)):
		user_message += "\n\nThe incomplete provider response was not added to the model's conversation history."
	if bool(error.get("retryable", false)):
		user_message += "\n\nThis failure may be temporary; you can retry after checking the provider connection."
	_current_stream_content = ""
	_finish_request_error(user_message)

func _on_api_request_cancelled() -> void:
	if api_client.last_request_may_have_usage():
		_latest_context_tokens = 0
		_usage_complete = false
		_cost_complete = false
		_emit_session_usage()
	if not _current_stream_content.is_empty():
		message_history.append({
			"role": "assistant",
			"content": _current_stream_content
		})
	_current_stream_content = ""
	_finish_cancelled()

func _on_stream_started() -> void:
	_current_stream_content = ""
	message_stream_started.emit()

func _on_stream_delta(content: String) -> void:
	_current_stream_content += content
	message_stream_delta.emit(content)

func _set_running(value: bool) -> void:
	if _is_running == value:
		return
	_is_running = value
	if not value:
		_turn_provider_config.clear()
	request_state_changed.emit(value)


func _send_current_request() -> bool:
	var definitions := [] if _loop_final_request else _get_tool_definitions()
	var model := str(_turn_provider_config.get("model", ""))
	var api_url := str(_turn_provider_config.get("base_url", ""))
	var effective_model := _last_usage_model if _tool_rounds > 0 and not _last_usage_model.is_empty() else model
	var metadata := ModelMetadata.resolve(effective_model, api_url, model)
	var prepared := ContextBudget.prepare(message_history, definitions, int(metadata.get("context_window", 0)))
	if not prepared.get("success", false):
		_finish_request_error("Orca could not send the request safely: " + str(prepared.get("error", "The context budget was exceeded.")))
		return false
	if prepared.get("compacted", false):
		_remap_context_indices(int(prepared.get("removed_start", -1)), int(prepared.get("removed_count", 0)), int(prepared.get("inserted_count", 0)))
		message_history = prepared.get("messages", []).duplicate(true)
	if _loop_final_request:
		workflow_state_changed.emit("finalizing", {"trigger_reason": _loop_final_trigger_reason})
	else:
		workflow_state_changed.emit("thinking", {"follow_up": _tool_rounds > 0})
	api_client.send_chat_completion(message_history, definitions, _turn_provider_config, {"allow_stream_options_retry": _tool_rounds == 0})
	return true


func _remap_context_indices(removed_start: int, removed_count: int, inserted_count: int) -> void:
	if removed_start < 0 or removed_count <= 0:
		return
	var removed_end := removed_start + removed_count
	for field in ["_context_message_index", "_runtime_context_message_index", "_loop_notice_message_index"]:
		var index: int = get(field)
		if index >= removed_end:
			set(field, index - removed_count + inserted_count)
		elif index >= removed_start:
			set(field, -1)

func _get_tool_definitions() -> Array:
	if not _turn_allows_tools():
		return []
	return tools_script.get_tool_definitions(_mode == AgentMode.BUILD)


func _turn_allows_tools() -> bool:
	if _turn_provider_config.is_empty():
		return true
	var provider = ProviderRegistry.get_provider(str(_turn_provider_config.get("provider", "custom")))
	var definition: Dictionary = provider.definition()
	if not bool(definition.get("agent_tools", true)):
		return bool(Config.agent_compatibility_status(str(_turn_provider_config.get("provider", "custom")), _turn_provider_config).get("enabled", false))
	var configured := EndpointPolicy.inspect_base_url(str(_turn_provider_config.get("base_url", "")))
	var canonical := EndpointPolicy.inspect_base_url(str(definition.get("base_url", "")))
	if not configured.get("success", false) or not canonical.get("success", false):
		return false
	if bool(definition.get("custom_url", false)) or str(configured.get("origin", "")) != str(canonical.get("origin", "")):
		return bool(Config.agent_compatibility_status(str(_turn_provider_config.get("provider", "custom")), _turn_provider_config).get("enabled", false))
	return true

func _get_system_prompt() -> String:
	var shared := "You are Orca, an AI game-development assistant integrated into the Godot editor. Use project tools proactively to understand the user's Godot project. Prefer inspect_scene over raw file reads when understanding saved .tscn structure; it reports saved serialized state, does not include unsaved or runtime-generated nodes, and does not recursively expand scene instances. Prefer inspect_project_settings over reading project.godot when understanding project configuration; omit setting_path for the bounded overview or provide one exact non-sensitive path. Be concise, explain important decisions, and never claim a tool action succeeded unless its result confirms success. For genuinely multi-step work, maintain the session checklist with update_tasks; provide the complete desired list, keep at most one item in_progress, and do not use it for trivial one-step requests."
	if _mode == AgentMode.PLAN:
		return shared + " You are in Plan mode. Explore and analyze the project using read-only tools, identify relevant files, ask focused questions when needed, and produce a concrete implementation plan. You may update Orca's session checklist, but you must not create, edit, delete, apply changes, or start/stop game processes. If the user asks you to implement something, finish the plan and tell them to switch to Work mode."
	return shared + " You are in Work mode. You may search and read project files, inspect current editor context and diagnostics, propose reviewed changes, and run or stop only Orca-owned game processes. Read relevant line ranges first and use the SHA-256 returned by read_file as base_hash. Use propose_scene_changes for structured scene creation, nodes, typed properties, dependency-free scripts and child instances, and bindless signals instead of writing .tscn text. Script attach/detach requires a script_hash from read_file and two user decisions: trust to execute the exact script while constructing a candidate, then approval to apply it. Use propose_input_map_changes for typed Input Map changes, propose_main_scene_change to configure the launch scene, propose_project_settings_changes for allowlisted display settings, and apply_patch for minimal non-overlapping source edits. Use run_current_scene or run_main_scene only when execution advances the task. Declare clean_startup or expected_exit verification before launch when those narrow criteria match the task, preserve the same criteria across reruns, and use observe_game_run or get_diagnostics for later evidence. Orca automatically waits briefly for one bounded observation after launch. Only claim verified when verify_game_run returns passed; launch, a zero exit code, or absence of retained errors does not establish gameplay correctness. Visual behavior, input feel, animation, and rendering remain unverified without visual evidence. Use stop_game only for the current Orca-owned run. Every project file change requires explicit user approval before it is applied."

func _get_mode_transition_prompt() -> String:
	if _mode == AgentMode.PLAN:
		return "MODE CHANGED: Orca is now in Plan mode. From this point forward, use only read-only project tools and update_tasks; do not propose or apply file changes or start/stop game processes."
	return "MODE CHANGED: Orca is now in Work mode. This supersedes any earlier statement that Orca is in Plan mode. Continue the user's task now, use reviewed mutation tools when implementation is requested, and run only Orca-owned game processes when execution advances the task; every project file change still requires user approval."

func _finish_cancelled() -> void:
	_pending_change_id = ""
	_pending_run_observation.clear()
	_current_stream_content = ""
	_clear_turn_context()
	_reset_turn_recovery_state()
	_set_running(false)
	workflow_state_changed.emit("cancelled", {})
	request_cancelled.emit()


func _finish_request_error(message: String) -> void:
	_clear_turn_context()
	_last_failure_checkpointed = _checkpoint_failed_tool_turn()
	var rendered := message
	if _last_failure_checkpointed:
		rendered += "\n\nCompleted tool actions were saved in a sanitized recovery checkpoint. " + _continuation_guidance()
	elif _tool_rounds > 0:
		rendered += "\n\nCompleted tool actions were kept, but Orca could not prove that the interrupted turn is safe to resume. Start a new conversation to avoid repeating side effects."
	_set_running(false)
	workflow_state_changed.emit("idle", {})
	error_occurred.emit(rendered)

func _clear_turn_context() -> void:
	var indices := [_context_message_index, _runtime_context_message_index, _loop_notice_message_index]
	indices.sort()
	indices.reverse()
	for index in indices:
		if int(index) >= 0 and int(index) < message_history.size():
			message_history.remove_at(int(index))
	_context_message_index = -1
	_runtime_context_message_index = -1
	_pending_run_observation.clear()
	_clear_turn_loop_state()


func _reset_session_usage() -> void:
	_session_input_tokens = 0
	_session_output_tokens = 0
	_session_cached_tokens = 0
	_latest_context_tokens = 0
	_session_cost_usd = 0.0
	_usage_complete = true
	_cost_complete = true
	_completed_requests = 0
	_last_usage_model = ""
	_last_configured_model = ""
	_last_api_url = ""
	_cost_records.clear()
	_all_costs_available = true
	_cost_estimated = false
	_restored_cost_usd = 0.0
	_restored_cost_available = true
	_restored_cost_estimated = false
	_restored_context_limit = 0
	_emit_session_usage()


func _record_request_usage(response: Dictionary) -> void:
	_restored_context_limit = 0
	_completed_requests += 1
	var usage := _normalize_usage(response.get("usage", {}))
	var model := str(response.get("model", Config.get_model()))
	var configured_model := str(response.get("requested_model", Config.get_model()))
	var api_url := str(response.get("requested_api_url", Config.get_api_url()))
	_last_usage_model = model
	_last_configured_model = configured_model
	_last_api_url = api_url
	if model.strip_edges().to_lower() != configured_model.strip_edges().to_lower():
		model_metadata_requested.emit(model, api_url)
	if usage.is_empty():
		_latest_context_tokens = 0
		_usage_complete = false
		_cost_complete = false
		_emit_session_usage(model)
		return
	_session_input_tokens += int(usage["input_tokens"])
	_session_output_tokens += int(usage["output_tokens"])
	_session_cached_tokens += int(usage["cached_tokens"])
	_latest_context_tokens = int(usage["total_tokens"])
	_cost_records.append({
		"usage": usage,
		"model": model,
		"configured_model": configured_model,
		"api_url": api_url,
		"reported_cost": float(usage.get("cost", -1.0))
	})
	_recalculate_session_cost()
	_emit_session_usage(model)


func _normalize_usage(raw_usage) -> Dictionary:
	if typeof(raw_usage) != TYPE_DICTIONARY:
		return {}
	var input_value = raw_usage.get("input_tokens", raw_usage.get("prompt_tokens", null))
	var output_value = raw_usage.get("output_tokens", raw_usage.get("completion_tokens", null))
	if typeof(input_value) not in [TYPE_INT, TYPE_FLOAT] or typeof(output_value) not in [TYPE_INT, TYPE_FLOAT]:
		return {}
	var input_tokens := int(input_value)
	var output_tokens := int(output_value)
	if input_tokens < 0 or output_tokens < 0:
		return {}
	var details = raw_usage.get("prompt_tokens_details", {})
	var cached_value = raw_usage.get("cached_tokens", 0)
	var cached_tokens := int(cached_value) if typeof(cached_value) in [TYPE_INT, TYPE_FLOAT] else 0
	if typeof(details) == TYPE_DICTIONARY:
		var detailed_cached = details.get("cached_tokens", cached_tokens)
		if typeof(detailed_cached) in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = int(detailed_cached)
		var detailed_cache_write = details.get("cache_write_tokens", null)
		if typeof(detailed_cache_write) in [TYPE_INT, TYPE_FLOAT]:
			raw_usage["cache_write_tokens"] = int(detailed_cache_write)
	var cache_hit_value = raw_usage.get("prompt_cache_hit_tokens", null)
	if typeof(cache_hit_value) in [TYPE_INT, TYPE_FLOAT]:
		cached_tokens = int(cache_hit_value)
	var cache_read_value = raw_usage.get("cache_read_input_tokens", null)
	var cache_write_value = raw_usage.get("cache_creation_input_tokens", raw_usage.get("cache_write_tokens", 0))
	var cache_write_tokens := int(cache_write_value) if typeof(cache_write_value) in [TYPE_INT, TYPE_FLOAT] else 0
	var regular_value = raw_usage.get("regular_input_tokens", null)
	var regular_input_tokens := int(regular_value) if typeof(regular_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens - cached_tokens - cache_write_tokens
	var has_separate_cache_counters: bool = typeof(cache_read_value) in [TYPE_INT, TYPE_FLOAT] or raw_usage.has("cache_creation_input_tokens")
	if has_separate_cache_counters:
		if typeof(cache_read_value) not in [TYPE_INT, TYPE_FLOAT]:
			cached_tokens = 0
		else:
			cached_tokens = int(cache_read_value)
		regular_input_tokens = int(input_value)
		input_tokens = regular_input_tokens + cached_tokens + cache_write_tokens
	elif typeof(regular_value) in [TYPE_INT, TYPE_FLOAT]:
		regular_input_tokens = int(regular_value)
	else:
		regular_input_tokens = input_tokens - cached_tokens - cache_write_tokens
	var total_value = raw_usage.get("total_tokens", input_tokens + output_tokens)
	var total_tokens := maxi(int(total_value), input_tokens + output_tokens) if typeof(total_value) in [TYPE_INT, TYPE_FLOAT] else input_tokens + output_tokens
	var usage := {
		"input_tokens": input_tokens,
		"regular_input_tokens": maxi(0, regular_input_tokens),
		"output_tokens": output_tokens,
		"total_tokens": maxi(0, total_tokens),
		"cached_tokens": clampi(cached_tokens, 0, input_tokens),
		"cache_write_tokens": clampi(cache_write_tokens, 0, input_tokens)
	}
	var reported_cost = raw_usage.get("cost", raw_usage.get("total_cost", null))
	if reported_cost != null and (typeof(reported_cost) == TYPE_FLOAT or typeof(reported_cost) == TYPE_INT) and float(reported_cost) >= 0.0:
		usage["cost"] = float(reported_cost)
	return usage


func _emit_session_usage(model: String = "") -> void:
	var summary := _session_usage_summary(model)
	session_usage_changed.emit(summary)


func _session_usage_summary(model: String = "") -> Dictionary:
	var effective_model := Config.get_model() if model.is_empty() else model
	var configured_model := Config.get_model() if _last_configured_model.is_empty() else _last_configured_model
	var api_url := Config.get_api_url() if _last_api_url.is_empty() else _last_api_url
	var metadata := ModelMetadata.resolve(effective_model, api_url, configured_model)
	var pricing_available := metadata.has("input_per_million") and metadata.has("output_per_million")
	return {
		"model": configured_model,
		"context_tokens": _latest_context_tokens,
		"context_limit": _restored_context_limit if _restored_context_limit > 0 else int(metadata.get("context_window", 0)),
		"input_tokens": _session_input_tokens,
		"output_tokens": _session_output_tokens,
		"cached_tokens": _session_cached_tokens,
		"cost_usd": _session_cost_usd,
		"usage_complete": _usage_complete,
		"cost_available": _cost_complete and (_all_costs_available if _completed_requests > 0 else pricing_available),
		"cost_complete": _cost_complete,
		"cost_estimated": _cost_estimated or (_completed_requests == 0 and pricing_available),
		"completed_requests": _completed_requests
	}


func _recalculate_session_cost() -> void:
	_session_cost_usd = _restored_cost_usd
	_all_costs_available = _restored_cost_available
	_cost_estimated = _restored_cost_estimated
	for request_data in _cost_records:
		var request_cost := float(request_data.get("reported_cost", -1.0))
		if request_cost < 0.0:
			var metadata := ModelMetadata.resolve(
				str(request_data.get("model", "")),
				str(request_data.get("api_url", "")),
				str(request_data.get("configured_model", ""))
			)
			request_cost = ModelMetadata.calculate_cost(request_data.get("usage", {}), metadata)
			_cost_estimated = true
		if request_cost < 0.0:
			_all_costs_available = false
		else:
			_session_cost_usd += request_cost


func _restore_session_usage(usage: Dictionary) -> void:
	_session_input_tokens = maxi(0, int(usage.get("input_tokens", 0)))
	_session_output_tokens = maxi(0, int(usage.get("output_tokens", 0)))
	_session_cached_tokens = maxi(0, int(usage.get("cached_tokens", 0)))
	_latest_context_tokens = maxi(0, int(usage.get("context_tokens", 0)))
	_session_cost_usd = maxf(0.0, float(usage.get("cost_usd", 0.0)))
	_usage_complete = bool(usage.get("usage_complete", true))
	_cost_complete = bool(usage.get("cost_complete", true))
	_completed_requests = maxi(0, int(usage.get("completed_requests", 0)))
	_last_usage_model = str(usage.get("model", ""))
	_last_configured_model = _last_usage_model
	_last_api_url = ""
	_cost_records.clear()
	_restored_cost_usd = _session_cost_usd
	_restored_cost_available = bool(usage.get("cost_available", false))
	_restored_cost_estimated = bool(usage.get("cost_estimated", false))
	_restored_context_limit = maxi(0, int(usage.get("context_limit", 0)))
	_all_costs_available = _restored_cost_available
	_cost_estimated = _restored_cost_estimated
	_emit_session_usage(_last_usage_model)


func _valid_continuation(continuation: Array) -> bool:
	if continuation.size() > 120:
		return false
	for message in continuation:
		if typeof(message) != TYPE_DICTIONARY:
			return false
		if str(message.get("role", "")) not in ["user", "assistant"] or typeof(message.get("content")) != TYPE_STRING:
			return false
	return true
