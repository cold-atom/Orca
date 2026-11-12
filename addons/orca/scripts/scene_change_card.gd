@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const CardHeader = preload("res://addons/orca/scripts/card_header.gd")
const CardFooter = preload("res://addons/orca/scripts/card_footer.gd")

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


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	set_meta("orca_scene_change_card", true)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.085, 0.095, 0.11, 1)
	style.border_color = Color(0.28, 0.5, 0.4, 1)
	style.set_border_width_all(UiMetrics.scaled_int(1))
	style.set_corner_radius_all(UiMetrics.scaled_int(7))
	style.set_content_margin_all(UiMetrics.scaled(8))
	add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiMetrics.scaled_int(7))
	add_child(content)
	var header := CardHeader.new()
	content.add_child(header)
	_title_label = Label.new()
	_title_label.clip_text = true
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title_label.text = "Scene Change"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)
	_status_label = header.create_status_badge()
	CardHeader.set_status(_status_label, "review")
	_validation_label = Label.new()
	_validation_label.add_theme_color_override("font_color", Color(0.48, 0.78, 0.58))
	_validation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_validation_label)
	var details := Label.new()
	details.set_meta("orca_scene_change_details", true)
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(details)
	var footer := CardFooter.new()
	content.add_child(footer)
	_open_button = Button.new()
	_open_button.text = "Open Scene"
	_open_button.flat = true
	_open_button.disabled = true
	_open_button.pressed.connect(func(): open_requested.emit(str(_proposal.get("filepath", "")), 1, 1))
	footer.navigation.add_child(_open_button)
	var actions := footer.actions
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
	var editor_current: bool = proposal.get("application_strategy") == "editor_current"
	CardHeader.set_status(_status_label, "trust_review" if trust_review else "review")
	Localization.bind(_validation_label, &"text", "Warning: %s" if trust_review else "Validated: %s", [Localization.source(str(proposal.get("validation", {}).get("message", "Passed")))])
	_validation_label.add_theme_color_override("font_color", Color(0.95, 0.68, 0.28) if trust_review else Color(0.48, 0.78, 0.58))
	_apply_button.text = "Trust and Prepare" if trust_review else "Apply in editor" if editor_current else "Apply"
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
					Localization.bind(details, &"text", "Target  %s\nNode    %s\nScript  %s\n\nThis first approval permits Godot to compile, load, and instantiate the reviewed script after an immediate hash recheck while preparing and revalidating a candidate. It does not modify the scene. Godot cannot lock the file against external replacement during loading.", [target, str(summary.get("node_path", "")), str(summary.get("script_path", ""))])
				else:
					Localization.bind(details, &"text", "Target    %s\nNode      %s (%s)\nPrevious  %s\nProposed  %s\nBase      %s", [target, str(summary.get("node_path", "")), str(summary.get("node_type", "")), _display_script(str(summary.get("before_script", ""))), _display_script(str(summary.get("after_script", ""))), str(summary.get("script_base", ""))])
			"add_node":
				_title_label.text = "Add Scene Node"
				var added: Dictionary = summary.get("added_node", {})
				Localization.bind(details, &"text", "Target  %s\nParent  %s\nNode    %s \"%s\"\nResult  %s nodes", [target, str(added.get("parent_path", "")), str(added.get("type", "")), str(added.get("name", "")), str(summary.get("after_node_count", ""))])
			"set_property":
				_title_label.text = "Set Scene Property"
				Localization.bind(details, &"text", "Target    %s\nNode      %s\nProperty  %s\nPrevious  %s\nProposed  %s", [target, str(summary.get("node_path", "")), str(summary.get("property_name", "")), JSON.stringify(summary.get("before")), JSON.stringify(summary.get("after"))])
			"rename_node":
				_title_label.text = "Rename Scene Node"
				Localization.bind(details, &"text", "Target    %s\nPrevious  %s\nProposed  %s", [target, str(summary.get("old_path", "")), str(summary.get("new_path", ""))])
			"remove_node":
				_title_label.text = "Remove Scene Node"
				var removed: Dictionary = summary.get("removed_node", {})
				Localization.bind(details, &"text", "Target  %s\nRemove  %s \"%s\"\nResult  %s nodes", [target, str(removed.get("type", "")), str(removed.get("path", "")), str(summary.get("after_node_count", ""))])
			"reparent_node":
				_title_label.text = "Reparent Scene Node"
				Localization.bind(details, &"text", "Target    %s\nNode      %s\nPrevious  %s\nProposed  %s", [target, str(summary.get("node_name", "")), str(summary.get("old_parent_path", "")), str(summary.get("new_parent_path", ""))])
			"instantiate_child_scene":
				_title_label.text = "Instantiate Child Scene"
				var instance: Dictionary = summary.get("instance", {})
				Localization.bind(details, &"text", "Target  %s\nParent  %s\nScene   %s\nNode    %s", [target, str(instance.get("parent_path", "")), str(instance.get("scene_path", "")), str(instance.get("path", ""))])
			"connect_signal", "disconnect_signal":
				_title_label.text = "Connect Scene Signal" if str(summary.get("operation")) == "connect_signal" else "Disconnect Scene Signal"
				var connection: Dictionary = summary.get("connection", {})
				Localization.bind(details, &"text", "Target  %s\nSignal  %s.%s\nMethod  %s.%s\nFlags   %s", [target, str(connection.get("source", "")), str(connection.get("signal", "")), str(connection.get("target", "")), str(connection.get("method", "")), _connection_flags(int(connection.get("flags", 0)))])
			_:
				_title_label.text = "Create Scene"
				Localization.bind(details, &"text", "Target  %s\nRoot    %s \"%s\"", [target, str(summary.get("root_type", "")), str(summary.get("root_name", ""))])
		details.tooltip_text = str(proposal.get("filepath", ""))
		if editor_current:
			# Add a translated disclosure without replacing the existing bound review.
			var bindings: Dictionary = details.get_meta(Localization.BINDINGS, {})
			var parts: Array = bindings.get(&"text", {}).get("parts", []).duplicate(true)
			parts.append(["\n\nKeeps the scene open and preserves normal Godot Undo. Applies in the editor only; save the scene before running it. Script trust also covers live attachment, property restoration and revalidation.", []])
			Localization.bind_parts(details, &"text", parts)


func set_status(status: String, message: String) -> void:
	_proposal["status"] = status
	CardHeader.set_status(_status_label, status, message)
	var editor_statuses := ["applied_editor", "saved_editor", "save_observed_editor", "undone_editor", "reverted_editor", "editor_changed"]
	_apply_button.visible = false
	_reject_button.visible = false
	_revert_button.visible = status in ["applied", "applied_recovery", "revert_failed", "applied_editor", "saved_editor", "save_observed_editor"]
	_revert_button.text = "Revert in editor" if _proposal.get("application_strategy") == "editor_current" else "Revert"
	_open_button.disabled = status not in ["applied", "applied_recovery", "revert_failed", "applied_editor", "saved_editor", "save_observed_editor", "undone_editor", "reverted_editor", "editor_changed"]
	if editor_statuses.has(status):
		_validation_label.text = message
	if status in ["applied_recovery", "reverted_recovery", "apply_recovery_required", "revert_recovery_required"]:
		_validation_label.text = message


func set_revert_available(available: bool) -> void:
	_revert_button.disabled = not available
	_revert_button.tooltip_text = "Revert rechecks current file state." if available else "Revert is available in idle Work mode."


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
