@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

signal decision_requested(call_id: String, origin_turn_id: int, approved: bool)

var _call_id := ""
var _origin_turn_id := 0
var _title: Label
var _reason: Label
var _status: Label
var _stay_button: Button
var _switch_button: Button


func _ready() -> void:
	set_meta("orca_mode_switch_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.105, 0.1, 0.96)
	style.border_color = Color(0.38, 0.68, 0.46, 1.0)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(7))
	style.set_content_margin_all(UiMetrics.scaled(9))
	add_theme_stylebox_override("panel", style)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	add_child(content)

	_title = Label.new()
	_title.text = "Switch to Work mode?"
	_title.add_theme_font_size_override("font_size", _font_size(14))
	_title.add_theme_color_override("font_color", Color(0.68, 0.9, 0.72))
	content.add_child(_title)

	var explanation := Label.new()
	explanation.text = "Orca needs Work mode to continue this task. Switching modes does not approve any file change."
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.add_theme_font_size_override("font_size", _font_size(13))
	explanation.add_theme_color_override("font_color", Color(0.76, 0.79, 0.83))
	content.add_child(explanation)

	_reason = Label.new()
	_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reason.add_theme_font_size_override("font_size", _font_size(13))
	_reason.add_theme_color_override("font_color", Color(0.9, 0.82, 0.62))
	content.add_child(_reason)

	var actions := VBoxContainer.new()
	actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	content.add_child(actions)
	_switch_button = Button.new()
	_switch_button.text = "Switch to Work"
	_switch_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_switch_button.pressed.connect(_choose.bind(true))
	actions.add_child(_switch_button)
	_stay_button = Button.new()
	_stay_button.text = "Stay in Plan"
	_stay_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stay_button.pressed.connect(_choose.bind(false))
	actions.add_child(_stay_button)

	_status = Label.new()
	_status.visible = false
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", _font_size(12))
	content.add_child(_status)


func configure(request: Dictionary, origin_turn_id: int) -> void:
	_call_id = str(request.get("call_id", ""))
	_origin_turn_id = origin_turn_id
	_reason.text = "Reason: " + str(request.get("reason", ""))


func complete(execution: Dictionary, _duration_ms: int) -> void:
	_set_actions_disabled(true)
	_switch_button.visible = false
	_stay_button.visible = false
	_status.visible = true
	var outcome := str(execution.get("outcome", "failed"))
	var content := str(execution.get("content", ""))
	if outcome == "completed" and content.contains("approved Work mode"):
		_title.text = "Work mode enabled"
		_status.text = "Continuing this task in Work mode. Changes still require approval."
		_status.add_theme_color_override("font_color", Color(0.48, 0.84, 0.57))
	elif outcome == "completed":
		_title.text = "Remaining in Plan mode"
		_status.text = "Orca will finish this turn without making project changes."
		_status.add_theme_color_override("font_color", Color(0.92, 0.69, 0.4))
	elif outcome == "cancelled":
		_title.text = "Mode switch cancelled"
		_status.text = "Orca remains in Plan mode."
		_status.add_theme_color_override("font_color", Color(0.65, 0.67, 0.72))
	else:
		_title.text = "Mode switch unavailable"
		_status.text = "Orca remains in Plan mode."
		_status.add_theme_color_override("font_color", Color(0.95, 0.45, 0.42))


func _choose(approved: bool) -> void:
	if _call_id.is_empty() or _origin_turn_id <= 0 or _switch_button.disabled or _stay_button.disabled:
		return
	_set_actions_disabled(true)
	_status.visible = true
	_status.text = "Switching to Work mode..." if approved else "Staying in Plan mode..."
	_status.add_theme_color_override("font_color", Color(0.65, 0.7, 0.76))
	decision_requested.emit(_call_id, _origin_turn_id, approved)


func _set_actions_disabled(disabled: bool) -> void:
	_switch_button.disabled = disabled
	_stay_button.disabled = disabled


func _font_size(fallback: int) -> int:
	if not Engine.is_editor_hint():
		return fallback
	return maxi(EditorInterface.get_editor_theme().get_font_size("font_size", "Label"), fallback)
