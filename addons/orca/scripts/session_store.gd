@tool
extends RefCounted

const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")

const SCHEMA_VERSION := 1
const MAX_SESSIONS := 50
const MAX_SESSION_BYTES := 4 * 1024 * 1024
const MAX_EVENTS := 300
const MAX_CONTINUATION_MESSAGES := 120
const MAX_MESSAGE_CHARS := 65536
const MAX_SUMMARY_CHARS := 4096
const MAX_HELP_TOPIC_CHARS := 256
const HELP_TOPIC_PREFIXES := ["class_name", "class_method", "class_property", "class_signal", "class_constant", "class_enum"]

var _project_root: String
var _project_hash: String
var _storage_root: String
var _index_path: String


func _init(storage_root: String = "") -> void:
	_project_root = ProjectSettings.globalize_path("res://").simplify_path()
	_project_hash = _project_root.sha256_text()
	_storage_root = storage_root.trim_suffix("/") if not storage_root.is_empty() else "user://orca/projects/%s/sessions" % _project_hash
	_index_path = _storage_root + "/index.json"


func create_session(mode: int, provider: String, model: String) -> Dictionary:
	var now := Time.get_unix_time_from_system()
	return {
		"schema_version": SCHEMA_VERSION,
		"project_hash": _project_hash,
		"id": _new_session_id(),
		"title": "New conversation",
		"created_at": now,
		"updated_at": now,
		"mode": mode,
		"provider": provider,
		"model": model,
		"clean": true,
		"resumable": true,
		"events": [],
		"continuation": [],
		"usage": {},
		"tasks": [],
		"changed_file_count": 0,
		"last_prompt": "",
		"truncated": false
	}


func save_session(session: Dictionary, make_active: bool = true) -> Dictionary:
	var sanitized := _sanitize_session(session)
	if sanitized.is_empty():
		return {"success": false, "error": "Session data is invalid."}
	if not _ensure_storage_directory():
		return {"success": false, "error": "Could not create the session storage directory."}
	sanitized = _fit_session(sanitized)
	var session_path := _session_path(str(sanitized["id"]))
	var write_error := _atomic_write_json(session_path, sanitized)
	if not write_error.is_empty():
		return {"success": false, "error": write_error}

	var index := _load_index()
	var summaries: Array = index.get("sessions", [])
	var summary := _session_summary(sanitized)
	var replaced := false
	var removed_ids := PackedStringArray()
	for entry_index in range(summaries.size()):
		if str(summaries[entry_index].get("id", "")) == str(sanitized["id"]):
			summaries[entry_index] = summary
			replaced = true
			break
	if not replaced:
		summaries.append(summary)
	summaries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("updated_at", 0.0)) > float(b.get("updated_at", 0.0)))
	while summaries.size() > MAX_SESSIONS:
		var removed: Dictionary = summaries.pop_back()
		removed_ids.append(str(removed.get("id", "")))
	index["sessions"] = summaries
	if make_active:
		index["active_session_id"] = sanitized["id"]
	write_error = _atomic_write_json(_index_path, index)
	if not write_error.is_empty():
		if not replaced:
			if not _remove_session_file(str(sanitized["id"])):
				write_error += " The unindexed session file could not be removed."
		return {"success": false, "error": write_error}
	var cleanup_failures := PackedStringArray()
	for removed_id in removed_ids:
		if not _remove_session_file(removed_id):
			cleanup_failures.append(removed_id)
	var result := {"success": true, "session": sanitized}
	if not cleanup_failures.is_empty():
		result["warning"] = "Some expired session files could not be removed. Delete All will retry cleanup."
	return result


func list_sessions() -> Array:
	var index := _load_index()
	var sessions: Array = index.get("sessions", [])
	return sessions.duplicate(true)


func load_session(session_id: String) -> Dictionary:
	if not _valid_session_id(session_id):
		return {}
	var data := _read_json(_session_path(session_id), MAX_SESSION_BYTES)
	if data.is_empty() or int(data.get("schema_version", 0)) != SCHEMA_VERSION:
		return {}
	if str(data.get("project_hash", "")) != _project_hash or str(data.get("id", "")) != session_id:
		return {}
	return _sanitize_session(data)


func load_active_session() -> Dictionary:
	var active_id := str(_load_index().get("active_session_id", ""))
	return load_session(active_id) if not active_id.is_empty() else {}


func set_active_session(session_id: String) -> bool:
	if not session_id.is_empty() and load_session(session_id).is_empty():
		return false
	var index := _load_index()
	index["active_session_id"] = session_id
	return _atomic_write_json(_index_path, index).is_empty()


func delete_session(session_id: String) -> Dictionary:
	if not _valid_session_id(session_id):
		return {"committed": false, "cleanup_complete": false, "error": "Invalid session ID."}
	var index := _load_index()
	var absolute_path := ProjectSettings.globalize_path(_session_path(session_id))
	var tombstone_path := absolute_path + ".delete"
	DirAccess.remove_absolute(tombstone_path)
	var had_file := FileAccess.file_exists(absolute_path)
	if had_file and DirAccess.rename_absolute(absolute_path, tombstone_path) != OK:
		return {"committed": false, "cleanup_complete": false, "error": "Could not prepare the session for deletion."}
	var sessions: Array = index.get("sessions", [])
	sessions = sessions.filter(func(entry): return str(entry.get("id", "")) != session_id)
	index["sessions"] = sessions
	if str(index.get("active_session_id", "")) == session_id:
		index["active_session_id"] = ""
	if not _atomic_write_json(_index_path, index).is_empty():
		if had_file:
			DirAccess.rename_absolute(tombstone_path, absolute_path)
		return {"committed": false, "cleanup_complete": false, "error": "Could not update the session index."}
	var cleanup_complete := not had_file or DirAccess.remove_absolute(tombstone_path) == OK
	return {
		"committed": true,
		"cleanup_complete": cleanup_complete,
		"error": "" if cleanup_complete else "The conversation was deleted from History, but its local tombstone could not be removed."
	}


func delete_all_sessions() -> Dictionary:
	if not _atomic_write_json(_index_path, _empty_index()).is_empty():
		return {"committed": false, "cleanup_complete": false, "error": "Could not clear the session index."}
	var cleanup_complete := _remove_all_session_artifacts()
	return {
		"committed": true,
		"cleanup_complete": cleanup_complete,
		"error": "" if cleanup_complete else "History was cleared, but some local session artifacts could not be removed."
	}


func storage_root() -> String:
	return _storage_root


func _sanitize_session(raw: Dictionary) -> Dictionary:
	var session_id := str(raw.get("id", ""))
	if not _valid_session_id(session_id):
		return {}
	var events: Array = []
	var raw_events = raw.get("events", [])
	var was_truncated := bool(raw.get("truncated", false)) or _requires_truncation(raw)
	if typeof(raw_events) == TYPE_ARRAY:
		var start := maxi(0, raw_events.size() - MAX_EVENTS)
		for index in range(start, raw_events.size()):
			var event := _sanitize_event(raw_events[index])
			if not event.is_empty():
				events.append(event)
	var continuation := _sanitize_continuation(raw.get("continuation", []))
	var usage := _sanitize_usage(raw.get("usage", {}))
	var tasks := TaskUtils.sanitize_tasks(raw.get("tasks", []))
	return {
		"schema_version": SCHEMA_VERSION,
		"project_hash": _project_hash,
		"id": session_id,
		"title": _bounded_text(str(raw.get("title", "New conversation")), 120),
		"created_at": float(raw.get("created_at", Time.get_unix_time_from_system())),
		"updated_at": float(raw.get("updated_at", Time.get_unix_time_from_system())),
		"mode": clampi(int(raw.get("mode", 1)), 0, 1),
		"provider": _bounded_text(str(raw.get("provider", "")), 64),
		"model": _bounded_text(str(raw.get("model", "")), 160),
		"clean": bool(raw.get("clean", true)),
		"resumable": bool(raw.get("resumable", true)),
		"events": events,
		"continuation": continuation,
		"usage": usage,
		"tasks": tasks,
		"changed_file_count": maxi(0, int(raw.get("changed_file_count", 0))),
		"last_prompt": _bounded_text(str(raw.get("last_prompt", "")), 240),
		"truncated": was_truncated or events.size() < (raw_events.size() if typeof(raw_events) == TYPE_ARRAY else 0)
	}


func _sanitize_event(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var event_type := str(raw.get("type", ""))
	var event := {
		"type": event_type,
		"timestamp": float(raw.get("timestamp", Time.get_unix_time_from_system()))
	}
	match event_type:
		"message":
			event["sender"] = _bounded_text(str(raw.get("sender", "")), 40)
			event["text"] = _bounded_text(str(raw.get("text", "")), MAX_MESSAGE_CHARS)
			event["kind"] = str(raw.get("kind", "assistant")) if str(raw.get("kind", "")) in ["user", "assistant", "error", "status"] else "status"
			event["mode"] = clampi(int(raw.get("mode", 1)), 0, 1)
			event["completion"] = str(raw.get("completion", "complete"))
			return event
		"tool":
			event["id"] = _bounded_text(str(raw.get("id", "")), 160)
			event["name"] = _bounded_text(str(raw.get("name", "")), 80)
			event["arguments"] = _sanitize_tool_arguments(raw.get("arguments", {}), str(event["name"]))
			event["outcome"] = _bounded_text(str(raw.get("outcome", "completed")), 32)
			event["summary"] = _bounded_text(str(raw.get("summary", "")), MAX_SUMMARY_CHARS)
			event["duration_ms"] = maxi(0, int(raw.get("duration_ms", 0)))
			event["open_path"] = _bounded_text(str(raw.get("open_path", "")), 512)
			event["open_line"] = maxi(1, int(raw.get("open_line", 1)))
			event["open_column"] = maxi(1, int(raw.get("open_column", 1)))
			var help_topic := str(raw.get("help_topic", ""))
			if _is_safe_help_topic(help_topic):
				event["help_topic"] = help_topic
			return event
		"change":
			for field in ["id", "filepath", "kind", "summary", "status", "validation_message", "resolution_message"]:
				event[field] = _bounded_text(str(raw.get(field, "")), MAX_SUMMARY_CHARS if field in ["validation_message", "resolution_message"] else 256)
			event["additions"] = maxi(0, int(raw.get("additions", 0)))
			event["deletions"] = maxi(0, int(raw.get("deletions", 0)))
			event["existed"] = bool(raw.get("existed", false))
			return event
	return {}


func _sanitize_tool_arguments(raw, tool_name: String = "") -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var result := {}
	if tool_name == "read_project_skill":
		if typeof(raw.get("name")) == TYPE_STRING:
			result["name"] = _bounded_text(str(raw["name"]), 128)
		return result
	if tool_name == "inspect_godot_api":
		for key in ["class_name", "member_name"]:
			if typeof(raw.get(key)) == TYPE_STRING:
				result[key] = _bounded_text(str(raw[key]), 256)
		if typeof(raw.get("member_kind")) == TYPE_STRING and str(raw["member_kind"]) in ["auto", "method", "property", "signal", "constant", "enum"]:
			result["member_kind"] = raw["member_kind"]
		if typeof(raw.get("include_inherited")) == TYPE_BOOL:
			result["include_inherited"] = raw["include_inherited"]
		return result
	if tool_name == "read_gdscript_function":
		if typeof(raw.get("filepath")) == TYPE_STRING:
			result["filepath"] = _bounded_text(str(raw["filepath"]), 512)
		if typeof(raw.get("function_name")) == TYPE_STRING:
			result["function_name"] = _bounded_text(str(raw["function_name"]), 128)
		if typeof(raw.get("start_line_hint")) in [TYPE_INT, TYPE_FLOAT]:
			result["start_line_hint"] = maxi(1, int(raw["start_line_hint"]))
		if typeof(raw.get("include_documentation")) == TYPE_BOOL:
			result["include_documentation"] = raw["include_documentation"]
		return result
	if tool_name == "discover_dependencies":
		if typeof(raw.get("filepath")) == TYPE_STRING:
			result["filepath"] = _bounded_text(str(raw["filepath"]), 512)
		if typeof(raw.get("direction")) == TYPE_STRING and str(raw["direction"]) in ["forward", "reverse"]:
			result["direction"] = raw["direction"]
		if typeof(raw.get("max_depth")) in [TYPE_INT, TYPE_FLOAT]:
			result["max_depth"] = clampi(int(raw["max_depth"]), 1, 3)
		if typeof(raw.get("max_results")) in [TYPE_INT, TYPE_FLOAT]:
			result["max_results"] = clampi(int(raw["max_results"]), 1, 100)
		return result
	var keys := ["filepath", "path", "scene_path", "setting_path", "query", "file_glob", "start_line", "end_line", "case_sensitive", "max_results", "include_properties", "max_nodes", "max_properties_per_node"]
	for key in keys:
		if not raw.has(key):
			continue
		var value = raw[key]
		if typeof(value) == TYPE_STRING:
			var limit := 512
			if key == "name" or key == "function_name":
				limit = 128
			elif key in ["class_name", "member_name", "member_kind", "direction"]:
				limit = 256
			result[key] = _bounded_text(value, limit)
		elif typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL]:
			result[key] = value
	return result


func _is_safe_help_topic(topic: String) -> bool:
	if topic.is_empty() or topic.length() > MAX_HELP_TOPIC_CHARS or topic.contains("\n") or topic.contains("\r") or topic.contains("\t"):
		return false
	var parts := topic.split(":", true)
	if parts.is_empty() or parts[0] not in HELP_TOPIC_PREFIXES:
		return false
	var expected_parts := 2 if parts[0] == "class_name" else 3
	if parts.size() != expected_parts:
		return false
	for index in range(1, parts.size()):
		if str(parts[index]).is_empty():
			return false
	return true


func _sanitize_continuation(raw) -> Array:
	var result: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return result
	var start := maxi(0, raw.size() - MAX_CONTINUATION_MESSAGES)
	for index in range(start, raw.size()):
		var message = raw[index]
		if typeof(message) != TYPE_DICTIONARY:
			continue
		var role := str(message.get("role", ""))
		if role not in ["user", "assistant"] or typeof(message.get("content")) != TYPE_STRING:
			continue
		result.append({"role": role, "content": _bounded_text(message["content"], MAX_MESSAGE_CHARS)})
	return result


func _sanitize_usage(raw) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	return {
		"model": _bounded_text(str(raw.get("model", "")), 160),
		"context_tokens": maxi(0, int(raw.get("context_tokens", 0))),
		"context_limit": maxi(0, int(raw.get("context_limit", 0))),
		"input_tokens": maxi(0, int(raw.get("input_tokens", 0))),
		"output_tokens": maxi(0, int(raw.get("output_tokens", 0))),
		"cached_tokens": maxi(0, int(raw.get("cached_tokens", 0))),
		"cost_usd": maxf(0.0, float(raw.get("cost_usd", 0.0))),
		"usage_complete": bool(raw.get("usage_complete", true)),
		"cost_available": bool(raw.get("cost_available", false)),
		"cost_complete": bool(raw.get("cost_complete", true)),
		"cost_estimated": bool(raw.get("cost_estimated", false)),
		"completed_requests": maxi(0, int(raw.get("completed_requests", 0)))
	}


func _fit_session(session: Dictionary) -> Dictionary:
	var fitted := session.duplicate(true)
	while JSON.stringify(fitted).to_utf8_buffer().size() > MAX_SESSION_BYTES:
		fitted["truncated"] = true
		var events: Array = fitted.get("events", [])
		if events.size() > 1:
			events.pop_front()
			continue
		var continuation: Array = fitted.get("continuation", [])
		if continuation.size() > 1:
			continuation.pop_front()
			continue
		break
	return fitted


func _session_summary(session: Dictionary) -> Dictionary:
	return {
		"id": session.get("id", ""),
		"title": session.get("title", "New conversation"),
		"created_at": session.get("created_at", 0.0),
		"updated_at": session.get("updated_at", 0.0),
		"mode": session.get("mode", 1),
		"provider": session.get("provider", ""),
		"model": session.get("model", ""),
		"clean": session.get("clean", true),
		"resumable": session.get("resumable", true),
		"last_prompt": session.get("last_prompt", ""),
		"changed_file_count": session.get("changed_file_count", 0),
		"cost_usd": session.get("usage", {}).get("cost_usd", 0.0),
		"cost_available": session.get("usage", {}).get("cost_available", false),
		"truncated": session.get("truncated", false)
	}


func _load_index() -> Dictionary:
	var index := _read_json(_index_path, 512 * 1024)
	if index.is_empty() or int(index.get("schema_version", 0)) != SCHEMA_VERSION or str(index.get("project_hash", "")) != _project_hash:
		return _empty_index()
	var sessions = index.get("sessions", [])
	if typeof(sessions) != TYPE_ARRAY:
		return _empty_index()
	_reconcile_tombstones(index)
	var valid_sessions: Array = sessions.filter(func(entry):
		return typeof(entry) == TYPE_DICTIONARY and _valid_session_id(str(entry.get("id", ""))) and FileAccess.file_exists(_session_path(str(entry.get("id", ""))))
	)
	valid_sessions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("updated_at", 0.0)) > float(b.get("updated_at", 0.0)))
	if valid_sessions.size() > MAX_SESSIONS:
		valid_sessions.resize(MAX_SESSIONS)
	index["sessions"] = valid_sessions
	return index


func _empty_index() -> Dictionary:
	return {"schema_version": SCHEMA_VERSION, "project_hash": _project_hash, "active_session_id": "", "sessions": []}


func _read_json(path: String, max_bytes: int) -> Dictionary:
	_recover_backup(path, max_bytes)
	return _read_json_file(path, max_bytes)


func _read_json_file(path: String, max_bytes: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > max_bytes:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	return data if typeof(data) == TYPE_DICTIONARY else {}


func _atomic_write_json(path: String, data: Dictionary) -> String:
	if not _ensure_storage_directory():
		return "Could not create the session storage directory."
	var absolute_path := ProjectSettings.globalize_path(path)
	var temporary_path := absolute_path + ".tmp"
	var backup_path := absolute_path + ".backup"
	_recover_backup(absolute_path, MAX_SESSION_BYTES)
	DirAccess.remove_absolute(temporary_path)
	if FileAccess.file_exists(backup_path):
		return "A previous session backup could not be recovered."
	var payload := JSON.stringify(data, "  ")
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return "Could not create a temporary session file."
	file.store_string(payload)
	file.flush()
	file = null
	var verified := _read_json_file(temporary_path, MAX_SESSION_BYTES)
	if verified.is_empty():
		DirAccess.remove_absolute(temporary_path)
		return "Could not verify the temporary session file."
	var target_exists := FileAccess.file_exists(absolute_path)
	if target_exists and DirAccess.rename_absolute(absolute_path, backup_path) != OK:
		DirAccess.remove_absolute(temporary_path)
		return "Could not checkpoint the existing session file."
	var replace_error := DirAccess.rename_absolute(temporary_path, absolute_path)
	if replace_error != OK:
		if target_exists:
			DirAccess.rename_absolute(backup_path, absolute_path)
		DirAccess.remove_absolute(temporary_path)
		return "Could not replace the session file."
	if _read_json_file(absolute_path, MAX_SESSION_BYTES).is_empty():
		DirAccess.remove_absolute(absolute_path)
		if target_exists:
			DirAccess.rename_absolute(backup_path, absolute_path)
		return "Could not verify the replaced session file."
	if target_exists and DirAccess.remove_absolute(backup_path) != OK:
		return "The session was saved, but its recovery backup could not be removed."
	return ""


func _ensure_storage_directory() -> bool:
	var absolute_root := ProjectSettings.globalize_path(_storage_root)
	return DirAccess.dir_exists_absolute(absolute_root) or DirAccess.make_dir_recursive_absolute(absolute_root) == OK


func _remove_session_file(session_id: String) -> bool:
	if _valid_session_id(session_id):
		var path := ProjectSettings.globalize_path(_session_path(session_id))
		return not FileAccess.file_exists(path) or DirAccess.remove_absolute(path) == OK
	return false


func _remove_all_session_artifacts() -> bool:
	var absolute_root := ProjectSettings.globalize_path(_storage_root)
	var directory := DirAccess.open(absolute_root)
	if directory == null:
		return true
	var success := true
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and (filename.begins_with("session_") or filename in ["index.json.tmp", "index.json.backup"]):
			if DirAccess.remove_absolute(absolute_root.path_join(filename)) != OK:
				success = false
		filename = directory.get_next()
	directory.list_dir_end()
	return success


func _reconcile_tombstones(index: Dictionary) -> void:
	var absolute_root := ProjectSettings.globalize_path(_storage_root)
	var directory := DirAccess.open(absolute_root)
	if directory == null:
		return
	var indexed_ids: Dictionary = {}
	for summary in index.get("sessions", []):
		if typeof(summary) == TYPE_DICTIONARY:
			indexed_ids[str(summary.get("id", ""))] = true
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and filename.begins_with("session_") and filename.ends_with(".json.delete"):
			var session_id := filename.trim_suffix(".json.delete")
			var tombstone_path := absolute_root.path_join(filename)
			if indexed_ids.has(session_id):
				var target_path := ProjectSettings.globalize_path(_session_path(session_id))
				if not FileAccess.file_exists(target_path):
					DirAccess.rename_absolute(tombstone_path, target_path)
			else:
				DirAccess.remove_absolute(tombstone_path)
		filename = directory.get_next()
	directory.list_dir_end()


func _recover_backup(path: String, max_bytes: int) -> void:
	var absolute_path := ProjectSettings.globalize_path(path)
	var backup_path := absolute_path + ".backup"
	if not FileAccess.file_exists(backup_path):
		return
	var target_valid := not _read_json_file(absolute_path, max_bytes).is_empty()
	if target_valid:
		DirAccess.remove_absolute(backup_path)
		return
	if _read_json_file(backup_path, max_bytes).is_empty():
		return
	DirAccess.remove_absolute(absolute_path)
	DirAccess.rename_absolute(backup_path, absolute_path)


func _session_path(session_id: String) -> String:
	return _storage_root + "/" + session_id + ".json"


func _new_session_id() -> String:
	return "session_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec()]


func _valid_session_id(session_id: String) -> bool:
	if session_id.is_empty() or session_id.length() > 80 or not session_id.begins_with("session_"):
		return false
	for character in session_id:
		if not (character.is_valid_int() or character == "_" or character.to_lower() != character.to_upper()):
			return false
	return true


func _bounded_text(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	return text.left(maxi(0, limit - 14)) + "\n...[truncated]"


func _requires_truncation(raw: Dictionary) -> bool:
	var events = raw.get("events", [])
	if typeof(events) == TYPE_ARRAY:
		if events.size() > MAX_EVENTS:
			return true
		for event in events:
			if typeof(event) == TYPE_DICTIONARY and str(event.get("type", "")) == "message" and str(event.get("text", "")).length() > MAX_MESSAGE_CHARS:
				return true
	var continuation = raw.get("continuation", [])
	if typeof(continuation) != TYPE_ARRAY:
		return true
	if continuation.size() > MAX_CONTINUATION_MESSAGES:
		return true
	for message in continuation:
		if typeof(message) != TYPE_DICTIONARY:
			return true
		if str(message.get("role", "")) not in ["user", "assistant"] or typeof(message.get("content")) != TYPE_STRING:
			return true
		if str(message.get("content", "")).length() > MAX_MESSAGE_CHARS:
			return true
	return false
