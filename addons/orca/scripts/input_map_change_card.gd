@tool
extends PanelContainer

signal action_requested(change_id: String, action: String)
signal open_requested(filepath: String, line: int, column: int)

var _proposal: Dictionary
var _status_label: Label
var _validation_label: Label
var _review_label: RichTextLabel
var _apply_button: Button
var _reject_button: Button
var _revert_button: Button


func _ready() -> void:
	set_meta("orca_input_map_change_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.085, 0.095, 0.11, 1)
	style.border_color = Color(0.28, 0.46, 0.36, 1)
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
	title.text = "Input Map  res://project.godot"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	header.add_child(title)
	_status_label = Label.new()
	header.add_child(_status_label)
	_validation_label = Label.new()
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	content.add_child(_validation_label)
	_review_label = RichTextLabel.new()
	_review_label.bbcode_enabled = true
	_review_label.fit_content = false
	_review_label.selection_enabled = true
	_review_label.custom_minimum_size = Vector2(0, 110)
	_review_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_review_label)
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_END
	actions.add_theme_constant_override("separation", 6)
	content.add_child(actions)
	var open_button := Button.new()
	open_button.text = "Open File"
	open_button.flat = true
	open_button.pressed.connect(func(): open_requested.emit("res://project.godot", 1, 1))
	actions.add_child(open_button)
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
	var review: Array = proposal.get("review", [])
	_status_label.text = "%d action%s" % [review.size(), "" if review.size() == 1 else "s"]
	_validation_label.text = "Validated: " + str(proposal.get("validation", {}).get("message", "Passed"))
	_review_label.text = _format_review(review)


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


func _format_review(review: Array) -> String:
	var lines := PackedStringArray()
	for item in review:
		var operation := str(item.get("operation", "update"))
		var color := "#8fd7a6" if operation == "add" else "#f0a8a8" if operation == "remove" else "#e2c879"
		lines.append("[color=%s][b]%s[/b][/color]  %s" % [color, operation.to_upper(), _escape(str(item.get("action", "")))])
		if item.get("before") != null:
			lines.append("  Previous: " + _escape(_format_action(item["before"])))
		if item.get("after") != null:
			lines.append("  Proposed: " + _escape(_format_action(item["after"])))
	return "\n".join(lines)


func _format_action(action: Dictionary) -> String:
	var event_names := PackedStringArray()
	for event in action.get("events", []):
		var name := str(event.get("type", "event"))
		if event.get("type") == "key":
			var key_parts := PackedStringArray()
			if int(event.get("keycode", 0)) != 0:
				key_parts.append("key=" + OS.get_keycode_string(int(event["keycode"])))
			if int(event.get("physical_keycode", 0)) != 0:
				key_parts.append("physical=" + OS.get_keycode_string(int(event["physical_keycode"])))
			if int(event.get("key_label", 0)) != 0:
				key_parts.append("label=" + OS.get_keycode_string(int(event["key_label"])))
			if int(event.get("unicode", 0)) != 0:
				key_parts.append("unicode=U+%04X" % int(event["unicode"]))
			if int(event.get("location", 0)) != 0:
				key_parts.append("location=" + str(event["location"]))
			name += " " + " ".join(key_parts)
		elif event.has("button_index"):
			name += " button=" + str(event["button_index"])
			if event.get("double_click", false):
				name += " double_click=true"
		elif event.has("axis"):
			name += " axis=%s direction=%s" % [event["axis"], event.get("axis_value", 0)]
		elif event.get("type") == "unsupported":
			name += " class=" + str(event.get("class", "Unknown"))
			if not str(event.get("display", "")).is_empty():
				name += " " + str(event["display"])
		var modifiers := PackedStringArray()
		for modifier in ["ctrl", "alt", "shift", "meta"]:
			if event.get(modifier, false):
				modifiers.append(modifier)
		if not modifiers.is_empty():
			name += " modifiers=" + "+".join(modifiers)
		name += " device=" + str(event.get("device", -1))
		event_names.append(name)
	return "deadzone %s; %s" % [action.get("deadzone", 0.5), ", ".join(event_names) if not event_names.is_empty() else "no events"]


func _escape(value: String) -> String:
	return value.replace("[", "[lb]").replace("]", "[rb]")
