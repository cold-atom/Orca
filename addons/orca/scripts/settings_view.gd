@tool
extends PanelContainer

signal done_requested
signal settings_saved(provider_id: String, model: String)

const Config = preload("res://addons/orca/scripts/config.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const ProviderModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const AgentCompatibilityProbe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const SupportDiagnosticReport = preload("res://addons/orca/scripts/support_diagnostic_report.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const UpdatePanel = preload("res://addons/orca/scripts/update_panel.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")
const PLUGIN_CONFIG_PATH := "res://addons/orca/plugin.cfg"
const ABOUT_LOGO_PATH := "res://addons/orca/assets/orca.svg"
const PROVIDER_ICON = preload("res://addons/orca/assets/providerconfig.svg")
const SYSTEM_ICON = preload("res://addons/orca/assets/systems.svg")
const ABOUT_ICON = preload("res://addons/orca/assets/about.svg")
const ACCOUNT_ICON = preload("res://addons/orca/assets/profile.svg")
const SUPPORTED_GODOT_VERSION := "4.7.2"

var provider_selector: OptionButton
var api_key_label: Label
var api_key_input: LineEdit
var show_key_button: Button
var key_link: LinkButton
var model_search: LineEdit
var model_selector: OptionButton
var custom_url_label: Label
var custom_url_input: LineEdit
var endpoint_status_label: Label
var custom_model_input: LineEdit
var api_mode_label: Label
var api_mode_selector: OptionButton
var api_mode_help: Label
var continuation_label: Label
var continuation_selector: OptionButton
var effort_label: Label
var effort_selector: OptionButton
var effort_help: Label
var metadata_label: Label
var status_label: Label
var agent_status_label: Label
var agent_heading_label: Label
var agent_probe_button: Button
var agent_enable_toggle: CheckButton
var agent_warning_label: Label
var done_button: Button
var refresh_button: Button
var settings_scroll: ScrollContainer
var about_scroll: ScrollContainer
var system_scroll: ScrollContainer
var provider_tab_button: Button
var system_tab_button: Button
var about_tab_button: Button
var account_tab_button: Button
var account_scroll: ScrollContainer
var account_service
var account_sign_in_button: Button
var account_cancel_button: Button
var account_reopen_button: Button
var account_refresh_button: Button
var account_console_button: Button
var account_sign_out_button: Button
var account_use_models_button: Button
var _account_status_label: Label
var _account_name_label: Label
var _account_usage_label: Label
var _account_code_label: Label
var _key_help: Label
var language_selector: OptionButton
var image_support_toggle: CheckButton
var about_version_label: Label
var update_service
var update_panel
var support_report_status: Label
var _trust_dialog: ConfirmationDialog
var _pending_trust_action := ""
var _pending_trust_origin := ""
var _pending_trust_provider := ""
var _model_service
var _agent_probe
var _key_timer: Timer
var _current_provider := ""
var _current_models: Array[Dictionary] = []
var _selected_model := ""
var _selected_effort := "default"
var _selected_api_mode := "chat_completions"
var _continuation_style := "standard"
var _agent_enable_intent := ""
var _loading_provider := false
var _body_font_size := 13
var _meta_font_size := 11
var _support_request_metadata: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		var editor_font_size := editor_theme.get_font_size("font_size", "Label")
		if editor_font_size <= 0:
			editor_font_size = editor_theme.get_font_size("font_size", "TextEdit")
		if editor_font_size > 0:
			_body_font_size = maxi(editor_font_size, 13)
			_meta_font_size = maxi(_body_font_size - 1, 11)
	_build_ui()
	_trust_dialog = ConfirmationDialog.new()
	_trust_dialog.title = "Trust AI Endpoint"
	_trust_dialog.confirmed.connect(_on_endpoint_trust_confirmed)
	_trust_dialog.canceled.connect(_on_endpoint_trust_cancelled)
	add_child(_trust_dialog)
	_model_service = ProviderModelService.new()
	add_child(_model_service)
	_model_service.models_loaded.connect(_on_models_loaded)
	_model_service.models_failed.connect(_on_models_failed)
	_agent_probe = AgentCompatibilityProbe.new()
	_agent_probe.account_service = account_service
	add_child(_agent_probe)
	_agent_probe.probe_step_changed.connect(_on_probe_step_changed)
	_agent_probe.probe_passed.connect(_on_probe_passed)
	_agent_probe.probe_failed.connect(_on_probe_failed)
	_agent_probe.probe_cancelled.connect(_on_probe_cancelled)
	_key_timer = Timer.new()
	_key_timer.one_shot = true
	_key_timer.wait_time = 0.8
	_key_timer.timeout.connect(_refresh_models)
	add_child(_key_timer)
	_populate_providers()
	if account_service != null:
		account_service.changed.connect(_on_account_changed)
		account_service.signed_in.connect(_on_cloud_signed_in)
	_render_account()


func open() -> void:
	show()
	_show_section("provider")
	_select_provider(Config.get_provider())


func open_model_configuration() -> void:
	open()
	call_deferred("_focus_model_configuration")


func open_account_setup() -> void:
	# Only a user-owned setup action calls this entry point. Opening Settings or
	# constructing the welcome never starts pairing or opens a browser.
	show()
	_select_provider(Config.get_provider())
	_show_section("account")
	if account_service == null:
		return
	if account_service.connected():
		_on_use_cloud_models()
		call_deferred("_focus_model_configuration")
	elif account_service.state not in ["connecting", "pairing", "restoring", "signing_out"]:
		_on_account_sign_in()


func open_provider_setup() -> void:
	open()
	if _current_provider == "orca_cloud":
		_select_provider("openai")
	call_deferred("_focus_provider_setup")


func _focus_provider_setup() -> void:
	if not settings_scroll.visible:
		return
	provider_selector.grab_focus()
	settings_scroll.scroll_vertical = 0


func set_support_request_metadata(metadata: Dictionary) -> void:
	_support_request_metadata = metadata.duplicate(true)


func _build_ui() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.09, 0.095, 0.105, 1.0)
	add_theme_stylebox_override("panel", background)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UiMetrics.scaled_int(14))
	margin.add_theme_constant_override("margin_top", UiMetrics.scaled_int(12))
	margin.add_theme_constant_override("margin_right", UiMetrics.scaled_int(14))
	margin.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(12))
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	margin.add_child(root)

	var header := HBoxContainer.new()
	root.add_child(header)
	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", _body_font_size + 4)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	done_button = Button.new()
	done_button.text = "Done"
	done_button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(72, 34))
	done_button.pressed.connect(_on_done_pressed)
	header.add_child(done_button)
	root.add_child(HSeparator.new())

	var navigation := PanelContainer.new()
	navigation.name = "SectionNavigation"
	var navigation_style := StyleBoxFlat.new()
	navigation_style.bg_color = Color(0.115, 0.12, 0.13)
	navigation_style.set_corner_radius_all(UiMetrics.scaled_int(8))
	navigation_style.content_margin_left = UiMetrics.scaled(4)
	navigation_style.content_margin_right = UiMetrics.scaled(4)
	navigation_style.content_margin_top = UiMetrics.scaled(4)
	navigation_style.content_margin_bottom = UiMetrics.scaled(4)
	navigation.add_theme_stylebox_override("panel", navigation_style)
	root.add_child(navigation)
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", UiMetrics.scaled_int(4))
	navigation.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	tab_group.allow_unpress = false
	provider_tab_button = _section_tab("Provider", PROVIDER_ICON, tab_group)
	provider_tab_button.name = "ProviderTab"
	provider_tab_button.pressed.connect(_show_section.bind("provider"))
	tab_row.add_child(provider_tab_button)
	system_tab_button = _section_tab("System", SYSTEM_ICON, tab_group)
	system_tab_button.name = "SystemTab"
	system_tab_button.pressed.connect(_show_section.bind("system"))
	tab_row.add_child(system_tab_button)
	account_tab_button = _section_tab("Account", ACCOUNT_ICON, tab_group)
	account_tab_button.name = "AccountTab"
	account_tab_button.pressed.connect(_show_section.bind("account"))
	tab_row.add_child(account_tab_button)
	about_tab_button = _section_tab("About", ABOUT_ICON, tab_group)
	about_tab_button.name = "AboutTab"
	about_tab_button.pressed.connect(_show_section.bind("about"))
	tab_row.add_child(about_tab_button)

	settings_scroll = ScrollContainer.new()
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(settings_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	settings_scroll.add_child(content)

	var section := Label.new()
	section.text = "API CONFIGURATION"
	section.add_theme_font_size_override("font_size", _meta_font_size)
	section.add_theme_color_override("font_color", Color(0.66, 0.7, 0.76))
	content.add_child(section)
	content.add_child(_field_label("API Provider"))
	provider_selector = OptionButton.new()
	provider_selector.fit_to_longest_item = false
	provider_selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	provider_selector.item_selected.connect(_on_provider_selected)
	content.add_child(provider_selector)

	api_key_label = _field_label("API Key")
	content.add_child(api_key_label)
	var key_row := HBoxContainer.new()
	content.add_child(key_row)
	api_key_input = LineEdit.new()
	api_key_input.secret = true
	api_key_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	api_key_input.placeholder_text = "Enter API key"
	api_key_input.text_changed.connect(_on_api_key_changed)
	key_row.add_child(api_key_input)
	show_key_button = Button.new()
	show_key_button.text = "Show"
	show_key_button.toggle_mode = true
	show_key_button.toggled.connect(_on_show_key_toggled)
	key_row.add_child(show_key_button)
	key_link = LinkButton.new()
	key_link.text = "Get an API key"
	key_link.pressed.connect(_on_key_link_pressed)
	content.add_child(key_link)
	var key_help := Label.new()
	_key_help = key_help
	key_help.text = "Stored in Godot Editor Settings and used only for requests to the selected provider."
	key_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	key_help.add_theme_color_override("font_color", Color(0.58, 0.61, 0.67))
	content.add_child(key_help)

	custom_url_label = _field_label("Base URL")
	content.add_child(custom_url_label)
	custom_url_input = LineEdit.new()
	custom_url_input.text_changed.connect(_on_custom_url_changed)
	content.add_child(custom_url_input)
	endpoint_status_label = Label.new()
	endpoint_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	endpoint_status_label.add_theme_color_override("font_color", Color(0.72, 0.64, 0.42))
	content.add_child(endpoint_status_label)
	api_mode_label = _field_label("API")
	content.add_child(api_mode_label)
	api_mode_selector = OptionButton.new()
	api_mode_selector.fit_to_longest_item = false
	api_mode_selector.add_item("Responses (reasoning + tools)")
	api_mode_selector.set_item_metadata(0, "responses")
	api_mode_selector.add_item("Chat Completions")
	api_mode_selector.set_item_metadata(1, "chat_completions")
	api_mode_selector.item_selected.connect(_on_api_mode_selected)
	content.add_child(api_mode_selector)
	api_mode_help = Label.new()
	api_mode_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	api_mode_help.add_theme_color_override("font_color", Color(0.58, 0.61, 0.67))
	content.add_child(api_mode_help)
	continuation_label = _field_label("Reasoning Continuation")
	content.add_child(continuation_label)
	continuation_selector = OptionButton.new()
	continuation_selector.fit_to_longest_item = false
	continuation_selector.add_item("Standard")
	continuation_selector.set_item_metadata(0, "standard")
	continuation_selector.add_item("DeepSeek reasoning")
	continuation_selector.set_item_metadata(1, "deepseek")
	continuation_selector.tooltip_text = "For Azure DeepSeek deployments, preserve private reasoning through Chat or Responses tool follow-ups and remove one leaked leading </think> delimiter. Works with custom deployment names."
	continuation_selector.item_selected.connect(_on_continuation_selected)
	content.add_child(continuation_selector)

	content.add_child(_field_label("Model"))
	model_search = LineEdit.new()
	model_search.placeholder_text = "Search available models..."
	model_search.text_changed.connect(_on_model_search_changed)
	content.add_child(model_search)
	var model_row := HBoxContainer.new()
	content.add_child(model_row)
	model_selector = OptionButton.new()
	model_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model_selector.fit_to_longest_item = false
	model_selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	model_selector.item_selected.connect(_on_model_selected)
	model_row.add_child(model_selector)
	refresh_button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_refresh_models)
	model_row.add_child(refresh_button)
	custom_model_input = LineEdit.new()
	custom_model_input.placeholder_text = "Model ID"
	custom_model_input.text_changed.connect(_on_manual_model_changed)
	content.add_child(custom_model_input)
	image_support_toggle = CheckButton.new()
	image_support_toggle.text = "Enable unconfirmed image input"
	image_support_toggle.clip_text = true
	image_support_toggle.tooltip_text = "Use only if this exact endpoint and model accept image_url content. This does not enable Agent tools or verify vision quality."
	image_support_toggle.toggled.connect(_on_image_support_toggled)
	content.add_child(image_support_toggle)

	effort_label = _field_label("Reasoning Effort")
	content.add_child(effort_label)
	effort_selector = OptionButton.new()
	effort_selector.item_selected.connect(_on_effort_selected)
	content.add_child(effort_selector)
	effort_help = Label.new()
	effort_help.text = "Higher effort can improve difficult planning and debugging, but may use more tokens."
	effort_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effort_help.add_theme_color_override("font_color", Color(0.58, 0.61, 0.67))
	content.add_child(effort_help)

	metadata_label = Label.new()
	metadata_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	metadata_label.add_theme_color_override("font_color", Color(0.68, 0.73, 0.8))
	content.add_child(metadata_label)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.58, 0.7, 0.82))
	content.add_child(status_label)
	agent_heading_label = _field_label("Agent Compatibility")
	content.add_child(agent_heading_label)
	agent_status_label = Label.new()
	agent_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(agent_status_label)
	agent_probe_button = Button.new()
	agent_probe_button.text = "Test & Enable Agent tools"
	agent_probe_button.tooltip_text = "Run the project-free compatibility check and enable Agent tools for this exact profile only if it passes."
	agent_probe_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	agent_probe_button.pressed.connect(_on_agent_probe_pressed)
	content.add_child(agent_probe_button)
	agent_enable_toggle = CheckButton.new()
	agent_enable_toggle.text = "Enable Agent tools"
	agent_enable_toggle.tooltip_text = "Enable Agent tools for this exact endpoint and model"
	agent_enable_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agent_enable_toggle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	agent_enable_toggle.clip_text = true
	agent_enable_toggle.toggled.connect(_on_agent_enable_toggled)
	content.add_child(agent_enable_toggle)
	agent_warning_label = Label.new()
	agent_warning_label.text = "This project-free check enables Agent tools when it passes. Agent tools may send project context and perform normal Plan/Work operations; project changes still require approval."
	agent_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	agent_warning_label.add_theme_color_override("font_color", Color(0.72, 0.64, 0.42))
	content.add_child(agent_warning_label)

	system_scroll = _build_system_view()
	root.add_child(system_scroll)
	account_scroll = _build_account_view()
	root.add_child(account_scroll)
	about_scroll = _build_about_view()
	about_scroll.hide()
	root.add_child(about_scroll)
	_show_section("provider")


func _section_tab(section_name: String, texture: Texture2D, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.tooltip_text = section_name
	button.icon = texture
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.add_theme_constant_override("icon_max_width", UiMetrics.scaled_int(22))
	button.toggle_mode = true
	button.button_group = group
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = UiMetrics.scaled_vector(Vector2(40, 36))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0)
	normal.set_corner_radius_all(UiMetrics.scaled_int(5))
	normal.set_content_margin_all(UiMetrics.scaled(8))
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.17, 0.175, 0.185)
	var selected := normal.duplicate() as StyleBoxFlat
	selected.bg_color = Color(0.235, 0.24, 0.25)
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = Color(0.58, 0.6, 0.63, 0.6)
	focus.set_border_width_all(UiMetrics.scaled_int(1))
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", selected)
	button.add_theme_stylebox_override("hover_pressed", selected)
	button.add_theme_stylebox_override("focus", focus)
	button.add_theme_color_override("icon_normal_color", Color(0.58, 0.6, 0.63))
	button.add_theme_color_override("icon_hover_color", Color(0.82, 0.83, 0.85))
	button.add_theme_color_override("icon_pressed_color", Color(0.94, 0.95, 0.96))
	button.add_theme_color_override("icon_hover_pressed_color", Color(0.98, 0.98, 0.99))
	return button


func _show_section(section: String) -> void:
	if section != "account" and account_service != null and account_service.state in ["pairing", "connecting"]:
		account_service.cancel_pairing()
	if account_scroll != null:
		account_scroll.visible = section == "account"
		if section == "account" and account_service != null and account_service.connected():
			account_service.refresh_account()
	if account_tab_button != null:
		account_tab_button.set_pressed_no_signal(section == "account")
	if settings_scroll != null:
		settings_scroll.visible = section == "provider"
	if system_scroll != null:
		system_scroll.visible = section == "system"
	if about_scroll != null:
		about_scroll.visible = section == "about"
	if provider_tab_button != null:
		provider_tab_button.set_pressed_no_signal(section == "provider")
	if system_tab_button != null:
		system_tab_button.set_pressed_no_signal(section == "system")
	if about_tab_button != null:
		about_tab_button.set_pressed_no_signal(section == "about")


func _build_system_view() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "SystemScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	scroll.add_child(content)
	content.add_child(_about_heading("GENERAL SETTINGS"))
	content.add_child(_field_label("Language"))
	language_selector = OptionButton.new()
	language_selector.name = "LanguageSelector"
	language_selector.add_item("English")
	language_selector.select(0)
	language_selector.disabled = true
	language_selector.tooltip_text = "English is the only supported language currently."
	content.add_child(language_selector)
	var language_help := Label.new()
	language_help.text = "More languages will be available in a future update."
	language_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	language_help.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(language_help)
	content.add_child(HSeparator.new())
	update_panel = UpdatePanel.new()
	update_panel.name = "PluginUpdates"
	update_panel.service = update_service
	content.add_child(update_panel)
	return scroll


func _build_account_view() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "AccountScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	scroll.add_child(content)
	content.add_child(_about_heading("ORCA ACCOUNT"))
	_account_name_label = _field_label("")
	_account_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_account_name_label)
	_account_usage_label = _field_label("")
	_account_usage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_account_usage_label)
	_account_status_label = _field_label("Sign in to access models provided by Orca.")
	_account_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_account_status_label.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(_account_status_label)
	_account_code_label = _field_label("")
	content.add_child(_account_code_label)
	account_sign_in_button = _account_button(content, "Sign in / Sign up", "AccountSignIn", _on_account_sign_in)
	account_reopen_button = _account_button(content, "Open browser again", "AccountReopen", _on_account_reopen)
	account_cancel_button = _account_button(content, "Cancel connection", "AccountCancel", _on_account_cancel)
	account_use_models_button = _account_button(content, "Choose model", "AccountUseModels", _on_use_cloud_models)
	account_refresh_button = _account_button(content, "Refresh account", "AccountRefresh", _on_account_refresh)
	account_console_button = _account_button(content, "Open Orca Console", "AccountConsole", _on_account_console)
	account_sign_out_button = _account_button(content, "Sign out", "AccountSignOut", _on_account_sign_out)
	var storage := _field_label("Your connection is remembered in your OS credential vault. Account passwords and model-provider keys stay outside the plugin.")
	storage.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	storage.add_theme_font_size_override("font_size", _meta_font_size)
	storage.add_theme_color_override("font_color", Color(0.58, 0.61, 0.67))
	content.add_child(storage)
	return scroll


func _account_button(parent: Control, text: String, node_name: String, callback: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _render_account() -> void:
	if _account_status_label == null:
		return
	var connected: bool = account_service != null and account_service.connected()
	var pairing: bool = account_service != null and account_service.state in ["connecting", "pairing"]
	account_sign_in_button.visible = not connected and not pairing
	var locked: bool = account_service != null and account_service.state in ["restoring", "signing_out"]
	account_sign_in_button.disabled = account_service == null or locked
	account_reopen_button.visible = account_service != null and account_service.state == "pairing"
	account_cancel_button.visible = pairing
	for button in [account_use_models_button, account_console_button, account_sign_out_button]:
		button.visible = connected
	account_refresh_button.visible = connected or (account_service != null and account_service.state == "signed_out")
	account_refresh_button.disabled = account_service == null or locked
	_account_name_label.visible = connected
	_account_usage_label.visible = connected
	_account_code_label.visible = account_service != null and account_service.state == "pairing"
	_account_status_label.text = str(account_service.status) if account_service != null else "Account service is unavailable."
	if pairing:
		_account_code_label.text = "Pairing code: " + str(account_service.pairing_code)
	if connected:
		_account_name_label.text = str(account_service.account.get("display_name", ""))
		var allowance: Dictionary = account_service.account.get("allowance", {})
		_account_usage_label.text = "Plan: %s\nAvailable usage: %s\nReserved: %s" % [str(account_service.account.get("plan_name", "Free")), _account_money(int(allowance["available_units"])) if allowance.has("available_units") else "unavailable", _account_money(int(allowance["reserved_units"])) if allowance.has("reserved_units") else "unavailable"]
	var parent = get_parent()
	var controller = parent.get("agent_controller") if parent != null else null
	account_sign_out_button.disabled = locked or (controller != null and controller.is_busy())
	account_use_models_button.disabled = locked


func _account_money(units: int) -> String:
	var cents := units / 10000
	return "$%d.%02d" % [cents / 100, cents % 100]


func _on_account_sign_in() -> void:
	if account_service != null:
		account_service.begin_pairing()

func _on_account_reopen() -> void:
	if account_service != null:
		account_service.open_pairing_browser()

func _on_account_cancel() -> void:
	if account_service != null:
		account_service.cancel_pairing()

func _on_account_refresh() -> void:
	if account_service != null:
		account_service.refresh_account()

func _on_account_console() -> void:
	if account_service != null:
		account_service.open_console()

func _on_account_sign_out() -> void:
	if account_service != null and not account_sign_out_button.disabled:
		_cancel_agent_probe_for_change()
		account_service.sign_out()


func _on_use_cloud_models() -> void:
	if account_service == null or not account_service.connected():
		return
	_save_current_profile()
	_select_provider("orca_cloud")
	_show_section("provider")
	if not _selected_model.is_empty():
		Config.save_provider_config("orca_cloud", "", _selected_model, _selected_effort)
		settings_saved.emit("orca_cloud", _selected_model)


func _on_cloud_signed_in() -> void:
	var parent = get_parent()
	var controller = parent.get("agent_controller") if parent != null else null
	if controller != null and controller.is_busy():
		return # Never change the provider of an active turn.
	_on_use_cloud_models()
	_show_section("account")


func _on_account_changed() -> void:
	_render_account()
	if _current_provider == "orca_cloud" and account_service != null:
		var incoming: Array = account_service.models.duplicate(true)
		if incoming != _current_models:
			_cancel_agent_probe_for_change()
			_on_models_loaded("orca_cloud", incoming, false)


func _build_about_view() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "AboutScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.name = "AboutContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(10))
	scroll.add_child(content)

	var logo_center := CenterContainer.new()
	content.add_child(logo_center)
	var logo := TextureRect.new()
	logo.name = "AboutLogo"
	logo.texture = _about_logo_texture()
	logo.custom_minimum_size = UiMetrics.scaled_vector(Vector2(72, 72))
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo_center.add_child(logo)

	var product_name := Label.new()
	product_name.text = "ORCA"
	product_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	product_name.add_theme_font_size_override("font_size", _body_font_size + 6)
	content.add_child(product_name)
	about_version_label = Label.new()
	about_version_label.name = "AboutVersion"
	about_version_label.text = "Version " + _plugin_version()
	about_version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	about_version_label.add_theme_color_override("font_color", Color(0.58, 0.72, 0.82))
	content.add_child(about_version_label)

	var tagline := Label.new()
	tagline.text = "A safety-first AI development assistant for the Godot editor."
	tagline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tagline.add_theme_font_size_override("font_size", _body_font_size + 1)
	content.add_child(tagline)
	var overview := Label.new()
	overview.text = "Explore project context, prepare Godot-aware changes, and run bounded checks without leaving the editor."
	overview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	overview.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(overview)

	content.add_child(HSeparator.new())
	content.add_child(_about_heading("RESOURCES"))
	content.add_child(_about_link("AboutDocsLink", "Documentation", "Guides and getting started", "https://www.aiorca.dev/docs/"))
	content.add_child(_about_link("AboutWebsiteLink", "Orca website", "News and product updates", "https://www.aiorca.dev/"))
	content.add_child(_about_heading("COMMUNITY & DEVELOPMENT"))
	content.add_child(_about_link("AboutGitHubLink", "GitHub", "Source code and releases", "https://github.com/cold-atom/Orca"))
	content.add_child(_about_link("AboutIssuesLink", "Report an issue", "Bugs and troubleshooting", "https://github.com/cold-atom/Orca/issues"))
	content.add_child(_about_link("AboutDiscussionsLink", "Ideas & feature requests", "Discuss improvements with the community", "https://github.com/cold-atom/Orca/discussions"))
	content.add_child(HSeparator.new())
	content.add_child(_about_heading("REVIEW-FIRST"))
	var safety := Label.new()
	safety.text = "Plan mode is read-only. Work mode requires your approval before model-requested project changes are written."
	safety.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	safety.add_theme_color_override("font_color", Color(0.72, 0.75, 0.8))
	content.add_child(safety)

	content.add_child(_about_heading("COMPATIBILITY"))
	var compatibility := Label.new()
	compatibility.name = "AboutCompatibility"
	compatibility.text = "Godot " + SUPPORTED_GODOT_VERSION
	content.add_child(compatibility)

	content.add_child(_about_heading("SUPPORT"))
	var support_description := Label.new()
	support_description.name = "SupportReportDescription"
	support_description.text = "Copies a strict-allowlist report with Orca/Godot versions and coarse provider/request state. It excludes credentials, endpoint addresses, project data, conversations, model output, logs, and file changes."
	support_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	support_description.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(support_description)
	var copy_report_button := Button.new()
	copy_report_button.name = "CopySupportReport"
	copy_report_button.text = "Copy Privacy-Safe Diagnostic Report"
	copy_report_button.tooltip_text = copy_report_button.text
	copy_report_button.clip_text = true
	copy_report_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_report_button.pressed.connect(_on_copy_support_report_pressed)
	content.add_child(copy_report_button)
	support_report_status = Label.new()
	support_report_status.name = "SupportReportStatus"
	support_report_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	support_report_status.add_theme_color_override("font_color", Color(0.58, 0.72, 0.82))
	content.add_child(support_report_status)

	content.add_child(_about_heading("LICENSE"))
	var license := Label.new()
	license.name = "AboutLicense"
	license.text = "MIT License\nCopyright (c) 2026 Minghang Chamling"
	license.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	license.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(license)
	return scroll


func _about_link(node_name: String, title: String, description: String, url: String) -> PanelContainer:
	# The container measures the text and padding. A Button alone does not
	# include child-control minimum sizes, so a fixed-height row can overflow.
	var panel := PanelContainer.new()
	panel.name = node_name + "Row"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var button := Button.new()
	button.name = node_name
	button.tooltip_text = title + "\n" + description + "\n" + url + "\nOpens in your browser"
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.accessibility_name = title
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.12, 0.125, 0.135)
	normal.set_corner_radius_all(UiMetrics.scaled_int(6))
	normal.set_content_margin_all(0)
	panel.add_theme_stylebox_override("panel", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.17, 0.18, 0.195)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = Color(0.5, 0.6, 0.68)
	focus.set_border_width_all(UiMetrics.scaled_int(1))
	focus.set_corner_radius_all(UiMetrics.scaled_int(6))
	button.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("focus", focus)
	panel.add_child(button)
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(margin)
	margin.add_theme_constant_override("margin_left", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_right", UiMetrics.scaled_int(10))
	margin.add_theme_constant_override("margin_top", UiMetrics.scaled_int(6))
	margin.add_theme_constant_override("margin_bottom", UiMetrics.scaled_int(6))
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", UiMetrics.scaled_int(2))
	row.add_child(text)
	var title_label := Label.new()
	title_label.text = title
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.add_theme_font_size_override("font_size", _body_font_size)
	title_label.add_theme_color_override("font_color", Color(0.82, 0.87, 0.91))
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.clip_text = true
	text.add_child(title_label)
	var subtitle := Label.new()
	subtitle.text = description
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle.add_theme_font_size_override("font_size", _meta_font_size)
	subtitle.add_theme_color_override("font_color", Color(0.58, 0.62, 0.68))
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(subtitle)
	var arrow := Label.new()
	arrow.text = "↗"
	arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.add_theme_font_size_override("font_size", _body_font_size)
	arrow.add_theme_color_override("font_color", Color(0.58, 0.62, 0.68))
	row.add_child(arrow)
	button.pressed.connect(_on_about_link_pressed.bind(url))
	return panel


func _on_about_link_pressed(url: String) -> void:
	OS.shell_open(url)


func _about_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", _meta_font_size)
	label.add_theme_color_override("font_color", Color(0.48, 0.68, 0.8))
	return label


func _plugin_version() -> String:
	var plugin_config := ConfigFile.new()
	if plugin_config.load(PLUGIN_CONFIG_PATH) != OK:
		return "Unknown"
	return str(plugin_config.get_value("plugin", "version", "Unknown")).strip_edges()


func diagnostic_report_text() -> String:
	var profile := SupportDiagnosticReport.current_profile(Config.get_active_provider_config())
	return SupportDiagnosticReport.serialize(SupportDiagnosticReport.build(_plugin_version(), profile, _support_request_metadata))


func _on_copy_support_report_pressed() -> void:
	DisplayServer.clipboard_set(diagnostic_report_text())
	support_report_status.text = "Copied diagnostic report."


func _about_logo_texture() -> Texture2D:
	var loaded := load(ABOUT_LOGO_PATH)
	if loaded is Texture2D:
		return loaded
	var fallback_size := UiMetrics.scaled_int(72)
	var image := Image.create(fallback_size, fallback_size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.62, 0.9, 1.0))
	return ImageTexture.create_from_image(image)


func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", _body_font_size)
	return label


func _focus_model_configuration() -> void:
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	var target: Control = model_search if bool(definition.get("model_discovery", _current_provider != "custom")) else custom_model_input
	target.grab_focus()
	settings_scroll.ensure_control_visible(target)


func _on_image_support_toggled(enabled: bool) -> void:
	_save_current_profile()
	var config := Config.get_provider_config(_current_provider)
	Config.set_image_input_override(_current_provider, ImageCapability.binding(config), enabled)
	_sync_image_support()


func _sync_image_support() -> void:
	if image_support_toggle == null or _current_provider.is_empty():
		return
	var config := Config.get_provider_config(_current_provider)
	config["model"] = _selected_model
	if custom_url_input.visible:
		config["base_url"] = custom_url_input.text.strip_edges()
	config["api_key"] = api_key_input.text.strip_edges()
	var record = config.get("image_input_override", {})
	var enabled: bool = typeof(record) == TYPE_DICTIONARY and record.get("binding") == ImageCapability.binding(config) and record.get("enabled") == true
	image_support_toggle.set_pressed_no_signal(enabled)
	config.erase("image_input_override")
	image_support_toggle.visible = ImageCapability.resolve(config) == "unknown" or enabled


func _populate_providers() -> void:
	provider_selector.clear()
	for definition in ProviderRegistry.definitions():
		provider_selector.add_item(str(definition["name"]))
		provider_selector.set_item_metadata(provider_selector.item_count - 1, definition["id"])


func _select_provider(provider_id: String) -> void:
	for index in range(provider_selector.item_count):
		if str(provider_selector.get_item_metadata(index)) == provider_id:
			provider_selector.select(index)
			_load_provider(provider_id)
			return
	provider_selector.select(0)
	_load_provider(str(provider_selector.get_item_metadata(0)))


func _on_provider_selected(index: int) -> void:
	_cancel_agent_probe_for_change()
	_save_current_profile()
	_load_provider(str(provider_selector.get_item_metadata(index)))


func _load_provider(provider_id: String) -> void:
	_cancel_agent_probe_for_change()
	_loading_provider = true
	_key_timer.stop()
	_current_provider = provider_id
	_current_models.clear()
	_model_service.cancel()
	model_selector.clear()
	model_selector.disabled = false
	refresh_button.disabled = false
	model_search.text = ""
	metadata_label.text = ""
	var provider = ProviderRegistry.get_provider(provider_id)
	var definition: Dictionary = provider.definition()
	var config := Config.get_provider_config(provider_id)
	var managed := bool(definition.get("managed_auth", false))
	api_key_label.visible = not managed
	api_key_input.get_parent().visible = not managed
	_key_help.visible = not managed
	api_key_label.text = str(definition.get("key_label", "API Key"))
	api_key_input.text = str(config.get("api_key", ""))
	key_link.visible = not str(definition.get("key_url", "")).is_empty()
	custom_url_label.visible = bool(definition.get("custom_url", false))
	custom_url_input.visible = custom_url_label.visible
	endpoint_status_label.visible = custom_url_label.visible
	custom_url_input.text = str(config.get("base_url", definition.get("base_url", "")))
	_update_endpoint_status()
	var supports_discovery := bool(definition.get("model_discovery", provider_id != "custom"))
	var supports_manual_model := bool(definition.get("manual_model", provider_id == "custom"))
	var auth_optional := bool(definition.get("auth_optional", false))
	model_search.visible = supports_discovery
	model_selector.visible = supports_discovery
	refresh_button.visible = supports_discovery
	custom_model_input.visible = supports_manual_model
	custom_model_input.text = str(config.get("model", ""))
	_selected_model = str(config.get("model", definition.get("default_model", "")))
	_selected_effort = str(config.get("reasoning_effort", "default"))
	_selected_api_mode = str(config.get("api_mode", definition.get("default_api_mode", "chat_completions")))
	_continuation_style = str(config.get("continuation_style", "standard"))
	api_mode_selector.select(0 if _selected_api_mode == "responses" else 1)
	continuation_selector.select(1 if _continuation_style == "deepseek" else 0)
	custom_model_input.placeholder_text = "Exact deployment name" if provider_id == "azure" else "Model ID"
	_sync_api_controls()
	_set_efforts(PackedStringArray(), _selected_effort)
	metadata_label.text = ""
	api_key_input.placeholder_text = "Optional for local servers" if auth_optional else "Enter API key"
	status_label.text = "Select Refresh to load models from this endpoint." if bool(definition.get("local", false)) else ("Loading models..." if not api_key_input.text.is_empty() else "Enter an API key to load models.")
	if not supports_discovery:
		status_label.text = "Enter the exact deployment name and run Test & Enable Agent tools." if provider_id == "azure" else "Enter a Model ID and run Test & Enable Agent tools."
	if supports_discovery and not bool(definition.get("local", false)) and not api_key_input.text.is_empty():
		_refresh_models()
	_loading_provider = false
	if managed:
		status_label.text = "Connect in Account to load Orca models."
		_on_account_changed()
	_sync_agent_compatibility()
	_sync_image_support()


func _on_api_key_changed(_text: String) -> void:
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	if _loading_provider:
		return
	_cancel_agent_probe_for_change()
	if not bool(definition.get("model_discovery", _current_provider != "custom")):
		return
	_model_service.cancel()
	_current_models.clear()
	model_selector.clear()
	model_selector.disabled = false
	refresh_button.disabled = false
	metadata_label.text = ""
	var auth_optional := bool(definition.get("auth_optional", false))
	status_label.text = "Waiting to load models..." if auth_optional or not api_key_input.text.is_empty() else "Enter an API key to load models."
	if not bool(definition.get("local", false)) and (auth_optional or not api_key_input.text.is_empty()):
		_key_timer.start()


func _on_custom_url_changed(_text: String) -> void:
	if _loading_provider:
		return
	_update_endpoint_status()
	_cancel_agent_probe_for_change()
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	if bool(definition.get("model_discovery", false)):
		_model_service.cancel()
		_current_models.clear()
		model_selector.clear()
		model_selector.disabled = false
		refresh_button.disabled = false
		metadata_label.text = ""
		status_label.text = "Endpoint changed. Select Refresh to contact it."
	_sync_image_support()
	_sync_agent_compatibility()


func _on_manual_model_changed(text: String) -> void:
	if not _loading_provider:
		_selected_model = text.strip_edges()
		_current_models.clear()
		model_selector.clear()
		metadata_label.text = ""
		_set_efforts(PackedStringArray(), _selected_effort)
		var discovery := bool(ProviderRegistry.get_provider(_current_provider).definition().get("model_discovery", _current_provider != "custom"))
		status_label.text = "Using a manual Model ID. Select Refresh to restore discovered models." if discovery else "Using an exact deployment name. Run Test & Enable Agent tools." if _current_provider == "azure" else "Using a manual Model ID. Run Test & Enable Agent tools."
		_cancel_agent_probe_for_change()
		_sync_agent_compatibility()
		_sync_image_support()


func _refresh_models() -> void:
	if _current_provider == "orca_cloud":
		if account_service != null:
			account_service.refresh_account()
		return
	var provider = ProviderRegistry.get_provider(_current_provider)
	var definition: Dictionary = provider.definition()
	if not bool(definition.get("model_discovery", _current_provider != "custom")):
		return
	if bool(definition.get("custom_url", false)):
		var inspected := EndpointPolicy.inspect_base_url(custom_url_input.text)
		if not inspected.get("success", false):
			status_label.text = str(inspected.get("error", "Invalid endpoint."))
			return
		if inspected.get("requires_confirmation", false) and Config.get_confirmed_origin(_current_provider) != str(inspected.get("origin", "")):
			_request_endpoint_trust("refresh", inspected)
			return
		_set_normalized_url(str(inspected["base_url"]))
	status_label.text = "Loading models..."
	model_selector.disabled = true
	refresh_button.disabled = true
	_model_service.fetch_models(_current_provider, {
		"api_key": api_key_input.text.strip_edges(),
		"base_url": custom_url_input.text.strip_edges() if bool(definition.get("custom_url", false)) else definition.get("base_url", ""),
		"confirmed_origin": Config.get_confirmed_origin(_current_provider)
	})


func _on_models_loaded(provider_id: String, models: Array, from_cache: bool) -> void:
	if provider_id != _current_provider:
		return
	var selected_found := false
	for model in models:
		if str(model.get("id", "")) == _selected_model:
			selected_found = provider_id != "orca_cloud" or (model.get("allowed") == true and model.get("availability") == "available")
			break
	if provider_id == "orca_cloud" and not selected_found:
		_selected_model = ""
		for preference in ["recommended", "fast", "advanced", ""]:
			for record in models:
				if record.get("allowed") == true and record.get("availability") == "available" and (preference.is_empty() or record.get("recommendation") == preference):
					_selected_model = str(record.get("id", ""))
					break
			if not _selected_model.is_empty():
				break
	if provider_id != "orca_cloud" and not selected_found and not _selected_model.is_empty():
		models.push_front({
			"id": _selected_model,
			"name": _selected_model + " (current)",
			"context_window": 0,
			"input_per_million": -1.0,
			"output_per_million": -1.0,
			"efforts": PackedStringArray(),
			"default_effort": ""
		})
	_current_models.assign(models)
	model_selector.disabled = false
	refresh_button.disabled = false
	var local_note := " Known embedding models are hidden; enter a Model ID manually to override discovery." if bool(ProviderRegistry.get_provider(provider_id).definition().get("local", false)) else ""
	status_label.text = "Loaded %d models%s.%s" % [models.size(), " from cache" if from_cache else "", local_note]
	_populate_models(model_search.text)


func _on_models_failed(provider_id: String, message: String) -> void:
	if provider_id != _current_provider:
		return
	model_selector.disabled = false
	refresh_button.disabled = false
	status_label.text = message


func _on_model_search_changed(query: String) -> void:
	_populate_models(query)


func _populate_models(query: String) -> void:
	model_selector.clear()
	var normalized_query := query.strip_edges().to_lower()
	var selected_index := -1
	for model in _current_models:
		var searchable := (str(model.get("name", "")) + " " + str(model.get("id", ""))).to_lower()
		if not normalized_query.is_empty() and normalized_query not in searchable:
			continue
		model_selector.add_item(str(model.get("name", model.get("id", ""))) + (" — subscription required" if _current_provider == "orca_cloud" and not model.get("allowed", false) else ""))
		var index := model_selector.item_count - 1
		model_selector.set_item_metadata(index, model.get("id", ""))
		if _current_provider == "orca_cloud":
			model_selector.set_item_disabled(index, not model.get("allowed", false) or model.get("availability") != "available")
		if str(model.get("id", "")) == _selected_model:
			selected_index = index
	if model_selector.item_count == 0:
		metadata_label.text = "No matching models."
		return
	model_selector.select(selected_index if selected_index >= 0 else 0)
	_on_model_selected(model_selector.selected)


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= model_selector.item_count:
		return
	_selected_model = str(model_selector.get_item_metadata(index))
	if custom_model_input.visible:
		var was_loading := _loading_provider
		_loading_provider = true
		custom_model_input.text = _selected_model
		_loading_provider = was_loading
	var model := _find_model(_selected_model)
	_set_efforts(model.get("efforts", PackedStringArray()), _selected_effort)
	metadata_label.text = _format_model_metadata(model)
	if not _loading_provider:
		_cancel_agent_probe_for_change()
		_sync_agent_compatibility()


func _set_efforts(efforts, selected_effort: String) -> void:
	if _current_provider == "orca_cloud":
		efforts = PackedStringArray()
		selected_effort = "default" # The managed profile supplies its tested default.
	if _current_provider in ["azure", "custom"]:
		efforts = PackedStringArray(["none", "minimal", "low", "medium", "high", "xhigh", "max"])
	effort_selector.clear()
	effort_selector.add_item("Provider default")
	effort_selector.set_item_metadata(0, "default")
	if typeof(efforts) == TYPE_PACKED_STRING_ARRAY or typeof(efforts) == TYPE_ARRAY:
		for effort in efforts:
			effort_selector.add_item(str(effort).capitalize())
			effort_selector.set_item_metadata(effort_selector.item_count - 1, str(effort))
	for index in range(effort_selector.item_count):
		if str(effort_selector.get_item_metadata(index)) == selected_effort:
			effort_selector.select(index)
			break
	_selected_effort = str(effort_selector.get_item_metadata(effort_selector.selected))
	var has_efforts := effort_selector.item_count > 1
	effort_label.visible = has_efforts
	effort_selector.visible = has_efforts
	effort_help.visible = has_efforts
	effort_help.text = "Supported levels depend on your deployment. Provider default does not disable reasoning. For GPT reasoning with tools, prefer Responses; use None on Chat only if the deployment supports it." if _current_provider in ["azure", "custom"] else "Higher effort can improve difficult planning and debugging, but may use more tokens."


func _sync_api_controls() -> void:
	var azure := _current_provider == "azure"
	for control in [api_mode_label, api_mode_selector, api_mode_help]:
		control.visible = azure
	for control in [continuation_label, continuation_selector]:
		control.visible = azure
	api_mode_help.text = "Use the resource's /openai/v1 base URL and exact deployment name. Responses supports reasoning with Orca function tools; requests use store=false. Select DeepSeek reasoning continuation for DeepSeek deployments." if _selected_api_mode == "responses" else "For GPT reasoning with tools, prefer Responses. Chat without reasoning requires a deployment that supports None. Select DeepSeek reasoning continuation for DeepSeek deployments."


func _on_api_mode_selected(index: int) -> void:
	_selected_api_mode = str(api_mode_selector.get_item_metadata(index))
	_sync_api_controls()
	if not _loading_provider:
		_cancel_agent_probe_for_change()
		_sync_agent_compatibility()


func _on_continuation_selected(index: int) -> void:
	_continuation_style = str(continuation_selector.get_item_metadata(index))
	if not _loading_provider:
		_cancel_agent_probe_for_change()
		_sync_agent_compatibility()


func _on_effort_selected(index: int) -> void:
	if index >= 0:
		_selected_effort = str(effort_selector.get_item_metadata(index))
		if not _loading_provider:
			_cancel_agent_probe_for_change()
			_sync_agent_compatibility()


func _find_model(model_id: String) -> Dictionary:
	for model in _current_models:
		if str(model.get("id", "")) == model_id:
			return model
	return {}


func _format_model_metadata(model: Dictionary) -> String:
	if model.is_empty():
		return ""
	var parts := PackedStringArray()
	var context := int(model.get("context_window", 0))
	if context > 0:
		parts.append("Context: " + _format_tokens(context))
	var input_price := float(model.get("input_per_million", -1.0))
	var output_price := float(model.get("output_per_million", -1.0))
	if input_price >= 0.0:
		parts.append("Input: $%.2f/M" % input_price)
	if output_price >= 0.0:
		parts.append("Output: $%.2f/M" % output_price)
	return "   ".join(parts)


func _format_tokens(tokens: int) -> String:
	return "%.1fM" % (tokens / 1000000.0) if tokens >= 1000000 else "%.0fk" % (tokens / 1000.0)


func _on_show_key_toggled(pressed: bool) -> void:
	api_key_input.secret = not pressed
	show_key_button.text = "Hide" if pressed else "Show"


func _on_key_link_pressed() -> void:
	var url := str(ProviderRegistry.get_provider(_current_provider).definition().get("key_url", ""))
	if not url.is_empty():
		OS.shell_open(url)


func _on_done_pressed() -> void:
	if account_scroll != null and account_scroll.visible:
		if account_service != null and account_service.state in ["pairing", "connecting"]:
			account_service.cancel_pairing()
		done_requested.emit()
		return
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	if bool(definition.get("custom_url", false)):
		var inspected := EndpointPolicy.inspect_base_url(custom_url_input.text)
		if not inspected.get("success", false):
			status_label.text = str(inspected.get("error", "Invalid endpoint."))
			return
		if inspected.get("requires_confirmation", false) and Config.get_confirmed_origin(_current_provider) != str(inspected.get("origin", "")):
			_request_endpoint_trust("done", inspected)
			return
		_set_normalized_url(str(inspected["base_url"]))
	var model := _selected_model
	var effort := "default"
	if effort_selector.visible and effort_selector.selected >= 0:
		effort = str(effort_selector.get_item_metadata(effort_selector.selected))
	_selected_effort = effort
	var saved := Config.save_provider_config(
		_current_provider,
		api_key_input.text.strip_edges(),
		model,
		effort,
		custom_url_input.text.strip_edges(),
		_selected_api_mode,
		_continuation_style
	)
	if not saved:
		status_label.text = "Could not save this provider profile. Check the endpoint and API settings."
		return
	settings_saved.emit(_current_provider, model)
	done_requested.emit()


func _save_current_profile() -> void:
	if _current_provider.is_empty():
		return
	var model := _selected_model
	Config.save_provider_profile(
		_current_provider,
		api_key_input.text.strip_edges(),
		model,
		_selected_effort,
		custom_url_input.text.strip_edges(),
		_selected_api_mode,
		_continuation_style
	)
	_sync_image_support()


func _update_endpoint_status() -> void:
	if endpoint_status_label == null or not endpoint_status_label.visible:
		return
	var inspected := EndpointPolicy.inspect_base_url(custom_url_input.text)
	if not inspected.get("success", false):
		endpoint_status_label.text = "Invalid endpoint: " + str(inspected.get("error", "Unknown error"))
		return
	var scope := str(inspected.get("scope", "remote")).capitalize()
	if inspected.get("is_loopback", false):
		endpoint_status_label.text = "Loopback endpoint. Requests stay addressed to this machine."
		return
	var warning := " HTTP is unencrypted." if inspected.get("uses_plaintext", false) else ""
	var trusted := Config.get_confirmed_origin(_current_provider) == str(inspected.get("origin", ""))
	endpoint_status_label.text = "%s endpoint%s %s" % [scope, warning, "Trusted for this exact origin." if trusted else "Confirmation is required before sending data."]


func _request_endpoint_trust(action: String, inspected: Dictionary) -> void:
	_pending_trust_action = action
	_pending_trust_origin = str(inspected.get("origin", ""))
	_pending_trust_provider = _current_provider
	var plaintext := " This connection is HTTP and is not encrypted." if inspected.get("uses_plaintext", false) else ""
	_trust_dialog.dialog_text = "Allow Orca to send this profile's credentials, prompts, and project context to %s? This confirmation is stored for this exact scheme, host, and port.%s" % [_pending_trust_origin, plaintext]
	_trust_dialog.popup_centered()


func _on_endpoint_trust_confirmed() -> void:
	if _pending_trust_provider != _current_provider:
		_clear_pending_trust()
		return
	var inspected := EndpointPolicy.inspect_base_url(custom_url_input.text)
	if not inspected.get("success", false) or str(inspected.get("origin", "")) != _pending_trust_origin:
		status_label.text = "Endpoint changed before confirmation. Review it again."
		_clear_pending_trust()
		return
	var action := _pending_trust_action
	Config.set_confirmed_origin(_current_provider, _pending_trust_origin)
	_set_normalized_url(str(inspected["base_url"]))
	_clear_pending_trust()
	_update_endpoint_status()
	if action == "refresh":
		_refresh_models()
	elif action == "done":
		_on_done_pressed()
	elif action == "probe":
		_start_agent_probe()


func _on_endpoint_trust_cancelled() -> void:
	if _pending_trust_action == "probe":
		_agent_enable_intent = ""
	_clear_pending_trust()


func _clear_pending_trust() -> void:
	_pending_trust_action = ""
	_pending_trust_origin = ""
	_pending_trust_provider = ""


func _set_normalized_url(value: String) -> void:
	_loading_provider = true
	custom_url_input.text = value
	_loading_provider = false


func _on_agent_probe_pressed() -> void:
	if _current_provider == "orca_cloud":
		return
	if _agent_probe != null and _agent_probe.is_running():
		return
	var config := _current_form_config()
	_agent_enable_intent = _agent_profile_key(config)
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	if bool(definition.get("custom_url", false)):
		var inspected := EndpointPolicy.inspect_base_url(str(config.get("base_url", "")))
		if not inspected.get("success", false):
			_agent_enable_intent = ""
			agent_status_label.text = str(inspected.get("error", "Invalid endpoint."))
			return
		if inspected.get("requires_confirmation", false) and Config.get_confirmed_origin(_current_provider) != str(inspected.get("origin", "")):
			_request_endpoint_trust("probe", inspected)
			return
	_start_agent_probe()


func _start_agent_probe() -> void:
	var config := _current_form_config()
	if _agent_enable_intent.is_empty() or _agent_enable_intent != _agent_profile_key(config):
		_agent_enable_intent = ""
		_sync_agent_compatibility()
		agent_status_label.text = "Profile changed. Run Test & Enable Agent tools again."
		return
	Config.clear_agent_compatibility(_current_provider)
	agent_enable_toggle.set_pressed_no_signal(false)
	agent_enable_toggle.disabled = true
	agent_probe_button.disabled = true
	done_button.disabled = true
	if not _agent_probe.start_probe(config):
		_agent_enable_intent = ""
		agent_probe_button.disabled = false
		done_button.disabled = false


func _on_probe_step_changed(step: int) -> void:
	agent_status_label.text = "Testing Agent compatibility, step %d of 2..." % step


func _on_probe_passed(binding: Dictionary) -> void:
	if _agent_enable_intent.is_empty():
		return
	var intent := _agent_enable_intent
	_agent_enable_intent = "" # Claim the user action once before persistence/reentry.
	var config := _current_form_config()
	var current_binding: Dictionary = AgentCompatibilityProbe.create_binding(config).get("binding", {})
	var error := ""
	if intent != _agent_profile_key(config) or not AgentCompatibilityProbe.record_matches_binding(binding, current_binding):
		error = "Profile changed during the check. Run Test & Enable Agent tools again."
	elif not Config.record_agent_probe_pass(binding) or not Config.set_agent_enabled(_current_provider, config, true):
		error = "Compatibility passed, but Agent tools could not be enabled. Run the check again."
	_sync_agent_compatibility()
	if not error.is_empty():
		agent_status_label.text = error
	done_button.disabled = false


func _on_probe_failed(_binding: Dictionary, message: String) -> void:
	_agent_enable_intent = ""
	agent_status_label.text = "Compatibility check failed: " + message
	agent_probe_button.disabled = false
	agent_enable_toggle.disabled = true
	agent_enable_toggle.set_pressed_no_signal(false)
	done_button.disabled = false


func _on_probe_cancelled() -> void:
	_agent_enable_intent = ""
	_sync_agent_compatibility()
	done_button.disabled = false


func _on_agent_enable_toggled(enabled: bool) -> void:
	if _loading_provider:
		return
	if not Config.set_agent_enabled(_current_provider, _current_form_config(), enabled):
		agent_enable_toggle.set_pressed_no_signal(false)
	_sync_agent_compatibility()


func _sync_agent_compatibility() -> void:
	if agent_status_label == null:
		return
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	var required := bool(definition.get("custom_url", false))
	for control in [agent_heading_label, agent_status_label, agent_probe_button, agent_enable_toggle, agent_warning_label]:
		control.visible = required
	if not required:
		return
	var status := Config.agent_compatibility_status(_current_provider, _current_form_config())
	var passed := bool(status.get("passed", false))
	var enabled := bool(status.get("enabled", false))
	agent_probe_button.disabled = _agent_probe != null and _agent_probe.is_running()
	if _current_provider == "orca_cloud" and (account_service == null or not account_service.connected() or not account_service.model_record(_selected_model).get("allowed", false) or not account_service.model_record(_selected_model).get("tools", false)):
		agent_probe_button.disabled = true
	agent_enable_toggle.disabled = not passed or agent_probe_button.disabled
	agent_enable_toggle.set_pressed_no_signal(enabled)
	if not agent_probe_button.disabled:
		agent_status_label.text = ("Agent tools enabled for this exact profile." if enabled else "Compatibility passed. Agent tools are off.") if passed else str(status.get("reason", "Run the compatibility probe."))


func _cancel_agent_probe_for_change() -> void:
	_agent_enable_intent = ""
	if _agent_probe != null and _agent_probe.is_running():
		_agent_probe.cancel()


func _agent_profile_key(config: Dictionary) -> String:
	var endpoint := EndpointPolicy.inspect_base_url(str(config.get("base_url", "")))
	if not endpoint.get("success", false):
		return ""
	# Memory-only intent, including credentials, can survive endpoint confirmation
	# but cannot authorize a changed model, API, effort, origin, or credential.
	return JSON.stringify([config.get("provider"), endpoint["base_url"], config.get("model"), config.get("reasoning_effort", "default"), config.get("api_mode", "chat_completions"), config.get("continuation_style", "standard"), str(config.get("hosted_identity", "")) if config.get("provider") == "orca_cloud" else str(config.get("api_key", "")).sha256_text(), config.get("capability_version", "")]).sha256_text()


func _current_form_config() -> Dictionary:
	if _current_provider == "orca_cloud" and account_service != null:
		return account_service.profile_config(_selected_model, _selected_effort)
	var definition: Dictionary = ProviderRegistry.get_provider(_current_provider).definition()
	return {
		"provider": _current_provider,
		"api_key": api_key_input.text.strip_edges(),
		"base_url": custom_url_input.text.strip_edges() if bool(definition.get("custom_url", false)) else definition.get("base_url", ""),
		"model": _selected_model,
		"reasoning_effort": _selected_effort,
		"api_mode": _selected_api_mode,
		"continuation_style": _continuation_style,
		"confirmed_origin": Config.get_confirmed_origin(_current_provider),
		"agent_compatibility": Config.get_agent_compatibility(_current_provider)
	}
