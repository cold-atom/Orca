extends SceneTree

const ProjectSkills = preload("res://addons/orca/scripts/project_skills.gd")

var _failures := PackedStringArray()
var _fixture_root := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_root = OS.get_temp_dir().path_join("orca_project_skills_test_%d" % Time.get_ticks_usec())
	_expect(DirAccess.make_dir_recursive_absolute(_fixture_root.path_join("skills")) == OK, "skills fixture root should be created")
	_test_discovery_and_exact_load()
	_test_invalid_and_bounded_inputs()
	_test_discovery_bounds()
	_test_symlink_rejection()
	_remove_tree(_fixture_root)
	_finish()


func _test_discovery_and_exact_load() -> void:
	_write_skill("z-last", "Zeta", "Later skill", "Do Zeta work.\n")
	_write_skill("a_first", "Alpha", "First skill", "Read references/other.md as plain text.\nNever execute tools automatically.\n")
	_write_skill("nested", "Nested", "Immediate skill", "Body.\n")
	_expect(DirAccess.make_dir_recursive_absolute(_fixture_root.path_join("skills/nested/child")) == OK, "nested fixture should be created")
	_write(_fixture_root.path_join("skills/nested/child/SKILL.md"), "---\nname: Hidden\ndescription: Must not be found\n---\nHidden body.\n")
	var discovery := ProjectSkills._discover_from_root(_fixture_root)
	_expect(discovery.get("success", false), "skill discovery should succeed")
	var skills: Array = discovery.get("skills", [])
	_expect(skills.size() == 3, "only immediate skill directories should be discovered")
	_expect(skills[0].get("name") == "Alpha" and skills[1].get("name") == "Nested" and skills[2].get("name") == "Zeta", "skill discovery should use deterministic slug ordering")
	var loaded := ProjectSkills._load_from_root("Alpha", _fixture_root)
	_expect(loaded.get("success", false), "an exact discovered skill name should load")
	_expect(str(loaded.get("body", "")).begins_with("Read references/other.md"), "on-demand loading should return only the body")
	_expect(loaded.get("body_line_count") == 2, "loaded body metadata should report complete lines")
	_expect(str(loaded.get("wrapped_body", "")).contains("do not recursively load") and str(loaded.get("wrapped_body", "")).contains("do not execute"), "skill bodies should be wrapped as non-recursive, non-executable guidance")
	_expect(not ProjectSkills._load_from_root("alpha", _fixture_root).get("success", true), "skill names should match exactly")


func _test_invalid_and_bounded_inputs() -> void:
	_write_skill("Bad-Slug", "Invalid", "Invalid slug", "Body.\n")
	_write(_fixture_root.path_join("skills/a_first/SKILL.md"), "---\nname: Alpha\ndescription: First skill\n---\n" + "line\n".repeat(ProjectSkills.MAX_BODY_LINES + 1))
	var oversized_lines := ProjectSkills._load_from_root("Alpha", _fixture_root)
	_expect(not oversized_lines.get("success", true) and not oversized_lines.has("body"), "over-line skill bodies must fail without partial content")
	_write(_fixture_root.path_join("skills/a_first/SKILL.md"), "---\nname: Alpha\ndescription: First skill\n---\n" + "x".repeat(ProjectSkills.MAX_BODY_BYTES + 1))
	var oversized_bytes := ProjectSkills._load_from_root("Alpha", _fixture_root)
	_expect(not oversized_bytes.get("success", true) and not oversized_bytes.has("body"), "oversized skill bodies must fail without partial content")
	_write(_fixture_root.path_join("skills/a_first/SKILL.md"), "---\nname: Alpha\ndescription: First skill\n---\nBody.\n")
	var discovery := ProjectSkills._discover_from_root(_fixture_root)
	var slugs := PackedStringArray()
	for skill in discovery.get("skills", []):
		slugs.append(str(skill.get("slug", "")))
	_expect(not slugs.has("Bad-Slug"), "directories outside the strict lowercase slug grammar should be ignored")
	_expect(ProjectSkills._is_valid_slug("a") and ProjectSkills._is_valid_slug("a-0_name") and not ProjectSkills._is_valid_slug("_bad") and not ProjectSkills._is_valid_slug("A-bad") and not ProjectSkills._is_valid_slug("a".repeat(65)), "slug validation should implement the exact length and character grammar")
	_write_skill("long-name", "n".repeat(ProjectSkills.MAX_NAME_CHARS + 1), "Description", "Body.\n")
	_write_skill("long-description", "Valid name", "d".repeat(ProjectSkills.MAX_DESCRIPTION_CHARS + 1), "Body.\n")
	var bounded_metadata := ProjectSkills._discover_from_root(_fixture_root)
	var bounded_slugs := PackedStringArray()
	for skill in bounded_metadata.get("skills", []):
		bounded_slugs.append(str(skill.get("slug", "")))
	_expect(not bounded_slugs.has("long-name") and not bounded_slugs.has("long-description"), "skill names and descriptions beyond 64 and 240 characters should be rejected")


func _test_discovery_bounds() -> void:
	var bounded_root := _fixture_root.path_join("bounded")
	_expect(DirAccess.make_dir_recursive_absolute(bounded_root.path_join("skills")) == OK, "bounded discovery fixture should be created")
	for index in range(ProjectSkills.MAX_DIRECTORIES + 2):
		var slug := "skill-%02d" % index
		var directory := bounded_root.path_join("skills").path_join(slug)
		DirAccess.make_dir_recursive_absolute(directory)
		_write(directory.path_join("SKILL.md"), "---\nname: Skill %02d\ndescription: Bounded fixture\n---\nBody.\n" % index)
	var discovery := ProjectSkills._discover_from_root(bounded_root)
	_expect(discovery.get("scanned_directory_count") == ProjectSkills.MAX_DIRECTORIES, "discovery should inspect at most 64 immediate directories")
	_expect(discovery.get("skills", []).size() == ProjectSkills.MAX_SKILLS, "discovery should return at most 32 skills")
	_expect(discovery.get("truncated", false), "directory or skill bounds should be reported")
	_expect(discovery.get("skills", [])[0].get("name") == "Skill 00" and discovery.get("skills", [])[-1].get("name") == "Skill 31", "bounded discovery should select skills deterministically")


func _test_symlink_rejection() -> void:
	if OS.get_name() not in ["Linux", "FreeBSD", "NetBSD", "OpenBSD", "macOS"]:
		return
	var external := _fixture_root.path_join("external")
	_expect(DirAccess.make_dir_recursive_absolute(external) == OK, "symlink target should be created")
	_write(external.path_join("SKILL.md"), "---\nname: Linked\ndescription: Linked skill\n---\nBody.\n")
	var link := _fixture_root.path_join("skills/linked")
	var exit_code := OS.execute("ln", PackedStringArray(["-s", external, link]))
	_expect(exit_code == 0, "skill symlink fixture should be created")
	if exit_code == 0:
		var discovery := ProjectSkills._discover_from_root(_fixture_root)
		var names := PackedStringArray()
		for skill in discovery.get("skills", []):
			names.append(str(skill.get("name", "")))
		_expect(not names.has("Linked"), "symlinked skill directories should not be discovered")
		_expect(not ProjectSkills._load_from_root("Linked", _fixture_root).get("success", true), "symlinked skills should not load on demand")


func _write_skill(slug: String, name: String, description: String, body: String) -> void:
	var directory := _fixture_root.path_join("skills").path_join(slug)
	_expect(DirAccess.make_dir_recursive_absolute(directory) == OK, "skill fixture directory should be created: " + slug)
	_write(directory.path_join("SKILL.md"), "---\nname: %s\ndescription: %s\n---\n%s" % [name, description, body])


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
		print("project_skills_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("project_skills_test: ", failure)
	quit(1)
