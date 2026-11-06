@tool
extends PanelContainer

signal account_requested
signal provider_requested
signal model_requested
signal dismiss_requested

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")

var body_font_size := 13
var meta_font_size := 11
var title_label: Label
var description_label: Label
var account_button: Button
var provider_button: Button
var model_button: Button
var close_button: Button
var later_button: Button
var _account_title: Label
var _account_description: Label


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.115, 0.125, 0.14)
	background.border_color = Color(0.26, 0.29, 0.33)
	background.set_border_width_all(UiMetrics.scaled_int(1))
	background.set_corner_radius_all(UiMetrics.scaled_int(10))
	background.set_content_margin_all(UiMetrics.scaled(16))
	add_theme_stylebox_override("panel", background)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiMetrics.scaled_int(12))
	add_child(column)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	column.add_child(heading)
	title_label = _label("Connect a model to continue", body_font_size + 1, Color(0.86, 0.89, 0.93))
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title_label)
	close_button = Button.new()
	close_button.name = "CloseSetup"
	close_button.text = "×"
	close_button.flat = true
	close_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(28, 28))
	close_button.add_theme_font_size_override("font_size", body_font_size + 2)
	close_button.tooltip_text = "Close connection setup"
	close_button.accessibility_name = close_button.tooltip_text
	close_button.pressed.connect(func(): dismiss_requested.emit())
	heading.add_child(close_button)
	description_label = _label("", body_font_size, Color(0.62, 0.66, 0.72))
	column.add_child(description_label)
	var account_row := _action(column, "Account", "Sign in / Sign up with Orca", "Use models through your Orca account.", true)
	account_button = account_row.get_node("Button")
	_account_title = account_row.get_node("Margin/Content/Title")
	_account_description = account_row.get_node("Margin/Content/Description")
	account_button.pressed.connect(func(): if not account_button.disabled: account_requested.emit())
	var provider_row := _action(column, "Provider", "Bring your own API key", "Connect your preferred provider—or use local models.", false)
	provider_button = provider_row.get_node("Button")
	provider_button.pressed.connect(func(): if not provider_button.disabled: provider_requested.emit())
	var model_row := _action(column, "Model", "Choose a model", "Open model selection in Provider Settings.", true)
	model_button = model_row.get_node("Button")
	model_button.pressed.connect(func(): if not model_button.disabled: model_requested.emit())
	model_row.hide()
	later_button = Button.new()
	later_button.name = "SetUpLater"
	later_button.text = "Set up later"
	later_button.flat = true
	later_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	later_button.add_theme_font_size_override("font_size", meta_font_size)
	later_button.add_theme_color_override("font_color", Color(0.62, 0.67, 0.73))
	later_button.pressed.connect(func(): dismiss_requested.emit())
	column.add_child(later_button)


func configure(setup: Dictionary, connected: bool, account_state: String, locked: bool = false, first_open: bool = false) -> void:
	var status := str(setup.get("status", "ready"))
	title_label.text = "Choose a model to continue" if status == "model" else "Restoring your connection" if status == "restoring" else "Get started with Orca" if first_open else "Connect a model to continue"
	description_label.text = ("Choose how you’d like to connect." if first_open else "Your draft is kept while you connect.") if status in ["account", "credentials"] else str(setup.get("message", ""))
	var model_only := status == "model"
	account_button.get_parent().visible = not model_only
	provider_button.get_parent().visible = not model_only
	model_button.get_parent().visible = model_only
	_account_title.text = "Use Orca models" if connected else "Continue Orca sign-in" if account_state in ["connecting", "pairing"] else "Sign in / Sign up with Orca"
	_account_description.text = "Choose a model included in your account." if connected else "Finish connecting your account in the browser." if account_state in ["connecting", "pairing"] else "Use models through your Orca account."
	account_button.accessibility_name = _account_title.text
	Localization.bind(account_button, &"tooltip_text", "%s\n%s", [Localization.source(_account_title.text), Localization.source(_account_description.text)])
	account_button.disabled = locked or account_state in ["restoring", "signing_out"]
	provider_button.disabled = locked
	model_button.disabled = locked


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _action(parent: Control, node_name: String, title: String, description: String, primary: bool) -> PanelContainer:
	# Text-driven height and wrapped captions stay readable in narrow docks.
	var panel := PanelContainer.new()
	panel.name = node_name
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.21, 0.26) if primary else Color(0.13, 0.14, 0.16)
	normal.border_color = Color(0.23, 0.39, 0.47) if primary else Color(0.23, 0.25, 0.28)
	normal.set_border_width_all(UiMetrics.scaled_int(1))
	normal.set_corner_radius_all(UiMetrics.scaled_int(7))
	panel.add_theme_stylebox_override("panel", normal)
	parent.add_child(panel)
	var button := Button.new()
	button.name = "Button"
	button.accessibility_name = title
	Localization.bind(button, &"tooltip_text", "%s\n%s", [Localization.source(title), Localization.source(description)])
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("disabled", StyleBoxEmpty.new())
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = normal.bg_color.lightened(0.07)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	var focus := normal.duplicate() as StyleBoxFlat
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = Color(0.5, 0.7, 0.81)
	button.add_theme_stylebox_override("focus", focus)
	panel.add_child(button)
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", UiMetrics.scaled_int(12))
	margin.add_theme_constant_override("margin_right", UiMetrics.scaled_int(12))
	margin.add_theme_constant_override("margin_top", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(10))
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.name = "Content"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(4))
	margin.add_child(content)
	var caption := _label(title, body_font_size, Color(0.87, 0.91, 0.94))
	caption.name = "Title"
	content.add_child(caption)
	var subtitle := _label(description, meta_font_size, Color(0.61, 0.67, 0.73))
	subtitle.name = "Description"
	subtitle.hide()
	content.add_child(subtitle)
	return panel
