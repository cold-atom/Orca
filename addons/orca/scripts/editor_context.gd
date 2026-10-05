@tool
extends RefCounted

const MAX_SELECTION_CHARS := 12000
const CONTEXT_RADIUS := 30


static func capture() -> Dictionary:
	if not Engine.is_editor_hint():
		return {}

	var context := {
		"active_scene": {},
		"selected_nodes": [],
		"active_script": {},
		"selected_files": Array(EditorInterface.get_selected_paths()),
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"unsaved_scenes": Array(EditorInterface.get_unsaved_scenes())
	}
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		context["active_scene"] = {
			"name": str(scene_root.name),
			"path": scene_root.scene_file_path,
			"root_type": scene_root.get_class()
		}
		var selected_nodes: Array = []
		for node in EditorInterface.get_selection().get_selected_nodes().slice(0, 20):
			var script := node.get_script() as Script
			selected_nodes.append({
				"name": str(node.name),
				"type": node.get_class(),
				"path": str(scene_root.get_path_to(node)),
				"script": script.resource_path if script != null else "",
				"groups": Array(node.get_groups()).filter(func(group): return not str(group).begins_with("_"))
			})
		context["selected_nodes"] = selected_nodes

	var script_editor := EditorInterface.get_script_editor()
	context["unsaved_scripts"] = Array(script_editor.get_unsaved_files())
	var script := script_editor.get_current_script()
	if script != null:
		var script_context := {"path": script.resource_path}
		var current_editor := script_editor.get_current_editor()
		var code_edit: CodeEdit = null
		if current_editor != null:
			code_edit = current_editor.get_base_editor() as CodeEdit
		if code_edit != null:
			var caret_line := code_edit.get_caret_line(0)
			var all_lines := code_edit.text.split("\n")
			var first_line := maxi(0, caret_line - CONTEXT_RADIUS)
			var last_line := mini(all_lines.size() - 1, caret_line + CONTEXT_RADIUS)
			var excerpt := PackedStringArray()
			for line_index in range(first_line, last_line + 1):
				excerpt.append("%d | %s" % [line_index + 1, all_lines[line_index]])
			script_context.merge({
				"caret_line": caret_line + 1,
				"caret_column": code_edit.get_caret_column(0) + 1,
				"excerpt_start_line": first_line + 1,
				"excerpt": "\n".join(excerpt),
				"selected_text": code_edit.get_selected_text(0).left(MAX_SELECTION_CHARS) if code_edit.has_selection(0) else ""
			})
		context["active_script"] = script_context

	return context


static func format_for_model(context: Dictionary) -> String:
	if context.is_empty():
		return "No Godot editor context is currently available."
	return JSON.stringify(context, "  ")


static func has_unsaved_file(filepath: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	return (
		filepath in EditorInterface.get_script_editor().get_unsaved_files()
		or filepath in EditorInterface.get_unsaved_scenes()
	)


static func is_scene_open(filepath: String) -> bool:
	return Engine.is_editor_hint() and filepath in EditorInterface.get_open_scenes()


static func get_unsaved_open_script(filepath: String) -> Dictionary:
	if not Engine.is_editor_hint() or filepath.is_empty():
		return {}
	var script_editor := EditorInterface.get_script_editor()
	if filepath not in script_editor.get_unsaved_files():
		return {}
	var current_script := script_editor.get_current_script()
	if current_script == null or current_script.resource_path != filepath:
		return {}
	var current_editor := script_editor.get_current_editor()
	var code_edit: CodeEdit = current_editor.get_base_editor() as CodeEdit if current_editor != null else null
	if code_edit != null:
		return {"filepath": filepath, "source": code_edit.text}
	return {}


static func open_file(filepath: String, line: int = 1, column: int = 1) -> bool:
	if not Engine.is_editor_hint() or not filepath.begins_with("res://"):
		return false
	if not FileAccess.file_exists(filepath):
		return false
	if filepath.get_extension().to_lower() == "gd":
		var script := ResourceLoader.load(filepath, "Script") as Script
		if script == null:
			return false
		EditorInterface.edit_script(script, maxi(1, line), maxi(1, column), true)
		return true
	if filepath.get_extension().to_lower() == "tscn":
		EditorInterface.open_scene_from_path(filepath)
		return true
	var resource := ResourceLoader.load(filepath)
	if resource != null:
		EditorInterface.edit_resource(resource)
		return true
	EditorInterface.select_file(filepath)
	return true
