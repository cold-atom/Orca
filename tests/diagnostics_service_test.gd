extends SceneTree

const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_validation_contract()
	_test_logger_normalization()
	_test_record_bounds_and_isolation()
	_test_report_isolation()
	DiagnosticsService.clear()
	_finish()


func _test_validation_contract() -> void:
	var skipped := DiagnosticsService.validate_source("res://fixture.txt", "not gdscript")
	_expect(skipped.get("valid", false), "non-GDScript source should not require validation")
	_expect(skipped.get("diagnostics", []).is_empty(), "non-GDScript validation should not produce diagnostics")

	var valid := DiagnosticsService.validate_source("res://valid_fixture.gd", "extends Node\n\nfunc ok() -> void:\n\tpass\n")
	_expect(valid.get("valid", false), "valid GDScript should pass validation")

	var invalid := DiagnosticsService.validate_source("res://invalid_fixture.gd", "extends Node\n\nfunc broken( -> void:\n\tpass\n")
	_expect(not invalid.get("valid", true), "invalid GDScript should fail validation")
	_expect(not invalid.get("diagnostics", []).is_empty(), "invalid GDScript should return at least one diagnostic")
	for diagnostic in invalid.get("diagnostics", []):
		_expect(diagnostic.get("file") == "res://invalid_fixture.gd", "validation diagnostics should identify the candidate path")

	var duplicate_class_variable := DiagnosticsService.validate_source("res://duplicate_class_variable.gd", "extends Node\n\nvar value := 1\nvar value := 2\n")
	_expect(not duplicate_class_variable.get("valid", true), "duplicate class variables should fail GDScript validation")
	_expect(not duplicate_class_variable.get("diagnostics", []).is_empty(), "duplicate class variable validation should return diagnostics")

	var duplicate_local_variable := DiagnosticsService.validate_source("res://duplicate_local_variable.gd", "extends Node\n\nfunc duplicate() -> void:\n\tvar value := 1\n\tvar value := 2\n")
	_expect(not duplicate_local_variable.get("valid", true), "duplicate local variables should fail GDScript validation")
	_expect(not duplicate_local_variable.get("diagnostics", []).is_empty(), "duplicate local variable validation should return diagnostics")


func _test_record_bounds_and_isolation() -> void:
	DiagnosticsService.clear()
	var source := {
		"severity": "error",
		"file": "res://" + "f".repeat(DiagnosticsService.MAX_FILE_CHARS + 20),
		"function": "fn".repeat(DiagnosticsService.MAX_FUNCTION_CHARS),
		"message": "m".repeat(DiagnosticsService.MAX_MESSAGE_CHARS + 20)
	}
	DiagnosticsService._record(source)
	source["message"] = "mutated"
	var first: Dictionary = DiagnosticsService.get_report().get("records", [])[0]
	_expect(first.get("origin") == "editor", "diagnostic records should receive the default editor origin")
	_expect(str(first.get("message", "")).length() == DiagnosticsService.MAX_MESSAGE_CHARS, "diagnostic messages should be bounded")
	_expect(str(first.get("file", "")).length() == DiagnosticsService.MAX_FILE_CHARS, "diagnostic paths should be bounded")
	_expect(str(first.get("function", "")).length() == DiagnosticsService.MAX_FUNCTION_CHARS, "diagnostic function names should be bounded")
	_expect(first.get("message") != "mutated", "recording should not mutate or retain the caller's dictionary")

	DiagnosticsService.clear()
	for index in range(DiagnosticsService.MAX_RECORDS + 7):
		DiagnosticsService._record({"message": "record-%d" % index})
	var records: Array = DiagnosticsService.get_report().get("records", [])
	_expect(records.size() == DiagnosticsService.MAX_RECORDS, "diagnostic retention should be bounded")
	_expect(records[0].get("message") == "record-7", "diagnostic retention should discard the oldest records first")
	_expect(records[-1].get("message") == "record-%d" % (DiagnosticsService.MAX_RECORDS + 6), "diagnostic retention should preserve the newest record")
	for index in range(1, records.size()):
		_expect(int(records[index].get("sequence", 0)) > int(records[index - 1].get("sequence", 0)), "diagnostic sequences should increase monotonically")


func _test_logger_normalization() -> void:
	DiagnosticsService.clear()
	var logger := DiagnosticsService.CaptureLogger.new()
	logger._log_error("fixture", "res://fixture.gd", 3, "warning code", "", false, Logger.ERROR_TYPE_WARNING, [])
	logger._log_error("fixture", "res://fixture.gd", 4, "error code", "", false, Logger.ERROR_TYPE_ERROR, [])
	logger._log_message("stderr fixture", true)
	logger._log_message("stdout fixture", false)
	var records: Array = DiagnosticsService.get_report().get("records", [])
	_expect(records.size() == 3, "the logger should capture errors, warnings, and stderr but ignore stdout")
	_expect(records[0].get("severity") == "warning", "Godot warnings should retain warning severity")
	_expect(records[1].get("severity") == "error", "Godot errors should retain error severity")
	_expect(records[2].get("message") == "stderr fixture", "stderr messages should be captured")


func _test_report_isolation() -> void:
	DiagnosticsService.clear()
	DiagnosticsService._record({"message": "original"})
	var snapshot := {"diagnostics": [{"message": "game-original"}], "state": "running"}
	var report := DiagnosticsService.get_report(snapshot)
	report["records"][0]["message"] = "changed"
	report["game_records"][0]["message"] = "game-changed"
	snapshot["diagnostics"][0]["message"] = "source-changed"
	var fresh := DiagnosticsService.get_report()
	_expect(fresh.get("records", [])[0].get("message") == "original", "reports should deep-copy retained editor records")
	_expect(report.get("orca_run", {}).get("diagnostics", [])[0].get("message") == "game-original", "reports should deep-copy the supplied game snapshot")
	_expect(DiagnosticsService.get_report().get("orca_run", {}).get("state") == "idle", "an absent game snapshot should report an idle Orca run")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("diagnostics_service_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("diagnostics_service_test: ", failure)
	quit(1)
