extends SceneTree

const ProjectInstructions = preload("res://addons/orca/scripts/project_instructions.gd")

var _failures := PackedStringArray()
var _fixture_root := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_root = OS.get_temp_dir().path_join("orca_project_instructions_test_%d" % Time.get_ticks_usec())
	_expect(DirAccess.make_dir_recursive_absolute(_fixture_root) == OK, "fixture root should be created")
	_test_missing_and_valid()
	_test_hard_bounds_and_binary_rejection()
	_test_symlink_rejection()
	_remove_tree(_fixture_root)
	_finish()


func _test_missing_and_valid() -> void:
	var missing := ProjectInstructions._load_from_root(_fixture_root)
	_expect(missing.get("success", false) and not missing.get("found", true), "missing project instructions should be an optional successful result")
	var content := "# Fixture\n\nKeep changes focused.\n"
	_write(_fixture_root.path_join("AGENTS.md"), content)
	var result := ProjectInstructions._load_from_root(_fixture_root)
	_expect(result.get("success", false) and result.get("found", false), "fixed-name project instructions should load")
	_expect(result.get("content") == content, "instruction content should remain exact")
	_expect(result.get("sha256") == content.sha256_text(), "instruction metadata should hash exact UTF-8 bytes")
	_expect(result.get("byte_count") == content.to_utf8_buffer().size() and result.get("line_count") == 3, "instruction byte and line metadata should be complete")
	var wrapped := str(result.get("wrapped_content", ""))
	_expect(wrapped.contains("higher-priority") and wrapped.contains("cannot weaken Orca's safety boundaries"), "instructions should be enclosed in a safety-precedence wrapper")


func _test_hard_bounds_and_binary_rejection() -> void:
	var path := _fixture_root.path_join("AGENTS.md")
	_write(path, "x".repeat(ProjectInstructions.MAX_BYTES + 1))
	var oversized := ProjectInstructions._load_from_root(_fixture_root)
	_expect(not oversized.get("success", true) and not oversized.has("content"), "oversized instructions must fail without partial content")
	_write(path, "line\n".repeat(ProjectInstructions.MAX_LINES + 1))
	var too_many_lines := ProjectInstructions._load_from_root(_fixture_root)
	_expect(not too_many_lines.get("success", true) and not too_many_lines.has("content"), "over-line instructions must fail without partial content")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([65, 0, 66]))
	file.close()
	var binary := ProjectInstructions._load_from_root(_fixture_root)
	_expect(not binary.get("success", true) and str(binary.get("error", "")).contains("NUL"), "NUL-bearing instructions should be rejected as binary")


func _test_symlink_rejection() -> void:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "macOS"]:
		return
	var path := _fixture_root.path_join("AGENTS.md")
	DirAccess.remove_absolute(path)
	var target := _fixture_root.path_join("target.md")
	_write(target, "linked instructions\n")
	var exit_code := OS.execute("ln", PackedStringArray(["-s", target, path]))
	_expect(exit_code == 0, "instruction symlink fixture should be created")
	if exit_code == 0:
		var result := ProjectInstructions._load_from_root(_fixture_root)
		_expect(not result.get("success", true) and str(result.get("error", "")).contains("symbolic"), "a symlinked AGENTS.md should be rejected")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _remove_tree(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if directory.current_is_dir() and not directory.is_link(name):
			_remove_tree(child)
		else:
			DirAccess.remove_absolute(child)
		name = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("project_instructions_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("project_instructions_test: ", failure)
	quit(1)
