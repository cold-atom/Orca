extends SceneTree

const Registry = preload("res://addons/orca/scripts/provider_registry.gd")
const Qwen = preload("res://addons/orca/scripts/providers/qwen_provider.gd")
const EndpointPolicy = preload("res://addons/orca/scripts/endpoint_policy.gd")
const Probe = preload("res://addons/orca/scripts/agent_compatibility_probe.gd")
const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const Anthropic = preload("res://addons/orca/scripts/anthropic_messages.gd")
const AnthropicProvider = preload("res://addons/orca/scripts/providers/anthropic_provider.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const Store = preload("res://addons/orca/scripts/session_store.gd")
const Metadata = preload("res://addons/orca/scripts/model_metadata.gd")
const ModelService = preload("res://addons/orca/scripts/provider_model_service.gd")
const Config = preload("res://addons/orca/scripts/config.gd")
var failures := PackedStringArray()


func _init() -> void:
	_test_qwen()
	_test_anthropic()
	_test_scoped_metadata()
	_test_official_readiness()
	if failures.is_empty():
		print("dedicated_provider_test: PASS")
		quit(0)
	else:
		for failure in failures: printerr(failure)
		quit(1)


func _test_qwen() -> void:
	var provider = Registry.get_provider("qwen")
	_expect(provider.definition().get("id") == "qwen", "Qwen is independently registered")
	for region in Qwen.REGIONS:
		var url := Qwen.endpoint(region, "llm-fixture")
		_expect(Qwen.endpoint_selection(url) == {"region": region, "workspace": "llm-fixture"}, "exact regional workspace round trip: " + region)
		_expect(provider.chat_url({"base_url": url}) == url + "/chat/completions", "same-origin chat URL")
		_expect(provider.models_url({"base_url": url}) == url + "/models", "same-origin model URL")
	_expect(Qwen.endpoint("us-east-1", "").is_empty(), "regions without legacy endpoints need workspace identity")
	for workspace in ["x.evil", "../x", " x", "x/path", "x@host", "x%2e"]:
		_expect(Qwen.endpoint("ap-southeast-1", workspace).is_empty(), "workspace cannot choose authority or path")
	_expect(Qwen.endpoint_selection("https://llm-x.ap-southeast-1.maas.aliyuncs.com.evil/compatible-mode/v1").is_empty(), "suffix spoofing is not a preset")
	var config := {"provider": "qwen", "base_url": Qwen.endpoint("ap-southeast-1", "llm-fixture"), "model": "qwen-plus", "reasoning_effort": "on"}
	_expect(not Probe.create_binding(config).get("success", true), "unconfirmed remote endpoint cannot be probed")
	config["confirmed_origin"] = EndpointPolicy.inspect_base_url(config["base_url"])["origin"]
	var binding: Dictionary = Probe.create_binding(config).get("binding", {})
	_expect(not binding.is_empty(), "confirmed exact profile has a binding")
	var controller := Controller.new()
	_expect(not controller._profile_allows_tools(config), "Qwen starts Chat-only")
	config["agent_compatibility"] = binding.merged({"enabled": true})
	_expect(controller._profile_allows_tools(config), "only an exact enabled pass grants Agent access")
	config["reasoning_effort"] = "off"
	_expect(not controller._profile_allows_tools(config), "thinking change invalidates the pass")
	controller.free()
	var body := {"model": "qwen-plus"}
	provider.apply_chat_options(body, "off")
	_expect(body.get("enable_thinking") == false and body.get("max_tokens") == 8192 and not body.has("reasoning_effort"), "Qwen uses native thinking options")
	body = {"model": "qwen4-max"}
	provider.apply_chat_options(body, "default")
	_expect(body.get("thinking_budget") == 4096 and not body.has("enable_thinking"), "default thinking remains bounded")
	body = {"model": "qwen3-coder-plus"}
	provider.apply_chat_options(body, "default")
	_expect(not body.has("enable_thinking"), "coder models do not inherit hybrid options")
	_expect(not provider.validate_config({"model": "qwen3-coder-plus", "reasoning_effort": "on"}).is_empty(), "invalid reasoning is locally rejected")
	_expect(Qwen.efforts_for_model("qwen3.7-max-2026-05-17").is_empty() and Qwen.efforts_for_model("qwen-plus-2025-01-01").is_empty(), "documented thinking-only and pre-hybrid snapshots do not inherit On/Off")
	_expect(provider.normalize_models({"data": [{"id": "qwen-plus", "context_window": {"invalid": true}, "name": false}]}).size() == 1, "malformed optional Qwen metadata falls back without a conversion error")
	var source := [{"role": "system", "content": "primary"}, {"role": "user", "content": "question"}, {"role": "assistant", "content": "", "tool_calls": [{"id": "call", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}], "reasoning_content": "private"}, {"role": "tool", "tool_call_id": "call", "content": "result"}, {"role": "system", "content": "fresh context"}]
	var original := source.duplicate(true)
	var wire: Array = provider.sanitize_messages(source)
	_expect(wire.size() == 4 and wire[0]["content"] == "primary\n\nfresh context" and wire[3] == source[3], "fresh context and tool results survive normalization")
	_expect(not wire[2].has("reasoning_content") and source == original, "private fields are removed only on the outgoing copy")
	_expect(provider.sanitize_messages(wire) == wire, "projection is idempotent")
	var models: Array = provider.normalize_models({"data": [{"id": "qwen-plus"}, {"id": "qwen3-coder-plus"}, {"id": "qwen-vl-max"}, {"id": "text-embedding-v4"}, {"id": "qwen-audio"}, {"id": "qwen-omni-turbo"}, {"id": "unrelated"}]})
	_expect(models.size() == 3, "discovery excludes incompatible model families and preserves vision candidates")


func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)


func _test_anthropic() -> void:
	var provider = Registry.get_provider("anthropic")
	_expect(provider.definition().get("id") == "anthropic" and provider.api_mode({}) == "anthropic_messages", "native Anthropic adapter is registered")
	_expect(provider.chat_url({}) == "https://api.anthropic.com/v1/messages", "Anthropic uses Messages")
	_expect("x-api-key: fixture" in provider.request_headers("fixture") and "anthropic-version: " + AnthropicProvider.API_VERSION in provider.model_headers("fixture"), "chat and discovery use native versioned headers")
	_expect(not "off" in AnthropicProvider.efforts_for_model("claude-opus-5-5"), "always-thinking Claude models do not receive an Off setting")
	var config := {"provider": "anthropic", "base_url": "https://api.anthropic.com/v1", "model": "claude-sonnet-4-6", "api_mode": "anthropic_messages", "reasoning_effort": "high"}
	var calls := [{"type": "tool_use", "id": "call_1", "name": "read_file", "input": {"path": "res://player.gd"}}, {"type": "tool_use", "id": "call_2", "name": "list_directory", "input": {}}]
	var blocks := [{"type": "thinking", "thinking": "PRIVATE_CLAUDE_THINKING", "signature": "signed_private"}, {"type": "redacted_thinking", "data": "opaque_private"}, {"type": "text", "text": "Inspecting"}] + calls
	var raw := {"type": "message", "id": "msg_fixture", "role": "assistant", "model": config["model"], "content": blocks, "stop_reason": "tool_use", "usage": {"input_tokens": 12, "output_tokens": 9}}
	var completed := Anthropic.completion(raw, config)
	_expect(completed.get("success", false), "signed/redacted thinking and parallel tools normalize")
	if not completed.get("success", false): return
	var message: Dictionary = completed["response"]["choices"][0]["message"]
	var messages := [{"role": "system", "content": "primary"}, {"role": "user", "content": "inspect"}, message, {"role": "tool", "tool_call_id": "call_2", "content": "directory"}, {"role": "system", "content": "refreshed context"}, {"role": "tool", "tool_call_id": "call_1", "content": "source"}]
	var original := messages.duplicate(true)
	var schemas := [{"type": "function", "function": {"name": "read_file", "description": "Inspect", "parameters": {"type": "object"}}}]
	var projected := Anthropic.request_body(messages, schemas, config, true)
	_expect(projected.get("success", false), "native request projects canonical parallel tools with refreshed context")
	if projected.get("success", false):
		var body: Dictionary = projected["body"]
		_expect(body["system"] == "primary\n\nrefreshed context" and body["messages"].size() == 3 and body["messages"][1]["content"] == blocks, "native request preserves complete exact block order")
		_expect(body["messages"][-1]["content"].size() == 2 and body["tool_choice"].get("disable_parallel_tool_use") == true, "parallel results stay together and external calls can request serialization")
		_expect(body.get("thinking", {}).get("display") == "omitted" and body.get("output_config", {}).get("effort") == "high" and not body.has("stream_options"), "native thinking options and request envelope")
		_expect(messages == original, "native projection never alters controller history")
		_expect(Budget.estimate_tokens(messages, schemas, true, false, {}, config) > 0, "native projection is budgeted")
	var tampered := messages.duplicate(true)
	tampered[2][Anthropic.PRIVATE_FIELD]["blocks"][0]["signature"] = "tampered"
	_expect(not Anthropic.request_body(tampered, schemas, config).get("success", true), "changed signed continuation is rejected")
	var other := config.duplicate(true)
	other["model"] = "claude-opus-4-6"
	_expect(not Anthropic.request_body(messages, schemas, other).get("success", true), "private blocks cannot cross profiles")
	_expect(not Anthropic.request_body(messages.slice(0, 4), schemas, config).get("success", true), "missing parallel results fail closed")
	var duplicated := messages.duplicate(true)
	duplicated[5]["tool_call_id"] = "call_2"
	_expect(not Anthropic.request_body(duplicated, schemas, config).get("success", true), "duplicate results fail closed")
	for reason in ["max_tokens", "refusal", "pause_turn", null, "end_turn"]:
		var invalid := raw.duplicate(true)
		invalid["stop_reason"] = reason
		_expect(not Anthropic.completion(invalid, config).get("success", true), "incomplete/contradictory native completion is rejected: " + str(reason))
	var wrong_model := raw.duplicate(true)
	wrong_model["model"] = "claude-opus-4-6"
	_expect(not Anthropic.completion(wrong_model, config).get("success", true), "native model substitution fails before tool dispatch")
	for oversized in [
		{"type": "text", "text": "x".repeat(Anthropic.MAX_BYTES + 1)},
		{"type": "thinking", "thinking": "", "signature": "x".repeat(Anthropic.MAX_BYTES + 1)},
		{"type": "tool_use", "id": "large_call", "name": "read_file", "input": {"text": "x".repeat(Anthropic.MAX_BYTES + 1)}}
	]:
		var invalid := raw.duplicate(true)
		invalid["content"] = [oversized]
		_expect(not Anthropic.completion(invalid, config).get("success", true), "oversized native text/signature/arguments are denied")
	var too_many := raw.duplicate(true)
	too_many["content"] = []
	for index in 17: too_many["content"].append({"type": "tool_use", "id": "bounded_" + str(index), "name": "read_file", "input": {}})
	_expect(not Anthropic.completion(too_many, config).get("success", true), "native call cap is enforced independently of block cap")
	var nested := {}
	for index in 18: nested = {"nested": nested}
	too_many["content"] = [{"type": "tool_use", "id": "nested_call", "name": "read_file", "input": nested}]
	_expect(not Anthropic.completion(too_many, config).get("success", true), "native input traversal cannot exceed the nesting budget")
	for invalid_block in [{"type": "thinking", "thinking": "unsigned", "signature": ""}, {"type": "server_tool_use", "name": "code_execution"}, {"type": "text", "text": "x", "citations": true}]:
		var invalid := raw.duplicate(true)
		invalid["content"] = [invalid_block]
		_expect(not Anthropic.completion(invalid, config).get("success", true), "unsupported or malformed blocks are rejected")
	var stream := Anthropic.new()
	_expect(not stream.consume({"type": "message_stop"}, config).get("success", true), "stream completion requires a start")
	stream = Anthropic.new()
	var start := raw.duplicate(true)
	start["content"] = []
	start["stop_reason"] = null
	_expect(stream.consume({"type": "message_start", "message": start}, config).get("success", false), "valid native stream starts")
	_expect(not stream.consume({"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}, config).get("success", true), "non-contiguous block indices are denied")
	stream = Anthropic.new()
	stream.consume({"type": "message_start", "message": start}, config)
	stream.consume({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "call", "name": "read_file", "input": {}}}, config)
	stream.consume({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": "{"}}, config)
	_expect(not stream.consume({"type": "content_block_stop", "index": 0}, config).get("success", true), "malformed streamed tool JSON never completes")
	var store := Store.new("user://unused_native_fixture")
	var persisted: Array = store._sanitize_continuation(messages)
	_expect(not JSON.stringify(persisted).contains("PRIVATE_CLAUDE_THINKING") and not JSON.stringify(persisted).contains(Anthropic.PRIVATE_FIELD), "native thinking cannot persist through session sanitation")
	var controller := Controller.new()
	controller.message_history = messages.duplicate(true)
	controller._turn_provider_config = config.duplicate(true)
	controller._is_running = true
	controller._set_running(false)
	_expect(not JSON.stringify(controller.message_history).contains(Anthropic.PRIVATE_FIELD), "turn completion clears native envelopes before another profile")
	controller.free()


func _test_scoped_metadata() -> void:
	var service := ModelService.new()
	var first := Qwen.endpoint("us-east-1", "llm-scoped")
	var second := Qwen.endpoint("ap-southeast-1", "llm-scoped")
	var records: Array[Dictionary] = [{"id": "qwen-scope-fixture", "context_window": 8192, "image_input": true}]
	service._merge_public_metadata("qwen", records, first)
	_expect(Metadata.resolve("qwen-scope-fixture", first).get("context_window") == 8192, "Qwen discovery context participates in request budgeting")
	_expect(not Metadata.resolve("qwen-scope-fixture", second).has("context_window") and not Metadata.resolve("qwen-scope-fixture", first).has("image_input"), "regional context and vision do not cross endpoint boundaries")
	records = [{"id": "claude-scope-fixture", "context_window": 16384, "image_input": true}]
	service._merge_public_metadata("anthropic", records, "http://127.0.0.1:18473/override")
	_expect(not Metadata.resolve("claude-scope-fixture", "https://api.anthropic.com/v1").has("image_input") and not Metadata.resolve("claude-scope-fixture", "https://api.anthropic.com/v1").has("context_window"), "native override discovery cannot poison canonical model capabilities")
	service.free()


func _test_official_readiness() -> void:
	var controller := Controller.new()
	for provider_id in ["qwen", "anthropic"]:
		var provider = Registry.get_provider(provider_id)
		for base_url in provider.official_base_urls():
			var profile := {"provider": provider_id, "base_url": base_url, "model": provider.definition()["default_model"], "api_key": "synthetic-key", "api_mode": provider.definition().get("default_api_mode", "chat_completions"), "reasoning_effort": "default"}
			var authorization := EndpointPolicy.authorize_profile(provider_id, profile)
			_expect(authorization.get("success", false) and authorization.get("scope") == "fixed" and not authorization.get("requires_confirmation", true), "release-owned route needs no editable-origin consent: " + base_url)
			_expect(authorization.get("config", {}).get("base_url") == base_url, "fixed regional base is never replaced by another region")
			_expect(Config.official_agent_status(provider_id, profile).get("automatic", false) and controller._profile_allows_tools(profile), "supported official profile is ready without a probe")
			var original := profile.duplicate(true)
			var binding: Dictionary = Probe.create_binding(profile)["binding"]
			for flag in [false, "true", 1, null]:
				profile["official_agent_enabled"] = flag
				_expect(not controller._profile_allows_tools(profile), "opt-out/malformed positive preferences cannot enable official tools")
			profile = original.duplicate(true)
			profile["agent_compatibility"] = binding.merged({"enabled": false})
			_expect(not controller._profile_allows_tools(profile), "matching historical disabled pass remains an intentional opt-out")
			profile["reasoning_effort"] = "unsupported"
			profile["agent_compatibility"] = binding.merged({"enabled": true})
			_expect(not controller._profile_allows_tools(profile), "unsupported reasoning cannot copy readiness")
			for field in ["api_mode", "continuation_style"]:
				profile = original.duplicate(true)
				profile[field] = "unsupported"
				profile["agent_compatibility"] = binding.merged({"enabled": true})
				_expect(not controller._profile_allows_tools(profile), "unsupported protocol cannot copy readiness")
			for model in ["unknown-model", original["model"] + "-20990101", "QWEN3-CODER-PLUS", "qwen4-max-latest"]:
				profile = original.duplicate(true)
				profile["model"] = model
				profile["agent_tools"] = true
				profile["image_input"] = true
				profile["hosted_agent_ready"] = true
				_expect(not controller._profile_allows_tools(profile), "manual/discovered capability flags cannot grant readiness: " + model)
				profile["agent_compatibility"] = Probe.create_binding(profile)["binding"].merged({"enabled": true})
				_expect(controller._profile_allows_tools(profile), "unknown valid manual IDs retain explicitly enabled exact probing")
			profile = original.duplicate(true)
			profile["api_key"] = ""
			_expect(not controller._profile_allows_tools(profile) and controller._connection_setup_for_profile(profile).get("status") == "credentials", "missing keys retain ordinary setup guidance")
			profile["model"] = ""
			profile["api_key"] = "synthetic-key"
			_expect(not controller._profile_allows_tools(profile) and controller._connection_setup_for_profile(profile).get("status") == "model", "missing models retain ordinary setup guidance")
			for url in [base_url.replace("https://", "http://"), base_url.replace(".com/", ".com:444/"), base_url + "/other", base_url.replace(".com/", ".com.evil/"), "https://llm-fixture.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"]:
				profile = original.duplicate(true)
				profile["base_url"] = url
				profile["official_agent_enabled"] = true
				profile["agent_compatibility"] = binding.merged({"enabled": true})
				_expect(not EndpointPolicy.authorize_profile(provider_id, profile).get("success", true) and not controller._profile_allows_tools(profile), "nonofficial route needs exact consent, not copied readiness: " + url)
				profile["confirmed_origin"] = EndpointPolicy.inspect_base_url(url)["origin"]
				_expect(not controller._profile_allows_tools(profile), "origin consent alone never grants tools")
				var exact := Probe.create_binding(profile)
				_expect(exact.get("config", {}).get("base_url") == url, "overrides retain their exact path instead of canonicalizing")
				profile["agent_compatibility"] = exact["binding"].merged({"enabled": true})
				_expect(controller._profile_allows_tools(profile), "confirmed override still supports exact passed/enabled probing")
		for model in provider.AGENT_MODELS:
			var profile := {"provider": provider_id, "base_url": provider.definition()["base_url"], "model": model, "api_key": "synthetic-key", "api_mode": provider.definition().get("default_api_mode", "chat_completions")}
			for effort in ["default"] + Array(provider.efforts_for_model(model)):
				profile["reasoning_effort"] = effort
				_expect(controller._profile_allows_tools(profile), "documented exact model/options are ready: " + model + " " + effort)
	controller.free()
