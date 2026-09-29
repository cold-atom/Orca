@tool
extends Node

signal run_state_changed(snapshot: Dictionary)

const MainSceneProposal = preload("res://addons/orca/scripts/main_scene_proposal.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")

const RUN_TIMEOUT_MS := 120000
const MAX_RETAINED_OUTPUT_BYTES := 128 * 1024
const MAX_RETAINED_STREAM_BYTES := MAX_RETAINED_OUTPUT_BYTES / 2
const MAX_OUTPUT_LINES := 1000
const MAX_LINE_CHARS := 4096
const MAX_DIAGNOSTICS := 100
const MAX_DRAIN_BYTES_PER_STREAM_FRAME := 32 * 1024
const MAX_DIAGNOSTIC_LINE_BYTES := 8192
const MAX_VERIFICATION_CLAIM_CHARS := 240
const MAX_VERIFICATION_MARKERS := 5
const MAX_VERIFICATION_MARKER_CHARS := 200
const MIN_STARTUP_VERIFICATION_MS := 250
const MAX_STARTUP_VERIFICATION_MS := 10000

var _active: Dictionary = {}
var _last_snapshot: Dictionary = _idle_snapshot()
var _generation := 0


func _ready() -> void:
	set_process(true)


func _exit_tree() -> void:
	shutdown()


func _process(_delta: float) -> void:
	poll()


func start_current_scene(verification: Dictionary = {}) -> Dictionary:
	if not Engine.is_editor_hint():
		return _failure("The current scene can only be run from the Godot editor.")
	var root := EditorInterface.get_edited_scene_root()
	if root == null or str(root.scene_file_path).is_empty():
		return _failure("The current scene must be saved before Orca can run it.")
	var scene_path := _canonical_res_path(str(root.scene_file_path))
	if EditorContext.has_unsaved_file(scene_path):
		return _failure("The current scene has unsaved changes. Save it before running through Orca.")
	return start_scene("current_scene", scene_path, verification)


func start_main_scene(verification: Dictionary = {}) -> Dictionary:
	var scene_path := MainSceneProposal.resolve_setting_value(ProjectSettings.get_setting(MainSceneProposal.SETTING_PATH, null))
	if scene_path.is_empty():
		return _failure("The project does not have a resolvable main scene. Configure one before running it.")
	if EditorContext.has_unsaved_file(scene_path):
		return _failure("The main scene has unsaved changes. Save it before running through Orca.")
	return start_scene("main_scene", scene_path, verification)


func start_scene(run_kind: String, scene_path: String, verification: Dictionary = {}) -> Dictionary:
	poll()
	if is_running():
		return _failure("An Orca-started game is already running. Stop it before starting another.")
	if Engine.is_editor_hint() and EditorInterface.is_playing_scene():
		return _failure("The editor is already playing a scene. Stop that run before starting an Orca-owned process.")
	if run_kind not in ["current_scene", "main_scene"]:
		return _failure("Unknown game run kind.")
	var verification_result := _normalize_verification(verification)
	if not verification_result.get("success", false):
		return _failure(str(verification_result.get("error", "Invalid verification criteria.")))
	var normalized_verification: Dictionary = verification_result.get("verification", {})
	var canonical_path := _canonical_res_path(scene_path)
	var path_error := _validate_scene_path(canonical_path)
	if not path_error.is_empty():
		return _failure(path_error)
	if Engine.is_editor_hint():
		var unsaved_scripts := Array(EditorInterface.get_script_editor().get_unsaved_files())
		if not unsaved_scripts.is_empty():
			return _failure("Save all open scripts before running through Orca so the child process does not execute stale disk code.")
		var unsaved_scenes := Array(EditorInterface.get_unsaved_scenes())
		if not unsaved_scenes.is_empty():
			return _failure("Save all open scenes before running through Orca so the child process does not load stale scene dependencies.")
	var executable := _get_executable_path()
	if executable.is_empty():
		return _failure("Could not resolve the Godot executable path.")
	var arguments := PackedStringArray(["--path", ProjectSettings.globalize_path("res://")])
	arguments.append_array(["--scene", canonical_path])
	var launched := _launch_process(executable, arguments)
	if launched.is_empty() or int(launched.get("pid", -1)) <= 0 or not launched.get("stdio") is FileAccess or not launched.get("stderr") is FileAccess:
		_close_pipe(launched.get("stdio"))
		_close_pipe(launched.get("stderr"))
		_last_snapshot = _failed_snapshot(run_kind, canonical_path, "Godot could not start the game process.")
		run_state_changed.emit(_last_snapshot.duplicate(true))
		return _failure(str(_last_snapshot.get("message", "Could not start the game process.")))
	_generation += 1
	var now := Time.get_ticks_msec()
	_active = {
		"generation": _generation,
		"run_id": _generation,
		"sequence": 1,
		"pid": int(launched["pid"]),
		"stdio": launched["stdio"],
		"stderr": launched["stderr"],
		"run_kind": run_kind,
		"scene_path": canonical_path,
		"started_at_ms": now,
		"deadline_ms": now + RUN_TIMEOUT_MS,
		"stdout": PackedByteArray(),
		"stderr_bytes": PackedByteArray(),
		"stdout_parser": {"pending": PackedByteArray(), "pending_record": -1},
		"stderr_parser": {"pending": PackedByteArray(), "pending_record": -1},
		"diagnostics": [],
		"diagnostics_truncated": false,
		"dropped_bytes": 0,
		"state": "running",
		"verification": normalized_verification,
		"criteria_id": _criteria_id(normalized_verification)
	}
	_last_snapshot = _snapshot_active()
	run_state_changed.emit(_last_snapshot.duplicate(true))
	return _success("Started %s %s as Orca run %d. A bounded observation will follow; use observe_game_run or get_diagnostics for later evidence." % ["the current scene" if run_kind == "current_scene" else "the main scene", canonical_path, int(_last_snapshot.get("run_id", 0))], _public_run_data(_last_snapshot))


func stop_game() -> Dictionary:
	poll()
	if not is_running():
		return _failure("No Orca-started game process is running.")
	var pid := int(_active.get("pid", -1))
	if pid <= 0 or not _is_process_running(pid):
		_finalize_natural_exit()
		return _failure("The Orca-started game had already exited.")
	var kill_error := _kill_process(pid)
	if kill_error != OK:
		return _failure("Godot could not stop the Orca-owned game process: " + error_string(kill_error))
	_finalize("stopped", null, "Stopped by Orca.")
	return _success("Stopped the Orca-started game process.", _public_run_data(_last_snapshot))


func poll() -> void:
	if _active.is_empty():
		return
	_drain_pipe("stdio", "stdout")
	_drain_pipe("stderr", "stderr_bytes")
	var pid := int(_active.get("pid", -1))
	if pid <= 0 or not _is_process_running(pid):
		_drain_pipe("stdio", "stdout")
		_drain_pipe("stderr", "stderr_bytes")
		_finalize_natural_exit()
		return
	if str(_active.get("state", "")) != "timeout_stop_failed" and Time.get_ticks_msec() >= int(_active.get("deadline_ms", 0)):
		var kill_error := _kill_process(pid)
		if kill_error == OK:
			_finalize("timed_out", null, "The %d ms wall-clock timeout expired." % RUN_TIMEOUT_MS)
		else:
			_active["state"] = "timeout_stop_failed"
			_active["message"] = "The wall-clock timeout expired, but Godot could not stop the owned process: " + error_string(kill_error)
			_increment_sequence()
			_last_snapshot = _snapshot_active()
			run_state_changed.emit(_last_snapshot.duplicate(true))


func is_running() -> bool:
	return not _active.is_empty() and int(_active.get("pid", -1)) > 0 and _is_process_running(int(_active["pid"]))


func get_snapshot() -> Dictionary:
	poll()
	return (_snapshot_active() if not _active.is_empty() else _last_snapshot).duplicate(true)


func observe_run(run_id: int, after_sequence: int = -1) -> Dictionary:
	var snapshot := get_snapshot()
	if run_id <= 0 or int(snapshot.get("run_id", 0)) != run_id:
		return {"success": false, "error": "The requested run_id is not the active or latest Orca run."}
	return {"success": true, "snapshot": snapshot, "changed_since": after_sequence < 0 or int(snapshot.get("sequence", 0)) > after_sequence}


func verify_run(run_id: int) -> Dictionary:
	var observed := observe_run(run_id)
	if not observed.get("success", false):
		return observed
	return {"success": true, "verification": _evaluate_verification(observed["snapshot"])}


func criteria_id_for(verification: Dictionary) -> Dictionary:
	var normalized := _normalize_verification(verification)
	if not normalized.get("success", false):
		return normalized
	return {"success": true, "criteria_id": _criteria_id(normalized.get("verification", {}))}


func shutdown() -> bool:
	if _active.is_empty():
		return true
	var pid := int(_active.get("pid", -1))
	if pid > 0 and _is_process_running(pid):
		var kill_error := _kill_process(pid)
		if kill_error != OK:
			_active["state"] = "shutdown_stop_failed"
			_active["message"] = "Orca could not stop its owned game process during shutdown: " + error_string(kill_error)
			_increment_sequence()
			_last_snapshot = _snapshot_active()
			run_state_changed.emit(_last_snapshot.duplicate(true))
			push_warning(str(_active["message"]))
			return false
	_finalize("stopped", null, "Stopped during Orca plugin shutdown.")
	return true


func _drain_pipe(pipe_key: String, buffer_key: String) -> void:
	var pipe = _active.get(pipe_key)
	if not pipe is FileAccess or not pipe.is_open():
		return
	var available := maxi(0, int(pipe.get_length()))
	var remaining_budget := mini(available, MAX_DRAIN_BYTES_PER_STREAM_FRAME)
	while remaining_budget > 0:
		var chunk: PackedByteArray = pipe.get_buffer(remaining_budget)
		if chunk.is_empty():
			break
		remaining_budget -= chunk.size()
		_retain_output(buffer_key, chunk)


func _retain_output(buffer_key: String, chunk: PackedByteArray) -> void:
	if buffer_key not in ["stdout", "stderr_bytes"]:
		return
	var retained: PackedByteArray = _active.get(buffer_key, PackedByteArray())
	var retain_count := mini(chunk.size(), maxi(0, MAX_RETAINED_STREAM_BYTES - retained.size()))
	if retain_count > 0:
		retained.append_array(chunk.slice(0, retain_count))
		_active[buffer_key] = retained
	_active["dropped_bytes"] = int(_active.get("dropped_bytes", 0)) + chunk.size() - retain_count
	_feed_diagnostic_bytes(buffer_key, chunk)
	_increment_sequence()


func _finalize_natural_exit() -> void:
	var pid := int(_active.get("pid", -1))
	var exit_code = _get_process_exit_code(pid) if pid > 0 else null
	_finalize("exited", exit_code, "Game process exited.")


func _finalize(state: String, exit_code, message: String) -> void:
	if _active.is_empty():
		return
	_drain_pipe("stdio", "stdout")
	_drain_pipe("stderr", "stderr_bytes")
	_mark_undrained_output("stdio")
	_mark_undrained_output("stderr")
	_flush_diagnostic_parser("stdout")
	_flush_diagnostic_parser("stderr_bytes")
	_active["state"] = state
	_active["exit_code"] = exit_code
	_active["message"] = message
	_increment_sequence()
	_last_snapshot = _snapshot_active()
	_close_pipe(_active.get("stdio"))
	_close_pipe(_active.get("stderr"))
	_active.clear()
	run_state_changed.emit(_last_snapshot.duplicate(true))


func _mark_undrained_output(pipe_key: String) -> void:
	var pipe = _active.get(pipe_key)
	if pipe is FileAccess and pipe.is_open():
		_active["dropped_bytes"] = int(_active.get("dropped_bytes", 0)) + maxi(0, int(pipe.get_length()))


func _snapshot_active() -> Dictionary:
	if _active.is_empty():
		return _last_snapshot.duplicate(true)
	var stdout_result := _bounded_text(_active.get("stdout", PackedByteArray()))
	var stderr_result := _bounded_text(_active.get("stderr_bytes", PackedByteArray()))
	var stdout := str(stdout_result.get("text", ""))
	var stderr := str(stderr_result.get("text", ""))
	var now := Time.get_ticks_msec()
	var snapshot := {
		"run_id": int(_active.get("run_id", 0)),
		"sequence": int(_active.get("sequence", 0)),
		"state": str(_active.get("state", "running")),
		"run_kind": str(_active.get("run_kind", "")),
		"scene_path": str(_active.get("scene_path", "")),
		"started_at_ms": int(_active.get("started_at_ms", 0)),
		"elapsed_ms": maxi(0, now - int(_active.get("started_at_ms", now))),
		"exit_code": _active.get("exit_code"),
		"message": str(_active.get("message", "")),
		"stdout": stdout,
		"stderr": stderr,
		"diagnostics": _active.get("diagnostics", []).duplicate(true),
		"diagnostics_truncated": bool(_active.get("diagnostics_truncated", false)),
		"output_truncated": int(_active.get("dropped_bytes", 0)) > 0 or bool(stdout_result.get("truncated", false)) or bool(stderr_result.get("truncated", false)),
		"dropped_bytes": int(_active.get("dropped_bytes", 0)),
		"criteria_id": str(_active.get("criteria_id", "")),
		"verification_configured": not _active.get("verification", {}).is_empty(),
		"verification": _active.get("verification", {}).duplicate(true)
	}
	var verification_status := str(_evaluate_verification(snapshot, _active.get("verification", {})).get("status", "unverified"))
	var previous_verification_status := str(_active.get("last_verification_status", ""))
	if not previous_verification_status.is_empty() and previous_verification_status != verification_status:
		_increment_sequence()
		snapshot["sequence"] = int(_active.get("sequence", 0))
	_active["last_verification_status"] = verification_status
	snapshot["verification_status"] = verification_status
	return snapshot


func _bounded_text(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty():
		return {"text": "", "truncated": false}
	var lines := bytes.get_string_from_utf8().replace("\r\n", "\n").split("\n")
	var rendered := PackedStringArray()
	var truncated := lines.size() > MAX_OUTPUT_LINES
	for index in range(mini(lines.size(), MAX_OUTPUT_LINES)):
		var line := str(lines[index])
		truncated = truncated or line.length() > MAX_LINE_CHARS
		rendered.append(line.left(MAX_LINE_CHARS))
	return {"text": "\n".join(rendered), "truncated": truncated}


func _feed_diagnostic_bytes(buffer_key: String, chunk: PackedByteArray) -> void:
	var parser_key := "stdout_parser" if buffer_key == "stdout" else "stderr_parser"
	var parser: Dictionary = _active.get(parser_key, {"pending": PackedByteArray(), "pending_record": -1})
	var pending: PackedByteArray = parser.get("pending", PackedByteArray())
	pending.append_array(chunk)
	var line_start := 0
	for index in range(pending.size()):
		if pending[index] != 10:
			continue
		var line_bytes := pending.slice(line_start, index)
		if not line_bytes.is_empty() and line_bytes[-1] == 13:
			line_bytes.resize(line_bytes.size() - 1)
		_parse_diagnostic_line("stdout" if buffer_key == "stdout" else "stderr", line_bytes.get_string_from_utf8(), parser)
		line_start = index + 1
	if line_start > 0:
		pending = pending.slice(line_start)
	if pending.size() > MAX_DIAGNOSTIC_LINE_BYTES:
		pending = pending.slice(pending.size() - MAX_DIAGNOSTIC_LINE_BYTES)
		_active["diagnostics_truncated"] = true
	parser["pending"] = pending
	_active[parser_key] = parser


func _flush_diagnostic_parser(buffer_key: String) -> void:
	var parser_key := "stdout_parser" if buffer_key == "stdout" else "stderr_parser"
	var parser: Dictionary = _active.get(parser_key, {})
	var pending: PackedByteArray = parser.get("pending", PackedByteArray())
	if not pending.is_empty():
		_parse_diagnostic_line("stdout" if buffer_key == "stdout" else "stderr", pending.get_string_from_utf8(), parser)
		parser["pending"] = PackedByteArray()
		_active[parser_key] = parser


func _parse_diagnostic_line(stream: String, raw_line: String, parser: Dictionary) -> void:
	var line := raw_line.strip_edges()
	var severity := ""
	if line.begins_with("SCRIPT ERROR:") or line.begins_with("ERROR:") or line.begins_with("USER ERROR:"):
		severity = "error"
	elif line.begins_with("SCRIPT WARNING:") or line.begins_with("WARNING:"):
		severity = "warning"
	if not severity.is_empty():
		var diagnostics: Array = _active.get("diagnostics", [])
		if diagnostics.size() >= MAX_DIAGNOSTICS:
			_active["diagnostics_truncated"] = true
			parser["pending_record"] = -1
			return
		var record := {"origin": "game", "source": "process_output", "stream": stream, "severity": severity, "file": "", "line": 0, "function": "", "message": line.left(MAX_LINE_CHARS)}
		var location := _safe_location(line)
		if not location.is_empty():
			record.merge(location, true)
		diagnostics.append(record)
		_active["diagnostics"] = diagnostics
		parser["pending_record"] = diagnostics.size() - 1
		return
	var pending_index := int(parser.get("pending_record", -1))
	if pending_index >= 0 and (line.begins_with("at:") or line.begins_with("[")):
		var diagnostics: Array = _active.get("diagnostics", [])
		if pending_index < diagnostics.size():
			var location := _safe_location(line)
			if not location.is_empty():
				var record: Dictionary = diagnostics[pending_index]
				record.merge(location, true)
				var location_start := line.find("(")
				if location_start > 0:
					var function_name := line.substr(0, location_start).trim_prefix("at:").strip_edges()
					if function_name.begins_with("[") and function_name.contains("]"):
						function_name = function_name.substr(function_name.find("]") + 1).strip_edges()
					record["function"] = function_name.left(256)
				diagnostics[pending_index] = record
				_active["diagnostics"] = diagnostics
				parser["pending_record"] = -1
				return
		return
	if pending_index >= 0 and line.begins_with("GDScript backtrace"):
		return
	parser["pending_record"] = -1


func _safe_location(line: String) -> Dictionary:
	var start := line.find("res://")
	if start < 0:
		return {}
	var end := line.find(")", start)
	if end < 0:
		end = line.length()
	var candidate := line.substr(start, end - start)
	var separator := candidate.rfind(":")
	var line_number := 0
	if separator > 5 and candidate.substr(separator + 1).is_valid_int():
		line_number = int(candidate.substr(separator + 1))
		candidate = candidate.substr(0, separator)
	var canonical := _canonical_res_path(candidate)
	if not _validate_project_path(canonical).is_empty() or not FileAccess.file_exists(canonical):
		return {}
	return {"file": canonical, "line": line_number}


func _normalize_verification(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {"success": true, "verification": {}}
	var allowed := ["kind", "claim", "minimum_runtime_ms", "expected_exit_code", "required_stdout", "forbidden_output", "require_no_runtime_errors"]
	for key in raw:
		if str(key) not in allowed:
			return {"success": false, "error": "Unknown verification field: " + str(key)}
	if typeof(raw.get("kind")) != TYPE_STRING or str(raw.get("kind", "")) not in ["clean_startup", "expected_exit"]:
		return {"success": false, "error": "verification.kind must be clean_startup or expected_exit."}
	if raw.has("claim") and (typeof(raw["claim"]) != TYPE_STRING or str(raw["claim"]).strip_edges().is_empty() or str(raw["claim"]).length() > MAX_VERIFICATION_CLAIM_CHARS):
		return {"success": false, "error": "verification.claim must contain 1-%d characters." % MAX_VERIFICATION_CLAIM_CHARS}
	if raw.has("require_no_runtime_errors") and typeof(raw["require_no_runtime_errors"]) != TYPE_BOOL:
		return {"success": false, "error": "require_no_runtime_errors must be a boolean."}
	var required_result := _normalize_markers(raw.get("required_stdout", []), "required_stdout")
	if not required_result.get("success", false):
		return required_result
	var forbidden_result := _normalize_markers(raw.get("forbidden_output", []), "forbidden_output")
	if not forbidden_result.get("success", false):
		return forbidden_result
	var kind := str(raw["kind"])
	var normalized := {
		"kind": kind,
		"claim": str(raw.get("claim", "Startup verification" if kind == "clean_startup" else "Expected process exit")),
		"required_stdout": required_result.get("markers", []),
		"forbidden_output": forbidden_result.get("markers", []),
		"require_no_runtime_errors": bool(raw.get("require_no_runtime_errors", true))
	}
	if kind == "clean_startup":
		if raw.has("expected_exit_code"):
			return {"success": false, "error": "clean_startup does not accept expected_exit_code."}
		if raw.has("minimum_runtime_ms") and typeof(raw["minimum_runtime_ms"]) != TYPE_INT:
			return {"success": false, "error": "minimum_runtime_ms must be an integer."}
		var minimum_runtime_ms := int(raw.get("minimum_runtime_ms", 1500))
		if minimum_runtime_ms < MIN_STARTUP_VERIFICATION_MS or minimum_runtime_ms > MAX_STARTUP_VERIFICATION_MS:
			return {"success": false, "error": "minimum_runtime_ms must be between %d and %d." % [MIN_STARTUP_VERIFICATION_MS, MAX_STARTUP_VERIFICATION_MS]}
		normalized["minimum_runtime_ms"] = minimum_runtime_ms
	else:
		if raw.has("minimum_runtime_ms"):
			return {"success": false, "error": "expected_exit does not accept minimum_runtime_ms."}
		if typeof(raw.get("expected_exit_code")) != TYPE_INT or int(raw["expected_exit_code"]) < -255 or int(raw["expected_exit_code"]) > 255:
			return {"success": false, "error": "expected_exit requires expected_exit_code between -255 and 255."}
		normalized["expected_exit_code"] = int(raw["expected_exit_code"])
	return {"success": true, "verification": normalized}


func _normalize_markers(raw, field_name: String) -> Dictionary:
	if typeof(raw) != TYPE_ARRAY or raw.size() > MAX_VERIFICATION_MARKERS:
		return {"success": false, "error": "%s must be an array of at most %d strings." % [field_name, MAX_VERIFICATION_MARKERS]}
	var markers: Array[String] = []
	for marker in raw:
		if typeof(marker) != TYPE_STRING or str(marker).is_empty() or str(marker).length() > MAX_VERIFICATION_MARKER_CHARS:
			return {"success": false, "error": "%s markers must contain 1-%d characters." % [field_name, MAX_VERIFICATION_MARKER_CHARS]}
		if str(marker) in markers:
			return {"success": false, "error": field_name + " cannot contain duplicate markers."}
		markers.append(str(marker))
	return {"success": true, "markers": markers}


func _criteria_id(verification: Dictionary) -> String:
	return "" if verification.is_empty() else JSON.stringify(verification).sha256_text()


func _evaluate_verification(snapshot: Dictionary, criteria = null) -> Dictionary:
	var spec: Dictionary = snapshot.get("verification", {}) if criteria == null else criteria
	var run_id := int(snapshot.get("run_id", 0))
	if spec.is_empty():
		return {"run_id": run_id, "criteria_id": "", "status": "unverified", "claim": "", "scope": "none", "checks": [], "message": "No verification criteria were declared before this run."}
	var checks: Array = []
	var state := str(snapshot.get("state", "idle"))
	var output := str(snapshot.get("stdout", "")) + "\n" + str(snapshot.get("stderr", ""))
	var truncated := bool(snapshot.get("output_truncated", false)) or bool(snapshot.get("diagnostics_truncated", false))
	var base_status := "pending"
	var scope := "startup_only" if str(spec.get("kind", "")) == "clean_startup" else "process_exit"
	if str(spec.get("kind", "")) == "clean_startup":
		var required_runtime := int(spec.get("minimum_runtime_ms", 1500))
		var elapsed := int(snapshot.get("elapsed_ms", 0))
		if state == "exited" and snapshot.get("exit_code") != 0:
			base_status = "failed"
		elif state in ["running", "exited"] and elapsed >= required_runtime:
			base_status = "passed"
		elif state == "running":
			base_status = "pending"
		else:
			base_status = "failed"
		checks.append({"name": "minimum_runtime_ms", "status": base_status, "expected": required_runtime, "observed": elapsed})
	else:
		var expected_code := int(spec.get("expected_exit_code", 0))
		if state == "running":
			base_status = "pending"
		elif state == "exited" and snapshot.get("exit_code") == expected_code:
			base_status = "passed"
		else:
			base_status = "failed"
		checks.append({"name": "expected_exit_code", "status": base_status, "expected": expected_code, "observed": snapshot.get("exit_code")})
	var aggregate := base_status
	for marker in spec.get("required_stdout", []):
		var marker_status := "passed" if str(snapshot.get("stdout", "")).contains(str(marker)) else "pending" if state == "running" else "inconclusive" if truncated else "failed"
		checks.append({"name": "required_stdout", "status": marker_status, "expected": marker, "observed": marker_status == "passed"})
		aggregate = _combine_verification_status(aggregate, marker_status)
	for marker in spec.get("forbidden_output", []):
		var marker_status := "failed" if output.contains(str(marker)) else "pending" if state == "running" and base_status == "pending" else "inconclusive" if truncated else "passed"
		checks.append({"name": "forbidden_output", "status": marker_status, "expected": marker, "observed": output.contains(str(marker))})
		aggregate = _combine_verification_status(aggregate, marker_status)
	if bool(spec.get("require_no_runtime_errors", true)):
		var error_count := 0
		for diagnostic in snapshot.get("diagnostics", []):
			if str(diagnostic.get("severity", "error")) == "error":
				error_count += 1
		var error_status := "failed" if error_count > 0 else "pending" if state == "running" and base_status == "pending" else "inconclusive" if truncated else "passed"
		checks.append({"name": "runtime_errors", "status": error_status, "expected": 0, "observed": error_count})
		aggregate = _combine_verification_status(aggregate, error_status)
	return {"run_id": run_id, "run_kind": str(snapshot.get("run_kind", "")), "scene_path": str(snapshot.get("scene_path", "")), "criteria_id": str(snapshot.get("criteria_id", _criteria_id(spec))), "status": aggregate, "claim": str(spec.get("claim", "")), "scope": scope, "checks": checks, "output_truncated": bool(snapshot.get("output_truncated", false)), "diagnostics_truncated": bool(snapshot.get("diagnostics_truncated", false)), "message": _verification_message(aggregate, scope)}


func _combine_verification_status(current: String, next: String) -> String:
	for status in ["failed", "inconclusive", "pending", "passed"]:
		if current == status or next == status:
			return status
	return "inconclusive"


func _verification_message(status: String, scope: String) -> String:
	match status:
		"passed":
			return "The predeclared %s criterion passed. This is not general gameplay verification." % scope.replace("_", " ")
		"failed":
			return "The predeclared verification criterion failed."
		"pending":
			return "The verification criterion is not yet evaluable."
		"inconclusive":
			return "The retained evidence is incomplete, so the criterion is inconclusive."
	return "No verification criterion was configured."


func _increment_sequence() -> void:
	if not _active.is_empty():
		_active["sequence"] = int(_active.get("sequence", 0)) + 1


func _validate_scene_path(scene_path: String) -> String:
	var path_error := _validate_project_path(scene_path)
	if not path_error.is_empty():
		return path_error
	var scene_error := MainSceneProposal.validate_scene(scene_path)
	return scene_error.replace("proposed main scene", "run target").replace("main scene proposal", "game runner")


func _validate_project_path(path: String) -> String:
	if path.is_empty() or not path.begins_with("res://") or _canonical_res_path(path) != path:
		return "The run target must be a canonical res:// path."
	var relative := path.trim_prefix("res://")
	if relative == "addons/orca" or relative.begins_with("addons/orca/"):
		return "Orca cannot run scenes from its own plugin directory."
	var project_root := ProjectSettings.globalize_path("res://").simplify_path()
	var current := project_root
	for component in relative.split("/", false):
		var parent := DirAccess.open(current)
		if parent != null and parent.is_link(component):
			return "Run targets containing symbolic links are blocked."
		current = current.path_join(component)
	return ""


func _canonical_res_path(path: String) -> String:
	if not path.begins_with("res://"):
		return ""
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())


func _public_run_data(snapshot: Dictionary) -> Dictionary:
	var data := snapshot.duplicate(true)
	data.erase("stdout")
	data.erase("stderr")
	data.erase("diagnostics")
	data.erase("verification")
	return data


func _idle_snapshot() -> Dictionary:
	return {"run_id": 0, "sequence": 0, "state": "idle", "run_kind": "", "scene_path": "", "started_at_ms": 0, "elapsed_ms": 0, "exit_code": null, "message": "No Orca-started game has run in this plugin session.", "stdout": "", "stderr": "", "diagnostics": [], "diagnostics_truncated": false, "output_truncated": false, "dropped_bytes": 0, "criteria_id": "", "verification_configured": false, "verification": {}, "verification_status": "unverified"}


func _failed_snapshot(run_kind: String, scene_path: String, message: String) -> Dictionary:
	var snapshot := _idle_snapshot()
	snapshot.merge({"state": "launch_failed", "run_kind": run_kind, "scene_path": scene_path, "message": message}, true)
	return snapshot


func _success(content: String, data: Dictionary = {}) -> Dictionary:
	return {"success": true, "content": content, "outcome": "completed", "data": data}


func _failure(message: String) -> Dictionary:
	return {"success": false, "content": "Error: " + message, "outcome": "failed", "data": {}}


func _close_pipe(pipe) -> void:
	if pipe is FileAccess and pipe.is_open():
		pipe.close()


func _launch_process(executable: String, arguments: PackedStringArray) -> Dictionary:
	return OS.execute_with_pipe(executable, arguments, false)


func _is_process_running(pid: int) -> bool:
	return OS.is_process_running(pid)


func _get_process_exit_code(pid: int) -> int:
	return OS.get_process_exit_code(pid)


func _kill_process(pid: int) -> Error:
	return OS.kill(pid)


func _get_executable_path() -> String:
	return OS.get_executable_path()
