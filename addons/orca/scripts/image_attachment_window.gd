@tool
extends Window

signal browse_requested
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
var status_label: Label
var browse_button: Button


func _init() -> void:
	name = "ImageAttachmentWindow"
	title = "Attach images — Orca"
	visible = false
	# A separate native Window receives desktop file drops on its own signal.
	# Embedding this UI in the editor would route drops through editor import.
	force_native = true
	transient = true
	exclusive = false
	unresizable = true
	size = Vector2i(UiMetrics.scaled_int(360), UiMetrics.scaled_int(240))
	min_size = size
	close_requested.connect(hide)


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	var background := PanelContainer.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.105, 0.11, 0.12)
	style.set_content_margin_all(UiMetrics.scaled(18))
	background.add_theme_stylebox_override("panel", style)
	add_child(background)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(12))
	background.add_child(content)
	var heading := Label.new()
	heading.text = "Drop images here"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", UiMetrics.scaled_int(18))
	content.add_child(heading)
	var description := Label.new()
	description.text = "PNG, JPEG, or WebP · up to four images\nAttachments stay outside your project files."
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", Color(0.65, 0.68, 0.72))
	content.add_child(description)
	status_label = Label.new()
	status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.add_child(status_label)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	content.add_child(actions)
	browse_button = Button.new()
	browse_button.text = "Browse…"
	browse_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(100, 32))
	browse_button.pressed.connect(func(): browse_requested.emit())
	actions.add_child(browse_button)
	var done := Button.new()
	done.text = "Done"
	done.custom_minimum_size = browse_button.custom_minimum_size
	done.pressed.connect(hide)
	actions.add_child(done)


func set_state(image_count: int, error: String = "") -> void:
	if status_label == null:
		return
	Localization.bind(status_label, &"text", "%s" if not error.is_empty() else "%d / 4 images attached", [Localization.source(error)] if not error.is_empty() else [image_count])
	status_label.add_theme_color_override("font_color", Color(0.9, 0.57, 0.55) if not error.is_empty() else Color(0.75, 0.78, 0.82))
	browse_button.disabled = image_count >= 4
