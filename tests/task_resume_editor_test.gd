@tool
extends "res://tests/editor_test_case.gd"

const ChatScene = preload("res://addons/orca/scenes/chat_window.tscn")
const Config = preload("res://addons/orca/scripts/config.gd")
const Component = preload("res://tests/auto_apply_test.gd")
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting(Config.SETTING_PROVIDER, "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	var view = ChatScene.instantiate()
	root.add_child(view)
	for frame in 8: await process_frame
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view._on_new_session_pressed()
	var session_id: String = view._session["id"]
	var tasks := [{"content": "Already finished", "status": "completed"}, {"content": "Verify the remaining change", "status": "pending"}]
	view.agent_controller._tasks.assign(tasks)
	view._on_tasks_changed(tasks)
	view._set_request_active(false)
	view.prompt_input.text = "Keep my draft"
	view._on_resume_remaining_work()
	_check(client.requests.is_empty() and view.prompt_input.text == "Keep my draft", "Resume must preserve a draft")
	view.prompt_input.text = ""
	view._session_resumable = false
	view._on_resume_remaining_work()
	_check(client.requests.is_empty(), "Resume must not bypass view-only restoration")
	view._session_resumable = true
	view.agent_controller.set_mode(0)
	view.task_list_panel._resume_button.pressed.emit()
	view.task_list_panel._resume_button.pressed.emit()
	_check(client.requests.size() == 1 and view._session["id"] == session_id, "one click must start one new turn in the same session")
	_check(view.agent_controller.get_mode() == 0 and not view.agent_controller.auto_apply_enabled(), "Resume must preserve Plan and edit permissions")
	_check(JSON.stringify(client.requests[0]).contains("Verify the remaining change"), "Resume uses the current request-scoped checklist")
	client.complete({"role": "assistant", "content": "Reviewed remaining work."})
	for frame in 4: await process_frame
	var first_turn: int = view.agent_controller._turn_id_serial
	view.agent_controller._tool_rounds = 24
	view.agent_controller._tool_calls_admitted = 192
	view._on_resume_remaining_work()
	_check(client.requests.size() == 2 and view.agent_controller._turn_id_serial > first_turn, "Resume creates a fresh turn rather than replaying a prior request")
	_check(view.agent_controller._tool_rounds == 0 and view.agent_controller._tool_calls_admitted == 0, "ordinary submission refreshes turn budgets")
	client.complete({"role": "assistant", "content": "Done."})
	for frame in 4: await process_frame
	view.agent_controller._tasks.assign([{"content": "Done", "status": "completed"}])
	view._on_tasks_changed(view.agent_controller._tasks)
	view._on_resume_remaining_work()
	_check(client.requests.size() == 2, "finished or cancelled checklists cannot generate a resume request")
	view.queue_free()
	for frame in 8: await process_frame
	for failure in failures: print("FAIL: ", failure)
	print("task_resume_editor_test: PASS" if failures.is_empty() else "task_resume_editor_test: FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
