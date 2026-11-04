@tool
extends Node

## Editor cases run inside the editor's existing tree, never as --editor --script
## main loops. Godot 4.7.2 leaks the initial editor tree when replacing its loop.
signal completed

var root: Window:
	get: return get_tree().root
var process_frame: Signal:
	get: return get_tree().process_frame


func get_root() -> Window:
	return get_tree().root


func create_timer(seconds: float) -> SceneTreeTimer:
	return get_tree().create_timer(seconds)


func quit(code: int = 0) -> void:
	completed.emit()
	get_tree().quit(code)
