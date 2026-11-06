@tool
extends PanelContainer

signal remove_requested(index: int)
signal preview_requested(image: Dictionary)
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
var _row: HBoxContainer


func configure(images: Array, removable: bool = true) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var style := StyleBoxEmpty.new()
	style.set_content_margin_all(UiMetrics.scaled(4))
	add_theme_stylebox_override("panel", style)
	mouse_filter = Control.MOUSE_FILTER_PASS
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = UiMetrics.scaled(56)
	scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	add_child(scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	scroll.add_child(_row)
	for index in range(images.size()):
		var record: Dictionary = images[index]
		var tile := Control.new()
		tile.custom_minimum_size = UiMetrics.scaled_vector(Vector2(56, 56))
		_row.add_child(tile)
		var preview := Button.new()
		var thumbnail_style := StyleBoxFlat.new()
		thumbnail_style.bg_color = Color(0.115, 0.12, 0.13)
		thumbnail_style.border_color = Color(0.3, 0.31, 0.33)
		thumbnail_style.set_border_width_all(UiMetrics.scaled_int(1))
		thumbnail_style.set_corner_radius_all(UiMetrics.scaled_int(6))
		thumbnail_style.set_content_margin_all(0)
		thumbnail_style.shadow_color = Color(0, 0, 0, 0.22)
		thumbnail_style.shadow_size = UiMetrics.scaled_int(2)
		preview.add_theme_stylebox_override("normal", thumbnail_style)
		var thumbnail_hover := thumbnail_style.duplicate() as StyleBoxFlat
		thumbnail_hover.border_color = Color(0.55, 0.57, 0.6)
		preview.add_theme_stylebox_override("hover", thumbnail_hover)
		preview.add_theme_stylebox_override("pressed", thumbnail_hover)
		preview.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		Localization.bind(preview, &"tooltip_text", "%s · %d × %d%s", [record.get("name", "Image"), record["width"], record["height"], Localization.source(" · resized" if record.get("resized", false) else "")])
		preview.pressed.connect(func(): preview_requested.emit(record))
		tile.add_child(preview)
		var image := TextureRect.new()
		image.texture = ImageAttachments.texture(record)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		image.mouse_filter = Control.MOUSE_FILTER_IGNORE
		preview.add_child(image)
		image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		image.offset_left = UiMetrics.scaled(4)
		image.offset_top = UiMetrics.scaled(4)
		image.offset_right = -UiMetrics.scaled(4)
		image.offset_bottom = -UiMetrics.scaled(4)
		if removable:
			var remove := Button.new()
			remove.text = ""
			# Keep editor font metrics from enlarging the close button's click target.
			var close_image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
			close_image.fill(Color.TRANSPARENT)
			for pixel in range(2, 10):
				close_image.set_pixel(pixel, pixel, Color(0.85, 0.86, 0.88))
				close_image.set_pixel(11 - pixel, pixel, Color(0.85, 0.86, 0.88))
			remove.icon = ImageTexture.create_from_image(close_image)
			remove.expand_icon = true
			remove.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			remove.add_theme_constant_override("icon_max_width", UiMetrics.scaled_int(12))
			remove.tooltip_text = "Remove image"
			var remove_style := StyleBoxFlat.new()
			remove_style.bg_color = Color(0.17, 0.18, 0.2, 0.96)
			remove_style.set_corner_radius_all(UiMetrics.scaled_int(10))
			remove_style.set_content_margin_all(0)
			remove.add_theme_stylebox_override("normal", remove_style)
			var hover_style := remove_style.duplicate() as StyleBoxFlat
			hover_style.bg_color = Color(0.28, 0.29, 0.31)
			remove.add_theme_stylebox_override("hover", hover_style)
			remove.add_theme_stylebox_override("pressed", hover_style)
			remove.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
			remove.offset_left = -UiMetrics.scaled(22)
			remove.offset_top = -UiMetrics.scaled(2)
			remove.offset_right = UiMetrics.scaled(2)
			remove.offset_bottom = UiMetrics.scaled(22)
			remove.pressed.connect(func(): remove_requested.emit(index))
			tile.add_child(remove)
	visible = not images.is_empty()
