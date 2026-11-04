extends SceneTree

const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const Journal = preload("res://addons/orca/scripts/script_change_journal.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const OLD := "extends RefCounted\nconst VALUE = 1\n"
const NEW := "extends RefCounted\nconst VALUE = 2\n"
const THIRD := "extends RefCounted\nconst VALUE = 3\n"

class Client extends Node:
	signal request_completed(id: int, response: Dictionary)
	signal request_failed(id: int, error: Dictionary)
	signal request_cancelled(id: int)
	signal stream_started(id: int)
	signal stream_delta(id: int, content: String)
	var requests: Array = []
	var requesting := false
	func send_chat_completion(messages: Array, tools: Array, profile: Dictionary, options: Dictionary) -> void:
		requests.append({"messages": messages.duplicate(true), "tools": tools.duplicate(true), "profile": profile.duplicate(true), "options": options.duplicate(true)})
		requesting = true
	func is_requesting() -> bool: return requesting
	func last_request_may_have_usage() -> bool: return false
	func cancel_request() -> void:
		requesting = false
		request_cancelled.emit(int(requests.back()["options"]["lifecycle_request_id"]))
	func complete(message: Dictionary) -> void:
		requesting = false
		request_completed.emit(int(requests.back()["options"]["lifecycle_request_id"]), {"choices": [{"message": message, "finish_reason": "tool_calls" if message.has("tool_calls") else "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})

class FixtureController extends Controller:
	func _capture_provider_config() -> Dictionary:
		return {"provider": "openai", "model": "gpt-4o-mini", "api_key": "synthetic", "base_url": "https://api.openai.com/v1"}

class StopAfterWrite extends RefCounted:
	var controller
	func get_tool_definitions(edit: bool, switch: bool) -> Array: return Tools.get_tool_definitions(edit, switch)
	func prepare_reviewed_change(name: String, id: String, arguments: Dictionary) -> Dictionary: return Tools.prepare_reviewed_change(name, id, arguments)
	func apply_reviewed_change(proposal: Dictionary) -> String:
		var result := Tools.apply_reviewed_change(proposal)
		controller.cancel_current_request()
		return result

var failures := PackedStringArray()
var path := ""
var storage := ""
var store
var session := {}
var controller
var client
var write_behavior := ""
var prepared_checks := 0

func _init() -> void: call_deferred("_run")

func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if not arguments.is_empty() and arguments[0] == "recover_checkpoint":
		_recover_in_new_process(arguments)
		return
	path = "res://tests/auto_apply_fixture_%d.gd" % Time.get_ticks_usec()
	storage = "user://orca_auto_apply_test_%d" % Time.get_ticks_usec()
	store = Store.new(storage)
	await _default_and_plan()
	await _continuous_edits_and_recovery()
	await _permission_changes()
	await _failure_and_cancellation()
	await _boundaries()
	await _interrupted_checkpoint()
	_test_record_validation()
	_test_process_recovery()
	if controller != null:
		controller.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".uid"))
	store.delete_all_sessions()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage + "/index.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(storage))
	for failure in failures: push_error(failure)
	print("auto_apply_test: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)

func check(value: bool, message: String) -> void:
	if not value: failures.append(message)

func _put(content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _read() -> String:
	return FileAccess.get_file_as_string(path)

func _reset(automatic: bool = false) -> void:
	if controller != null:
		if controller.is_busy(): controller.cancel_current_request()
		controller.queue_free()
		await process_frame
	controller = FixtureController.new()
	root.add_child(controller)
	client = Client.new()
	controller.set_api_client_for_testing(client)
	controller.script_change_writer = _write_checkpoint
	session = store.create_session(1, "openai", "fixture")
	write_behavior = ""
	_put(OLD)
	if automatic: check(controller.set_auto_apply_enabled(true), "idle Work can grant session automatic edits")

func _write_checkpoint(record: Dictionary) -> bool:
	if write_behavior == "fail_before" or (write_behavior == "fail_after" and record["status"] != "prepared"):
		return false
	var records: Array = session.get("script_changes", []).duplicate(true)
	var replaced := false
	for index in records.size():
		if records[index]["id"] == record["id"]:
			records[index] = record
			replaced = true
			break
	if not replaced: records.append(record)
	var candidate := session.duplicate(true)
	candidate["script_changes"] = records
	candidate["clean"] = not controller.is_busy()
	var result: Dictionary = store.save_session(candidate)
	if not result.get("success", false): return false
	session = result["session"]
	if record["status"] == "prepared":
		var loaded: Dictionary = Store.new(storage).load_session(session["id"])
		check(loaded["script_changes"].back()["old_content"] == record["old_content"] and not loaded["clean"], "exact pre-write source and dirty turn must already be durable")
		check(_read() == record["old_content"] or not record["existed"], "checkpoint must precede file replacement")
		prepared_checks += 1
		if write_behavior == "revoke": controller.set_auto_apply_enabled(false)
		if write_behavior == "cancel": controller.cancel_current_request()
		if write_behavior == "independent": _put("extends RefCounted\nconst INDEPENDENT = true\n")
	return true

func _patch(old: String = OLD, replacement: String = "const VALUE = 2", id: String = "patch", target: String = "") -> Dictionary:
	return {"id": id, "type": "function", "function": {"name": "apply_patch", "arguments": JSON.stringify({"filepath": path if target.is_empty() else target, "base_hash": old.sha256_text(), "edits": [{"start_line": 2, "end_line": 2, "replacement": replacement}]})}}

func _tool(call: Dictionary) -> void:
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})

func _finish() -> void:
	client.complete({"role": "assistant", "content": "Done."})

func _results(id: String) -> Array:
	return controller.message_history.filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == id)

func _default_and_plan() -> void:
	await _reset()
	check(not controller.auto_apply_enabled(), "Review edits is the default")
	controller.send_user_message("Edit the script")
	_tool(_patch())
	check(_read() == OLD and client.requests.size() == 1 and controller._pending_change_id == "patch", "default mode waits before writing")
	controller.resolve_edit("patch", controller._active_turn_id, false)
	check(_read() == OLD and _results("patch").size() == 1, "rejection yields one matching result without writing")
	_finish()
	check(controller.set_mode(0), "idle Plan selection works")
	check(not controller.set_auto_apply_enabled(true), "Plan cannot grant automatic editing")
	controller.send_user_message("Plan only")
	_tool(_patch(OLD, "const VALUE = 2", "plan_patch"))
	check(_read() == OLD and _results("plan_patch").size() == 1 and not controller._pending_change_id.length(), "direct Plan mutation remains denied")
	_finish()
	controller.set_mode(1)
	controller.script_change_writer = Callable()
	check(not controller.set_auto_apply_enabled(true), "automatic editing requires an available checkpoint writer")

func _continuous_edits_and_recovery() -> void:
	await _reset(true)
	controller.send_user_message("Make two edits")
	check(client.requests[0]["messages"][0]["content"].contains("user enabled Auto apply"), "request prompt describes actual session authorization")
	_tool(_patch())
	check(_read() == NEW and client.requests.size() == 2 and controller._pending_change_id.is_empty(), "automatic edit applies and continues without a click")
	_tool(_patch(NEW, "const VALUE = 3", "second"))
	check(_read() == THIRD and session["script_changes"].size() == 2 and _results("second").size() == 1, "successive edits retain separate durable checkpoints and valid results")
	_finish()
	check(controller.auto_apply_enabled(), "session grant survives a completed user turn")
	var loaded: Dictionary = Store.new(storage).load_session(session["id"])
	check(controller.start_new_session() and not controller.auto_apply_enabled(), "New Session revokes the grant")
	check(controller.restore_session_state(1, [], {}) and controller.restore_script_changes(loaded["script_changes"]), "durable checkpoints restore independently of model history")
	check(not controller.auto_apply_enabled() and _read() == THIRD and controller.message_history.size() == 1, "restoration grants no permissions and replays no edits")
	var first: String = loaded["script_changes"][0]["id"]
	var second: String = loaded["script_changes"][1]["id"]
	controller.revert_edit(first)
	check(_read() == THIRD, "reverting an older checkpoint protects a newer edit")
	controller.revert_edit(second)
	check(_read() == NEW, "latest checkpoint can revert after a controller restart")
	controller.revert_edit(first)
	check(_read() == OLD, "earlier checkpoint can revert after the newer edit is reverted")
	check(session["script_changes"][0]["status"] == "reverted" and session["script_changes"][1]["status"] == "reverted", "revert results persist")

func _permission_changes() -> void:
	await _reset(true)
	controller.send_user_message("Work")
	check(not controller.set_auto_apply_enabled(true), "an active turn cannot acquire a fresh grant")
	controller.set_auto_apply_enabled(false)
	_tool(_patch())
	check(_read() == OLD and controller._pending_change_id == "patch", "revocation during transport returns the next edit to review")
	controller.resolve_edit("patch", controller._active_turn_id, false)
	check(client.requests.back()["messages"][0]["content"].contains("Review edits is active"), "follow-up prompt refreshes revoked permission")
	_finish()
	await _reset(true)
	controller.edit_proposed.connect(func(_turn: int, proposal: Dictionary):
		if proposal.get("_auto_apply", false): controller.set_auto_apply_enabled(false))
	controller.send_user_message("Work")
	_tool(_patch())
	check(_read() == OLD and controller._pending_change_id == "patch", "revocation from proposal UI callback cannot write")
	controller.resolve_edit("patch", controller._active_turn_id, false)
	_finish()
	await _reset(true)
	write_behavior = "revoke"
	controller.send_user_message("Work")
	_tool(_patch())
	check(_read() == OLD and _results("patch").size() == 1 and client.requests.size() == 2, "revocation from pre-write persistence blocks replacement with one result")
	_finish()

func _failure_and_cancellation() -> void:
	for behavior in ["fail_before", "fail_after", "cancel", "independent"]:
		await _reset(true)
		write_behavior = behavior
		controller.send_user_message("Work")
		_tool(_patch())
		check(_results("patch").size() == 1, "%s retains exactly one protocol result" % behavior)
		if behavior == "fail_after":
			check(_read() == NEW and session["script_changes"][0]["status"] == "prepared" and not controller.auto_apply_enabled(), "failed post-write status preserves the pre-write checkpoint and pauses auto apply")
		elif behavior == "independent":
			check(_read().contains("INDEPENDENT"), "stale pre-write content never replaces independent edits")
		else:
			check(_read() == OLD, "%s causes no replacement" % behavior)
		if behavior == "cancel":
			check(not controller.is_busy() and client.requests.size() == 1, "pre-write cancellation sends no continuation")
		else:
			_finish()
	await _reset(true)
	var stop_tools := StopAfterWrite.new()
	stop_tools.controller = controller
	controller.tools_script = stop_tools
	controller.send_user_message("Work")
	_tool(_patch())
	check(_read() == NEW and not controller.is_busy() and client.requests.size() == 1, "Stop immediately after replacement preserves completed work without follow-up")
	check(_results("patch").size() == 1 and session["script_changes"][0]["status"] == "applied", "Stop during commit retains the true applied result and durable recovery")

func _boundaries() -> void:
	await _reset(true)
	controller.send_user_message("Work")
	_tool(_patch(OLD, "func broken("))
	check(_read() == OLD and not session.has("script_changes"), "invalid GDScript never checkpoints or writes")
	_finish()
	await _reset(true)
	controller.send_user_message("Work")
	_tool(_patch(OLD, "const VALUE = 2", "protected", "res://addons/orca/scripts/tools.gd"))
	check(not session.has("script_changes") and controller._pending_change_id.is_empty(), "protected addon mutations cannot acquire auto permission")
	_finish()
	await _reset(true)
	controller.send_user_message("Work")
	var call := {"id": "settings", "type": "function", "function": {"name": "propose_input_map_changes", "arguments": "{}"}}
	check(controller._edit_permission({"kind": "input_map", "tool_name": "propose_input_map_changes"}, 1) == "ask", "structured settings retain explicit approval")
	check(controller._edit_permission({"kind": "scene", "tool_name": "propose_scene_changes", "approval_stage": "script_trust"}, 1) == "ask", "script execution trust is not an editing grant")
	client.complete({"role": "assistant", "content": "", "tool_calls": [_patch(), call]})
	check(_read() == OLD and not session.has("script_changes") and client.requests.size() == 2, "mixed mutation batches remain atomically rejected even with auto permission")
	_finish()
	var proposal := Tools.prepare_file_patch("size", path, OLD.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}])
	var large := proposal.duplicate(true)
	large["new_content"] = "x".repeat(Journal.MAX_SOURCE_BYTES + 1)
	check(not Journal.eligible(large), "large source falls back to explicit review")
	var addon := proposal.duplicate(true)
	addon["filepath"] = "res://addons/other/script.gd"
	check(not Journal.eligible(addon), "other addons remain outside the automatic editing scope")
	var auth_checks := [0]
	proposal["_auto_apply"] = true
	proposal["_write_authorization"] = func() -> bool: auth_checks[0] += 1; return auth_checks[0] == 1
	check(Tools.apply_reviewed_change(proposal).begins_with("Error:") and _read() == OLD, "runtime revocation is rechecked immediately before file replacement")

func _interrupted_checkpoint() -> void:
	await _reset()
	var proposal := Tools.prepare_file_patch("interrupted", path, OLD.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}])
	var record := Journal.prepare(proposal)
	check(controller.restore_script_changes([record]), "prepared crash checkpoint can be inspected")
	controller.inspect_script_change(record["id"])
	check(_read() == OLD and controller.recovered_script_change(record["id"])["status"] == "not_applied", "original disk state is disclosed without replay")
	_put(NEW)
	controller.inspect_script_change(record["id"])
	check(_read() == NEW and controller.recovered_script_change(record["id"])["status"] == "applied", "candidate disk state is recognized through read-only recovery")
	controller.set_mode(0)
	controller.revert_edit(record["id"])
	check(_read() == NEW, "restored checkpoints never bypass Plan revert denial")
	controller.set_mode(1)
	controller.revert_edit(record["id"])
	check(_read() == OLD, "an interrupted candidate reverts only after the user action in Work")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var created := Tools.prepare_file_patch("created", path, "", [{"start_line": 1, "end_line": 0, "replacement": NEW}])
	var created_record := Journal.prepare(created)
	created_record["status"] = "applied"
	_put(NEW)
	controller.restore_script_changes([created_record])
	controller.revert_edit(created_record["id"])
	check(not FileAccess.file_exists(path), "reverting a restored new-file checkpoint removes only the exact created file")
	_put(OLD)

func _test_record_validation() -> void:
	var proposal := Tools.prepare_file_patch("validation", path, OLD.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}])
	var record := Journal.prepare(proposal)
	check(Journal.validate_records([record]).is_empty(), "canonical checkpoints validate")
	var raw := session.duplicate(true)
	raw["auto_apply_enabled"] = true
	raw["script_changes"] = [record]
	check(store.save_session(raw).get("success", false), "canonical journal can persist with unrelated input fields stripped")
	var loaded: Dictionary = store.load_session(raw["id"])
	check(not loaded.has("auto_apply_enabled") and not controller.snapshot_session_state().has("script_changes"), "permissions and recovery source stay out of continuation snapshots")
	var forged := record.duplicate(true)
	forged["auto_apply_enabled"] = true
	check(not Journal.validate_records([forged]).is_empty(), "recovery cannot persist permission fields")
	forged = record.duplicate(true)
	forged["old_content"] += "tamper"
	check(not Journal.validate_records([forged]).is_empty(), "hash/content mismatch is rejected")
	forged = record.duplicate(true)
	forged["filepath"] = "res://addons/orca/tool.gd"
	check(not Journal.validate_records([forged]).is_empty(), "protected recovery paths are rejected")
	check(not Journal.validate_records([record, record]).is_empty(), "duplicate checkpoint identities are rejected")
	var too_many: Array = []
	for index in Journal.MAX_RECORDS + 1:
		var extra := record.duplicate(true)
		extra["id"] = "script_change_%032x" % index
		too_many.append(extra)
	check(not Journal.validate_records(too_many).is_empty(), "checkpoint count is bounded")
	var large_records: Array = []
	for index in 9:
		var extra := record.duplicate(true)
		extra["id"] = "script_change_%032x" % index
		extra["old_content"] = "#".repeat(Journal.MAX_SOURCE_BYTES)
		extra["new_content"] = "#".repeat(Journal.MAX_SOURCE_BYTES - 1) + "x"
		extra["old_hash"] = extra["old_content"].sha256_text()
		extra["new_hash"] = extra["new_content"].sha256_text()
		large_records.append(extra)
	check(not Journal.validate_records(large_records).is_empty(), "actual serialized recovery bytes are bounded independently of record count")
	var stale: Dictionary = store.load_session(raw["id"])
	stale.erase("script_changes")
	check(store.save_session(stale).get("success", false) and not store.load_session(raw["id"])["script_changes"].is_empty(), "a stale display save cannot discard durable checkpoints")
	raw["script_changes"] = [forged]
	check(not store.save_session(raw).get("success", false), "corrupt checkpoint save is rejected rather than silently fitted")
	var disposable: Dictionary = store.create_session(1, "openai", "fixture")
	disposable["script_changes"] = [record]
	check(store.save_session(disposable).get("success", false), "deletion fixture saves a recovery record")
	var backup_path: String = store._session_path(disposable["id"]) + ".backup"
	var backup := FileAccess.open(backup_path, FileAccess.WRITE)
	backup.store_string(JSON.stringify(disposable))
	backup.close()
	check(store.delete_session(disposable["id"]).get("cleanup_complete", false) and not FileAccess.file_exists(backup_path), "conversation deletion removes checkpoint source from recovery backups too")
	check(prepared_checks >= 6, "actual pre-write durability was exercised across success and failures")


func _test_process_recovery() -> void:
	var proposal := Tools.prepare_file_patch("process", path, OLD.sha256_text(), [{"start_line": 2, "end_line": 2, "replacement": "const VALUE = 2"}])
	var record := Journal.prepare(proposal)
	record["status"] = "applied"
	var recovery_session: Dictionary = store.create_session(1, "openai", "fixture")
	recovery_session["script_changes"] = [record]
	check(store.save_session(recovery_session).get("success", false), "process recovery fixture is durable")
	_put(NEW)
	var output := []
	var exit_code := OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/auto_apply_test.gd", "--", "recover_checkpoint", path, storage, recovery_session["id"]], output, true)
	check(exit_code == 0 and _read() == OLD, "a separate Godot process restores and explicitly reverts the checkpoint: %s" % str(output))
	check(store.load_session(recovery_session["id"])["script_changes"][0]["status"] == "reverted", "separate-process revert outcome is durable")


func _recover_in_new_process(arguments: PackedStringArray) -> void:
	if arguments.size() != 4:
		quit(1)
		return
	path = arguments[1]
	storage = arguments[2]
	store = Store.new(storage)
	session = store.load_session(arguments[3])
	controller = FixtureController.new()
	root.add_child(controller)
	controller.script_change_writer = _write_checkpoint
	check(controller.restore_session_state(1, [], {}) and controller.restore_script_changes(session.get("script_changes", [])), "new process loads canonical recovery")
	check(not controller.auto_apply_enabled() and _read() == NEW, "new process grants nothing and replays nothing")
	controller.revert_edit(session["script_changes"][0]["id"])
	check(_read() == OLD, "explicit Work revert restores original source in the new process")
	for failure in failures: push_error(failure)
	controller.free()
	quit(0 if failures.is_empty() else 1)
