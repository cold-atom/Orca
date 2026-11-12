extends Area2D

@export var interceptions := 0

func _get(_property):
	interceptions += 1
	return null

func _set(_property, _value) -> bool:
	interceptions += 1
	return false

@warning_ignore("native_method_override")
func set_position(_position: Vector2) -> void:
	interceptions += 1

@warning_ignore("native_method_override")
func get_position() -> Vector2:
	interceptions += 1
	return Vector2(999, 999)

func _on_body_entered(_body: Node2D) -> void:
	interceptions += 1
