@tool
extends PanelContainer

signal action_requested(change_id: String, action: String)
signal open_requested(filepath: String, line: int, column: int)

var _proposal: Dictionary
var _title_label: Label
var _status_label: Label
var _validation_label: Label
var _open_button: Button
var _apply_button: Button
var _reject_button: Button
var _revert_button: Button


func _ready() -> void:
	set_meta("orca_scene_change_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.085, 0.095, 0.11, 1)
	style.border_color = Color(0.28, 0.5, 0.4, 1)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	_title_label = Label.new()
	_title_label.text = "Scene Change"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_status_label = Label.new()
	_status_label.text = "REVIEW"
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	_validation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_validation_label)
	var details := Label.new()
	details.set_meta("orca_scene_change_details", true)
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(details)
	_open_button = Button.new()
	_open_button.text = "Open Scene"
	_open_button.flat = true
	_open_button.disabled = true
	_open_button.pressed.connect(func(): open_requested.emit(str(_proposal.get("filepath", "")), 1, 1))
	content.add_child(_open_button)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 6)
	content.add_child(actions)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	_reject_button = Button.new()
	_reject_button.text = "Reject"
	_reject_button.pressed.connect(func(): _request_decision("reject"))
	actions.add_child(_reject_button)
	_apply_button = Button.new()
	_apply_button.text = "Apply"
	_apply_button.pressed.connect(func(): _request_decision("apply"))
	actions.add_child(_apply_button)
	_revert_button = Button.new()
	_revert_button.text = "Revert"
	_revert_button.visible = false
	_revert_button.pressed.connect(func(): action_requested.emit(str(_proposal.get("id", "")), "revert"))
	actions.add_child(_revert_button)


func configure(proposal: Dictionary) -> void:
	_proposal = proposal
	var summary: Dictionary = proposal.get("scene_summary", {})
	var trust_review := str(proposal.get("approval_stage", "")) == "script_trust"
	_status_label.text = "TRUST REVIEW" if trust_review else "REVIEW"
	_status_label.tooltip_text = ""
	_status_label.remove_theme_color_override("font_color")
	_validation_label.text = ("Warning: " if trust_review else "Validated: ") + str(proposal.get("validation", {}).get("message", "Passed"))
	_validation_label.add_theme_color_override("font_color", Color(0.95, 0.68, 0.28) if trust_review else Color(0.48, 0.78, 0.58))
	_apply_button.text = "Trust and Prepare" if trust_review else "Apply"
	_apply_button.visible = true
	_apply_button.disabled = false
	_reject_button.visible = true
	_reject_button.disabled = false
	_revert_button.visible = false
	_open_button.disabled = true
	var details := _find_details(self)
	if details != null:
		var target := str(proposal.get("filepath", ""))
		match str(summary.get("operation", "create_scene")):
			"attach_script", "detach_script":
				var attaching := str(summary.get("operation", "")) == "attach_script"
				_title_label.text = ("Authorize Script Attach" if attaching else "Authorize Script Detach") if trust_review else ("Attach Scene Script" if attaching else "Detach Scene Script")
				if trust_review:
					details.text = "Target  %s\nNode    %s\nScript  %s\n\nThis first approval permits Godot to compile, load, and instantiate the reviewed script after an immediate hash recheck while preparing and revalidating a candidate. It does not modify the scene. Godot cannot lock the file against external replacement during loading." % [target, str(summary.get("node_path", "")), str(summary.get("script_path", ""))]
				else:
					details.text = "Target    %s\nNode      %s (%s)\nPrevious  %s\nProposed  %s\nBase      %s" % [target, str(summary.get("node_path", "")), str(summary.get("node_type", "")), _display_script(str(summary.get("before_script", ""))), _display_script(str(summary.get("after_script", ""))), str(summary.get("script_base", ""))]
			"add_node":
				_title_label.text = "Add Scene Node"
				var added: Dictionary = summary.get("added_node", {})
				details.text = "Target  %s\nParent  %s\nNode    %s \"%s\"\nResult  %s nodes" % [target, str(added.get("parent_path", "")), str(added.get("type", "")), str(added.get("name", "")), str(summary.get("after_node_count", ""))]
			"set_property":
				_title_label.text = "Set Scene Property"
				details.text = "Target    %s\nNode      %s\nProperty  %s\nPrevious  %s\nProposed  %s" % [target, str(summary.get("node_path", "")), str(summary.get("property_name", "")), JSON.stringify(summary.get("before")), JSON.stringify(summary.get("after"))]
			"rename_node":
				_title_label.text = "Rename Scene Node"
				details.text = "Target    %s\nPrevious  %s\nProposed  %s" % [target, str(summary.get("old_path", "")), str(summary.get("new_path", ""))]
			"remove_node":
				_title_label.text = "Remove Scene Node"
				var removed: Dictionary = summary.get("removed_node", {})
				details.text = "Target  %s\nRemove  %s \"%s\"\nResult  %s nodes" % [target, str(removed.get("type", "")), str(removed.get("path", "")), str(summary.get("after_node_count", ""))]
			"reparent_node":
				_title_label.text = "Reparent Scene Node"
				details.text = "Target    %s\nNode      %s\nPrevious  %s\nProposed  %s" % [target, str(summary.get("node_name", "")), str(summary.get("old_parent_path", "")), str(summary.get("new_parent_path", ""))]
			"instantiate_child_scene":
				_title_label.text = "Instantiate Child Scene"
				var instance: Dictionary = summary.get("instance", {})
				details.text = "Target  %s\nParent  %s\nScene   %s\nNode    %s" % [target, str(instance.get("parent_path", "")), str(instance.get("scene_path", "")), str(instance.get("path", ""))]
			"connect_signal", "disconnect_signal":
				_title_label.text = "Connect Scene Signal" if str(summary.get("operation")) == "connect_signal" else "Disconnect Scene Signal"
				var connection: Dictionary = summary.get("connection", {})
				details.text = "Target  %s\nSignal  %s.%s\nMethod  %s.%s\nFlags   %s" % [target, str(connection.get("source", "")), str(connection.get("signal", "")), str(connection.get("target", "")), str(connection.get("method", "")), _connection_flags(int(connection.get("flags", 0)))]
			_:
				_title_label.text = "Create Scene"
				details.text = "Target  %s\nRoot    %s \"%s\"" % [target, str(summary.get("root_type", "")), str(summary.get("root_name", ""))]
		details.tooltip_text = str(proposal.get("filepath", ""))


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	_status_label.text = status.replace("_", " ").to_upper()
	_status_label.tooltip_text = message
	_apply_button.visible = false
	_reject_button.visible = false
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed"]
	_open_button.disabled = status not in ["applied", "applied_recovery", "revert_failed"]
	if status in ["applied_recovery", "reverted_recovery"]:
		_validation_label.text = message
	_status_label.add_theme_color_override("font_color", Color(0.45, 0.82, 0.55) if status == "applied" else Color(0.62, 0.65, 0.7) if status in ["rejected", "reverted"] else Color(0.95, 0.4, 0.4))


func _request_decision(action: String) -> void:
	_apply_button.disabled = true
	_reject_button.disabled = true
	action_requested.emit(str(_proposal.get("id", "")), action)


func _display_script(path: String) -> String:
	return "(none)" if path.is_empty() else path


func _find_details(node: Node) -> Label:
	if node.has_meta("orca_scene_change_details"):
		return node as Label
	for child in node.get_children():
		var found := _find_details(child)
		if found != null:
			return found
	return null


func _connection_flags(flags: int) -> String:
	var labels := PackedStringArray(["persistent"])
	if (flags & Object.CONNECT_DEFERRED) != 0:
		labels.append("deferred")
	if (flags & Object.CONNECT_ONE_SHOT) != 0:
		labels.append("one-shot")
	return ", ".join(labels)
