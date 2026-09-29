extends SceneTree

const ChatWindowScene = preload("res://addons/orca/scenes/chat_window.tscn")
const ChatWindow = preload("res://addons/orca/scripts/chat_window.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	var scale := EditorInterface.get_editor_scale()
	_expect(is_equal_approx(UiMetrics.editor_scale(), scale), "UI metrics should use Godot's effective editor scale")
	var view = ChatWindowScene.instantiate()
	get_root().add_child(view)
	await process_frame
	await process_frame
	var margin := view.get_node("MarginContainer") as MarginContainer
	var logo := view.get_node("MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Logo") as TextureRect
	var mode := view.get_node("MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector") as Control
	_expect(margin.get_theme_constant("margin_left") == UiMetrics.scaled_int(10), "dock margins should follow the effective editor scale")
	_expect(logo.custom_minimum_size == UiMetrics.scaled_vector(Vector2(60, 60)), "empty-state logo geometry should follow the effective editor scale")
	var minimum_mode_size := UiMetrics.scaled_vector(Vector2(82, 24))
	_expect(mode.custom_minimum_size.x >= minimum_mode_size.x and mode.custom_minimum_size.y >= minimum_mode_size.y, "composer controls should preserve their scaled minimum target")
	view.prompt_input.text = ""
	view._sync_prompt_height()
	var line_height: float = view.prompt_input.get_line_height()
	var style_height: float = view.prompt_input.get_theme_stylebox("normal").get_minimum_size().y
	_expect(view.prompt_input.custom_minimum_size.y == ceilf(ChatWindow.PROMPT_MIN_LINES * line_height + style_height), "composer height should derive from scaled editor font metrics")
	view.queue_free()
	await process_frame
	if _failures.is_empty():
		print("editor_ui_scale_test: PASS (scale %.2f)" % scale)
		quit(0)
		return
	for failure in _failures:
		printerr("editor_ui_scale_test: ", failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
