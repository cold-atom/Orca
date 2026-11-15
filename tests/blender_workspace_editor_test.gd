@tool
extends "res://tests/editor_test_case.gd"

const Service = preload("res://addons/orca/scripts/blender_workspace_service.gd")
const Component = preload("res://tests/auto_apply_test.gd")
const Localization = preload("res://addons/orca/scripts/localization.gd")
const Metrics = preload("res://addons/orca/scripts/ui_metrics.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
const Preview = preload("res://addons/orca/scripts/blender_preview_view.gd")
var failures: Array[String] = []

class Peer extends "res://addons/orca/scripts/mcp_stdio_client.gd":
	var refuse_stop := false
	func connect_process(_command: String, arguments: Array) -> Dictionary:
		return await super.connect_process("/usr/bin/python3", [ProjectSettings.globalize_path("res://tests/blender_workspace_fixture.py"), arguments.back()])
	func _stop_process(pid: int) -> int:
		return FAILED if refuse_stop else super._stop_process(pid)

class FixtureService extends "res://addons/orca/scripts/blender_workspace_service.gd":
	var installations: Array[String] = []
	func _valid_executable(path: String) -> bool:
		return path in ["/usr/bin/python3", "/fixture/blender-a", "/fixture/blender-b"]
	func discover() -> Array[String]:
		return installations.duplicate()
	func _ready() -> void:
		super._ready()
		_client.queue_free()
		_client = Peer.new()
		add_child(_client)

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	for frame in 60: await process_frame
	while EditorInterface.get_resource_filesystem().is_scanning(): await process_frame
	var phase := OS.get_environment("ORCA_BLENDER_EDITOR_PHASE")
	if not phase.is_empty() and phase != "exercise":
		await _remembered_phase(phase)
		return
	await _exercise_guided_setup()
	var live := OS.get_environment("ORCA_BLENDER_WORKSPACE_LIVE_EXECUTABLE")
	var service = Service.new() if not live.is_empty() else FixtureService.new()
	root.add_child(service)
	_check(service.choose(live if not live.is_empty() else "/usr/bin/python3"), "explicit installation selection")
	var panel = preload("res://addons/orca/scripts/blender_setup_panel.gd").new()
	panel.service = service
	root.add_child(panel)
	for path in [Service.SCRIPT, "res://addons/orca/blender/workspace_contract.py"]:
		var backup: String = path + ".missing-fixture"
		_check(DirAccess.rename_absolute(path, backup) == OK, "temporarily remove one shipped runtime file in disposable fixture")
		panel._request("connect")
		panel._confirm.hide()
		await panel._confirmed()
		_check(service.state == "disconnected" and service.workspace.is_empty() and service._client._child.is_empty(), "missing runtime fails before workspace creation or process launch")
		_check(service.status.contains("connector is missing") and panel._status.text.contains("addons/orca/blender/"), "early installation failure is visible in actual setup panel")
		_check(DirAccess.rename_absolute(backup, path) == OK, "restore original runtime bytes")
	panel.queue_free()
	var started: Dictionary = await service.connect_workspace(true)
	_check(started.get("success", false), "workspace MCP launch: " + str(started))
	if not started.get("success", false):
		service.queue_free()
		_finish()
		return
	var view = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	view.blender_service = service
	var settings := EditorInterface.get_editor_settings()
	settings.set_setting("orca/providers/selected", "openai")
	settings.set_setting("orca/providers/openai/api_key", "synthetic")
	settings.set_setting("orca/providers/openai/model", "gpt-4o-mini")
	var window := Window.new()
	window.size = Vector2i(Metrics.scaled_int(320), Metrics.scaled_int(700))
	root.add_child(window)
	window.add_child(view)
	for frame in 8: await process_frame
	var client := Component.Client.new()
	view.agent_controller.set_api_client_for_testing(client)
	view._start_new_session()
	var controller = view.agent_controller
	view.prompt_input.text = "Keep my asset draft"
	view._on_settings_button_pressed()
	view.settings_view._show_section("extensions")
	var studio = view.settings_view.extensions_view.blender_panel
	_check(studio.is_visible_in_tree() and studio._primary.text == Localization.message("Back to chat") and not studio._actions.visible, "connected workspace offers a direct compact return to chat")
	controller.set_mode(0)
	_check(studio._blocker.visible and studio._blocker.text == Localization.message("Switch to Work mode in chat to create Blender assets."), "workspace readiness distinguishes the Plan-mode blocker")
	controller.set_mode(1)
	_check(not studio._blocker.visible, "explicit Work transition refreshes setup guidance")
	await _capture_setup(window, "orca-blender-setup-ready.png")
	studio._primary.pressed.emit()
	_check(not view.settings_view.visible and view.main_content.visible and view.prompt_input.text == "Keep my asset draft", "Back to chat follows normal Settings completion and preserves the composer draft")
	view.prompt_input.text = ""
	await _exercise_batch_recovery(view, controller, client, service)
	view._start_new_session()
	_check(controller.set_auto_apply_enabled(true), "script Auto apply fixture grant")
	var initial: Dictionary = service.current.duplicate(true)
	var commands := JSON.stringify([{"op": "primitive", "name": "GameProp", "kind": "cube"}, {"op": "material", "name": "GameProp", "material": "Blue", "color": [0.1, 0.5, 0.9, 1]}])
	controller.send_user_message("Create a game prop in Blender.")
	_check(client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "blender_workspace"), "connected Work exposes bounded workspace tool")
	var call := {"id": "studio_edit", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "edit", "commands": commands})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(service.current == initial and not controller._pending_mcp_read.is_empty(), "Auto apply never bypasses asset review")
	var card = view._tool_cards.get("studio_edit")
	_check(card != null and card._details.text.contains("GameProp"), "semantic asset review appears")
	if card != null:
		for locale in Localization.LOCALES:
			Localization.select_language(locale)
			for factor in [1.0, 1.5, 2.0]:
				for control in [card._allow, card._reject, card._title, card._help]: control.add_theme_font_size_override("font_size", int(14 * factor * Metrics.editor_scale()))
				for frame in 3: await process_frame
				_check(card.get_combined_minimum_size().x <= Metrics.scaled(320), "asset review narrow layout " + locale + str(factor))
		card._allow.pressed.emit()
	for frame in 600:
		if not controller._pending_mcp_read.is_empty(): await process_frame; continue
		if service.current.get("revision", 0) > initial["revision"] and client.requests.size() >= 2: break
		await process_frame
	_check(service.current.get("revision", 0) > initial["revision"] and JSON.stringify(service.current).contains("GameProp"), "approved native asset creation")
	_check(_receipts(controller, "studio_edit").size() == 1, "exact matching creation receipt")
	client.complete({"role": "assistant", "content": "Prop created."})
	for frame in 4: await process_frame
	var before_reject: Dictionary = service.current.duplicate(true)
	controller.send_user_message("Reject another change.")
	call["id"] = "studio_reject"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 3: await process_frame
	card = view._tool_cards.get("studio_reject")
	if card != null: card._reject.pressed.emit()
	for frame in 4: await process_frame
	_check(service.current == before_reject and _receipts(controller, "studio_reject").size() == 1, "Reject preserves exact workspace revision")
	client.complete({"role": "assistant", "content": "Rejected."})
	for frame in 4: await process_frame
	# An existing script-only grant requires one fresh Blender scope decision.
	controller.send_user_message("Automate the dedicated Blender workspace.")
	var auto_commands := JSON.stringify([{"op": "primitive", "name": "AutomaticProp", "kind": "cube", "location": [2, 0, 0]}])
	call = {"id": "studio_auto", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "edit", "commands": auto_commands})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	card = view._tool_cards.get("studio_auto")
	_check(card != null and card._auto_button != null and not controller.blender_auto_apply_enabled(), "existing script grant exposes one-time Blender scope confirmation")
	if card != null:
		card._auto_button.pressed.emit()
		view._edit_permission_dialog.hide()
		_check(not controller.blender_auto_apply_enabled(), "opening/dismissing scope dialog grants nothing")
		view._edit_permission_dialog_revision -= 1
		view._enable_session_edits()
		_check(not Config.project_blender_edit_preference()["enabled"], "stale confirmation cannot save Blender authorization")
		card._auto_button.pressed.emit()
		view._edit_permission_dialog.hide()
		view._edit_permission_dialog.confirmed.emit()
	for frame in 600:
		if service.current["revision"] > before_reject["revision"] and not controller._executing_tool_call: break
		await process_frame
	_check(controller.blender_auto_apply_enabled() and Config.project_blender_edit_preference()["enabled"], "actual scope confirmation remembers and enables Blender")
	_check(service.current["revision"] > before_reject["revision"] and _receipts(controller, "studio_auto").size() == 1, "confirmed scope applies pending original operation exactly once")
	card = view._tool_cards.get("studio_auto")
	_check(card != null and card._status.text == "Auto applied" and not card._allow.visible, "automatic compact result card replaces approval actions")
	var automatic_revision: int = service.current["revision"]
	var requests_before: int = client.requests.size()
	client.complete({"role": "assistant", "content": "", "tool_calls": [
		{"id": "auto_batch_workspace", "type": "function", "function": {"name": "blender_workspace", "arguments": '{"operation":"help"}'}},
		{"id": "auto_batch_project", "type": "function", "function": {"name": "get_editor_context", "arguments": "{}"}}
	]})
	_check(client.requests.size() == requests_before + 1 and service.current["revision"] == automatic_revision and controller._pending_mcp_read.is_empty(), "mixed automatic workspace/project batch is corrected atomically before dispatch")
	_check(client.requests.back()["options"].get("_orca_serial_tool_calls") == true, "automatic correction continuation requests serial tool generation")
	for operation in ["help", "inspect", "preview", "export"]:
		var id_call: String = "studio_automatic_" + operation
		call = {"id": id_call, "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": operation})}}
		client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
		for frame in 1200:
			if not controller._executing_tool_call: break
			await process_frame
		_check(_receipts(controller, id_call).size() == 1 and controller._pending_mcp_read.is_empty(), "automatic continuation without approval " + operation)
		_check(service.current["revision"] == automatic_revision, "read/render/export preserves asset revision " + operation)
		if operation == "preview":
			card = view._tool_cards.get(id_call)
			var viewers: Array = card.get_child(0).get_children().filter(func(child): return child is Preview)
			_check(viewers.size() == 1 and viewers[0]._camera != null, "preview card contains native real 3D geometry")
			if not viewers.is_empty(): await _exercise_viewer(viewers[0], window, view)
	client.complete({"role": "assistant", "content": "Automatic workspace complete."})
	for frame in 4: await process_frame
	before_reject = service.current.duplicate(true)
	# Provider/catalog state never substitutes for user approval of import/place.
	controller.send_user_message("Review project import.")
	call = {"id": "studio_import_review", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "import", "artifact_id": service.artifacts.keys()[0], "destination": "res://game_prop.glb"})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(not controller._pending_mcp_read.is_empty() and not FileAccess.file_exists("res://game_prop.glb"), "Blender automation never bypasses project import review")
	controller.resolve_mcp_read("studio_import_review", controller._active_turn_id, false)
	for frame in 4: await process_frame
	client.complete({"role": "assistant", "content": "Import rejected."})
	for frame in 4: await process_frame
	controller.send_user_message("Fail an automatic operation safely.")
	call = {"id": "studio_auto_failure", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "edit", "commands": '[{"op":"delete","name":"MissingAutomaticObject"}]'})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 600:
		if not controller._executing_tool_call: break
		await process_frame
	_check(not controller.blender_auto_apply_enabled() and service.current == before_reject and _receipts(controller, "studio_auto_failure").size() == 1, "failure pauses automatic operations, preserves baseline and settles one receipt")
	client.complete({"role": "assistant", "content": "Operation failed without replay."})
	for frame in 4: await process_frame
	controller.apply_project_edit_default()
	_check(not controller.blender_auto_apply_enabled(), "failed automatic operation cannot silently reacquire remembered scope")
	view._start_new_session()
	_check(controller.blender_auto_apply_enabled(), "user-initiated New Session may obtain fresh remembered permission")
	Config.set_project_blender_edit_default(true)
	_check(not controller.blender_auto_apply_enabled(), "changed preference revision revokes the exact runtime binding")
	controller.send_user_message("Review after preference revision changed.")
	call = {"id": "studio_stale_grant", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "inspect"})}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(not controller._pending_mcp_read.is_empty(), "stale remembered preference cannot send an automatic operation")
	controller.resolve_mcp_read("studio_stale_grant", controller._active_turn_id, false)
	for frame in 4: await process_frame
	client.complete({"role": "assistant", "content": "Reviewed scope required."})
	for frame in 4: await process_frame
	view._start_new_session()
	controller.mcp_read_requested.connect(func(_turn: int, visible: Dictionary):
		if visible.get("auto_apply", false): controller.set_blender_auto_apply_enabled(false), CONNECT_ONE_SHOT)
	controller.send_user_message("Revoke before dispatch.")
	call["id"] = "studio_revoke_dispatch"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(not controller.blender_auto_apply_enabled() and not controller._pending_mcp_read.is_empty(), "revocation in the visible-card callback falls back to exact review before sending")
	controller.resolve_mcp_read("studio_revoke_dispatch", controller._active_turn_id, false)
	for frame in 4: await process_frame
	client.complete({"role": "assistant", "content": "Revoked."})
	for frame in 4: await process_frame
	view._start_new_session()
	var exported := service.prepare(service.snapshot(), {"operation": "export"})
	var result: Dictionary = await service.execute(exported["review"], func(): return true)
	_check(result.get("success", false), "bounded staged GLB export: " + str(result.get("error", "")))
	var id: String = service.artifacts.keys()[0] if not service.artifacts.is_empty() else ""
	var prepared := service.prepare(service.snapshot(), {"operation": "import", "artifact_id": id, "destination": "res://game_prop.glb"})
	_check(prepared.get("success", false), "typed import review")
	if prepared.get("success", false):
		var tampered: Dictionary = prepared["review"].duplicate(true)
		tampered["destination"] = "res://other.glb"
		_check(not (await service.execute(tampered, func(): return true)).get("success", false), "tampered import review denied")
		result = await service.execute(prepared["review"], func(): return true)
		_check(result.get("success", false) and result.get("data", {}).get("import_verified", false), "actual Godot GLB import observed")
		EditorInterface.open_scene_from_path("res://tests/fixtures/blender_workspace_scene.tscn")
		for frame in 20: await process_frame
		var scene := EditorInterface.get_edited_scene_root()
		var scene_hash := FileAccess.get_sha256("res://tests/fixtures/blender_workspace_scene.tscn")
		controller.send_user_message("Review scene placement.")
		call = {"id": "studio_place_review", "type": "function", "function": {"name": "blender_workspace", "arguments": JSON.stringify({"operation": "place"})}}
		client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
		for frame in 4: await process_frame
		_check(controller.blender_auto_apply_enabled() and not controller._pending_mcp_read.is_empty() and scene.get_child_count() == 0, "Blender grant cannot bypass exact scene placement approval")
		controller.resolve_mcp_read("studio_place_review", controller._active_turn_id, false)
		for frame in 4: await process_frame
		client.complete({"role": "assistant", "content": "Placement rejected."})
		for frame in 4: await process_frame
		var placement: Dictionary = service.prepare(service.snapshot(), {"operation": "place"})
		_check(placement.get("success", false), "clean native scene placement review")
		if placement.get("success", false):
			result = await service.execute(placement["review"], func(): return true)
			_check(result.get("success", false) and result.get("data", {}).get("save_pending", false) and scene.get_child_count() == 1, "native asset addition is editor-only/save-pending")
			_check(FileAccess.get_sha256("res://tests/fixtures/blender_workspace_scene.tscn") == scene_hash, "placement never saves scene bytes")
			var history := EditorInterface.get_editor_undo_redo().get_history_undo_redo(EditorInterface.get_editor_undo_redo().get_object_history_id(scene))
			history.undo()
			_check(scene.get_child_count() == 0, "native asset placement Undo")
			history.redo()
			_check(scene.get_child_count() == 1, "native asset placement Redo")
			history.undo()
		for frame in 6: await process_frame
		_check(not service.revert_import(false).get("success", false), "Plan revert denied")
		result = service.revert_import(true)
		_check(result.get("success", false) and not FileAccess.file_exists("res://game_prop.glb"), "explicit conflict-checked source Revert")
	controller.set_mode(0)
	controller.send_user_message("Plan only.")
	_check(not client.requests.back()["tools"].any(func(tool): return tool["function"]["name"] == "blender_workspace"), "Plan schema omits asset tool")
	call["id"] = "studio_plan"
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	_check(_receipts(controller, "studio_plan").size() == 1 and service.current == before_reject, "direct Plan call denied without external mutation")
	client.complete({"role": "assistant", "content": "Plan complete."})
	controller.set_mode(1)
	controller.set_blender_auto_apply_enabled(false)
	controller.send_user_message("Stop while reviewing.")
	call["id"] = "studio_stop"
	call["function"]["arguments"] = JSON.stringify({"operation": "edit", "commands": auto_commands})
	client.complete({"role": "assistant", "content": "", "tool_calls": [call]})
	for frame in 4: await process_frame
	controller.cancel_current_request()
	for frame in 4: await process_frame
	_check(_receipts(controller, "studio_stop").size() == 1 and not controller.is_busy(), "Stop settles matching workspace receipt")
	var events: Array = view._session.get("events", []).filter(func(event): return event.get("name") == "blender_workspace")
	_check(events.all(func(event): return event.get("arguments", {}).is_empty() and not JSON.stringify(event).contains("GameProp")), "history keeps coarse receipts, never command/review authority")
	view.settings_view._show_section("extensions")
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for frame in 4: await process_frame
		_check(view.settings_view.get_combined_minimum_size().x <= Metrics.scaled(320), "guided setup narrow locale " + locale)
	window.queue_free()
	for frame in 8: await process_frame
	_check(service.state == "disconnected", "dock teardown stops only its workspace")
	service.queue_free()
	Localization.select_language("en")
	for frame in 8: await process_frame
	_finish()

func _exercise_guided_setup() -> void:
	var settings := EditorInterface.get_editor_settings()
	var workspace_key := "orca/blender/workspaces/" + ProjectSettings.globalize_path("res://").sha256_text()
	var saved_installation = settings.get_setting(Service.SETTING) if settings.has_setting(Service.SETTING) else null
	var saved_workspace = settings.get_setting(workspace_key) if settings.has_setting(workspace_key) else null
	var service := FixtureService.new()
	root.add_child(service)
	service.executable = ""
	var host := Window.new()
	host.size = Vector2i(Metrics.scaled_int(300), Metrics.scaled_int(650))
	root.add_child(host)
	var page = preload("res://addons/orca/scripts/extensions_view.gd").new()
	page.blender_service = service
	page.blender_work_allowed = func(): return true
	host.add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel = page.blender_panel
	_check(panel.is_visible_in_tree() and panel._primary.text == Localization.message("Set up Blender") and service._client._child.is_empty(), "first-open asset setup is visible and never launches Blender")
	await _capture_setup(host, "orca-blender-setup-first.png")
	panel._primary.pressed.emit()
	_check(panel._choose.is_visible_in_tree() and panel._download.is_visible_in_tree() and not panel._browse.visible and not panel._confirm.visible, "missing Blender explains Browse and Download without forcing a file dialog")
	panel._browse.file_selected.emit("/not/blender")
	_check(panel._status.text == Localization.message("Choose an installed Blender executable.") and service.executable.is_empty(), "invalid file choice has visible recovery guidance")
	service.installations.assign(["/fixture/blender-a", "/fixture/blender-b"])
	panel._primary.pressed.emit()
	_check(panel._installations.visible and panel._installations.selected == -1 and not panel._download.visible and service.executable.is_empty(), "multiple installations require an explicit choice and do not assume the first")
	panel._installations.select(1)
	panel._installations.item_selected.emit(1)
	_check(service.executable == "/fixture/blender-b" and not panel._confirm.visible and service._client._child.is_empty(), "installation choice alone never starts a workspace")
	panel._primary.pressed.emit()
	_check(panel._confirm.visible and panel._confirm.dialog_text.contains(service.executable), "startup confirmation discloses the exact selected Blender")
	panel._confirm.canceled.emit()
	panel._confirm.hide()
	panel._confirm.confirmed.emit()
	_check(service.state == "disconnected" and service._client._child.is_empty(), "dismissed confirmation cannot be replayed")
	panel._primary.pressed.emit()
	service.choose("/fixture/blender-a")
	panel._confirm.hide()
	panel._confirm.confirmed.emit()
	_check(service._client._child.is_empty(), "changing the installation invalidates the original confirmation")
	service.executable = ""
	service.installations.assign(["/fixture/blender-a"])
	panel._primary.pressed.emit()
	_check(service.executable == "/fixture/blender-a" and panel._confirm.visible and service._client._child.is_empty(), "one detected installation proceeds directly to confirmation without launching")
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for factor in [1.0, 1.5, 2.0]:
			_scale_setup_fonts(page, factor)
			for frame in 3: await process_frame
			_check(page.get_combined_minimum_size().x <= Metrics.scaled(300) + 1, "guided setup fits narrow dock and enlarged fonts " + locale + str(factor))
			_check(panel._confirm.visible and panel._approved_executable == service.executable and panel._choice == "connect", "language and font refresh preserve the exact pending startup decision")
	_scale_setup_fonts(page, 1.0)
	Localization.select_language("en")
	panel._confirm.hide()
	panel._confirm.confirmed.emit()
	_check(service.state == "connecting" and panel._primary.text == "Cancel" and not panel._primary.disabled, "startup exposes immediate Cancel")
	panel._primary.pressed.emit()
	for frame in 600:
		if not service.busy(): break
		await process_frame
	_check(service.state == "disconnected" and service._client._child.is_empty() and not service.busy() and service.status.contains("disconnected"), "Cancel settles startup without failure replacement or replay")
	panel._primary.pressed.emit()
	panel._confirm.hide()
	panel._confirm.confirmed.emit()
	for frame in 600:
		if service.state == "connected" or not service.busy(): break
		await process_frame
	_check(service.state == "connected" and panel._status.text == "Workspace ready" and panel._primary.text == "Back to chat", "fresh user restart validates the workspace and offers chat without an MCP connector")
	var snapshot: Dictionary = service.snapshot()
	panel._confirm.confirmed.emit()
	_check(service.snapshot() == snapshot, "consumed confirmation cannot restart a ready workspace")
	panel._manage.button_pressed = true
	panel._manage.pressed.emit()
	_check(panel._actions.visible and panel._disconnect.is_visible_in_tree() and not panel._manage_choose.visible, "workspace management reveals recovery controls without installation changes while connected")
	panel.set_locked(true)
	_check(panel._primary.disabled and panel._new_asset.disabled and panel._template_button.disabled, "active-turn lock disables setup and asset mutation entry points")
	panel.set_locked(false)
	service._client.refuse_stop = true
	panel._disconnect.pressed.emit()
	_check(service.state == "stop_failed" and panel._primary.text == "Try disconnect again" and not panel._primary.disabled and not service._client._child.is_empty(), "failed stop retains ownership and exposes recovery on the main card")
	service._client.refuse_stop = false
	panel._primary.pressed.emit()
	_check(service.state == "disconnected" and panel._primary.text == "Start asset workspace", "disconnect keeps installation for one-action reconnect")
	host.queue_free()
	service.queue_free()
	for frame in 8: await process_frame
	settings.set_setting(Service.SETTING, saved_installation)
	settings.set_setting(workspace_key, saved_workspace)

func _capture_setup(host: Window, filename: String) -> void:
	var directory := OS.get_environment("ORCA_BLENDER_SETUP_PREVIEW_DIR")
	if directory.is_empty() or not DirAccess.dir_exists_absolute(directory) or DisplayServer.get_name() == "headless": return
	for frame in 4: await process_frame
	await RenderingServer.frame_post_draw
	host.get_texture().get_image().save_png(directory.path_join(filename))

func _scale_setup_fonts(node: Node, factor: float) -> void:
	if node is Label or node is Button:
		if not node.has_meta("setup_test_font"): node.set_meta("setup_test_font", node.get_theme_font_size("font_size"))
		node.add_theme_font_size_override("font_size", int(node.get_meta("setup_test_font") * factor))
	for child in node.get_children(): _scale_setup_fonts(child, factor)

func _exercise_viewer(viewer, window: Window, view) -> void:
	for frame in 6: await process_frame
	view.chat_scroll.scroll_vertical = int(view.chat_scroll.get_v_scroll_bar().max_value)
	for frame in 6: await process_frame
	var point: Vector2 = viewer._surface.get_global_rect().get_center()
	var yaw: float = viewer._yaw
	var target: Vector3 = viewer._target
	var distance: float = viewer._distance
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	window.push_input(event, true)
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(20, 10)
	motion.global_position = motion.position
	motion.relative = Vector2(20, 10)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	window.push_input(motion, true)
	event.pressed = false
	event.button_mask = 0
	window.push_input(event, true)
	_check(viewer._yaw != yaw and viewer._drag == 0, "real pointer orbit and release routing")
	event.button_index = MOUSE_BUTTON_MIDDLE
	event.pressed = true
	event.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	window.push_input(event, true)
	motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	window.push_input(motion, true)
	event.pressed = false
	event.button_mask = 0
	window.push_input(event, true)
	_check(viewer._target != target, "real pointer pan changes only preview camera")
	event.button_index = MOUSE_BUTTON_WHEEL_UP
	event.pressed = true
	window.push_input(event, true)
	_check(viewer._distance < distance, "real mouse wheel zoom")
	viewer.reset_view()
	_check(viewer._yaw == 0.65 and viewer._target == viewer._center, "frame/reset restores whole-model camera")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var rendered: Image = viewer._viewport.get_texture().get_image()
		_check(not rendered.is_empty(), "graphical preview produces a real rendered frame")
		var background := rendered.get_pixel(0, 0)
		var occupied := 0
		for y in range(0, rendered.get_height(), 8):
			for x in range(0, rendered.get_width(), 8):
				if rendered.get_pixel(x, y).to_abgr32() != background.to_abgr32(): occupied += 1
		_check(occupied > 4, "native preview frame contains visible geometry, not only background")
		var capture := OS.get_environment("ORCA_BLENDER_PREVIEW_DIR")
		if not capture.is_empty() and DirAccess.dir_exists_absolute(capture): rendered.save_png(capture.path_join("orca-blender-3d-preview.png"))
	for locale in Localization.LOCALES:
		Localization.select_language(locale)
		for factor in [1.0, 1.5, 2.0]:
			viewer._hint.add_theme_font_size_override("font_size", int(14 * factor * Metrics.editor_scale()))
			for frame in 3: await process_frame
			_check(viewer.get_combined_minimum_size().x <= Metrics.scaled(320), "interactive preview narrow locale/font layout")
	viewer._open_expanded()
	for frame in 4: await process_frame
	_check(is_instance_valid(viewer._expanded) and viewer._expanded.visible, "larger native preview window opens")
	var expanded_viewer = viewer._expanded.get_child(0).get_child(0)
	_check(expanded_viewer._scroll == null and expanded_viewer._camera != null, "expanded viewer is independent of the original dock's scroll clipping")
	viewer._expanded.close_requested.emit()
	for frame in 4: await process_frame
	_check(not is_instance_valid(viewer._expanded), "closing expanded window releases its render scene")
	for index in 3:
		var extra := Preview.new()
		viewer.get_parent().add_child(extra)
		extra.configure_asset(viewer._asset.duplicate(), viewer._thumbnail)
		if index == 2: _check(viewer._viewport == null, "old preview geometry released after bounded render-scene limit")
	for child in viewer.get_parent().get_children():
		if child is Preview and child != viewer: child.queue_free()
	for frame in 4: await process_frame

func _exercise_batch_recovery(view, controller, client, service) -> void:
	var initial: Dictionary = service.current.duplicate(true)
	var errors: Array[String] = []
	var error_listener := func(_turn: int, message: String): errors.append(message)
	controller.error_occurred.connect(error_listener)
	controller.send_user_message("Design, model and preview a Blender asset.")
	var primary: String = client.requests.back()["messages"][0]["content"]
	_check(primary.contains("BLENDER PERMISSION") and primary.contains("blender_workspace and inspect_mcp alone"), "first connected turn receives current permission and explicit singleton guidance")
	var tasks := [{"content": "Inspect Blender", "status": "in_progress"}, {"content": "Model asset", "status": "pending"}, {"content": "Preview asset", "status": "pending"}]
	client.complete({"role": "assistant", "content": "", "tool_calls": [{"id": "batch_tasks", "type": "function", "function": {"name": "update_tasks", "arguments": JSON.stringify({"tasks": tasks})}}]})
	for frame in 4: await process_frame
	var workspace := {"id": "rejected_workspace_first", "type": "function", "function": {"name": "blender_workspace", "arguments": '{"operation":"inspect"}'}}
	var project := {"id": "rejected_project_first", "type": "function", "function": {"name": "get_editor_context", "arguments": "{}"}}
	client.complete({"role": "assistant", "content": "", "tool_calls": [workspace, project]})
	for frame in 4: await process_frame
	_check(service.current == initial and controller._pending_mcp_read.is_empty() and not view._tool_cards.has(workspace["id"]), "first mixed batch performs no partial workspace or project activity")
	_check(JSON.stringify(client.requests.back()["messages"]).contains("blender_workspace must be the only tool call"), "regeneration tells the provider the exact standalone operation")
	workspace["id"] = "rejected_workspace_second"
	project["id"] = "rejected_project_second"
	client.complete({"role": "assistant", "content": "", "tool_calls": [project, workspace]})
	for frame in 4: await process_frame
	_check(errors.size() == 1 and errors[0].contains("call 2") and errors[0].contains("blender_workspace must be the only tool call"), "terminal repeated-batch error identifies the actual cause and call ordinal")
	_check(controller.last_failure_was_checkpointed() and errors[0].contains("Only task-list metadata") and errors[0].contains("no project or Blender operation ran"), "checklist-only recovery does not claim that an asset was generated")
	_check(service.current == initial and not controller.is_busy() and view._session_resumable, "failed batches preserve the asset and recoverable checklist")
	view._on_resume_remaining_work()
	for frame in 4: await process_frame
	_check(controller.is_busy() and client.requests.back()["messages"][0]["content"].contains("blender_workspace and inspect_mcp alone"), "actual Resume refreshes current batching and permission guidance")
	workspace["id"] = "resumed_workspace_inspect"
	client.complete({"role": "assistant", "content": "", "tool_calls": [workspace]})
	for frame in 4: await process_frame
	var card = view._tool_cards.get(workspace["id"])
	_check(card != null and not controller._pending_mcp_read.is_empty(), "resumed standalone workspace call reaches its normal review instead of another batch rejection")
	if card != null: card._allow.pressed.emit()
	for frame in 600:
		if not controller._executing_tool_call: break
		await process_frame
	_check(_receipts(controller, workspace["id"]).size() == 1 and service.current["revision"] == initial["revision"], "resumed inspection executes once with a matching receipt and no asset mutation")
	client.complete({"role": "assistant", "content": "Workspace inspected; continue with normal reviewed modeling."})
	for frame in 4: await process_frame
	controller.error_occurred.disconnect(error_listener)

func _remembered_phase(phase: String) -> void:
	var view = preload("res://addons/orca/scenes/chat_window.tscn").instantiate()
	root.add_child(view)
	for frame in 8: await process_frame
	view._start_new_session()
	var controller = view.agent_controller
	if phase == "other_project":
		_check(not controller.blender_auto_apply_enabled(), "another project never inherits the grant")
		var root_path := ProjectSettings.globalize_path("res://").simplify_path()
		EditorInterface.get_editor_settings().set_setting(Config.PROJECT_BLENDER_EDITS_PREFIX + root_path.sha256_text(), {"version": 1, "project_root": OS.get_environment("ORCA_BLENDER_ORIGINAL_ROOT") + "/", "enabled": true, "revision": "a".repeat(32)})
		_check(not Config.project_blender_edit_preference()["enabled"], "copied root-mismatched preference fails closed")
	elif phase == "verify_revoked":
		_check(not controller.blender_auto_apply_enabled() and not Config.project_blender_edit_preference()["enabled"], "revocation survives actual editor restart")
	else:
		_check(controller.blender_auto_apply_enabled() and not controller.auto_apply_enabled(), "clean restart obtains only explicitly remembered Blender scope")
		controller.set_mode(0)
		_check(not controller.blender_auto_apply_enabled(), "Plan cannot activate remembered workspace permission")
		controller.set_mode(1)
		_check(controller.blender_auto_apply_enabled(), "explicit Work transition obtains fresh exact-project grant")
		controller.restore_session_state(1, [], {}, [], false)
		controller.apply_project_edit_default()
		_check(not controller.blender_auto_apply_enabled(), "view-only restoration cannot activate workspace permission")
		controller.restore_session_state(1, [], {}, [], true)
		controller.apply_project_edit_default()
		_check(controller.blender_auto_apply_enabled(), "resumable Work restoration obtains fresh preference authority")
		if phase == "revoke":
			view._on_edit_permission_pressed()
			_check(not controller.blender_auto_apply_enabled() and not Config.project_blender_edit_preference()["enabled"], "green header revokes workspace grant and remembered defaults")
	view.queue_free()
	for frame in 8: await process_frame
	_finish()

func _receipts(controller, id: String) -> Array:
	return controller.message_history.filter(func(message): return message.get("role") == "tool" and message.get("tool_call_id") == id)

func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

func _finish() -> void:
	for failure in failures: print("FAIL: ", failure)
	print("blender_workspace_editor_test: PASS" if failures.is_empty() else "blender_workspace_editor_test: FAIL")
	quit(0 if failures.is_empty() else 1)
