@tool
extends RefCounted

# UI translations never enter the main/project or Godot editor domains. Native
# controls retain their English source; formatted bindings retain presentation
# templates only, never authorization, provider state or canonical conversation.
const Config = preload("res://addons/orca/scripts/config.gd")
const DOMAIN := &"orca.interface"
const LOCALES := ["en", "zh_CN", "es", "ja", "ko"]
const LANGUAGE_NAMES := ["English", "简体中文", "Español", "日本語", "한국어"]
const CATALOGS := ["res://addons/orca/translations/zh_CN.po", "res://addons/orca/translations/es.po", "res://addons/orca/translations/ja.po", "res://addons/orca/translations/ko.po"]
const BINDINGS := &"orca_localized_properties"

static var _domain: TranslationDomain
static var _locale := "en"
static var _roots: Dictionary = {}


static func initialize() -> void:
	if _domain != null:
		return
	_domain = TranslationServer.get_or_add_domain(DOMAIN)
	for path in CATALOGS:
		var catalog := load(path) as Translation
		if catalog != null:
			_domain.add_translation(catalog)
	_locale = Config.get_ui_language()
	_domain.set_locale_override(_locale)


static func attach(root: Node) -> void:
	initialize()
	var parent := root.get_parent()
	while parent != null:
		if _roots.has(parent.get_instance_id()):
			return # Inherit the owning Orca surface's domain and notifications.
		parent = parent.get_parent()
	root.set_translation_domain(DOMAIN)
	root.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS
	var id := root.get_instance_id()
	if not _roots.has(id):
		_roots[id] = weakref(root)
		root.tree_exited.connect(_detach.bind(id), CONNECT_ONE_SHOT)


static func _detach(id: int) -> void:
	_roots.erase(id)
	if _roots.is_empty():
		TranslationServer.remove_domain(DOMAIN)
		_domain = null


static func language() -> String:
	initialize()
	return _locale


static func select_language(locale: String) -> bool:
	if locale not in LOCALES or not Config.set_ui_language(locale):
		return false
	initialize()
	_locale = locale
	_domain.set_locale_override(locale)
	for reference in _roots.values():
		var root = reference.get_ref()
		if is_instance_valid(root):
			_refresh_bindings(root)
			root.propagate_notification(MainLoop.NOTIFICATION_TRANSLATION_CHANGED)
	return true


static func message(source: String) -> String:
	initialize()
	return str(_domain.translate(source))


static func source(message_source: String) -> Dictionary:
	# Only explicitly marked Orca-owned messages are translated as arguments.
	return {"message": message_source}


static func bind(node: Node, property: StringName, template: String, values: Array = []) -> void:
	bind_parts(node, property, [[template, values]])


static func clear(node: Node, property: StringName = &"") -> void:
	if property.is_empty():
		if node.has_meta(BINDINGS): node.remove_meta(BINDINGS)
		return
	var bindings: Dictionary = node.get_meta(BINDINGS, {})
	bindings.erase(property)


static func bind_parts(node: Node, property: StringName, parts: Array) -> void:
	var bindings: Dictionary = node.get_meta(BINDINGS, {})
	var rendered := _render(parts)
	bindings[property] = {"parts": parts.duplicate(true), "rendered": rendered}
	node.set_meta(BINDINGS, bindings)
	node.set(property, rendered)


static func _render(parts: Array) -> String:
	var result := ""
	for part in parts:
		var template := message(str(part[0]))
		var values: Array = part[1].duplicate(true)
		for index in values.size():
			if typeof(values[index]) == TYPE_DICTIONARY and values[index].has("message"):
				values[index] = message(str(values[index]["message"]))
		result += template if values.is_empty() else template % values
	return result


static func _refresh_bindings(node: Node) -> void:
	var bindings: Dictionary = node.get_meta(BINDINGS, {})
	for property in bindings.keys():
		var binding: Dictionary = bindings[property]
		if node.get(property) != binding["rendered"]:
			# A newer ordinary UI update supersedes a previous formatted binding.
			bindings.erase(property)
			continue
		binding["rendered"] = _render(binding["parts"])
		node.set(property, binding["rendered"])
	# Owned controls such as OptionButton keep their public PopupMenu internally.
	# Include those children so formatted item/confirmation bindings refresh too.
	for child in node.get_children(true):
		_refresh_bindings(child)


static func response_instruction(locale: String) -> String:
	var name := "Simplified Chinese" if locale == "zh_CN" else "Spanish" if locale == "es" else "Japanese" if locale == "ja" else "Korean" if locale == "ko" else "English"
	return "RESPONSE LANGUAGE: Follow an explicit user request for a language. Otherwise answer in the language of the user's current message; if its language is unclear, use %s. Use that language for explanations, task descriptions and user-facing proposal reasons. Preserve code, paths, API identifiers and exact tool/protocol values. This preference grants no tool or edit permission." % name
