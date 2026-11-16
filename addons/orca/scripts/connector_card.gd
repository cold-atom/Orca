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
var _role: Label
var _body_font_size := 13
var _meta_font_size := 11


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint(): _body_font_size = maxi(13, EditorInterface.get_editor_theme().get_font_size("font_size", "Label"))
	_meta_font_size = maxi(11, _body_font_size - 1)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.145)
	style.border_color = Color(0.25, 0.27, 0.30, 0.75)
	style.set_border_width_all(Metrics.scaled_int(1))
	style.set_corner_radius_all(Metrics.scaled_int(8))
	style.content_margin_left = Metrics.scaled(12)
	style.content_margin_right = Metrics.scaled(12)
	style.content_margin_top = Metrics.scaled(12)
	style.content_margin_bottom = Metrics.scaled(12)
	add_theme_stylebox_override("panel", style)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", Metrics.scaled_int(8))
	add_child(body)
	_title = _label(body)
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_title.add_theme_font_size_override("font_size", _body_font_size + 1)
	_title.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	_title.text = str(config.get("name", ""))
	_role = _label(body)
	_role.add_theme_font_size_override("font_size", _meta_font_size)
	_role.add_theme_color_override("font_color", Color(0.64, 0.68, 0.74))
	Localization.bind(_role, &"text", "Live Blender · Inspection only" if config.get("profile") in ["blender", "blender_lab"] else "MCP · Inspection only")
	_status = _label(body)
	_status.add_theme_font_size_override("font_size", _meta_font_size)
	_purpose = _label(body)
	_purpose.add_theme_font_size_override("font_size", _meta_font_size)
	_purpose.add_theme_color_override("font_color", Color(0.64, 0.68, 0.74))
	_program = _label(body)
	_program.add_theme_font_size_override("font_size", _meta_font_size)
	_program.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_program.text = str(config.get("command", "")).get_file()
	_program.tooltip_text = str(config.get("command", "")) + "\n" + JSON.stringify(config.get("arguments", []))
	_program.add_theme_color_override("font_color", Color(0.65, 0.68, 0.72))
	var actions := HBoxContainer.new()
	body.add_child(actions)
	_action = Button.new()
	_action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_action.add_theme_font_size_override("font_size", _body_font_size)
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
	if config.get("profile") == "blender_lab":
		popup.add_separator()
		popup.add_item("Enable live authoring…", 3)
		popup.add_item("Undo last Orca live edit", 4)
		popup.add_item("Show live recovery copies", 5)
		popup.add_item("Attach live asset texture…", 6)
		popup.add_item("Revert live asset import", 7)
	popup.id_pressed.connect(func(id): menu_requested.emit(id, config.duplicate(true)))
	set_state({"state": "disconnected"}, [], false)


func _label(parent: Node) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", _body_font_size)
	parent.add_child(label)
	return label


func set_state(status: Dictionary, operations: Array, locked: bool) -> void:
	if _action == null: return
	_state = str(status.get("state", "disconnected"))
	var error := str(status.get("error", ""))
	var caption := "Not connected"
	if _state == "connected": caption = "Connected for inspection"
	elif _state == "connecting": caption = "Connecting…"
	elif _state == "stop_failed": caption = "Needs attention"
	elif not error.is_empty(): caption = "Connection failed"
	var live: bool = status.get("live_state") == "connected"
	if live: caption = "Connected for creation and editing"
	elif status.get("live_state") == "connecting": caption = "Preparing live authoring…"
	elif status.get("live_state") == "paused": caption = "Live authoring needs attention"
	Localization.bind(_role, &"text", "Live Blender · Create & edit" if live else "Live Blender · Inspection only" if config.get("profile") in ["blender", "blender_lab"] else "MCP · Inspection only")
	Localization.bind(_status, &"text", caption)
	_status.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58) if _state == "connected" else Color(0.92, 0.74, 0.46) if _state == "stop_failed" or not error.is_empty() else Color(0.64, 0.68, 0.74))
	Localization.bind(_action, &"text", "Cancel" if _state == "connecting" else "Disconnect" if _state in ["connected", "stop_failed"] else "Connect")
	_action.disabled = (_state == "disconnected" and status.get("settling", false)) or (locked and _state not in ["connected", "connecting", "stop_failed"])
	_menu.disabled = locked or _state == "connecting" or status.get("busy", false)
	var popup := _menu.get_popup()
	if popup.get_item_index(3) >= 0: popup.set_item_text(popup.get_item_index(3), "Disable live authoring" if live else "Enable live authoring…")
	for action in [3, 4, 5, 6, 7]:
		if popup.get_item_index(action) < 0: continue
		popup.set_item_disabled(popup.get_item_index(action), locked or not status.get("live_work_allowed", false) or not status.get("live_supported", false) or status.get("live_state") == "connecting" or (action in [4, 6] and not live) or (action in [5, 7] and status.get("live_state", "disconnected") == "disconnected"))
	var purpose := "Listed text resources"
	if config.get("profile") in ["blender", "blender_lab"]:
		purpose = "Inspect objects and scene details in your open Blender session."
	if _state == "connected" and operations.has("blender_status") and not operations.has("blender_scene"):
		purpose = "Data-block inspection" if config.get("profile") == "blender_lab" else "Add-on inspection"
	elif _state == "connected" and operations.has("blender_scene") and not operations.has("blender_status"):
		purpose = "Scene inspection"
	if _state == "connected" and not operations.has("blender_scene") and not operations.has("read_resource") and not operations.has("blender_status"):
		purpose = "No supported inspections found. Check the connector type in Configure."
	if live: purpose = "Create, edit, preview and export assets in your open Blender scene."
	if not error.is_empty():
		Localization.bind(_purpose, &"text", error)
	else:
		Localization.bind(_purpose, &"text", purpose)
