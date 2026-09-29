@tool
extends BaseButton

var _hover_style := StyleBoxFlat.new()
var _pressed_style := StyleBoxFlat.new()


func _ready() -> void:
	_hover_style.bg_color = Color(0.28, 0.32, 0.37, 0.65)
	_hover_style.corner_radius_top_left = 4
	_hover_style.corner_radius_top_right = 4
	_hover_style.corner_radius_bottom_right = 4
	_hover_style.corner_radius_bottom_left = 4

	_pressed_style.bg_color = Color(0.18, 0.22, 0.27, 0.9)
	_pressed_style.corner_radius_top_left = 4
	_pressed_style.corner_radius_top_right = 4
	_pressed_style.corner_radius_bottom_right = 4
	_pressed_style.corner_radius_bottom_left = 4

	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	if is_pressed():
		draw_style_box(_pressed_style, Rect2(Vector2.ZERO, size))
	elif is_hovered():
		draw_style_box(_hover_style, Rect2(Vector2.ZERO, size))
