@tool
extends PanelContainer

const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")

var service
var compact := false
var title_label: Label
var status_label: Label
var install_button: Button
var check_button: Button
var notes_button: Button
var cancel_button: Button
var dismiss_button: Button
var automatic_toggle: CheckButton
var progress: ProgressBar
var _confirm: ConfirmationDialog
var recovery_button: Button
var browser_opener := Callable()


func _enter_tree() -> void:
	Localization.attach(self)


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.145)
	style.set_corner_radius_all(UiMetrics.scaled_int(6))
	style.set_content_margin_all(UiMetrics.scaled(8))
	# Leave room for full action captions inside narrow settings scroll areas.
	style.content_margin_left = UiMetrics.scaled(6)
	style.content_margin_right = UiMetrics.scaled(6)
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiMetrics.scaled_int(5))
	add_child(column)
	title_label = Label.new()
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(title_label)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override("font_color", Color(0.65, 0.69, 0.74))
	column.add_child(status_label)
	progress = ProgressBar.new()
	progress.show_percentage = true
	column.add_child(progress)
	var buttons := HFlowContainer.new()
	column.add_child(buttons)
	install_button = _button("Update & Restart", buttons, _confirm_install)
	check_button = _button("Check for updates", buttons, func(): service.check_for_updates())
	notes_button = _button("What’s new", buttons, _on_release_notes_pressed)
	notes_button.tooltip_text = "Open official release notes in your browser"
	cancel_button = _button("Cancel", buttons, func(): service.cancel())
	dismiss_button = _button("Later", buttons, func(): service.dismiss())
	automatic_toggle = CheckButton.new()
	automatic_toggle.text = "Check automatically (daily)"
	automatic_toggle.clip_text = true
	automatic_toggle.tooltip_text = automatic_toggle.text
	automatic_toggle.toggled.connect(func(enabled): service.set_automatic_checks(enabled))
	column.add_child(automatic_toggle)
	if not compact:
		recovery_button = _button("Restore previous addon & restart", column, func(): _confirm_install("recover"))
		recovery_button.tooltip_text = "Restore the verified rollback copy for this project"
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Update Orca"
	_confirm.ok_button_text = "Update & Restart"
	_confirm.confirmed.connect(func(): service.request_install(str(_confirm.get_meta("operation", "install"))))
	add_child(_confirm)
	if service != null:
		service.changed.connect(refresh)
	refresh()


func _button(text: String, parent: Node, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = text
	# Flow children need their full text minimum size; clipping collapses them
	# to padding-only blocks. Full-width column actions may still ellipsize.
	button.clip_text = not (parent is HFlowContainer)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _on_release_notes_pressed() -> void:
	if service == null:
		return
	var url := str(service.release.get("page", service.RELEASES))
	if browser_opener.is_valid():
		browser_opener.call(url)
	else:
		OS.shell_open(url)


func _confirm_install(operation: String = "install") -> void:
	if service == null or service.busy():
		return
	_confirm.set_meta("operation", operation)
	_confirm.title = "Restore Orca" if operation == "recover" else "Update Orca"
	_confirm.ok_button_text = "Restore & Restart" if operation == "recover" else "Update & Restart"
	var parts: Array = [["Restore the verified previous Orca addon and restart Godot?", []]] if operation == "recover" else [["Download and install Orca %s in this project, then restart Godot?\n\nThe previous addon will be retained for rollback.", [str(service.release.get("version", ""))]]]
	parts.append(["\n\nSave your editor work first and close other editors of this project. Active Orca work and unsaved scripts/scenes must be finished before installation.", []])
	Localization.bind_parts(_confirm, &"dialog_text", parts)
	_confirm.popup_centered(UiMetrics.scaled_vector(Vector2(440, 220)))


func refresh() -> void:
	if service == null:
		hide()
		return
	visible = not compact or (not service.release.is_empty() and not service.dismissed())
	Localization.bind(title_label, &"text", "Orca %s is available" if not service.release.is_empty() else "Plugin updates", [str(service.release.get("version", ""))] if not service.release.is_empty() else [])
	status_label.text = service.status
	var version := str(service.release.get("version", ""))
	if service.status == "Orca " + version + " is available.":
		Localization.bind(status_label, &"text", "Orca %s is available.", [version])
	elif service.status == "Downloading Orca " + version + "…":
		Localization.bind(status_label, &"text", "Downloading Orca %s…", [version])
	status_label.visible = not compact or service.state not in ["available", "up_to_date", "idle"]
	install_button.visible = not service.release.is_empty()
	install_button.disabled = service.busy()
	check_button.visible = not compact
	check_button.disabled = service.busy()
	cancel_button.visible = service.state in ["checking", "downloading", "preparing"]
	dismiss_button.visible = compact and not service.busy()
	automatic_toggle.visible = not compact
	automatic_toggle.set_pressed_no_signal(service.automatic_checks())
	progress.visible = service.state == "downloading"
	progress.max_value = maxi(1, int(service.release.get("size", 1)))
	progress.value = service.downloaded_bytes
	if recovery_button != null:
		var root: String = service._project_root().path_join(service.Package.WORKSPACE)
		recovery_button.disabled = service.busy() or not FileAccess.file_exists(root.path_join("backup/update_manifest.json"))
