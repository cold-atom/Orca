@tool
extends "res://tests/editor_test_case.gd"

const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const PLUGIN_NAME := "orca"
const PLUGIN_SCRIPT := "res://addons/orca/orca.gd"
const CHAT_SCRIPT := "res://addons/orca/scripts/chat_window.gd"
const DIAGNOSTICS_SCRIPT := "res://addons/orca/scripts/diagnostics_service.gd"
const GAME_PROCESS_SCRIPT := "res://addons/orca/scripts/game_process_service.gd"
const ACCOUNT_SCRIPT := "res://addons/orca/scripts/account_service.gd"
const UPDATE_SCRIPT := "res://addons/orca/scripts/update_service.gd"
const TOOLBAR_SCRIPT := "res://addons/orca/scenes/open_close.gd"
const LOGO_PATH := "res://addons/orca/assets/orca.svg"
const WAIT_TIMEOUT_MS := 8000

var _failures := PackedStringArray()
var _originally_enabled := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	# Opening/closing real dock tabs must wait for editor startup's own addon
	# activation and layout work, rather than racing a second enable operation.
	for frame in 60:
		await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning():
		await process_frame
	if "--restore-fixture-logo" in OS.get_cmdline_user_args():
		await _test_asset_recovery()
		_finish()
		return
	_originally_enabled = EditorInterface.is_plugin_enabled(PLUGIN_NAME)
	if "--post-update" in OS.get_cmdline_user_args() and not _originally_enabled:
		_expect(false, "first post-update startup must work without manually re-enabling Orca")
		_finish()
		return
	if not _originally_enabled:
		EditorInterface.set_plugin_enabled(PLUGIN_NAME, true)
	var started := await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).size() == 1)
	_expect(started, "Orca should initialize exactly one plugin instance")
	if started:
		_assert_active_plugin("initial activation")
		if _failures.is_empty():
			await _test_dock_open_notifications()
			_test_dock_controls()

	EditorInterface.set_plugin_enabled(PLUGIN_NAME, false)
	var stopped := await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).is_empty())
	_expect(stopped, "disabling Orca should remove the plugin instance")
	_expect(_nodes_with_script(CHAT_SCRIPT).is_empty(), "disabling Orca should remove the chat dock")
	_expect(_nodes_with_script(TOOLBAR_SCRIPT).is_empty(), "disabling Orca should remove the toolbar control")
	_expect(_nodes_with_script(DIAGNOSTICS_SCRIPT).is_empty(), "disabling Orca should remove the diagnostics service")
	_expect(_nodes_with_script(GAME_PROCESS_SCRIPT).is_empty(), "disabling Orca should remove the game process service")
	_expect(_nodes_with_script(ACCOUNT_SCRIPT).is_empty(), "disabling Orca should remove the account service")
	_expect(_nodes_with_script(UPDATE_SCRIPT).is_empty(), "disabling Orca should remove the updater service")
	DiagnosticsService.clear()
	var disabled_marker := "orca-disabled-logger-%d" % Time.get_ticks_usec()
	printerr(disabled_marker)
	await process_frame
	_expect(_marker_count(disabled_marker) == 0, "disabling the final diagnostics service should unregister its logger")

	EditorInterface.set_plugin_enabled(PLUGIN_NAME, true)
	var restarted := await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).size() == 1)
	_expect(restarted, "re-enabling Orca should create exactly one fresh plugin instance")
	if restarted:
		_assert_active_plugin("re-activation")
		if _failures.is_empty():
			await _test_dock_open_notifications()
		DiagnosticsService.clear()
		var restarted_marker := "orca-restarted-logger-%d" % Time.get_ticks_usec()
		printerr(restarted_marker)
		_expect(await _wait_until(func(): return _marker_count(restarted_marker) > 0), "the re-enabled plugin should register a diagnostics logger")
		_expect(_marker_count(restarted_marker) == 1, "the re-enabled plugin should capture each message exactly once")

	if not _originally_enabled:
		EditorInterface.set_plugin_enabled(PLUGIN_NAME, false)
		await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).is_empty())
	_finish()


func _assert_active_plugin(stage: String) -> void:
	var plugins := _nodes_with_script(PLUGIN_SCRIPT)
	_expect(plugins.size() == 1, stage + " should retain one plugin")
	if plugins.size() != 1:
		return
	var plugin = plugins[0]
	var chats := _nodes_with_script(CHAT_SCRIPT)
	var diagnostics := _nodes_with_script(DIAGNOSTICS_SCRIPT)
	var game_services := _nodes_with_script(GAME_PROCESS_SCRIPT)
	var toolbars := _nodes_with_script(TOOLBAR_SCRIPT)
	_expect(chats.size() == 1, stage + " should retain one chat dock")
	_expect(diagnostics.size() == 1, stage + " should retain one diagnostics service")
	_expect(game_services.size() == 1, stage + " should retain one game process service")
	_expect(_nodes_with_script(ACCOUNT_SCRIPT).size() == 1, stage + " should retain one account service")
	_expect(_nodes_with_script(UPDATE_SCRIPT).size() == 1, stage + " should retain one updater service")
	_expect(toolbars.size() == 1, stage + " should retain one toolbar control")
	_expect(plugin.diagnostics_service != null and plugin.diagnostics_service.get_parent() == plugin, stage + " should keep diagnostics plugin-owned")
	_expect(plugin.game_process_service != null and plugin.game_process_service.get_parent() == plugin, stage + " should keep the game service plugin-owned")
	if chats.size() == 1:
		_expect(chats[0].diagnostics_service == plugin.diagnostics_service, stage + " should inject the plugin diagnostics service into the dock")
		_expect(chats[0].game_process_service == plugin.game_process_service, stage + " should inject the plugin game service into the dock")
		_expect(is_instance_valid(chats[0].settings_view), stage + " should finish building Settings")
		if is_instance_valid(chats[0].settings_view):
			_expect(chats[0].account_service == plugin.account_service and chats[0].settings_view.account_service == plugin.account_service and chats[0].agent_controller.account_service == plugin.account_service, stage + " should share plugin-owned account state")
			_expect(chats[0].update_service == plugin.update_service and chats[0].settings_view.update_service == plugin.update_service, stage + " should share one plugin-owned updater")
	_expect(not plugin._get_dock().is_empty(), stage + " should register the chat window in an editor dock")


func _test_dock_open_notifications() -> void:
	var plugin = _nodes_with_script(PLUGIN_SCRIPT)[0]
	var chat = plugin.chat_window
	plugin._set_chat_window_open(false)
	await process_frame
	_expect(not chat._connection_first_open_checked, "hidden initialization should retain first-open intent")
	chat.notify_dock_opened()
	await process_frame
	_expect(not chat._connection_first_open_checked and not chat._connection_overlay.visible, "hidden dock notification should not show setup")
	plugin._set_chat_window_open(true)
	await process_frame
	await process_frame
	_expect(chat._connection_first_open_checked, "actual plugin opening should decide onboarding once")
	plugin._set_chat_window_open(false)
	await process_frame
	_expect(not chat._connection_overlay.visible, "hiding the actual dock should dismiss setup")


func _nodes_with_script(script_path: String) -> Array:
	var matches := []
	_collect_nodes(get_root(), script_path, matches)
	return matches


func _test_dock_controls() -> void:
	var plugin = _nodes_with_script(PLUGIN_SCRIPT)[0]
	var chat = plugin.chat_window
	plugin.toolbar.get_node("TextureButton").pressed.emit()
	_expect(chat.is_visible_in_tree(), "toolbar opens the initialized dock")
	var logo: Texture2D = plugin.toolbar.get_node("TextureButton").texture_normal
	_expect(logo != null and logo.resource_path == LOGO_PATH, "toolbar uses the imported Orca logo")
	_expect(chat.empty_logo.texture is AtlasTexture and chat.empty_logo.texture.atlas != null, "animated logo uses imported artwork")
	chat.prompt_input.insert_text_at_caret("fixture draft")
	chat.settings_button.pressed.emit()
	_expect(chat.settings_view.is_visible_in_tree() and chat.prompt_input.text == "fixture draft", "composer accepts text and Settings opens with the draft intact")


func _test_asset_recovery() -> void:
	var plugins := _nodes_with_script(PLUGIN_SCRIPT)
	_expect(plugins.size() == 1, "the bootstrap remains enabled with a missing asset")
	if plugins.size() != 1: return
	var plugin = plugins[0]
	var fs := EditorInterface.get_resource_filesystem()
	plugin.toolbar.get_node("TextureButton").pressed.emit()
	_expect(plugin._startup_message != null and plugin._startup_message.is_visible_in_tree() and LOGO_PATH in plugin._startup_message.text, "the toolbar opens recovery guidance naming the missing asset")
	_expect(plugin.chat_window == null and plugin.account_service == null and plugin.update_service == null, "no partial chat or background services while waiting")
	# Disable with a filesystem notification already queued; only the fresh
	# plugin may react when the real asset is imported later.
	fs.filesystem_changed.emit()
	EditorInterface.set_plugin_enabled(PLUGIN_NAME, false)
	await process_frame
	_expect(_nodes_with_script(PLUGIN_SCRIPT).is_empty() and _nodes_with_script(TOOLBAR_SCRIPT).is_empty(), "disable while waiting cleans up the shell")
	EditorInterface.set_plugin_enabled(PLUGIN_NAME, true)
	await process_frame
	plugins = _nodes_with_script(PLUGIN_SCRIPT)
	if plugins.size() != 1:
		_expect(false, "re-enable while waiting recreates one plugin")
		return
	plugin = plugins[0]
	plugin._set_chat_window_open(true)
	if not FileAccess.file_exists("res://addons/editor_fixture/plugin.cfg") or FileAccess.file_exists(LOGO_PATH) or DirAccess.rename_absolute("res://.fixture-held-logo", LOGO_PATH) != OK:
		_expect(false, "only restore a held fixture logo to its empty slot")
		return
	fs.scan()
	_expect(await _wait_until(func(): return plugin.chat_window != null and plugin.chat_window.startup_complete), "a real import notification recovers without another restart")
	_assert_active_plugin("repaired asset")
	_expect(plugin.chat_window != null and plugin.chat_window.is_visible_in_tree(), "dock opened during import stays open when ready")


func _collect_nodes(node: Node, script_path: String, matches: Array) -> void:
	var script := node.get_script() as Script
	if script != null and script.resource_path == script_path:
		matches.append(node)
	for child in node.get_children():
		_collect_nodes(child, script_path, matches)


func _marker_count(marker: String) -> int:
	var count := 0
	for record in DiagnosticsService.get_report().get("records", []):
		if str(record.get("message", "")).contains(marker):
			count += 1
	return count


func _wait_until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return predicate.call()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("plugin_lifecycle_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("plugin_lifecycle_test: ", failure)
	quit(1)
