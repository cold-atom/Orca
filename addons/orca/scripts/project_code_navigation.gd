@tool
extends RefCounted

# On-demand lexical index. Never load scripts, retain source, or supply patch hashes.
const MAX_RESULTS := 100
const MAX_NAME_CHARS := 128
const MAX_PATH_CHARS := 512
const MAX_SOURCE_BYTES := 512 * 1024
const MAX_TOTAL_BYTES := 8 * 1024 * 1024
const MAX_FILES := 256
const MAX_DIRECTORIES := 128
const MAX_ENTRIES := 4096
const MAX_LINE_CHARS := 8192
const MAX_LINE_TOKENS := 2048
const MAX_OUTPUT_BYTES := 96 * 1024
const MAX_PREVIEW_CHARS := 240
const SCAN_TIMEOUT_MS := 250
const KINDS := ["auto", "class", "function", "signal", "member", "constant", "enum"]


static func inspect(arguments: Dictionary, references: bool, validate_path: Callable, dirty_paths: Array = []) -> Dictionary:
	var error := _argument_error(arguments, references)
	if not error.is_empty():
		return {"success": false, "error": error}
	var path: String = arguments.get("path", "res://")
	if not path.begins_with("res://") or path.length() > MAX_PATH_CHARS or path.to_utf8_buffer().has(0):
		return {"success": false, "error": "path must be a bounded canonical res:// directory or .gd file."}
	var canonical := ProjectSettings.localize_path(ProjectSettings.globalize_path(path).simplify_path())
	# Godot localizes existing directories with a trailing slash.
	if canonical.trim_suffix("/") != path.trim_suffix("/") or not validate_path.call(path, false).is_empty():
		return {"success": false, "error": "The path is noncanonical, outside the project, protected, or contains a symbolic link."}
	var single_file := FileAccess.file_exists(path)
	if single_file and path.get_extension() != "gd":
		return {"success": false, "error": "Only standalone saved .gd scripts are supported."}
	if not single_file and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(path)):
		return {"success": false, "error": "The requested directory or script does not exist."}
	if single_file and path in dirty_paths:
		return {"success": false, "error": "This script has unsaved editor changes. Save it before searching its saved declarations or references."}
	var started := Time.get_ticks_msec()
	var state := {
		"deadline": started + SCAN_TIMEOUT_MS, "reasons": [], "matches": [],
		"files_scanned": 0, "directories_scanned": 0, "entries_scanned": 0,
		"source_bytes": 0, "skipped_files": 0, "stopped": false,
		"max_results": int(arguments.get("max_results", MAX_RESULTS)),
		"query": str(arguments.get("symbol" if references else "query", "")),
		"kind": str(arguments.get("kind", "auto")),
		"references": references, "include_declarations": bool(arguments.get("include_declarations", false))
	}
	if single_file:
		_scan_file(path, state)
	else:
		_scan_directory(path, state, validate_path, dirty_paths)
	var report := {
		"path": path, "source": "saved_gdscript_lexical_scan",
		"query": state["query"], "kind": "references" if references else state["kind"],
		"matches": state["matches"], "returned_match_count": state["matches"].size(),
		"scan": {"files_scanned": state["files_scanned"], "directories_scanned": state["directories_scanned"], "entries_scanned": state["entries_scanned"], "source_bytes": state["source_bytes"], "skipped_files": state["skipped_files"], "elapsed_ms": Time.get_ticks_msec() - started},
		"truncation": {"truncated": not state["reasons"].is_empty(), "reasons": state["reasons"]},
		"note": "Saved standalone .gd source only; dirty scripts are omitted. Lexical declarations and whole-identifier reference candidates exclude comments and strings. Candidates are not resolved to a declaration: locals, parameters, shadowing and unrelated same-name members may match. Dynamic/string-based calls, scene connections, inherited members and runtime state are not covered. No result is a patch base; use a fresh read_file and normal approval for edits."
	}
	var content := JSON.stringify(report, "  ")
	while content.to_utf8_buffer().size() > MAX_OUTPUT_BYTES and not report["matches"].is_empty():
		report["matches"].pop_back()
		report["returned_match_count"] = report["matches"].size()
		_reason(state, "output_limit")
		report["truncation"]["truncated"] = true
		content = JSON.stringify(report, "  ")
	return {"success": true, "report": report, "content": content}


static func _argument_error(arguments: Dictionary, references: bool) -> String:
	var allowed := ["symbol", "path", "max_results", "include_declarations"] if references else ["query", "path", "kind", "max_results"]
	for key in arguments:
		if typeof(key) != TYPE_STRING or key not in allowed:
			return "Unknown code-navigation argument: " + str(key)
	var name_key := "symbol" if references else "query"
	if (references or arguments.has(name_key)) and typeof(arguments.get(name_key)) != TYPE_STRING:
		return name_key + " must be a string."
	var name: String = arguments.get(name_key, "")
	if name.length() > MAX_NAME_CHARS or (references and not _valid_identifier(name)) or name.contains("\n") or name.contains("\r") or name.to_utf8_buffer().has(0):
		return name_key + " must be a bounded identifier (query may be an empty or partial name)."
	if arguments.has("path") and typeof(arguments["path"]) != TYPE_STRING:
		return "path must be a string."
	if arguments.has("kind") and (typeof(arguments["kind"]) != TYPE_STRING or arguments["kind"] not in KINDS):
		return "kind must be one of: " + ", ".join(KINDS)
	if arguments.has("include_declarations") and typeof(arguments["include_declarations"]) != TYPE_BOOL:
		return "include_declarations must be a boolean."
	if arguments.has("max_results"):
		if typeof(arguments["max_results"]) not in [TYPE_INT, TYPE_FLOAT]:
			return "max_results must be an integer from 1 to %d." % MAX_RESULTS
		var limit := float(arguments["max_results"])
		if not is_finite(limit) or limit != floorf(limit) or limit < 1 or limit > MAX_RESULTS:
			return "max_results must be an integer from 1 to %d." % MAX_RESULTS
	return ""


static func _scan_directory(root: String, state: Dictionary, validate_path: Callable, dirty_paths: Array) -> void:
	var queue := [root]
	var cursor := 0
	while cursor < queue.size() and not _stopped(state):
		if state["directories_scanned"] >= MAX_DIRECTORIES:
			_stop(state, "directory_limit")
			break
		var path: String = queue[cursor]
		cursor += 1
		if not validate_path.call(path, false).is_empty():
			_reason(state, "unsafe_path_omitted")
			continue
		var directory := DirAccess.open(path)
		if directory == null:
			_reason(state, "unreadable_directory")
			continue
		state["directories_scanned"] += 1
		var files: Array[String] = []
		var children: Array[String] = []
		directory.list_dir_begin()
		var entry := directory.get_next()
		while not entry.is_empty() and not _stopped(state):
			if state["entries_scanned"] >= MAX_ENTRIES:
				_stop(state, "entry_limit")
				break
			state["entries_scanned"] += 1
			var child_path := path.path_join(entry)
			if child_path.length() > MAX_PATH_CHARS:
				_reason(state, "path_limit")
			elif directory.is_link(entry):
				_reason(state, "symbolic_link_omitted")
			elif entry not in [".godot", ".git", ".orca-update"] and not validate_path.call(child_path, false).is_empty():
				# Protected addon/update bytes are never inspected.
				pass
			elif entry not in [".godot", ".git", ".orca-update"]:
				if directory.current_is_dir():
					children.append(child_path)
				elif entry.get_extension() == "gd":
					files.append(child_path)
			entry = directory.get_next()
		directory.list_dir_end()
		files.sort()
		children.sort()
		for filepath in files:
			if _stopped(state):
				break
			if filepath in dirty_paths:
				state["skipped_files"] += 1
				_reason(state, "unsaved_script_omitted")
				continue
			# Recheck ancestors after enumeration and immediately before opening.
			if not validate_path.call(filepath, false).is_empty():
				_reason(state, "unsafe_path_omitted")
				continue
			_scan_file(filepath, state)
		for child in children:
			if queue.size() >= MAX_DIRECTORIES:
				_reason(state, "directory_limit")
				break
			queue.append(child)


static func _scan_file(path: String, state: Dictionary) -> void:
	if _stopped(state):
		return
	if state["files_scanned"] >= MAX_FILES:
		_stop(state, "file_limit")
		return
	state["files_scanned"] += 1
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_skip(state, "unreadable_script")
		return
	var length := file.get_length()
	if length > MAX_SOURCE_BYTES:
		file.close()
		_skip(state, "source_file_limit")
		return
	if state["source_bytes"] + length > MAX_TOTAL_BYTES:
		file.close()
		_stop(state, "source_total_limit")
		return
	var bytes := file.get_buffer(length)
	file.close()
	state["source_bytes"] += bytes.size()
	if bytes.size() != length or bytes.has(0):
		_skip(state, "invalid_source")
		return
	var source := bytes.get_string_from_utf8()
	if source.to_utf8_buffer() != bytes:
		_skip(state, "invalid_source")
		return
	var lines := source.replace("\r\n", "\n").replace("\r", "\n").split("\n", true)
	var lexer := {"quote": "", "escaped": false}
	var scopes: Array = []
	var root_class := ""
	var depth := 0
	var continued := false
	var pending_block := {}
	for index in range(lines.size()):
		if _stopped(state):
			break
		var line: String = lines[index]
		if line.length() > MAX_LINE_CHARS:
			_skip(state, "source_line_limit")
			break # Do not guess string/scope state after an omitted line.
		var tokens := _tokens(line, lexer, state)
		if _stopped(state) or tokens.is_empty():
			continue
		var indent := _indent(line)
		var declaration := {}
		if depth == 0 and not continued:
			while not scopes.is_empty() and indent <= int(scopes.back()["indent"]):
				scopes.pop_back()
			var class_body: bool = scopes.is_empty() or scopes.back()["kind"] == "class"
			if class_body:
				declaration = _declaration(tokens)
		var class_names := PackedStringArray()
		if not root_class.is_empty():
			class_names.append(root_class)
		for scope in scopes:
			if scope["kind"] == "class":
				class_names.append(scope["name"])
		var class_path := ".".join(class_names)
		if not declaration.is_empty():
			var token: Dictionary = tokens[declaration["token_index"]]
			var symbol: String = token["text"]
			var kind: String = declaration["kind"]
			if not state["references"] and (state["kind"] == "auto" or state["kind"] == kind) and (state["query"].is_empty() or symbol.contains(state["query"])):
				_append_match(state, path, index + 1, token["column"], symbol, kind, "declaration", class_path, line)
			if declaration.get("keyword") == "class_name":
				root_class = symbol
			if declaration.get("keyword") in ["func", "class"]:
				pending_block = {"indent": indent, "kind": "class" if declaration["keyword"] == "class" else "block", "name": symbol}
		if state["references"]:
			for token_index in range(tokens.size()):
				var token: Dictionary = tokens[token_index]
				if token["text"] != state["query"]:
					continue
				var is_declaration := token_index == int(declaration.get("token_index", -1))
				if not is_declaration or state["include_declarations"]:
					_append_match(state, path, index + 1, token["column"], token["text"], str(declaration.get("kind", "identifier")) if is_declaration else "identifier", "declaration" if is_declaration else "reference_candidate", class_path, line)
				if _stopped(state):
					break
		# Any non-class block suppresses member declarations in function/accessor bodies.
		for token in tokens:
			if token["text"] in ["(", "[", "{"]:
				depth += 1
			elif token["text"] in [")", "]", "}"]:
				depth = maxi(0, depth - 1)
		continued = tokens.back()["text"] == "\\"
		if depth == 0 and tokens.back()["text"] == ":":
			scopes.append(pending_block if not pending_block.is_empty() else {"indent": indent, "kind": "block", "name": ""})
			pending_block = {}
	if not lexer["quote"].is_empty() or depth != 0 or continued:
		_reason(state, "incomplete_lexical_source")


static func _tokens(line: String, lexer: Dictionary, state: Dictionary) -> Array:
	var tokens: Array = []
	var cursor := 0
	while cursor < line.length():
		if cursor % 256 == 0 and _stopped(state):
			return []
		if tokens.size() >= MAX_LINE_TOKENS:
			_stop(state, "token_limit")
			return []
		var character := line.substr(cursor, 1)
		if not lexer["quote"].is_empty():
			var quote: String = lexer["quote"]
			if not lexer["escaped"] and line.substr(cursor, quote.length()) == quote:
				cursor += quote.length()
				lexer["quote"] = ""
			else:
				lexer["escaped"] = character == "\\" and not lexer["escaped"]
				cursor += 1
			continue
		if character == "#":
			break
		if character in ["\"", "'"]:
			var quote := character.repeat(3) if line.substr(cursor, 3) == character.repeat(3) else character
			lexer["quote"] = quote
			lexer["escaped"] = false
			tokens.append({"text": "<string>", "column": cursor + 1})
			cursor += quote.length()
			continue
		if character in [" ", "\t"]:
			cursor += 1
			continue
		var start := cursor
		if _identifier_start(character):
			cursor += 1
			while cursor < line.length() and _identifier_part(line.substr(cursor, 1)):
				if cursor % 256 == 0 and _stopped(state):
					return []
				cursor += 1
		elif character >= "0" and character <= "9":
			cursor += 1
			while cursor < line.length() and _identifier_part(line.substr(cursor, 1)):
				if cursor % 256 == 0 and _stopped(state):
					return []
				cursor += 1
		else:
			cursor += 1
		var text := line.substr(start, cursor - start)
		tokens.append({"text": text if text.length() <= MAX_NAME_CHARS else "<long-token>", "column": start + 1})
	# Invalid single-line strings do not swallow unrelated later declarations.
	if str(lexer["quote"]).length() == 1:
		_reason(state, "incomplete_lexical_source")
		lexer["quote"] = ""
	lexer["escaped"] = false
	return tokens


static func _declaration(tokens: Array) -> Dictionary:
	var cursor := 0
	# Skip annotations, including inline argument lists; multi-line continuations
	# are suppressed by the enclosing scan's bracket depth.
	while cursor < tokens.size() and tokens[cursor]["text"] == "@":
		cursor += 2
		if cursor < tokens.size() and tokens[cursor]["text"] == "(":
			var depth := 1
			cursor += 1
			while cursor < tokens.size() and depth > 0:
				if tokens[cursor]["text"] == "(":
					depth += 1
				elif tokens[cursor]["text"] == ")":
					depth -= 1
				cursor += 1
	if cursor < tokens.size() and tokens[cursor]["text"] == "static":
		cursor += 1
	if cursor + 1 >= tokens.size():
		return {}
	var keyword: String = tokens[cursor]["text"]
	var kind := str({"class_name": "class", "class": "class", "func": "function", "signal": "signal", "var": "member", "const": "constant", "enum": "enum"}.get(keyword, ""))
	var name: String = tokens[cursor + 1]["text"]
	if kind.is_empty() or not _valid_identifier(name):
		return {}
	if keyword == "func" and (cursor + 2 >= tokens.size() or tokens[cursor + 2]["text"] != "("):
		return {}
	return {"token_index": cursor + 1, "kind": kind, "keyword": keyword}


static func _append_match(state: Dictionary, path: String, line: int, column: int, name: String, kind: String, role: String, class_path: String, preview: String) -> void:
	if state["matches"].size() >= state["max_results"]:
		_stop(state, "result_limit")
		return
	state["matches"].append({"filepath": path, "line": line, "column": column, "name": name, "kind": kind, "role": role, "class_path": class_path.left(MAX_NAME_CHARS * 4), "preview": preview.strip_edges().left(MAX_PREVIEW_CHARS)})


static func _identifier_start(character: String) -> bool:
	return character == "_" or character.is_valid_identifier() or (character.unicode_at(0) > 127 and _valid_identifier(character))


static func _identifier_part(character: String) -> bool:
	return _identifier_start(character) or (character >= "0" and character <= "9") or (character.unicode_at(0) > 127 and _valid_identifier("a" + character))


static func _valid_identifier(text: String) -> bool:
	return not text.is_empty() and TextServerManager.get_primary_interface().is_valid_identifier(text)


static func _indent(line: String) -> int:
	var width := 0
	for character in line:
		if character == " ":
			width += 1
		elif character == "\t":
			width += 4 - width % 4
		else:
			break
	return width


static func _reason(state: Dictionary, reason: String) -> void:
	if reason not in state["reasons"]:
		state["reasons"].append(reason)


static func _stop(state: Dictionary, reason: String) -> void:
	_reason(state, reason)
	state["stopped"] = true


static func _skip(state: Dictionary, reason: String) -> void:
	state["skipped_files"] += 1
	_reason(state, reason)


static func _stopped(state: Dictionary) -> bool:
	if not state["stopped"] and Time.get_ticks_msec() >= int(state["deadline"]):
		_stop(state, "time_limit")
	return state["stopped"]
