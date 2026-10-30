@tool
extends Node

signal changed
signal refresh_finished
signal signed_in

const Config = preload("res://addons/orca/scripts/config.gd")
const CredentialStore = preload("res://addons/orca/scripts/credential_store.gd")
const CloudProvider = preload("res://addons/orca/scripts/providers/orca_cloud_provider.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const MAX_RESPONSE := 64 * 1024

var state := "signed_out"
var status := "Sign in to use Orca-hosted models."
var pairing_code := ""
var models: Array[Dictionary] = []
var account: Dictionary = {}
var _tokens: Dictionary = {}
var _vault
var native_helper
var _generation := 0
var _refreshing := false
var _pairing_secret := ""
var _pairing_url := ""
var _scope := ""
var _closed := false
var _signing_out := false
var _requests: Array[HTTPRequest] = []
var _account_refresh_serial := 0
var _startup_restore_pending := false
var browser_opener := Callable()


func _ready() -> void:
	if _vault == null:
		_vault = CredentialStore.new()
		add_child(_vault)
		native_helper = _vault.helper_service
	if native_helper != null and not native_helper.changed.is_connected(_on_native_helper_changed):
		native_helper.changed.connect(_on_native_helper_changed)
	# OS vaults are per-user. Share one connection across projects; the native
	# lock serializes refresh rotation across all editor processes.
	_scope = ("dev.aiorca.EditorAccount.v1|" + CloudProvider.ORIGIN).sha256_text()
	# The vault is authoritative; an EditorSettings marker can be stale when
	# several editors save preferences. Tests can explicitly suppress owner login.
	if Engine.is_editor_hint() and OS.get_environment("ORCA_DISABLE_ACCOUNT_RESTORE") != "1" and (_vault.available() or (native_helper != null and not native_helper.entry.is_empty() and native_helper.automatic_downloads_enabled())):
		_startup_restore_pending = true
		call_deferred("_restore_after_helper", _generation)


func _restore_after_helper(generation: int) -> void:
	if not _closed and generation == _generation and not _vault.available() and native_helper != null:
		await native_helper.prepare()
	if not _closed and generation == _generation and _vault.available():
		await restore_connection()
	_startup_restore_pending = false
	if not _closed:
		changed.emit()


func onboarding_restoration_pending() -> bool:
	# A configured Cloud model is an onboarding hint only, never vault authority.
	return state == "restoring" or (_startup_restore_pending and not str(Config.get_provider_config("orca_cloud").get("model", "")).is_empty())


func connected() -> bool:
	return not _tokens.is_empty() and not account.is_empty()


func identity() -> String:
	return (str(account.get("id", "")) + "|" + str(_tokens.get("session_id", ""))).sha256_text() if connected() else ""


func profile_config(model_id: String, effort: String = "default") -> Dictionary:
	effort = "default" # Managed deployments use the operator-tested server default.
	var record := model_record(model_id)
	var result := {
		"provider": "orca_cloud", "base_url": CloudProvider.BASE_URL, "model": model_id,
		"api_key": "", "reasoning_effort": effort, "api_mode": "chat_completions",
		"continuation_style": str(record.get("continuation_style", "standard")),
		"agent_compatibility": {}, # Managed readiness is operator-owned, not a user toggle.
		"hosted_identity": identity(), "capability_version": str(record.get("capability_version", "")),
		"hosted_context_window": int(record.get("context_window", 0)),
		"hosted_output_tokens": mini(8192, int(record.get("max_output_tokens", 8192))),
		"hosted_image_input": bool(record.get("image_input", false)),
		"hosted_tools": bool(record.get("tools", false)), "hosted_allowed": bool(record.get("allowed", false)),
		"hosted_agent_ready": bool(record.get("agent_ready", false)),
		"hosted_verified_capability": str(record.get("verified_capability", "")),
		"hosted_context_policy": record.get("context_budget", {}).duplicate(true),
		"hosted_available": record.get("availability", "") == "available",
		"hosted_pricing": record.get("pricing", {}).duplicate(true)
	}
	return result


func model_record(model_id: String) -> Dictionary:
	for record in models:
		if record.get("id") == model_id:
			return record.duplicate(true)
	return {}


func begin_pairing() -> void:
	if _refreshing or _signing_out or state in ["connecting", "pairing", "restoring"] or _closed:
		return
	_generation += 1
	var generation := _generation
	_startup_restore_pending = false
	_set_state("connecting", "Preparing connection…")
	if generation != _generation or _closed:
		return
	if not _vault.available():
		var prepared: bool = await native_helper.prepare() if native_helper != null else false
		if generation != _generation or _closed:
			return
		if not prepared or not _vault.available():
			_set_state("signed_out", str(native_helper.status) if native_helper != null else "Secure credential storage is unavailable. Enable your OS credential vault.")
			return
	var result := await _request("/v1/auth/device/code", HTTPClient.METHOD_POST, {"client_id": "orca-godot", "device_label": "Godot editor"})
	if generation != _generation or _closed:
		return
	var body: Dictionary = result.get("body", {})
	if not result.get("success", false) or not _valid_secret(body.get("device_code")) or not _safe_browser_url(str(body.get("verification_uri_complete", "")), "/activate") or body.get("verification_uri_complete") != CloudProvider.ORIGIN + "/activate?user_code=" + str(body.get("user_code", "")):
		_set_state("signed_out", "Orca Cloud could not start sign-in. Check your connection and try again.")
		return
	_pairing_secret = body["device_code"]
	_pairing_url = body["verification_uri_complete"]
	pairing_code = str(body.get("user_code", "")).left(32)
	var deadline := Time.get_ticks_msec() + clampi(int(body.get("expires_in", 600)), 1, 600) * 1000
	var interval := clampi(int(body.get("interval", 5)), 5, 60)
	_set_state("pairing", "Sign in or sign up in your browser, then approve this editor.")
	open_pairing_browser()
	while generation == _generation and not _closed and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(interval).timeout
		if generation != _generation or _closed:
			return
		result = await _request("/v1/auth/device/token", HTTPClient.METHOD_POST, {"device_code": _pairing_secret})
		if generation != _generation or _closed:
			return
		if result.get("success", false):
			_pairing_secret = ""
			pairing_code = ""
			_pairing_url = ""
			if not _accept_tokens(result.get("body", {})):
				_set_state("signed_out", "The account service returned invalid credentials. Start sign-in again.")
				return
			if not await _vault.acquire(_scope):
				await _forget_session()
				_set_state("signed_out", "The OS credential vault could not be opened. Unlock it and sign in again.")
				return
			var saved: bool = await _vault.write_record(_saved_record())
			_vault.release()
			if not saved:
				await _forget_session()
				_set_state("signed_out", "Your connection could not be saved securely. Unlock the OS vault and try again.")
				return
			await refresh_account()
			if generation == _generation and connected():
				signed_in.emit()
			return
		var code := str(result.get("code", ""))
		if code in ["authorization_pending", "slow_down"]:
			interval = clampi(int(result.get("retry_after", interval)), interval, 60)
			continue
		_pairing_secret = ""
		_set_state("signed_out", "Sign-in was declined or interrupted. Start a new connection.")
		return
	if generation == _generation:
		await cancel_pairing()
		_set_state("signed_out", "The pairing code expired. Sign in again to get a new code.")


func cancel_pairing() -> void:
	_generation += 1
	_startup_restore_pending = false
	var secret := _pairing_secret
	_pairing_secret = ""
	_pairing_url = ""
	pairing_code = ""
	_set_state("connected" if connected() else "signed_out", "Connected." if connected() else "Sign-in cancelled.")
	if not secret.is_empty():
		await _request("/v1/auth/device/cancel", HTTPClient.METHOD_POST, {"device_code": secret})


func _on_native_helper_changed() -> void:
	changed.emit()


func open_pairing_browser() -> void:
	if not _pairing_url.is_empty() and _safe_browser_url(_pairing_url, "/activate"):
		_open_browser(_pairing_url)


func open_console() -> void:
	_open_browser(CloudProvider.ORIGIN + "/account")


func invalidate_access(expected_identity: String) -> void:
	if not expected_identity.is_empty() and expected_identity == identity():
		_tokens["expires_at"] = 0
		_set_state("connected", "Refresh your account connection before the next request.")


func restore_connection() -> void:
	if _refreshing or _closed or connected():
		return
	_set_state("restoring", "Restoring your Orca connection…")
	if not await _refresh_credentials():
		return
	await refresh_account()


func authorization(expected_identity: String = "") -> Dictionary:
	var generation := _generation
	if not expected_identity.is_empty() and expected_identity != identity():
		return {"success": false}
	if float(_tokens.get("expires_at", 0.0)) <= Time.get_unix_time_from_system() + 60:
		if not await _refresh_credentials():
			return {"success": false}
	if generation != _generation or _closed or (not expected_identity.is_empty() and expected_identity != identity()):
		return {"success": false}
	return {"success": true, "token": str(_tokens.get("access_token", ""))}


func refresh_account() -> void:
	var generation := _generation
	_account_refresh_serial += 1
	var serial := _account_refresh_serial
	var auth := await authorization()
	if not auth.get("success", false) or generation != _generation:
		return
	var result := await _request("/v1/account", HTTPClient.METHOD_GET, {}, auth["token"])
	if generation != _generation or _closed or serial != _account_refresh_serial:
		return
	if not result.get("success", false):
		if int(result.get("status", 0)) == 401:
			await _invalidate_saved_connection()
		_set_state("signed_out" if _tokens.is_empty() else "connected", "Account information could not be refreshed. Reconnect if your session was revoked.")
		return
	var body: Dictionary = result["body"]
	var raw = body.get("account")
	if typeof(raw) != TYPE_DICTIONARY or not _bounded_string(raw.get("id"), 128) or not _bounded_string(raw.get("display_name"), 100):
		_set_state("connected", "The account service returned invalid account information.")
		return
	account = {"id": raw["id"], "display_name": raw["display_name"], "allowance": {}, "subscription": {}}
	account["plan_name"] = "Free"
	var capabilities = body.get("capabilities", {})
	if typeof(capabilities) == TYPE_DICTIONARY and typeof(capabilities.get("model_access_plans")) == TYPE_ARRAY:
		for plan in capabilities["model_access_plans"].slice(0, 10):
			if typeof(plan) == TYPE_DICTIONARY and _bounded_string(plan.get("name"), 100):
				account["plan_name"] = plan["name"]
				break
	var allowance = body.get("allowance", {})
	if typeof(allowance) == TYPE_DICTIONARY and allowance.get("currency") == "USD" and allowance.get("units_per_currency") == 1000000:
		for field in ["available_units", "paid_available_units", "free_available_units", "reserved_units", "unknown_reserved_units"]:
			var value = allowance.get(field, 0)
			if typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= 0 and float(value) <= 9007199254740991:
				account["allowance"][field] = int(value)
	var subscription = body.get("subscription")
	if typeof(subscription) == TYPE_DICTIONARY:
		account["subscription"] = {"status": str(subscription.get("status", "")).left(32), "plan_id": str(subscription.get("plan_id", "")).left(100)}
	result = await _request("/v1/models", HTTPClient.METHOD_GET, {}, auth["token"])
	if generation != _generation or _closed or serial != _account_refresh_serial:
		return
	if result.get("success", false):
		models = CloudProvider.normalize_catalog(result["body"])
		for model in models:
			ModelMetadata.set_runtime_metadata("orca_cloud", str(model["id"]), pricing_metadata(model))
	_set_state("connected", "Your account is connected. Hosted models are ready to use.")


func sign_out() -> void:
	if _signing_out:
		return
	_signing_out = true
	if _refreshing:
		await refresh_finished
	var session_id := str(_tokens.get("session_id", ""))
	var token := str(_tokens.get("access_token", ""))
	_set_state("signing_out", "Signing out…")
	if connected():
		var auth := await authorization(identity())
		if auth.get("success", false):
			token = str(auth["token"])
	_generation += 1
	if not _pairing_secret.is_empty():
		await cancel_pairing()
	# Delete local credentials before awaiting network revocation, so closing the
	# editor during logout cannot restore an intentionally signed-out connection.
	var erased := await _invalidate_saved_connection(session_id)
	var revoked := await _forget_session(token)
	Config.clear_agent_compatibility("orca_cloud")
	_signing_out = false
	_set_state("signed_out", "Signed out." if erased and revoked else "Signed out locally. Check Orca Console to revoke the editor session if the backend or OS vault was unavailable.")


func cancel_remote_request(request_id: String, token: String) -> void:
	if _bounded_string(request_id, 128) and request_id.is_valid_identifier() == false and request_id.contains("-"):
		# Only backend opaque UUID receipt paths are accepted, never arbitrary URLs.
		if request_id.length() == 36 and request_id.replace("-", "").is_valid_hex_number(false):
			await _request("/v1/requests/" + request_id + "/cancel", HTTPClient.METHOD_POST, {}, token)


func _refresh_credentials() -> bool:
	if _refreshing:
		await refresh_finished
		return not _tokens.is_empty()
	_refreshing = true
	var generation := _generation
	var success := false
	var offline := false
	var no_saved_record := false
	if await _vault.acquire(_scope):
		var stored: Dictionary = await _vault.read_record()
		var record: Dictionary = stored.get("record", {})
		no_saved_record = stored.get("success", false) and record.is_empty()
		if no_saved_record:
			_tokens.clear()
			account.clear()
			models.clear()
		if stored.get("success", false) and record.get("origin") == CloudProvider.ORIGIN and _valid_secret(record.get("refresh_token")):
			var same_session: bool = _tokens.is_empty() or record.get("session_id") == _tokens.get("session_id")
			var result := await _request("/v1/auth/token/refresh", HTTPClient.METHOD_POST, {"refresh_token": record["refresh_token"]}) if same_session else {"success": false, "different_session": true}
			if generation == _generation and not _closed:
				if result.get("success", false) and result.get("body", {}).get("session_id") == record.get("session_id") and _accept_tokens(result.get("body", {})):
					success = await _vault.write_record(_saved_record())
				if not success:
					# An accepted or ambiguous rotation cannot safely reuse the old secret.
					offline = result.get("safe_pre_submit", false)
					if not offline and not result.get("different_session", false):
						await _vault.erase()
					_tokens.clear()
					account.clear()
					models.clear()
		_vault.release()
	_refreshing = false
	refresh_finished.emit()
	if not success:
		_set_state("signed_out", "Sign in to use Orca-hosted models." if no_saved_record else "The backend is offline. Your saved connection is retained; use Refresh account when it is available." if offline else "Your saved connection could not be restored. Check the backend and OS vault, then sign in again if needed.")
	return success


func _accept_tokens(body: Dictionary) -> bool:
	if body.get("token_type") != "Bearer" or not _valid_secret(body.get("access_token")) or not _valid_secret(body.get("refresh_token")) or not _bounded_string(body.get("session_id"), 128):
		return false
	var expires = body.get("expires_in", 0)
	if typeof(expires) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(expires)) or float(expires) != floorf(float(expires)) or float(expires) < 1 or float(expires) > 3600:
		return false
	_tokens = {"access_token": body["access_token"], "refresh_token": body["refresh_token"], "session_id": body["session_id"], "expires_at": Time.get_unix_time_from_system() + int(expires)}
	return true


func _saved_record() -> Dictionary:
	return {"version": 1, "origin": CloudProvider.ORIGIN, "refresh_token": _tokens["refresh_token"], "session_id": _tokens["session_id"]}


func _forget_session(token_override: String = "") -> bool:
	var token := token_override if not token_override.is_empty() else str(_tokens.get("access_token", ""))
	_tokens.clear()
	account.clear()
	models.clear()
	if not token.is_empty():
		var response := await _request("/v1/auth/logout", HTTPClient.METHOD_POST, {}, token)
		return response.get("success", false) and response.get("body", {}).get("signed_out") == true
	return true


func _invalidate_saved_connection(expected_session: String = "") -> bool:
	if expected_session.is_empty():
		expected_session = str(_tokens.get("session_id", ""))
	_tokens.clear()
	account.clear()
	models.clear()
	if await _vault.acquire(_scope):
		var stored: Dictionary = await _vault.read_record()
		var record: Dictionary = stored.get("record", {})
		var erased := false
		if stored.get("success", false):
			if record.is_empty() or (not expected_session.is_empty() and record.get("session_id") == expected_session):
				erased = await _vault.erase()
			else:
				erased = true # A newer/different session belongs to another editor.
		_vault.release()
		return erased
	return false


func _request(path: String, method: int, body: Dictionary = {}, token: String = "") -> Dictionary:
	if _closed or not path.begins_with("/v1/"):
		return {"success": false}
	if _requests.size() >= 4:
		return {"success": false, "safe_pre_submit": true, "status": 0}
	var request := HTTPRequest.new()
	request.timeout = 25.0
	request.body_size_limit = MAX_RESPONSE
	request.max_redirects = 0
	add_child(request)
	_requests.append(request)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if not token.is_empty():
		if not _valid_secret(token):
			request.queue_free()
			_requests.erase(request)
			return {"success": false}
		headers.append("Authorization: Bearer " + token)
	var error := request.request(_request_url(path), headers, method, "" if method == HTTPClient.METHOD_GET else JSON.stringify(body))
	if error != OK:
		_requests.erase(request)
		request.queue_free()
		return {"success": false}
	var reply: Array = await request.request_completed
	# Leave HTTPRequest's signal stack before callers may close/free the account
	# service (notably logout and editor teardown).
	await get_tree().process_frame
	if _closed or not is_instance_valid(request):
		return {"success": false}
	_requests.erase(request)
	request.queue_free()
	var bytes: PackedByteArray = reply[3]
	var text := bytes.get_string_from_utf8()
	var value = JSON.parse_string(text) if bytes.size() <= MAX_RESPONSE and text.to_utf8_buffer() == bytes else null
	var result := {"success": reply[0] == HTTPRequest.RESULT_SUCCESS and int(reply[1]) in range(200, 300) and typeof(value) == TYPE_DICTIONARY, "status": int(reply[1]), "body": value if typeof(value) == TYPE_DICTIONARY else {}}
	result["safe_pre_submit"] = reply[0] in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR]
	if typeof(value) == TYPE_DICTIONARY and typeof(value.get("error")) == TYPE_DICTIONARY:
		result["code"] = str(value["error"].get("code", "")).left(64)
	for header in reply[2]:
		if str(header).to_lower().begins_with("retry-after:"):
			result["retry_after"] = clampi(int(str(header).get_slice(":", 1).strip_edges()), 5, 60)
	return result


func _request_url(path: String) -> String:
	return CloudProvider.ORIGIN + path


static func pricing_metadata(model: Dictionary) -> Dictionary:
	var rates: Dictionary = model.get("pricing", {})
	var result := {"context_window": int(model.get("context_window", 0)), "source": "Orca Cloud catalog", "image_input": bool(model.get("image_input", false))}
	for pair in [["input_units_per_million", "input_per_million"], ["output_units_per_million", "output_per_million"], ["cached_units_per_million", "cached_input_per_million"], ["cache_write_units_per_million", "cache_write_per_million"]]:
		if rates.has(pair[0]):
			result[pair[1]] = float(rates[pair[0]]) / 1000000.0
	return result


func _safe_browser_url(url: String, path: String) -> bool:
	var prefix := CloudProvider.ORIGIN + path + "?user_code="
	if not url.begins_with(prefix):
		return false
	var code := url.substr(prefix.length())
	if code.length() < 5 or code.length() > 32:
		return false
	for character in code:
		if character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-":
			return false
	return true


func _open_browser(url: String) -> void:
	if browser_opener.is_valid():
		browser_opener.call(url)
	else:
		OS.shell_open(url)


func _set_state(value: String, message: String) -> void:
	state = value
	status = message
	changed.emit()


static func _bounded_string(value, limit: int) -> bool:
	if typeof(value) != TYPE_STRING or value.is_empty() or value.length() > limit:
		return false
	for character in value:
		if character.unicode_at(0) < 32 or character.unicode_at(0) == 127:
			return false
	return true


static func _valid_secret(value) -> bool:
	return _bounded_string(value, 8192) and not value.contains(" ")


func _exit_tree() -> void:
	_closed = true
	_generation += 1
	_tokens.clear()
	for request in _requests:
		if is_instance_valid(request):
			request.cancel_request()
	_requests.clear()
