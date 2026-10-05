extends SceneTree

const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")

const WAIT_TIMEOUT_MS := 3000

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var primary_service := DiagnosticsService.new()
	get_root().add_child(primary_service)
	await process_frame
	DiagnosticsService.clear()
	var first_marker := "orca-diagnostics-editor-%d" % Time.get_ticks_usec()
	printerr(first_marker)
	_expect(await _wait_for_marker(first_marker), "an active diagnostics service should capture editor stderr")
	_expect(_marker_count(first_marker) == 1, "one editor message should produce exactly one diagnostic record")

	var additional_service := DiagnosticsService.new()
	get_root().add_child(additional_service)
	await process_frame
	DiagnosticsService.clear()
	var shared_marker := "orca-diagnostics-shared-%d" % Time.get_ticks_usec()
	printerr(shared_marker)
	_expect(await _wait_for_marker(shared_marker), "a shared diagnostics service should keep logger capture active")
	_expect(_marker_count(shared_marker) == 1, "multiple diagnostics service instances must not register duplicate loggers")
	additional_service.queue_free()
	await process_frame

	DiagnosticsService.clear()
	var retained_marker := "orca-diagnostics-retained-%d" % Time.get_ticks_usec()
	printerr(retained_marker)
	_expect(await _wait_for_marker(retained_marker), "releasing one service should retain the plugin-owned logger")
	_expect(_marker_count(retained_marker) == 1, "the retained shared logger should capture once")
	primary_service.queue_free()
	await process_frame
	DiagnosticsService.clear()
	_finish()


func _wait_for_marker(marker: String) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if _marker_count(marker) > 0:
			return true
		await process_frame
	return _marker_count(marker) > 0


func _marker_count(marker: String) -> int:
	var count := 0
	for record in DiagnosticsService.get_report().get("records", []):
		if str(record.get("message", "")).contains(marker):
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("diagnostics_editor_integration_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("diagnostics_editor_integration_test: ", failure)
	quit(1)
