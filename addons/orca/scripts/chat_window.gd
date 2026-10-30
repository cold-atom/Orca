@tool
extends Control

const ToolActivityCard = preload("res://addons/orca/scripts/tool_activity_card.gd")
const ToolActivityGroup = preload("res://addons/orca/scripts/tool_activity_group.gd")
const TaskListPanel = preload("res://addons/orca/scripts/task_list_panel.gd")
const ModeSwitchCard = preload("res://addons/orca/scripts/mode_switch_card.gd")
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
const ResponseAttribution = preload("res://addons/orca/scripts/response_attribution.gd")
const ImageAttachments = preload("res://addons/orca/scripts/image_attachments.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")
const ImageAttachmentTray = preload("res://addons/orca/scripts/image_attachment_tray.gd")
const ImageAttachmentWindow = preload("res://addons/orca/scripts/image_attachment_window.gd")
const ScriptReferences = preload("res://addons/orca/scripts/script_references.gd")
const ScriptReferenceTray = preload("res://addons/orca/scripts/script_reference_tray.gd")
const UpdatePanel = preload("res://addons/orca/scripts/update_panel.gd")
const ConnectionSetupPanel = preload("res://addons/orca/scripts/connection_setup_panel.gd")
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
	"inspect_editor_scene": true,
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
@onready var image_icon_view: TextureRect = $MarginContainer/VBoxContainer/Composer/ComposerContent/ComposerActions/ImageButton/Icon
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
var account_service
var update_service
var update_notice
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
var _response_attribution: Dictionary = {}
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
var _change_origin_turns: Dictionary = {}
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
var _turn_had_mode_request := false
var _session_resume_tainted := false
var _request_active := false
var _active_turn_id := 0
var _scroll_follow_frames := 0
var _draft_images: Array = []
var _draft_script_paths: Array = []
var _script_reference_tray: PanelContainer
var _attachment_tray: PanelContainer
var _image_picker: FileDialog
var _image_preview: AcceptDialog
var _preview_texture: TextureRect
var _submitted_image_draft: Dictionary = {}
var _image_drop_cue: PanelContainer
var _image_drop_timer: Timer
var _image_attachment_window: Window
var _image_attachment_session_id := ""
var _connection_setup_card: PanelContainer
var _connection_overlay: Control
var _connection_overlay_scroll: ScrollContainer
var _connection_dock_open_notified := false
var _connection_first_open_pending := false
var _connection_first_open_checked := false
var _connection_setup_first_open := false


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
	if update_service != null:
		update_notice = UpdatePanel.new()
		update_notice.name = "UpdateNotice"
		update_notice.compact = true
		update_notice.service = update_service
		var column := chat_scroll.get_parent()
		column.add_child(update_notice)
		column.move_child(update_notice, chat_scroll.get_index())
	_setup_image_attachments()
	task_list_panel = TaskListPanel.new()
	var main_column := chat_scroll.get_parent()
	main_column.add_child(task_list_panel)
	main_column.move_child(task_list_panel, composer.get_index())
	task_list_panel.item_rect_changed.connect(_position_attachment_tray)
	task_list_panel.visibility_changed.connect(_position_attachment_tray)
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
	if account_service == null:
		account_service = preload("res://addons/orca/scripts/account_service.gd").new()
		add_child(account_service)
	agent_controller.account_service = account_service
	agent_controller.api_client.account_service = account_service
	account_service.changed.connect(_on_account_state_changed)
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
	agent_controller.message_received.connect(_on_turn_message_received)
	agent_controller.error_occurred.connect(_on_turn_error_occurred)
	agent_controller.tool_execution_started.connect(_on_turn_tool_execution_started)
	agent_controller.tool_execution_completed.connect(_on_turn_tool_execution_completed)
	agent_controller.edit_proposed.connect(_on_turn_edit_proposed)
	agent_controller.edit_resolved.connect(_on_edit_resolved)
	agent_controller.message_stream_started.connect(_on_turn_message_stream_started)
	agent_controller.message_stream_delta.connect(_on_turn_message_stream_delta)
	agent_controller.request_state_changed.connect(_on_turn_request_state_changed)
	agent_controller.request_cancelled.connect(_on_turn_request_cancelled)
	agent_controller.mode_changed.connect(_sync_mode_ui)
	agent_controller.session_usage_changed.connect(_sync_session_usage)
	agent_controller.model_metadata_requested.connect(model_catalog_service.refresh)
	agent_controller.tasks_changed.connect(_on_tasks_changed)
	agent_controller.workflow_state_changed.connect(_on_turn_workflow_state_changed)
	agent_controller.work_mode_requested.connect(_on_turn_work_mode_requested)
	_setup_mode_menu()

	settings_view = SettingsView.new()
	settings_view.account_service = account_service
	settings_view.update_service = update_service
	settings_view.hide()
	add_child(settings_view)
	settings_view.done_requested.connect(_on_settings_done)
	settings_view.settings_saved.connect(_on_settings_saved)
	_setup_connection_overlay()
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
	_close_image_attachment_window()
	if session_store != null and not _session.is_empty() and _has_session_content:
		_save_current_session()


func update_readiness() -> String:
	if agent_controller != null and (agent_controller.is_busy() or not agent_controller._pending_change_id.is_empty() or not agent_controller._pending_work_mode_call_id.is_empty()):
		return "Finish or cancel the active Orca request and approvals before updating."
	if not prompt_input.text.strip_edges().is_empty() or not _draft_images.is_empty() or not _draft_script_paths.is_empty():
		return "Submit or clear the composer draft before restarting so it is not lost."
	return ""


func save_for_update() -> bool:
	return update_readiness().is_empty() and _save_current_session()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_hide_image_drop_cue()


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
	image_button.show()
	image_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(28, 28))
	image_icon_view.offset_left = -UiMetrics.scaled(11)
	image_icon_view.offset_top = -UiMetrics.scaled(11)
	image_icon_view.offset_right = UiMetrics.scaled(11)
	image_icon_view.offset_bottom = UiMetrics.scaled(11)
	for button in [new_session_button, history_button, settings_button]:
		button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(28, 28))
	send_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(42, 34))
	send_icon_view.offset_left = -UiMetrics.scaled(11)
	send_icon_view.offset_top = -UiMetrics.scaled(11)
	send_icon_view.offset_right = UiMetrics.scaled(11)
	send_icon_view.offset_bottom = UiMetrics.scaled(11)
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


func _setup_image_attachments() -> void:
	# MarginContainer owns its direct children's rectangles. A plain Control host
	# keeps the positioned tray out of that layout contract and contributes no minimum size.
	var overlay_host := Control.new()
	overlay_host.name = "AttachmentOverlay"
	overlay_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main_content.add_child(overlay_host)
	_attachment_tray = ImageAttachmentTray.new()
	_attachment_tray.name = "AttachmentTray"
	overlay_host.add_child(_attachment_tray)
	_attachment_tray.remove_requested.connect(_remove_draft_image)
	_attachment_tray.preview_requested.connect(_show_image_preview)
	_attachment_tray.hide()
	_script_reference_tray = ScriptReferenceTray.new()
	_script_reference_tray.name = "ScriptReferenceTray"
	overlay_host.add_child(_script_reference_tray)
	_script_reference_tray.remove_requested.connect(_remove_script_reference)
	_script_reference_tray.open_requested.connect(_open_script_reference)
	_script_reference_tray.hide()
	_setup_image_intake(overlay_host)
	composer.resized.connect(_position_attachment_tray)
	composer.item_rect_changed.connect(_position_attachment_tray)
	_image_attachment_window = ImageAttachmentWindow.new()
	add_child(_image_attachment_window)
	_image_attachment_window.files_dropped.connect(_on_attachment_window_files_dropped)
	_image_attachment_window.browse_requested.connect(_browse_attachment_images)
	_image_attachment_window.visibility_changed.connect(_on_attachment_window_visibility_changed)
	_image_picker = FileDialog.new()
	_image_picker.title = "Attach images"
	_image_picker.access = FileDialog.ACCESS_FILESYSTEM
	_image_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_image_picker.filters = PackedStringArray(["*.png,*.jpg,*.jpeg,*.webp ; Images"])
	_image_picker.files_selected.connect(_on_images_selected)
	_image_attachment_window.add_child(_image_picker)
	image_button.pressed.connect(_on_image_button_pressed)
	_image_preview = AcceptDialog.new()
	_image_preview.title = "Image preview"
	_preview_texture = TextureRect.new()
	_preview_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview_texture.custom_minimum_size = UiMetrics.scaled_vector(Vector2(260, 240))
	_image_preview.add_child(_preview_texture)
	_image_preview.visibility_changed.connect(func():
		if not _image_preview.visible:
			_preview_texture.texture = null
	)
	add_child(_image_preview)


func _on_image_button_pressed() -> void:
	_sync_send_availability()
	if image_button.disabled:
		return
	_ensure_session()
	_image_attachment_session_id = str(_session.get("id", ""))
	_image_attachment_window.set_state(_draft_images.size())
	_image_attachment_window.popup_centered()


func _browse_attachment_images() -> void:
	if not _attachment_window_accepts_intake():
		return
	_image_picker.popup_centered_ratio(0.65)


func _on_images_selected(paths: PackedStringArray) -> void:
	# Release FileDialog's exclusive ownership before checking the intake window.
	if _image_picker != null:
		_image_picker.hide()
	if _attachment_window_accepts_intake():
		_attach_image_files(paths)


func _image_intake_error(count: int) -> String:
	if not _session_resumable or not prompt_input.editable or not main_content.is_visible_in_tree():
		return "This conversation is not accepting attachments."
	var capability := _selected_image_capability()
	if capability != "supported":
		return "This model does not support image input." if capability == "unsupported" else "Image support is unconfirmed. Configure it in Provider settings."
	if count <= 0 or count + _draft_images.size() > ImageAttachments.MAX_IMAGES:
		return "Attach at most four images per message."
	return ""


func _selected_image_capability() -> String:
	if Config.get_provider() == "orca_cloud" and account_service != null:
		return ImageCapability.resolve(account_service.profile_config(Config.get_model(), Config.get_reasoning_effort()))
	return ImageCapability.resolve(Config.get_active_provider_config())


func _attach_image_files(paths: PackedStringArray) -> bool:
	var error := _image_intake_error(paths.size())
	if error.is_empty():
		error = _image_file_paths_error(paths)
	if not error.is_empty():
		_show_image_intake_error(error)
		return false
	var prepared: Array = []
	for path in paths:
		var result := _prepare_image_file(path)
		if not result.get("success", false):
			_show_image_intake_error(str(result.get("error", "Could not prepare image.")))
			return false
		prepared.append(result["image"])
	return _accept_prepared_images(prepared)


func _prepare_image_file(path: String) -> Dictionary:
	return ImageAttachments.prepare_file(path)


func _accept_prepared_images(prepared: Array) -> bool:
	var error := _image_intake_error(prepared.size())
	if error.is_empty() and session_store != null:
		error = session_store.image_storage_error(_session, _draft_images + prepared)
	if not error.is_empty():
		_show_image_intake_error(error)
		return false
	_draft_images.append_array(prepared)
	_refresh_attachment_tray()
	return true


func _show_image_intake_error(message: String) -> void:
	if _image_attachment_window != null and _image_attachment_window.visible:
		_image_attachment_window.set_state(_draft_images.size(), message)
	else:
		_add_message("Attachments", message, Color.INDIAN_RED, "error")


func _clipboard_has_image() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD) and DisplayServer.clipboard_has_image()


func _clipboard_image() -> Image:
	return DisplayServer.clipboard_get_image()


func _try_paste_image() -> bool:
	# No clipboard polling: this callback runs only for an explicit composer Paste.
	if not _clipboard_has_image():
		return false
	var error := _image_intake_error(1)
	if not error.is_empty():
		_show_image_intake_error(error)
		return true
	var result := ImageAttachments.prepare_image(_clipboard_image(), "Pasted image.png")
	if result.get("success", false):
		_accept_prepared_images([result["image"]])
	else:
		_show_image_intake_error(str(result.get("error", "Could not read clipboard image.")))
	return true


func _image_file_paths_error(paths: PackedStringArray) -> String:
	for path in paths:
		if path.length() > 4096 or path.to_utf8_buffer().has(0) or path.get_extension().to_lower() not in ["png", "jpg", "jpeg", "webp"]:
			return "Drop PNG, JPEG, or WebP still-image files only."
		if not path.begins_with("res://") and (not path.is_absolute_path() or path.contains("://")):
			return "Only local image files can be attached."
	return ""


func _image_paths_from_drag(data) -> PackedStringArray:
	if typeof(data) != TYPE_DICTIONARY or data.get("type") not in ["files", "files_and_dirs"]:
		return PackedStringArray()
	var files = data.get("files")
	if typeof(files) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY] or files.is_empty() or files.size() > ImageAttachments.MAX_IMAGES:
		return PackedStringArray()
	var paths := PackedStringArray()
	for file in files:
		if typeof(file) != TYPE_STRING:
			return PackedStringArray()
		paths.append(file)
	return paths if _image_file_paths_error(paths).is_empty() else PackedStringArray()


func _setup_image_intake(overlay_host: Control) -> void:
	prompt_input.image_paste_handler = _try_paste_image
	for target in [prompt_input, composer]:
		target.set_drag_forwarding(Callable(), _can_drop_image_data.bind(target), _drop_image_data.bind(target))
	for target in [composer_content, composer_actions, mode_selector, mode_button, model_label, image_button, send_button]:
		target.set_drag_forwarding(Callable(), _can_drop_image_data.bind(target), _drop_image_data.bind(target))
	_image_drop_cue = PanelContainer.new()
	_image_drop_cue.name = "ImageDropCue"
	_image_drop_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.125, 0.14, 0.97)
	style.border_color = Color(0.46, 0.48, 0.52)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(8))
	style.set_content_margin_all(UiMetrics.scaled(8))
	_image_drop_cue.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = "Drop images to attach"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", _meta_font_size)
	_image_drop_cue.add_child(label)
	overlay_host.add_child(_image_drop_cue)
	_image_drop_cue.hide()
	_image_drop_timer = Timer.new()
	_image_drop_timer.one_shot = true
	_image_drop_timer.wait_time = 0.15
	_image_drop_timer.timeout.connect(_refresh_image_drop_cue)
	add_child(_image_drop_timer)
	main_content.visibility_changed.connect(_hide_image_drop_cue)
	main_content.visibility_changed.connect(func():
		if not main_content.is_visible_in_tree():
			_close_image_attachment_window()
	)


func _can_drop_image_data(_position: Vector2, data, target: Control) -> bool:
	var paths := _image_paths_from_drag(data)
	var accepted := target.is_visible_in_tree() and not paths.is_empty() and _image_intake_error(paths.size()).is_empty() and get_last_exclusive_window() == get_window()
	if not accepted:
		var scripts := _script_paths_from_drag(data)
		accepted = target.is_visible_in_tree() and not scripts.is_empty() and _script_intake_error(scripts).is_empty() and get_last_exclusive_window() == get_window()
	if accepted:
		(_image_drop_cue.get_child(0) as Label).text = "Drop images to attach" if not paths.is_empty() else "Drop scripts to attach"
		_image_drop_cue.size = prompt_input.size
		_image_drop_cue.global_position = prompt_input.global_position
		_image_drop_cue.show()
		_image_drop_timer.start()
	else:
		_hide_image_drop_cue()
	return accepted


func _drop_image_data(_position: Vector2, data, _target: Control) -> void:
	_hide_image_drop_cue()
	if not _target.is_visible_in_tree() or get_last_exclusive_window() != get_window():
		return
	var paths := _image_paths_from_drag(data)
	if not paths.is_empty():
		_attach_image_files(paths)
	else:
		var scripts := _script_paths_from_drag(data)
		if not scripts.is_empty():
			_attach_script_paths(scripts)


func _script_paths_from_drag(data) -> Array:
	if typeof(data) != TYPE_DICTIONARY:
		return []
	var paths: Array = []
	if data.get("type") == "script_list_element":
		var path := _current_script_drag_path(data.get("script_list_element"))
		if not path.is_empty():
			paths.append(path)
	elif data.get("type") in ["files", "files_and_dirs"]:
		var files = data.get("files")
		if typeof(files) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY] or files.is_empty() or files.size() > ScriptReferences.MAX_REFERENCES:
			return []
		for path in files:
			if typeof(path) != TYPE_STRING:
				return []
			paths.append(path)
	for path in paths:
		if not ScriptReferences.path_error(path).is_empty():
			return []
	return paths


func _current_script_drag_path(element) -> String:
	# Godot's script-list payload is an editor control, not a resource/path.
	# Compare identity only; never scrape it or invoke methods on supplied objects.
	return ScriptReferences.editor_drag_path(element)


func _script_intake_error(paths: Array) -> String:
	if not _session_resumable or not prompt_input.editable or not main_content.is_visible_in_tree():
		return "This conversation is not accepting script references."
	var unique := _draft_script_paths.duplicate()
	for path in paths:
		if path not in unique:
			unique.append(path)
	if unique.size() > ScriptReferences.MAX_REFERENCES:
		return "Attach at most four scripts per message."
	return ""


func _attach_script_paths(paths: Array) -> bool:
	var error := _script_intake_error(paths)
	if paths.is_empty() or paths.size() > ScriptReferences.MAX_REFERENCES:
		error = "Attach at most four project scripts."
	if error.is_empty():
		for path in paths:
			error = ScriptReferences.path_error(path, true) if typeof(path) == TYPE_STRING else "Invalid script reference."
			if not error.is_empty():
				break
	if not error.is_empty():
		_show_image_intake_error(error)
		return false
	for path in paths:
		if path not in _draft_script_paths:
			_draft_script_paths.append(path)
	_refresh_script_reference_tray()
	return true


func _prepare_script_references() -> Dictionary:
	return ScriptReferences.prepare(_draft_script_paths)


func _remove_script_reference(index: int) -> void:
	if index >= 0 and index < _draft_script_paths.size():
		_draft_script_paths.remove_at(index)
	_refresh_script_reference_tray()


func _open_script_reference(path: String) -> void:
	var error := ScriptReferences.path_error(path, true)
	if error.is_empty():
		if not EditorContext.open_file(path):
			_show_image_intake_error("The referenced script could not be opened.")
	else:
		_show_image_intake_error(error)


func _refresh_script_reference_tray() -> void:
	if _script_reference_tray == null:
		return
	var records: Array = []
	for path in _draft_script_paths:
		records.append({"filepath": path})
	_script_reference_tray.configure(records)
	call_deferred("_position_attachment_tray")
	_sync_send_availability()


func _hide_image_drop_cue() -> void:
	if _image_drop_cue != null:
		_image_drop_cue.hide()
	if _image_drop_timer != null:
		_image_drop_timer.stop()


func _refresh_image_drop_cue() -> void:
	if get_viewport().gui_is_dragging() and Rect2(Vector2.ZERO, composer.size).has_point(composer.get_local_mouse_position()):
		_can_drop_image_data(Vector2.ZERO, get_viewport().gui_get_drag_data(), composer)
	else:
		_hide_image_drop_cue()


func _attachment_window_accepts_intake() -> bool:
	if not is_instance_valid(_image_attachment_window) or not _image_attachment_window.visible or not main_content.is_visible_in_tree():
		return false
	if _image_attachment_session_id.is_empty() or _image_attachment_session_id != str(_session.get("id", "")):
		return false
	if get_last_exclusive_window() != get_window():
		return false
	if (_image_preview != null and _image_preview.visible) or mode_overlay.visible or (_new_session_dialog != null and _new_session_dialog.visible):
		return false
	return true


func _on_attachment_window_files_dropped(paths: PackedStringArray) -> void:
	if _attachment_window_accepts_intake() and not _image_picker.visible:
		_attach_image_files(paths)


func _on_attachment_window_visibility_changed() -> void:
	if not _image_attachment_window.visible:
		_image_attachment_session_id = ""
		if _image_picker != null:
			_image_picker.hide()


func _close_image_attachment_window() -> void:
	_image_attachment_session_id = ""
	if is_instance_valid(_image_picker):
		_image_picker.hide()
	if is_instance_valid(_image_attachment_window):
		_image_attachment_window.hide()


func _remove_draft_image(index: int) -> void:
	if index >= 0 and index < _draft_images.size():
		_draft_images.remove_at(index)
	_refresh_attachment_tray()


func _refresh_attachment_tray() -> void:
	if _attachment_tray == null:
		return
	_attachment_tray.configure(_draft_images)
	if _image_attachment_window != null:
		_image_attachment_window.set_state(_draft_images.size())
	call_deferred("_position_attachment_tray")
	_sync_send_availability()


func _position_attachment_tray() -> void:
	if _attachment_tray == null or not is_instance_valid(composer):
		return
	var thumbnail_width := UiMetrics.scaled(_draft_images.size() * 56 + maxi(0, _draft_images.size() - 1) * 8 + 8)
	_attachment_tray.size = Vector2(minf(composer.size.x, thumbnail_width), UiMetrics.scaled(64))
	var anchor := composer.global_position
	if task_list_panel != null and task_list_panel.visible:
		anchor.y = minf(anchor.y, task_list_panel.global_position.y)
	_attachment_tray.global_position = anchor - Vector2(0, UiMetrics.scaled(68))
	if _script_reference_tray != null and not _draft_script_paths.is_empty():
		if not _draft_images.is_empty():
			anchor.y -= UiMetrics.scaled(68)
		_script_reference_tray.size = Vector2(composer.size.x, _script_reference_tray.height_for_width(composer.size.x))
		_script_reference_tray.global_position = anchor - Vector2(0, _script_reference_tray.size.y + UiMetrics.scaled(4))


func _show_image_preview(record: Dictionary) -> void:
	_preview_texture.texture = ImageAttachments.texture(record)
	_image_preview.title = str(record.get("name", "Image"))
	_image_preview.popup_centered_ratio(0.7)


func _add_message_images(label: RichTextLabel, images: Array) -> void:
	if images.is_empty():
		return
	var panel := label.get_parent()
	panel.remove_child(label)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(content)
	content.add_child(label)
	var tray := ImageAttachmentTray.new()
	content.add_child(tray)
	tray.configure(images, false)
	tray.preview_requested.connect(_show_image_preview)


func _add_message_script_references(label: RichTextLabel, references: Array) -> void:
	if references.is_empty():
		return
	var parent := label.get_parent()
	if parent is PanelContainer:
		parent.remove_child(label)
		var content := VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		parent.add_child(content)
		content.add_child(label)
		parent = content
	var tray := ScriptReferenceTray.new()
	parent.add_child(tray)
	tray.configure(references, false)
	tray.open_requested.connect(_open_script_reference)


func _sync_send_availability() -> void:
	send_button.disabled = not _request_active and (not _session_resumable or (prompt_input.text.strip_edges().is_empty() and _draft_images.is_empty() and _draft_script_paths.is_empty()))
	_sync_image_button(_selected_image_capability())
	_sync_send_icon_tint(_request_active)


func _sync_image_button(capability: String) -> void:
	image_button.disabled = not _session_resumable or capability != "supported" or _draft_images.size() >= ImageAttachments.MAX_IMAGES
	image_icon_view.self_modulate = Color(0.34, 0.36, 0.39, 0.55) if image_button.disabled else Color(0.8, 0.82, 0.85)
	image_button.mouse_default_cursor_shape = Control.CURSOR_ARROW if image_button.disabled else Control.CURSOR_POINTING_HAND
	if not _session_resumable:
		image_button.tooltip_text = "This saved conversation is view-only."
	elif capability == "unsupported":
		image_button.tooltip_text = "This model does not support image input."
	elif capability != "supported":
		image_button.tooltip_text = "Image support is unconfirmed. Configure it in Provider settings."
	elif _draft_images.size() >= ImageAttachments.MAX_IMAGES:
		image_button.tooltip_text = "Four images attached. Remove an image to add another."
	else:
		image_button.tooltip_text = "%s supports image input. Opens a separate drop/Browse window. Paste screenshots or drag project images onto the input. Dropping desktop files on the main editor imports them; use the attachment window instead." % Config.get_model()
	if _session_resumable and capability != "supported" and agent_controller != null and ImageAttachments.has_images(agent_controller.message_history):
		image_button.tooltip_text += "\nPrevious session images are preserved. Text follow-ups send placeholders and any earlier descriptions instead of image pixels."


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
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		if event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed or not prompt_input.has_focus() or not prompt_input.is_visible_in_tree():
			return
		# Consume repeats and locked-state presses too, without inserting draft tabs.
		prompt_input.accept_event()
		if event.echo or _request_active or not _session_resumable or mode_button.disabled or agent_controller == null:
			return
		var next_mode := AgentController.AgentMode.PLAN if agent_controller.get_mode() == AgentController.AgentMode.BUILD else AgentController.AgentMode.BUILD
		_on_mode_selected(next_mode, true)
		return
	if event is InputEventKey and event.pressed and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER):
		if event.shift_pressed or _request_active:
			return
		get_viewport().set_input_as_handled()
		_on_send_button_pressed()


func _on_send_button_pressed() -> void:
	if _request_active:
		if agent_controller != null:
			agent_controller.cancel_current_request()
		return
	if not _session_resumable:
		return
	var text := prompt_input.text.strip_edges()
	if text.is_empty() and _draft_images.is_empty() and _draft_script_paths.is_empty():
		return
	var setup: Dictionary = agent_controller.connection_setup()
	if setup.get("status") != "ready":
		_show_connection_setup(setup)
		return
	_dismiss_connection_setup(false)
	var prepared := _prepare_script_references()
	if not prepared.get("success", false):
		_show_image_intake_error(str(prepared.get("error", "Could not prepare script references.")))
		return
	var references: Array = prepared["references"]
	var attachment_error: String = agent_controller.submission_error(_draft_images, references)
	if attachment_error.is_empty():
		attachment_error = session_store.image_storage_error(_session, _draft_images)
	if not attachment_error.is_empty():
		_add_message("Attachments", attachment_error, Color.INDIAN_RED, "error")
		return
	var images := _draft_images.duplicate(true)
	var script_paths := _draft_script_paths.duplicate()
	var previous_session := _session.duplicate(true)
	_submitted_image_draft = {"text": text, "images": images, "script_paths": script_paths} if not images.is_empty() or not script_paths.is_empty() else {}
	_clear_prompt_input()
	prompt_input.placeholder_text = "Describe what you want to build or fix..."
	_has_session_content = true
	_sync_metrics_visibility()
	var user_label := _add_message("User", text, Color.LIGHT_SKY_BLUE, "user")
	_add_message_images(user_label, images)
	_add_message_script_references(user_label, references)
	var user_panel := _response_panel(user_label)
	_ensure_session()
	if str(_session.get("last_prompt", "")).is_empty():
		_session["title"] = _session_title(text if not text.is_empty() or script_paths.is_empty() else script_paths[0].get_file())
	_session["last_prompt"] = (text if not text.is_empty() or script_paths.is_empty() else script_paths[0].get_file()).left(240)
	_session["mode"] = agent_controller.get_mode()
	_session["provider"] = Config.get_provider()
	_session["model"] = Config.get_model()
	_session["clean"] = false
	_session["resumable"] = not _session_resume_tainted
	_turn_had_tools = false
	_turn_had_mode_request = false
	var event := _message_event("User", text, "user", "complete")
	if not images.is_empty():
		event["images"] = images
	if not references.is_empty():
		event["script_references"] = references
	_append_session_event(event)
	_set_request_active(true)
	_show_working_indicator("Thinking")
	_draft_images.clear()
	_draft_script_paths.clear()
	_refresh_attachment_tray()
	_refresh_script_reference_tray()
	if not agent_controller.send_user_message(text, images, references):
		_set_request_active(false)
		_remove_transient_card()
		if prompt_input.text.is_empty() and _draft_images.is_empty() and _draft_script_paths.is_empty():
			prompt_input.text = text
			_draft_images = images
			_draft_script_paths = script_paths
			_refresh_attachment_tray()
			_refresh_script_reference_tray()
		user_panel.queue_free()
		_session = previous_session
		_submitted_image_draft.clear()
		_add_message("Attachments", "Submission was not accepted. Your draft has been kept.", Color.INDIAN_RED, "error")
		return
	_save_current_session()


func _on_turn_request_state_changed(turn_id: int, active: bool) -> void:
	if active:
		if turn_id <= _active_turn_id:
			return
		_active_turn_id = turn_id
		_response_attribution.clear()
	elif turn_id != _active_turn_id:
		return
	_set_request_active(active)


func _on_turn_message_received(turn_id: int, role: String, content: String, attribution: Dictionary = {}) -> void:
	if turn_id != _active_turn_id:
		return
	_on_agent_message_received(role, content, attribution)
	if _active_turn_id == turn_id:
		_active_turn_id = 0
		_response_attribution.clear()


func _on_turn_error_occurred(turn_id: int, message: String) -> void:
	if turn_id != _active_turn_id:
		return
	_on_agent_error_occurred(message)
	if _active_turn_id == turn_id:
		_active_turn_id = 0
		_response_attribution.clear()


func _on_turn_request_cancelled(turn_id: int) -> void:
	if turn_id != _active_turn_id:
		return
	_on_agent_request_cancelled()
	if _active_turn_id == turn_id:
		_active_turn_id = 0
		_response_attribution.clear()


func _on_turn_message_stream_started(turn_id: int) -> void:
	if turn_id == _active_turn_id:
		_on_message_stream_started()


func _on_turn_message_stream_delta(turn_id: int, content: String) -> void:
	if turn_id == _active_turn_id:
		_on_message_stream_delta(content)


func _on_turn_tool_execution_started(turn_id: int, call_id: String, tool_name: String, arguments: Dictionary) -> void:
	if turn_id == _active_turn_id:
		_on_tool_execution_started(call_id, tool_name, arguments)


func _on_turn_tool_execution_completed(turn_id: int, call_id: String, tool_name: String, execution: Dictionary, duration_ms: int) -> void:
	if turn_id == _active_turn_id:
		_on_tool_execution_completed(call_id, tool_name, execution, duration_ms)


func _on_turn_edit_proposed(turn_id: int, proposal: Dictionary) -> void:
	if turn_id == _active_turn_id:
		_on_edit_proposed(proposal, turn_id)


func _on_turn_workflow_state_changed(turn_id: int, state: String, details: Dictionary) -> void:
	if turn_id == _active_turn_id:
		_on_workflow_state_changed(state, details)


func _on_turn_work_mode_requested(turn_id: int, request: Dictionary) -> void:
	if turn_id == _active_turn_id:
		_on_work_mode_requested(request, turn_id)


func _on_tool_execution_started(call_id: String, tool_name: String, arguments: Dictionary) -> void:
	_finish_stream_before_activity()
	_remove_transient_card()
	if tool_name == AgentController.WORK_MODE_REQUEST_TOOL:
		_turn_had_mode_request = true
		_close_active_tool_group()
		return
	_turn_had_tools = true
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
	if tool_name == AgentController.WORK_MODE_REQUEST_TOOL:
		if _tool_cards.has(call_id) and is_instance_valid(_tool_cards[call_id]):
			_tool_cards[call_id].complete(execution, duration_ms)
		var summary := "Switched to Work mode" if execution.get("success", false) and str(execution.get("content", "")).contains("approved Work mode") else "Stayed in Plan mode" if execution.get("success", false) else "Mode switch cancelled" if str(execution.get("outcome", "")) == "cancelled" else "Mode switch failed"
		_append_session_event({"type": "tool", "timestamp": Time.get_unix_time_from_system(), "id": call_id, "name": tool_name, "arguments": {}, "outcome": str(execution.get("outcome", "failed")), "summary": summary, "duration_ms": duration_ms})
		_save_current_session()
		_scroll_to_bottom()
		return
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


func _on_work_mode_requested(request: Dictionary, origin_turn_id: int) -> void:
	_close_active_tool_group()
	var call_id := str(request.get("call_id", ""))
	if call_id.is_empty():
		return
	if _tool_cards.has(call_id) and is_instance_valid(_tool_cards[call_id]):
		_tool_cards[call_id].queue_free()
	var card := ModeSwitchCard.new()
	chat_feed.add_child(card)
	card.configure(request, origin_turn_id)
	card.decision_requested.connect(_on_work_mode_decision_requested)
	_tool_cards[call_id] = card
	_scroll_to_bottom()


func _on_work_mode_decision_requested(call_id: String, origin_turn_id: int, approved: bool) -> void:
	agent_controller.resolve_work_mode_request(call_id, origin_turn_id, approved)


func _on_tasks_changed(tasks: Array) -> void:
	_ensure_session()
	_session["tasks"] = tasks.duplicate(true)
	if task_list_panel != null:
		task_list_panel.set_tasks(tasks)
	_save_current_session()


func _on_workflow_state_changed(state: String, details: Dictionary) -> void:
	if state in ["thinking", "finalizing"]:
		_response_attribution = ResponseAttribution.sanitize(details.get("attribution", {}))
	match state:
		"thinking":
			_show_working_indicator("Preparing response" if bool(details.get("follow_up", false)) else "Thinking")
		"finalizing":
			_show_working_indicator("Finalizing safely")
		"observing":
			_show_working_indicator("Observing game")
		"assessment_ready":
			if agent_controller.is_busy():
				_show_working_indicator("Assessing results")
			else:
				_remove_transient_card()
		_:
			_remove_transient_card()


func _on_edit_proposed(proposal: Dictionary, origin_turn_id: int = -1) -> void:
	_close_active_tool_group()
	var change_id: String = proposal.get("id", "")
	if origin_turn_id >= 0:
		_change_origin_turns[change_id] = origin_turn_id
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
	card.action_requested.connect(_on_change_action_requested.bind(origin_turn_id))
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
	_update_change_event(change_id, status, message)
	_change_origin_turns.erase(change_id)
	_recount_changed_files()
	_save_current_session()
	_scroll_to_bottom()


func _on_change_action_requested(change_id: String, action: String, origin_turn_id: int = -1) -> void:
	match action:
		"apply":
			agent_controller.resolve_edit(change_id, origin_turn_id, true)
		"reject":
			agent_controller.resolve_edit(change_id, origin_turn_id, false)
		"revert":
			agent_controller.revert_edit(change_id)


func _on_open_file_requested(filepath: String, line: int, column: int) -> void:
	if not EditorContext.open_file(filepath, line, column):
		_add_message("System Error", "Could not open " + filepath, Color.INDIAN_RED, "error")


func _on_help_requested(topic: String) -> void:
	if not ToolActivityCard.is_safe_help_topic(topic) or not Engine.is_editor_hint():
		return
	EditorInterface.get_script_editor().goto_help(topic)


func _on_agent_message_received(_role: String, content: String, attribution: Dictionary = {}) -> void:
	var response_attribution := ResponseAttribution.sanitize(attribution)
	var color := _assistant_color_for_mode(response_attribution["mode"]) if not response_attribution.is_empty() else _assistant_color()
	_submitted_image_draft.clear()
	_close_active_tool_group()
	_set_request_active(false)
	_remove_transient_card()
	if _stream_label != null and is_instance_valid(_stream_label):
		if content.strip_edges().is_empty():
			_stream_label.get_parent().queue_free()
		else:
			_stream_content = content
			_finalize_assistant_message(_stream_label, "Orca", content, color, response_attribution)
		_stream_label = null
		_stream_content = ""
	elif not content.is_empty():
		_add_final_assistant_message("Orca", content, color, response_attribution)
	if not content.is_empty():
		_append_session_event(_message_event("Orca", content, "assistant", "complete", response_attribution))
	_session["clean"] = true
	_session["resumable"] = not _session_resume_tainted
	prompt_input.placeholder_text = "Describe what you want to build or fix..."
	_turn_had_tools = false
	_turn_had_mode_request = false
	_save_current_session()
	_scroll_to_bottom()


func _on_agent_error_occurred(message: String) -> void:
	if not _submitted_image_draft.is_empty() and not _turn_had_tools and not _turn_had_mode_request and _draft_images.is_empty() and _draft_script_paths.is_empty() and prompt_input.text.is_empty():
		prompt_input.text = str(_submitted_image_draft.get("text", ""))
		_draft_images = _submitted_image_draft.get("images", []).duplicate(true)
		_draft_script_paths = _submitted_image_draft.get("script_paths", []).duplicate()
		_refresh_attachment_tray()
		_refresh_script_reference_tray()
	_submitted_image_draft.clear()
	_set_request_active(false)
	_remove_transient_card()
	var recovered: bool = (_turn_had_tools or _turn_had_mode_request) and agent_controller != null and agent_controller.has_method("last_failure_was_checkpointed") and bool(agent_controller.last_failure_was_checkpointed())
	var partial_content := _stream_content
	if _stream_label != null and is_instance_valid(_stream_label):
		if _stream_content.is_empty():
			_stream_label.get_parent().queue_free()
		else:
			_update_message_label(_stream_label, "Orca (incomplete)", _stream_content, Color(0.78, 0.64, 0.36))
			_set_response_footer(_response_panel(_stream_label), _response_attribution)
	_stream_label = null
	_stream_content = ""
	_add_message("Recovery Ready" if recovered else "System Error", message, Color(0.78, 0.64, 0.36) if recovered else Color.INDIAN_RED, "status" if recovered else "error")
	if not partial_content.is_empty():
		_append_session_event(_message_event("Orca (incomplete)", partial_content, "assistant", "incomplete", _response_attribution))
	_append_session_event(_message_event("Recovery Ready" if recovered else "System Error", message, "status" if recovered else "error", "complete"))
	_session["clean"] = true
	if _turn_had_tools or _turn_had_mode_request:
		_set_interrupted_turn_resumability(recovered)
	_turn_had_tools = false
	_turn_had_mode_request = false
	_save_current_session()
	print("Orca Error: ", message)


func _set_interrupted_turn_resumability(recovered: bool) -> void:
	_session_resume_tainted = not recovered
	_session["resumable"] = recovered
	_session_resumable = recovered
	prompt_input.editable = recovered
	prompt_input.placeholder_text = "Describe unfinished work from the recovery checkpoint..." if recovered else "Start a new chat to continue after this interrupted tool turn"
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
		var color := _assistant_color_for_mode(_response_attribution["mode"]) if not _response_attribution.is_empty() else _assistant_color()
		_finalize_assistant_message(_stream_label, "Orca", _stream_content, color, _response_attribution)
		_append_session_event(_message_event("Orca", _stream_content, "assistant", "tool_preface", _response_attribution))
	_stream_label = null
	_stream_content = ""


func _on_agent_request_cancelled() -> void:
	_set_request_active(false)
	_remove_transient_card()
	var partial_content := _stream_content
	if _stream_label != null and is_instance_valid(_stream_label) and not partial_content.is_empty():
		_set_response_footer(_response_panel(_stream_label), _response_attribution)
	_stream_label = null
	_stream_content = ""
	if not partial_content.is_empty():
		_append_session_event(_message_event("Orca", partial_content, "assistant", "cancelled", _response_attribution))
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
	_turn_had_mode_request = false
	_save_current_session()


func _set_request_active(active: bool) -> void:
	_request_active = active
	send_icon_view.texture = _stop_icon if active else _send_icon
	send_button.tooltip_text = "Stop response (draft text is kept)" if active else "Send message"
	_sync_send_availability()
	mode_button.disabled = active or not _session_resumable
	new_session_button.disabled = active
	history_button.disabled = active
	settings_button.disabled = active
	model_label.disabled = active
	prompt_input.editable = _session_resumable
	mode_label.modulate = Color(1, 1, 1, 0.5) if active else Color.WHITE
	_refresh_connection_setup()


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
	_dismiss_connection_setup(false)
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

func _on_mode_selected(mode: int, keep_prompt_focus: bool = false) -> void:
	if agent_controller.set_mode(mode):
		_sync_mode_ui(mode)
		if not _session.is_empty():
			_session["mode"] = mode
			_save_current_session()
	if keep_prompt_focus:
		mode_overlay.hide()
	else:
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
	) + "\nTab to switch modes in the prompt box"
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
	_refresh_connection_setup()
	prompt_input.grab_focus()


func _sync_model_ui() -> void:
	_close_image_attachment_window()
	var model := Config.get_model().strip_edges()
	model_label.text = model if not model.is_empty() else "No model"
	model_label.tooltip_text = "Current model: %s\nClick to configure" % model_label.text
	_sync_send_availability()
	_refresh_connection_setup()


func _refresh_model_metadata() -> void:
	if Config.get_provider() == "orca_cloud":
		return
	model_catalog_service.refresh(Config.get_model(), Config.get_api_url())


func _on_account_state_changed() -> void:
	_refresh_connection_setup()
	if Config.get_provider() == "orca_cloud":
		_sync_model_ui()
		if not agent_controller.is_busy():
			agent_controller.refresh_session_usage()


func _on_model_metadata_updated() -> void:
	agent_controller.refresh_session_usage()
	_sync_send_availability()


func _on_new_session_pressed() -> void:
	if agent_controller == null or agent_controller.is_busy():
		return
	if _has_session_content:
		_new_session_dialog.popup_centered()
	else:
		_start_new_session()


func _start_new_session() -> void:
	_close_image_attachment_window()
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
	_response_attribution.clear()
	_tool_cards.clear()
	_change_cards.clear()
	_tool_event_indices.clear()
	_task_tool_arguments.clear()
	_turn_had_tools = false
	_turn_had_mode_request = false
	_clear_chat_feed()
	if task_list_panel != null:
		task_list_panel.clear()
	_clear_prompt_input()
	prompt_input.editable = true
	_draft_images.clear()
	_draft_script_paths.clear()
	_refresh_script_reference_tray()
	_refresh_attachment_tray()
	_submitted_image_draft.clear()
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
	_close_image_attachment_window()
	var resumable := bool(session.get("clean", true)) and bool(session.get("resumable", true)) and not bool(session.get("truncated", false))
	var previous_session_id := str(_session.get("id", ""))
	if not session_store.set_active_session(str(session.get("id", ""))):
		return false
	if not agent_controller.restore_session_state(int(session.get("mode", AgentController.AgentMode.BUILD)), session.get("continuation", []), session.get("usage", {}), session.get("tasks", [])):
		session_store.set_active_session(previous_session_id)
		return false
	_session = session.duplicate(true)
	_response_attribution.clear()
	_draft_images.clear()
	_draft_script_paths.clear()
	_refresh_script_reference_tray()
	_submitted_image_draft.clear()
	_refresh_attachment_tray()
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


func _message_event(sender: String, text: String, kind: String, completion: String, attribution: Dictionary = {}) -> Dictionary:
	var event := {
		"type": "message",
		"timestamp": Time.get_unix_time_from_system(),
		"sender": sender,
		"text": text,
		"kind": kind,
		"mode": agent_controller.get_mode(),
		"completion": completion
	}
	if kind == "assistant":
		var response_attribution := ResponseAttribution.sanitize(attribution)
		if not response_attribution.is_empty():
			event["attribution"] = response_attribution
			event["mode"] = response_attribution["mode"]
	return event


func _safe_tool_arguments(arguments: Dictionary, tool_name: String = "") -> Dictionary:
	var result := {}
	if tool_name == "inspect_editor_scene":
		if typeof(arguments.get("scope")) == TYPE_STRING and str(arguments["scope"]) in ["selection", "scene", "subtree"]:
			result["scope"] = arguments["scope"]
		for key in ["node_path", "scene_path"]:
			if typeof(arguments.get(key)) == TYPE_STRING:
				result[key] = str(arguments[key]).left(512)
		for bounds in [["max_nodes", 1, 120], ["max_depth", 0, 16], ["max_properties_per_node", 0, 32]]:
			if typeof(arguments.get(bounds[0])) in [TYPE_INT, TYPE_FLOAT]:
				var limit := float(arguments[bounds[0]])
				if is_finite(limit) and limit == floorf(limit):
					result[bounds[0]] = int(clampf(limit, bounds[1], bounds[2]))
		if typeof(arguments.get("include_properties")) == TYPE_BOOL:
			result["include_properties"] = arguments["include_properties"]
		return result
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
	if str(event.get("name", "")) == "inspect_editor_scene":
		if outcome == "completed":
			var node_count := clampi(int(data.get("returned_node_count", 0)), 0, 120)
			var state_label := " with unsaved changes" if data.get("unsaved_changes", false) else ""
			var truncation_label := " (truncated)" if data.get("truncated", false) else ""
			event["summary"] = "Historical live-editor inspection: %d node(s)%s%s. Inspect again for current state." % [node_count, state_label, truncation_label]
		else:
			event["summary"] = "Live editor inspection did not complete."
	elif str(event.get("name", "")) == "verify_game_run" and outcome == "completed":
		event["summary"] = "Verification %s." % str(data.get("status", "unverified")).replace("_", " ")
	elif str(event.get("name", "")) in ["run_current_scene", "run_main_scene", "stop_game"] and outcome == "completed":
		event["summary"] = "Game process: " + str(data.get("state", "updated")).replace("_", " ")
	else:
		if outcome in ["apply_recovery_required", "revert_recovery_required"]:
			event["summary"] = "Recovery required. See the associated change record."
		elif outcome in ["failed", "conflict"]:
			event["summary"] = "Tool did not complete."
		elif outcome == "cancelled":
			event["summary"] = "Tool was cancelled."
		elif outcome in ["applied_recovery", "reverted_recovery"]:
			event["summary"] = "Completed with cleanup required."
		else:
			event["summary"] = "Completed successfully."
	if data.has("open_path"):
		event["open_path"] = str(data.get("open_path", ""))
		event["open_line"] = maxi(1, int(data.get("open_line", 1)))
		event["open_column"] = maxi(1, int(data.get("open_column", 1)))
	var help_topic := str(data.get("help_topic", ""))
	if ToolActivityCard.is_safe_help_topic(help_topic):
		event["help_topic"] = help_topic
	events[index] = event
	_session["events"] = events


func _update_change_event(change_id: String, status: String, message: String = "") -> void:
	var events: Array = _session.get("events", [])
	for index in range(events.size() - 1, -1, -1):
		var event = events[index]
		if typeof(event) == TYPE_DICTIONARY and event.get("type") == "change" and str(event.get("id", "")) == change_id:
			event["status"] = status
			if status in ["apply_recovery_required", "revert_recovery_required"]:
				event["resolution_message"] = _persisted_recovery_message(message)
			else:
				event.erase("resolution_message")
			events[index] = event
			break
	_session["events"] = events


func _persisted_recovery_message(message: String) -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	var sanitized := message.replace(project_root, "res://") if not project_root.is_empty() else message
	return sanitized.replace("\r", " ").replace("\n", " ").replace("\t", " ").left(512)


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
			var attribution := ResponseAttribution.sanitize(event.get("attribution", {})) if kind == "assistant" else {}
			if not attribution.is_empty():
				color = _assistant_color_for_mode(attribution["mode"])
			if kind == "assistant" and completion in ["complete", "tool_preface"]:
				_add_final_assistant_message(sender, text, color, attribution)
			else:
				var label := _add_message(sender, text, color, kind)
				if kind == "assistant":
					_set_response_footer(_response_panel(label), attribution)
				if kind == "user":
					_add_message_images(label, event.get("images", []))
					_add_message_script_references(label, event.get("script_references", []))
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
			var resolution_message := str(event.get("resolution_message", ""))
			if not resolution_message.is_empty():
				summary += "\n" + resolution_message
			_add_message("Change", summary, Color(0.62, 0.78, 0.68), "status")


func _clear_chat_feed() -> void:
	_dismiss_connection_setup(false)
	_close_active_tool_group()
	_tool_groups_by_call_id.clear()
	_change_origin_turns.clear()
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
	var request_budget: Dictionary = summary.get("request_budget", {})
	if not request_budget.is_empty() and (request_budget.get("active", false) or request_budget.get("status") == "blocked"):
		context_label.text = "Request ~%s" % _format_token_count(int(request_budget.get("estimated_tokens", 0)))
		if int(request_budget.get("context_limit", 0)) > 0:
			context_label.text += " / %s" % _format_token_count(int(request_budget["context_limit"]))
	var total_tokens := int(summary.get("input_tokens", 0)) + int(summary.get("output_tokens", 0))
	context_label.tooltip_text = (
		"Latest completed request (provider-reported): %s%s\nSession input: %s\nSession output: %s\nCached input: %s\nUsage reporting: %s"
		% [
			_format_token_count(context_tokens),
			" / " + _format_token_count(context_limit) if context_limit > 0 else "",
			_format_token_count(int(summary.get("input_tokens", 0))),
			_format_token_count(int(summary.get("output_tokens", 0))),
			_format_token_count(int(summary.get("cached_tokens", 0))),
			"complete" if usage_complete else "partial or unavailable"
		]
	)
	if not request_budget.is_empty():
		context_label.tooltip_text += "\n\nLocal request estimate: %d tokens (%s).\nSafe input budget: %d of %d tokens.\nReserved output: %d; future tool result: %d.\nIncludes request instructions, tool schemas/results, image reserves and private continuation when applicable. This estimate is separate from provider-reported usage and billing reservations." % [int(request_budget.get("estimated_tokens", 0)), str(request_budget.get("status", "prepared")), int(request_budget.get("input_budget", 0)), int(request_budget.get("context_limit", 0)), int(request_budget.get("output_reserve", 0)), int(request_budget.get("tool_reserve", 0))]
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
	_position_connection_overlay()
	if mode_overlay.visible:
		call_deferred("_position_mode_menu")


func _unhandled_key_input(event: InputEvent) -> void:
	if _connection_overlay != null and _connection_overlay.visible and event.is_action_pressed("ui_cancel"):
		_dismiss_connection_setup()
		get_viewport().set_input_as_handled()
		return
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


func _add_final_assistant_message(sender: String, message: String, color: Color, attribution: Dictionary = {}) -> void:
	var response_attribution := ResponseAttribution.sanitize(attribution)
	if not response_attribution.is_empty():
		color = _assistant_color_for_mode(response_attribution["mode"])
	var label := _add_message(sender, message, color, "assistant")
	_finalize_assistant_message(label, sender, message, color, response_attribution)


func _finalize_assistant_message(label: RichTextLabel, sender: String, message: String, color: Color, attribution: Dictionary = {}) -> void:
	if not is_instance_valid(label):
		return
	var blocks := _split_final_message_blocks(message)
	var has_code := blocks.any(func(block: Dictionary): return block.get("type") == "code")
	if not has_code:
		_update_message_label(label, sender, message, color)
		_set_response_footer(_response_panel(label), attribution)
		return
	var panel := _response_panel(label)
	if panel == null:
		return
	label.get_parent().remove_child(label)
	label.queue_free()
	for previous_child in panel.get_children():
		panel.remove_child(previous_child)
		previous_child.queue_free()
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
	_set_response_footer(panel, attribution)
	_scroll_to_bottom()


func _response_panel(label: RichTextLabel) -> PanelContainer:
	var parent: Node = label.get_parent()
	for _depth in range(3):
		if parent is PanelContainer:
			return parent
		if parent == null:
			break
		parent = parent.get_parent()
	return null


func _set_response_footer(panel: PanelContainer, raw_attribution: Dictionary) -> void:
	if panel == null:
		return
	var attribution := ResponseAttribution.sanitize(raw_attribution)
	var content := panel.get_child(0) as VBoxContainer if panel.get_child_count() == 1 else null
	if content != null:
		for child in content.get_children():
			if child.has_meta("orca_response_footer"):
				content.remove_child(child)
				child.queue_free()
	if attribution.is_empty():
		return
	if content == null:
		content = VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_theme_constant_override("separation", 0)
		for child in panel.get_children():
			panel.remove_child(child)
			content.add_child(child)
		panel.add_child(content)
	var footer := MarginContainer.new()
	footer.set_meta("orca_response_footer", true)
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_theme_constant_override("margin_top", maxi(0, UiMetrics.scaled_int(8) - content.get_theme_constant("separation")))
	for edge in ["left", "right", "bottom"]:
		footer.add_theme_constant_override("margin_" + edge, 0)
	content.add_child(footer)
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", UiMetrics.scaled_int(12))
	footer.add_child(row)
	var model := Label.new()
	model.set_meta("orca_response_model", true)
	model.text = attribution["model"]
	model.tooltip_text = attribution["model"]
	model.mouse_filter = Control.MOUSE_FILTER_PASS
	model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	model.max_lines_visible = 2
	model.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	model.add_theme_font_size_override("font_size", _meta_font_size)
	model.add_theme_color_override("font_color", Color(0.62, 0.65, 0.7))
	row.add_child(model)
	var mode := Label.new()
	mode.set_meta("orca_response_mode", true)
	mode.text = "Plan" if attribution["mode"] == AgentController.AgentMode.PLAN else "Work"
	mode.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	mode.add_theme_font_size_override("font_size", _meta_font_size)
	mode.add_theme_color_override("font_color", _assistant_color_for_mode(attribution["mode"]))
	row.add_child(mode)
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


func _setup_connection_overlay() -> void:
	if _connection_overlay != null:
		return
	# A positioned Control contributes no minimum size to the conversation or
	# composer. The normal empty state retains its original scene/theme layout.
	_connection_overlay = Control.new()
	_connection_overlay.name = "ConnectionOverlay"
	_connection_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_connection_overlay.hide()
	add_child(_connection_overlay)
	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0, 0, 0, 0.38)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_connection_overlay.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	_connection_overlay.add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_set_scaled_margins(margin, 12, 12, 12, 12)
	_connection_overlay_scroll = ScrollContainer.new()
	_connection_overlay_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(_connection_overlay_scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_connection_overlay_scroll.add_child(center)
	_connection_setup_card = ConnectionSetupPanel.new()
	_connection_setup_card.name = "ConnectionSetup"
	_connection_setup_card.body_font_size = _body_font_size
	_connection_setup_card.meta_font_size = _meta_font_size
	_connection_setup_card.account_requested.connect(_on_connection_account_requested)
	_connection_setup_card.provider_requested.connect(_on_connection_provider_requested)
	_connection_setup_card.model_requested.connect(_on_model_button_pressed)
	_connection_setup_card.dismiss_requested.connect(_dismiss_connection_setup)
	center.add_child(_connection_setup_card)
	chat_scroll.resized.connect(_position_connection_overlay)
	chat_scroll.item_rect_changed.connect(_position_connection_overlay)
	visibility_changed.connect(_on_connection_view_visibility_changed)
	main_content.visibility_changed.connect(_on_connection_view_visibility_changed)
	_position_connection_overlay()


func notify_dock_opened() -> void:
	if _connection_overlay == null or not is_visible_in_tree() or not main_content.is_visible_in_tree():
		return
	_connection_dock_open_notified = true
	_connection_first_open_pending = true
	call_deferred("_maybe_show_first_connection_setup")


func _on_connection_view_visibility_changed() -> void:
	if not is_visible_in_tree() or not main_content.is_visible_in_tree():
		_dismiss_connection_setup(false)
	elif _connection_dock_open_notified:
		# Godot may restore dock visibility during initialization. Only an
		# explicit Orca opening arms subsequent visibility-driven notifications.
		notify_dock_opened()


func _maybe_show_first_connection_setup() -> void:
	if _connection_overlay == null or _connection_first_open_checked or not _connection_first_open_pending or not is_visible_in_tree() or not main_content.is_visible_in_tree() or agent_controller == null or agent_controller.is_busy():
		return
	# Wait for the vault restoration decision without changing the empty state
	# or consuming first-open intent while the dock is hidden.
	if account_service != null and account_service.onboarding_restoration_pending():
		return
	var setup: Dictionary = agent_controller.connection_setup()
	_connection_first_open_checked = true
	_connection_first_open_pending = false
	if setup.get("status") != "ready" and not agent_controller.has_configured_connection() and _session_resumable:
		_show_connection_setup(setup, true)


func _refresh_connection_setup() -> void:
	if _connection_overlay == null or agent_controller == null or not agent_controller.has_method("connection_setup"):
		return
	var setup: Dictionary = agent_controller.connection_setup()
	var connected: bool = account_service != null and account_service.connected()
	var account_state := str(account_service.state) if account_service != null else "signed_out"
	if _connection_overlay.visible:
		if setup.get("status") == "ready" or agent_controller.is_busy():
			_dismiss_connection_setup(false)
		else:
			_connection_setup_card.configure(setup, connected, account_state, false, _connection_setup_first_open)
	if _connection_first_open_pending and not _connection_first_open_checked:
		call_deferred("_maybe_show_first_connection_setup")


func _show_connection_setup(setup: Dictionary, first_open: bool = false) -> void:
	if _connection_overlay == null or agent_controller == null or agent_controller.is_busy() or not _session_resumable:
		return
	_connection_first_open_checked = true
	_connection_first_open_pending = false
	_connection_setup_first_open = first_open
	var connected: bool = account_service != null and account_service.connected()
	_connection_setup_card.configure(setup, connected, str(account_service.state) if account_service != null else "signed_out", false, first_open)
	mode_overlay.hide()
	_connection_overlay.show()
	_position_connection_overlay()
	_connection_overlay_scroll.scroll_vertical = 0
	call_deferred("_focus_connection_setup")


func _position_connection_overlay() -> void:
	if _connection_overlay == null:
		return
	_connection_overlay.position = chat_scroll.global_position - global_position
	_connection_overlay.size = chat_scroll.size
	var scrollbar_width := _connection_overlay_scroll.get_v_scroll_bar().get_combined_minimum_size().x
	_connection_setup_card.custom_minimum_size.x = minf(UiMetrics.scaled(360), maxf(0.0, chat_scroll.size.x - UiMetrics.scaled(24) - scrollbar_width))


func _focus_connection_setup() -> void:
	if _connection_overlay == null or not _connection_overlay.is_visible_in_tree():
		return
	var button: Button = _connection_setup_card.model_button if _connection_setup_card.model_button.get_parent().visible else _connection_setup_card.provider_button if _connection_setup_card.account_button.disabled else _connection_setup_card.account_button
	button.grab_focus()


func _dismiss_connection_setup(focus_prompt: bool = true) -> void:
	if _connection_overlay == null:
		return
	var was_visible := _connection_overlay.visible
	_connection_overlay.hide()
	if was_visible and focus_prompt and prompt_input.is_visible_in_tree():
		prompt_input.grab_focus()


func _on_connection_account_requested() -> void:
	_open_settings(false, "account")


func _on_connection_provider_requested() -> void:
	_open_settings(false, "provider")


func _on_settings_button_pressed() -> void:
	_open_settings(false)


func _on_model_button_pressed() -> void:
	_open_settings(true)


func _open_settings(focus_model: bool, setup_route: String = "") -> void:
	if agent_controller != null and agent_controller.is_busy():
		return
	_dismiss_connection_setup(false)
	if mode_overlay.visible:
		mode_overlay.hide()
	if history_view != null:
		history_view.hide()
	main_content.hide()
	if settings_view != null:
		var support_metadata: Dictionary = {}
		if agent_controller != null and agent_controller.has_method("support_request_metadata"):
			support_metadata = agent_controller.support_request_metadata()
		settings_view.set_support_request_metadata(support_metadata)
	if setup_route == "account":
		settings_view.open_account_setup()
	elif setup_route == "provider":
		settings_view.open_provider_setup()
	elif focus_model:
		settings_view.open_model_configuration()
	else:
		settings_view.open()
