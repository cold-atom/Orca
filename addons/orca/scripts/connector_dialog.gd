@tool
extends ConfirmationDialog

signal save_requested(config: Dictionary, expected: Dictionary)
const Config = preload("res://addons/orca/scripts/mcp_config.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var name_input: LineEdit
var command_input: LineEdit
var arguments_input: TextEdit
var profile_selector: OptionButton
var _error: Label
var _browse: FileDialog
var _advanced: VBoxContainer
var _body: VBoxContainer
var _blender_help: VBoxContainer
var _purpose: Label
var _scroll: ScrollContainer
var _id := ""
var _expected := {}
var _locked := false
var _loading := false


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	title = "Configure connector"
	ok_button_text = "Save"
	confirmed.connect(_confirmed)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Metrics.scaled_vector(Vector2(220, 280))
	add_child(_scroll)
	var body := VBoxContainer.new()
	_body = body
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", Metrics.scaled_int(8))
	_scroll.add_child(body)
	_label(body, "Connector type")
	profile_selector = OptionButton.new()
	profile_selector.fit_to_longest_item = false
	profile_selector.clip_text = true
	for profile in [["Blender Lab — Official", "blender_lab"], ["Blender — Community", "blender"], ["Custom MCP", "resources"]]:
		profile_selector.add_item(profile[0])
		profile_selector.set_item_metadata(profile_selector.item_count - 1, profile[1])
	profile_selector.item_selected.connect(_type_changed)
	body.add_child(profile_selector)
	_purpose = _label(body, "Inspect your open Blender session. For asset creation, use Blender Asset Studio on Extensions.")
	_blender_help = VBoxContainer.new()
	body.add_child(_blender_help)
	_label(_blender_help, "1. Install and enable the official MCP add-on in Blender.\n2. Install the separate official MCP server.\n3. Open Blender and start the listener in Preferences → Add-ons → MCP.\n4. Choose the server program below, Save, then Enable.")
	var guide := Button.new()
	guide.text = "Blender Lab installation guide"
	guide.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	guide.pressed.connect(func(): OS.shell_open("https://www.blender.org/lab/mcp-server/"))
	_blender_help.add_child(guide)
	_label(body, "Name")
	name_input = LineEdit.new()
	body.add_child(name_input)
	_label(body, "MCP server program")
	command_input = LineEdit.new()
	Localization.bind(command_input, &"placeholder_text", "Choose an installed MCP server")
	Localization.bind(command_input, &"tooltip_text", "This is the MCP server program, not the Blender executable.")
	body.add_child(command_input)
	var browse := Button.new()
	browse.text = "Browse…"
	browse.pressed.connect(func():
		if not _locked: _browse.popup_centered_ratio(0.75))
	body.add_child(browse)
	var advanced := CheckBox.new()
	advanced.text = "Advanced"
	body.add_child(advanced)
	_advanced = VBoxContainer.new()
	body.add_child(_advanced)
	_advanced.hide()
	advanced.toggled.connect(_advanced.set_visible)
	_label(_advanced, "Arguments (JSON array)")
	arguments_input = TextEdit.new()
	arguments_input.custom_minimum_size.y = Metrics.scaled(70)
	arguments_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	arguments_input.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_advanced.add_child(arguments_input)
	_label(body, "Setup is saved on this computer. Enable starts this local program with your account's file and network access. External reads ask separately.")
	_error = _label(body, "")
	_error.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_browse = FileDialog.new()
	_browse.title = "Choose MCP server"
	_browse.access = FileDialog.ACCESS_FILESYSTEM
	_browse.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_browse.use_native_dialog = true
	_browse.file_selected.connect(func(path):
		if not _locked: command_input.text = path)
	add_child(_browse)
	for field in [name_input, command_input]: field.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED


func _label(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func open_config(config: Dictionary, expected: Dictionary) -> void:
	_loading = true
	_id = str(config.get("id", ""))
	_expected = expected.duplicate(true)
	name_input.text = str(config.get("name", "Blender Lab"))
	command_input.text = str(config.get("command", Config.find_blender_server()))
	arguments_input.text = JSON.stringify(config.get("arguments", []))
	for index in profile_selector.item_count:
		if profile_selector.get_item_metadata(index) == config.get("profile", "blender_lab"):
			profile_selector.select(index)
	_error.text = ""
	_loading = false
	_sync_help()
	_scroll.scroll_vertical = 0
	popup_centered_clamped(Metrics.scaled_vector(Vector2(420, 460)), 0.85)


func _type_changed(_index: int) -> void:
	if _loading or _locked: return
	_sync_help()
	if name_input.text in ["", "Blender", "Blender Lab"]:
		name_input.text = "Blender Lab" if profile_selector.get_selected_metadata() == "blender_lab" else "Blender" if profile_selector.get_selected_metadata() == "blender" else ""
	if profile_selector.get_selected_metadata() in ["blender", "blender_lab"] and command_input.text.is_empty():
		command_input.text = Config.find_blender_server()


func _sync_help() -> void:
	var profile: String = profile_selector.get_selected_metadata()
	_purpose.visible = profile in ["blender", "blender_lab"]
	_blender_help.visible = profile == "blender_lab"


func _confirmed() -> void:
	if _locked: return
	var arguments = JSON.parse_string(arguments_input.text) if arguments_input.text.to_utf8_buffer().size() <= 8192 else null
	var config := Config.validate({"id": _id if not _id.is_empty() else "mcp_" + Crypto.new().generate_random_bytes(8).hex_encode(), "name": name_input.text.strip_edges(), "command": command_input.text.strip_edges(), "arguments": arguments, "profile": profile_selector.get_selected_metadata()})
	if config.is_empty():
		show_error("Choose a name and an absolute MCP server path. Advanced arguments must be a JSON array.")
		return
	save_requested.emit(config, _expected.duplicate(true))


func show_error(message: String) -> void:
	Localization.bind(_error, &"text", message)
	show()


func set_locked(locked: bool) -> void:
	_locked = locked
	get_ok_button().disabled = locked
	if locked:
		hide()
		_browse.hide()
