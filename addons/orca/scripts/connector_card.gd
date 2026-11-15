@tool
extends PanelContainer

signal enable_requested(config: Dictionary)
signal disable_requested(id: String)
signal menu_requested(action: int, config: Dictionary)

const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var config := {}
var _state := "disconnected"
var _title: Label
var _status: Label
var _purpose: Label
var _program: Label
var _action: Button
var _menu: MenuButton


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.115, 0.12, 0.13)
	style.set_corner_radius_all(Metrics.scaled_int(8))
	style.content_margin_left = Metrics.scaled(12)
	style.content_margin_right = Metrics.scaled(12)
	style.content_margin_top = Metrics.scaled(12)
	style.content_margin_bottom = Metrics.scaled(12)
	add_theme_stylebox_override("panel", style)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", Metrics.scaled_int(6))
	add_child(body)
	_title = _label(body)
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_title.add_theme_font_size_override("font_size", Metrics.scaled_int(16))
	_title.text = str(config.get("name", ""))
	_status = _label(body)
	_purpose = _label(body)
	_program = _label(body)
	_program.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_program.text = str(config.get("command", "")).get_file()
	_program.tooltip_text = str(config.get("command", "")) + "\n" + JSON.stringify(config.get("arguments", []))
	_program.add_theme_color_override("font_color", Color(0.65, 0.68, 0.72))
	var actions := HBoxContainer.new()
	body.add_child(actions)
	_action = Button.new()
	_action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action.pressed.connect(func():
		if _state in ["connected", "connecting", "stop_failed"]: disable_requested.emit(config["id"])
		else: enable_requested.emit(config.duplicate(true)))
	actions.add_child(_action)
	_menu = MenuButton.new()
	_menu.text = "⋮"
	_menu.custom_minimum_size.x = Metrics.scaled(36)
	_menu.tooltip_text = "Connector options"
	actions.add_child(_menu)
	var popup := _menu.get_popup()
	popup.add_item("Configure…", 0)
	popup.add_item("Connection details", 1)
	popup.add_separator()
	popup.add_item("Remove connector", 2)
	popup.id_pressed.connect(func(id): menu_requested.emit(id, config.duplicate(true)))
	set_state({"state": "disconnected"}, [], false)


func _label(parent: Node) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func set_state(status: Dictionary, operations: Array, locked: bool) -> void:
	if _action == null: return
	_state = str(status.get("state", "disconnected"))
	var error := str(status.get("error", ""))
	var caption := "Disabled"
	if _state == "connected": caption = "MCP connected — inspection"
	elif _state == "connecting": caption = "Connecting…"
	elif _state == "stop_failed": caption = "Needs attention"
	elif not error.is_empty(): caption = "Connection failed"
	Localization.bind(_status, &"text", caption)
	Localization.bind(_action, &"text", "Cancel" if _state == "connecting" else "Disable" if _state in ["connected", "stop_failed"] else "Enable")
	_action.disabled = (_state == "disconnected" and status.get("settling", false)) or (locked and _state not in ["connected", "connecting", "stop_failed"])
	_menu.disabled = locked or _state == "connecting" or status.get("busy", false)
	var purpose := "Listed text resources"
	if config.get("profile") in ["blender", "blender_lab"]:
		purpose = "Inspect your open Blender session. Create assets with Blender Asset Studio above."
	if _state == "connected" and operations.has("blender_status") and not operations.has("blender_scene"):
		purpose = "Data-block inspection" if config.get("profile") == "blender_lab" else "Add-on inspection"
	elif _state == "connected" and operations.has("blender_scene") and not operations.has("blender_status"):
		purpose = "Scene inspection"
	if _state == "connected" and not operations.has("blender_scene") and not operations.has("read_resource") and not operations.has("blender_status"):
		purpose = "No supported inspections found. Check the connector type in Configure."
	if not error.is_empty():
		Localization.bind(_purpose, &"text", error)
	else:
		Localization.bind(_purpose, &"text", purpose)
