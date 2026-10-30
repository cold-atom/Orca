@tool
extends EditorPlugin

const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const AccountService = preload("res://addons/orca/scripts/account_service.gd")
const UpdateService = preload("res://addons/orca/scripts/update_service.gd")

var toolbar
var chat_window
var diagnostics_service
var game_process_service
var account_service
var update_service
var _updating := false

func _enable_plugin():
	# Add autoloads here.
	pass


func _disable_plugin():
	# Remove autoloads here.
	pass


func _enter_tree():
	# Initialization of the plugin goes here.
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
	
	toolbar = preload("res://addons/orca/scenes/orca.tscn").instantiate()
	chat_window = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	toolbar.custom_minimum_size = UiMetrics.scaled_vector(Vector2(24, 24))
	chat_window.diagnostics_service = diagnostics_service
	chat_window.game_process_service = game_process_service
	chat_window.account_service = account_service
	chat_window.update_service = update_service
	chat_window.set_custom_minimum_size(Vector2(UiMetrics.scaled(300), 0))
	
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, toolbar)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, chat_window)
	
	call_deferred("_set_chat_window_open", false)
	
	var button = toolbar.get_node("TextureButton")
	if button:
		button.pressed.connect(_toggle_chat_window)


func _exit_tree():
	# Clean-up of the plugin goes here.
	if chat_window:
		remove_control_from_docks(chat_window)
		chat_window.free()
		chat_window = null
		
	if toolbar:
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, toolbar)
		toolbar.free()
		toolbar = null
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
	if not chat_window:
		return

	var dock := _get_dock()
	var is_active := false
	if dock:
		var dock_tabs: TabContainer = dock.tabs
		var orca_tab := dock_tabs.get_tab_idx_from_control(dock.control)
		is_active = dock.control.visible and dock_tabs.current_tab == orca_tab
	_set_chat_window_open(not is_active)


func _set_chat_window_open(is_open: bool) -> void:
	var dock := _get_dock()
	if not dock:
		chat_window.visible = is_open
		if is_open:
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
		chat_window.notify_dock_opened()
	else:
		if dock_tabs.current_tab == orca_tab:
			_select_another_dock_tab(dock_tabs)
		dock_control.hide()
		dock_tabs.set_tab_hidden(orca_tab, true)


func _get_dock() -> Dictionary:
	var control: Control = chat_window
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
