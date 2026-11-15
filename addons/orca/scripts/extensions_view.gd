@tool
extends VBoxContainer

const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Card = preload("res://addons/orca/scripts/connector_card.gd")
const Dialog = preload("res://addons/orca/scripts/connector_dialog.gd")
signal chat_requested
var service
var blender_service
var blender_work_allowed: Callable
var blender_setup_message: Callable
var blender_panel
var _cards := {}
var _list: VBoxContainer
var _main: ScrollContainer
var _dialog
var _details: AcceptDialog
var _details_text: TextEdit
var _notice: Label
var _empty: Label
var _locked := false
var _rendered := []
var _enable_serials := {}


func _enter_tree() -> void:
	Localization.attach(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready() and is_visible_in_tree() and service != null:
		service.refresh_connectors()
		_sync()


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main = _scroll()
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Metrics.scaled_int(10))
	_main.add_child(body)
	_label(body, "EXTENSIONS")
	var studio := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.115, 0.12, 0.13)
	style.set_corner_radius_all(Metrics.scaled_int(8))
	style.content_margin_left = Metrics.scaled(12)
	style.content_margin_right = Metrics.scaled(12)
	style.content_margin_top = Metrics.scaled(12)
	style.content_margin_bottom = Metrics.scaled(12)
	studio.add_theme_stylebox_override("panel", style)
	body.add_child(studio)
	blender_panel = preload("res://addons/orca/scripts/blender_setup_panel.gd").new()
	blender_panel.service = blender_service
	blender_panel.work_allowed = blender_work_allowed
	blender_panel.setup_message = blender_setup_message
	blender_panel.chat_requested.connect(func(): chat_requested.emit())
	studio.add_child(blender_panel)
	_label(body, "CONNECTORS")
	_label(body, "Optional connections for inspection and reference.")
	_notice = _label(body, "")
	_notice.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_empty = _label(body, "No connectors configured.")
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", Metrics.scaled_int(10))
	body.add_child(_list)
	_button(body, "Add connector…", func(): _configure({}))
	_dialog = Dialog.new()
	_dialog.save_requested.connect(_save)
	add_child(_dialog)
	_details = AcceptDialog.new()
	_details.title = "Connection details"
	_details_text = TextEdit.new()
	_details_text.editable = false
	_details_text.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_details_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_details_text.custom_minimum_size = Metrics.scaled_vector(Vector2(220, 220))
	_details.add_child(_details_text)
	add_child(_details)
	if service != null: service.changed.connect(_sync)
	_sync()


func _scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	return scroll


func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _sync() -> void:
	if _list == null: return
	refresh_blender_setup()
	var entries: Array = service.connections if service != null else []
	if entries != _rendered:
		for child in _list.get_children():
			_list.remove_child(child)
			child.queue_free()
		_cards.clear()
		_rendered = entries.duplicate(true)
		for config in entries:
			var card := Card.new()
			card.config = config.duplicate(true)
			card.enable_requested.connect(_enable)
			card.disable_requested.connect(_disable)
			card.menu_requested.connect(_menu)
			_list.add_child(card)
			_cards[config["id"]] = card
	_empty.visible = entries.is_empty()
	_notice.text = Localization.message(service.configuration_error) if service != null else ""
	_notice.visible = not _notice.text.is_empty()
	var snapshot: Dictionary = service.snapshot() if service != null else {}
	for id in _cards:
		_cards[id].set_state(service.status(id), snapshot.get("servers", {}).get(id, {}).get("operations", []), _locked)


func _configure(config: Dictionary) -> void:
	if _locked or service == null: return
	if not config.is_empty() and service.connection(config["id"]) != config:
		_notice.text = Localization.message("Connector setup changed. Reopen its options.")
		_notice.show()
		return
	_dialog.open_config(config, service.registry_snapshot())


func _save(config: Dictionary, expected: Dictionary) -> void:
	if _locked or service == null: return
	if not service.save_connection(config, expected):
		_dialog.show_error("Setup changed or could not be saved. Reopen Configure and check the connector limit.")
		return
	_dialog.hide()
	_sync()


func _enable(config: Dictionary) -> void:
	if _locked or service == null: return
	var id: String = config["id"]
	var serial: int = int(_enable_serials.get(id, 0)) + 1
	_enable_serials[id] = serial
	var action: Dictionary = service.prepare_launch(config)
	var result: Dictionary = await service.connect_server(action)
	if _enable_serials.get(id) != serial: return
	_sync()
	if not result.get("success", false):
		_notice.text = Localization.message(str(result.get("error", "Could not enable connector.")))
		_notice.show()


func _disable(id: String) -> void:
	_enable_serials[id] = int(_enable_serials.get(id, 0)) + 1
	if service != null: service.disconnect_server(id, true)
	_sync()


func _menu(action: int, config: Dictionary) -> void:
	if _locked or service == null: return
	if service.connection(config["id"]) != config: return
	if action == 0: _configure(config)
	elif action == 1:
		_details_text.text = JSON.stringify({"configuration": config, "status": service.status(config["id"]), "inspections": service.snapshot().get("servers", {}).get(config["id"], {})}, "  ")
		_details.popup_centered_clamped(Metrics.scaled_vector(Vector2(460, 360)), 0.85)
	elif action == 2:
		if not service.remove_connection(config["id"], service.registry_snapshot()):
			_notice.text = Localization.message("Disable the connector before removing it, or reopen Connectors if setup changed.")
			_notice.show()


func refresh_blender_setup() -> void:
	if blender_panel != null: blender_panel._sync()


func set_locked(locked: bool) -> void:
	_locked = locked
	if _dialog != null: _dialog.set_locked(locked)
	if blender_panel != null: blender_panel.set_locked(locked)
	_sync()
