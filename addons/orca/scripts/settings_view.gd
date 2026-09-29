@tool
extends PanelContainer

signal done_requested
signal settings_saved(provider_id: String, model: String)

const Config = preload("res://addons/orca/scripts/config.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const ProviderModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
const PLUGIN_CONFIG_PATH := "res://addons/orca/plugin.cfg"
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
var custom_model_input: LineEdit
var effort_label: Label
var effort_selector: OptionButton
var effort_help: Label
var metadata_label: Label
var status_label: Label
var done_button: Button
var refresh_button: Button
var settings_scroll: ScrollContainer
var about_scroll: ScrollContainer
var provider_tab_button: Button
var about_tab_button: Button
var about_version_label: Label
var _model_service
var _key_timer: Timer
var _current_provider := ""
var _current_models: Array[Dictionary] = []
var _selected_model := ""
var _selected_effort := "default"
var _loading_provider := false
var _body_font_size := 13
var _meta_font_size := 11


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
	_model_service = ProviderModelService.new()
	add_child(_model_service)
	_model_service.models_loaded.connect(_on_models_loaded)
	_model_service.models_failed.connect(_on_models_failed)
	_key_timer = Timer.new()
	_key_timer.one_shot = true
	_key_timer.wait_time = 0.8
	_key_timer.timeout.connect(_refresh_models)
	add_child(_key_timer)
	_populate_providers()


func open() -> void:
	show()
	_show_section("provider")
	_select_provider(Config.get_provider())


func open_model_configuration() -> void:
	open()
	call_deferred("_focus_model_configuration")


func _build_ui() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.09, 0.095, 0.105, 1.0)
	add_theme_stylebox_override("panel", background)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
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
	done_button.custom_minimum_size = Vector2(72, 34)
	done_button.pressed.connect(_on_done_pressed)
	header.add_child(done_button)
	root.add_child(HSeparator.new())

	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	root.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	tab_group.allow_unpress = false
	provider_tab_button = _section_tab("Provider", tab_group)
	provider_tab_button.name = "ProviderTab"
	provider_tab_button.pressed.connect(_show_section.bind("provider"))
	tab_row.add_child(provider_tab_button)
	about_tab_button = _section_tab("About", tab_group)
	about_tab_button.name = "AboutTab"
	about_tab_button.pressed.connect(_show_section.bind("about"))
	tab_row.add_child(about_tab_button)

	settings_scroll = ScrollContainer.new()
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(settings_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 7)
	settings_scroll.add_child(content)

	var section := Label.new()
	section.text = "API CONFIGURATION"
	section.add_theme_font_size_override("font_size", _meta_font_size)
	section.add_theme_color_override("font_color", Color(0.66, 0.7, 0.76))
	content.add_child(section)
	content.add_child(_field_label("API Provider"))
	provider_selector = OptionButton.new()
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
	key_help.text = "Stored in Godot Editor Settings and used only for requests to the selected provider."
	key_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	key_help.add_theme_color_override("font_color", Color(0.58, 0.61, 0.67))
	content.add_child(key_help)

	custom_url_label = _field_label("Base URL")
	content.add_child(custom_url_label)
	custom_url_input = LineEdit.new()
	custom_url_input.text_changed.connect(_on_custom_url_changed)
	content.add_child(custom_url_input)

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
	content.add_child(custom_model_input)

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

	about_scroll = _build_about_view()
	about_scroll.hide()
	root.add_child(about_scroll)
	_show_section("provider")


func _section_tab(text: String, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, 34)
	return button


func _show_section(section: String) -> void:
	var show_about := section == "about"
	if settings_scroll != null:
		settings_scroll.visible = not show_about
	if about_scroll != null:
		about_scroll.visible = show_about
	if provider_tab_button != null:
		provider_tab_button.set_pressed_no_signal(not show_about)
	if about_tab_button != null:
		about_tab_button.set_pressed_no_signal(show_about)


func _build_about_view() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "AboutScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.name = "AboutContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	var logo_center := CenterContainer.new()
	content.add_child(logo_center)
	var logo := TextureRect.new()
	logo.name = "AboutLogo"
	logo.texture = load("res://addons/orca/assets/orca.svg")
	logo.custom_minimum_size = Vector2(72, 72)
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

	content.add_child(_about_heading("LICENSE"))
	var license := Label.new()
	license.name = "AboutLicense"
	license.text = "MIT License\nCopyright (c) 2026 Minghang Chamling"
	license.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	license.add_theme_color_override("font_color", Color(0.66, 0.69, 0.74))
	content.add_child(license)
	return scroll


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


func _field_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", _body_font_size)
	return label


func _focus_model_configuration() -> void:
	var target: Control = custom_model_input if _current_provider == "custom" else model_search
	target.grab_focus()
	settings_scroll.ensure_control_visible(target)


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
	_save_current_profile()
	_load_provider(str(provider_selector.get_item_metadata(index)))


func _load_provider(provider_id: String) -> void:
	_loading_provider = true
	_key_timer.stop()
	_current_provider = provider_id
	_current_models.clear()
	model_search.text = ""
	var provider = ProviderRegistry.get_provider(provider_id)
	var definition: Dictionary = provider.definition()
	var config := Config.get_provider_config(provider_id)
	api_key_label.text = str(definition.get("key_label", "API Key"))
	api_key_input.text = str(config.get("api_key", ""))
	key_link.visible = not str(definition.get("key_url", "")).is_empty()
	custom_url_label.visible = bool(definition.get("custom_url", false))
	custom_url_input.visible = custom_url_label.visible
	custom_url_input.text = str(config.get("base_url", definition.get("base_url", "")))
	var is_custom := provider_id == "custom"
	model_search.visible = not is_custom
	model_selector.visible = not is_custom
	refresh_button.visible = not is_custom
	custom_model_input.visible = is_custom
	custom_model_input.text = str(config.get("model", ""))
	_selected_model = str(config.get("model", definition.get("default_model", "")))
	_selected_effort = str(config.get("reasoning_effort", "default"))
	_set_efforts(PackedStringArray(), _selected_effort)
	metadata_label.text = ""
	status_label.text = "Enter an API key to load models." if api_key_input.text.is_empty() else "Loading models..."
	if not is_custom and not api_key_input.text.is_empty():
		_refresh_models()
	_loading_provider = false


func _on_api_key_changed(_text: String) -> void:
	if _loading_provider or _current_provider == "custom":
		return
	_model_service.cancel()
	_current_models.clear()
	model_selector.clear()
	metadata_label.text = ""
	status_label.text = "Enter an API key to load models." if api_key_input.text.is_empty() else "Waiting to load models..."
	_key_timer.start()


func _on_custom_url_changed(_text: String) -> void:
	pass


func _refresh_models() -> void:
	if _current_provider == "custom":
		return
	status_label.text = "Loading models..."
	model_selector.disabled = true
	refresh_button.disabled = true
	var provider = ProviderRegistry.get_provider(_current_provider)
	_model_service.fetch_models(_current_provider, {
		"api_key": api_key_input.text.strip_edges(),
		"base_url": provider.definition().get("base_url", "")
	})


func _on_models_loaded(provider_id: String, models: Array, from_cache: bool) -> void:
	if provider_id != _current_provider:
		return
	var selected_found := false
	for model in models:
		if str(model.get("id", "")) == _selected_model:
			selected_found = true
			break
	if not selected_found and not _selected_model.is_empty():
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
	status_label.text = "Loaded %d models%s." % [models.size(), " from cache" if from_cache else ""]
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
		model_selector.add_item(str(model.get("name", model.get("id", ""))))
		var index := model_selector.item_count - 1
		model_selector.set_item_metadata(index, model.get("id", ""))
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
	var model := _find_model(_selected_model)
	_set_efforts(model.get("efforts", PackedStringArray()), _selected_effort)
	metadata_label.text = _format_model_metadata(model)


func _set_efforts(efforts, selected_effort: String) -> void:
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


func _on_effort_selected(index: int) -> void:
	if index >= 0:
		_selected_effort = str(effort_selector.get_item_metadata(index))


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
	var model := custom_model_input.text.strip_edges() if _current_provider == "custom" else _selected_model
	var effort := "default"
	if effort_selector.visible and effort_selector.selected >= 0:
		effort = str(effort_selector.get_item_metadata(effort_selector.selected))
	_selected_effort = effort
	Config.save_provider_config(
		_current_provider,
		api_key_input.text.strip_edges(),
		model,
		effort,
		custom_url_input.text.strip_edges()
	)
	settings_saved.emit(_current_provider, model)
	done_requested.emit()


func _save_current_profile() -> void:
	if _current_provider.is_empty():
		return
	var model := custom_model_input.text.strip_edges() if _current_provider == "custom" else _selected_model
	Config.save_provider_profile(
		_current_provider,
		api_key_input.text.strip_edges(),
		model,
		_selected_effort,
		custom_url_input.text.strip_edges()
	)
