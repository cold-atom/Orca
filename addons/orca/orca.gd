@tool
extends EditorPlugin

const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

var toolbar
var chat_window
var diagnostics_service
var game_process_service

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
	
	toolbar = preload("res://addons/orca/scenes/orca.tscn").instantiate()
	chat_window = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	toolbar.custom_minimum_size = UiMetrics.scaled_vector(Vector2(24, 24))
	chat_window.diagnostics_service = diagnostics_service
	chat_window.game_process_service = game_process_service
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
