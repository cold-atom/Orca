extends SceneTree

const HistoryView = preload("res://addons/orca/scripts/history_view.gd")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var view = HistoryView.new()
	get_root().add_child(view)
	view.set_sessions([
		{
			"id": "session_1_1",
			"title": "A restored conversation with a deliberately long title",
			"updated_at": Time.get_unix_time_from_system(),
			"mode": 1,
			"model": "provider/a-very-long-model-name-that-must-not-hide-actions",
			"last_prompt": "Continue building the current scene",
			"changed_file_count": 2,
			"cost_available": true,
			"cost_usd": 0.0123,
			"clean": true,
			"resumable": true
		}
	], "")
	await process_frame
	await process_frame
	var minimum := view.get_combined_minimum_size()
	if minimum.x > 300.0:
		printerr("history_view_test: minimum width exceeded 300 px: ", minimum.x)
		quit(1)
		return
	print("history_view_test: PASS")
	quit(0)
