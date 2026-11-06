extends SceneTree

const Account = preload("res://addons/orca/scripts/account_service.gd")
const Client = preload("res://addons/orca/scripts/api_client.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const NativeStore = preload("res://addons/orca/scripts/credential_store.gd")
const Images = preload("res://addons/orca/scripts/image_attachments.gd")
const ImageCapability = preload("res://addons/orca/scripts/image_capability.gd")
const CloudProvider = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")
var failures := 0

class FixtureVault:
	extends RefCounted
	var record := {}
	func available() -> bool: return true
	func acquire(_scope: String) -> bool: return true
	func read_record() -> Dictionary: return {"success": true, "record": record.duplicate(true)}
	func write_record(value: Dictionary) -> bool:
		record = value.duplicate(true)
		return true
	func erase() -> bool:
		record.clear()
		return true
	func release() -> void: pass

class FixtureAccount:
	extends Account
	var origin := ""
	func _request_url(path: String) -> String: return origin + path
	func _request(path: String, method: int, body: Dictionary = {}, token: String = "") -> Dictionary:
		var result: Dictionary = await super._request(path, method, body, token)
		# The disposable server supplies synthetic pairing URLs. Project only that
		# fixture reply onto the canonical origin to exercise production validation;
		# browser approval and all account HTTP requests still use localhost.
		if path == "/v1/auth/device/code" and result.get("success", false):
			result["body"]["verification_uri"] = CloudProvider.ORIGIN + "/activate"
			result["body"]["verification_uri_complete"] = CloudProvider.ORIGIN + "/activate?user_code=" + str(result["body"].get("user_code", ""))
		return result
	func approve(url: String) -> void:
		await _request("/v1/test/approve", HTTPClient.METHOD_POST, {"user_code": url.get_slice("user_code=", 1)})

class FixtureClient:
	extends Client
	var fixture_port := 0
	var fixture_target := ""
	func _parse_url(url: String) -> Dictionary:
		var endpoint: Dictionary = super._parse_url(url)
		# Redirect transport only, after the real fixed-origin authorization gate.
		endpoint["scheme"] = "http"
		endpoint["host"] = "127.0.0.1"
		endpoint["port"] = fixture_port
		if not fixture_target.is_empty():
			endpoint["target"] = fixture_target
		return endpoint

class FixtureController:
	extends Controller
	var fixture_profile := {}
	func _capture_provider_config() -> Dictionary: return fixture_profile.duplicate(true)

func _init() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	var setup = JSON.parse_string(OS.read_string_from_stdin())
	if typeof(setup) != TYPE_DICTIONARY or not str(setup.get("origin", "")).begins_with("http://127.0.0.1:"):
		quit(1)
		return
	var origin: String = setup["origin"]
	var port := int(origin.get_slice(":", 2))
	var native_scope := str(setup.get("native_scope", ""))
	var stage := str(setup.get("stage", ""))
	if stage == "cleanup":
		var store := NativeStore.new()
		root.add_child(store)
		if await store.acquire(native_scope):
			await store.erase()
			store.release()
		store.free()
		quit(0)
		return
	var vault := FixtureVault.new()
	var account := FixtureAccount.new()
	account.origin = origin
	if native_scope.is_empty():
		account._vault = vault
	account.browser_opener = account.approve
	root.add_child(account)
	if not native_scope.is_empty():
		account._scope = native_scope
	if stage == "restore":
		await account.restore_connection()
	else:
		account.begin_pairing()
	var deadline := Time.get_ticks_msec() + 20000
	while (not account.connected() or account.state != "connected") and Time.get_ticks_msec() < deadline:
		await process_frame
	check(account.connected(), "browser pairing connected")
	if not account.connected():
		print("Pairing state: " + account.status)
		quit(1)
		return
	if stage == "pair":
		account.free() # Actual process exit keeps the saved editor session.
		print("Native pairing persisted: PASS")
		quit(0)
		return
	var first_identity := account.identity()
	if native_scope.is_empty():
		account.free() # Simulated editor restart: do not sign out or revoke the session.
		account = FixtureAccount.new()
		account.origin = origin
		account._vault = vault
		root.add_child(account)
		await account.restore_connection()
	check(account.connected() and account.identity() == first_identity, "restart restores same account/session with rotated credentials")
	var profile: Dictionary = account.profile_config(str(setup.get("model", "orca-cloud-fixture")))
	check(profile.get("hosted_agent_ready", false), "operator-verified managed model is ready without a user probe")
	check(profile.get("agent_compatibility", {}).is_empty(), "fixture provides no user compatibility grant")
	var controller := FixtureController.new()
	controller.account_service = account
	controller.fixture_profile = profile
	root.add_child(controller)
	var client := FixtureClient.new()
	client.fixture_port = port
	client.account_service = account
	controller.set_api_client_for_testing(client)
	var events := {"reads": 0, "errors": 0, "answer": false}
	var code_navigation: bool = setup.get("code_navigation") == "1"
	var focused_inspection: bool = setup.get("focused_inspection") == "1"
	if focused_inspection:
		check(profile.get("hosted_focused_inspection", false), "authenticated catalog advertises focused-inspection vocabulary")
	if code_navigation:
		check(profile.get("hosted_code_navigation", false), "authenticated catalog advertises code-navigation vocabulary")
	controller.tool_execution_completed.connect(func(_turn, _call, tool, execution, _duration):
		if tool == "read_file" or (code_navigation and tool in ["find_project_symbols", "find_symbol_references"]) or (focused_inspection and tool in ["inspect_scene", "inspect_animation", "list_directory"]):
			events["reads"] += 1
			check(execution.get("success", false), "real hosted read tool succeeds")
			if code_navigation:
				check(execution.get("data", {}).get("source") == "saved_gdscript_lexical_scan" and execution.get("data", {}).get("matches", []).size() == 1, "fragmented hosted navigation returns the exact saved declaration without an edit hash"))
	controller.error_occurred.connect(func(_turn, message):
		events["errors"] += 1
		print("Fixture controller error: " + str(message)))
	controller.message_received.connect(func(_turn, role, content, _attribution): events["answer"] = role == "assistant" and str(content).contains("completed"))
	var images: Array = []
	if setup.get("image") == "1":
		check(ImageCapability.resolve(profile) == "supported", "authenticated live catalog confirms image input")
		var pixels := Image.create(256, 128, false, Image.FORMAT_RGB8)
		pixels.fill(Color.RED)
		var prepared := Images.prepare_image(pixels, "Hosted image fixture.png")
		check(prepared.get("success", false), "hosted fixture image prepared")
		images.append(prepared["image"])
	check(controller.send_user_message("hi", images), "fresh request with full editor instructions, Work schemas and optional image submitted")
	while controller.is_busy():
		await process_frame
	check(events["reads"] == (3 if focused_inspection else 2 if code_navigation else 1) and events["errors"] == 0 and events["answer"], "real tool continuation completes exactly once")
	check(not JSON.stringify(controller.snapshot_session_state()).contains("fixture-private"), "private continuation absent from persistence")
	var auth: Dictionary = await account.authorization()
	var receipt: Dictionary = await account._request("/v1/account/usage", HTTPClient.METHOD_GET, {}, auth["token"])
	check(receipt.get("success", false) and receipt["body"].get("data", []).size() >= 2, "metered receipts exist for automatic managed tool rounds")
	for kind in ["eof", "json", "error", "credits"]:
		var failure_client := FixtureClient.new()
		failure_client.fixture_port = port
		failure_client.fixture_target = "/v1/test/stream/" + kind
		root.add_child(failure_client)
		var terminal := {"failed": false, "completed": false, "error": {}}
		failure_client.request_completed.connect(func(_id, _response): terminal["completed"] = true)
		failure_client.request_failed.connect(func(_id, error):
			terminal["failed"] = true
			terminal["error"] = error)
		var request_config := profile.duplicate(true)
		request_config["api_key"] = auth["token"]
		failure_client.send_chat_completion([{"role": "user", "content": "Fixture failure"}], [], request_config)
		while failure_client.is_requesting():
			await process_frame
		check(terminal["failed"] and not terminal["completed"], "hosted " + kind + " does not become success")
		check(not str(terminal["error"].get("message", "")).contains("fixture-token-do-not-display"), "error body privacy")
		if kind == "credits":
			check(terminal["error"].get("code") == "insufficient_credits", "credit exhaustion remains actionable")
		failure_client.free()
	controller.free()
	await account.sign_out()
	check(vault.record.is_empty() and not account.connected(), "sign-out clears credentials")
	if not native_scope.is_empty():
		if await account._vault.acquire(native_scope):
			var persisted: Dictionary = await account._vault.read_record()
			check(persisted.get("success", false) and persisted.get("record", {}) == {}, "native persisted credentials removed on sign-out")
			account._vault.release()
		else:
			check(false, "native logout cleanup could not be verified")
	account.free()
	print("Orca Cloud Godot/backend integration: " + ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
