extends SceneTree

const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const PLUGIN_NAME := "orca"
const PLUGIN_SCRIPT := "res://addons/orca/orca.gd"
const CHAT_SCRIPT := "res://addons/orca/scripts/chat_window.gd"
const DIAGNOSTICS_SCRIPT := "res://addons/orca/scripts/diagnostics_service.gd"
const GAME_PROCESS_SCRIPT := "res://addons/orca/scripts/game_process_service.gd"
const TOOLBAR_SCRIPT := "res://addons/orca/scenes/open_close.gd"
const WAIT_TIMEOUT_MS := 8000

var _failures := PackedStringArray()
var _originally_enabled := false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Engine.is_editor_hint(), "this test must run with --editor")
	_originally_enabled = EditorInterface.is_plugin_enabled(PLUGIN_NAME)
	if not _originally_enabled:
		EditorInterface.set_plugin_enabled(PLUGIN_NAME, true)
	var started := await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).size() == 1)
	_expect(started, "Orca should initialize exactly one plugin instance")
	if started:
		_assert_active_plugin("initial activation")

	EditorInterface.set_plugin_enabled(PLUGIN_NAME, false)
	var stopped := await _wait_until(func(): return _nodes_with_script(PLUGIN_SCRIPT).is_empty())
	_expect(stopped, "disabling Orca should remove the plugin instance")
	_expect(_nodes_with_script(CHAT_SCRIPT).is_empty(), "disabling Orca should remove the chat dock")
	_expect(_nodes_with_script(TOOLBAR_SCRIPT).is_empty(), "disabling Orca should remove the toolbar control")
	_expect(_nodes_with_script(DIAGNOSTICS_SCRIPT).is_empty(), "disabling Orca should remove the diagnostics service")
	_expect(_nodes_with_script(GAME_PROCESS_SCRIPT).is_empty(), "disabling Orca should remove the game process service")
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
	_expect(toolbars.size() == 1, stage + " should retain one toolbar control")
	_expect(plugin.diagnostics_service != null and plugin.diagnostics_service.get_parent() == plugin, stage + " should keep diagnostics plugin-owned")
	_expect(plugin.game_process_service != null and plugin.game_process_service.get_parent() == plugin, stage + " should keep the game service plugin-owned")
	if chats.size() == 1:
		_expect(chats[0].diagnostics_service == plugin.diagnostics_service, stage + " should inject the plugin diagnostics service into the dock")
		_expect(chats[0].game_process_service == plugin.game_process_service, stage + " should inject the plugin game service into the dock")
	_expect(not plugin._get_dock().is_empty(), stage + " should register the chat window in an editor dock")


func _nodes_with_script(script_path: String) -> Array:
	var matches := []
	_collect_nodes(get_root(), script_path, matches)
	return matches


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
