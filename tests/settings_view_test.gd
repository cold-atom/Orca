extends SceneTree

const SettingsView = preload("res://addons/orca/scripts/settings_view.gd")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	get_root().size = Vector2i(300, 700)
	var view := SettingsView.new()
	get_root().add_child(view)
	await process_frame
	await process_frame

	_expect(view.settings_scroll.visible and not view.about_scroll.visible, "provider settings should be the default section")
	_expect(view.provider_tab_button.button_pressed and not view.about_tab_button.button_pressed, "the Provider tab should be selected by default")
	view.about_tab_button.emit_signal("pressed")
	await process_frame
	_expect(not view.settings_scroll.visible and view.about_scroll.visible, "the About tab should replace provider settings")
	_expect(view.about_tab_button.button_pressed, "the About tab should show its selected state")
	_expect(view.about_version_label.text == "Version 1.1.0", "the About page should read the release version from plugin.cfg")
	var compatibility := view.find_child("AboutCompatibility", true, false) as Label
	var license := view.find_child("AboutLicense", true, false) as Label
	var logo := view.find_child("AboutLogo", true, false) as TextureRect
	_expect(compatibility != null and compatibility.text == "Godot 4.7.2", "the About page should state supported Godot compatibility")
	_expect(license != null and license.text.contains("MIT License"), "the About page should state the plugin license")
	_expect(logo != null and logo.texture != null, "the About page should display the Orca mark")
	_expect(view.get_combined_minimum_size().x <= 300.0, "the Settings and About pages should fit the 300 px dock width")

	view.provider_tab_button.emit_signal("pressed")
	await process_frame
	_expect(view.settings_scroll.visible and not view.about_scroll.visible, "the Provider tab should restore provider settings")
	view.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("settings_view_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("settings_view_test: ", failure)
	quit(1)
