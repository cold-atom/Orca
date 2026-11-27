@tool
extends EditorPlugin

const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const AccountService = preload("res://addons/orca/scripts/account_service.gd")
const UpdateService = preload("res://addons/orca/scripts/update_service.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const ASSETS := "res://addons/orca/assets"
# Only textures used by the toolbar, chat scene and their script preloads.
const UI_TEXTURES := [
	"orca.svg", "settings.svg", "send-alt.svg", "history.svg", "new_session.svg", "image.svg", "check.svg",
	"orca-animated-sheet.png", "providerconfig.svg", "systems.svg", "about.svg", "profile.svg", "extension.svg", "chevron_down.svg",
]

var toolbar
var chat_window
var diagnostics_service
var game_process_service
var account_service
var update_service
var _updating := false
var _dock_root: Control
var _startup_message: Label
var _filesystem: EditorFileSystem
var _check_queued := false
var _open_requested := false

func _enable_plugin():
	# Add autoloads here.
	pass


func _disable_plugin():
	# Remove autoloads here.
	pass


func _enter_tree():
	if not Engine.is_editor_hint():
		return
	# Register the same dock through import, success and failure so Godot can
	# restore its layout and the toolbar can open it even on a cold start.
	_dock_root = Control.new()
	_dock_root.name = "Orca"
	_dock_root.custom_minimum_size = Vector2(UiMetrics.scaled(300), 0)
	_startup_message = Label.new()
	_startup_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_startup_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_startup_message.text = "Waiting for Godot to import Orca assets. If progress stops, check the editor Output."
	_dock_root.add_child(_startup_message)
	_startup_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Localization.attach(_dock_root)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock_root)
	# This small toolbar scene uses only native controls/scripts before import.
	toolbar = preload("res://addons/orca/scenes/orca.tscn").instantiate()
	toolbar.custom_minimum_size = UiMetrics.scaled_vector(Vector2(24, 24))
	var button: TextureButton = toolbar.get_node("TextureButton")
	button.texture_normal = EditorInterface.get_editor_theme().get_icon("Node", "EditorIcons")
	button.tooltip_text = "Orca"
	button.pressed.connect(_toggle_chat_window)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, toolbar)
	call_deferred("_hide_unopened_dock")
	_filesystem = EditorInterface.get_resource_filesystem()
	_filesystem.filesystem_changed.connect(_queue_import_check)
	_filesystem.resources_reimported.connect(_queue_import_check)
	_check_imports()


func _queue_import_check(_resources = null) -> void:
	if not _check_queued:
		_check_queued = true
		call_deferred("_check_imports")


func _check_imports() -> void:
	_check_queued = false
	if _filesystem == null or _filesystem.is_scanning() or _filesystem.is_importing():
		return # Startup must return to Godot for the first scan/import to finish.
	var directory := _filesystem.get_filesystem_path(ASSETS)
	var textures := {} # Hold until scene load; Godot reuses cached textures.
	for filename: String in UI_TEXTURES:
		var path := ASSETS.path_join(filename)
		var index := directory.find_file_index(filename) if directory != null else -1
		var texture: Texture2D
		if index >= 0 and directory.get_file_import_is_valid(index) and ResourceLoader.exists(path, "Texture2D"):
			texture = ResourceLoader.load(path, "Texture2D") as Texture2D
		if texture == null:
			Localization.bind(_startup_message, &"text", "Godot could not import %s. Restore or reimport this asset in the FileSystem dock. Orca will retry when it changes.", [path])
			return
		textures[filename] = texture
	_stop_import_checks()
	toolbar.get_node("TextureButton").texture_normal = textures["orca.svg"]
	_start_chat()


func _start_chat() -> void:
	# preload() here would still compile the chat UI before _enter_tree().
	var scene := ResourceLoader.load("res://addons/orca/scenes/chat_window.tscn", "PackedScene") as PackedScene
	chat_window = scene.instantiate() if scene != null and scene.can_instantiate() else null
	if chat_window == null or not chat_window.has_method("notify_dock_opened"):
		_show_startup_failure()
		return
	SceneProposal.cleanup_stale_scratch(60)
	var config_script = preload("res://addons/orca/scripts/config.gd").new()
	config_script._init_settings()
	config_script.free()
	diagnostics_service = DiagnosticsService.new()
	add_child(diagnostics_service)
	game_process_service = GameProcessService.new()
	add_child(game_process_service)
	account_service = AccountService.new()
	add_child(account_service)
	update_service = UpdateService.new()
	add_child(update_service)
	update_service.install_requested.connect(_on_install_requested)
	chat_window.diagnostics_service = diagnostics_service
	chat_window.game_process_service = game_process_service
	chat_window.account_service = account_service
	chat_window.update_service = update_service
	_dock_root.add_child(chat_window)
	if chat_window.get("startup_complete") != true:
		_show_startup_failure()
		return
	_startup_message.free()
	_startup_message = null
	if not scene_saved.is_connected(_on_scene_saved):
		scene_saved.connect(_on_scene_saved)
		scene_changed.connect(_on_scene_state_changed)
		scene_closed.connect(_on_scene_state_changed)
	if not EditorInterface.get_editor_undo_redo().version_changed.is_connected(_on_scene_history_changed):
		EditorInterface.get_editor_undo_redo().version_changed.connect(_on_scene_history_changed)
	if _open_requested:
		chat_window.notify_dock_opened()


func _hide_unopened_dock() -> void:
	if _dock_root != null and not _open_requested:
		_set_chat_window_open(false)


func _stop_import_checks() -> void:
	if _filesystem != null:
		_filesystem.filesystem_changed.disconnect(_queue_import_check)
		_filesystem.resources_reimported.disconnect(_queue_import_check)
		_filesystem = null


func _show_startup_failure() -> void:
	if chat_window != null:
		chat_window.free()
		chat_window = null
	_free_services()
	_startup_message.text = "Orca could not initialize the chat dock. Check the editor Output, then disable and re-enable Orca in Project Settings."


func _on_scene_saved(path: String) -> void:
	if is_instance_valid(chat_window) and is_instance_valid(chat_window.agent_controller):
		chat_window.agent_controller.record_editor_scene_save(path)
	call_deferred("_on_scene_history_changed")


func _on_scene_state_changed(_scene) -> void:
	call_deferred("_on_scene_history_changed")


func _on_scene_history_changed() -> void:
	if is_instance_valid(chat_window) and is_instance_valid(chat_window.agent_controller):
		chat_window.agent_controller.queue_editor_scene_refresh()


func _exit_tree():
	_stop_import_checks()
	if not Engine.is_editor_hint():
		return
	if EditorInterface.get_editor_undo_redo().version_changed.is_connected(_on_scene_history_changed):
		EditorInterface.get_editor_undo_redo().version_changed.disconnect(_on_scene_history_changed)
	if _dock_root:
		remove_control_from_docks(_dock_root)
		_dock_root.free()
		_dock_root = null
		_startup_message = null
		chat_window = null
		
	if toolbar:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, toolbar)
		toolbar.free()
		toolbar = null
	_free_services()


func _free_services() -> void:
	if game_process_service:
		if not game_process_service.shutdown():
			push_warning("Orca is unloading while its owned game process may still be running.")
		game_process_service.free()
		game_process_service = null
	if diagnostics_service:
		diagnostics_service.free()
		diagnostics_service = null
	if account_service:
		account_service.free()
		account_service = null
	if update_service:
		update_service.free()
		update_service = null


func _update_readiness() -> String:
	if not Engine.is_editor_hint():
		return "Updates can only be installed from the Godot editor."
	if game_process_service != null and game_process_service.is_running() or EditorInterface.is_playing_scene():
		return "Stop the game before installing an update."
	if not EditorInterface.get_unsaved_scenes().is_empty() or not EditorInterface.get_script_editor().get_unsaved_files().is_empty():
		return "Save all open scenes and scripts before installing an update."
	if account_service != null and (account_service._refreshing or account_service.state in ["connecting", "pairing", "restoring", "signing_out"]):
		return "Finish or cancel account sign-in/refresh before restarting."
	if account_service != null and account_service.native_helper != null and account_service.native_helper.busy():
		return "Secure connection preparation is still running. Try updating again when it finishes."
	if chat_window != null:
		return chat_window.update_readiness()
	return ""


func _on_install_requested(operation: String) -> void:
	if _updating or update_service == null or operation not in ["install", "recover"]:
		return
	var blocked := _update_readiness()
	if not blocked.is_empty():
		update_service.show_error(blocked)
		return
	_updating = true
	var prepared: Dictionary = await update_service.prepare_update() if operation == "install" else {"success": true}
	if not prepared.get("success", false):
		_updating = false
		return
	blocked = _update_readiness()
	if not blocked.is_empty() or not chat_window.save_for_update():
		update_service.show_error(blocked if not blocked.is_empty() else "Conversation could not be saved. The editor remains open.")
		_updating = false
		return
	var launched: Dictionary = await update_service.launch_installer(prepared, operation)
	blocked = _update_readiness()
	if not launched.get("success", false) or not blocked.is_empty() or not chat_window.save_for_update():
		update_service.close_installer(true)
		update_service.show_error(str(launched.get("error", blocked if not blocked.is_empty() else "Conversation could not be saved.")))
		_updating = false
		return
	update_service.hand_off()
	# The independent updater waits for this exact editor process to exit. It
	# replaces the addon only afterward and reopens the same project/binary.
	get_tree().quit()
		
func _toggle_chat_window():
	if not _dock_root:
		return

	var dock := _get_dock()
	var is_active := false
	if dock:
		var dock_tabs: TabContainer = dock.tabs
		var orca_tab := dock_tabs.get_tab_idx_from_control(dock.control)
		is_active = dock.control.visible and dock_tabs.current_tab == orca_tab
	_set_chat_window_open(not is_active)


func _set_chat_window_open(is_open: bool) -> void:
	_open_requested = is_open
	var dock := _get_dock()
	if not dock:
		_dock_root.visible = is_open
		if is_open and chat_window != null:
			chat_window.notify_dock_opened()
		return

	var dock_tabs: TabContainer = dock.tabs
	var dock_control: Control = dock.control
	var orca_tab := dock_tabs.get_tab_idx_from_control(dock_control)
	if orca_tab == -1:
		return

	if is_open:
		dock_tabs.set_tab_hidden(orca_tab, false)
		dock_control.show()
		dock_tabs.current_tab = orca_tab
		if chat_window != null:
			chat_window.notify_dock_opened()
	else:
		if dock_tabs.current_tab == orca_tab:
			_select_another_dock_tab(dock_tabs)
		dock_control.hide()
		dock_tabs.set_tab_hidden(orca_tab, true)


func _get_dock() -> Dictionary:
	var control: Control = _dock_root
	var parent = control.get_parent()
	while parent:
		if parent is TabContainer:
			return {"tabs": parent, "control": control}
		if parent is Control:
			control = parent
		parent = parent.get_parent()
	return {}


func _select_another_dock_tab(dock_tabs: TabContainer) -> void:
	if not dock_tabs.select_next_available():
		dock_tabs.select_previous_available()
