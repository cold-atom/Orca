@tool
extends ConfirmationDialog

## Native actions stay outside a non-fit-content, scrollable text body.
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
var body: RichTextLabel
var message_source := ""
var message_arguments: Array = []
var requested_size := Vector2i.ZERO
var owner_size := Vector2i.ZERO


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	dialog_text = ""
	body = RichTextLabel.new()
	body.name = "ConfirmationBody"
	body.fit_content = false
	body.scroll_active = true
	body.selection_enabled = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint(): body.add_theme_font_size_override("normal_font_size", maxi(13, EditorInterface.get_editor_theme().get_font_size("font_size", "Label")))
	add_child(body)
	for button in [get_ok_button(), get_cancel_button()]:
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func popup_message(message: String, arguments: Array = []) -> void:
	message_source = message
	message_arguments = arguments.duplicate(true)
	Localization.bind(body, &"text", message, arguments)
	body.get_v_scroll_bar().value = 0
	var owner := get_parent().get_window()
	var available := owner.size
	if DisplayServer.get_name() != "headless":
		var usable := DisplayServer.screen_get_usable_rect(owner.current_screen).size
		if usable.x > 0 and usable.y > 0: available = available.min(usable)
	var target := Vector2i(mini(Metrics.scaled_int(440), maxi(1, int(available.x * 0.85))), mini(Metrics.scaled_int(240), maxi(1, int(available.y * 0.85))))
	requested_size = target
	owner_size = available
	# The editor theme supplies wide native button minima. Bound these as well
	# as the body; otherwise the footer can expand a narrow confirmation.
	var panel_padding: float = get_theme_stylebox("panel", "AcceptDialog").get_minimum_size().x
	var gaps: int = get_theme_constant("separation", "HBoxContainer") * 4
	var button_width := maxi(0, int((target.x / maxf(content_scale_factor, 1.0) - panel_padding - gaps) / 2.0))
	add_theme_constant_override("buttons_min_width", button_width)
	popup_centered_clamped(target, 0.85)
