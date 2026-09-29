extends SceneTree

const TaskListPanel = preload("res://addons/orca/scripts/task_list_panel.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	get_root().size = Vector2i(300, 900)
	var panel = TaskListPanel.new()
	get_root().add_child(panel)
	await process_frame
	_expect(not panel.visible, "an empty task panel should be hidden")
	var tasks := [
		{"content": "Pending task with a deliberately long description that must wrap inside the narrow dock", "status": "pending"},
		{"content": "Current task", "status": "in_progress"},
		{"content": "Completed task", "status": "completed"},
		{"content": "Blocked task", "status": "blocked"},
		{"content": "Cancelled task", "status": "cancelled"}
	]
	panel.set_tasks(tasks)
	await process_frame
	await process_frame
	_expect(panel.visible, "a non-empty task panel should be visible")
	_expect(panel.get_tasks() == tasks, "the task panel should retain sanitized task order and states")
	_expect(panel.get_combined_minimum_size().x <= 300.0, "task content must not widen the panel beyond 300 px")
	_expect(panel.get_combined_minimum_size().y <= 220.0, "the expanded task panel should keep a bounded height")
	panel.set_expanded(false)
	_expect(not panel.is_expanded(), "the task panel should collapse")
	_expect(not panel._scroll.visible, "collapsing should hide task rows")
	panel.set_expanded(true)
	_expect(panel._scroll.visible, "expanding should restore task rows")
	panel.clear()
	_expect(not panel.visible and panel.get_tasks().is_empty(), "clearing tasks should hide and empty the panel")
	panel.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("task_list_panel_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("task_list_panel_test: ", failure)
	quit(1)
