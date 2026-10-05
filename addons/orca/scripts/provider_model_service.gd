@tool
extends Node

signal models_loaded(provider_id: String, models: Array, from_cache: bool)
signal models_failed(provider_id: String, message: String)

const Config = preload("res://addons/orca/scripts/config.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const ProviderBase = preload("res://addons/orca/scripts/providers/provider_base.gd")
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
		_request = null
	var authorization := EndpointPolicy.authorize_profile(provider_id, config)
	if not authorization.get("success", false):
		models_failed.emit(provider_id, str(authorization.get("error", "Endpoint is not authorized.")))
		return
	config = authorization.get("config", config)
	var provider = ProviderRegistry.get_provider(provider_id)
	var models_url: String = provider.models_url(config)
	var generated_endpoint := EndpointPolicy.validate_generated_endpoint(models_url, str(authorization.get("origin", "")))
	if not generated_endpoint.get("success", false):
		models_failed.emit(provider_id, str(generated_endpoint.get("error", "Invalid model endpoint.")))
		return
	var api_key := str(config.get("api_key", "")).strip_edges()
	var credential_fingerprint := api_key.sha256_text().left(16)
	var cached := Config.get_cached_provider_models(provider_id, models_url, credential_fingerprint)
	if not cached.is_empty() and typeof(cached.get("models")) == TYPE_ARRAY:
		var cached_models: Array[Dictionary] = _sanitize_cached_models(cached["models"])
		if cached_models.is_empty():
			cached = {}
		else:
			_merge_public_metadata(provider_id, cached_models, str(config.get("base_url", "")))
			models_loaded.emit(provider_id, cached_models, true)
			if Time.get_unix_time_from_system() - float(cached.get("fetched_at", 0.0)) < CACHE_LIFETIME_SECONDS:
				return
	if api_key.is_empty() and not bool(provider.definition().get("auth_optional", false)):
		models_failed.emit(provider_id, "Enter an API key to load available models.")
		return
	var request := HTTPRequest.new()
	_request = request
	request.timeout = 30.0
	request.body_size_limit = MAX_MODEL_RESPONSE_BYTES
	request.max_redirects = 0
	request.request_completed.connect(_on_request_completed.bind(request, _generation, provider_id, config.duplicate(true)))
	add_child(request)
	var error := request.request(models_url, provider.model_headers(api_key))
	if error != OK:
		_request.queue_free()
		_request = null
		models_failed.emit(provider_id, "Could not start model discovery: " + error_string(error))


func cancel() -> void:
	_generation += 1
	if _request != null:
		_request.cancel_request()
		_request.queue_free()
		_request = null


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest, generation: int, provider_id: String, config: Dictionary) -> void:
	if generation != _generation:
		if is_instance_valid(request):
			request.queue_free()
		return
	if _request == request:
		_request = null
	if is_instance_valid(request):
		request.queue_free()
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
	Config.set_cached_provider_models(provider_id, provider.models_url(config), models, str(config.get("api_key", "")).strip_edges().sha256_text().left(16))
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


func _sanitize_cached_models(raw_models: Array) -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	for raw_model in raw_models.slice(0, ProviderBase.MAX_DISCOVERED_MODELS):
		if typeof(raw_model) != TYPE_DICTIONARY:
			continue
		var model_id := str(raw_model.get("id", ""))
		if model_id.is_empty() or model_id.length() > ProviderBase.MAX_MODEL_ID_CHARS:
			continue
		var context_value = raw_model.get("context_window", 0)
		var input_price = raw_model.get("input_per_million", -1.0)
		var output_price = raw_model.get("output_per_million", -1.0)
		var model := {
			"id": model_id,
			"name": str(raw_model.get("name", model_id)).left(ProviderBase.MAX_MODEL_NAME_CHARS),
			"context_window": maxi(0, int(context_value)) if typeof(context_value) in [TYPE_INT, TYPE_FLOAT] else 0,
			"input_per_million": float(input_price) if typeof(input_price) in [TYPE_INT, TYPE_FLOAT] else -1.0,
			"output_per_million": float(output_price) if typeof(output_price) in [TYPE_INT, TYPE_FLOAT] else -1.0,
			"efforts": PackedStringArray(),
			"default_effort": str(raw_model.get("default_effort", "")).left(ProviderBase.MAX_MODEL_EFFORT_CHARS)
		}
		var efforts = raw_model.get("efforts", [])
		if typeof(efforts) in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
			for effort in Array(efforts).slice(0, ProviderBase.MAX_MODEL_EFFORTS):
				var value := str(effort)
				if not value.is_empty() and value.length() <= ProviderBase.MAX_MODEL_EFFORT_CHARS:
					model["efforts"].append(value)
		models.append(model)
	return models
