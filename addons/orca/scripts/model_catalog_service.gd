@tool
extends Node

signal metadata_updated

const Config = preload("res://addons/orca/scripts/config.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const CATALOG_URL := "https://models.dev/api.json"
const CACHE_LIFETIME_SECONDS := 7 * 24 * 60 * 60
const MAX_CATALOG_BYTES := 8 * 1024 * 1024
const MAX_REFRESH_ATTEMPTS := 2

var _request: HTTPRequest
var _active_request: Dictionary = {}
var _pending_requests: Array[Dictionary] = []
var _catalog: Dictionary = {}
var _refresh_attempts := 0


func _ready() -> void:
	_request = HTTPRequest.new()
	_request.timeout = 30.0
	_request.body_size_limit = MAX_CATALOG_BYTES
	_request.request_completed.connect(_on_request_completed)
	add_child(_request)


func refresh(model: String, api_url: String) -> void:
	var provider := ModelMetadata.infer_provider(api_url, model)
	if provider.is_empty() or model.strip_edges().is_empty():
		return
	var requested_model := model.strip_edges()
	var cached := Config.get_cached_model_metadata(provider, requested_model)
	if not cached.is_empty():
		ModelMetadata.set_runtime_metadata(provider, requested_model, cached.get("metadata", {}))
		metadata_updated.emit()
		if Time.get_unix_time_from_system() - float(cached.get("fetched_at", 0.0)) < CACHE_LIFETIME_SECONDS:
			return
	if not _catalog.is_empty():
		_apply_catalog_metadata(provider, requested_model)
		return
	var request_data := {"provider": provider, "model": requested_model}
	if _active_request == request_data or request_data in _pending_requests:
		return
	_pending_requests.append(request_data)
	_start_next_request()


func _start_next_request() -> void:
	if not _active_request.is_empty() or _pending_requests.is_empty():
		return
	_active_request = _pending_requests.pop_front()
	if not _catalog.is_empty():
		_apply_catalog_metadata(str(_active_request["provider"]), str(_active_request["model"]))
		_active_request.clear()
		call_deferred("_start_next_request")
		return
	var error := _request.request(CATALOG_URL)
	if error != OK:
		_handle_request_failure()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var request_data := _active_request.duplicate()
	_active_request.clear()
	if result != HTTPRequest.RESULT_SUCCESS or response_code != HTTPClient.RESPONSE_OK or body.size() > MAX_CATALOG_BYTES:
		_active_request = request_data
		_handle_request_failure()
		return
	var catalog = JSON.parse_string(body.get_string_from_utf8())
	if typeof(catalog) != TYPE_DICTIONARY:
		_active_request = request_data
		_handle_request_failure()
		return
	_catalog = catalog
	_refresh_attempts = 0
	var provider := str(request_data.get("provider", ""))
	var model := str(request_data.get("model", ""))
	_apply_catalog_metadata(provider, model)
	call_deferred("_start_next_request")


func _apply_catalog_metadata(provider: String, model: String) -> void:
	var metadata := ModelMetadata.metadata_from_catalog(_catalog, provider, model)
	if metadata.is_empty():
		ModelMetadata.remove_runtime_metadata(provider, model)
		metadata = ModelMetadata.resolve(model, _provider_url(provider))
	if metadata.get("source") == "unavailable":
		Config.remove_cached_model_metadata(provider, model)
		metadata_updated.emit()
		return
	ModelMetadata.set_runtime_metadata(provider, model, metadata)
	Config.set_cached_model_metadata(provider, model, metadata)
	metadata_updated.emit()


func _handle_request_failure() -> void:
	var failed_request := _active_request.duplicate()
	_active_request.clear()
	_refresh_attempts += 1
	if _refresh_attempts < MAX_REFRESH_ATTEMPTS and not failed_request.is_empty():
		_pending_requests.push_front(failed_request)
	else:
		_pending_requests.clear()
		_refresh_attempts = 0
	call_deferred("_start_next_request")


func _provider_url(provider: String) -> String:
	match provider:
		"openai":
			return "https://api.openai.com"
		"deepseek":
			return "https://api.deepseek.com"
		"openrouter":
			return "https://openrouter.ai"
		"groq":
			return "https://api.groq.com"
		"togetherai":
			return "https://api.together.xyz"
		"mistral":
			return "https://api.mistral.ai"
		"google":
			return "https://generativelanguage.googleapis.com"
		"xai":
			return "https://api.x.ai"
	return ""
