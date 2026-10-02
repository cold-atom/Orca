@tool
extends Control

const ToolActivityCard = preload("res://addons/orca/scripts/tool_activity_card.gd")
const ToolActivityGroup = preload("res://addons/orca/scripts/tool_activity_group.gd")
const TaskListPanel = preload("res://addons/orca/scripts/task_list_panel.gd")
const ChangeCard = preload("res://addons/orca/scripts/change_card.gd")
const InputMapChangeCard = preload("res://addons/orca/scripts/input_map_change_card.gd")
const MainSceneChangeCard = preload("res://addons/orca/scripts/main_scene_change_card.gd")
const ProjectSettingsChangeCard = preload("res://addons/orca/scripts/project_settings_change_card.gd")
const SceneChangeCard = preload("res://addons/orca/scripts/scene_change_card.gd")
const AgentController = preload("res://addons/orca/scripts/agent_controller.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const GameProcessService = preload("res://addons/orca/scripts/game_process_service.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const ModelCatalogService = preload("res://addons/orca/scripts/model_catalog_service.gd")
const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")
const SessionStore = preload("res://addons/orca/scripts/session_store.gd")
const HistoryView = preload("res://addons/orca/scripts/history_view.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const PROMPT_MIN_LINES := 2
const PROMPT_MAX_LINES := 7
const PROMPT_MAX_DOCK_RATIO := 0.28
const CODE_MIN_VISIBLE_LINES := 2
const CODE_MAX_VISIBLE_LINES := 14
const WORKING_SQUARE_COUNT := 5
const WORKING_ANIMATION_INTERVAL := 0.095
const WORKING_ANIMATION_PHASES := 11
const SCROLL_FOLLOW_FRAMES := 4
const GROUPABLE_TOOL_NAMES := {
	"list_directory": true,
	"read_file": true,
	"search_files": true,
	"inspect_scene": true,
	"inspect_project_settings": true,
	"read_project_skill": true,
	"inspect_godot_api": true,
	"read_gdscript_function": true,
	"discover_dependencies": true,
	"get_editor_context": true,
	"get_diagnostics": true,
	"observe_game_run": true
}

@onready var chat_scroll: ScrollContainer = $MarginContainer/VBoxContainer/ChatScroll
@onready var main_content: Control = $MarginContainer
@onready var main_margin: MarginContainer = $MarginContainer
@onready var header: VBoxContainer = $MarginContainer/VBoxContainer/Header
@onready var header_top_row: HBoxContainer = $MarginContainer/VBoxContainer/Header/TopRow
@onready var chat_feed: VBoxContainer = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed
@onready var empty_state: Control = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState
@onready var empty_content: VBoxContainer = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content
@onready var empty_logo: TextureRect = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Logo
@onready var empty_description: Label = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Description
@onready var empty_mode_hint: Label = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/ModeHint
@onready var composer: PanelContainer = $MarginContainer/VBoxContainer/Composer
@onready var composer_content: VBoxContainer = $MarginContainer/VBoxContainer/Composer/ComposerContent
@onready var composer_actions: HBoxContainer = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions
@onready var prompt_input: TextEdit = $MarginContainer/VBoxContainer/Composer/ComposerContent/PromptInput
@onready var mode_selector: Control = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector
@onready var mode_button: Button = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector/ModeButton
@onready var mode_label: Label = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModeSelector/Label
@onready var model_label: Button = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ModelLabel
@onready var image_button: BaseButton = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ImageButton
@onready var send_button: BaseButton = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/SendButton
@onready var send_icon_view: TextureRect = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/SendButton/Icon
@onready var settings_button: BaseButton = $MarginContainer/VBoxContainer/Header/TopRow/SettingsButton
@onready var new_session_button: BaseButton = $MarginContainer/VBoxContainer/Header/TopRow/NewSessionButton
@onready var history_button: BaseButton = $MarginContainer/VBoxContainer/Header/TopRow/HistoryButton
@onready var header_title: Label = $MarginContainer/VBoxContainer/Header/TopRow/Title
@onready var metrics_row: Control = $MarginContainer/VBoxContainer/Header/MetricsRow
@onready var header_separator: Control = $MarginContainer/VBoxContainer/HSeparator
@onready var context_label: Label = $MarginContainer/VBoxContainer/Header/MetricsRow/ContextLabel
@onready var cost_label: Label = $MarginContainer/VBoxContainer/Header/MetricsRow/CostLabel
@onready var empty_title: Label = $MarginContainer/VBoxContainer/ChatScroll/ChatFeed/EmptyState/Content/Title
@onready var mode_overlay: Control = $ModeOverlay
@onready var mode_menu: PanelContainer = $ModeOverlay/ModeMenu
@onready var mode_menu_heading: Label = $ModeOverlay/ModeMenu/MenuMargin/Content/Heading
@onready var mode_menu_help: Label = $ModeOverlay/ModeMenu/MenuMargin/Content/Help
@onready var mode_dismiss_button: Button = $ModeOverlay/DismissButton
@onready var build_mode_panel: PanelContainer = $ModeOverlay/ModeMenu/MenuMargin/Content/BuildOption
@onready var build_mode_button: Button = $ModeOverlay/ModeMenu/MenuMargin/Content/BuildOption/SelectButton
@onready var build_mode_icon: TextureRect = $ModeOverlay/ModeMenu/MenuMargin/Content/BuildOption/RowMargin/Row/Icon
@onready var plan_mode_panel: PanelContainer = $ModeOverlay/ModeMenu/MenuMargin/Content/PlanOption
@onready var plan_mode_button: Button = $ModeOverlay/ModeMenu/MenuMargin/Content/PlanOption/SelectButton
@onready var plan_mode_icon: TextureRect = $ModeOverlay/ModeMenu/MenuMargin/Content/PlanOption/RowMargin/Row/Icon

var agent_controller
var settings_view
var diagnostics_service
var game_process_service
var model_catalog_service
var session_store
var history_view
var task_list_panel
var _send_icon: Texture2D
var _stop_icon: Texture2D
var _build_mode_icon: Texture2D
var _plan_mode_icon: Texture2D
var _stream_label: RichTextLabel
var _stream_content := ""
var _transient_card: Control
var _working_timer: Timer
var _working_status_label: Label
var _working_squares: Array[Panel] = []
var _working_phase := -1
var _tool_cards: Dictionary = {}
var _active_tool_group
var _tool_groups_by_call_id: Dictionary = {}
var _task_tool_arguments: Dictionary = {}
var _change_cards: Dictionary = {}
var _mode_items: Array[Button] = []
var _mode_panels: Array[PanelContainer] = []
var _body_font_size := 13
var _meta_font_size := 11
var _composer_style: StyleBoxFlat
var _composer_focus_style: StyleBoxFlat
var _new_session_dialog: ConfirmationDialog
var _has_session_content := false
var _session: Dictionary = {}
var _last_usage_summary: Dictionary = {}
var _tool_event_indices: Dictionary = {}
var _session_resumable := true
var _turn_had_tools := false
var _session_resume_tainted := false
var _request_active := false
var _scroll_follow_frames := 0


func _ready() -> void:
	set_process(false)
	chat_feed.resized.connect(_on_chat_feed_resized)
	if not Engine.is_editor_hint():
		return
	_send_icon = send_icon_view.texture
	var editor_theme := EditorInterface.get_editor_theme()
	_stop_icon = editor_theme.get_icon("Stop", "EditorIcons")
	_build_mode_icon = editor_theme.get_icon("Tools", "EditorIcons")
	_plan_mode_icon = editor_theme.get_icon("Script", "EditorIcons")
	var editor_font_size := editor_theme.get_font_size("font_size", "TextEdit")
	if editor_font_size <= 0:
		editor_font_size = editor_theme.get_font_size("font_size", "Label")
	if editor_font_size <= 0:
		editor_font_size = 13
	_body_font_size = maxi(editor_font_size + 1, 13)
	_meta_font_size = maxi(editor_font_size, 11)
	_apply_scaled_geometry()
	_setup_visual_theme(editor_theme)
	task_list_panel = TaskListPanel.new()
	var main_column := chat_scroll.get_parent()
	main_column.add_child(task_list_panel)
	main_column.move_child(task_list_panel, composer.get_index())
	prompt_input.add_theme_font_size_override("font_size", _body_font_size + 1)
	mode_button.add_theme_font_size_override("font_size", 1)
	mode_label.add_theme_font_size_override("font_size", maxi(_meta_font_size - 1, 11))
	model_label.add_theme_font_size_override("font_size", maxi(_meta_font_size - 1, 11))
	context_label.add_theme_font_size_override("font_size", maxi(_meta_font_size - 1, 11))
	cost_label.add_theme_font_size_override("font_size", maxi(_meta_font_size - 1, 11))
	empty_description.add_theme_font_size_override("font_size", _body_font_size + 2)
	empty_mode_hint.add_theme_font_size_override("font_size", _body_font_size + 1)
	_sync_model_ui()
	mode_selector.custom_minimum_size = model_label.get_combined_minimum_size()
	send_button.pressed.connect(_on_send_button_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	model_label.pressed.connect(_on_model_button_pressed)
	new_session_button.pressed.connect(_on_new_session_pressed)
	history_button.pressed.connect(_on_history_button_pressed)
	prompt_input.focus_entered.connect(_on_prompt_focus_changed.bind(true))
	prompt_input.focus_exited.connect(_on_prompt_focus_changed.bind(false))
	prompt_input.text_changed.connect(_sync_send_availability)
	prompt_input.text_changed.connect(_queue_prompt_height_sync)
	resized.connect(_on_dock_resized)

	agent_controller = AgentController.new()
	add_child(agent_controller)
	if diagnostics_service == null:
		diagnostics_service = DiagnosticsService.new()
		add_child(diagnostics_service)
	if game_process_service == null:
		game_process_service = GameProcessService.new()
		add_child(game_process_service)
	agent_controller.game_process_service = game_process_service
	model_catalog_service = ModelCatalogService.new()
	add_child(model_catalog_service)
	model_catalog_service.metadata_updated.connect(_on_model_metadata_updated)
	agent_controller.message_received.connect(_on_agent_message_received)
	agent_controller.error_occurred.connect(_on_agent_error_occurred)
	agent_controller.tool_execution_started.connect(_on_tool_execution_started)
	agent_controller.tool_execution_completed.connect(_on_tool_execution_completed)
	agent_controller.edit_proposed.connect(_on_edit_proposed)
	agent_controller.edit_resolved.connect(_on_edit_resolved)
	agent_controller.message_stream_started.connect(_on_message_stream_started)
	agent_controller.message_stream_delta.connect(_on_message_stream_delta)
	agent_controller.request_state_changed.connect(_set_request_active)
	agent_controller.request_cancelled.connect(_on_agent_request_cancelled)
	agent_controller.mode_changed.connect(_sync_mode_ui)
	agent_controller.session_usage_changed.connect(_sync_session_usage)
	agent_controller.model_metadata_requested.connect(model_catalog_service.refresh)
	agent_controller.tasks_changed.connect(_on_tasks_changed)
	agent_controller.workflow_state_changed.connect(_on_workflow_state_changed)
	_setup_mode_menu()

	settings_view = SettingsView.new()
	settings_view.hide()
	add_child(settings_view)
	settings_view.done_requested.connect(_on_settings_done)
	settings_view.settings_saved.connect(_on_settings_saved)
	session_store = SessionStore.new()
	history_view = HistoryView.new()
	history_view.hide()
	add_child(history_view)
	history_view.done_requested.connect(_on_history_done)
	history_view.session_requested.connect(_on_history_session_requested)
	history_view.delete_requested.connect(_on_history_delete_requested)
	history_view.delete_all_requested.connect(_on_history_delete_all_requested)
	history_view.new_session_requested.connect(_on_history_new_session_requested)
	_new_session_dialog = ConfirmationDialog.new()
	_new_session_dialog.title = "Start New Session"
	_new_session_dialog.dialog_text = "Save this conversation to History and start a new session?\n\nApplied file changes will remain."
	_new_session_dialog.ok_button_text = "Start New Session"
	_new_session_dialog.confirmed.connect(_start_new_session)
	add_child(_new_session_dialog)
	prompt_input.gui_input.connect(_on_prompt_gui_input)
	_set_request_active(false)
	_sync_metrics_visibility()
	_on_dock_resized()
	_queue_prompt_height_sync()
	agent_controller.refresh_session_usage()
	_refresh_model_metadata()
	call_deferred("_restore_active_session")


func _process(_delta: float) -> void:
	if _scroll_follow_frames <= 0:
		set_process(false)
		return
	_scroll_to_bottom_now()
	_scroll_follow_frames -= 1
	if _scroll_follow_frames <= 0:
		set_process(false)


func _exit_tree() -> void:
	if session_store != null and not _session.is_empty() and _has_session_content:
		_save_current_session()


func _setup_visual_theme(editor_theme: Theme) -> void:
	var base_color := _editor_color(editor_theme, "base_color", Color(0.12, 0.125, 0.14))
	var border_color := _editor_color(editor_theme, "contrast_color_1", Color(0.25, 0.27, 0.3))
	var accent_color := _editor_color(editor_theme, "accent_color", Color(0.12, 0.55, 0.78))
	_composer_style = _make_composer_style(base_color.darkened(0.24), border_color)
	_composer_focus_style = _make_composer_style(base_color.darkened(0.2), accent_color)
	composer.add_theme_stylebox_override("panel", _composer_style)
	var menu_style := StyleBoxFlat.new()
	menu_style.bg_color = base_color.darkened(0.3)
	menu_style.border_color = Color(accent_color.r, accent_color.g, accent_color.b, 0.65)
	menu_style.set_border_width_all(UiMetrics.scaled_int(1))
	menu_style.set_corner_radius_all(UiMetrics.scaled_int(8))
	mode_menu.add_theme_stylebox_override("panel", menu_style)
	header_title.add_theme_font_size_override("font_size", _meta_font_size + 1)
	empty_title.add_theme_font_size_override("font_size", _body_font_size + 10)


func _editor_color(editor_theme: Theme, color_name: String, fallback: Color) -> Color:
	if editor_theme.has_color(color_name, "Editor"):
		return editor_theme.get_color(color_name, "Editor")
	return fallback


func _make_composer_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(10))
	style.content_margin_left = UiMetrics.scaled(11)
	style.content_margin_top = UiMetrics.scaled(9)
	style.content_margin_right = UiMetrics.scaled(9)
	style.content_margin_bottom = UiMetrics.scaled(9)
	return style


func _apply_scaled_geometry() -> void:
	main_margin.add_theme_constant_override("margin_left", UiMetrics.scaled_int(10))
	main_margin.add_theme_constant_override("margin_top", UiMetrics.scaled_int(8))
	main_margin.add_theme_constant_override("margin_right", UiMetrics.scaled_int(10))
	main_margin.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(10))
	header.custom_minimum_size.y = UiMetrics.scaled(52)
	header.add_theme_constant_override("separation", UiMetrics.scaled_int(1))
	header_top_row.custom_minimum_size.y = UiMetrics.scaled(30)
	header_top_row.add_theme_constant_override("separation", UiMetrics.scaled_int(12))
	metrics_row.custom_minimum_size.y = UiMetrics.scaled(20)
	chat_feed.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	empty_content.add_theme_constant_override("separation", UiMetrics.scaled_int(14))
	empty_logo.custom_minimum_size = UiMetrics.scaled_vector(Vector2(60, 60))
	composer_content.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	composer_actions.custom_minimum_size.y = UiMetrics.scaled(30)
	composer_actions.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	mode_selector.custom_minimum_size = UiMetrics.scaled_vector(Vector2(82, 24))
	model_label.custom_minimum_size = UiMetrics.scaled_vector(Vector2(82, 24))
	image_button.hide()
	for button in [new_session_button, history_button, settings_button]:
		button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(28, 28))
	send_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(42, 34))
	send_icon_view.offset_left = -UiMetrics.scaled(13)
	send_icon_view.offset_top = -UiMetrics.scaled(13)
	send_icon_view.offset_right = UiMetrics.scaled(13)
	send_icon_view.offset_bottom = UiMetrics.scaled(13)
	mode_menu.custom_minimum_size.x = UiMetrics.scaled(260)
	_scale_local_styleboxes(mode_button, ["normal", "hover", "pressed", "disabled", "focus"])
	_scale_local_styleboxes(model_label, ["normal", "hover", "pressed", "disabled", "focus"])
	_scale_local_styleboxes(prompt_input, ["normal", "focus"])
	_scale_local_styleboxes(build_mode_button, ["hover", "pressed", "focus"])
	_scale_local_styleboxes(plan_mode_button, ["hover", "pressed", "focus"])
	var menu_margin := $ModeOverlay/ModeMenu/MenuMargin as MarginContainer
	_set_scaled_margins(menu_margin, 10, 10, 10, 10)
	var menu_content := $ModeOverlay/ModeMenu/MenuMargin/Content as VBoxContainer
	menu_content.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	menu_content.get_node("Separator").custom_minimum_size.y = UiMetrics.scaled(7)
	for panel in [build_mode_panel, plan_mode_panel]:
		var row_margin := panel.get_node("RowMargin") as MarginContainer
		_set_scaled_margins(row_margin, 8, 5, 8, 5)
		var row := row_margin.get_node("Row") as HBoxContainer
		row.add_theme_constant_override("separation", UiMetrics.scaled_int(9))
		row.get_node("Icon").custom_minimum_size = UiMetrics.scaled_vector(Vector2(20, 20))
		row.get_node("Check").custom_minimum_size = UiMetrics.scaled_vector(Vector2(16, 16))


func _set_scaled_margins(container: MarginContainer, left: float, top: float, right: float, bottom: float) -> void:
	container.add_theme_constant_override("margin_left", UiMetrics.scaled_int(left))
	container.add_theme_constant_override("margin_top", UiMetrics.scaled_int(top))
	container.add_theme_constant_override("margin_right", UiMetrics.scaled_int(right))
	container.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(bottom))


func _scale_local_styleboxes(control: Control, names: Array[String]) -> void:
	for style_name in names:
		var source := control.get_theme_stylebox(style_name)
		if not source is StyleBoxFlat:
			continue
		var style := (source as StyleBoxFlat).duplicate() as StyleBoxFlat
		style.border_width_left = UiMetrics.scaled_int(style.border_width_left) if style.border_width_left > 0 else 0
		style.border_width_top = UiMetrics.scaled_int(style.border_width_top) if style.border_width_top > 0 else 0
		style.border_width_right = UiMetrics.scaled_int(style.border_width_right) if style.border_width_right > 0 else 0
		style.border_width_bottom = UiMetrics.scaled_int(style.border_width_bottom) if style.border_width_bottom > 0 else 0
		style.corner_radius_top_left = UiMetrics.scaled_int(style.corner_radius_top_left) if style.corner_radius_top_left > 0 else 0
		style.corner_radius_top_right = UiMetrics.scaled_int(style.corner_radius_top_right) if style.corner_radius_top_right > 0 else 0
		style.corner_radius_bottom_right = UiMetrics.scaled_int(style.corner_radius_bottom_right) if style.corner_radius_bottom_right > 0 else 0
		style.corner_radius_bottom_left = UiMetrics.scaled_int(style.corner_radius_bottom_left) if style.corner_radius_bottom_left > 0 else 0
		if style.content_margin_left >= 0:
			style.content_margin_left = UiMetrics.scaled(style.content_margin_left)
		if style.content_margin_top >= 0:
			style.content_margin_top = UiMetrics.scaled(style.content_margin_top)
		if style.content_margin_right >= 0:
			style.content_margin_right = UiMetrics.scaled(style.content_margin_right)
		if style.content_margin_bottom >= 0:
			style.content_margin_bottom = UiMetrics.scaled(style.content_margin_bottom)
		control.add_theme_stylebox_override(style_name, style)


func _on_prompt_focus_changed(focused: bool) -> void:
	composer.add_theme_stylebox_override("panel", _composer_focus_style if focused else _composer_style)


func _sync_send_availability() -> void:
	var request_active: bool = agent_controller != null and agent_controller.is_busy()
	send_button.disabled = not request_active and (not _session_resumable or prompt_input.text.strip_edges().is_empty())
	_sync_send_icon_tint(request_active)


func _sync_send_icon_tint(request_active: bool) -> void:
	send_icon_view.modulate = Color.WHITE if request_active or not send_button.disabled else Color(0.42, 0.45, 0.5, 0.65)


func _queue_prompt_height_sync() -> void:
	if prompt_input.has_meta("height_sync_queued"):
		return
	prompt_input.set_meta("height_sync_queued", true)
	call_deferred("_sync_prompt_height")


func _sync_prompt_height() -> void:
	prompt_input.remove_meta("height_sync_queued")
	var visual_lines := 0
	for line in range(prompt_input.get_line_count()):
		visual_lines += 1 + prompt_input.get_line_wrap_count(line)
	var input_style := prompt_input.get_theme_stylebox("normal")
	var line_height := maxf(prompt_input.get_line_height(), _body_font_size + UiMetrics.scaled(3))
	var style_height := input_style.get_minimum_size().y
	var content_height := visual_lines * line_height + style_height
	var minimum_height := PROMPT_MIN_LINES * line_height + style_height
	var line_maximum := PROMPT_MAX_LINES * line_height + style_height
	var dock_maximum := maxf(minimum_height, size.y * PROMPT_MAX_DOCK_RATIO)
	prompt_input.custom_minimum_size.y = clampf(ceilf(content_height), ceilf(minimum_height), ceilf(minf(line_maximum, dock_maximum)))


func _clear_prompt_input() -> void:
	prompt_input.text = ""
	_queue_prompt_height_sync()


func _on_prompt_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		if event.shift_pressed:
			return
		get_viewport().set_input_as_handled()
		if agent_controller != null and agent_controller.is_busy():
			return
		_on_send_button_pressed()


func _on_send_button_pressed() -> void:
	if agent_controller != null and agent_controller.is_busy():
		agent_controller.cancel_current_request()
		return
	if not _session_resumable:
		return
	var text := prompt_input.text.strip_edges()
	if text.is_empty():
		return
	_clear_prompt_input()
	prompt_input.placeholder_text = "Describe what you want to build or fix..."
	_has_session_content = true
	_sync_metrics_visibility()
	_add_message("User", text, Color.LIGHT_SKY_BLUE, "user")
	_ensure_session()
	if str(_session.get("last_prompt", "")).is_empty():
		_session["title"] = _session_title(text)
	_session["last_prompt"] = text.left(240)
	_session["mode"] = agent_controller.get_mode()
	_session["provider"] = Config.get_provider()
	_session["model"] = Config.get_model()
	_session["clean"] = false
	_session["resumable"] = not _session_resume_tainted
	_turn_had_tools = false
	_append_session_event(_message_event("User", text, "user", "complete"))
	_set_request_active(true)
	_show_working_indicator("Thinking")
	agent_controller.send_user_message(text)
	_save_current_session()


func _on_tool_execution_started(call_id: String, tool_name: String, arguments: Dictionary) -> void:
	_turn_had_tools = true
	_finish_stream_before_activity()
	_remove_transient_card()
	if tool_name == "update_tasks":
		_close_active_tool_group()
		_task_tool_arguments[call_id] = arguments.duplicate(true)
		return
	var card
	if GROUPABLE_TOOL_NAMES.has(tool_name):
		card = _add_grouped_tool_card(call_id, tool_name, arguments)
	else:
		_close_active_tool_group()
		card = ToolActivityCard.new()
		chat_feed.add_child(card)
		card.configure(tool_name, arguments)
		card.open_requested.connect(_on_open_file_requested)
		card.help_requested.connect(_on_help_requested)
	_tool_cards[call_id] = card
	var event := {
		"type": "tool",
		"timestamp": Time.get_unix_time_from_system(),
		"id": call_id,
		"name": tool_name,
		"arguments": _safe_tool_arguments(arguments, tool_name),
		"outcome": "running",
		"summary": "Running",
		"duration_ms": 0
	}
	_tool_event_indices[call_id] = _session.get("events", []).size()
	_append_session_event(event)
	_scroll_to_bottom()


func _on_tool_execution_completed(call_id: String, tool_name: String, execution: Dictionary, duration_ms: int) -> void:
	if tool_name == "update_tasks":
		var arguments: Dictionary = _task_tool_arguments.get(call_id, {})
		_task_tool_arguments.erase(call_id)
		if not execution.get("success", false):
			var card = ToolActivityCard.new()
			chat_feed.add_child(card)
			card.configure(tool_name, arguments)
			card.complete(execution, duration_ms)
			var events: Array = _session.get("events", [])
			_tool_event_indices[call_id] = events.size()
			_append_session_event({
				"type": "tool",
				"timestamp": Time.get_unix_time_from_system(),
				"id": call_id,
				"name": tool_name,
				"arguments": {},
				"outcome": str(execution.get("outcome", "failed")),
				"summary": str(execution.get("content", "Task checklist update failed.")),
				"duration_ms": duration_ms
			})
		_save_current_session()
		_scroll_to_bottom()
		return
	if _tool_groups_by_call_id.has(call_id) and is_instance_valid(_tool_groups_by_call_id[call_id]):
		_tool_groups_by_call_id[call_id].complete_tool(call_id, execution, duration_ms)
	elif _tool_cards.has(call_id) and is_instance_valid(_tool_cards[call_id]):
		_tool_cards[call_id].complete(execution, duration_ms)
	_update_tool_event(call_id, execution, duration_ms)
	_save_current_session()
	_scroll_to_bottom()


func _on_tasks_changed(tasks: Array) -> void:
	_ensure_session()
	_session["tasks"] = tasks.duplicate(true)
	if task_list_panel != null:
		task_list_panel.set_tasks(tasks)
	_save_current_session()


func _on_workflow_state_changed(state: String, details: Dictionary) -> void:
	match state:
		"thinking":
			_show_working_indicator("Preparing response" if bool(details.get("follow_up", false)) else "Thinking")
		"observing":
			_show_working_indicator("Observing game")
		"assessment_ready":
			if agent_controller.is_busy():
				_show_working_indicator("Assessing results")
			else:
				_remove_transient_card()
		_:
			_remove_transient_card()


func _on_edit_proposed(proposal: Dictionary) -> void:
	_close_active_tool_group()
	var change_id: String = proposal.get("id", "")
	if _change_cards.has(change_id) and is_instance_valid(_change_cards[change_id]) and str(proposal.get("kind", "")) == "scene":
		_change_cards[change_id].configure(proposal)
		_update_staged_change_event(proposal)
		_save_current_session()
		_scroll_to_bottom()
		return
	if _tool_cards.has(change_id) and is_instance_valid(_tool_cards[change_id]):
		_tool_cards[change_id].queue_free()
		_tool_cards.erase(change_id)
	var card
	match str(proposal.get("kind", "file_patch")):
		"input_map":
			card = InputMapChangeCard.new()
		"main_scene":
			card = MainSceneChangeCard.new()
		"project_settings":
			card = ProjectSettingsChangeCard.new()
		"scene":
			card = SceneChangeCard.new()
		_:
			card = ChangeCard.new()
	chat_feed.add_child(card)
	card.configure(proposal)
	card.action_requested.connect(_on_change_action_requested)
	card.open_requested.connect(_on_open_file_requested)
	_change_cards[change_id] = card
	var diff: Dictionary = proposal.get("diff", {})
	var validation: Dictionary = proposal.get("validation", {})
	_append_session_event({
		"type": "change",
		"timestamp": Time.get_unix_time_from_system(),
		"id": change_id,
		"filepath": str(proposal.get("filepath", "")),
		"kind": str(proposal.get("kind", "file_patch")),
		"summary": _proposal_summary(proposal),
		"status": "pending",
		"additions": int(diff.get("additions", 0)),
		"deletions": int(diff.get("deletions", 0)),
		"validation_message": str(validation.get("message", "")),
		"existed": bool(proposal.get("existed", false))
	})
	_recount_changed_files()
	_save_current_session()
	_scroll_to_bottom()


func _proposal_summary(proposal: Dictionary) -> String:
	if proposal.get("kind", "file_patch") == "scene":
		var root: Dictionary = proposal.get("scene_summary", {})
		var target := str(proposal.get("filepath", ""))
		match str(root.get("operation", "create_scene")):
			"attach_script", "detach_script":
				var verb := "Attach" if str(root.get("operation", "")) == "attach_script" else "Detach"
				var script_path := str(root.get("script_path", ""))
				if script_path.is_empty():
					script_path = str(root.get("after_script", "")) if not str(root.get("after_script", "")).is_empty() else str(root.get("before_script", ""))
				return ("%s script: %s - %s at %s" % [verb, target, script_path, str(root.get("node_path", ""))]).left(512)
			"add_node":
				var added: Dictionary = root.get("added_node", {})
				return ("Add node: %s - %s \"%s\" at %s" % [target, str(added.get("type", "")), str(added.get("name", "")), str(added.get("parent_path", ""))]).left(512)
			"set_property":
				return ("Set property: %s - %s.%s" % [target, str(root.get("node_path", "")), str(root.get("property_name", ""))]).left(512)
			"rename_node":
				return ("Rename node: %s - %s to %s" % [target, str(root.get("old_path", "")), str(root.get("new_name", ""))]).left(512)
			"remove_node":
				return ("Remove node: %s - %s" % [target, str(root.get("removed_node", {}).get("path", ""))]).left(512)
			"reparent_node":
				return ("Reparent node: %s - %s to %s" % [target, str(root.get("old_path", "")), str(root.get("new_parent_path", ""))]).left(512)
			"instantiate_child_scene":
				return ("Instantiate scene: %s - %s at %s" % [target, str(root.get("instance", {}).get("scene_path", "")), str(root.get("instance", {}).get("parent_path", ""))]).left(512)
			"connect_signal", "disconnect_signal":
				var connection: Dictionary = root.get("connection", {})
				var flag_suffix := ""
				if (int(connection.get("flags", 0)) & Object.CONNECT_DEFERRED) != 0:
					flag_suffix += " deferred"
				if (int(connection.get("flags", 0)) & Object.CONNECT_ONE_SHOT) != 0:
					flag_suffix += " one-shot"
				return ("%s signal: %s - %s.%s to %s.%s%s" % ["Connect" if str(root.get("operation")) == "connect_signal" else "Disconnect", target, str(connection.get("source", "")), str(connection.get("signal", "")), str(connection.get("target", "")), str(connection.get("method", "")), flag_suffix]).left(512)
		return ("Create scene: %s - %s \"%s\"" % [target, str(root.get("root_type", "")), str(root.get("root_name", ""))]).left(512)
	if proposal.get("kind", "file_patch") == "main_scene":
		return ("Main scene: " + str(proposal.get("new_scene_path", ""))).left(512)
	if proposal.get("kind", "file_patch") == "project_settings":
		var labels := PackedStringArray()
		for item in proposal.get("review", []):
			labels.append(str(item.get("label", item.get("setting_path", ""))))
		return ("Project settings: " + ", ".join(labels)).left(512)
	if proposal.get("kind", "file_patch") != "input_map":
		return "File patch"
	var names: Array = proposal.get("action_names", [])
	var shown := PackedStringArray()
	for index in range(mini(names.size(), 8)):
		shown.append(str(names[index]))
	var summary := "Input Map: " + ", ".join(shown)
	if names.size() > shown.size():
		summary += " and %d more" % (names.size() - shown.size())
	return summary.left(512)


func _on_edit_resolved(change_id: String, status: String, message: String) -> void:
	if _change_cards.has(change_id) and is_instance_valid(_change_cards[change_id]):
		_change_cards[change_id].set_status(status, message)
	_update_change_event(change_id, status)
	_recount_changed_files()
	_save_current_session()
	_scroll_to_bottom()


func _on_change_action_requested(change_id: String, action: String) -> void:
	match action:
		"apply":
			agent_controller.resolve_edit(change_id, true)
		"reject":
			agent_controller.resolve_edit(change_id, false)
		"revert":
			agent_controller.revert_edit(change_id)


func _on_open_file_requested(filepath: String, line: int, column: int) -> void:
	if not EditorContext.open_file(filepath, line, column):
		_add_message("System Error", "Could not open " + filepath, Color.INDIAN_RED, "error")


func _on_help_requested(topic: String) -> void:
	if not ToolActivityCard.is_safe_help_topic(topic) or not Engine.is_editor_hint():
		return
	EditorInterface.get_script_editor().goto_help(topic)


func _on_agent_message_received(_role: String, content: String) -> void:
	_close_active_tool_group()
	_set_request_active(false)
	_remove_transient_card()
	if _stream_label != null and is_instance_valid(_stream_label):
		_stream_content = content
		_finalize_assistant_message(_stream_label, "Orca", content, _assistant_color())
		_stream_label = null
		_stream_content = ""
	elif not content.is_empty():
		_add_final_assistant_message("Orca", content, _assistant_color())
	if not content.is_empty():
		_append_session_event(_message_event("Orca", content, "assistant", "complete"))
	_session["clean"] = true
	_session["resumable"] = not _session_resume_tainted
	prompt_input.placeholder_text = "Describe what you want to build or fix..."
	_turn_had_tools = false
	_save_current_session()
	_scroll_to_bottom()


func _on_agent_error_occurred(message: String) -> void:
	_set_request_active(false)
	_remove_transient_card()
	var recovered: bool = _turn_had_tools and agent_controller != null and agent_controller.has_method("last_failure_was_checkpointed") and bool(agent_controller.last_failure_was_checkpointed())
	var partial_content := _stream_content
	if _stream_label != null and is_instance_valid(_stream_label):
		if _stream_content.is_empty():
			_stream_label.get_parent().queue_free()
		else:
			_update_message_label(_stream_label, "Orca (incomplete)", _stream_content, Color(0.78, 0.64, 0.36))
	_stream_label = null
	_stream_content = ""
	_add_message("Recovery Ready" if recovered else "System Error", message, Color(0.78, 0.64, 0.36) if recovered else Color.INDIAN_RED, "status" if recovered else "error")
	if not partial_content.is_empty():
		_append_session_event(_message_event("Orca (incomplete)", partial_content, "assistant", "incomplete"))
	_append_session_event(_message_event("Recovery Ready" if recovered else "System Error", message, "status" if recovered else "error", "complete"))
	_session["clean"] = true
	if _turn_had_tools:
		_set_interrupted_turn_resumability(recovered)
	_turn_had_tools = false
	_save_current_session()
	print("Orca Error: ", message)


func _set_interrupted_turn_resumability(recovered: bool) -> void:
	_session_resume_tainted = not recovered
	_session["resumable"] = recovered
	_session_resumable = recovered
	prompt_input.editable = recovered
	prompt_input.placeholder_text = "Continue from the recovery checkpoint..." if recovered else "Start a new chat to continue after this interrupted tool turn"
	_sync_send_availability()


func _on_message_stream_started() -> void:
	_stream_content = ""
	_stream_label = null


func _on_message_stream_delta(content: String) -> void:
	if content.is_empty():
		return
	if _stream_label == null or not is_instance_valid(_stream_label):
		_remove_transient_card()
		_stream_label = _add_message("Orca", "", _assistant_color(), "assistant")
	_stream_content += content
	_update_message_label(_stream_label, "Orca", _stream_content, _assistant_color())
	_scroll_to_bottom()


func _finish_stream_before_activity() -> void:
	if _stream_label == null or not is_instance_valid(_stream_label):
		return
	if _stream_content.is_empty():
		_stream_label.get_parent().queue_free()
	else:
		_finalize_assistant_message(_stream_label, "Orca", _stream_content, _assistant_color())
		_append_session_event(_message_event("Orca", _stream_content, "assistant", "tool_preface"))
	_stream_label = null
	_stream_content = ""


func _on_agent_request_cancelled() -> void:
	_set_request_active(false)
	_remove_transient_card()
	var partial_content := _stream_content
	_stream_label = null
	_stream_content = ""
	if not partial_content.is_empty():
		_append_session_event(_message_event("Orca", partial_content, "assistant", "cancelled"))
	_add_message("Orca", "Response stopped.", Color(0.5, 0.53, 0.58), "status")
	_append_session_event(_message_event("Orca", "Response stopped.", "status", "complete"))
	_session["clean"] = true
	if _turn_had_tools:
		_session_resume_tainted = true
		_session["resumable"] = false
		_session_resumable = false
		prompt_input.editable = false
		prompt_input.placeholder_text = "Start a new chat to continue after this interrupted tool turn"
		_sync_send_availability()
	_turn_had_tools = false
	_save_current_session()


func _set_request_active(active: bool) -> void:
	_request_active = active
	send_icon_view.texture = _stop_icon if active else _send_icon
	send_button.tooltip_text = "Stop response" if active else "Send message"
	send_button.disabled = false if active else prompt_input.text.strip_edges().is_empty()
	_sync_send_icon_tint(active)
	mode_button.disabled = active or not _session_resumable
	new_session_button.disabled = active
	history_button.disabled = active
	settings_button.disabled = active
	model_label.disabled = active
	prompt_input.editable = _session_resumable
	mode_label.modulate = Color(1, 1, 1, 0.5) if active else Color.WHITE


func _setup_mode_menu() -> void:
	build_mode_icon.texture = _build_mode_icon
	build_mode_icon.self_modulate = Color(0.57, 0.84, 0.63)
	plan_mode_icon.texture = _plan_mode_icon
	plan_mode_icon.self_modulate = Color(0.94, 0.64, 0.35)
	mode_menu_heading.add_theme_font_size_override("font_size", _body_font_size + 1)
	mode_menu_help.add_theme_font_size_override("font_size", _meta_font_size)

	_mode_items.append(build_mode_button)
	_mode_items.append(plan_mode_button)
	_mode_panels.append(build_mode_panel)
	_mode_panels.append(plan_mode_panel)
	build_mode_button.set_meta("mode_id", AgentController.AgentMode.BUILD)
	build_mode_button.set_meta("accent_color", Color(0.57, 0.84, 0.63))
	plan_mode_button.set_meta("mode_id", AgentController.AgentMode.PLAN)
	plan_mode_button.set_meta("accent_color", Color(0.94, 0.64, 0.35))

	for panel in _mode_panels:
		var title: Label = panel.get_node("RowMargin/Row/Text/Title")
		var description: Label = panel.get_node("RowMargin/Row/Text/Description")
		title.add_theme_font_size_override("font_size", _body_font_size)
		description.add_theme_font_size_override("font_size", _meta_font_size)

	build_mode_button.pressed.connect(_on_mode_selected.bind(AgentController.AgentMode.BUILD))
	plan_mode_button.pressed.connect(_on_mode_selected.bind(AgentController.AgentMode.PLAN))
	mode_dismiss_button.pressed.connect(_hide_mode_menu)
	mode_button.pressed.connect(_on_mode_button_pressed)
	_sync_mode_ui(agent_controller.get_mode())

func _on_mode_button_pressed() -> void:
	if not _session_resumable:
		return
	if mode_overlay.visible:
		_hide_mode_menu()
	else:
		mode_overlay.show()
		_position_mode_menu()
		call_deferred("_position_mode_menu")


func _position_mode_menu() -> void:
	if not mode_overlay.visible:
		return
	var menu_minimum := mode_menu.get_combined_minimum_size()
	var edge_gap := UiMetrics.scaled(4)
	var menu_width := minf(maxf(menu_minimum.x, composer.size.x), size.x - edge_gap * 2.0)
	mode_menu.size = Vector2(menu_width, menu_minimum.y)
	var local_button_position := mode_selector.global_position - global_position
	var local_composer_position := composer.global_position - global_position
	var menu_x := clampf(local_composer_position.x, edge_gap, maxf(edge_gap, size.x - menu_width - edge_gap))
	var menu_y := local_button_position.y - mode_menu.size.y - edge_gap
	if menu_y < edge_gap:
		menu_y = local_button_position.y + mode_selector.size.y + edge_gap
	mode_menu.position = Vector2(menu_x, menu_y)


func _hide_mode_menu() -> void:
	mode_overlay.hide()
	mode_button.grab_focus()

func _on_mode_selected(mode: int) -> void:
	if agent_controller.set_mode(mode):
		_sync_mode_ui(mode)
		if not _session.is_empty():
			_session["mode"] = mode
			_save_current_session()
	_hide_mode_menu()

func _sync_mode_ui(mode: int) -> void:
	var is_build := mode == AgentController.AgentMode.BUILD
	mode_label.text = "Work" if is_build else "Plan"
	mode_label.add_theme_color_override(
		"font_color",
		Color(0.68, 0.9, 0.72) if is_build else Color(0.97, 0.71, 0.43)
	)
	mode_button.tooltip_text = (
		"Work mode: Explore, run the game, and propose reviewed project changes"
		if is_build
		else "Plan mode: Analyze and design without changing files"
	)
	for index in range(_mode_items.size()):
		var btn := _mode_items[index]
		var panel := _mode_panels[index]
		var check: TextureRect = panel.get_node("RowMargin/Row/Check")
		var selected: bool = btn.get_meta("mode_id") == mode
		check.visible = selected
		if selected:
			var selected_style := StyleBoxFlat.new()
			var selected_color: Color = btn.get_meta("accent_color")
			selected_style.bg_color = Color(selected_color.r, selected_color.g, selected_color.b, 0.12)
			selected_style.set_corner_radius_all(UiMetrics.scaled_int(6))
			panel.add_theme_stylebox_override("panel", selected_style)
		else:
			panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())


func _on_settings_saved(_provider_id: String, _model: String) -> void:
	_sync_model_ui()
	agent_controller.refresh_session_usage()
	_refresh_model_metadata()


func _on_settings_done() -> void:
	settings_view.hide()
	main_content.show()
	prompt_input.grab_focus()


func _sync_model_ui() -> void:
	var model := Config.get_model().strip_edges()
	model_label.text = model if not model.is_empty() else "No model"
	model_label.tooltip_text = "Current model: %s\nClick to configure" % model_label.text


func _refresh_model_metadata() -> void:
	model_catalog_service.refresh(Config.get_model(), Config.get_api_url())


func _on_model_metadata_updated() -> void:
	agent_controller.refresh_session_usage()


func _on_new_session_pressed() -> void:
	if agent_controller == null or agent_controller.is_busy():
		return
	if _has_session_content:
		_new_session_dialog.popup_centered()
	else:
		_start_new_session()


func _start_new_session() -> void:
	if not _save_current_session():
		return
	if not session_store.set_active_session(""):
		_add_message("System Error", "Could not clear the active conversation checkpoint.", Color.INDIAN_RED, "error")
		return
	if not agent_controller.start_new_session():
		return
	_session = session_store.create_session(agent_controller.get_mode(), Config.get_provider(), Config.get_model())
	_session_resumable = true
	_session_resume_tainted = false
	_last_usage_summary = {}
	_remove_transient_card()
	_stream_label = null
	_stream_content = ""
	_tool_cards.clear()
	_change_cards.clear()
	_tool_event_indices.clear()
	_task_tool_arguments.clear()
	_turn_had_tools = false
	_clear_chat_feed()
	if task_list_panel != null:
		task_list_panel.clear()
	_clear_prompt_input()
	prompt_input.editable = true
	prompt_input.placeholder_text = "Describe what you want to build or fix..."
	_has_session_content = false
	_sync_metrics_visibility()
	if mode_overlay.visible:
		mode_overlay.hide()
	if history_view != null:
		history_view.hide()
	main_content.show()
	chat_scroll.scroll_vertical = 0
	prompt_input.grab_focus()
	_sync_send_availability()


func _restore_active_session() -> void:
	var active: Dictionary = session_store.load_active_session()
	if active.is_empty():
		_session = session_store.create_session(agent_controller.get_mode(), Config.get_provider(), Config.get_model())
		if task_list_panel != null:
			task_list_panel.clear()
		return
	if not bool(active.get("clean", true)):
		active["resumable"] = false
		active["updated_at"] = Time.get_unix_time_from_system()
		session_store.save_session(active)
	_restore_session(active)


func _restore_session(session: Dictionary) -> bool:
	var resumable := bool(session.get("clean", true)) and bool(session.get("resumable", true)) and not bool(session.get("truncated", false))
	var previous_session_id := str(_session.get("id", ""))
	if not session_store.set_active_session(str(session.get("id", ""))):
		return false
	if not agent_controller.restore_session_state(int(session.get("mode", AgentController.AgentMode.BUILD)), session.get("continuation", []), session.get("usage", {}), session.get("tasks", [])):
		session_store.set_active_session(previous_session_id)
		return false
	_session = session.duplicate(true)
	if task_list_panel != null:
		task_list_panel.set_tasks(_session.get("tasks", []))
	_session_resumable = resumable
	_session_resume_tainted = not resumable
	_tool_cards.clear()
	_change_cards.clear()
	_tool_event_indices.clear()
	_clear_chat_feed()
	for event in _session.get("events", []):
		_render_session_event(event)
	_close_active_tool_group()
	_has_session_content = not _session.get("events", []).is_empty()
	_sync_metrics_visibility()
	if not _session_resumable:
		_add_message("History", "This interrupted or truncated session is view-only. Start a new chat to continue.", Color(0.78, 0.64, 0.36), "status")
	prompt_input.editable = _session_resumable
	prompt_input.placeholder_text = "Describe what you want to build or fix..." if _session_resumable else "This saved session is view-only"
	_sync_send_availability()
	_scroll_to_bottom()
	return true


func _on_history_button_pressed() -> void:
	if agent_controller == null or agent_controller.is_busy():
		return
	if not _save_current_session():
		return
	if mode_overlay.visible:
		mode_overlay.hide()
	settings_view.hide()
	history_view.set_sessions(session_store.list_sessions(), str(_session.get("id", "")))
	main_content.hide()
	history_view.show()


func _on_history_done() -> void:
	history_view.hide()
	main_content.show()
	if _session_resumable:
		prompt_input.grab_focus()


func _on_history_session_requested(session_id: String) -> void:
	if not _save_current_session():
		return
	var selected: Dictionary = session_store.load_session(session_id)
	if selected.is_empty() or not _restore_session(selected):
		history_view.set_sessions(session_store.list_sessions(), str(_session.get("id", "")))
		return
	history_view.hide()
	main_content.show()


func _on_history_delete_requested(session_id: String) -> void:
	var deleting_current := session_id == str(_session.get("id", ""))
	var result: Dictionary = session_store.delete_session(session_id)
	if not bool(result.get("committed", false)):
		return
	if deleting_current:
		_session.clear()
		_start_new_session()
	else:
		history_view.set_sessions(session_store.list_sessions(), str(_session.get("id", "")))
	_show_storage_cleanup_warning(result)


func _on_history_delete_all_requested() -> void:
	var result: Dictionary = session_store.delete_all_sessions()
	if not bool(result.get("committed", false)):
		return
	_session.clear()
	_start_new_session()
	_show_storage_cleanup_warning(result)


func _on_history_new_session_requested() -> void:
	_start_new_session()


func _ensure_session() -> void:
	if _session.is_empty():
		_session = session_store.create_session(agent_controller.get_mode(), Config.get_provider(), Config.get_model())


func _save_current_session() -> bool:
	if session_store == null or _session.is_empty() or not _has_session_content:
		return true
	var snapshot: Dictionary = agent_controller.snapshot_session_state()
	_session["mode"] = snapshot.get("mode", agent_controller.get_mode())
	_session["continuation"] = snapshot.get("continuation", [])
	_session["usage"] = snapshot.get("usage", _last_usage_summary)
	_session["tasks"] = snapshot.get("tasks", _session.get("tasks", []))
	_session["updated_at"] = Time.get_unix_time_from_system()
	var result: Dictionary = session_store.save_session(_session)
	if bool(result.get("success", false)):
		_session = result.get("session", _session)
		_rebuild_tool_event_indices()
		if not str(result.get("warning", "")).is_empty():
			_add_message("Storage Warning", str(result["warning"]), Color(0.78, 0.64, 0.36), "status")
		return true
	else:
		var message := "Could not save this conversation: " + str(result.get("error", "Unknown error"))
		print("Orca session save failed: ", message)
		_add_message("System Error", message, Color.INDIAN_RED, "error")
		return false


func _append_session_event(event: Dictionary) -> void:
	_ensure_session()
	var events: Array = _session.get("events", [])
	events.append(event)
	_session["events"] = events
	_has_session_content = true


func _message_event(sender: String, text: String, kind: String, completion: String) -> Dictionary:
	return {
		"type": "message",
		"timestamp": Time.get_unix_time_from_system(),
		"sender": sender,
		"text": text,
		"kind": kind,
		"mode": agent_controller.get_mode(),
		"completion": completion
	}


func _safe_tool_arguments(arguments: Dictionary, tool_name: String = "") -> Dictionary:
	var result := {}
	if tool_name == "read_project_skill":
		if typeof(arguments.get("name")) == TYPE_STRING:
			result["name"] = str(arguments["name"]).left(128)
		return result
	if tool_name == "inspect_godot_api":
		for key in ["class_name", "member_name"]:
			if typeof(arguments.get(key)) == TYPE_STRING:
				result[key] = str(arguments[key]).left(256)
		if typeof(arguments.get("member_kind")) == TYPE_STRING and str(arguments["member_kind"]) in ["auto", "method", "property", "signal", "constant", "enum"]:
			result["member_kind"] = arguments["member_kind"]
		if typeof(arguments.get("include_inherited")) == TYPE_BOOL:
			result["include_inherited"] = arguments["include_inherited"]
		return result
	if tool_name == "read_gdscript_function":
		if typeof(arguments.get("filepath")) == TYPE_STRING:
			result["filepath"] = str(arguments["filepath"]).left(512)
		if typeof(arguments.get("function_name")) == TYPE_STRING:
			result["function_name"] = str(arguments["function_name"]).left(128)
		if typeof(arguments.get("start_line_hint")) == TYPE_INT:
			result["start_line_hint"] = maxi(1, int(arguments["start_line_hint"]))
		if typeof(arguments.get("include_documentation")) == TYPE_BOOL:
			result["include_documentation"] = arguments["include_documentation"]
		return result
	if tool_name == "discover_dependencies":
		if typeof(arguments.get("filepath")) == TYPE_STRING:
			result["filepath"] = str(arguments["filepath"]).left(512)
		if typeof(arguments.get("direction")) == TYPE_STRING and str(arguments["direction"]) in ["forward", "reverse"]:
			result["direction"] = arguments["direction"]
		if typeof(arguments.get("max_depth")) == TYPE_INT:
			result["max_depth"] = clampi(int(arguments["max_depth"]), 1, 3)
		if typeof(arguments.get("max_results")) == TYPE_INT:
			result["max_results"] = clampi(int(arguments["max_results"]), 1, 100)
		return result
	var keys := ["filepath", "path", "scene_path", "setting_path", "query", "file_glob", "start_line", "end_line", "case_sensitive", "max_results", "include_properties", "max_nodes", "max_properties_per_node"]
	for key in keys:
		if arguments.has(key):
			result[key] = arguments[key]
	return result


func _update_tool_event(call_id: String, execution: Dictionary, duration_ms: int) -> void:
	if not _tool_event_indices.has(call_id):
		return
	var events: Array = _session.get("events", [])
	var index := int(_tool_event_indices[call_id])
	if index < 0 or index >= events.size():
		return
	var event: Dictionary = events[index]
	var outcome := str(execution.get("outcome", "failed"))
	event["outcome"] = outcome
	event["duration_ms"] = duration_ms
	var data: Dictionary = execution.get("data", {})
	if str(event.get("name", "")) == "verify_game_run" and outcome == "completed":
		event["summary"] = "Verification %s." % str(data.get("status", "unverified")).replace("_", " ")
	elif str(event.get("name", "")) in ["run_current_scene", "run_main_scene", "stop_game"] and outcome == "completed":
		event["summary"] = "Game process: " + str(data.get("state", "updated")).replace("_", " ")
	else:
		event["summary"] = "Failed. See the live session for details." if outcome == "failed" else "Completed successfully."
	if data.has("open_path"):
		event["open_path"] = str(data.get("open_path", ""))
		event["open_line"] = maxi(1, int(data.get("open_line", 1)))
		event["open_column"] = maxi(1, int(data.get("open_column", 1)))
	var help_topic := str(data.get("help_topic", ""))
	if ToolActivityCard.is_safe_help_topic(help_topic):
		event["help_topic"] = help_topic
	events[index] = event
	_session["events"] = events


func _update_change_event(change_id: String, status: String) -> void:
	var events: Array = _session.get("events", [])
	for index in range(events.size() - 1, -1, -1):
		var event = events[index]
		if typeof(event) == TYPE_DICTIONARY and event.get("type") == "change" and str(event.get("id", "")) == change_id:
			event["status"] = status
			events[index] = event
			break
	_session["events"] = events


func _update_staged_change_event(proposal: Dictionary) -> void:
	var events: Array = _session.get("events", [])
	for index in range(events.size() - 1, -1, -1):
		var event = events[index]
		if typeof(event) == TYPE_DICTIONARY and event.get("type") == "change" and str(event.get("id", "")) == str(proposal.get("id", "")):
			event["summary"] = _proposal_summary(proposal)
			event["status"] = "pending"
			event["validation_message"] = str(proposal.get("validation", {}).get("message", ""))
			events[index] = event
			break
	_session["events"] = events


func _recount_changed_files() -> void:
	var changed: Dictionary = {}
	for event in _session.get("events", []):
		if typeof(event) == TYPE_DICTIONARY and event.get("type") == "change" and str(event.get("status", "")) in ["applied", "applied_recovery", "revert_failed"]:
			changed[str(event.get("filepath", ""))] = true
	_session["changed_file_count"] = changed.size()


func _rebuild_tool_event_indices() -> void:
	_tool_event_indices.clear()
	var events: Array = _session.get("events", [])
	for index in range(events.size()):
		var event = events[index]
		if typeof(event) == TYPE_DICTIONARY and event.get("type") == "tool":
			_tool_event_indices[str(event.get("id", ""))] = index


func _render_session_event(event: Dictionary) -> void:
	match str(event.get("type", "")):
		"message":
			var kind := str(event.get("kind", "status"))
			var color := Color(0.5, 0.53, 0.58)
			if kind == "user":
				color = Color.LIGHT_SKY_BLUE
			elif kind == "assistant":
				color = _assistant_color_for_mode(int(event.get("mode", AgentController.AgentMode.BUILD)))
			elif kind == "error":
				color = Color.INDIAN_RED
			var sender := str(event.get("sender", ""))
			var text := str(event.get("text", ""))
			var completion := str(event.get("completion", "complete"))
			if kind == "assistant" and completion in ["complete", "tool_preface"]:
				_add_final_assistant_message(sender, text, color)
			else:
				_add_message(sender, text, color, kind)
		"tool":
			var tool_name := str(event.get("name", ""))
			var call_id := str(event.get("id", ""))
			var card
			if GROUPABLE_TOOL_NAMES.has(tool_name):
				card = _add_grouped_tool_card(call_id, tool_name, event.get("arguments", {}))
			else:
				_close_active_tool_group()
				card = ToolActivityCard.new()
				chat_feed.add_child(card)
				card.configure(tool_name, event.get("arguments", {}))
				card.open_requested.connect(_on_open_file_requested)
				card.help_requested.connect(_on_help_requested)
			var outcome := str(event.get("outcome", "interrupted"))
			if outcome == "running":
				outcome = "interrupted"
			var data := {}
			if not str(event.get("open_path", "")).is_empty():
				data = {"open_path": str(event.get("open_path", "")), "open_line": int(event.get("open_line", 1)), "open_column": int(event.get("open_column", 1))}
			if ToolActivityCard.is_safe_help_topic(str(event.get("help_topic", ""))):
				data["help_topic"] = str(event.get("help_topic", ""))
			var execution := {"content": str(event.get("summary", "")), "outcome": outcome, "data": data}
			if _tool_groups_by_call_id.has(call_id):
				_tool_groups_by_call_id[call_id].complete_tool(call_id, execution, int(event.get("duration_ms", 0)))
			else:
				card.complete(execution, int(event.get("duration_ms", 0)))
		"change":
			_close_active_tool_group()
			var filepath := str(event.get("filepath", ""))
			var summary := "%s\n+%d  -%d · %s" % [filepath, int(event.get("additions", 0)), int(event.get("deletions", 0)), str(event.get("status", "unknown")).replace("_", " ").capitalize()]
			_add_message("Change", summary, Color(0.62, 0.78, 0.68), "status")


func _clear_chat_feed() -> void:
	_close_active_tool_group()
	_tool_groups_by_call_id.clear()
	for child in chat_feed.get_children():
		if child != empty_state:
			child.queue_free()
	empty_state.visible = _session.get("events", []).is_empty()


func _add_grouped_tool_card(call_id: String, tool_name: String, arguments: Dictionary):
	if _active_tool_group == null or not is_instance_valid(_active_tool_group) or not _active_tool_group.can_append():
		_active_tool_group = ToolActivityGroup.new()
		chat_feed.add_child(_active_tool_group)
		_active_tool_group.open_requested.connect(_on_open_file_requested)
		_active_tool_group.help_requested.connect(_on_help_requested)
	var card = _active_tool_group.add_tool(call_id, tool_name, arguments)
	_tool_groups_by_call_id[call_id] = _active_tool_group
	return card


func _close_active_tool_group() -> void:
	if _active_tool_group != null and is_instance_valid(_active_tool_group):
		_active_tool_group.close_for_appends()
	_active_tool_group = null


func _session_title(prompt: String) -> String:
	var title := prompt.replace("\n", " ").strip_edges()
	return title.left(64) + ("..." if title.length() > 64 else "")


func _show_storage_cleanup_warning(result: Dictionary) -> void:
	if bool(result.get("cleanup_complete", true)):
		return
	var message := str(result.get("error", "Some local session files could not be removed."))
	print("Orca session cleanup warning: ", message)
	if main_content.visible:
		_add_message("Storage Warning", message, Color(0.78, 0.64, 0.36), "status")


func _sync_session_usage(summary: Dictionary) -> void:
	_last_usage_summary = summary.duplicate(true)
	var context_tokens := int(summary.get("context_tokens", 0))
	var context_limit := int(summary.get("context_limit", 0))
	var completed_requests := int(summary.get("completed_requests", 0))
	var usage_complete := bool(summary.get("usage_complete", true))
	if context_tokens > 0 or completed_requests == 0:
		context_label.text = "Context %s" % _format_token_count(context_tokens)
		if context_limit > 0:
			context_label.text += " / %s" % _format_token_count(context_limit)
	else:
		context_label.text = "Context --"
	var total_tokens := int(summary.get("input_tokens", 0)) + int(summary.get("output_tokens", 0))
	context_label.tooltip_text = (
		"Current context: %s%s\nSession input: %s\nSession output: %s\nCached input: %s\nUsage reporting: %s"
		% [
			_format_token_count(context_tokens),
			" / " + _format_token_count(context_limit) if context_limit > 0 else "",
			_format_token_count(int(summary.get("input_tokens", 0))),
			_format_token_count(int(summary.get("output_tokens", 0))),
			_format_token_count(int(summary.get("cached_tokens", 0))),
			"complete" if usage_complete else "partial or unavailable"
		]
	)
	if bool(summary.get("cost_available", false)):
		cost_label.text = "Cost $%.4f" % float(summary.get("cost_usd", 0.0))
	else:
		cost_label.text = "Cost --"
	var cost_source := "estimated from public model pricing" if bool(summary.get("cost_estimated", false)) else "reported by the provider"
	cost_label.tooltip_text = (
		"Session cost: %s\nModel: %s\nBillable tokens reported: %s\nCost source: %s."
		% [cost_label.text, str(summary.get("model", "")), _format_token_count(total_tokens), cost_source]
	)


func _sync_metrics_visibility() -> void:
	metrics_row.visible = _has_session_content
	header_separator.visible = _has_session_content


func _format_token_count(tokens: int) -> String:
	if tokens >= 1000000:
		return "%.1fM" % (tokens / 1000000.0)
	if tokens >= 1000:
		return "%.1fk" % (tokens / 1000.0)
	return str(tokens)


func _on_dock_resized() -> void:
	_queue_prompt_height_sync()
	if mode_overlay.visible:
		call_deferred("_position_mode_menu")


func _unhandled_key_input(event: InputEvent) -> void:
	if mode_overlay.visible and event.is_action_pressed("ui_cancel"):
		_hide_mode_menu()
		get_viewport().set_input_as_handled()


func _assistant_color() -> Color:
	return _assistant_color_for_mode(agent_controller.get_mode() if agent_controller != null else AgentController.AgentMode.BUILD)


func _assistant_color_for_mode(mode: int) -> Color:
	if mode == AgentController.AgentMode.PLAN:
		return Color(1.0, 0.62, 0.25)
	return Color.LIGHT_GREEN


func _add_message(sender: String, message: String, color: Color, kind: String) -> RichTextLabel:
	_close_active_tool_group()
	if empty_state != null:
		empty_state.hide()
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = _message_background(kind)
	style.set_corner_radius_all(UiMetrics.scaled_int(6))
	style.set_content_margin_all(UiMetrics.scaled(8))
	panel.add_theme_stylebox_override("panel", style)
	chat_feed.add_child(panel)

	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = false
	label.selection_enabled = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(0, 1)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("normal_font_size", _body_font_size)
	label.add_theme_constant_override("line_separation", UiMetrics.scaled_int(4))
	panel.add_child(label)
	label.resized.connect(_queue_message_label_fit.bind(label))
	_update_message_label(label, sender, message, color)
	_scroll_to_bottom()
	return label


func _update_message_label(label: RichTextLabel, sender: String, message: String, color: Color) -> void:
	var formatted_message := _parse_markdown_to_bbcode(message)
	if sender.is_empty():
		label.text = "[color=#%s]%s[/color]" % [color.to_html(false), formatted_message]
	else:
		label.text = "[b][color=#%s]%s:[/color][/b]\n%s" % [color.to_html(false), _escape_bbcode(sender), formatted_message]
	_queue_message_label_fit(label)


func _add_final_assistant_message(sender: String, message: String, color: Color) -> void:
	var label := _add_message(sender, message, color, "assistant")
	_finalize_assistant_message(label, sender, message, color)


func _finalize_assistant_message(label: RichTextLabel, sender: String, message: String, color: Color) -> void:
	if not is_instance_valid(label):
		return
	var blocks := _split_final_message_blocks(message)
	var has_code := blocks.any(func(block: Dictionary): return block.get("type") == "code")
	if not has_code:
		_update_message_label(label, sender, message, color)
		return
	var panel := label.get_parent() as PanelContainer
	if panel == null:
		return
	panel.remove_child(label)
	label.queue_free()
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(8))
	panel.add_child(content)
	if not sender.is_empty():
		var heading := _create_message_text_label()
		heading.text = "[b][color=#%s]%s:[/color][/b]" % [color.to_html(false), _escape_bbcode(sender)]
		content.add_child(heading)
		_queue_message_label_fit(heading)
	for block in blocks:
		if block.get("type") == "code":
			_add_code_block(content, str(block.get("language", "")), str(block.get("text", "")))
		elif not str(block.get("text", "")).is_empty():
			var prose := _create_message_text_label()
			prose.text = _parse_markdown_to_bbcode(str(block.get("text", "")))
			content.add_child(prose)
			_queue_message_label_fit(prose)
	_scroll_to_bottom()


func _create_message_text_label() -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = false
	label.selection_enabled = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(0, 1)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("normal_font_size", _body_font_size)
	label.add_theme_constant_override("line_separation", UiMetrics.scaled_int(4))
	label.resized.connect(_queue_message_label_fit.bind(label))
	return label


func _add_code_block(parent: VBoxContainer, language: String, code: String) -> void:
	var card := PanelContainer.new()
	card.set_meta("orca_code_block", true)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.05, 0.06, 0.9)
	style.border_color = Color(0.2, 0.22, 0.25, 0.8)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(6))
	style.set_content_margin_all(UiMetrics.scaled(7))
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)

	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", UiMetrics.scaled_int(4))
	card.add_child(column)
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(header)
	var language_label := Label.new()
	language_label.set_meta("orca_code_language", true)
	language_label.text = _display_code_language(language)
	language_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	language_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	language_label.add_theme_font_size_override("font_size", _meta_font_size)
	language_label.add_theme_color_override("font_color", Color(0.55, 0.59, 0.66))
	header.add_child(language_label)
	var copy_button := Button.new()
	copy_button.set_meta("orca_copy_button", true)
	copy_button.text = "Copy"
	copy_button.flat = true
	copy_button.focus_mode = Control.FOCUS_NONE
	copy_button.tooltip_text = "Copy code"
	copy_button.add_theme_font_size_override("font_size", _meta_font_size)
	copy_button.pressed.connect(_copy_code.bind(code))
	header.add_child(copy_button)

	var editor := CodeEdit.new()
	editor.set_meta("orca_code_editor", true)
	editor.set_meta("orca_code_language", language.strip_edges().to_lower())
	editor.text = code
	editor.editable = false
	editor.context_menu_enabled = true
	editor.selecting_enabled = true
	editor.gutters_draw_line_numbers = editor.get_line_count() > 1
	editor.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	editor.scroll_fit_content_height = false
	editor.scroll_past_end_of_file = false
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.add_theme_font_size_override("font_size", _body_font_size)
	if Engine.is_editor_hint() and _is_gdscript_language(language):
		editor.syntax_highlighter = GDScriptSyntaxHighlighter.new()
	column.add_child(editor)
	call_deferred("_sync_code_edit_height", editor)


func _sync_code_edit_height(editor: CodeEdit) -> void:
	if not is_instance_valid(editor):
		return
	var visible_lines := clampi(editor.get_line_count(), CODE_MIN_VISIBLE_LINES, CODE_MAX_VISIBLE_LINES)
	var line_height := editor.get_line_height()
	if line_height <= 0:
		line_height = _body_font_size + 6
	var style := editor.get_theme_stylebox("normal")
	editor.custom_minimum_size.y = ceilf(visible_lines * line_height + style.get_minimum_size().y)


func _copy_code(code: String) -> void:
	DisplayServer.clipboard_set(code)


func _display_code_language(language: String) -> String:
	var normalized := language.strip_edges().to_lower()
	if _is_gdscript_language(normalized):
		return "GDScript"
	if normalized.is_empty():
		return "Code"
	return language.strip_edges().left(40)


func _is_gdscript_language(language: String) -> bool:
	return language.strip_edges().to_lower() in ["gd", "gdscript", "gd-script"]


func _queue_message_label_fit(label: RichTextLabel) -> void:
	if not is_instance_valid(label) or label.has_meta("fit_queued"):
		return
	label.set_meta("fit_queued", true)
	call_deferred("_fit_message_label", label)


func _fit_message_label(label: RichTextLabel) -> void:
	if not is_instance_valid(label):
		return
	label.remove_meta("fit_queued")
	var label_style := label.get_theme_stylebox("normal")
	var required_height := maxf(1.0, ceilf(label.get_content_height() + label_style.get_minimum_size().y))
	if not is_equal_approx(label.custom_minimum_size.y, required_height):
		label.custom_minimum_size.y = required_height


func _message_background(kind: String) -> Color:
	match kind:
		"user":
			return Color(0.09, 0.16, 0.22, 0.8)
		"error":
			return Color(0.24, 0.1, 0.11, 0.75)
		"status":
			return Color(0.1, 0.105, 0.115, 0.65)
		_:
			return Color(0.08, 0.085, 0.095, 0.55)


func _show_working_indicator(status: String) -> void:
	if _transient_card != null and is_instance_valid(_transient_card) and _transient_card.has_meta("orca_working_indicator"):
		if _working_status_label != null and is_instance_valid(_working_status_label):
			_working_status_label.text = status
		return
	_remove_transient_card()
	_close_active_tool_group()
	if empty_state != null:
		empty_state.hide()

	var panel := PanelContainer.new()
	panel.set_meta("orca_working_indicator", true)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = _message_background("status")
	var accent := _assistant_color()
	panel_style.border_color = Color(accent.r, accent.g, accent.b, 0.28)
	panel_style.set_border_width_all(UiMetrics.scaled_int(1))
	panel_style.set_corner_radius_all(UiMetrics.scaled_int(6))
	panel_style.set_content_margin_all(UiMetrics.scaled(8))
	panel.add_theme_stylebox_override("panel", panel_style)
	chat_feed.add_child(panel)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	panel.add_child(content)
	var heading := _create_message_text_label()
	heading.text = "[b][color=#%s]Orca:[/color][/b]" % accent.to_html(false)
	content.add_child(heading)
	_queue_message_label_fit(heading)

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	content.add_child(row)
	_working_status_label = Label.new()
	_working_status_label.set_meta("orca_working_status", true)
	_working_status_label.text = status
	_working_status_label.add_theme_font_size_override("font_size", _body_font_size)
	_working_status_label.add_theme_color_override("font_color", Color(0.68, 0.71, 0.76))
	row.add_child(_working_status_label)

	var square_row := HBoxContainer.new()
	square_row.set_meta("orca_working_squares", true)
	square_row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	square_row.add_theme_constant_override("separation", UiMetrics.scaled_int(4))
	row.add_child(square_row)
	_working_squares.clear()
	for index in range(WORKING_SQUARE_COUNT):
		var square := Panel.new()
		square.set_meta("orca_working_square", index)
		var square_size := UiMetrics.scaled(7)
		square.custom_minimum_size = Vector2(square_size, square_size)
		square.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		square.mouse_filter = Control.MOUSE_FILTER_IGNORE
		square.pivot_offset = Vector2.ONE * square_size * 0.5
		var square_style := StyleBoxFlat.new()
		square_style.set_corner_radius_all(UiMetrics.scaled_int(1))
		square.add_theme_stylebox_override("panel", square_style)
		square_row.add_child(square)
		_working_squares.append(square)

	_working_timer = Timer.new()
	_working_timer.wait_time = WORKING_ANIMATION_INTERVAL
	_working_timer.timeout.connect(_advance_working_animation)
	panel.add_child(_working_timer)
	_working_phase = -1
	_transient_card = panel
	_advance_working_animation()
	_working_timer.start()
	_scroll_to_bottom()


func _advance_working_animation() -> void:
	if _transient_card == null or not is_instance_valid(_transient_card):
		return
	_working_phase = (_working_phase + 1) % WORKING_ANIMATION_PHASES
	var palette := _working_palette()
	for index in range(mini(_working_squares.size(), palette.size())):
		var square := _working_squares[index]
		if not is_instance_valid(square):
			continue
		var lit := false
		var active := false
		var crest := _working_phase == 5
		if _working_phase <= 4:
			lit = index <= _working_phase
			active = index == _working_phase
		elif _working_phase <= 9:
			var threshold := _working_phase - 5
			lit = index >= threshold
			active = index == threshold
		var color: Color = palette[index]
		color.a = 0.92 if crest else 1.0 if active else 0.66 if lit else 0.18
		var style := square.get_theme_stylebox("panel") as StyleBoxFlat
		if style != null:
			style.bg_color = color
		var target_scale := 1.08 if crest else 1.24 if active else 1.0 if lit else 0.82
		square.scale = Vector2.ONE * target_scale


func _working_palette() -> Array[Color]:
	if agent_controller != null and agent_controller.get_mode() == AgentController.AgentMode.PLAN:
		return [Color("b96a32"), Color("df853a"), Color("f2a348"), Color("f5bc63"), Color("ffd58a")]
	return [Color("3a78b8"), Color("71b5e6"), Color("62d6d2"), Color("74deb3"), Color("8fe39a")]


func _remove_transient_card() -> void:
	if _working_timer != null and is_instance_valid(_working_timer):
		_working_timer.stop()
	if _transient_card != null and is_instance_valid(_transient_card):
		_transient_card.queue_free()
	_transient_card = null
	_working_timer = null
	_working_status_label = null
	_working_squares.clear()
	_working_phase = -1


func _on_chat_feed_resized() -> void:
	if _request_active or _scroll_follow_frames > 0:
		_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	_scroll_follow_frames = maxi(_scroll_follow_frames, SCROLL_FOLLOW_FRAMES)
	set_process(true)
	call_deferred("_scroll_to_bottom_now")


func _scroll_to_bottom_now() -> void:
	if chat_scroll != null:
		chat_scroll.scroll_vertical = int(chat_scroll.get_v_scroll_bar().max_value)


func _parse_markdown_to_bbcode(text: String) -> String:
	var bbcode := _escape_bbcode(text)
	var regex := RegEx.new()
	regex.compile("\\*\\*(.*?)\\*\\*")
	bbcode = regex.sub(bbcode, "[b]$1[/b]", true)
	regex.compile("\\*(.*?)\\*")
	bbcode = regex.sub(bbcode, "[i]$1[/i]", true)
	regex.compile("`(.*?)`")
	bbcode = regex.sub(bbcode, "[code]$1[/code]", true)
	regex.compile("### (.*?)\\n")
	bbcode = regex.sub(bbcode, "[b][u]$1[/u][/b]\n", true)
	regex.compile("## (.*?)\\n")
	bbcode = regex.sub(bbcode, "[b][u]$1[/u][/b]\n", true)
	regex.compile("# (.*?)\\n")
	bbcode = regex.sub(bbcode, "[b][u]$1[/u][/b]\n", true)
	return bbcode


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "\u0001").replace("]", "\u0002").replace("\u0001", "[lb]").replace("\u0002", "[rb]")


static func _split_final_message_blocks(text: String) -> Array[Dictionary]:
	var normalized := text.replace("\r\n", "\n").replace("\r", "\n")
	var lines := normalized.split("\n", true)
	var blocks: Array[Dictionary] = []
	var text_start := 0
	var index := 0
	while index < lines.size():
		var stripped := lines[index].strip_edges()
		if not stripped.begins_with("```"):
			index += 1
			continue
		var closing := index + 1
		while closing < lines.size() and lines[closing].strip_edges() != "```":
			closing += 1
		if closing >= lines.size():
			index += 1
			continue
		if index > text_start:
			blocks.append({"type": "text", "text": "\n".join(lines.slice(text_start, index))})
		var language := stripped.substr(3).strip_edges().left(40)
		blocks.append({"type": "code", "language": language, "text": "\n".join(lines.slice(index + 1, closing))})
		index = closing + 1
		text_start = index
	if text_start < lines.size():
		blocks.append({"type": "text", "text": "\n".join(lines.slice(text_start))})
	if blocks.is_empty():
		blocks.append({"type": "text", "text": normalized})
	return blocks


func _on_settings_button_pressed() -> void:
	_open_settings(false)


func _on_model_button_pressed() -> void:
	_open_settings(true)


func _open_settings(focus_model: bool) -> void:
	if agent_controller != null and agent_controller.is_busy():
		return
	if mode_overlay.visible:
		mode_overlay.hide()
	if history_view != null:
		history_view.hide()
	main_content.hide()
	if focus_model:
		settings_view.open_model_configuration()
	else:
		settings_view.open()
