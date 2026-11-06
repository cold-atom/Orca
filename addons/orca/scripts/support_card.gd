@tool
extends PanelContainer

signal link_requested(url: String)
signal dismiss_requested(permanent: bool)

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const GITHUB := "https://github.com/cold-atom/Orca"
const STORE := "https://store.godotengine.org/asset/cold-atom/orca-ai-agent-for-godot/"

var body_label: Label
var github_button: Button
var review_button: Button
var later_button: Button
var never_button: Button
var close_button: Button
var title_label: Label
var body_font_size := 13
var meta_font_size := 11
var _caption_panels: Array[Dictionary] = []
var _available_width := 0.0


func _enter_tree() -> void:
	Localization.attach(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED or what == NOTIFICATION_THEME_CHANGED:
		call_deferred("_refresh_caption_widths")


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.105, 0.12, 0.135)
	style.border_color = Color(0.26, 0.31, 0.35)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(10))
	style.set_content_margin_all(UiMetrics.scaled(12))
	style.shadow_color = Color(0, 0, 0, 0.3)
	style.shadow_size = UiMetrics.scaled_int(4)
	style.shadow_offset = UiMetrics.scaled_vector(Vector2(0, 2))
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiMetrics.scaled_int(9))
	add_child(column)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	column.add_child(heading)
	var star := Label.new()
	star.text = "★"
	star.add_theme_font_size_override("font_size", body_font_size + 3)
	star.add_theme_color_override("font_color", Color(0.88, 0.74, 0.43))
	heading.add_child(star)
	title_label = Label.new()
	title_label.text = "Finding Orca useful?"
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", body_font_size + 1)
	title_label.add_theme_color_override("font_color", Color(0.87, 0.91, 0.94))
	heading.add_child(title_label)
	close_button = _button("×", heading, func(): dismiss_requested.emit(false), true, false)
	close_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(24, 24))
	close_button.add_theme_font_size_override("font_size", body_font_size + 3)
	close_button.tooltip_text = "Dismiss support reminder"
	close_button.accessibility_name = close_button.tooltip_text
	body_label = Label.new()
	body_label.text = "A GitHub star or an honest Godot Asset Library review helps other Godot developers discover the project. Thanks for supporting Orca!"
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_label.add_theme_font_size_override("font_size", body_font_size)
	body_label.add_theme_color_override("font_color", Color(0.66, 0.72, 0.77))
	column.add_child(body_label)
	var links := HFlowContainer.new()
	links.add_theme_constant_override("h_separation", UiMetrics.scaled_int(6))
	links.add_theme_constant_override("v_separation", UiMetrics.scaled_int(6))
	column.add_child(links)
	github_button = _button("Star on GitHub", links, func(): link_requested.emit(GITHUB))
	review_button = _button("Leave a review", links, func(): link_requested.emit(STORE))
	github_button.tooltip_text = "Open Orca's GitHub repository in your browser"
	review_button.tooltip_text = "Open Orca's Godot Asset Library page in your browser"
	var dismissal := HFlowContainer.new()
	dismissal.add_theme_constant_override("h_separation", UiMetrics.scaled_int(7))
	column.add_child(dismissal)
	later_button = _button("Not now", dismissal, func(): dismiss_requested.emit(false), true)
	never_button = _button("Don't ask again", dismissal, func(): dismiss_requested.emit(true), true)


func _button(caption: String, parent: Control, action: Callable, quiet: bool = false, wrap_caption: bool = true) -> Button:
	var button := Button.new()
	button.text = "" if wrap_caption else caption
	button.accessibility_name = caption
	button.add_theme_font_size_override("font_size", meta_font_size)
	button.add_theme_color_override("font_color", Color(0.62, 0.68, 0.74) if quiet else Color(0.83, 0.9, 0.94))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.TRANSPARENT if quiet else Color(0.14, 0.2, 0.24)
	normal.border_color = Color(0.27, 0.38, 0.44)
	normal.set_border_width_all(0 if quiet else UiMetrics.scaled_int(1))
	normal.set_corner_radius_all(UiMetrics.scaled_int(6))
	normal.content_margin_left = UiMetrics.scaled(4 if quiet else 8)
	normal.content_margin_right = UiMetrics.scaled(4 if quiet else 8)
	normal.content_margin_top = UiMetrics.scaled(3 if quiet else 6)
	normal.content_margin_bottom = UiMetrics.scaled(3 if quiet else 6)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.16, 0.19, 0.22) if quiet else Color(0.18, 0.27, 0.32)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	var focus := normal.duplicate() as StyleBoxFlat
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = Color(0.5, 0.7, 0.81)
	focus.set_border_width_all(UiMetrics.scaled_int(1))
	button.add_theme_stylebox_override("focus", focus)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(action)
	if not wrap_caption:
		parent.add_child(button)
		return button
	# A flow can wrap between buttons, but native Button captions otherwise keep
	# an unbounded one-line minimum. Let a wrapped label drive each action's height.
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	parent.add_child(panel)
	panel.add_child(button)
	var margin := MarginContainer.new()
	margin.name = "CaptionMargin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, roundi(normal.get("content_margin_" + side)))
	panel.add_child(margin)
	var label := Label.new()
	label.name = "Caption"
	label.text = caption
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", meta_font_size)
	label.add_theme_color_override("font_color", button.get_theme_color("font_color"))
	margin.add_child(label)
	_caption_panels.append({"panel": panel, "label": label, "padding": normal.get_minimum_size().x})
	parent.resized.connect(func(): call_deferred("_refresh_caption_widths"))
	label.minimum_size_changed.connect(func(): call_deferred("_refresh_caption_widths"))
	call_deferred("_refresh_caption_widths")
	return button


func _refresh_caption_widths() -> void:
	if _available_width <= 0.0:
		return
	var content_width := maxf(0.0, _available_width - get_theme_stylebox("panel").get_minimum_size().x)
	for record in _caption_panels:
		var panel: PanelContainer = record["panel"]
		var label: Label = record["label"]
		var natural_width := ceilf(label.get_theme_font("font").get_string_size(Localization.message(label.text), HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x) + float(record["padding"])
		panel.custom_minimum_size.x = minf(natural_width, content_width)


func set_available_width(width: float) -> void:
	if not is_equal_approx(_available_width, width):
		_available_width = width
		call_deferred("_refresh_caption_widths")
