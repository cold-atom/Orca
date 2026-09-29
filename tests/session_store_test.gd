extends SceneTree

const SessionStore = preload("res://addons/orca/scripts/session_store.gd")
const AgentController = preload("res://addons/orca/scripts/agent_controller.gd")

var _failures := PackedStringArray()
var _test_root := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_root = "user://orca_session_test_%d" % Time.get_ticks_usec()
	var store = SessionStore.new(_test_root)
	var session: Dictionary = store.create_session(1, "deepseek", "deepseek-chat")
	session["title"] = "Test session"
	session["last_prompt"] = "Build a test"
	session["api_key"] = "must-not-persist"
	session["events"] = [
		{"type": "message", "sender": "User", "text": "Build a test", "kind": "user", "mode": 1, "completion": "complete"},
		{"type": "tool", "id": "call_1", "name": "apply_patch", "arguments": {"filepath": "res://main.gd", "scene_path": "res://main.tscn", "setting_path": "application/run/main_scene", "include_properties": true, "max_nodes": 20, "query": "Player", "setting_value": "must-not-persist", "edits": [{"replacement": "secret source"}]}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 3, "open_path": "res://main.gd", "open_line": 7, "open_column": 4, "raw_data": "must-not-persist"},
		{"type": "change", "id": "call_1", "filepath": "res://main.gd", "status": "applied", "additions": 2, "deletions": 1, "old_hash": "old", "new_hash": "new", "old_content": "must-not-persist"},
		{"type": "change", "id": "input_1", "filepath": "res://project.godot", "kind": "input_map", "summary": "Input Map: jump", "status": "applied", "old_hash": "old-input", "new_hash": "new-input", "review": [{"action": "jump", "secret": "must-not-persist"}], "old_content": "must-not-persist"},
		{"type": "change", "id": "main_1", "filepath": "res://project.godot", "kind": "main_scene", "summary": "Main scene: res://main.tscn", "status": "applied", "old_hash": "must-not-persist", "new_hash": "must-not-persist", "new_value": "must-not-persist"},
		{"type": "change", "id": "settings_1", "filepath": "res://project.godot", "kind": "project_settings", "summary": "Project settings: Viewport width", "status": "applied", "values": {"display/window/size/viewport_width": "must-not-persist"}, "changes": ["must-not-persist"]},
		{"type": "tool", "id": "verify_1", "name": "verify_game_run", "arguments": {"run_id": 9, "verification": {"claim": "must-not-persist", "required_stdout": ["must-not-persist"]}}, "outcome": "completed", "summary": "Completed successfully.", "duration_ms": 2, "raw_data": {"stdout": "must-not-persist", "criteria_id": "must-not-persist"}}
	]
	session["continuation"] = [
		{"role": "user", "content": "Build a test", "reasoning_content": "must-not-persist"},
		{"role": "assistant", "content": "Finished"}
	]
	session["usage"] = {"model": "deepseek-chat", "input_tokens": 100, "output_tokens": 20, "cached_tokens": 10, "context_tokens": 120, "cost_usd": 0.002, "cost_available": true, "cost_complete": true, "usage_complete": true, "completed_requests": 1}
	session["tasks"] = [
		{"content": "Completed", "status": "completed", "secret": "must-not-persist"},
		{"content": "Current", "status": "in_progress"},
		{"content": "Second active becomes pending", "status": "in_progress"},
		{"content": "Unknown status becomes pending", "status": "unknown"}
	]
	var save_result: Dictionary = store.save_session(session)
	_expect(save_result.get("success") == true, "a valid session should save")
	var loaded: Dictionary = store.load_session(str(session["id"]))
	_expect(not loaded.is_empty(), "a saved session should load")
	_expect(not loaded.has("api_key"), "credentials must not be persisted")
	_expect(not loaded.get("continuation", [])[0].has("reasoning_content"), "hidden reasoning must not be persisted")
	_expect(not loaded.get("events", [])[1].get("arguments", {}).has("edits"), "patch source must not be persisted in tool arguments")
	_expect(loaded.get("events", [])[1].get("arguments", {}).get("query") == "Player", "bounded search queries should persist for restored activity labels")
	_expect(loaded.get("events", [])[1].get("arguments", {}).get("scene_path") == "res://main.tscn", "bounded scene paths should persist for restored activity labels")
	_expect(loaded.get("events", [])[1].get("arguments", {}).get("include_properties") == true, "scene inspection options should persist as bounded metadata")
	_expect(loaded.get("events", [])[1].get("arguments", {}).get("setting_path") == "application/run/main_scene", "explicit setting paths should persist for restored activity labels")
	_expect(not loaded.get("events", [])[1].get("arguments", {}).has("setting_value"), "project setting values must not persist in activity metadata")
	_expect(loaded.get("events", [])[1].get("open_path") == "res://main.gd", "bounded navigation paths should persist")
	_expect(loaded.get("events", [])[1].get("open_line") == 7 and loaded.get("events", [])[1].get("open_column") == 4, "navigation coordinates should persist")
	_expect(not loaded.get("events", [])[1].has("raw_data"), "arbitrary tool execution data must not persist")
	_expect(not loaded.get("events", [])[2].has("old_content"), "source snapshots must not be persisted in change summaries")
	_expect(loaded.get("events", [])[3].get("kind") == "input_map" and loaded.get("events", [])[3].get("summary") == "Input Map: jump", "safe structured change kind and summary should persist")
	_expect(not loaded.get("events", [])[3].has("review") and not loaded.get("events", [])[3].has("old_content"), "structured review payloads must not persist")
	_expect(not loaded.get("events", [])[2].has("old_hash") and not loaded.get("events", [])[3].has("new_hash"), "proposal hashes must not persist in change summaries")
	_expect(loaded.get("events", [])[4].get("kind") == "main_scene" and loaded.get("events", [])[4].get("summary") == "Main scene: res://main.tscn", "safe main scene change summaries should persist")
	_expect(not loaded.get("events", [])[4].has("new_value") and not loaded.get("events", [])[4].has("old_hash"), "main scene raw values and hashes must not persist")
	_expect(loaded.get("events", [])[5].get("kind") == "project_settings" and loaded.get("events", [])[5].get("summary") == "Project settings: Viewport width", "safe ProjectSettings change summaries should persist")
	_expect(not loaded.get("events", [])[5].has("values") and not loaded.get("events", [])[5].has("changes"), "ProjectSettings values and operations must not persist")
	_expect(loaded.get("events", [])[6].get("name") == "verify_game_run" and loaded.get("events", [])[6].get("arguments", {}).is_empty(), "runtime run IDs and verification criteria must not persist")
	_expect(not loaded.get("events", [])[6].has("raw_data"), "runtime evidence and criteria IDs must not persist")
	_expect(loaded.get("tasks", []).size() == 4, "sanitized task state should persist")
	_expect(not loaded.get("tasks", [])[0].has("secret"), "unknown task fields must not persist")
	_expect(loaded.get("tasks", [])[2].get("status") == "pending", "only one persisted task may remain in progress")
	_expect(loaded.get("tasks", [])[3].get("status") == "pending", "unknown persisted task states should become pending")
	_expect(store.load_active_session().get("id") == session.get("id"), "the active session should be restored")
	var session_path: String = store._session_path(str(session["id"]))
	var raw_file := FileAccess.open(session_path, FileAccess.READ)
	var raw_payload := raw_file.get_as_text() if raw_file != null else ""
	_expect(not raw_payload.contains("must-not-persist"), "serialized sessions must not contain redaction sentinels")
	var absolute_session_path := ProjectSettings.globalize_path(session_path)
	_expect(DirAccess.rename_absolute(absolute_session_path, absolute_session_path + ".backup") == OK, "the recovery fixture should move the session to a backup")
	_expect(not store.load_session(str(session["id"])).is_empty(), "a valid backup should recover when the canonical session is missing")

	var oversized: Dictionary = store.create_session(1, "openai", "gpt-4o")
	oversized["continuation"] = []
	for index in range(SessionStore.MAX_CONTINUATION_MESSAGES + 1):
		oversized["continuation"].append({"role": "user", "content": "message %d" % index})
	var oversized_result: Dictionary = store.save_session(oversized, false)
	_expect(oversized_result.get("success") == true, "bounded oversized history should still save")
	_expect(oversized_result.get("session", {}).get("truncated") == true, "dropped continuation history should mark the session truncated")
	var malformed: Dictionary = store.create_session(1, "openai", "gpt-4o")
	malformed["continuation"] = [{"role": "tool", "content": "invalid"}]
	var malformed_result: Dictionary = store.save_session(malformed, false)
	_expect(malformed_result.get("session", {}).get("truncated") == true, "rejected continuation entries should mark the session truncated")

	var second_store = SessionStore.new(_test_root)
	_expect(second_store.list_sessions().size() == 3, "the session index should survive a new store instance")
	for index in range(52):
		var extra: Dictionary = store.create_session(1, "openai", "gpt-4o")
		extra["title"] = "Session %d" % index
		extra["updated_at"] = float(index + 10)
		var retention_result: Dictionary = store.save_session(extra, false)
		_expect(retention_result.get("success") == true, "retention fixture sessions should save")
	_expect(store.list_sessions().size() == SessionStore.MAX_SESSIONS, "retention should keep only the latest 50 sessions")

	var controller = AgentController.new()
	get_root().add_child(controller)
	var restored := controller.restore_session_state(0, loaded.get("continuation", []), loaded.get("usage", {}), loaded.get("tasks", []))
	_expect(restored, "validated continuation history should restore")
	var snapshot: Dictionary = controller.snapshot_session_state()
	_expect(snapshot.get("mode") == 0, "restored mode should be retained")
	_expect(snapshot.get("continuation", []).size() == 2, "restored continuation should remain resumable")
	_expect(snapshot.get("usage", {}).get("input_tokens") == 100, "restored usage should be retained")
	_expect(snapshot.get("usage", {}).get("context_tokens") == 120, "restored context usage should be retained")
	_expect(snapshot.get("tasks", []).size() == 4, "restored controller task state should be retained")
	controller.queue_free()
	await process_frame

	var orphan_path := ProjectSettings.globalize_path(store.storage_root() + "/session_orphan.json.backup")
	var orphan := FileAccess.open(orphan_path, FileAccess.WRITE)
	if orphan != null:
		orphan.store_string("orphan")
		orphan = null
	var delete_result: Dictionary = store.delete_all_sessions()
	_expect(delete_result.get("committed") == true, "Delete All should commit the empty index")
	_expect(store.list_sessions().is_empty(), "Delete All should clear the project session index")
	_expect(not FileAccess.file_exists(orphan_path), "Delete All should remove orphaned session artifacts")
	_remove_tree(ProjectSettings.globalize_path(_test_root))
	_finish()


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if directory.current_is_dir():
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
		print("session_store_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("session_store_test: ", failure)
	quit(1)
