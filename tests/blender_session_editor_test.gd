@tool
extends "res://tests/editor_test_case.gd"

const Mcp = preload("res://addons/orca/scripts/mcp_service.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
var failures: Array[String] = []
var service
var view
var controller
var client
var config := {}
var call_serial := 0


func _ready() -> void:
	call_deferred("_run")


func _check(value: bool, message: String) -> void:
	if not value: failures.append(message); printerr("blender_session_editor_test: ", message)


func _wait(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 35000
	while not predicate.call() and Time.get_ticks_msec() < deadline: await process_frame
	return predicate.call()


func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("orca/providers/selected", "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	service = Mcp.new()
	root.add_child(service)
	var arguments := [ProjectSettings.globalize_path("res://tests/blender_live_fixture.py")]
	var native := OS.get_environment("ORCA_BLENDER_SESSION_LIVE_EXECUTABLE")
	if not native.is_empty(): arguments.append_array([native, OS.get_environment("ORCA_BLENDER_SESSION_MCP_EXECUTABLE")])
	config = {"id": "live_fixture", "name": "Blender Lab", "profile": "blender_lab", "command": "/usr/bin/python3", "arguments": arguments}
	_check(service.save_connection(config, service.registry_snapshot()), "save setup")
	_check((await service.connect_server(service.prepare_launch(config))).get("success", false), "real stdio connection")
	view = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	view.mcp_service = service
	var host := Window.new()
	host.size = Vector2i(Metrics.scaled_int(320), Metrics.scaled_int(700))
	root.add_child(host)
	host.add_child(view)
	for frame in 8: await process_frame
	controller = view.agent_controller
	client = Component.Client.new()
	controller.set_api_client_for_testing(client)
	view._start_new_session()
	var page = view.settings_view.extensions_view
	_check(not service.snapshot()["servers"][config["id"]].get("live_authoring", false), "Connect alone never grants editing")
	controller.set_mode(0)
	_check(service.prepare_live_enable(config).is_empty(), "Plan cannot enable authoring")
	controller.set_mode(1)
	var action: Dictionary = service.prepare_live_enable(config)
	var tampered := action.duplicate(true)
	tampered["root"] = "/other/project"
	_check(not (await service.enable_live_authoring(tampered)).get("success", false), "exact root/confirmation binding")
	page._menu(3, config)
	await _check_confirmation_layout(page._live_confirmation, host)
	page._live_confirmation.canceled.emit()
	page._live_confirmation.hide()
	_check(not service.snapshot()["servers"][config["id"]].get("live_authoring", false), "dismissed confirmation grants nothing")
	page._menu(3, config)
	page._live_confirmation.confirmed.emit()
	_check(await _wait(func(): return not service._live_starting.has(config["id"])), "setup settles")
	var session = service.live_session(config["id"])
	_check(session != null and session.state == "connected", "actual user-owned live authoring setup: " + str(page._notice.text))
	if session == null or session.state != "connected":
		await _finish(host)
		return
	var original: Dictionary = session.current.duplicate(true)
	var too_many := []
	too_many.resize(17)
	for item in [[{"operation": "help", "commands": '["unknown"]'}, "server_id"], [{"operation": "edit", "commands": "broken JSON"}, "valid JSON"], [{"operation": "edit", "commands": "[]"}, "Empty edit"], [{"operation": "edit", "commands": JSON.stringify(too_many)}, "17 commands; none ran"]]:
		var invalid: Dictionary = session.prepare(session.snapshot(), item[0])
		_check(not invalid["success"] and item[1] in invalid["error"] and session.current == original, "live validation gives a specific correction before dispatch")
	_check(not (await session.execute({"operation": "import", "review_id": "forged"}, func(): return true)).get("success", false), "sealed review is checked before external handoff inspection")
	var denied: Dictionary = await controller._inspect_live_blender({"server_id": config["id"], "operation": "inspect"}, "plan_denial", 1, 0)
	_check(not denied.get("success", false), "direct Plan runtime denial")
	var mixed := [_tool({"operation": "inspect"}), {"id": "project_read", "function": {"name": "read_file", "arguments": "{}"}}]
	_check(not controller._validate_tool_batch(mixed).get("success", false), "live calls are standalone even alongside read-only tools")
	var live_script = preload("res://addons/orca/scripts/blender_session_service.gd")
	for malformed in [{"content": [{"type": "text", "text": "not json"}]}, {"content": [{"type": "text", "text": '{"status":"error"}'}]}, {"content": [{"type": "text", "text": '{"ok":"true"}'}]}, {"content": [{"type": "text", "text": '{"ok":false,"completed_commands":{}}'}]}]:
		var invalid_result: Dictionary = live_script.decode({"success": true, "result": malformed})
		_check(not invalid_result.get("success", false) and invalid_result.get("data", {}).get("uncertain", false), "malformed accepted output remains uncertain, not successful")
	_check(session.capabilities.size() == 26 and not session.capabilities.has("reset") and not session.capabilities.has("scene"), "fixed live vocabulary excludes global document reset/settings")
	_check(page._cards[config["id"]]._role.text == Localization.message("Live Blender · Create & edit"), "capability-aware role")
	_check(controller.set_auto_apply_enabled(true), "existing script Auto apply fixture")
	controller.set_blender_auto_apply_enabled(true)
	var commands := JSON.stringify([{"op": "primitive", "name": "LiveProp", "kind": "cube"}, {"op": "material", "name": "LiveProp", "material": "Blue", "color": [0.1, 0.5, 0.9, 1]}])
	await _call({"operation": "edit", "commands": commands}, true, func(card):
		_check(session.current == original and card._auto_button != null and card._auto_button.text == Localization.message("Auto apply live session…") and not card._automatic, "workspace/script grants never bypass live review; live grant has its own button")
		_check(card._overview.text.contains("LiveProp") and card._overview.text.contains(session.current["document"]), "review identifies document and exact operations"))
	_check(session.current["revision"] == 2 and session.current["objects"].any(func(v): return v["name"] == "LiveProp"), "reviewed creation reaches live Blender")
	var after: Dictionary = session.current.duplicate(true)
	await _call({"operation": "edit", "commands": JSON.stringify([{"op": "transform", "name": "LiveProp", "location": [2, 0, 0]}])}, false)
	_check(session.current == after, "Reject preserves live state")
	await _exercise_live_auto_apply(session, host)
	await _exercise_cloud_command_correction(session)
	var escaped := []
	for index in 16:
		escaped.append({"op": "primitive", "kind": "cube", "name": "Escaped_%02d_" % index + "\"\\".repeat(20), "location": [index, 0, 0]})
	var escaped_commands := JSON.stringify(escaped)
	var framed := JSON.stringify({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "execute_blender_code", "arguments": {"code": session._call_code({"operation": "edit", "revision": session.current["revision"], "sha256": session.current["sha256"], "commands": escaped_commands})}}})
	_check(escaped_commands.to_utf8_buffer().size() <= 6000 and framed.to_utf8_buffer().size() > 8192, "bounded declarative input exercises larger trusted escaped framing")
	await _call({"operation": "edit", "commands": escaped_commands})
	_check(session.current["objects"].size() >= 18, "escaped names remain native data and fit the trusted request budget")
	await _call({"operation": "preview", "objects": ["LiveProp"]})
	_check(not session.preview_image.is_empty(), "native/synthetic preview enters existing viewer path")
	await _call({"operation": "export", "objects": ["LiveProp"]})
	_check(session.artifacts.size() == 1, "export validates and registers a session artifact")
	if not session.artifacts.is_empty():
		var artifact: String = session.artifacts.keys()[0]
		var invalid: Dictionary = service.prepare_live_operation(service.snapshot(), {"server_id": config["id"], "operation": "import", "artifact_id": artifact, "destination": "res://addons/orca/Forbidden.glb"})
		_check(not invalid.get("success", false), "protected project destinations remain denied")
		await _call({"operation": "import", "artifact_id": artifact, "destination": "res://LiveProp.glb"})
		_check(FileAccess.file_exists("res://LiveProp.glb") and session.last_import.get("import_verified", false), "reviewed source save and actual Godot import")
		EditorInterface.open_scene_from_path("res://tests/fixtures/blender_workspace_scene.tscn")
		for frame in 30: await process_frame
		await _call({"operation": "place"})
		_check(EditorInterface.get_edited_scene_root().get_child_count() == 1, "same reviewed native scene-placement path")
		_check(session.revert_import(true).get("success", false) and not FileAccess.file_exists("res://LiveProp.glb"), "current-session import recovery remains conflict checked")
	view._on_edit_permission_pressed()
	_check(not controller.live_auto_apply_enabled() and not controller.auto_apply_enabled() and not controller.blender_auto_apply_enabled() and session.state == "connected", "header revokes all automation without disconnecting live authoring")
	await _exercise_live_auto_apply(session, host)
	await _exercise_automatic_conflict(session)
	_check(not controller.live_auto_apply_enabled() and session.state == "connected", "automatic conflicts pause the grant without silently reacquiring it")
	await _exercise_live_auto_apply(session, host)
	session.current["sha256"] = "e".repeat(64)
	await _call({"operation": "inspect"})
	_check(not controller.live_auto_apply_enabled(), "fresh inspection of intervening live changes pauses automation")
	await _exercise_live_auto_apply(session, host)
	controller.set_mode(0)
	_check(not controller.live_auto_apply_enabled() and service.live_session(config["id"]) == null, "Plan clears live authoring and its automation scope")
	controller.set_mode(1)
	page._menu(3, config)
	page._live_confirmation.confirmed.emit()
	_check(await _wait(func(): return not service._live_starting.has(config["id"])), "explicit re-enable after Plan settles")
	session = service.live_session(config["id"])
	_check(session != null and session.state == "connected" and not controller.live_auto_apply_enabled(), "reconnecting authoring never inherits a previous live grant: " + str(page._notice.text))
	if session == null or session.state != "connected":
		await _finish(host)
		return
	await _exercise_live_auto_apply(session, host)
	var active: Dictionary = service.snapshot()
	controller.send_user_message("Cancel a reviewed live edit")
	var cancel_call := _tool({"operation": "inspect"})
	client.complete({"role": "assistant", "content": "", "tool_calls": [cancel_call]})
	for frame in 3: await process_frame
	controller.cancel_current_request()
	_check(await _wait(func(): return not controller.is_busy()), "Stop settles pending review")
	_check(_receipts(cancel_call["id"]).size() == 1, "Stop retains exactly one matching tool result")
	_check(not controller.live_auto_apply_enabled(config["id"]), "Stop revokes live automation")
	_check(service.prepare_live_operation(active, {"server_id": config["id"], "operation": "inspect", "code": "evil"}).get("success", false) == false, "direct runtime rejects Python fields")
	controller._turn_provider_config = {"provider": "orca_cloud", "hosted_blender_workspaces": true, "hosted_mcp_inspection": true}
	_check(not controller._turn_allows_live_blender(), "old Cloud flags cannot grant live vocabulary")
	controller._turn_provider_config.clear()
	view._start_new_session()
	_check(service.live_session(config["id"]) == null and not service.snapshot().get("servers", {}).get(config["id"], {}).get("live_authoring", false), "New Session clears all live authority")
	if service.status(config["id"])["state"] != "connected":
		_check((await service.connect_server(service.prepare_launch(config))).get("success", false), "explicit reconnect after an in-flight Stop")
	# Cancellation during setup must settle before the live Node can be retired.
	var setup_action: Dictionary = service.prepare_live_enable(config)
	service.enable_live_authoring(setup_action)
	service.clear_live_authoring()
	_check(await _wait(func(): return not service.busy()), "cancelled setup settles without freeing an awaiting Node")
	await _finish(host)


func _tool(arguments: Dictionary) -> Dictionary:
	call_serial += 1
	var full := arguments.duplicate(true)
	full["server_id"] = config["id"]
	return {"id": "live_" + str(call_serial), "type": "function", "function": {"name": "blender_session", "arguments": JSON.stringify(full)}}


func _check_confirmation_layout(dialog, owner: Window) -> void:
	var content: String = dialog.message_source
	var arguments: Array = dialog.message_arguments.duplicate(true)
	var original_font: int = dialog.body.get_theme_font_size("normal_font_size")
	var original_button_font: int = dialog.get_ok_button().get_theme_font_size("font_size")
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for factor in [1.0, 1.5, 2.0]:
			dialog.body.add_theme_font_size_override("normal_font_size", int(14 * factor * Metrics.editor_scale()))
			for button in [dialog.get_ok_button(), dialog.get_cancel_button()]: button.add_theme_font_size_override("font_size", int(14 * factor * Metrics.editor_scale()))
			dialog.popup_message(content, arguments)
			for frame in 3: await process_frame
			var bounds := Rect2(Vector2.ZERO, dialog.size)
			_check(dialog.size.x <= owner.size.x * 0.85 + 1 and dialog.size.y <= owner.size.y * 0.85 + 1, "confirmation fits its owning window " + locale + str(factor) + " dialog=" + str(dialog.size) + " owner=" + str(owner.size) + " min=" + str(dialog.get_contents_minimum_size()) + " scale=" + str(dialog.content_scale_factor) + " requested=" + str(dialog.requested_size) + " actual_owner=" + str(dialog.owner_size))
			for button in [dialog.get_ok_button(), dialog.get_cancel_button()]: _check(bounds.encloses(button.get_global_rect()), "confirmation action stays visible " + locale + str(factor))
			_check(dialog.body.fit_content == false and dialog.body.scroll_active, "confirmation body scrolls instead of enlarging the window")
	Localization.select_language("en")
	dialog.body.add_theme_font_size_override("normal_font_size", original_font)
	for button in [dialog.get_ok_button(), dialog.get_cancel_button()]: button.add_theme_font_size_override("font_size", original_button_font)
	var directory := OS.get_environment("ORCA_LIVE_CONFIRMATION_PREVIEW_DIR")
	if not directory.is_empty() and DisplayServer.get_name() != "headless":
		dialog.popup_message(content, arguments)
		for frame in 3: await process_frame
		RenderingServer.force_draw()
		dialog.get_texture().get_image().save_png(directory.path_join("orca-live-auto-confirmation.png" if dialog == view._live_auto_dialog else "orca-live-enable-confirmation.png"))


func _exercise_live_auto_apply(session, owner: Window) -> void:
	var count: int = client.requests.size()
	var original: Dictionary = session.current.duplicate(true)
	var resuming: bool = not controller.live_auto_apply_pause_reason(config["id"]).is_empty()
	controller.send_user_message("Automate this connected Blender session")
	var call := _tool({"operation": "inspect"} if resuming else {"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "AutomaticLive_" + str(call_serial), "kind": "cube"}])})
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	var card = view._tool_cards[call["id"]]
	if resuming: _check(card._auto_button.text == Localization.message("Resume live Auto apply…") and card._pause_note.visible, "paused live review names the cause and offers one explicit inspection/resume decision")
	card._auto_button.pressed.emit()
	var action: Dictionary = view._live_auto_action.duplicate(true)
	view._live_auto_dialog.canceled.emit()
	view._live_auto_dialog.hide()
	_check(not controller.live_auto_apply_enabled() and session.current == original, "opening/dismissing live confirmation grants nothing")
	_check(not controller.authorize_pending_live_edits(action), "cancelled live confirmation cannot be replayed")
	card._auto_button.pressed.emit()
	action = view._live_auto_action.duplicate(true)
	action["binding"]["root"] = "/copied/project"
	_check(not controller.authorize_pending_live_edits(action), "live grant cannot transfer across project roots")
	card._auto_button.pressed.emit()
	controller._edit_permission_revision += 1
	view._confirm_live_auto_apply()
	_check(not controller.live_auto_apply_enabled(), "stale preference/UI revision cannot authorize live automation")
	card._auto_button.pressed.emit()
	await _check_confirmation_layout(view._live_auto_dialog, owner)
	view._live_auto_dialog.confirmed.emit()
	_check(await _wait(func(): return client.requests.size() >= count + 2), "confirmed live grant applies original pending operation")
	_check(controller.live_auto_apply_enabled(config["id"]) and session.current["revision"] == original["revision"] + (0 if resuming else 1) and _receipts(call["id"]).size() == 1, "exact live confirmation grants bounded session automation")
	card = view._tool_cards[call["id"]]
	_check(card._automatic and not card._allow.visible and not card._reject.visible, "automatic live card has no repeated Apply controls")
	_check(controller.live_auto_apply_pause_reason(config["id"]).is_empty() and (card._pause_note == null or not card._pause_note.visible), "successful explicit inspection/resume clears the pause qualification")
	_check(JSON.stringify(client.requests.back()["messages"]).contains("LIVE BLENDER PERMISSION: Auto apply is enabled"), "follow-up prompt refreshes live automation permission")
	client.complete({"role": "assistant", "content": "Live automation enabled"})
	for frame in 3: await process_frame
	await _call({"operation": "help"})
	await _call({"operation": "inspect"})


func _exercise_cloud_command_correction(session) -> void:
	var settings := EditorInterface.get_editor_settings()
	var workspace_enabled: bool = controller.blender_auto_apply_enabled()
	controller._set_edit_permission_state(false)
	controller.apply_project_edit_default()
	_check(controller.live_auto_apply_enabled(config["id"]) and controller.blender_auto_apply_enabled() == workspace_enabled, "script-only default refresh cannot clear a separate live/workspace session grant")
	var account = Component.BlenderCloudAccount.new()
	root.add_child(account)
	var previous_account = controller.account_service
	controller.account_service = account
	settings.set_setting("orca/providers/selected", "orca_cloud")
	settings.set_setting("orca/providers/orca_cloud/model", Component.BlenderCloudAccount.MODEL)
	_check(controller.send_user_message("Create a model with the hosted live Blender workflow."), "start strict hosted live turn")
	_check(client.requests.back()["profile"].get("hosted_blender_sessions") == true and client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "blender_session"), "authenticated normalized Cloud vocabulary reaches real controller dispatch")
	var original: Dictionary = session.current.duplicate(true)
	var dispatch_serial: int = service._clients[config["id"]]._serial
	var grant: Dictionary = controller._live_auto_grants[config["id"]].duplicate(true)
	for arguments in [
		{"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "CloudCorrected", "kind": "cube", "radius": 0}])},
		{"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "CloudCorrected", "kind": "cube", "scale": [1, 0, 1]}])},
		{"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "CloudCorrected", "kind": "cube", "segments": 3.5}])},
		{"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "UnsentFirstCommand", "kind": "cube"}, {"op": "material", "name": "CloudCorrected", "material": "Invalid", "color": [1, 2, 0, 1]}])},
		{"operation": "help", "commands": "[]"},
		{"operation": "help", "destination": ""},
	]:
		var call := _tool(arguments)
		client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
		for frame in 3: await process_frame
		_check(_receipts(call["id"]).size() == 1 and controller._pending_mcp_read.is_empty(), "hosted invalid command produces one result without an approval")
		_check(session.current == original and service._clients[config["id"]]._serial == dispatch_serial, "local numeric/help rejection never contacts Blender or changes the scene")
		_check(controller.live_auto_apply_enabled(config["id"]) and controller._live_auto_grants.get(config["id"], {}) == grant, "locally rejected Cloud call preserves the exact confirmed live grant")
		_check(view._tool_cards[call["id"]]._validation_note.text == Localization.message("Command rejected locally; Auto apply remains enabled."), "collapsed failed call explains that Blender was not contacted and permission remains active")
		if arguments["operation"] == "edit":
			var text: String = _receipts(call["id"])[0]["content"]
			_check(text.contains("commands[") and text.contains("finite") and text.contains("["), "numeric rejection identifies its field, supplied value, type and bounds")
		if not controller.live_auto_apply_enabled(config["id"]):
			# Fail cleanly on the regression rather than hanging on the next Apply.
			client.complete({"role": "assistant", "content": "Local command rejected."})
			controller.account_service = previous_account
			settings.set_setting("orca/providers/selected", "openai")
			account.queue_free()
			return
	for wrong_id in ["", "unknown-live-session"]:
		var invalid := _tool({"operation": "help"})
		var arguments: Dictionary = JSON.parse_string(invalid["function"]["arguments"])
		if wrong_id.is_empty(): arguments.erase("server_id")
		else: arguments["server_id"] = wrong_id
		invalid["function"]["arguments"] = JSON.stringify(arguments)
		client.complete({"role": "assistant", "content": "", "tool_calls": [invalid]})
		for frame in 3: await process_frame
		_check(_receipts(invalid["id"]).size() == 1 and controller._live_auto_grants.get(config["id"], {}) == grant and service._clients[config["id"]]._serial == dispatch_serial, "missing/unknown server ID cannot revoke another confirmed session or dispatch")
	var call := _tool({"operation": "edit", "commands": JSON.stringify([{"op": "primitive", "name": "CloudCorrected", "kind": "cube", "radius": 1}])})
	var count: int = client.requests.size()
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	_check(await _wait(func(): return client.requests.size() > count), "corrected hosted command continues without another Apply click")
	_check(session.current["revision"] == original["revision"] + 1 and controller.live_auto_apply_enabled(config["id"]) and view._tool_cards[call["id"]]._automatic, "valid correction uses the retained live grant exactly once")
	client.complete({"role": "assistant", "content": "Hosted correction complete."})
	for frame in 3: await process_frame
	await _call({"operation": "help"})
	await _call({"operation": "inspect"})
	await _call({"operation": "preview", "objects": ["CloudCorrected"]})
	await _call({"operation": "export", "objects": ["CloudCorrected"]})
	_check(controller.live_auto_apply_enabled(config["id"]), "hosted live permission survives delayed follow-up help/edit/preview/export")
	account.profile["hosted_blender_sessions"] = false
	controller.send_user_message("Deny unavailable hosted Blender vocabulary")
	call = _tool({"operation": "help"})
	_check(not client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "blender_session"), "older Cloud capability snapshot still omits live authoring")
	dispatch_serial = service._clients[config["id"]]._serial
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	_check(_receipts(call["id"]).size() == 1 and service._clients[config["id"]]._serial == dispatch_serial, "live grant never bypasses the fixed hosted vocabulary gate")
	client.complete({"role": "assistant", "content": "Unavailable hosted tool denied."})
	controller.account_service = previous_account
	settings.set_setting("orca/providers/selected", "openai")
	account.queue_free()
	_check(controller.set_auto_apply_enabled(true), "restore independent script fixture scope")
	session.artifacts.clear() # Later handoff assertions own their fresh export.


func _exercise_automatic_conflict(session) -> void:
	var before: Dictionary = session.current.duplicate(true)
	var count: int = client.requests.size()
	controller.send_user_message("Reject an automatic stale live baseline")
	var call := _tool({"operation": "edit", "commands": JSON.stringify([{"op": "transform", "name": "LiveProp", "location": [5, 0, 0]}])})
	controller.mcp_read_requested.connect(func(_turn: int, request: Dictionary):
		if request.get("live_operation", false) and request.get("auto_apply", false): session.current["sha256"] = "f".repeat(64), CONNECT_ONE_SHOT)
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	_check(await _wait(func(): return client.requests.size() >= count + 2), "automatic conflict returns a matching provider result")
	_check(_receipts(call["id"]).size() == 1 and not controller.live_auto_apply_enabled(), "failed automatic operation revokes its exact grant")
	_check(client.requests.back()["tools"].is_empty() and controller._loop_final_trigger_reason == controller.LOOP_TRIGGER_BLENDER_PAUSE and controller._pending_mcp_read.is_empty(), "genuine pause finalizes once without subsequent approval churn")
	_check(view._tool_cards[call["id"]]._pause_note.visible and view._edit_permission_status.tooltip_text.contains("Live Blender Auto apply paused"), "failed card and combined header identify the paused live scope even when other grants remain active")
	session.current = before
	client.complete({"role": "assistant", "content": "Live automation paused after conflict"})
	for frame in 3: await process_frame


func _call(arguments: Dictionary, approve: bool = true, inspect_card: Callable = Callable()) -> void:
	var count: int = client.requests.size()
	var automatic: bool = controller.live_auto_apply_enabled(config["id"]) and arguments["operation"] in controller.LIVE_AUTO_OPERATIONS
	_check(controller.send_user_message("Fixture live " + arguments["operation"]), "start live turn")
	_check(client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "blender_session"), "enabled Work offers live tool")
	var call := _tool(arguments)
	var executions := []
	controller.tool_execution_completed.connect(func(_turn, id, _name, execution, _duration):
		if id == call["id"]: executions.append(execution.duplicate(true)), CONNECT_ONE_SHOT)
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	var card = view._tool_cards.get(call["id"])
	_check(card != null and card.has_method("_choose"), "live operation receives actual approval card")
	if card != null:
		if inspect_card.is_valid(): inspect_card.call(card)
		_check(card._automatic == automatic, "only the exact live grant selects automatic dispatch")
		for locale in Localization.LOCALES:
			Localization.select_language(locale)
			for factor in [1.0, 1.5, 2.0]:
				for control in [card._allow, card._reject, card._title, card._help]: control.add_theme_font_size_override("font_size", int(14 * factor * Metrics.editor_scale()))
				await process_frame
				_check(card.get_combined_minimum_size().x <= Metrics.scaled(320), "live review narrow layout " + locale + str(factor))
		Localization.select_language("en")
		if not automatic: card._choose(approve)
	_check(await _wait(func(): return client.requests.size() >= count + 2), "live operation returns a provider continuation")
	var receipts := _receipts(call["id"])
	_check(receipts.size() == 1, "exactly one matching live receipt")
	if approve: _check(executions.size() == 1 and executions[0]["success"], "live operation completed: " + str(receipts[0]["content"]) if not receipts.is_empty() else "live receipt missing")
	var history: Array = view._session["events"].filter(func(event): return event.get("name") == "blender_session")
	_check(history.all(func(event): return event.get("arguments", {}).is_empty() and not event.has("open_path")), "history keeps no code/live references/artifact authority")
	client.complete({"role": "assistant", "content": "Fixture operation complete"})
	for frame in 3: await process_frame


func _receipts(id: String) -> Array:
	return controller.message_history.filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == id)


func _finish(host: Window) -> void:
	service.shutdown()
	view.mcp_service = null
	controller.mcp_service = null
	host.queue_free()
	service.queue_free()
	for frame in 8: await process_frame
	if failures.is_empty(): print("blender_session_editor_test: PASS")
	quit(0 if failures.is_empty() else 1)
