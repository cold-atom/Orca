extends SceneTree

const ModelCatalogService = preload("res://addons/orca/scripts/model_catalog_service.gd")
const ModelMetadata = preload("res://addons/orca/scripts/model_metadata.gd")
const ProviderModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
const ProviderRegistry = preload("res://addons/orca/scripts/provider_registry.gd")
const Config = preload("res://addons/orca/scripts/config.gd")

var _failures := PackedStringArray()


func _init() -> void:
	_test_registry()
	_test_local_providers()
	_test_deepseek_provider()
	_test_gemini_provider()
	_test_xai_provider()
	_test_metadata_mapping()
	if _failures.is_empty():
		print("provider_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("provider_test: ", failure)
	quit(1)


func _test_registry() -> void:
	_expect("gemini" in ProviderRegistry.PROVIDER_IDS, "Gemini should be registered")
	_expect("xai" in ProviderRegistry.PROVIDER_IDS, "xAI should be registered")
	_expect(ProviderRegistry.get_provider("gemini").definition().get("id") == "gemini", "Gemini should resolve to its adapter")
	_expect(ProviderRegistry.get_provider("xai").definition().get("id") == "xai", "xAI should resolve to its adapter")
	_expect(ProviderRegistry.infer_provider("https://generativelanguage.googleapis.com/v1beta/openai/") == "gemini", "Gemini's canonical URL should be inferred")
	_expect(ProviderRegistry.infer_provider("https://api.x.ai/v1/") == "xai", "xAI's canonical URL should be inferred")


func _test_local_providers() -> void:
	var expected := {
		"ollama": "http://127.0.0.1:11434/v1",
		"lmstudio": "http://127.0.0.1:1234/v1",
		"local_openai": "http://127.0.0.1:8080/v1"
	}
	var expected_models_url := {
		"ollama": "http://127.0.0.1:11434/api/tags",
		"lmstudio": "http://127.0.0.1:1234/api/v1/models",
		"local_openai": "http://127.0.0.1:8080/v1/models"
	}
	for provider_id in expected:
		_expect(ProviderRegistry.PROVIDER_IDS.count(provider_id) == 1, provider_id + " should be registered exactly once")
		var provider = ProviderRegistry.get_provider(provider_id)
		var definition: Dictionary = provider.definition()
		_expect(definition.get("id") == provider_id and definition.get("auth_optional") == true, provider_id + " should resolve to a keyless local adapter")
		_expect(definition.get("custom_url") == true and definition.get("model_discovery") == true and definition.get("manual_model") == true, provider_id + " should expose editable discovery with manual fallback")
		_expect(provider.chat_url({"base_url": expected[provider_id]}) == expected[provider_id] + "/chat/completions", provider_id + " should use Chat Completions")
		_expect(provider.models_url({"base_url": expected[provider_id]}) == expected_models_url[provider_id], provider_id + " should use its bounded discovery endpoint")
		_expect(not "Authorization: Bearer " in provider.request_headers(""), provider_id + " should omit empty chat authorization")
		_expect(not "Authorization: Bearer " in provider.model_headers(""), provider_id + " should omit empty discovery authorization")
		_expect("Authorization: Bearer secret" in provider.request_headers("secret"), provider_id + " should support optional bearer authentication")
	var generic = ProviderRegistry.get_provider("local_openai")
	var generic_models: Array[Dictionary] = generic.normalize_models({"data": [{"id": "chat-model"}, {"id": "nomic-embed-text"}]})
	_expect(generic_models.size() == 1 and generic_models[0].get("id") == "chat-model", "generic local discovery should hide obvious embedding IDs")
	var ollama = ProviderRegistry.get_provider("ollama")
	var ollama_models: Array[Dictionary] = ollama.normalize_models({"models": [
		{"model": "qwen2.5-coder:3b", "name": "qwen2.5-coder:3b", "capabilities": ["completion", "tools"], "details": {"context_length": 32768}},
		{"model": "nomic-embed-text", "capabilities": ["embedding"]},
		{"model": "fallback-embed-model"},
		{"model": "neutral-model"}
	]})
	_expect(ollama_models.size() == 2, "Ollama should include completion models and neutral unknowns while excluding embeddings")
	_expect(ollama_models.any(func(model): return model.get("id") == "qwen2.5-coder:3b" and model.get("context_window") == 32768), "Ollama should retain completion capability and context metadata")
	var lmstudio = ProviderRegistry.get_provider("lmstudio")
	var lmstudio_models: Array[Dictionary] = lmstudio.normalize_models({"models": [
		{"type": "llm", "key": "llama-chat", "display_name": "Llama Chat", "max_context_length": 131072, "loaded_instances": [{"config": {"context_length": 8192}}]},
		{"type": "embedding", "key": "text-embedding-nomic", "display_name": "Nomic Embed"},
		{"key": "unknown-embed-model", "display_name": "Unknown"},
		{"type": "llm", "key": "unusual-embed-chat", "display_name": "Explicit LLM"}
	]})
	_expect(lmstudio_models.size() == 2, "LM Studio native type should exclude embeddings and override name heuristics for explicit LLMs")
	_expect(lmstudio_models.any(func(model): return model.get("id") == "llama-chat" and model.get("context_window") == 8192), "LM Studio should prefer the loaded context over the architectural maximum")
	_expect(ProviderRegistry.infer_provider("http://localhost:11434/v1/") == "ollama", "Ollama's canonical local URL should be inferred")
	_expect(ProviderRegistry.infer_provider("http://127.0.0.1:1234/v1") == "lmstudio", "LM Studio's canonical local URL should be inferred")
	var first_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/v1/models", "empty")
	var equivalent_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/v1/models/", "empty")
	var other_endpoint_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11435/v1/models", "empty")
	var other_credential_key := Config._provider_model_cache_key("ollama", "http://127.0.0.1:11434/v1/models", "other")
	_expect(first_key == equivalent_key, "equivalent trailing-slash model endpoints should share a cache key")
	_expect(first_key != other_endpoint_key, "local model caches should be isolated by endpoint")
	_expect(first_key != other_credential_key, "local model caches should be isolated by credential fingerprint")


func _test_deepseek_provider() -> void:
	var provider = ProviderRegistry.get_provider("deepseek")
	var default_body := {}
	provider.apply_chat_options(default_body, "default")
	_expect(default_body.get("max_tokens") == 8192, "DeepSeek default thinking should have a bounded output budget aligned with Orca's minimum known-context reserve")
	_expect(not default_body.has("thinking"), "DeepSeek provider default should not override the thinking toggle")
	var high_body := {}
	provider.apply_chat_options(high_body, "high")
	_expect(high_body.get("thinking", {}).get("type") == "enabled", "DeepSeek explicit reasoning should enable thinking")
	_expect(high_body.get("reasoning_effort") == "high" and high_body.get("max_tokens") == 8192, "DeepSeek reasoning should retain its effort and bounded output budget")
	var off_body := {}
	provider.apply_chat_options(off_body, "off")
	_expect(off_body.get("thinking", {}).get("type") == "disabled", "DeepSeek off should disable thinking")
	_expect(off_body.get("max_tokens") == 8192 and not off_body.has("reasoning_effort"), "DeepSeek non-thinking output should remain bounded without reasoning effort")


func _test_gemini_provider() -> void:
	var provider = ProviderRegistry.get_provider("gemini")
	var config := {"base_url": provider.definition()["base_url"]}
	_expect(provider.chat_url(config) == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "Gemini should use the OpenAI-compatible chat endpoint")
	_expect(provider.models_url(config) == "https://generativelanguage.googleapis.com/v1beta/models", "Gemini should use the native model-list endpoint")
	_expect("Authorization: Bearer secret" in provider.request_headers("secret"), "Gemini chat should use bearer authentication")
	_expect("x-goog-api-key: secret" in provider.model_headers("secret"), "Gemini model discovery should use Google's API-key header")
	_expect(provider.allows_stop_finish_with_tool_calls(), "Gemini should declare its stop-finished tool-call compatibility behavior")
	var body := {}
	provider.apply_chat_options(body, "high")
	_expect(body.get("reasoning_effort") == "high", "Gemini reasoning effort should use the compatibility field")
	var models: Array[Dictionary] = provider.normalize_models({"models": [
		{"name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash", "inputTokenLimit": 1048576, "supportedGenerationMethods": ["generateContent"]},
		{"name": "models/text-embedding-004", "displayName": "Embedding", "supportedGenerationMethods": ["embedContent"]},
		{"name": "models/imagen-4", "displayName": "Imagen", "supportedGenerationMethods": ["generateContent"]}
	]})
	_expect(models.size() == 1, "Gemini discovery should retain only compatible text-generation models")
	if models.size() == 1:
		_expect(models[0].get("id") == "gemini-2.5-flash", "Gemini discovery should strip the native models/ prefix")
		_expect(models[0].get("context_window") == 1048576, "Gemini discovery should retain the input token limit")
		_expect("high" in models[0].get("efforts", PackedStringArray()), "Gemini thinking models should expose reasoning effort")


func _test_xai_provider() -> void:
	var provider = ProviderRegistry.get_provider("xai")
	var config := {"base_url": provider.definition()["base_url"]}
	_expect(provider.chat_url(config) == "https://api.x.ai/v1/chat/completions", "xAI should use its Chat Completions endpoint")
	_expect(provider.models_url(config) == "https://api.x.ai/v1/models", "xAI should use its models endpoint")
	_expect("Authorization: Bearer secret" in provider.request_headers("secret"), "xAI should use bearer authentication")
	var body := {}
	provider.apply_chat_options(body, "xhigh")
	_expect(body.get("reasoning_effort") == "xhigh", "xAI reasoning effort should use the documented request field")
	var sanitized: Array = provider.sanitize_messages([{"role": "assistant", "reasoning_content": "keep", "reasoning": "drop", "reasoning_details": []}])
	_expect(sanitized[0].get("reasoning_content") == "keep", "xAI should preserve reasoning_content for continuation")
	_expect(not sanitized[0].has("reasoning") and not sanitized[0].has("reasoning_details"), "xAI should remove unrelated reasoning formats")
	var models: Array[Dictionary] = provider.normalize_models({"data": [
		{
			"id": "grok-420-reasoning",
			"context_length": 256000,
			"prompt_text_token_price": 20000,
			"completion_text_token_price": 80000,
			"capabilities": {"reasoning_effort": ["low", "high", "xhigh"], "default_reasoning_effort": "high"}
		},
		{"id": "grok-imagine-image", "image_price": 200000000}
	]})
	_expect(models.size() == 1, "xAI discovery should exclude generation-only media models")
	if models.size() == 1:
		_expect(models[0].get("context_window") == 256000, "xAI discovery should map context_length")
		_expect(is_equal_approx(float(models[0].get("input_per_million")), 2.0), "xAI input pricing should convert to dollars per million tokens")
		_expect(is_equal_approx(float(models[0].get("output_per_million")), 8.0), "xAI output pricing should convert to dollars per million tokens")
		_expect(models[0].get("default_effort") == "high", "xAI discovery should retain the default reasoning effort")


func _test_metadata_mapping() -> void:
	_expect(ModelMetadata.infer_provider("https://generativelanguage.googleapis.com/v1beta/openai") == "google", "Gemini should map to the models.dev google namespace")
	_expect(ModelMetadata.infer_provider("https://api.x.ai/v1") == "xai", "xAI should map to the models.dev xai namespace")
	var catalog_service = ModelCatalogService.new()
	_expect(catalog_service._provider_url("xai") == "https://api.x.ai", "xAI should have a canonical metadata URL")
	catalog_service.free()
	var model_service = ProviderModelService.new()
	var models: Array[Dictionary] = [{"id": "gemini-orca-test", "context_window": 123456, "input_per_million": -1.0, "output_per_million": -1.0}]
	model_service._merge_public_metadata("gemini", models, "https://generativelanguage.googleapis.com/v1beta/openai")
	var resolved := ModelMetadata.resolve("gemini-orca-test", "https://generativelanguage.googleapis.com/v1beta/openai")
	_expect(resolved.get("context_window") == 123456, "Gemini discovery metadata should be cached under its catalog namespace")
	ModelMetadata.remove_runtime_metadata("google", "gemini-orca-test")
	model_service.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
