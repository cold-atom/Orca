extends SceneTree

const AccountService = preload("res://addons/orca/scripts/account_service.gd")
const CloudProvider = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")
const Store = preload("res://addons/orca/scripts/credential_store.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")
var failures := 0

class MemoryVault:
	extends RefCounted
	var record := {}
	var locked := false
	func available() -> bool: return true
	func acquire(_scope: String) -> bool:
		if locked: return false
		locked = true
		return true
	func read_record() -> Dictionary: return {"success": true, "record": record.duplicate(true)}
	func write_record(value: Dictionary) -> bool:
		record = value.duplicate(true)
		return true
	func erase() -> bool:
		record.clear()
		return true
	func release() -> void: locked = false

class FixtureService:
	extends AccountService
	var calls: Array = []
	var rotations := 0
	var delay_refresh := false
	func _request(path: String, _method: int, body: Dictionary = {}, _token: String = "") -> Dictionary:
		calls.append(path)
		if path == "/v1/auth/token/refresh":
			rotations += 1
			if delay_refresh:
				await get_tree().process_frame
			return {"success": true, "body": {"access_token": "access-" + str(rotations), "refresh_token": "refresh-" + str(rotations), "token_type": "Bearer", "expires_in": 900, "session_id": "fixed-session"}}
		if path == "/v1/account":
			return {"success": true, "body": {"account": {"id": "account-a", "display_name": "Developer"}, "allowance": {"currency": "USD", "units_per_currency": 1000000, "available_units": 5000000, "reserved_units": 0}}}
		if path == "/v1/models":
			return {"success": true, "body": {"data": []}}
		if path == "/v1/auth/logout":
			return {"success": true, "body": {"signed_out": true}}
		return {"success": true, "body": {}}

class CapturingClient:
	extends Node
	signal request_completed(request_id: int, response: Dictionary)
	signal request_failed(request_id: int, error: Dictionary)
	signal request_cancelled(request_id: int)
	signal stream_started(request_id: int)
	signal stream_delta(request_id: int, content: String)
	var calls := 0
	func is_requesting() -> bool: return false
	func send_chat_completion(_messages, _tools, _profile, _options) -> void: calls += 1
	func cancel_request() -> void: pass

class FixtureController:
	extends Controller
	var profile := {}
	func _capture_provider_config() -> Dictionary: return profile.duplicate(true)
	func _load_project_instructions() -> Dictionary: return {"success": true, "found": false}
	func _discover_project_skills() -> Dictionary: return {"success": true, "skills": []}

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	var raw_navigation := {"id": "navigation-fixture", "context_window": 32768, "max_output_tokens": 8192, "effort": {"supported_levels": ["default"]}, "orca": {"protocol": "chat_completions", "tools": true, "continuation_style": "standard", "capability_version": "test-v1", "availability": "available", "access": {"allowed": true}}}
	for flag in [null, false, true, "true", 1]:
		var catalog := raw_navigation.duplicate(true)
		if flag != null:
			catalog["orca"]["project_code_navigation"] = flag
		var records := CloudProvider.normalize_catalog({"data": [catalog]})
		check(records.size() == 1 and records[0]["project_code_navigation"] == (typeof(flag) == TYPE_BOOL and flag == true), "only explicit boolean catalog support may enable Cloud code navigation")
	var vault := MemoryVault.new()
	vault.record = {"version": 1, "origin": CloudProvider.ORIGIN, "refresh_token": "saved-refresh", "session_id": "fixed-session"}
	var service := FixtureService.new()
	service._vault = vault
	root.add_child(service)
	check(service._request_url("/v1/auth/device/code") == "https://cloud.aiorca.dev/v1/auth/device/code", "pairing API uses the deployed HTTPS origin")
	check(service._safe_browser_url("https://cloud.aiorca.dev/activate?user_code=ABCDE-FGHJK", "/activate"), "production activation URL is accepted")
	for url in ["http://127.0.0.1:8000/activate?user_code=ABCDE-FGHJK", "http://cloud.aiorca.dev/activate?user_code=ABCDE-FGHJK", "https://cloud.aiorca.dev.attacker.example/activate?user_code=ABCDE-FGHJK", "https://cloud.aiorca.dev/activate?user_code=ABCDE-FGHJK&redirect=elsewhere"]:
		check(not service._safe_browser_url(url, "/activate"), "activation rejects wrong origins and extra query data")
	var browser := {"url": ""}
	service.browser_opener = func(url: String): browser["url"] = url
	service.open_console()
	check(browser["url"] == "https://cloud.aiorca.dev/account", "Console opens the deployed account page")
	check(service._scope != ("dev.aiorca.EditorAccount.v1|http://127.0.0.1:8000").sha256_text(), "production vault scope is distinct from local development")
	await service.restore_connection()
	check(service.connected() and service.rotations == 1, "restore rotates once and loads account")
	check(not vault.record.has("access_token"), "access token is not persisted")
	var principal := service.identity()
	var authorized: Dictionary = await service.authorization(principal)
	check(authorized.get("success", false) and service.rotations == 1, "valid token is reused without rotation")
	check(not (await service.authorization("different-account")).get("success", false), "account drift denied")
	service._tokens["expires_at"] = 0
	check((await service.authorization(principal)).get("success", false) and service.rotations == 2, "expired access rotates using stored refresh")
	check(service.identity() == principal, "refresh preserves turn identity")
	service._tokens["expires_at"] = 0
	service.delay_refresh = true
	var results := {}
	_collect_authorization(service, principal, results, "one")
	_collect_authorization(service, principal, results, "two")
	while results.size() < 2:
		await process_frame
	check(service.rotations == 3 and results["one"].get("success", false) and results["two"].get("token") == results["one"].get("token"), "simultaneous consumers share one refresh")
	service.models = CloudProvider.normalize_catalog({"data": [{"id": "model-fixture", "name": "Fixture", "context_window": 32768, "max_output_tokens": 8192, "effort": {"supported_levels": ["default"]}, "orca": {"protocol": "chat_completions", "tools": true, "agent": {"status": "operator_verified", "capability_version": "test-v1", "tool_contract": "orca-tools-v1"}, "context_budget": {"version": "utf8-conservative-v2", "text_bytes_per_token": 3, "message_overhead": 32, "tool_overhead": 64, "image_tokens": 16384, "opaque_reasoning_bytes": false}, "continuation_style": "standard", "capability_version": "test-v1", "availability": "available", "access": {"allowed": true}}}]})
	var profile := service.profile_config("model-fixture")
	check(ImageCapability.resolve(profile) == "unsupported", "missing hosted image metadata remains text-only")
	var vision_catalog := service.models.duplicate(true)
	vision_catalog[0]["image_input"] = true
	service.models.assign(vision_catalog)
	check(ImageCapability.resolve(service.profile_config("model-fixture")) == "supported", "authenticated hosted vision metadata reaches image intake")
	check(ImageCapability.resolve(profile) == "unsupported", "catalog refresh preserves the old turn's immutable image policy")
	service.models[0]["allowed"] = false
	check(ImageCapability.resolve(service.profile_config("model-fixture")) == "unsupported", "locked hosted vision model cannot accept new images")
	service.models[0]["allowed"] = true
	check(ImageCapability.resolve(service.profile_config("unknown-model")) == "unsupported", "unknown hosted aliases cannot inherit image capability")
	check(profile.get("agent_compatibility", {}).is_empty(), "managed fixture has no user probe record")
	check(service.profile_config("model-fixture", "high")["reasoning_effort"] == "default", "managed reasoning uses server default without configuration")
	var controller := FixtureController.new()
	controller.account_service = service
	root.add_child(controller)
	controller._turn_provider_config = profile.duplicate(true)
	check(controller._turn_allows_tools(), "verified managed profile enables eligible tools automatically")
	var old_names: Array = controller._get_tool_definitions().map(func(tool): return tool["function"]["name"])
	check(old_names.has("read_file") and not old_names.has("find_project_symbols") and not old_names.has("find_symbol_references"), "legacy Cloud catalogs must retain existing tools without sending unsupported new schemas")
	check(not old_names.has("inspect_animation"), "legacy Cloud catalogs omit animation inspection")
	var legacy_listing: Dictionary = await controller._execute_tool_call({"id": "legacy_listing", "function": {"name": "list_directory", "arguments": '{"path":"res://tests/fixtures"}'}})
	check(legacy_listing["outcome"] == "completed" and legacy_listing["execution"]["data"]["sidecars_omitted"] == 0 and not legacy_listing["arguments"].has("include_sidecars"), "legacy Cloud retains companion visibility without changing canonical call arguments")
	for definition in controller._get_tool_definitions():
		if definition["function"]["name"] == "inspect_scene": check(not definition["function"]["parameters"]["properties"].has("scope"), "legacy schemas omit focused-scene arguments")
		if definition["function"]["name"] == "list_directory": check(not definition["function"]["parameters"]["properties"].has("include_sidecars"), "legacy schemas omit compact-listing options")
	for call in [
		{"name": "inspect_animation", "arguments": "{}"},
		{"name": "inspect_scene", "arguments": '{"scene_path":"res://main.tscn","scope":"node","node_path":"."}'},
		{"name": "list_directory", "arguments": '{"path":"res://","include_sidecars":true}'}
	]:
		var denied: Dictionary = await controller._execute_tool_call({"id": "unadvertised_inspection", "function": call})
		check(denied["outcome"] == "failed" and denied["result"].contains("does not advertise"), "runtime denies every unadvertised focused tool/option")
	service.models[0]["focused_inspection"] = true
	controller._turn_provider_config = service.profile_config("model-fixture")
	check(controller._get_tool_definitions().map(func(tool): return tool["function"]["name"]).has("inspect_animation"), "advertised focused inspection joins normal managed readiness")
	service.models[0]["focused_inspection"] = false
	check(controller._turn_allows_focused_inspection() and not service.profile_config("model-fixture")["hosted_focused_inspection"], "focus capability remains fixed through the active turn")
	controller._turn_provider_config["hosted_focused_inspection"] = "true"
	check(not controller._turn_allows_focused_inspection(), "malformed focus flag cannot enable tools")
	controller._turn_provider_config = profile.duplicate(true)
	var unavailable: Dictionary = await controller._execute_tool_call({"id": "unadvertised_navigation", "function": {"name": "find_project_symbols", "arguments": "{}"}})
	check(unavailable["outcome"] == "failed" and unavailable["result"].contains("does not advertise"), "runtime checks must deny unadvertised Cloud navigation even when called directly")
	service.models[0]["project_code_navigation"] = true
	var newer_profile := service.profile_config("model-fixture")
	controller._turn_provider_config = newer_profile.duplicate(true)
	var new_names: Array = controller._get_tool_definitions().map(func(tool): return tool["function"]["name"])
	check(new_names.has("find_project_symbols") and new_names.has("find_symbol_references"), "advertised navigation must pass the existing managed gate and become available")
	service.models[0]["project_code_navigation"] = false
	check(controller._get_tool_definitions().map(func(tool): return tool["function"]["name"]).has("find_project_symbols") and not service.profile_config("model-fixture")["hosted_code_navigation"], "catalog changes must affect only future turn snapshots")
	controller._turn_provider_config["hosted_code_navigation"] = "true"
	check(not controller._turn_allows_code_navigation(), "malformed navigation feature flags must not grant tools")
	controller._turn_provider_config = profile.duplicate(true)
	controller._turn_provider_config["capability_version"] = "changed"
	check(not controller._turn_allows_tools(), "capability drift invalidates operator verification")
	controller._turn_provider_config = profile.duplicate(true)
	controller._turn_provider_config["hosted_tools"] = false
	check(not controller._turn_allows_tools(), "chat-only metadata cannot inherit an enabled pass")
	controller._turn_provider_config = profile.duplicate(true)
	controller._turn_provider_config["hosted_identity"] = "another-session"
	check(not controller._turn_allows_tools(), "account drift denies local tools")
	profile["agent_compatibility"] = {"enabled": false}
	controller.profile = profile
	var transport := CapturingClient.new()
	controller.set_api_client_for_testing(transport)
	service._tokens["expires_at"] = 0
	check(controller.send_user_message("A cancellable hosted request."), "owned authentication wait begins")
	controller.cancel_current_request()
	for frame in 4:
		await process_frame
	check(not controller.is_busy() and transport.calls == 0, "Stop during refresh launches no orphan inference")
	controller.free()
	check(not service._accept_tokens({"access_token": "bad\nheader"}), "invalid credentials denied")
	await service.sign_out()
	check(not service.connected() and vault.record.is_empty(), "logout erases saved credentials")
	service.free()
	var local_vault := MemoryVault.new()
	local_vault.record = {"version": 1, "origin": "http://127.0.0.1:8000", "refresh_token": "local-refresh", "session_id": "local-session"}
	var local_record := local_vault.record.duplicate(true)
	var migrated_service := FixtureService.new()
	migrated_service._vault = local_vault
	root.add_child(migrated_service)
	await migrated_service.restore_connection()
	check(not migrated_service.connected() and migrated_service.calls.is_empty(), "local credentials are never refreshed against production")
	check(local_vault.record == local_record, "wrong-origin credentials are not rewritten or erased")
	migrated_service.free()
	var malformed := CloudProvider.normalize_catalog({"data": [{"id": "bad"}]})
	check(malformed.is_empty(), "malformed catalog denied")
	var store := Store.new()
	root.add_child(store)
	check(store.helper_service != null and not store._executable().begins_with("res://"), "credential store resolves only verified user-cache helpers, never a bundled executable")
	store.free()
	print("Account service tests: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _collect_authorization(service, principal: String, results: Dictionary, key: String) -> void:
	results[key] = await service.authorization(principal)
