@tool
extends PanelContainer

signal decision_requested(call_id: String, turn_id: int, approved: bool)

const Localization = preload("res://addons/orca/scripts/localization.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var _id := ""
var _turn := 0
var _details: TextEdit
var _allow: Button
var _reject: Button
var _status: Label
var _title: Label
var _help: Label


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.105, 0.12)
	style.border_color = Color(0.35, 0.56, 0.7)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(7))
	style.set_content_margin_all(UiMetrics.scaled(9))
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	add_child(content)
	var title := Label.new()
	_title = title
	title.text = "Allow external MCP read?"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(title)
	var help := Label.new()
	_help = help
	help.text = "Send this inspection request to the connected server and share its returned text with the selected model?"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(help)
	_details = TextEdit.new()
	_details.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_details.editable = false
	_details.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_details.custom_minimum_size.y = UiMetrics.scaled(110)
	content.add_child(_details)
	_allow = Button.new()
	_allow.text = "Allow read"
	_allow.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_allow.pressed.connect(_choose.bind(true))
	content.add_child(_allow)
	_reject = Button.new()
	_reject.text = "Reject"
	_reject.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reject.pressed.connect(_choose.bind(false))
	content.add_child(_reject)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_status)


func configure(request: Dictionary, turn_id: int) -> void:
	_id = request["call_id"]
	_turn = turn_id
	var details := request.duplicate(true)
	details.erase("call_id")
	details.erase("success")
	details.erase("external")
	_details.text = JSON.stringify(details, "  ")


func _choose(approved: bool) -> void:
	if _allow.disabled or _id.is_empty():
		return
	_allow.disabled = true
	_reject.disabled = true
	decision_requested.emit(_id, _turn, approved)


func complete(execution: Dictionary, _duration_ms: int) -> void:
	_allow.disabled = true
	_reject.disabled = true
	_allow.hide()
	_reject.hide()
	_status.text = "MCP read finished" if execution.get("success", false) else "MCP read did not complete"
	_details.text += "\n\n" + str(execution.get("content", ""))
