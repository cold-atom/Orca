@tool
extends "res://tests/editor_test_case.gd"

const Service = preload("res://addons/orca/scripts/update_service.gd")
const UpdatePanel = preload("res://addons/orca/scripts/update_panel.gd")
const Package = preload("res://addons/orca/scripts/update_package.gd")
const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")
const UiMetrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var failures := 0

class FixtureService:
	extends Service
	var preferences := {}
	var checks := 0
	func _setting(key: String, fallback): return preferences.get(key, fallback)
	func _save_setting(key: String, value) -> void: preferences[key] = value
	func check_for_updates() -> void:
		checks += 1
		state = "checking"
		status = "Checking synthetic releases…"
		changed.emit()

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _find_plugin(node: Node):
	if node is EditorPlugin and node.get_script() != null and node.get_script().resource_path == "res://addons/orca/orca.gd":
		return node
	for child in node.get_children():
		var found = _find_plugin(child)
		if found != null: return found
	return null

func _run() -> void:
	create_timer(45).timeout.connect(func(): push_error("Update editor fixture timed out"); quit(1))
	check(Engine.is_editor_hint(), "editor fixture")
	for frame in 8:
		await process_frame
	var plugin = _find_plugin(root)
	check(plugin != null, "actual plugin owns updater")
	if plugin != null:
		check(plugin.chat_window.update_service == plugin.update_service and plugin.chat_window.settings_view.update_service == plugin.update_service, "dock/General Settings share one updater")
		check(plugin.chat_window.settings_view.system_scroll.is_ancestor_of(plugin.chat_window.settings_view.update_panel), "actual plugin update card belongs to General Settings")
		var chat = plugin.chat_window
		var draft: String = chat.prompt_input.text
		chat.prompt_input.text = "next-message draft"
		check(not plugin._update_readiness().is_empty(), "draft prevents restart")
		plugin._on_install_requested("install")
		check(plugin.update_service.state == "error" and plugin.update_service._installer.is_empty(), "blocked install launches no updater")
		chat.prompt_input.text = draft
		chat.agent_controller._is_running = true
		check(not plugin._update_readiness().is_empty(), "active turn prevents restart")
		chat.agent_controller._is_running = false
		chat.agent_controller._pending_change_id = "synthetic-approval"
		check(not plugin._update_readiness().is_empty(), "pending approval prevents restart")
		chat.agent_controller._pending_change_id = ""
		await _test_unsaved_work(plugin)
	var service := FixtureService.new()
	root.add_child(service)
	service.release = {"version": "1.4.0", "size": 1000, "page": Service.RELEASES + "/tag/v1.4.0"}
	service.state = "available"
	await _test_general_settings(service)
	var requests := {"count": 0, "operation": ""}
	service.install_requested.connect(func(operation: String): requests["count"] += 1; requests["operation"] = operation)
	for compact in [false, true]:
		var panel := UpdatePanel.new()
		panel.service = service
		panel.compact = compact
		panel.position = Vector2(0, 0)
		panel.size = UiMetrics.scaled_vector(Vector2(280, 350))
		root.add_child(panel)
		var browser := {"url": ""}
		panel.browser_opener = func(url: String): browser["url"] = url
		for frame in 4:
			await process_frame
		check(panel.visible and not panel.install_button.disabled, "update notice/General Settings action visible")
		check(panel.get_combined_minimum_size().x <= UiMetrics.scaled(280), "update controls fit narrow dock")
		_assert_action_labels(panel)
		panel.notes_button.pressed.emit()
		check(browser["url"] == Service.RELEASES + "/tag/v1.4.0", "release notes action opens the official version page")
		if not compact:
			var saved_release: Dictionary = service.release.duplicate(true)
			service.release = {}
			service.state = "up_to_date"
			service.changed.emit()
			for frame in 3:
				await process_frame
			check(panel.check_button.visible and panel.notes_button.visible and not panel.install_button.visible, "up-to-date settings card shows the two labeled actions")
			_assert_action_labels(panel)
			panel.notes_button.pressed.emit()
			check(browser["url"] == Service.RELEASES, "up-to-date release action opens official Releases")
			var previous_checks: int = service.checks
			panel.check_button.pressed.emit()
			check(service.checks == previous_checks + 1 and panel.check_button.disabled and panel.cancel_button.visible, "manual check action starts checking and updates controls")
			panel.cancel_button.pressed.emit()
			check(service.state == "idle" and not panel.check_button.disabled, "Cancel returns the actions to their idle state")
			service.release = saved_release
			service.state = "available"
			service.changed.emit()
			for frame in 3:
				await process_frame
		var normal_font := panel.get_theme_font_size("font_size", "Label")
		for multiplier in [1.5, 2.0]:
			panel.add_theme_font_size_override("font_size", roundi(normal_font * multiplier))
			for control in [panel.title_label, panel.status_label, panel.install_button, panel.check_button, panel.notes_button, panel.cancel_button, panel.dismiss_button, panel.automatic_toggle]:
				control.add_theme_font_size_override("font_size", roundi(normal_font * multiplier))
			for frame in 3:
				await process_frame
			check(panel.get_combined_minimum_size().x <= UiMetrics.scaled(280), "larger update fonts remain within narrow dock")
			_assert_action_labels(panel)
		service.state = "downloading"
		service.changed.emit()
		check(panel.install_button.disabled and panel.cancel_button.visible, "download progress/cancellation gates actions")
		service.state = "available"
		service.changed.emit()
		var previous_requests: int = requests["count"]
		panel.install_button.pressed.emit()
		check(panel._confirm.visible and panel._confirm.ok_button_text == "Update & Restart", "installation requires explicit user confirmation")
		check(requests["count"] == previous_requests, "opening confirmation does not request installation")
		panel._confirm.confirmed.emit()
		check(requests["count"] == previous_requests + 1 and requests["operation"] == "install", "confirmation requests the exact install action once")
		panel._confirm.hide()
		if compact:
			panel.dismiss_button.pressed.emit()
			check(service.dismissed() and not panel.visible, "Later action dismisses the main-window notice")
		panel.free()
	service.dismiss()
	var notice := UpdatePanel.new()
	notice.service = service
	notice.compact = true
	root.add_child(notice)
	check(not notice.visible, "dismissed notice stays hidden")
	service.release["version"] = "1.5.0"
	service.changed.emit()
	check(notice.visible, "new version reappears")
	notice.free()
	service.free()
	print("Update editor: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _assert_action_labels(panel) -> void:
	var flow: HFlowContainer = panel.install_button.get_parent()
	for child in flow.get_children():
		var button := child as Button
		if button == null or not button.visible:
			continue
		var font := button.get_theme_font("font")
		var font_size := button.get_theme_font_size("font_size")
		var caption_width := font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var padding := button.get_theme_stylebox("normal").get_minimum_size().x
		check(button.size.x + 1 >= caption_width + padding, "complete update action caption fits: " + button.text)
		var panel_rect: Rect2 = panel.get_global_rect()
		var button_rect := button.get_global_rect()
		check(button_rect.position.x >= panel_rect.position.x and button_rect.end.x <= panel_rect.end.x + 1, "update action stays inside panel: " + button.text)


func _test_general_settings(service) -> void:
	var view := SettingsView.new()
	view.update_service = service
	root.add_child(view)
	view.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var narrow_width := UiMetrics.scaled(300)
	view.size = UiMetrics.scaled_vector(Vector2(300, 850))
	view.system_tab_button.pressed.emit()
	for frame in 4:
		await process_frame
	var panel = view.update_panel
	check(panel.service == service and view.system_scroll.is_ancestor_of(panel), "General Settings uses the shared updater")
	check(panel.get_parent() == view.language_selector.get_parent() and panel.get_index() > view.language_selector.get_index(), "update card follows Language")
	check(panel.is_visible_in_tree() and not view.about_scroll.visible, "General tab reveals update controls")
	check(view.find_children("PluginUpdates", "", true, false).size() == 1, "there is one settings update card")
	var previous_checks: int = service.checks
	panel.check_button.pressed.emit()
	check(service.checks == previous_checks + 1 and panel.check_button.disabled, "General Settings manual check reaches updater")
	view.about_tab_button.pressed.emit()
	for frame in 3:
		await process_frame
	check(view.about_scroll.visible and not panel.is_visible_in_tree() and not view.about_scroll.is_ancestor_of(panel), "About hides update controls and retains its own content")
	check(not view.about_version_label.text.is_empty(), "About retains version information")
	view.system_tab_button.pressed.emit()
	for frame in 3:
		await process_frame
	check(view.update_panel == panel and panel.cancel_button.visible, "returning to General preserves the ongoing check and card identity")
	panel.cancel_button.pressed.emit()
	check(service.state == "available" and not panel.check_button.disabled, "General Settings cancellation remains connected")
	var normal_font: int = panel.get_theme_font_size("font_size", "Label")
	for multiplier in [1.0, 1.5, 2.0]:
		for control in [panel.title_label, panel.status_label, panel.install_button, panel.check_button, panel.notes_button, panel.cancel_button, panel.dismiss_button, panel.automatic_toggle]:
			control.add_theme_font_size_override("font_size", roundi(normal_font * multiplier))
		for height in [850, 600]:
			view.size = UiMetrics.scaled_vector(Vector2(300, height))
			for frame in 4:
				await process_frame
			check(view.get_combined_minimum_size().x <= narrow_width and view.size.x <= narrow_width, "General Settings fits a narrow dock with larger fonts: %.1fx, height %d units, minimum %.0fpx, width %.0fpx" % [multiplier, height, view.get_combined_minimum_size().x, narrow_width])
			var scrollbar: VScrollBar = view.system_scroll.get_v_scroll_bar()
			if height == 600:
				check(scrollbar.visible, "short General Settings fixture exercises vertical scrolling")
			if scrollbar.visible:
				check(panel.get_global_rect().end.x <= scrollbar.get_global_rect().position.x + 1, "update card fits beside the General Settings scrollbar")
			check(panel.get_global_rect().position.y >= view.script_edit_default_selector.get_global_rect().end.y, "update card stays below Script edits after layout")
			_assert_action_labels(panel)
	view.free()


func _test_unsaved_work(plugin) -> void:
	var fixture := "res://.orca_update_editor_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(fixture))
	var script_path := fixture.path_join("unsaved.gd")
	var scene_path := fixture.path_join("unsaved.tscn")
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string("extends Node\n")
	file.close()
	file = FileAccess.open(scene_path, FileAccess.WRITE)
	file.store_string("[gd_scene format=3]\n[node name=\"Fixture\" type=\"Node\"]\n")
	file.close()
	EditorInterface.edit_script(load(script_path), 1, 1, true)
	for frame in 8:
		await process_frame
	var editor := EditorInterface.get_script_editor().get_current_editor()
	var code: CodeEdit = editor.get_base_editor() as CodeEdit if editor != null else null
	if code != null:
		code.text += "# unsaved fixture change\n"
		for frame in 4:
			await process_frame
		check(script_path in EditorInterface.get_script_editor().get_unsaved_files() and plugin._update_readiness().contains("Save"), "actual unsaved script prevents installation")
	else:
		check(false, "script fixture editor available")
	EditorInterface.get_script_editor().close_file(script_path)
	EditorInterface.open_scene_from_path(scene_path)
	for frame in 10:
		await process_frame
	EditorInterface.mark_scene_as_unsaved()
	for frame in 4:
		await process_frame
	check(scene_path in EditorInterface.get_unsaved_scenes() and plugin._update_readiness().contains("Save"), "actual unsaved scene prevents installation")
	EditorInterface.save_scene()
	for frame in 4:
		await process_frame
	EditorInterface.close_scene()
	for frame in 12:
		await process_frame
	check(Package.remove_tree(ProjectSettings.globalize_path(fixture)), "editor update fixture cleanup")
