@tool
extends Container

## Navigation on the left, actions on the right; whole groups stack when needed.
## Native flow and Button word wrapping retain full captions at narrow widths.
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var navigation := HFlowContainer.new()
var actions := HFlowContainer.new()
var _height := 0.0


func _init() -> void:
	for group in [navigation, actions]:
		group.add_theme_constant_override("h_separation", UiMetrics.scaled_int(6))
		group.add_theme_constant_override("v_separation", UiMetrics.scaled_int(4))
		add_child(group)
		group.sort_children.connect(queue_sort)
	actions.alignment = FlowContainer.ALIGNMENT_END


func _get_minimum_size() -> Vector2:
	return Vector2(0, _height)


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var width := maxf(size.x, 1)
	var gap := UiMetrics.scaled(6)
	for group in [navigation, actions]:
		for button in group.get_children():
			if button is Button:
				var wrapped := _button_width(button) > width
				var wrapping := TextServer.AUTOWRAP_WORD if wrapped else TextServer.AUTOWRAP_OFF
				if button.autowrap_mode != wrapping:
					button.autowrap_mode = wrapping
				var minimum := width if wrapped else 0.0
				if button.custom_minimum_size.x != minimum:
					button.custom_minimum_size.x = minimum
	var navigation_width := _natural_width(navigation)
	var actions_width := _natural_width(actions)
	var stacked := navigation_width > 0 and actions_width > 0 and navigation_width + gap + actions_width > width
	var navigation_height := navigation.get_combined_minimum_size().y if navigation_width > 0 else 0.0
	var actions_height := actions.get_combined_minimum_size().y if actions_width > 0 else 0.0
	var height := navigation_height + gap + actions_height if stacked else maxf(navigation_height, actions_height)
	fit_child_in_rect(navigation, Rect2(0, 0, width if stacked or actions_width == 0 else maxf(0, width - actions_width - gap), navigation_height))
	fit_child_in_rect(actions, Rect2(0 if stacked else maxf(0, width - actions_width), navigation_height + gap if stacked else 0, width if stacked else minf(width, actions_width), actions_height))
	if not is_equal_approx(_height, height):
		_height = height
		update_minimum_size()


func _natural_width(group: HFlowContainer) -> float:
	var width := 0.0
	var count := 0
	for child in group.get_children():
		if child is Control and child.visible:
			width += _button_width(child) if child is Button else child.get_combined_minimum_size().x
			count += 1
	return width + maxi(0, count - 1) * UiMetrics.scaled(6)


func _button_width(button: Button) -> float:
	var padding := 0.0
	for style_name in ["normal", "hover", "pressed", "disabled"]:
		padding = maxf(padding, button.get_theme_stylebox(style_name).get_minimum_size().x)
	var caption := button.atr(button.text)
	var font := button.get_theme_font("font")
	var font_size := button.get_theme_font_size("font_size")
	var shaped := TextLine.new()
	shaped.add_string(caption, font, font_size, button.language)
	return ceilf(maxf(shaped.get_size().x, font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x) + padding) + 2
