@tool
extends VBoxContainer

const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Card = preload("res://addons/orca/scripts/connector_card.gd")
const Dialog = preload("res://addons/orca/scripts/connector_dialog.gd")
const CHEVRON_DOWN = preload("res://addons/orca/assets/chevron_down.svg")
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
var _connectors_toggle: Button
var _connectors_body: VBoxContainer
var _connectors_hint: Label
var _body_font_size := 13
var _meta_font_size := 11
var _live_confirmation
var _live_action := {}
var _live_texture: FileDialog
var _texture_session
var _configuration_error := ""


func _enter_tree() -> void:
	Localization.attach(self)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_node_ready() and is_visible_in_tree() and service != null:
		service.refresh_connectors()
		_sync()


func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint(): _body_font_size = maxi(13, EditorInterface.get_editor_theme().get_font_size("font_size", "Label"))
	_meta_font_size = maxi(11, _body_font_size - 1)
	_main = _scroll()
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Metrics.scaled_int(10))
	_main.add_child(body)
	var title := _label(body, "EXTENSIONS")
	title.add_theme_font_size_override("font_size", _meta_font_size)
	title.add_theme_color_override("font_color", Color(0.48, 0.68, 0.8))
	blender_panel = preload("res://addons/orca/scripts/blender_setup_panel.gd").new()
	blender_panel.service = blender_service
	blender_panel.work_allowed = blender_work_allowed
	blender_panel.setup_message = blender_setup_message
	blender_panel.chat_requested.connect(func(): chat_requested.emit())
	body.add_child(blender_panel)
	var optional := VBoxContainer.new()
	optional.add_theme_constant_override("separation", Metrics.scaled_int(8))
	body.add_child(optional)
	optional.add_child(HSeparator.new())
	_connectors_toggle = _button(optional, "Optional connections", func():
		_connectors_body.visible = _connectors_toggle.button_pressed
		_connectors_toggle.icon = _disclosure_icon(_connectors_toggle.button_pressed))
	_connectors_toggle.toggle_mode = true
	_connectors_toggle.flat = true
	_connectors_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_connectors_toggle.icon = _disclosure_icon(false)
	_connectors_toggle.add_theme_constant_override("icon_max_width", Metrics.scaled_int(14))
	_connectors_hint = _label(optional, "")
	_connectors_hint.add_theme_font_size_override("font_size", _meta_font_size)
	_connectors_hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_connectors_body = VBoxContainer.new()
	_connectors_body.add_theme_constant_override("separation", Metrics.scaled_int(10))
	optional.add_child(_connectors_body)
	_connectors_body.hide()
	var explanation := _label(_connectors_body, "Work with an open Blender session or connect other tools. Asset Studio can create assets independently.")
	explanation.add_theme_font_size_override("font_size", _meta_font_size)
	_notice = _label(body, "")
	_notice.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_empty = _label(_connectors_body, "No connectors configured.")
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", Metrics.scaled_int(10))
	_connectors_body.add_child(_list)
	var add := _button(_connectors_body, "Add connection…", func(): _configure({}))
	add.flat = true
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
	_live_confirmation = preload("res://addons/orca/scripts/bounded_confirmation.gd").new()
	_live_confirmation.title = "Enable live Blender authoring?"
	_live_confirmation.ok_button_text = "Enable authoring"
	_live_confirmation.confirmed.connect(_confirm_live_authoring)
	_live_confirmation.canceled.connect(func(): _live_action.clear())
	add_child(_live_confirmation)
	_live_texture = FileDialog.new()
	_live_texture.title = "Attach live asset texture"
	_live_texture.access = FileDialog.ACCESS_FILESYSTEM
	_live_texture.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_live_texture.use_native_dialog = true
	_live_texture.file_selected.connect(_attach_live_texture)
	_live_texture.canceled.connect(func(): _texture_session = null)
	add_child(_live_texture)
	if service != null: service.changed.connect(_sync)
	_sync()


func _scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	return scroll


static func _disclosure_icon(expanded: bool) -> Texture2D:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_theme().get_icon("GuiTreeArrowDown" if expanded else "GuiTreeArrowRight", "EditorIcons")
	return CHEVRON_DOWN


func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", _body_font_size)
	label.add_theme_color_override("font_color", Color(0.64, 0.68, 0.74))
	parent.add_child(label)
	return label


func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", _body_font_size)
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
	var configuration_error: String = service.configuration_error if service != null else ""
	if configuration_error != _configuration_error:
		if not configuration_error.is_empty() or _notice.text == Localization.message(_configuration_error): _notice.text = Localization.message(configuration_error)
		_configuration_error = configuration_error
	_notice.visible = not _notice.text.is_empty()
	var snapshot: Dictionary = service.snapshot() if service != null else {}
	var connected_count: int = snapshot.get("servers", {}).size()
	var live_count := 0
	for value in snapshot.get("servers", {}).values():
		if value.get("live_authoring", false): live_count += 1
	Localization.bind(_connectors_hint, &"text", "%d connected · %d with live authoring" if live_count > 0 else "%d connected for inspection", [connected_count, live_count] if live_count > 0 else [connected_count])
	_connectors_hint.visible = connected_count > 0
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
	elif action == 3:
		var session = service.live_session(config["id"])
		if session != null and session.state == "connected":
			service.disable_live_authoring(config["id"])
			return
		_live_action = service.prepare_live_enable(config)
		if _live_action.is_empty(): return
		_live_confirmation.popup_message("Enable asset creation and editing through %s in the current Blender scene?\n\nOrca installs its verified helper and replaces earlier Orca authoring sessions in this Blender instance. Edits keep private recovery copies; the original document stays open without automatic save or reload.\n\nOperations require review unless you separately enable Auto apply for this live session. Godot import and scene placement always require review. Linked libraries, embedded scripts and drivers require a separate workflow.", [config["name"]])
	elif action in [4, 5, 6, 7]:
		if not service.live_work_allowed.is_valid() or not service.live_work_allowed.call(): return
		var session = service.live_session(config["id"])
		if session == null: return
		if action == 5:
			if preload("res://addons/orca/scripts/update_package.gd").no_links(session.workspace): OS.shell_open(session.workspace)
		elif action == 6:
			_texture_session = session
			_live_texture.popup_centered_ratio(0.75)
		else:
			var result: Dictionary = await session.undo_last(func(): return not _locked and service.live_work_allowed.call() and service.live_session(config["id"]) == session) if action == 4 else session.revert_import(true)
			_notice.text = Localization.message(str(result.get("content", "")))
			_notice.show()
			_sync()


func _confirm_live_authoring() -> void:
	var action := _live_action.duplicate(true)
	_live_action.clear()
	if _locked or service == null or action.is_empty(): return
	var result: Dictionary = await service.enable_live_authoring(action)
	_notice.text = Localization.message(str(result.get("content", result.get("error", ""))))
	_notice.visible = not _notice.text.is_empty()
	_sync()


func _attach_live_texture(path: String) -> void:
	var session = _texture_session
	_texture_session = null
	if _locked or service == null or not is_instance_valid(session) or service.live_session(session.server_id) != session or not service.live_work_allowed.call(): return
	var result: Dictionary = session.attach_texture(path, func(): return not _locked and service.live_work_allowed.call() and service.live_session(session.server_id) == session)
	_notice.text = Localization.message(str(result.get("content", "")))
	_notice.show()


func refresh_blender_setup() -> void:
	if blender_panel != null: blender_panel._sync()


func set_locked(locked: bool) -> void:
	_locked = locked
	if _dialog != null: _dialog.set_locked(locked)
	if blender_panel != null: blender_panel.set_locked(locked)
	if locked:
		_live_action.clear()
		_texture_session = null
		if _live_confirmation != null: _live_confirmation.hide()
		if _live_texture != null: _live_texture.hide()
	_sync()
