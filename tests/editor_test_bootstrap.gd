@tool
extends EditorPlugin

## Installed and enabled only by run_editor_test.py in a disposable project.
const CASES := ["auto_apply_editor_test.gd", "editor_ui_scale_test.gd", "remembered_edit_editor_test.gd", "update_editor_test.gd", "localization_editor_test.gd", "project_inspection_editor_test.gd", "support_reminder_editor_test.gd"]
var _finished := false


func _enter_tree() -> void:
	var case_name := OS.get_environment("ORCA_EDITOR_TEST_CASE")
	if case_name.is_empty():
		return # The runner's initial import must not execute a case.
	if case_name not in CASES:
		push_error("Unsupported isolated editor test case.")
		get_tree().quit(2)
		return
	call_deferred("_run_case", case_name)


func _run_case(case_name: String) -> void:
	var case_script := load("res://tests/" + case_name) as Script
	if case_script == null or not case_script.can_instantiate():
		push_error("Could not load the isolated editor test case.")
		get_tree().quit(2)
		return
	var test := case_script.new() as Node
	if test == null or not test.has_signal("completed"):
		push_error("Editor tests must extend editor_test_case.gd.")
		if test != null: test.free()
		get_tree().quit(2)
		return
	test.completed.connect(func(): _finished = true)
	add_child(test)
	get_tree().create_timer(90).timeout.connect(func():
		if not _finished:
			push_error("Isolated editor test exceeded its completion deadline.")
			get_tree().quit(2)
	)
