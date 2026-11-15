@tool
extends "res://tests/editor_test_case.gd"

const Service = preload("res://addons/orca/scripts/mcp_service.gd")
const Settings = preload("res://addons/orca/scripts/settings_view.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const McpConfig = preload("res://addons/orca/scripts/mcp_config.gd")
var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var phase := OS.get_environment("ORCA_MCP_EDITOR_PHASE")
	if phase == "migration":
		_migration()
		await _finish()
		return
	var service := Service.new()
	root.add_child(service)
	if phase in ["other_project", "other_restart"]:
		await _cross_project(service, phase)
		service.queue_free()
		await _finish()
		return
	if phase in ["restart", "original_verify", "after_remove"]:
		if phase == "after_remove":
			_check(service.connections.is_empty(), "removed connectors do not reappear from preserved legacy settings")
		else:
			_check(service.connections.size() == 1 and service.connections[0]["name"] == ("Shared connector" if phase == "original_verify" else "Restart fixture"), "canonical connector configuration survives editor/project switches")
		if phase != "after_remove": _check(not service.connections.is_empty() and service.connections[0]["profile"] == "blender_lab", "official profile survives restart without migration")
		_check(service._clients.is_empty() and service.snapshot()["servers"].is_empty(), "restart never launches a saved executable")
		if phase == "original_verify" and not service.connections.is_empty():
			_check(service.remove_connection(service.connections[0]["id"], service.registry_snapshot()), "explicit removal deletes only the canonical connector")
		service.queue_free()
		await _finish()
		return
	var host := Window.new()
	host.size = Vector2i(Metrics.scaled_int(300), Metrics.scaled_int(650))
	root.add_child(host)
	var settings := Settings.new()
	settings.mcp_service = service
	host.add_child(settings)
	settings._show_section("extensions")
	var page = settings.extensions_view
	_check(settings.extensions_tab_button.icon == Settings.EXTENSIONS_ICON and page.visible and not settings.system_scroll.visible, "extension icon and independent section")
	_check(page._main.visible and page.blender_panel.is_visible_in_tree() and not page.blender_panel._actions.visible, "Extensions exposes compact asset setup before optional connectors")
	_check(settings.extensions_tab_button.tooltip_text == Localization.message("Extensions"), "Settings names the umbrella section Extensions")
	page._configure({})
	var dialog = page._dialog
	_check(dialog._blender_help.visible and dialog._purpose.visible, "official connector displays installation checklist and asset-creation guidance")
	dialog.profile_selector.select(2)
	dialog.profile_selector.item_selected.emit(2)
	_check(not dialog._blender_help.visible and not dialog._purpose.visible, "custom MCP setup does not receive Blender-specific installation help")
	dialog.profile_selector.select(0)
	dialog.profile_selector.item_selected.emit(0)
	dialog.command_input.text = ""
	dialog._confirmed()
	_check(not dialog._error.text.is_empty() and dialog.visible and service.connections.is_empty(), "invalid setup remains visible in focused dialog without starting a server")
	dialog.name_input.text = "Fixture"
	dialog.command_input.text = "/usr/bin/python3"
	dialog.arguments_input.text = JSON.stringify([ProjectSettings.globalize_path("res://tests/mcp_fixture.py")])
	dialog.profile_selector.select(1)
	dialog._confirmed()
	_check(service.connections.size() == 1, "actual canonical computer-local EditorSettings save")
	_check(service.connections[0]["profile"] == "blender", "existing community selection retains its stored identity")
	var id: String = service.connections[0]["id"]
	var live_executable := OS.get_environment("ORCA_BLENDER_LAB_LIVE_EXECUTABLE")
	page._configure(service.connection(id))
	dialog.profile_selector.select(0)
	dialog.command_input.text = live_executable if not live_executable.is_empty() else "/usr/bin/python3"
	dialog.arguments_input.text = "[]" if not live_executable.is_empty() else JSON.stringify([ProjectSettings.globalize_path("res://tests/mcp_fixture.py"), "lab_mixed"])
	dialog._confirmed()
	_check(dialog.profile_selector.get_selected_metadata() == "blender_lab" and service.connections[0]["profile"] == "blender_lab", "explicit official type is preserved")
	var restored := Service.new()
	root.add_child(restored)
	_check(restored.connections == service.connections and restored.snapshot()["servers"].is_empty(), "saved descriptions restore without launch or authorization")
	restored.queue_free()
	var launch: Dictionary = service.prepare_launch(service.connection(id))
	var changed := launch.duplicate(true)
	changed["root"] = "/another-project"
	_check(not (await service.connect_server(changed)).get("success", false) and service._clients.is_empty(), "launch decision rechecks exact project and immutable action")
	launch = service.prepare_launch(service.connection(id))
	changed = launch.duplicate(true)
	changed["service_id"] += 1
	_check(not (await service.connect_server(changed)).get("success", false), "launch cannot move to a different service")
	page._cards[id]._action.pressed.emit()
	_check(service.status(id)["state"] == "connecting" and not page._cards[id]._action.disabled, "connecting state exposes an explicit Cancel action")
	page._cards[id]._action.pressed.emit()
	for frame in 8: await process_frame
	_check(service.status(id)["state"] == "disconnected" and service._clients[id]._child.is_empty() and not service._clients[id].settling(), "Cancel settles connection startup without replay or lost ownership")
	page._cards[id]._action.pressed.emit()
	var original_pid: int = service._clients[id]._child["pid"]
	page._enable(service.connection(id))
	_check(service._clients[id]._child["pid"] == original_pid, "double Enable cannot spawn a replacement bridge")
	_check(not dialog.visible, "explicit Enable starts a connector without an extra configuration/import dialog")
	for frame in 300:
		if service.status(id)["state"] != "connecting": break
		await process_frame
	_check(service.status(id)["state"] == "connected", "real stdio connection from UI")
	var catalog: Dictionary = service.snapshot().get("servers", {}).get(id, {})
	_check(catalog.get("inspection_tools", {}) == Service.PROFILE_READS["blender_lab"], "UI connection discovers exact official inspection tools")
	var before_save := service.snapshot()
	_check(service.save_connection(service.connection(id), service.registry_snapshot()) and service.snapshot() == before_save, "unchanged Configure save leaves the current process and turn snapshot intact")
	page._configure(service.connection(id))
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for factor in [1.0, 1.5, 2.0]:
			_scale_fonts(settings, factor)
			for frame in 8: await process_frame
			_check(settings.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "narrow Extensions minimum " + locale + str(factor))
			_check(page._main.get_h_scroll_bar().max_value <= page.size.x + 1, "no horizontal scroll " + locale + str(factor))
			_check(dialog.name_input.text == "Fixture" and page._cards[id].config["id"] == id, "live language refresh preserves exact configuration")
			_check(dialog.profile_selector.get_selected_metadata() == "blender_lab", "language refresh preserves official profile " + locale)
			_check(page._cards[id]._action.text == Localization.message("Disable"), "connector action is localized without changing its decision " + locale)
			_check(page._cards[id]._status.text == Localization.message("MCP connected — inspection"), "connected state explicitly describes inspection " + locale)
			_check(dialog._body.get_combined_minimum_size().x <= Metrics.scaled(300), "focused dialog minimum fits narrow/large-font layout " + locale + str(factor))
	_scale_fonts(settings, 1.0)
	Localization.select_language("en")
	dialog.hide()
	for frame in 8: await process_frame
	if not OS.get_environment("ORCA_MCP_PREVIEW").is_empty() and DisplayServer.get_name() != "headless":
		host.get_texture().get_image().save_png(OS.get_environment("ORCA_MCP_PREVIEW"))
	host.hide()
	var editor_settings := EditorInterface.get_editor_settings()
	editor_settings.set_setting(Config.SETTING_PROVIDER, "openai")
	editor_settings.set_setting("orca/providers/openai/api_key", "synthetic-not-a-real-key")
	editor_settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	var view = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	view.mcp_service = service
	root.add_child(view)
	for frame in 8: await process_frame
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view._start_new_session()
	var controller = view.agent_controller
	controller.send_user_message("Inspect the connected Blender scene.")
	_check(client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "inspect_mcp"), "connected Work request offers bounded MCP schema")
	var call := {"id": "mcp_read_1", "type": "function", "function": {"name": "inspect_mcp", "arguments": JSON.stringify({"server_id": id, "operation": "blender_scene"})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	_check(not controller._pending_mcp_read.is_empty() and client.requests.size() == 1, "provider continuation waits for actual read review")
	var card = view._tool_cards.get("mcp_read_1")
	if card != null and card.has_method("_choose"):
		_check(card._details.text.contains("get_objects_summary") and card._details.text.contains("blender_lab"), "actual approval card identifies the official scene tool")
		for locale in Localization.LOCALES:
			Localization.select_language(locale)
			for factor in [1.0, 1.5, 2.0]:
				_scale_fonts(card, factor)
				for frame in 3: await process_frame
				_check(card.get_combined_minimum_size().x <= Metrics.scaled(280), "read card narrow layout " + locale + str(factor))
		card._allow.pressed.emit()
	for frame in 300:
		if client.requests.size() >= 2: break
		await process_frame
	_check(client.requests.size() == 2 and _receipts(controller, "mcp_read_1").size() == 1, "approved read continues exactly once with matching tool receipt")
	var scene_receipts := _receipts(controller, "mcp_read_1")
	var scene_content := str(scene_receipts[0].get("content", "")) if not scene_receipts.is_empty() else ""
	_check(scene_content.contains('"Camera"') and scene_content.contains('"Cube"') and scene_content.contains('"Light"'), "official scene evidence reaches the matched provider receipt")
	if live_executable.is_empty():
		_check(JSON.stringify(client.requests.back()["messages"]).contains("café 木"), "actual external UTF-8 evidence reaches follow-up")
	client.complete({"role": "assistant", "content": "Inspected the fixture scene."})
	for frame in 4: await process_frame
	_check(controller._turn_mcp_snapshot.is_empty(), "terminal cleanup removes capability snapshot")
	var events: Array = view._session["events"].filter(func(event): return event.get("name") == "inspect_mcp")
	_check(events.size() == 1 and events[0]["arguments"].is_empty() and not JSON.stringify(events).contains("café"), "history retains only coarse non-replayable receipt")
	controller.send_user_message("Inspect the Blender data-block summary.")
	call["id"] = "mcp_summary"
	call["function"]["arguments"] = JSON.stringify({"server_id": id, "operation": "blender_status"})
	var requests_before := client.requests.size()
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	card = view._tool_cards.get("mcp_summary")
	_check(card != null and card._details.text.contains("get_blendfile_summary_datablocks"), "data-block review names the exact official summary tool")
	if card != null: card._allow.pressed.emit()
	for frame in 300:
		if client.requests.size() > requests_before: break
		await process_frame
	var summary_receipts := _receipts(controller, "mcp_summary")
	_check(client.requests.size() == requests_before + 1 and summary_receipts.size() == 1 and str(summary_receipts[0].get("content", "")).contains("datablock_counts"), "official summary continues with exactly one matching receipt")
	client.complete({"role": "assistant", "content": "Inspected the data-block summary."})
	for frame in 4: await process_frame
	controller.send_user_message("Reject another scene read.")
	call["id"] = "mcp_reject"
	call["function"]["arguments"] = JSON.stringify({"server_id": id, "operation": "blender_scene"})
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	card = view._tool_cards.get("mcp_reject")
	if card != null: card._reject.pressed.emit()
	for frame in 4: await process_frame
	var rejected := _receipts(controller, "mcp_reject")
	_check(rejected.size() == 1 and str(rejected[0].get("content", "")).contains("rejected before sending"), "actual Reject card settles official read without dispatch")
	client.complete({"role": "assistant", "content": "Read rejected."})
	for frame in 4: await process_frame
	controller.send_user_message("Inspect again.")
	call["id"] = "mcp_stop"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	controller.cancel_current_request()
	for frame in 4: await process_frame
	_check(not controller.is_busy() and _receipts(controller, "mcp_stop").size() == 1, "Stop during review settles one matching receipt")
	controller.send_user_message("Read once more.")
	call["id"] = "mcp_reentry"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	controller.request_cancelled.connect(func(_turn): controller.send_user_message("New turn after cancellation."), CONNECT_ONE_SHOT)
	controller.cancel_current_request()
	for frame in 3: await process_frame
	_check(controller.is_busy() and client.requesting, "cancelled-read terminal reentry does not cancel the new turn")
	client.complete({"role": "assistant", "content": "New turn complete."})
	controller.set_mode(0)
	controller.send_user_message("Plan only.")
	_check(not client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "inspect_mcp"), "Plan omits MCP inspection")
	call["id"] = "mcp_plan"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(_receipts(controller, "mcp_plan").size() == 1 and controller._pending_mcp_read.is_empty(), "direct Plan MCP call denied at runtime")
	client.complete({"role": "assistant", "content": "Plan complete."})
	_check(service.remove_connection(id, service.registry_snapshot()), "user-owned removal stops the current connector")
	_check(service.save_connection({"id": "restart_fixture", "name": "Restart fixture", "command": live_executable if not live_executable.is_empty() else "/usr/bin/python3", "arguments": [] if not live_executable.is_empty() else [ProjectSettings.globalize_path("res://tests/mcp_fixture.py"), "lab"], "profile": "blender_lab"}, service.registry_snapshot()), "Save alone configures all projects without launch")
	view.queue_free()
	for frame in 5: await process_frame
	_check(service.snapshot()["servers"].is_empty(), "dock teardown disconnects owned bridge")
	host.queue_free()
	service.queue_free()
	Localization.select_language("en")
	await _finish()


func _cross_project(service: Node, phase: String) -> void:
	_check(service._clients.is_empty() and service.snapshot()["servers"].is_empty(), "different-root startup never launches or restores capability authority")
	_check(service.connections.size() == 1, "same canonical connector is available in B without importing or copying")
	if service.connections.is_empty():
		return
	var config: Dictionary = service.connections[0].duplicate(true)
	if phase == "other_restart":
		_check(config["name"] == "Shared connector", "configuration edits are computer-local and survive B restart")
		return
	var original_root := OS.get_environment("ORCA_MCP_ORIGINAL_ROOT")
	var host := Window.new()
	host.size = Vector2i(Metrics.scaled_int(300), Metrics.scaled_int(650))
	root.add_child(host)
	var settings := Settings.new()
	settings.mcp_service = service
	host.add_child(settings)
	settings._show_section("extensions")
	var page = settings.extensions_view
	var id: String = config["id"]
	_check(page._cards.size() == 1 and page._main.visible and page.blender_panel.is_visible_in_tree() and not page.blender_panel._actions.visible, "B shows the same connector and independently available asset setup")
	var launch: Dictionary = service.prepare_launch(config)
	launch["root"] = original_root
	var denied: Dictionary = await service.connect_server(launch)
	_check(not denied["success"] and service._clients.is_empty(), "runtime launch gate rejects another project's approval")
	page._cards[id]._action.pressed.emit()
	for frame in 300:
		if service.status(id)["state"] != "connecting": break
		await process_frame
	_check(service.status(id)["state"] == "connected", "B launches fresh owned bridge through visible reconnect UI")
	var snapshot: Dictionary = service.snapshot()
	var tampered := snapshot.duplicate(true)
	tampered["project_root"] = original_root
	var arguments := {"server_id": id, "operation": "blender_scene"}
	_check(not service.prepare_inspection(tampered, arguments)["success"], "another project's turn snapshot cannot authorize inspection")
	denied = await service.inspect(snapshot, arguments, false)
	_check(not denied["success"], "reuse does not grant external read approval")
	var other := Service.new()
	root.add_child(other)
	_check(other._clients.is_empty(), "simultaneous service does not adopt B's live process")
	var second: Dictionary = await other.connect_server(other.prepare_launch(config))
	_check(second.get("success", false) and service._clients[id]._child["pid"] != other._clients[id]._child["pid"], "each service retains a distinct direct bridge PID")
	var borrowed: Dictionary = other.snapshot()
	borrowed["generation"] = service.snapshot()["generation"]
	_check(not service.prepare_inspection(borrowed, arguments)["success"], "same-root same-generation snapshots cannot transfer across services")
	other.shutdown()
	other.queue_free()
	_check(service.status(id)["state"] == "connected", "disconnecting another service preserves B's connection")
	page._configure(config)
	page._dialog.name_input.text = "Shared connector"
	page._dialog._confirmed()
	_check(service.status(id)["state"] == "disconnected" and service.connections.size() == 1, "Configure changes require an explicit new Enable, never silent retargeting")
	page._cards[id]._action.pressed.emit()
	for frame in 300:
		if service.status(id)["state"] != "connecting": break
		await process_frame
	_check(service.status(id)["state"] == "connected", "B can explicitly re-enable edited canonical setup")
	await _cross_project_read(service, id)
	_check(service.snapshot()["servers"].is_empty(), "B dock teardown stops its bridge")
	_check(page.blender_panel.is_visible_in_tree() and page._main.visible, "asset setup remains directly accessible after MCP teardown")
	host.queue_free()
	for frame in 8: await process_frame


func _migration() -> void:
	var settings := EditorInterface.get_editor_settings()
	var lab := {"id": "legacy_lab", "name": "Blender Lab", "command": "/usr/bin/python3", "arguments": [ProjectSettings.globalize_path("res://tests/mcp_fixture.py"), "lab"], "profile": "blender_lab"}
	var alias := lab.duplicate(true)
	alias["id"] = "old_alias"
	settings.set_setting(McpConfig.LIBRARY_SETTING, {"version": 1, "connections": [lab, alias]})
	var original := {"version": 1, "root": McpConfig.project_root(), "connections": [lab]}
	var key := McpConfig.PROJECT_PREFIX + McpConfig.project_root().sha256_text()
	settings.set_setting(key, original)
	var other_root := McpConfig.project_root().path_join("older-project")
	var variant := lab.duplicate(true)
	variant["profile"] = "blender"
	var other_key := McpConfig.PROJECT_PREFIX + other_root.sha256_text()
	settings.set_setting(other_key, {"version": 1, "root": other_root, "connections": [variant]})
	var service := Service.new()
	root.add_child(service)
	_check(service.connections.size() == 2 and service._clients.is_empty(), "automatic migration deduplicates descriptions, preserves different profiles and never starts a server")
	_check(service.connections.map(func(entry): return entry["id"]).size() == 2 and service.connections[0]["id"] != service.connections[1]["id"], "migration resolves old ID collisions without overwriting variants")
	_check(settings.get_setting(key) == original, "legacy source records are preserved")
	var record := service.registry_snapshot()
	_check(record["version"] == McpConfig.VERSION and not record.has("enabled"), "canonical registry stores no launch authority")
	var same := McpConfig.load_registry()
	_check(same == record, "repeated migration is idempotent")
	var edited := service.connections[0].duplicate(true)
	edited["name"] = "Configured alias"
	_check(service.save_connection(edited, record), "configuration edits use the exact registry baseline")
	_check(not service.save_connection(lab, record) and service.connection(edited["id"]) == edited, "stale configuration save cannot overwrite newer setup")
	for config in service.connections.duplicate(true):
		_check(service.remove_connection(config["id"], service.registry_snapshot()), "explicitly remove migrated connector")
	service.refresh_connectors()
	_check(service.connections.is_empty() and settings.get_setting(key) == original, "removal fingerprints prevent preserved legacy records from resurrecting")
	var valid: Dictionary = settings.get_setting(McpConfig.LIBRARY_SETTING).duplicate(true)
	for malformed in [{"version": 3, "connections": []}, {"version": 2, "revision": 1, "connections": [lab, lab], "legacy_seen": []}, {"version": 2, "revision": 1, "connections": [], "legacy_seen": [], "enabled": true}]:
		settings.set_setting(McpConfig.LIBRARY_SETTING, malformed)
		_check(McpConfig.load_registry().is_empty() and settings.get_setting(McpConfig.LIBRARY_SETTING) == malformed, "malformed/future records are preserved and cannot grant connector startup")
	settings.set_setting(McpConfig.LIBRARY_SETTING, valid)
	var candidates := []
	for index in 17:
		var candidate := lab.duplicate(true)
		candidate["id"] = "entry_%d" % index
		candidate["name"] = "Connector %d" % index
		candidates.append({"source": "source_%d" % index, "config": candidate})
	var bounded := McpConfig.migrate(McpConfig.empty_registry(), candidates)
	_check(bounded["connections"].size() == 16, "migration respects connector count without deleting source records")
	service.queue_free()


func _cross_project_read(service: Node, id: String) -> void:
	var view = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	view.mcp_service = service
	root.add_child(view)
	for frame in 8: await process_frame
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view._start_new_session()
	var controller = view.agent_controller
	controller.send_user_message("Inspect Blender after changing projects.")
	client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "b_scene", "type": "function", "function": {"name": "inspect_mcp", "arguments": JSON.stringify({"server_id": id, "operation": "blender_scene"})}}]})
	for frame in 4: await process_frame
	var card = view._tool_cards.get("b_scene")
	_check(card != null and not controller._pending_mcp_read.is_empty(), "B scene read waits for a real current-turn approval card")
	if card != null: card._allow.pressed.emit()
	for frame in 300:
		if client.requests.size() > 1: break
		await process_frame
	var receipts := _receipts(controller, "b_scene")
	_check(receipts.size() == 1 and str(receipts[0].get("content", "")).contains('"Cube"'), "approved B scene read reaches exactly one matching provider receipt")
	client.complete({"role": "assistant", "content": "Scene inspected in B."})
	for frame in 4: await process_frame
	view.queue_free()
	for frame in 8: await process_frame


func _finish() -> void:
	for frame in 8: await process_frame
	for failure in failures: print("FAIL: ", failure)
	print("mcp_editor_test: PASS" if failures.is_empty() else "mcp_editor_test: FAIL")
	quit(0 if failures.is_empty() else 1)


func _receipts(controller, id: String) -> Array:
	return controller.message_history.filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == id)


func _scale_fonts(node: Node, factor: float) -> void:
	if node is Label or node is Button or node is LineEdit or node is TextEdit:
		if not node.has_meta("mcp_test_font"):
			node.set_meta("mcp_test_font", node.get_theme_font_size("font_size"))
		node.add_theme_font_size_override("font_size", int(node.get_meta("mcp_test_font") * factor))
	for child in node.get_children():
		_scale_fonts(child, factor)


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
