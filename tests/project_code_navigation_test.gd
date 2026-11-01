extends SceneTree

const Navigation = preload("res://addons/orca/scripts/project_code_navigation.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

var _failures := PackedStringArray()
var _root := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_root = "res://.orca_code_navigation_test_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_root))
	_write(_root.path_join(".gdignore"), "")
	_test_declarations()
	_test_references()
	_test_fresh_source()
	_test_boundaries()
	_test_limits()
	_remove_tree(ProjectSettings.globalize_path(_root))
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_root)), "all navigation fixtures must be removed")
	if _failures.is_empty():
		print("project_code_navigation_test: PASS")
		quit(0)
	else:
		for failure in _failures:
			printerr("project_code_navigation_test: ", failure)
		quit(1)


func _test_declarations() -> void:
	var path := _root.path_join("declarations.gd")
	var source := "class_name Player\nextends Node\nsignal health_changed(value: int)\n@export_range(0, 100) var health: int = 100\nstatic var shared := 1\nconst LIMIT := 10\nenum State { IDLE, RUN }\nvar description := \"\"\"\nfunc fake():\nvar phantom = 1\n\"\"\"\n# signal commented\nfunc move(\n\tvalue: int,\n\t) -> void:\n\tvar local_only := value\n\tif value > 0:\n\t\tvar another_local := 0\nclass Inventory:\n\tsignal item_added\n\t@onready var capacity := 3\n\tfunc move() -> void:\n\t\tvar nested_local := 0\n\tclass Item:\n\t\tconst WEIGHT := 1\n@export(\n\t)\nvar after_annotation := 3\nvar callback = func():\n\tvar lambda_local := 0\nvar computed: int:\n\tget:\n\t\tvar accessor_local := 1\n\t\treturn accessor_local\nstatic func final_function() -> void:\n\tpass\n"
	_write(path, source.replace("\n", "\r\n"))
	var result := _inspect({"path": path})
	_expect(result.get("success", false), "saved source must be scanned without loading even lexically valid unsupported annotations")
	var matches: Array = result.get("report", {}).get("matches", [])
	var expected := ["Player", "health_changed", "health", "shared", "LIMIT", "State", "description", "move", "Inventory", "item_added", "capacity", "move", "Item", "WEIGHT", "after_annotation", "callback", "computed", "final_function"]
	_expect(_names(matches) == expected, "declarations must distinguish nested classes, members, multiline signatures/annotations, lambdas, getters, comments and strings: " + str(_names(matches)))
	var nested_moves := matches.filter(func(match): return match.get("name") == "move")
	_expect(nested_moves.size() == 2 and nested_moves[0]["class_path"] == "Player" and nested_moves[1]["class_path"] == "Player.Inventory", "duplicate declarations must carry lexical class ownership")
	var health := matches.filter(func(match): return match.get("name") == "health")
	_expect(health.size() == 1 and health[0]["line"] == 4 and health[0]["column"] == 27 and health[0]["kind"] == "member", "annotation stripping must preserve exact one-based CRLF source coordinates")
	_expect(_names(_inspect({"path": path, "kind": "function", "query": "move"})["report"]["matches"]) == ["move", "move"], "partial name/kind lookup must retain ambiguous declarations")
	_expect(_inspect({"path": path, "query": "MOVE"})["report"]["matches"].is_empty(), "declaration lookup must be case-sensitive")
	_expect(not JSON.stringify(result).contains("sha256") and result["report"]["source"] == "saved_gdscript_lexical_scan", "navigation must have saved provenance and no patch-base hashes")
	_expect(_json_equal(JSON.parse_string(result["content"]), result["report"]), "readable report and structured result must agree")


func _test_references() -> void:
	var path := _root.path_join("references.gd")
	_write(path, "extends Node\nsignal health_changed\nvar health := 0\nfunc update(health: int):\n\tself.health = health + health\n\thealth_changed.emit() # health\n\tvar health_extra := \"health\"\n\tvar quoted := 'escaped \\\' health'\n\tvar multiline := \"\"\"health\nhealth\n\"\"\"\n\tprint(&\"health\", ^\"health\")\n\tvar health_local := health\n\tobj.health = 2\n\tHealth = 0\n")
	var report: Dictionary = _inspect({"path": path, "symbol": "health"}, true)["report"]
	var matches: Array = report["matches"]
	_expect(matches.size() == 6, "whole identifiers must include parameter/shadowing candidates but exclude declarations, substrings, strings, comments and other case: " + str(matches))
	_expect(matches.all(func(match): return match["role"] == "reference_candidate"), "references must never claim semantic resolution")
	_expect(matches[1]["line"] == 5 and matches[1]["column"] == 7 and matches[2]["column"] == 16 and matches[3]["column"] == 25, "multiple same-line references must retain distinct source columns")
	var inclusive: Array = _inspect({"path": path, "symbol": "health", "include_declarations": true}, true)["report"]["matches"]
	_expect(inclusive.size() == 7 and inclusive[0]["role"] == "declaration", "explicit declaration inclusion must label rather than resolve matches")
	_expect(_inspect({"path": path, "symbol": "health_changed"}, true)["report"]["matches"].size() == 1, "signal use must be discoverable without its declaration")
	var unicode_path := _root.path_join("unicode.gd")
	_write(unicode_path, "var énergie := 0\nfunc use():\n\ténergie += 1\n")
	var unicode_matches: Array = _inspect({"path": unicode_path, "symbol": "énergie"}, true)["report"]["matches"]
	_expect(unicode_matches.size() == 1 and unicode_matches[0]["column"] == 2, "UTF-8 identifiers must use character columns rather than byte offsets")


func _test_fresh_source() -> void:
	var directory := _root.path_join("fresh")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var path := directory.path_join("one.gd")
	_write(path, "func previous():\n\tpass\n")
	_expect(_names(_inspect({"path": directory})["report"]["matches"]) == ["previous"], "directory inventory must scan saved scripts")
	_write(path, "func current():\n\tpass\n")
	_expect(_names(_inspect({"path": directory})["report"]["matches"]) == ["current"], "a subsequent scan must see changed disk source without stale indexing")
	_write(directory.path_join("two.gd"), "signal newer\n")
	_expect(_names(_inspect({"path": directory})["report"]["matches"]) == ["current", "newer"], "new files must appear in deterministic path order")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_expect(_names(_inspect({"path": directory})["report"]["matches"]) == ["newer"], "deleted files must not remain in the index")
	var dirty_path := directory.path_join("two.gd")
	_expect(not Navigation.inspect({"path": dirty_path}, false, Tools._validate_path, [dirty_path]).get("success", true), "an explicit dirty file must reject saved lookup")
	var dirty := Navigation.inspect({"path": directory}, false, Tools._validate_path, [dirty_path])
	_expect(dirty["report"]["matches"].is_empty() and dirty["report"]["truncation"]["reasons"].has("unsaved_script_omitted"), "directory scans must disclose dirty omissions rather than report stale declarations")


func _test_boundaries() -> void:
	for arguments in [{"query": 1}, {"query": "a".repeat(129)}, {"path": 1}, {"kind": "local"}, {"max_results": 0}, {"max_results": 101}, {"max_results": 1.5}, {"source": "func unauthorized(): pass"}]:
		_expect(not _inspect(arguments).get("success", true), "invalid symbol argument must fail: " + str(arguments))
	for arguments in [{}, {"symbol": ""}, {"symbol": "a.b"}, {"symbol": 2}, {"symbol": "valid", "include_declarations": 1}, {"symbol": "valid", "source": "untrusted"}]:
		_expect(not _inspect(arguments, true).get("success", true), "invalid reference argument must fail: " + str(arguments))
	for path in ["user://any.gd", "/tmp/any.gd", "res://../any.gd", "res://addons/orca", "res://addons/orca/scripts/tools.gd", "res://.orca-update", "res://.orca-update/a.gd", _root + "/../project.godot", "res://project.godot", _root.path_join("missing.gd")]:
		_expect(not _inspect({"path": path}).get("success", true), "unsafe/noncanonical/unsupported path must fail: " + path)
	var links := _root.path_join("links")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(links))
	var directory := DirAccess.open(links)
	var file_link := links.path_join("linked.gd")
	var error := directory.create_link(ProjectSettings.globalize_path(_root.path_join("declarations.gd")), "linked.gd")
	if error == OK:
		_expect(not _inspect({"path": file_link}).get("success", true), "explicit script symlinks must be blocked")
		var report: Dictionary = _inspect({"path": links})["report"]
		_expect(report["matches"].is_empty() and report["truncation"]["reasons"].has("symbolic_link_omitted"), "enumerated symlinks must be omitted and disclosed")
		directory.create_link(ProjectSettings.globalize_path(_root), "directory")
		_expect(not _inspect({"path": links.path_join("directory/declarations.gd")}).get("success", true), "symlink ancestors must also fail")
	else:
		_expect(OS.get_name() == "Windows", "Unix symlink fixture must be supported")
	_write(_root.path_join("invalid.gd"), "abc")
	var binary := FileAccess.open(_root.path_join("invalid.gd"), FileAccess.WRITE)
	binary.store_buffer(PackedByteArray([97, 0, 98]))
	binary.close()
	_expect(_inspect({"path": _root.path_join("invalid.gd")})["report"]["truncation"]["reasons"].has("invalid_source"), "binary/NUL source must be rejected without resource loading")


func _test_limits() -> void:
	var path := _root.path_join("limits.gd")
	_write(path, "signal first\nsignal second\n")
	var limited: Dictionary = _inspect({"path": path, "max_results": 1})["report"]
	_expect(limited["matches"].size() == 1 and limited["truncation"]["reasons"].has("result_limit"), "excess matches must disclose result truncation")
	_write(path, "signal only\n")
	_expect(not _inspect({"path": path, "max_results": 1})["report"]["truncation"]["truncated"], "an exact result count must not falsely claim additional matches")
	_write(path, "#".repeat(Navigation.MAX_SOURCE_BYTES + 1))
	_expect(_inspect({"path": path})["report"]["truncation"]["reasons"].has("source_file_limit"), "oversized files must be skipped before reading")
	_write(path, "#".repeat(Navigation.MAX_LINE_CHARS + 1))
	_expect(_inspect({"path": path})["report"]["truncation"]["reasons"].has("source_line_limit"), "long lines must stop lexical interpretation with explicit limits")
	_write(path, "+".repeat(Navigation.MAX_LINE_TOKENS + 1))
	_expect(_inspect({"path": path})["report"]["truncation"]["reasons"].has("token_limit"), "adversarial punctuation must bound tokens")
	_write(path, "var unfinished = \"\"\"open\nfunc hidden():\n")
	_expect(_inspect({"path": path})["report"]["truncation"]["reasons"].has("incomplete_lexical_source"), "unterminated multiline source must be disclosed")
	var bulk := _root.path_join("bulk")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(bulk))
	for index in range(Navigation.MAX_FILES + 1):
		_write(bulk.path_join("file_%04d.gd" % index), "extends Node\n")
	var bulk_report: Dictionary = _inspect({"path": bulk})["report"]
	_expect(bulk_report["truncation"]["truncated"] and bulk_report["scan"]["files_scanned"] <= Navigation.MAX_FILES, "large project scans must stop at file/time bounds")
	var wide := _root.path_join("wide")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(wide))
	for index in range(Navigation.MAX_DIRECTORIES + 1):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(wide.path_join("dir_%04d" % index)))
	var wide_report: Dictionary = _inspect({"path": wide})["report"]
	_expect(wide_report["truncation"]["reasons"].has("directory_limit") and wide_report["scan"]["directories_scanned"] <= Navigation.MAX_DIRECTORIES, "both directory enumeration and queue size must be bounded")
	var long_directory := _root
	for index in range(4):
		long_directory = long_directory.path_join("d".repeat(80))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(long_directory))
	path = long_directory.path_join("output.gd")
	var content := ""
	for index in range(5):
		content += "\t".repeat(index) + "class " + "C".repeat(120) + ":\n"
	for index in range(100):
		content += "\t".repeat(5) + "var " + "member".repeat(20) + str(index) + " = 1\n"
	_write(path, content)
	var output := _inspect({"path": path, "kind": "member"})
	_expect(output["content"].to_utf8_buffer().size() <= Navigation.MAX_OUTPUT_BYTES and output["report"]["truncation"]["reasons"].has("output_limit"), "large excerpts/ownership/path combinations must fit the JSON output cap")
	_expect(_json_equal(JSON.parse_string(output["content"]), output["report"]), "output trimming must preserve report parity and returned count")
	var long_path := long_directory.path_join("hidden".repeat(40) + ".gd")
	_write(long_path, "signal forbidden_path\n")
	var path_report: Dictionary = _inspect({"path": long_directory, "query": "forbidden_path"})["report"]
	_expect(path_report["matches"].is_empty() and path_report["truncation"]["reasons"].has("path_limit"), "enumeration must omit paths exceeding the navigable path bound")
	# Expired absolute budget exercises the same production loop before file reads.
	var expired := {"stopped": false, "deadline": Time.get_ticks_msec() - 1, "reasons": []}
	Navigation._scan_file(path, expired)
	_expect(expired["stopped"] and expired["reasons"] == ["time_limit"], "elapsed scan budgets must prevent subsequent file work")


func _inspect(arguments: Dictionary, references: bool = false) -> Dictionary:
	return Navigation.inspect(arguments, references, Tools._validate_path)


func _names(matches: Array) -> Array:
	return matches.map(func(match): return match.get("name"))


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture should open: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.include_hidden = true
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		var child := path.path_join(entry)
		if directory.is_link(entry) or not directory.current_is_dir():
			DirAccess.remove_absolute(child)
		else:
			_remove_tree(child)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _json_equal(left, right) -> bool:
	if typeof(left) in [TYPE_INT, TYPE_FLOAT] and typeof(right) in [TYPE_INT, TYPE_FLOAT]:
		return float(left) == float(right)
	if typeof(left) != typeof(right):
		return false
	if typeof(left) == TYPE_DICTIONARY:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _json_equal(left[key], right[key]):
				return false
		return true
	if typeof(left) == TYPE_ARRAY:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _json_equal(left[index], right[index]):
				return false
		return true
	return left == right
