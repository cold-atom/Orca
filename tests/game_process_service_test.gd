extends SceneTree

const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const DIAGNOSTIC_SCRIPT_PATH := "res://tests/fixtures/game_process_child.gd"

class FakeGameProcessService extends GameProcessService:
	var running := false
	var killed_pids: Array[int] = []
	var launch_arguments := PackedStringArray()
	var launch_should_fail := false
	var exit_code := 0
	var kill_error := OK
	var stdout_path := ""
	var stderr_path := ""

	func _launch_process(_executable: String, arguments: PackedStringArray) -> Dictionary:
		launch_arguments = arguments.duplicate()
		if launch_should_fail:
			return {}
		running = true
		return {"pid": 4242, "stdio": FileAccess.open(stdout_path, FileAccess.READ), "stderr": FileAccess.open(stderr_path, FileAccess.READ)}

	func _is_process_running(_pid: int) -> bool:
		return running

	func _get_process_exit_code(_pid: int) -> int:
		return exit_code

	func _kill_process(pid: int) -> Error:
		killed_pids.append(pid)
		if kill_error == OK:
			running = false
		return kill_error

	func _get_executable_path() -> String:
		return "/test/godot"

	func _drain_pipe(_pipe_key: String, _buffer_key: String) -> void:
		pass

	func _mark_undrained_output(_pipe_key: String) -> void:
		pass


class RealHeadlessGameProcessService extends GameProcessService:
	func _launch_process(executable: String, _arguments: PackedStringArray) -> Dictionary:
		return OS.execute_with_pipe(executable, PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/fixtures/game_process_child.gd"]), false)


var _failures := PackedStringArray()
var _fixture_directory := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_directory = "res://.orca_game_process_test_%d" % Time.get_ticks_usec()
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_directory)) == OK, "fixture directory should be created")
	var scene_path := _fixture_directory.path_join("run.tscn")
	var stdout_path := _fixture_directory.path_join("stdout.txt")
	var stderr_path := _fixture_directory.path_join("stderr.txt")
	_write(scene_path, "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n")
	_write(stdout_path, "")
	_write(stderr_path, "")
	_test_launch_stop_and_ownership(scene_path, stdout_path, stderr_path)
	_test_main_scene_resolution(scene_path, stdout_path, stderr_path)
	_test_exit_timeout_and_failure(scene_path, stdout_path, stderr_path)
	_test_output_bounds_and_diagnostics(scene_path, stdout_path, stderr_path)
	_test_verification_contract(scene_path, stdout_path, stderr_path)
	await _test_real_nonblocking_process(scene_path)
	_remove_tree(ProjectSettings.globalize_path(_fixture_directory))
	_finish()


func _test_launch_stop_and_ownership(scene_path: String, stdout_path: String, stderr_path: String) -> void:
	var service := _service(stdout_path, stderr_path)
	var started := service.start_scene("current_scene", scene_path)
	_expect(started.get("success", false), "a valid saved scene should start")
	_expect(service.launch_arguments == PackedStringArray(["--path", ProjectSettings.globalize_path("res://"), "--scene", scene_path]), "launch arguments must be internally fixed to project and scene paths")
	_expect(not started.get("data", {}).has("pid"), "public launch results must not expose the owned PID")
	_expect(not service.start_scene("current_scene", scene_path).get("success", true), "a second Orca run should be rejected")
	var stopped := service.stop_game()
	_expect(stopped.get("success", false) and service.killed_pids == [4242], "stop should kill exactly the retained Orca-owned PID")
	_expect(service.get_snapshot().get("state") == "stopped", "successful stop should retain a bounded stopped snapshot")
	_expect(not service.stop_game().get("success", true) and service.killed_pids.size() == 1, "stop without ownership must not kill another process")
	service.free()


func _test_main_scene_resolution(scene_path: String, stdout_path: String, stderr_path: String) -> void:
	var setting_path := "application/run/main_scene"
	var previous = ProjectSettings.get_setting(setting_path, null)
	ProjectSettings.set_setting(setting_path, scene_path)
	var service := _service(stdout_path, stderr_path)
	var started := service.start_main_scene()
	_expect(started.get("success", false) and started.get("data", {}).get("scene_path") == scene_path, "run_main_scene should resolve the active ProjectSettings value")
	_expect(service.launch_arguments.has("--scene") and service.launch_arguments[-1] == scene_path, "main-scene launch should force the resolved active target")
	service.stop_game()
	service.free()
	ProjectSettings.set_setting(setting_path, previous)


func _test_exit_timeout_and_failure(scene_path: String, stdout_path: String, stderr_path: String) -> void:
	var service := _service(stdout_path, stderr_path)
	_expect(service.start_scene("main_scene", scene_path).get("success", false), "main-scene kind should start a fixed project run")
	service.exit_code = 7
	service.running = false
	service.poll()
	var exited := service.get_snapshot()
	_expect(exited.get("state") == "exited" and exited.get("exit_code") == 7, "natural exit should retain the child exit code")
	_expect(service.killed_pids.is_empty(), "natural exit must not call kill")
	_expect(service.start_scene("current_scene", scene_path).get("success", false), "a new run should be allowed after natural exit")
	service._active["deadline_ms"] = Time.get_ticks_msec() - 1
	service.poll()
	_expect(service.get_snapshot().get("state") == "timed_out" and service.killed_pids == [4242], "wall-clock timeout should stop only the owned PID")
	service.free()

	service = _service(stdout_path, stderr_path)
	service.kill_error = ERR_BUSY
	_expect(service.start_scene("current_scene", scene_path).get("success", false), "timeout failure fixture should start")
	service._active["deadline_ms"] = Time.get_ticks_msec() - 1
	service.poll()
	_expect(service.get_snapshot().get("state") == "timeout_stop_failed" and service.is_running(), "failed timeout termination must retain ownership of the still-running process")
	service.kill_error = OK
	_expect(service.stop_game().get("success", false) and service.killed_pids.size() == 2, "a retained timeout failure should remain stoppable")
	service.free()

	service = _service(stdout_path, stderr_path)
	service.kill_error = ERR_BUSY
	_expect(service.start_scene("current_scene", scene_path).get("success", false), "shutdown failure fixture should start")
	_expect(not service.shutdown() and service.get_snapshot().get("state") == "shutdown_stop_failed" and service.is_running(), "failed shutdown termination must not falsely report stopped or discard ownership")
	service.running = false
	service.poll()
	service.free()

	service = _service(stdout_path, stderr_path)
	service.launch_should_fail = true
	_expect(not service.start_scene("current_scene", scene_path).get("success", true), "launch failures should return a failed tool result")
	_expect(service.get_snapshot().get("state") == "launch_failed", "launch failure should remain visible in diagnostics")
	service.free()


func _test_output_bounds_and_diagnostics(scene_path: String, stdout_path: String, stderr_path: String) -> void:
	var service := _service(stdout_path, stderr_path)
	_expect(service.start_scene("current_scene", scene_path).get("success", false), "output fixture should start")
	var long_output := PackedByteArray()
	long_output.resize(GameProcessService.MAX_RETAINED_OUTPUT_BYTES)
	long_output.fill(65)
	service._retain_output("stdout", long_output)
	service._retain_output("stderr_bytes", ("SCRIPT ERROR: failure at: test (%s:2)\n" % DIAGNOSTIC_SCRIPT_PATH).to_utf8_buffer())
	var snapshot := service.get_snapshot()
	_expect(snapshot.get("output_truncated", false) and snapshot.get("dropped_bytes") > 0, "retained output bounds should report truncation and dropped bytes")
	_expect(str(snapshot.get("stdout", "")).length() <= GameProcessService.MAX_LINE_CHARS, "individual retained output lines should be bounded")
	var diagnostics: Array = snapshot.get("diagnostics", [])
	_expect(diagnostics.size() == 1 and diagnostics[0].get("file") == DIAGNOSTIC_SCRIPT_PATH and diagnostics[0].get("line") == 2, "stderr must retain runtime diagnostics even after stdout fills its independent quota")
	service.shutdown()
	service.free()


func _test_verification_contract(scene_path: String, stdout_path: String, stderr_path: String) -> void:
	var service := _service(stdout_path, stderr_path)
	_expect(not service.start_scene("current_scene", scene_path, {"kind": "unknown"}).get("success", true), "unknown verification kinds should fail before launch")
	_expect(not service.start_scene("current_scene", scene_path, {"kind": "expected_exit"}).get("success", true), "expected_exit should require an exit code")
	var criteria := {"kind": "clean_startup", "claim": "Starts cleanly", "minimum_runtime_ms": 500, "required_stdout": ["READY"], "forbidden_output": ["FATAL"], "require_no_runtime_errors": true}
	var started := service.start_scene("current_scene", scene_path, criteria)
	var run_id := int(started.get("data", {}).get("run_id", 0))
	_expect(run_id > 0 and not str(started.get("data", {}).get("criteria_id", "")).is_empty(), "configured runs should expose bounded run and criteria identities without PID")
	_expect(service.verify_run(run_id).get("verification", {}).get("status") == "pending", "startup verification should remain pending before runtime and markers are observed")
	service._retain_output("stdout", "READY\n".to_utf8_buffer())
	service._active["started_at_ms"] = Time.get_ticks_msec() - 600
	var passed: Dictionary = service.verify_run(run_id).get("verification", {})
	_expect(passed.get("status") == "passed" and passed.get("scope") == "startup_only", "clean startup should pass only its predeclared scoped criterion")
	var observation := service.observe_run(run_id, 1)
	_expect(observation.get("success", false) and observation.get("changed_since", false), "observation cursors should report sequence changes")
	var stopped := service.stop_game()
	_expect(str(stopped.get("content", "")).contains("Final run") and str(stopped.get("content", "")).contains("Final stdout:\nREADY"), "stop should return bounded final run evidence without requiring a diagnostics round")
	_expect(stopped.get("data", {}).get("stdout") == "READY\n" and stopped.get("data", {}).has("diagnostics"), "stop data should retain bounded final output and diagnostics without exposing process ownership internals")
	var truncated_snapshot := service.get_snapshot()
	truncated_snapshot["output_truncated"] = true
	truncated_snapshot["dropped_bytes"] = 42
	truncated_snapshot["stdout"] = "x".repeat(GameProcessService.MAX_STOP_OUTPUT_CHARS + 1)
	var many_diagnostics: Array = []
	for index in range(GameProcessService.MAX_STOP_DIAGNOSTICS + 1):
		many_diagnostics.append({"severity": "error", "message": "diagnostic %d" % index, "file": "res://fixture.gd", "line": index + 1})
	truncated_snapshot["diagnostics"] = many_diagnostics
	var bounded_data: Dictionary = service._final_run_data(truncated_snapshot)
	var bounded_text: String = service._format_stop_evidence(truncated_snapshot)
	_expect(bounded_data.get("diagnostics_truncated", false) and bounded_data.get("output_truncated", false), "bounded final stop data should disclose diagnostic and output truncation introduced by its own limits")
	_expect(bounded_text.contains("shown; truncated") and bounded_text.contains("Output is truncated") and bounded_text.contains("Final stdout tail (truncated)"), "model-facing stop evidence should label incomplete diagnostic and output tails explicitly")
	var aggregate_snapshot := truncated_snapshot.duplicate(true)
	var verbose_diagnostics: Array = []
	for index in range(GameProcessService.MAX_STOP_DIAGNOSTICS):
		verbose_diagnostics.append({"severity": "error", "message": "m".repeat(500), "file": "res://fixture.gd", "line": index + 1})
	aggregate_snapshot["diagnostics"] = verbose_diagnostics
	aggregate_snapshot["stderr"] = "e".repeat(GameProcessService.MAX_STOP_OUTPUT_CHARS)
	var aggregate_text: String = service._format_stop_evidence(aggregate_snapshot)
	_expect(aggregate_text.length() <= GameProcessService.MAX_STOP_CONTENT_CHARS and aggregate_text.ends_with("[Final stop evidence truncated to the response limit.]"), "aggregate stop-evidence truncation should retain an explicit terminal marker")

	var exit_criteria := {"kind": "expected_exit", "claim": "Fixture exits as expected", "expected_exit_code": 7, "require_no_runtime_errors": false}
	started = service.start_scene("current_scene", scene_path, exit_criteria)
	run_id = int(started.get("data", {}).get("run_id", 0))
	_expect(service.verify_run(run_id).get("verification", {}).get("status") == "pending", "expected-exit verification should wait for natural exit")
	service.exit_code = 7
	service.running = false
	service.poll()
	_expect(service.verify_run(run_id).get("verification", {}).get("status") == "passed", "matching natural exit should pass predeclared expected-exit criteria")
	_expect(not service.observe_run(run_id - 1).get("success", true), "stale run IDs should not observe a newer retained run")

	started = service.start_scene("current_scene", scene_path, {"kind": "clean_startup", "minimum_runtime_ms": 250, "require_no_runtime_errors": false})
	run_id = int(started.get("data", {}).get("run_id", 0))
	service._active["started_at_ms"] = Time.get_ticks_msec() - 300
	service.exit_code = 1
	service.running = false
	service.poll()
	_expect(service.verify_run(run_id).get("verification", {}).get("status") == "failed", "clean-startup verification must not pass after a nonzero process exit")

	started = service.start_scene("current_scene", scene_path, {"kind": "clean_startup", "minimum_runtime_ms": 250, "require_no_runtime_errors": true})
	run_id = int(started.get("data", {}).get("run_id", 0))
	service._retain_output("stderr_bytes", ("SCRIPT ERROR: broken\n          at: _ready (%s:2)\n" % DIAGNOSTIC_SCRIPT_PATH).to_utf8_buffer())
	service._active["started_at_ms"] = Time.get_ticks_msec() - 300
	var failed: Dictionary = service.verify_run(run_id).get("verification", {})
	_expect(failed.get("status") == "failed", "observed runtime errors should fail no-error criteria")
	var diagnostics: Array = service.get_snapshot().get("diagnostics", [])
	_expect(diagnostics.size() == 1 and diagnostics[0].get("file") == DIAGNOSTIC_SCRIPT_PATH and diagnostics[0].get("function") == "_ready", "multiline Godot at-lines should attach safe location and function metadata")
	service.stop_game()

	started = service.start_scene("current_scene", scene_path, {"kind": "clean_startup", "minimum_runtime_ms": 250, "forbidden_output": ["FATAL"], "require_no_runtime_errors": true})
	run_id = int(started.get("data", {}).get("run_id", 0))
	service._active["started_at_ms"] = Time.get_ticks_msec() - 300
	service._active["dropped_bytes"] = 1
	_expect(service.verify_run(run_id).get("verification", {}).get("status") == "inconclusive", "truncated evidence must not pass absence-based verification checks")
	service.stop_game()
	service.free()


func _test_real_nonblocking_process(scene_path: String) -> void:
	var service := RealHeadlessGameProcessService.new()
	var started := service.start_scene("current_scene", scene_path)
	_expect(started.get("success", false), "Godot execute_with_pipe should start a real nonblocking child")
	var deadline := Time.get_ticks_msec() + 10000
	while service.is_running() and Time.get_ticks_msec() < deadline:
		service.poll()
		await process_frame
	service.poll()
	var snapshot := service.get_snapshot()
	_expect(snapshot.get("state") == "exited" and snapshot.get("exit_code") == 7, "real child completion should expose its exit code without blocking")
	_expect(str(snapshot.get("stdout", "")).contains("Orca child stdout"), "real child stdout should be captured")
	_expect(str(snapshot.get("stderr", "")).contains("Orca genuine runtime fixture"), "real Godot runtime errors should be captured from stderr")
	var diagnostics: Array = snapshot.get("diagnostics", [])
	_expect(not diagnostics.is_empty() and diagnostics[0].get("file") == "res://tests/fixtures/game_process_child.gd", "real multiline Godot errors should produce safe project diagnostics")
	service.shutdown()
	service.free()


func _service(stdout_path: String, stderr_path: String) -> FakeGameProcessService:
	var service := FakeGameProcessService.new()
	service.stdout_path = stdout_path
	service.stderr_path = stderr_path
	return service


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


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
		print("game_process_service_test: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("game_process_service_test: " + failure)
	quit(1)
