@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")

signal action_requested(change_id: String, action: String)
signal open_requested(filepath: String, line: int, column: int)

var _proposal: Dictionary
var _status_label: Label
var _validation_label: Label
var _review: VBoxContainer
var _apply_button: Button
var _reject_button: Button
var _revert_button: Button


func _ready() -> void:
	set_meta("orca_project_settings_change_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.085, 0.095, 0.11, 1)
	style.border_color = Color(0.48, 0.38, 0.22, 1)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(7))
	style.set_content_margin_all(UiMetrics.scaled(8))
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	var title := Label.new()
	title.text = "Project Settings"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_status_label = Label.new()
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	content.add_child(_validation_label)
	_review = VBoxContainer.new()
	_review.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	content.add_child(_review)
	var navigation := HBoxContainer.new()
	content.add_child(navigation)
	var open_button := Button.new()
	open_button.text = "Project File"
	open_button.flat = true
	open_button.pressed.connect(func(): open_requested.emit("res://project.godot", 1, 1))
	navigation.add_child(open_button)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", UiMetrics.scaled_int(6))
	content.add_child(actions)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	_reject_button = Button.new()
	_reject_button.text = "Reject"
	_reject_button.pressed.connect(func(): action_requested.emit(str(_proposal.get("id", "")), "reject"))
	actions.add_child(_reject_button)
	_apply_button = Button.new()
	_apply_button.text = "Apply"
	_apply_button.pressed.connect(func(): action_requested.emit(str(_proposal.get("id", "")), "apply"))
	actions.add_child(_apply_button)
	_revert_button = Button.new()
	_revert_button.text = "Revert"
	_revert_button.visible = false
	_revert_button.pressed.connect(func(): action_requested.emit(str(_proposal.get("id", "")), "revert"))
	actions.add_child(_revert_button)


func configure(proposal: Dictionary) -> void:
	_proposal = proposal
	var items: Array = proposal.get("review", [])
	_status_label.text = "%d setting%s" % [items.size(), "" if items.size() == 1 else "s"]
	_validation_label.text = "Validated: " + str(proposal.get("validation", {}).get("message", "Passed"))
	for item in items:
		var label := Label.new()
		label.text = "%s\n  %s -> %s" % [str(item.get("label", item.get("setting_path", ""))), _format_value(item.get("before")), _format_value(item.get("after"))]
		label.tooltip_text = str(item.get("setting_path", ""))
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_review.add_child(label)


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	_status_label.text = status.replace("_", " ").to_upper()
	_status_label.tooltip_text = message
	_apply_button.visible = false
	_reject_button.visible = false
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed"]
	if status in ["applied_recovery", "reverted_recovery", "apply_recovery_required", "revert_recovery_required"]:
		_validation_label.text = message
	_status_label.add_theme_color_override("font_color", Color(0.45, 0.82, 0.55) if status == "applied" else Color(0.62, 0.65, 0.7) if status in ["rejected", "reverted"] else Color(0.95, 0.4, 0.4))


func _format_value(value) -> String:
	return JSON.stringify(value)
