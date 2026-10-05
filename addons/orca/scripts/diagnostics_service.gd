@tool
class_name OrcaDiagnosticsService
extends Node

const MAX_RECORDS := 100
const MAX_MESSAGE_CHARS := 2000
const MAX_FILE_CHARS := 512
const MAX_FUNCTION_CHARS := 256
static var _records: Array[Dictionary] = []
static var _records_mutex := Mutex.new()
static var _next_sequence := 1
static var _shared_logger: CaptureLogger
static var _logger_users := 0

class CaptureLogger extends Logger:
	func _record_diagnostic(record: Dictionary) -> void:
		OrcaDiagnosticsService._record(record)

	func _log_error(function, file, line, code, rationale, editor_notify, error_type, script_backtraces) -> void:
		_record_diagnostic({
			"origin": "editor",
			"severity": "warning" if int(error_type) == ERROR_TYPE_WARNING else "error",
			"file": str(file),
			"line": int(line),
			"function": str(function),
			"message": str(rationale) if not str(rationale).is_empty() else str(code),
			"time_ms": Time.get_ticks_msec()
		})

	func _log_message(message, is_stderr) -> void:
		if is_stderr:
			_record_diagnostic({
				"origin": "editor",
				"severity": "error",
				"file": "",
				"line": 0,
				"function": "",
				"message": str(message),
				"time_ms": Time.get_ticks_msec()
			})

var _logger_acquired := false


func _ready() -> void:
	if Engine.is_editor_hint():
		var logger_to_add: CaptureLogger
		_records_mutex.lock()
		if _shared_logger == null:
			_shared_logger = CaptureLogger.new()
			logger_to_add = _shared_logger
		_logger_users += 1
		_logger_acquired = true
		_records_mutex.unlock()
		if logger_to_add != null:
			OS.add_logger(logger_to_add)


func _exit_tree() -> void:
	if not _logger_acquired:
		return
	var logger_to_remove: CaptureLogger
	_records_mutex.lock()
	_logger_users = maxi(0, _logger_users - 1)
	if _logger_users == 0 and _shared_logger != null:
		logger_to_remove = _shared_logger
		_shared_logger = null
	_logger_acquired = false
	_records_mutex.unlock()
	if logger_to_remove != null:
		OS.remove_logger(logger_to_remove)


static func validate_source(filepath: String, source: String) -> Dictionary:
	if filepath.get_extension().to_lower() != "gd":
		return {"valid": true, "diagnostics": [], "message": "No GDScript validation required."}
	_records_mutex.lock()
	var first_sequence := _next_sequence
	_records_mutex.unlock()
	var candidate := GDScript.new()
	candidate.set_path_cache(filepath)
	candidate.source_code = source
	var result := candidate.reload()
	_records_mutex.lock()
	var diagnostics: Array = _records.filter(func(record):
		if int(record.get("sequence", 0)) < first_sequence:
			return false
		var record_file := str(record.get("file", ""))
		return record_file.is_empty() or record_file == filepath
	).duplicate(true)
	_records_mutex.unlock()
	if result != OK and diagnostics.is_empty():
		diagnostics.append({
			"severity": "error",
			"file": filepath,
			"line": 0,
			"message": error_string(result),
			"time_ms": Time.get_ticks_msec()
		})
	for diagnostic in diagnostics:
		if diagnostic.get("file", "").is_empty():
			diagnostic["file"] = filepath
	return {
		"valid": result == OK,
		"diagnostics": diagnostics,
		"message": "GDScript is valid." if result == OK else "GDScript validation failed: " + error_string(result)
	}


static func get_report(game_snapshot: Dictionary = {}) -> Dictionary:
	var playing := false
	var playing_scene := ""
	if Engine.is_editor_hint():
		playing = EditorInterface.is_playing_scene()
		playing_scene = EditorInterface.get_playing_scene()
	_records_mutex.lock()
	var records := _records.duplicate(true)
	_records_mutex.unlock()
	return {
		"records": records,
		"game_records": game_snapshot.get("diagnostics", []).duplicate(true),
		"orca_run": game_snapshot.duplicate(true) if not game_snapshot.is_empty() else {"run_id": 0, "sequence": 0, "state": "idle", "scene_path": "", "stdout": "", "stderr": "", "diagnostics": [], "diagnostics_truncated": false, "output_truncated": false, "dropped_bytes": 0, "verification_status": "unverified"},
		"playing": playing,
		"playing_scene": playing_scene,
		"note": "Godot does not expose historical Output dock or built-in debugger records to GDScript plugins. Game output and diagnostics are available only for the bounded process Orca started; validation and observed editor-process errors remain separate records. Orca API transport failures are excluded."
	}


static func clear() -> void:
	_records_mutex.lock()
	_records.clear()
	_records_mutex.unlock()


static func _record(record: Dictionary) -> void:
	var stored := record.duplicate(true)
	stored["message"] = str(stored.get("message", "")).left(MAX_MESSAGE_CHARS)
	stored["file"] = str(stored.get("file", "")).left(MAX_FILE_CHARS)
	stored["function"] = str(stored.get("function", "")).left(MAX_FUNCTION_CHARS)
	_records_mutex.lock()
	if not stored.has("origin"):
		stored["origin"] = "editor"
	stored["sequence"] = _next_sequence
	_next_sequence += 1
	_records.append(stored)
	if _records.size() > MAX_RECORDS:
		_records.pop_front()
	_records_mutex.unlock()
