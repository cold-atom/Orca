@tool
extends RefCounted

const MAX_SOURCE_BYTES := 2 * 1024 * 1024
const MAX_RETURN_LINES := 300
const MAX_RETURN_BYTES := 96 * 1024
const MAX_CANDIDATES := 20
const MAX_FUNCTION_NAME_CHARS := 128
const PROTECTED_ROOT := "res://addons/orca"


static func read_function(arguments: Dictionary, open_script: Dictionary = {}) -> Dictionary:
	var argument_error := _validate_arguments(arguments)
	if not argument_error.is_empty():
		return _error(argument_error)
	var filepath: String = arguments["filepath"]
	var path_result := _validate_path(filepath)
	if not path_result.get("success", false):
		return _error(str(path_result.get("error", "Invalid script path.")))
	var canonical_path: String = path_result["path"]
	var source_result := _read_source(canonical_path, open_script)
	if not source_result.get("success", false):
		return _error(str(source_result.get("error", "Could not read script source.")))

	var function_name: String = arguments["function_name"]
	var include_documentation: bool = arguments.get("include_documentation", true)
	var start_line_hint: int = arguments.get("start_line_hint", 0)
	var source: String = source_result["source"]
	var newline := "\r\n" if source.contains("\r\n") else "\n"
	var normalized := source.replace("\r\n", "\n").replace("\r", "\n")
	var lines := normalized.split("\n", true)
	var code_lines := _sanitize_lines(lines)
	var scan := _find_candidates(lines, code_lines, function_name)
	if not scan.get("success", false):
		return _error(str(scan.get("error", "Could not scan script source.")), scan.get("candidates", []), int(scan.get("candidate_count", 0)))
	var candidates: Array = scan.get("candidates", [])
	var candidate_count := int(scan.get("candidate_count", candidates.size()))
	if candidates.is_empty():
		return _error("Function '%s' was not found in %s." % [function_name, canonical_path])
	if candidate_count > MAX_CANDIDATES:
		return _error("Function name has more than %d candidates; narrow the source before reading it." % MAX_CANDIDATES, _candidate_summaries(candidates), candidate_count)
	var selection := _select_candidate(candidates, start_line_hint)
	if not selection.get("success", false):
		return _error(str(selection.get("error", "The function reference is ambiguous.")), _candidate_summaries(candidates), candidates.size())
	var candidate: Dictionary = selection["candidate"]
	var output_start: int = candidate["declaration_index"]
	if include_documentation:
		output_start = _metadata_start(lines, code_lines, output_start, int(candidate["indent"]))
	var output := _bounded_content(lines, output_start, int(candidate["end_index"]), newline)
	var result := {
		"success": true,
		"filepath": canonical_path,
		"function_name": function_name,
		"source_kind": source_result["source_kind"],
		"content": output["content"],
		"start_line": output_start + 1,
		"end_line": int(output["last_index"]) + 1,
		"declaration_line": int(candidate["declaration_index"]) + 1,
		"declaration_column": int(candidate["indent_chars"]) + 1,
		"function_end_line": int(candidate["end_index"]) + 1,
		"class_path": candidate["class_path"],
		"is_static": candidate["is_static"],
		"returned_line_count": output["line_count"],
		"truncated": output["truncated"],
		"truncation_reasons": output["reasons"],
		"open_path": canonical_path,
		"open_line": int(candidate["declaration_index"]) + 1,
		"open_column": int(candidate["indent_chars"]) + 1
	}
	if source_result["source_kind"] == "disk":
		result["disk_sha256"] = source_result["disk_sha256"]
	return result


static func _validate_arguments(arguments: Dictionary) -> String:
	for key in arguments:
		if str(key) not in ["filepath", "function_name", "start_line_hint", "include_documentation"]:
			return "Unknown function-reader argument: " + str(key)
	if typeof(arguments.get("filepath")) != TYPE_STRING or str(arguments.get("filepath", "")).is_empty():
		return "filepath must be a non-empty string."
	if typeof(arguments.get("function_name")) != TYPE_STRING:
		return "function_name must be a string."
	var function_name: String = arguments.get("function_name", "")
	if function_name.is_empty() or function_name.length() > MAX_FUNCTION_NAME_CHARS or not function_name.is_valid_identifier():
		return "function_name must be a valid GDScript identifier of at most %d characters." % MAX_FUNCTION_NAME_CHARS
	if arguments.has("start_line_hint") and (typeof(arguments["start_line_hint"]) != TYPE_INT or int(arguments["start_line_hint"]) < 1):
		return "start_line_hint must be a positive one-based integer."
	if arguments.has("include_documentation") and typeof(arguments["include_documentation"]) != TYPE_BOOL:
		return "include_documentation must be a boolean."
	return ""


static func _validate_path(filepath: String) -> Dictionary:
	if not filepath.begins_with("res://"):
		return {"success": false, "error": "Only res:// project paths are allowed."}
	var project_root := ProjectSettings.globalize_path("res://").simplify_path()
	var absolute_path := ProjectSettings.globalize_path(filepath).simplify_path()
	if absolute_path != project_root and not absolute_path.begins_with(project_root + "/"):
		return {"success": false, "error": "The script path resolves outside the project."}
	var canonical_path := ProjectSettings.localize_path(absolute_path)
	if canonical_path != filepath:
		return {"success": false, "error": "filepath must be a canonical res:// path."}
	if canonical_path.get_extension() != "gd":
		return {"success": false, "error": "The function reader accepts canonical .gd paths only."}
	if canonical_path == PROTECTED_ROOT or canonical_path.begins_with(PROTECTED_ROOT + "/"):
		return {"success": false, "error": "Orca's own addon directory is protected."}
	if _contains_symbolic_link(project_root, absolute_path):
		return {"success": false, "error": "Paths containing symbolic links are blocked."}
	return {"success": true, "path": canonical_path}


static func _contains_symbolic_link(project_root: String, absolute_path: String) -> bool:
	var relative := absolute_path.trim_prefix(project_root).trim_prefix("/")
	var current := project_root
	for component in relative.split("/", false):
		var parent := DirAccess.open(current)
		if parent != null and parent.is_link(component):
			return true
		current = current.path_join(component)
	return false


static func _read_source(filepath: String, open_script: Dictionary) -> Dictionary:
	if not open_script.is_empty():
		for key in open_script:
			if str(key) not in ["filepath", "source"]:
				return {"success": false, "error": "Unknown open-script field: " + str(key)}
		if typeof(open_script.get("filepath")) != TYPE_STRING or typeof(open_script.get("source")) != TYPE_STRING:
			return {"success": false, "error": "open_script requires string filepath and source fields."}
		if str(open_script["filepath"]) != filepath:
			return {"success": false, "error": "The open-script source path does not match filepath."}
		var open_source: String = open_script["source"]
		var open_bytes := open_source.to_utf8_buffer()
		if open_bytes.size() > MAX_SOURCE_BYTES:
			return {"success": false, "error": "Open script source exceeds the 2 MiB limit."}
		if open_bytes.has(0):
			return {"success": false, "error": "Open script source contains NUL bytes."}
		return {"success": true, "source": open_source, "source_kind": "editor"}
	if not FileAccess.file_exists(filepath):
		return {"success": false, "error": "Script does not exist at path: " + filepath}
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		return {"success": false, "error": "Could not open the script for reading."}
	var size := file.get_length()
	if size > MAX_SOURCE_BYTES:
		file.close()
		return {"success": false, "error": "Script exceeds the 2 MiB limit."}
	var bytes := file.get_buffer(size)
	file.close()
	if bytes.has(0):
		return {"success": false, "error": "Script contains NUL bytes."}
	var source := bytes.get_string_from_utf8()
	if source.to_utf8_buffer() != bytes:
		return {"success": false, "error": "Script is not valid UTF-8 text."}
	var disk_sha256 := _sha256(bytes)
	if disk_sha256.is_empty():
		return {"success": false, "error": "Could not hash the script source."}
	return {
		"success": true,
		"source": source,
		"source_kind": "disk",
		"disk_sha256": disk_sha256
	}


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func _sanitize_lines(lines: PackedStringArray) -> PackedStringArray:
	var sanitized := PackedStringArray()
	var triple_quote := ""
	for line in lines:
		var output := ""
		var index := 0
		while index < line.length():
			if not triple_quote.is_empty():
				if index + 2 < line.length() and line.substr(index, 3) == triple_quote and not _is_escaped(line, index):
					output += "   "
					index += 3
					triple_quote = ""
				else:
					output += " "
					index += 1
				continue
			var character := line.substr(index, 1)
			if character == "#":
				output += " ".repeat(line.length() - index)
				break
			if character == "\"" or character == "'":
				var delimiter := character.repeat(3)
				if index + 2 < line.length() and line.substr(index, 3) == delimiter:
					triple_quote = delimiter
					output += "   "
					index += 3
					continue
				output += " "
				index += 1
				while index < line.length():
					var string_character := line.substr(index, 1)
					output += " "
					index += 1
					if string_character == character and not _is_escaped(line, index - 1):
						break
				continue
			output += character
			index += 1
		sanitized.append(output)
	return sanitized


static func _is_escaped(line: String, index: int) -> bool:
	var slashes := 0
	var cursor := index - 1
	while cursor >= 0 and line.substr(cursor, 1) == "\\":
		slashes += 1
		cursor -= 1
	return slashes % 2 == 1


static func _find_candidates(lines: PackedStringArray, code_lines: PackedStringArray, function_name: String) -> Dictionary:
	var candidates: Array = []
	var candidate_count := 0
	var classes: Array = []
	for line_index in range(code_lines.size()):
		var code: String = code_lines[line_index]
		if code.strip_edges().is_empty():
			continue
		var indent := _indent_width(code)
		while not classes.is_empty() and indent <= int(classes.back()["indent"]):
			classes.pop_back()
		var nested_class_name := _class_declaration_name(code)
		if not nested_class_name.is_empty():
			classes.append({"name": nested_class_name, "indent": indent})
			continue
		var declaration := _function_declaration(code)
		if declaration.is_empty() or declaration["name"] != function_name:
			continue
		candidate_count += 1
		var signature_end := _signature_end(code_lines, line_index, int(declaration["name_end"]))
		if signature_end < 0:
			var partial := {
				"declaration_line": line_index + 1,
				"class_path": _class_path(classes),
				"is_static": declaration["is_static"]
			}
			return {"success": false, "error": "Function '%s' has an unterminated signature at line %d." % [function_name, line_index + 1], "candidates": [partial], "candidate_count": 1}
		var end_index := _function_end(code_lines, signature_end, indent)
		if candidates.size() < MAX_CANDIDATES:
			candidates.append({
				"declaration_index": line_index,
				"signature_end_index": signature_end,
				"end_index": end_index,
				"indent": indent,
				"indent_chars": _indent_character_count(code),
				"class_path": _class_path(classes),
				"is_static": declaration["is_static"]
			})
	return {"success": true, "candidates": candidates, "candidate_count": candidate_count}


static func _function_declaration(code: String) -> Dictionary:
	var cursor := _indent_character_count(code)
	var is_static := false
	if _token_at(code, cursor, "static"):
		is_static = true
		cursor += 6
		cursor = _skip_space(code, cursor)
	if not _token_at(code, cursor, "func"):
		return {}
	cursor += 4
	cursor = _skip_space(code, cursor)
	var name_start := cursor
	while cursor < code.length() and _is_identifier_character(code.substr(cursor, 1)):
		cursor += 1
	if cursor == name_start:
		return {}
	var name := code.substr(name_start, cursor - name_start)
	if not name.is_valid_identifier():
		return {}
	var after_name := _skip_space(code, cursor)
	if after_name >= code.length() or code.substr(after_name, 1) != "(":
		return {}
	return {"name": name, "name_end": cursor, "is_static": is_static}


static func _class_declaration_name(code: String) -> String:
	var cursor := _indent_character_count(code)
	if not _token_at(code, cursor, "class"):
		return ""
	cursor = _skip_space(code, cursor + 5)
	var start := cursor
	while cursor < code.length() and _is_identifier_character(code.substr(cursor, 1)):
		cursor += 1
	if cursor == start:
		return ""
	var name := code.substr(start, cursor - start)
	return name if name.is_valid_identifier() else ""


static func _token_at(text: String, index: int, token: String) -> bool:
	if text.substr(index, token.length()) != token:
		return false
	var end := index + token.length()
	return end >= text.length() or not _is_identifier_character(text.substr(end, 1))


static func _is_identifier_character(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or (character >= "0" and character <= "9")


static func _skip_space(text: String, index: int) -> int:
	while index < text.length() and text.substr(index, 1) in [" ", "\t"]:
		index += 1
	return index


static func _signature_end(code_lines: PackedStringArray, start_index: int, name_end: int) -> int:
	var depth := 0
	for line_index in range(start_index, code_lines.size()):
		var code: String = code_lines[line_index]
		var cursor := name_end if line_index == start_index else 0
		while cursor < code.length():
			var character := code.substr(cursor, 1)
			if character in ["(", "[", "{"]:
				depth += 1
			elif character in [")", "]", "}"]:
				depth -= 1
				if depth < 0:
					return -1
			elif character == ":" and depth == 0:
				return line_index
			cursor += 1
	return -1


static func _function_end(code_lines: PackedStringArray, signature_end: int, declaration_indent: int) -> int:
	var end_index := signature_end
	for line_index in range(signature_end + 1, code_lines.size()):
		var code: String = code_lines[line_index]
		if code.strip_edges().is_empty():
			end_index = line_index
			continue
		if _indent_width(code) <= declaration_indent:
			break
		end_index = line_index
	while end_index > signature_end and code_lines[end_index].strip_edges().is_empty():
		end_index -= 1
	return end_index


static func _metadata_start(lines: PackedStringArray, code_lines: PackedStringArray, declaration_index: int, declaration_indent: int) -> int:
	var boundary := declaration_index
	while boundary > 0:
		var previous := boundary - 1
		if lines[previous].strip_edges().is_empty() or _indent_width(lines[previous]) < declaration_indent:
			break
		boundary = previous
	for possible_start in range(boundary, declaration_index):
		if _valid_metadata_segment(lines, code_lines, possible_start, declaration_index):
			return possible_start
	return declaration_index


static func _valid_metadata_segment(lines: PackedStringArray, code_lines: PackedStringArray, start: int, end: int) -> bool:
	var annotation_depth := 0
	var saw_metadata := false
	for index in range(start, end):
		var raw := lines[index].strip_edges()
		var code := code_lines[index].strip_edges()
		if annotation_depth == 0:
			if raw.begins_with("##"):
				saw_metadata = true
				continue
			if not code.begins_with("@"):
				return false
			saw_metadata = true
		annotation_depth += _bracket_delta(code)
		if annotation_depth < 0:
			return false
	return saw_metadata and annotation_depth == 0


static func _bracket_delta(code: String) -> int:
	var delta := 0
	for character in code:
		if character in ["(", "[", "{"]:
			delta += 1
		elif character in [")", "]", "}"]:
			delta -= 1
	return delta


static func _select_candidate(candidates: Array, hint: int) -> Dictionary:
	if candidates.size() == 1:
		return {"success": true, "candidate": candidates[0]}
	if hint <= 0:
		return {"success": false, "error": "Function name is ambiguous; provide start_line_hint to select one of %d candidates." % candidates.size()}
	var containing: Array = []
	for candidate in candidates:
		if hint >= int(candidate["declaration_index"]) + 1 and hint <= int(candidate["end_index"]) + 1:
			containing.append(candidate)
	if containing.size() == 1:
		return {"success": true, "candidate": containing[0]}
	if containing.size() > 1:
		return {"success": false, "error": "start_line_hint falls within multiple candidates."}
	var nearest: Array = []
	var nearest_distance := 9223372036854775807
	for candidate in candidates:
		var distance := absi(int(candidate["declaration_index"]) + 1 - hint)
		if distance < nearest_distance:
			nearest = [candidate]
			nearest_distance = distance
		elif distance == nearest_distance:
			nearest.append(candidate)
	if nearest.size() == 1:
		return {"success": true, "candidate": nearest[0]}
	return {"success": false, "error": "start_line_hint is equally close to multiple candidates."}


static func _candidate_summaries(candidates: Array) -> Array:
	var summaries: Array = []
	for index in range(mini(candidates.size(), MAX_CANDIDATES)):
		var candidate: Dictionary = candidates[index]
		summaries.append({
			"declaration_line": int(candidate["declaration_index"]) + 1,
			"end_line": int(candidate["end_index"]) + 1,
			"class_path": candidate["class_path"],
			"is_static": candidate["is_static"]
		})
	return summaries


static func _bounded_content(lines: PackedStringArray, start_index: int, end_index: int, newline: String) -> Dictionary:
	var selected: Array[String] = []
	var reasons: Array[String] = []
	var last_index := start_index
	var used_bytes := 0
	for index in range(start_index, end_index + 1):
		if selected.size() >= MAX_RETURN_LINES:
			reasons.append("line_limit")
			break
		var line: String = lines[index]
		var separator := "" if selected.is_empty() else newline
		var separator_bytes := separator.to_utf8_buffer().size()
		var available := MAX_RETURN_BYTES - used_bytes - separator_bytes
		if available < 0:
			reasons.append("byte_limit")
			break
		if line.to_utf8_buffer().size() > available:
			selected.append(separator + _utf8_prefix(line, maxi(0, available)))
			reasons.append("byte_limit")
			last_index = index
			break
		selected.append(separator + line)
		used_bytes += separator_bytes + line.to_utf8_buffer().size()
		last_index = index
	if last_index < end_index and reasons.is_empty():
		reasons.append("line_limit")
	return {
		"content": "".join(selected),
		"last_index": last_index,
		"line_count": selected.size(),
		"truncated": not reasons.is_empty(),
		"reasons": reasons
	}


static func _utf8_prefix(text: String, byte_limit: int) -> String:
	var low := 0
	var high := text.length()
	while low < high:
		var middle := (low + high + 1) >> 1
		if text.left(middle).to_utf8_buffer().size() <= byte_limit:
			low = middle
		else:
			high = middle - 1
	return text.left(low)


static func _indent_width(line: String) -> int:
	var width := 0
	for character in line:
		if character == " ":
			width += 1
		elif character == "\t":
			width += 4 - (width % 4)
		else:
			break
	return width


static func _indent_character_count(line: String) -> int:
	var count := 0
	while count < line.length() and line.substr(count, 1) in [" ", "\t"]:
		count += 1
	return count


static func _class_path(classes: Array) -> String:
	var names := PackedStringArray()
	for entry in classes:
		names.append(str(entry["name"]))
	return ".".join(names)


static func _error(message: String, candidates: Array = [], candidate_count: int = 0) -> Dictionary:
	var result := {"success": false, "error": message}
	if candidate_count > 0:
		result["candidate_count"] = candidate_count
		result["candidates"] = candidates.slice(0, MAX_CANDIDATES)
		result["candidates_truncated"] = candidate_count > MAX_CANDIDATES
	return result
