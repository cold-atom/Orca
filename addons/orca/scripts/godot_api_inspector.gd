@tool
extends RefCounted

const MAX_OVERVIEW_MEMBERS := 80
const MAX_EXACT_MATCHES := 16
const MAX_PARENT_DEPTH := 16
const MAX_ARGUMENTS := 32
const MAX_STRING_CHARS := 256
const MAX_OUTPUT_BYTES := 64 * 1024

const MEMBER_KINDS := ["auto", "method", "property", "signal", "constant", "enum"]
const REFLECTED_KINDS := ["method", "property", "signal", "constant", "enum"]


static func inspect(arguments: Dictionary) -> Dictionary:
	var validation_error := _validate_arguments(arguments)
	if not validation_error.is_empty():
		return _error(validation_error)

	var requested_class: String = arguments["class_name"]
	var member_name := str(arguments.get("member_name", ""))
	var member_kind := str(arguments.get("member_kind", "auto"))
	var include_inherited := bool(arguments.get("include_inherited", true))
	var global_class := _find_global_class(requested_class)
	var native_class := requested_class if ClassDB.class_exists(requested_class) else str(global_class.get("base", ""))
	if not ClassDB.class_exists(native_class):
		return _error("Godot API class does not exist: " + requested_class)

	var reasons := PackedStringArray()
	var hierarchy := _class_hierarchy(requested_class, native_class, global_class, reasons)
	var records_by_kind := {}
	var total_by_kind := {}
	for kind in REFLECTED_KINDS:
		var records := _records_for_kind(native_class, kind, include_inherited, not global_class.is_empty())
		total_by_kind[kind] = records.size()
		records_by_kind[kind] = records

	var members: Array[Dictionary] = []
	if member_name.is_empty():
		members = _bounded_overview(records_by_kind, member_kind, reasons)
	else:
		members = _exact_matches(records_by_kind, member_kind, member_name, reasons)
		if members.is_empty():
			return _error("No matching %s member named '%s' was found on %s%s." % [member_kind, member_name, requested_class, " or its inherited API" if include_inherited else ""])

	var report := {
		"source": "godot_classdb",
		"engine_version": _engine_version(),
		"class": {
			"name": requested_class,
			"native_api_class": native_class,
			"built_in": global_class.is_empty(),
			"enabled": ClassDB.is_class_enabled(native_class),
			"parent": str(hierarchy[1]) if hierarchy.size() > 1 else "",
			"hierarchy": hierarchy,
			"global_class": global_class
		},
		"query": {
			"member_name": member_name,
			"member_kind": member_kind,
			"include_inherited": include_inherited
		},
		"help_topic": _help_topic("class", requested_class, ""),
		"total_members_by_kind": total_by_kind,
		"returned_member_count": members.size(),
		"members": members,
		"truncation": {"truncated": not reasons.is_empty(), "reasons": Array(reasons)},
		"note": "Reflected through ClassDB and ProjectSettings global-class metadata without loading scripts or creating objects."
	}
	var content := _fit_and_serialize(report)
	return {"success": true, "content": content, "outcome": "completed", "data": report}


static func _validate_arguments(arguments: Dictionary) -> String:
	for key in arguments:
		if str(key) not in ["class_name", "member_name", "member_kind", "include_inherited"]:
			return "Unknown Godot API inspection argument: " + _bounded_string(str(key))
	if not arguments.has("class_name") or typeof(arguments["class_name"]) != TYPE_STRING:
		return "class_name is required and must be a string."
	var requested_name: String = arguments["class_name"]
	if requested_name.is_empty():
		return "class_name cannot be empty."
	if requested_name.length() > MAX_STRING_CHARS:
		return "class_name exceeds the 256 character limit."
	if arguments.has("member_name"):
		if typeof(arguments["member_name"]) != TYPE_STRING:
			return "member_name must be a string."
		var member_name: String = arguments["member_name"]
		if member_name.is_empty():
			return "Omit member_name for a class overview; an explicit member_name cannot be empty."
		if member_name.length() > MAX_STRING_CHARS:
			return "member_name exceeds the 256 character limit."
	if arguments.has("member_kind"):
		if typeof(arguments["member_kind"]) != TYPE_STRING:
			return "member_kind must be a string."
		if str(arguments["member_kind"]) not in MEMBER_KINDS:
			return "member_kind must be auto, method, property, signal, constant, or enum."
	if arguments.has("include_inherited") and typeof(arguments["include_inherited"]) != TYPE_BOOL:
		return "include_inherited must be a boolean."
	return ""


static func _find_global_class(api_class: String) -> Dictionary:
	for value in ProjectSettings.get_global_class_list():
		if typeof(value) != TYPE_DICTIONARY or str(value.get("class", "")) != api_class:
			continue
		return {
			"class": _bounded_string(str(value.get("class", ""))),
			"base": _bounded_string(str(value.get("base", ""))),
			"language": _bounded_string(str(value.get("language", ""))),
			"path": _bounded_string(str(value.get("path", ""))),
			"icon": _bounded_string(str(value.get("icon", ""))),
			"is_abstract": bool(value.get("is_abstract", false)),
			"is_tool": bool(value.get("is_tool", false))
		}
	return {}


static func _class_hierarchy(requested_class: String, native_class: String, global_class: Dictionary, reasons: PackedStringArray) -> Array:
	var hierarchy: Array = []
	if not global_class.is_empty():
		hierarchy.append(_bounded_string(requested_class))
	var current := native_class
	while not current.is_empty() and hierarchy.size() < MAX_PARENT_DEPTH:
		hierarchy.append(_bounded_string(current))
		current = str(ClassDB.get_parent_class(current))
	if not current.is_empty():
		_add_reason(reasons, "parent_depth_limit")
	return hierarchy


static func _records_for_kind(native_class: String, kind: String, include_inherited: bool, is_global_class: bool) -> Array:
	if is_global_class and not include_inherited:
		return []
	var classes: Array[String] = []
	var current := native_class
	while not current.is_empty() and classes.size() < MAX_PARENT_DEPTH:
		classes.append(current)
		if not include_inherited:
			break
		current = str(ClassDB.get_parent_class(current))
	var records: Array = []
	for declaring_class in classes:
		var raw_list: Array = _raw_member_list(declaring_class, kind)
		for raw in raw_list:
			var record := _normalize_member(declaring_class, kind, raw)
			if not record.is_empty():
				records.append(record)
	records.sort_custom(func(left, right):
		var left_key := "%s|%s" % [str(left.get("name", "")), str(left.get("declaring_class", ""))]
		var right_key := "%s|%s" % [str(right.get("name", "")), str(right.get("declaring_class", ""))]
		return left_key < right_key
	)
	return records


static func _raw_member_list(api_class: String, kind: String) -> Array:
	match kind:
		"method":
			return ClassDB.class_get_method_list(api_class, true)
		"property":
			return ClassDB.class_get_property_list(api_class, true)
		"signal":
			return ClassDB.class_get_signal_list(api_class, true)
		"constant":
			return Array(ClassDB.class_get_integer_constant_list(api_class, true))
		"enum":
			return Array(ClassDB.class_get_enum_list(api_class, true))
	return []


static func _normalize_member(declaring_class: String, kind: String, raw) -> Dictionary:
	if kind == "constant" or kind == "enum":
		var name := str(raw)
		if name.is_empty():
			return {}
		if kind == "constant":
			var enum_name := str(ClassDB.class_get_integer_constant_enum(declaring_class, name, true))
			return {
				"kind": kind,
				"name": _bounded_string(name),
				"declaring_class": _bounded_string(declaring_class),
				"value": ClassDB.class_get_integer_constant(declaring_class, name),
				"enum": _bounded_string(enum_name),
				"help_topic": _help_topic(kind, declaring_class, name)
			}
		var values: Array[Dictionary] = []
		var constants := ClassDB.class_get_enum_constants(declaring_class, name, true)
		for index in range(mini(constants.size(), MAX_OVERVIEW_MEMBERS)):
			var constant_name := str(constants[index])
			values.append({"name": _bounded_string(constant_name), "value": ClassDB.class_get_integer_constant(declaring_class, constant_name)})
		return {
			"kind": kind,
			"name": _bounded_string(name),
			"declaring_class": _bounded_string(declaring_class),
			"value_count": constants.size(),
			"values": values,
			"values_truncated": values.size() < constants.size(),
			"help_topic": _help_topic(kind, declaring_class, name)
		}
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var name := str(raw.get("name", ""))
	if name.is_empty():
		return {}
	var record := {
		"kind": kind,
		"name": _bounded_string(name),
		"declaring_class": _bounded_string(declaring_class),
		"help_topic": _help_topic(kind, declaring_class, name)
	}
	if kind == "property":
		record["type"] = _type_description(raw)
		record["getter"] = _bounded_string(str(ClassDB.class_get_property_getter(declaring_class, name)))
		record["setter"] = _bounded_string(str(ClassDB.class_get_property_setter(declaring_class, name)))
		record["usage"] = int(raw.get("usage", 0))
		return record
	var arguments: Array[Dictionary] = []
	var raw_arguments = raw.get("args", [])
	if typeof(raw_arguments) == TYPE_ARRAY:
		for index in range(mini(raw_arguments.size(), MAX_ARGUMENTS)):
			if typeof(raw_arguments[index]) == TYPE_DICTIONARY:
				arguments.append({"name": _bounded_string(str(raw_arguments[index].get("name", ""))), "type": _type_description(raw_arguments[index])})
	record["arguments"] = arguments
	record["argument_count"] = raw_arguments.size() if typeof(raw_arguments) == TYPE_ARRAY else 0
	record["arguments_truncated"] = int(record["argument_count"]) > arguments.size()
	if kind == "method":
		var return_value = raw.get("return", {})
		record["return_type"] = _type_description(return_value if typeof(return_value) == TYPE_DICTIONARY else {})
		var flags := int(raw.get("flags", 0))
		record["flags"] = {"value": flags, "const": bool(flags & METHOD_FLAG_CONST), "static": bool(flags & METHOD_FLAG_STATIC), "vararg": bool(flags & METHOD_FLAG_VARARG), "virtual": bool(flags & METHOD_FLAG_VIRTUAL)}
		record["signature"] = _method_signature(name, arguments, record["return_type"], bool(record["arguments_truncated"]))
	else:
		record["signature"] = _signal_signature(name, arguments, bool(record["arguments_truncated"]))
	return record


static func _type_description(raw: Dictionary) -> Dictionary:
	var type_id := int(raw.get("type", TYPE_NIL))
	return {
		"variant_type": _bounded_string(type_string(type_id)),
		"variant_type_id": type_id,
		"class_name": _bounded_string(str(raw.get("class_name", ""))),
		"hint": int(raw.get("hint", PROPERTY_HINT_NONE)),
		"hint_string": _bounded_string(str(raw.get("hint_string", "")))
	}


static func _method_signature(name: String, arguments: Array[Dictionary], return_type: Dictionary, truncated: bool) -> String:
	var parts := PackedStringArray()
	for argument in arguments:
		parts.append("%s: %s" % [argument.get("name", ""), _display_type(argument.get("type", {}))])
	if truncated:
		parts.append("...")
	return _bounded_string("%s(%s) -> %s" % [name, ", ".join(parts), _display_type(return_type)])


static func _signal_signature(name: String, arguments: Array[Dictionary], truncated: bool) -> String:
	var parts := PackedStringArray()
	for argument in arguments:
		parts.append("%s: %s" % [argument.get("name", ""), _display_type(argument.get("type", {}))])
	if truncated:
		parts.append("...")
	return _bounded_string("%s(%s)" % [name, ", ".join(parts)])


static func _display_type(description: Dictionary) -> String:
	var object_class := str(description.get("class_name", ""))
	return object_class if not object_class.is_empty() else str(description.get("variant_type", "Variant"))


static func _bounded_overview(records_by_kind: Dictionary, requested_kind: String, reasons: PackedStringArray) -> Array[Dictionary]:
	var kinds := REFLECTED_KINDS if requested_kind == "auto" else [requested_kind]
	var result: Array[Dictionary] = []
	var indexes := {}
	for kind in kinds:
		indexes[kind] = 0
	var added := true
	while result.size() < MAX_OVERVIEW_MEMBERS and added:
		added = false
		for kind in kinds:
			var records: Array = records_by_kind.get(kind, [])
			var index := int(indexes[kind])
			if index < records.size() and result.size() < MAX_OVERVIEW_MEMBERS:
				result.append(records[index])
				indexes[kind] = index + 1
				added = true
	var available := 0
	for kind in kinds:
		available += records_by_kind.get(kind, []).size()
	if result.size() < available:
		_add_reason(reasons, "overview_member_limit")
	return result


static func _exact_matches(records_by_kind: Dictionary, requested_kind: String, member_name: String, reasons: PackedStringArray) -> Array[Dictionary]:
	var kinds := REFLECTED_KINDS if requested_kind == "auto" else [requested_kind]
	var result: Array[Dictionary] = []
	var total := 0
	for kind in kinds:
		for record in records_by_kind.get(kind, []):
			if str(record.get("name", "")) != member_name:
				continue
			total += 1
			if result.size() < MAX_EXACT_MATCHES:
				result.append(record)
	if total > result.size():
		_add_reason(reasons, "exact_match_limit")
	return result


static func _help_topic(kind: String, api_class: String, member_name: String) -> String:
	var prefix := {
		"class": "class_name",
		"method": "class_method",
		"property": "class_property",
		"signal": "class_signal",
		"constant": "class_constant",
		"enum": "class_enum"
	}.get(kind, "class_name")
	var topic := "%s:%s" % [prefix, api_class]
	if not member_name.is_empty():
		topic += ":" + member_name
	return _bounded_string(topic)


static func _engine_version() -> Dictionary:
	var raw := Engine.get_version_info()
	return {
		"major": int(raw.get("major", 0)),
		"minor": int(raw.get("minor", 0)),
		"patch": int(raw.get("patch", 0)),
		"status": _bounded_string(str(raw.get("status", ""))),
		"build": _bounded_string(str(raw.get("build", ""))),
		"hash": _bounded_string(str(raw.get("hash", ""))),
		"string": _bounded_string(str(raw.get("string", "")))
	}


static func _fit_and_serialize(report: Dictionary) -> String:
	var content := JSON.stringify(report, "  ")
	while content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES and not report.get("members", []).is_empty():
		report["members"].pop_back()
		report["returned_member_count"] = report["members"].size()
		_add_reason_to_report(report, "output_limit")
		content = JSON.stringify(report, "  ")
	if content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES:
		report["total_members_by_kind"] = {}
		report["class"]["global_class"] = {}
		_add_reason_to_report(report, "output_limit")
		content = JSON.stringify(report, "  ")
	return content


static func _bounded_string(value: String) -> String:
	return value if value.length() <= MAX_STRING_CHARS else value.left(MAX_STRING_CHARS)


static func _add_reason(reasons: PackedStringArray, reason: String) -> void:
	if reason not in reasons:
		reasons.append(reason)


static func _add_reason_to_report(report: Dictionary, reason: String) -> void:
	var truncation: Dictionary = report.get("truncation", {})
	var reasons: Array = truncation.get("reasons", [])
	if reason not in reasons:
		reasons.append(reason)
	truncation["truncated"] = true
	truncation["reasons"] = reasons
	report["truncation"] = truncation


static func _error(message: String) -> Dictionary:
	return {"success": false, "content": "Error: " + _bounded_string(message), "outcome": "failed", "data": {}}
