@tool
extends VBoxContainer

const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const CHEVRON_DOWN = preload("res://addons/orca/assets/chevron_down.svg")
const MUTED_COLOR := Color(0.64, 0.68, 0.74)
signal preview_attachment_requested(image: Dictionary)
signal chat_requested
var service
var work_allowed: Callable
var setup_message: Callable
var _status: Label
var _hint: Label
var _blocker: Label
var _program: Label
var _installation_help: VBoxContainer
var _selection_hint: Label
var _installations: OptionButton
var _primary: Button
var _choose: Button
var _download: Button
var _manage: Button
var _manage_choose: Button
var _rescan: Button
var _template_button: Button
var _texture_button: Button
var _disconnect: Button
var _new_asset: Button
var _open: Button
var _revert: Button
var _restore: Button
var _preview: TextureRect
var _attach: Button
var _browse: FileDialog
var _texture_browse: FileDialog
var _template_browse: FileDialog
var _template := ""
var _template_hash := ""
var _confirm: ConfirmationDialog
var _choice := ""
var _approved_executable := ""
var _locked := false
var _actions: VBoxContainer
var _setup_started := false
var _found: Array[String] = []
var _selection_error := ""
var _body_font_size := 13
var _meta_font_size := 11
var _connection_title: Label
var _connection_dot: PanelContainer
var _connection_dot_style: StyleBoxFlat

func _enter_tree() -> void:
	Localization.attach(self)

func _notification(what: int) -> void:
	if what in [NOTIFICATION_TRANSLATION_CHANGED, NOTIFICATION_VISIBILITY_CHANGED] and is_node_ready(): _sync()

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if Engine.is_editor_hint(): _body_font_size = maxi(13, EditorInterface.get_editor_theme().get_font_size("font_size", "Label"))
	_meta_font_size = maxi(11, _body_font_size - 1)
	add_theme_constant_override("separation", Metrics.scaled_int(8))
	var heading := VBoxContainer.new()
	heading.add_theme_constant_override("separation", Metrics.scaled_int(5))
	add_child(heading)
	var title := _label("Blender Asset Studio", heading)
	title.add_theme_font_size_override("font_size", _body_font_size + 1)
	title.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	var description := _label("Create and preview 3D assets from chat.", heading)
	description.add_theme_font_size_override("font_size", _meta_font_size)
	description.add_theme_color_override("font_color", MUTED_COLOR)
	var connection := HBoxContainer.new()
	connection.add_theme_constant_override("separation", Metrics.scaled_int(6))
	add_child(connection)
	var indicator_margin := MarginContainer.new()
	indicator_margin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	indicator_margin.add_theme_constant_override("margin_left", int(title.get_theme_stylebox("normal").get_content_margin(SIDE_LEFT)))
	connection.add_child(indicator_margin)
	_connection_dot = PanelContainer.new()
	_connection_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_connection_dot.custom_minimum_size = Metrics.scaled_vector(Vector2(6, 6))
	_connection_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_connection_dot_style = StyleBoxFlat.new()
	_connection_dot_style.bg_color = MUTED_COLOR
	_connection_dot_style.set_corner_radius_all(Metrics.scaled_int(3))
	_connection_dot.add_theme_stylebox_override("panel", _connection_dot_style)
	indicator_margin.add_child(_connection_dot)
	_connection_title = _label("", connection)
	_connection_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connection_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_connection_title.add_theme_font_size_override("font_size", _meta_font_size)
	_connection_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_status = _label("")
	_status.add_theme_font_size_override("font_size", _meta_font_size)
	_status.add_theme_color_override("font_color", MUTED_COLOR)
	_status.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_primary = _button("Set up Blender", _primary_action)
	_hint = _label("")
	_hint.add_theme_font_size_override("font_size", _meta_font_size)
	_hint.add_theme_color_override("font_color", MUTED_COLOR)
	_hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	Localization.bind(_hint, &"tooltip_text", "Orca includes the workspace connector. No Blender add-on or separate MCP installation is needed.")
	_blocker = _label("")
	_blocker.add_theme_font_size_override("font_size", _meta_font_size)
	_blocker.add_theme_color_override("font_color", Color(0.92, 0.74, 0.46))
	_blocker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_installation_help = VBoxContainer.new()
	add_child(_installation_help)
	_selection_hint = _label("", _installation_help)
	_installations = OptionButton.new()
	_installations.fit_to_longest_item = false
	_installations.clip_text = true
	_installations.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_installations.item_selected.connect(func(index):
		if service != null and not _locked and not service.busy() and service.state == "disconnected" and index >= 0:
			_selection_error = ""
			service.choose(str(_installations.get_item_metadata(index)))
			_sync())
	_installation_help.add_child(_installations)
	_choose = _button("Choose Blender…", _browse_blender, _installation_help)
	_download = _button("Download Blender", func():
		if not _locked: OS.shell_open("https://www.blender.org/download/"), _installation_help)
	_manage = _button("Manage workspace…", func(): _actions.visible = _manage.button_pressed)
	_manage.toggle_mode = true
	_manage.flat = true
	_manage.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_manage.add_theme_font_size_override("font_size", _meta_font_size)
	_manage.add_theme_color_override("font_color", MUTED_COLOR)
	_manage.add_theme_constant_override("icon_max_width", Metrics.scaled_int(12))
	_manage.toggled.connect(func(expanded): _manage.icon = _disclosure_icon(expanded))
	_manage.icon = _disclosure_icon(false)
	_actions = VBoxContainer.new()
	_actions.add_theme_constant_override("separation", Metrics.scaled_int(8))
	add_child(_actions)
	_actions.hide()
	_program = _label("", _actions)
	_program.add_theme_font_size_override("font_size", _meta_font_size)
	_program.add_theme_color_override("font_color", MUTED_COLOR)
	_program.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_manage_choose = _button("Choose Blender…", _browse_blender, _actions)
	_rescan = _button("Check for Blender", _setup, _actions)
	_disconnect = _button("Disconnect workspace", func():
		if service != null: service.disconnect_workspace(), _actions)
	_new_asset = _button("New asset workspace", func(): _request("new"), _actions)
	_template_button = _button("Start from saved Blender file…", func():
		if _work_mode() and service != null and not service.executable.is_empty(): _template_browse.popup_centered_ratio(0.75), _actions)
	_open = _button("Open asset in Blender", _open_asset, _actions)
	_texture_button = _button("Attach asset texture…", func():
		if _work_mode() and service != null and service.state == "connected": _texture_browse.popup_centered_ratio(0.75), _actions)
	_restore = _button("Restore previous asset revision", func(): _request("restore"), _actions)
	_revert = _button("Revert last asset import", func(): _request("revert"), _actions)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.custom_minimum_size.y = Metrics.scaled(180)
	_preview.hide()
	_actions.add_child(_preview)
	_attach = _button("Attach preview to chat", func(): preview_attachment_requested.emit(service.preview_image.duplicate(true)), _actions)
	_browse = FileDialog.new()
	_browse.title = "Choose Blender"
	_browse.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_browse.access = FileDialog.ACCESS_FILESYSTEM
	_browse.use_native_dialog = true
	_browse.file_selected.connect(func(path):
		if not _locked and service != null and not service.busy() and service.state == "disconnected":
			_selection_error = ""
			if not service.choose(path):
				_selection_error = "Choose an installed Blender executable."
				service.status = _selection_error
			_refresh_installations())
	add_child(_browse)
	_texture_browse = FileDialog.new()
	_texture_browse.title = "Choose asset texture"
	_texture_browse.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_texture_browse.access = FileDialog.ACCESS_FILESYSTEM
	_texture_browse.use_native_dialog = true
	_texture_browse.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp;Still images"])
	_texture_browse.file_selected.connect(func(path):
		if service != null and _work_mode(): service.attach_texture(path, _work_mode))
	add_child(_texture_browse)
	_template_browse = FileDialog.new()
	_template_browse.title = "Choose Blender template"
	_template_browse.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_template_browse.access = FileDialog.ACCESS_FILESYSTEM
	_template_browse.use_native_dialog = true
	_template_browse.filters = PackedStringArray(["*.blend;Blender files"])
	_template_browse.file_selected.connect(func(path):
		if _work_mode():
			var file := FileAccess.open(path, FileAccess.READ)
			if file == null or file.get_length() > 32 * 1024 * 1024:
				service.status = "Choose a saved Blender template no larger than 32 MiB."
				_sync()
				return
			_template = path
			_template_hash = FileAccess.get_sha256(path)
			_request("template"))
	add_child(_template_browse)
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Blender workspace"
	_confirm.ok_button_text = "Start workspace"
	_confirm.confirmed.connect(_confirmed)
	_confirm.canceled.connect(func(): _choice = ""; _approved_executable = "")
	add_child(_confirm)
	if service != null: service.changed.connect(_sync)
	_sync()

func _label(text: String, parent: Node = null) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", _body_font_size)
	(parent if parent != null else self).add_child(label)
	return label

func _button(text: String, action: Callable, parent: Node = null) -> Button:
	var button := Button.new()
	button.text = text
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", _body_font_size)
	button.pressed.connect(action)
	(parent if parent != null else self).add_child(button)
	return button

static func _disclosure_icon(expanded: bool) -> Texture2D:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_theme().get_icon("GuiTreeArrowDown" if expanded else "GuiTreeArrowRight", "EditorIcons")
	return CHEVRON_DOWN

func set_locked(locked: bool) -> void:
	_locked = locked
	if locked and _confirm != null:
		_confirm.hide()
		_choice = ""
		_approved_executable = ""
	_sync()

func _refresh_installations() -> void:
	if _installations == null: return
	_installations.clear()
	_found.clear()
	if service != null:
		_found = service.discover()
		for path in _found:
			_installations.add_item(path)
			_installations.set_item_metadata(_installations.item_count - 1, path)
			if path == service.executable: _installations.select(_installations.item_count - 1)
		if service.executable.is_empty(): _installations.select(-1)
	_sync()

func _browse_blender() -> void:
	if not _locked and service != null and not service.busy() and service.state == "disconnected":
		_browse.popup_centered_ratio(0.75)

func _primary_action() -> void:
	if service == null: return
	if service.state in ["connecting", "stop_failed"]:
		service.disconnect_workspace()
		return
	if _locked or service.busy(): return
	if service.state == "connected": chat_requested.emit()
	elif service.executable.is_empty(): _setup()
	else: _request("connect")

func _setup() -> void:
	if _locked or service == null or service.busy() or service.state != "disconnected": return
	_setup_started = true
	_selection_error = ""
	_refresh_installations()
	if service.executable.is_empty() and _found.size() == 1: service.choose(_found[0])
	_sync()
	if not service.executable.is_empty(): _request("connect")

func _request(choice: String) -> void:
	if _locked or service == null or service.busy(): return
	if choice in ["restore", "revert", "template"] and not _work_mode(): return
	_choice = choice
	_approved_executable = service.executable
	var message := ""
	var evidence := ""
	if choice in ["connect", "new"]:
		message = "Orca will start the selected Blender in the background with its shipped connector and a dedicated asset workspace. Your open Blender files are preserved."
		evidence = service.executable
	elif choice == "template":
		message = "Use the selected saved Blender file as a trusted asset template? Blender loads a private copy with automatic scripts disabled. Linked libraries, embedded scripts and drivers are unsupported. The original file is preserved."
		evidence = _template
	elif choice == "restore": message = "Restore the previous asset revision as a new workspace revision? Project imports are unchanged."
	else: message = "Revert the last imported asset only if its project bytes and recovery checkpoint still match?"
	Localization.bind_parts(_confirm, &"dialog_text", [[message, []], ["\n\n%s", [evidence]]] if not evidence.is_empty() else [[message, []]])
	Localization.bind(_confirm, &"ok_button_text", "Start workspace" if choice in ["connect", "new", "template"] else "Confirm")
	_confirm.popup_centered_clamped(Metrics.scaled_vector(Vector2(480, 280)), 0.85)

func _confirmed() -> void:
	if _locked or service == null or service.busy(): return
	if service.executable != _approved_executable: return
	var choice := _choice
	_choice = ""
	_approved_executable = ""
	if choice in ["connect", "new"]: await service.connect_workspace(choice == "new")
	elif choice == "template" and _work_mode(): await service.connect_workspace(true, _template, _template_hash)
	elif choice == "restore" and _work_mode(): await service.restore_previous(_work_mode)
	elif choice == "revert" and _work_mode():
		var result: Dictionary = service.revert_import(true)
		service.status = result["content"]
	_sync()

func _work_mode() -> bool:
	return not _locked and work_allowed.is_valid() and work_allowed.call()

func _open_asset() -> void:
	if _locked or service == null or service.current.is_empty(): return
	var path: String = service.workspace.path_join(service.current["blend_file"])
	if FileAccess.get_sha256(path) == service.current["sha256"]:
		OS.create_process(service.executable, PackedStringArray(service.launch_prefix() + ["--disable-autoexec", path]))

func _sync() -> void:
	if _status == null: return
	if service == null:
		Localization.bind(_status, &"text", "Blender workspace setup is unavailable.")
		_status.show()
		Localization.bind(_connection_title, &"text", "Setup unavailable")
		_connection_dot_style.bg_color = MUTED_COLOR
		_primary.disabled = true
		_installation_help.hide()
		_manage.hide()
		_hint.hide()
		_blocker.hide()
		return
	var busy: bool = _locked or service.busy()
	var connected: bool = service.state == "connected"
	var selecting: bool = _setup_started and service.executable.is_empty()
	_status.text = Localization.message(service.status)
	var connection_title := "Connect Blender" if service.executable.is_empty() else "Ready to start"
	var connection_color := MUTED_COLOR
	if connected:
		connection_title = "Workspace ready"
		connection_color = Color(0.48, 0.78, 0.58)
		if service.status == "Workspace ready": Localization.bind(_status, &"text", "Blender is running in the background.")
	elif service.state == "connecting": connection_title = "Starting asset workspace"
	elif service.state == "stop_failed":
		connection_title = "Connection needs attention"
		connection_color = Color(0.92, 0.74, 0.46)
	Localization.bind(_connection_title, &"text", connection_title)
	_connection_dot_style.bg_color = connection_color
	if service.state == "disconnected" and service.executable.is_empty() and selecting:
		Localization.bind(_status, &"text", "Choose a Blender installation." if not _found.is_empty() else "Blender was not found. Choose an installation or download Blender, then check again.")
	if not _selection_error.is_empty(): _status.text = Localization.message(_selection_error)
	_status.visible = service.state != "disconnected" or selecting or not _selection_error.is_empty() or service.status not in ["Choose Blender to prepare the asset workspace.", "Blender selected. Connect to create a dedicated asset workspace."]
	var caption := "Back to chat" if connected else "Start asset workspace" if not service.executable.is_empty() else "Check for Blender" if selecting else "Set up Blender"
	if service.state == "connecting": caption = "Cancel"
	elif service.state == "stop_failed": caption = "Try disconnect again"
	Localization.bind(_primary, &"text", caption)
	_primary.disabled = busy and service.state not in ["connecting", "stop_failed"]
	Localization.bind(_hint, &"text", "Only Blender 5.2+ is required.")
	_hint.visible = service.state == "disconnected" and not selecting
	var blocker: String = setup_message.call() if connected and setup_message.is_valid() else ""
	_blocker.text = Localization.message(blocker)
	_blocker.visible = not blocker.is_empty()
	_program.text = service.executable
	_program.tooltip_text = service.executable
	_program.visible = not service.executable.is_empty()
	_installation_help.visible = selecting and service.state == "disconnected"
	_installations.visible = not _found.is_empty()
	_selection_hint.text = Localization.message("Select the Blender installation to use.")
	_selection_hint.visible = not _found.is_empty()
	_choose.disabled = busy
	_download.visible = _found.is_empty()
	_download.disabled = _locked
	_manage.visible = not service.executable.is_empty() or service.state != "disconnected"
	_manage_choose.visible = service.state == "disconnected"
	_manage_choose.disabled = busy
	_rescan.visible = service.state == "disconnected"
	_rescan.disabled = busy
	_disconnect.disabled = service.state == "disconnected"
	_new_asset.disabled = busy or service.executable.is_empty()
	_open.disabled = busy or service.current.is_empty()
	_template_button.disabled = busy or service.executable.is_empty() or not _work_mode()
	_texture_button.disabled = busy or not connected or not _work_mode()
	_revert.disabled = busy or service.last_import.is_empty() or not _work_mode()
	_restore.disabled = busy or int(service.current.get("revision", 0)) <= 1 or service.state != "connected" or not _work_mode()
	_installations.disabled = busy or service.state == "connected"
	_preview.visible = not service.preview_image.is_empty()
	_preview.texture = Images.texture(service.preview_image) if not service.preview_image.is_empty() else null
	_attach.visible = not service.preview_image.is_empty()
	_attach.disabled = busy
