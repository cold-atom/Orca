@tool
extends PanelContainer

signal action_requested(change_id: String, action: String)
signal open_requested(filepath: String, line: int, column: int)

var _proposal: Dictionary
var _status_label: Label
var _validation_label: Label
var _paths: VBoxContainer
var _apply_button: Button
var _reject_button: Button
var _revert_button: Button


func _ready() -> void:
	set_meta("orca_main_scene_change_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.085, 0.095, 0.11, 1)
	style.border_color = Color(0.3, 0.43, 0.58, 1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	var title := Label.new()
	title.text = "Project Main Scene"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_status_label = Label.new()
	_status_label.text = "REVIEW"
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	content.add_child(_validation_label)
	_paths = VBoxContainer.new()
	content.add_child(_paths)
	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", 6)
	content.add_child(navigation)
	var open_project := Button.new()
	open_project.text = "Project File"
	open_project.flat = true
	open_project.pressed.connect(func(): open_requested.emit("res://project.godot", 1, 1))
	navigation.add_child(open_project)
	var open_scene := Button.new()
	open_scene.text = "Scene"
	open_scene.flat = true
	open_scene.pressed.connect(func(): open_requested.emit(str(_proposal.get("new_scene_path", "")), 1, 1))
	navigation.add_child(open_scene)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 6)
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
	_validation_label.text = "Validated: " + str(proposal.get("validation", {}).get("message", "Passed"))
	_add_path("Previous", str(proposal.get("old_scene_display", proposal.get("old_scene_path", ""))), false)
	_add_path("Proposed", str(proposal.get("new_scene_path", "")), true)


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	_status_label.text = status.replace("_", " ").to_upper()
	_status_label.tooltip_text = message
	_apply_button.visible = false
	_reject_button.visible = false
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed"]
	if status in ["applied_recovery", "reverted_recovery"]:
		_validation_label.text = message
	_status_label.add_theme_color_override("font_color", Color(0.45, 0.82, 0.55) if status == "applied" else Color(0.62, 0.65, 0.7) if status in ["rejected", "reverted"] else Color(0.95, 0.4, 0.4))


func _add_path(label: String, path: String, proposed: bool) -> void:
	var row := Label.new()
	row.text = label + "  " + ("Not configured" if path.is_empty() else path)
	row.tooltip_text = path
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if proposed:
		row.add_theme_color_override("font_color", Color(0.58, 0.82, 0.68))
	_paths.add_child(row)
