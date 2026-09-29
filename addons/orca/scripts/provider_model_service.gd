@tool
extends Node

signal models_loaded(provider_id: String, models: Array, from_cache: bool)
signal models_failed(provider_id: String, message: String)

const Config = preload("res://addons/orca/scripts/config.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const MAX_MODEL_RESPONSE_BYTES := 8 * 1024 * 1024
const CACHE_LIFETIME_SECONDS := 60 * 60

var _request: HTTPRequest
var _generation := 0


func _ready() -> void:
	pass


func fetch_models(provider_id: String, config: Dictionary) -> void:
	_generation += 1
	if _request != null:
		_request.cancel_request()
		_request.queue_free()
	_request = HTTPRequest.new()
	_request.timeout = 30.0
	_request.body_size_limit = MAX_MODEL_RESPONSE_BYTES
	_request.request_completed.connect(_on_request_completed.bind(_generation, provider_id, config.duplicate(true)))
	add_child(_request)
	var api_key := str(config.get("api_key", ""))
	var credential_fingerprint := api_key.sha256_text().left(16)
	var cached := Config.get_cached_provider_models(provider_id, credential_fingerprint)
	if not cached.is_empty() and typeof(cached.get("models")) == TYPE_ARRAY:
		var cached_models: Array[Dictionary] = []
		cached_models.assign(cached["models"])
		_merge_public_metadata(provider_id, cached_models, str(config.get("base_url", "")))
		models_loaded.emit(provider_id, cached_models, true)
		if Time.get_unix_time_from_system() - float(cached.get("fetched_at", 0.0)) < CACHE_LIFETIME_SECONDS:
			return
	if api_key.is_empty():
		models_failed.emit(provider_id, "Enter an API key to load available models.")
		return
	var provider = ProviderRegistry.get_provider(provider_id)
	var error := _request.request(provider.models_url(config), provider.model_headers(api_key))
	if error != OK:
		models_failed.emit(provider_id, "Could not start model discovery: " + error_string(error))


func cancel() -> void:
	_generation += 1
	if _request != null:
		_request.cancel_request()
		_request.queue_free()
		_request = null


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, generation: int, provider_id: String, config: Dictionary) -> void:
	if generation != _generation:
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		models_failed.emit(provider_id, "Could not reach the provider's model endpoint.")
		return
	if response_code != HTTPClient.RESPONSE_OK:
		models_failed.emit(provider_id, "Provider returned HTTP %d while loading models." % response_code)
		return
	var response = JSON.parse_string(body.get_string_from_utf8())
	if typeof(response) != TYPE_DICTIONARY:
		models_failed.emit(provider_id, "Provider returned an invalid model list.")
		return
	var provider = ProviderRegistry.get_provider(provider_id)
	var models: Array[Dictionary] = provider.normalize_models(response)
	if models.is_empty():
		models_failed.emit(provider_id, "No compatible models were returned.")
		return
	_merge_public_metadata(provider_id, models, str(config.get("base_url", provider.definition().get("base_url", ""))))
	Config.set_cached_provider_models(provider_id, models, str(config.get("api_key", "")).sha256_text().left(16))
	models_loaded.emit(provider_id, models, false)


func _merge_public_metadata(provider_id: String, models: Array[Dictionary], api_url: String) -> void:
	var metadata_provider := ModelMetadata.infer_provider(api_url)
	if metadata_provider.is_empty():
		metadata_provider = provider_id
	for model in models:
		var model_id := str(model.get("id", ""))
		var public_metadata := ModelMetadata.resolve(model_id, api_url)
		for pair in [
			["context_window", 0],
			["input_per_million", -1.0],
			["output_per_million", -1.0]
		]:
			if float(model.get(pair[0], pair[1])) <= float(pair[1]) and public_metadata.has(pair[0]):
				model[pair[0]] = public_metadata[pair[0]]
		var runtime := {}
		for key in ["context_window", "input_per_million", "output_per_million"]:
			if model.has(key) and float(model[key]) >= 0.0:
				runtime[key] = model[key]
		if not runtime.is_empty():
			ModelMetadata.set_runtime_metadata(metadata_provider, model_id, runtime)
