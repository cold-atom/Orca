@tool
extends Node

const DiffUtils = preload("res://addons/orca/scripts/diff_utils.gd")
const PatchUtils = preload("res://addons/orca/scripts/patch_utils.gd")
const EditorContext = preload("res://addons/orca/scripts/editor_context.gd")
const DiagnosticsService = preload("res://addons/orca/scripts/diagnostics_service.gd")
const TaskUtils = preload("res://addons/orca/scripts/task_utils.gd")
const SceneInspector = preload("res://addons/orca/scripts/scene_inspector.gd")
const ProjectSettingsInspector = preload("res://addons/orca/scripts/project_settings_inspector.gd")
const InputMapProposal = preload("res://addons/orca/scripts/input_map_proposal.gd")
const MainSceneProposal = preload("res://addons/orca/scripts/main_scene_proposal.gd")
const ProjectSettingsProposal = preload("res://addons/orca/scripts/project_settings_proposal.gd")
const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const ProjectSkills = preload("res://addons/orca/scripts/project_skills.gd")
const GodotApiInspector = preload("res://addons/orca/scripts/godot_api_inspector.gd")
const GDScriptFunctionReader = preload("res://addons/orca/scripts/gdscript_function_reader.gd")
const DependencyInspector = preload("res://addons/orca/scripts/dependency_inspector.gd")

const MAX_READ_FILE_BYTES := 2 * 1024 * 1024
const MAX_READ_LINES := 400
const MAX_READ_OUTPUT_BYTES := 128 * 1024
const MAX_SEARCH_FILES := 500
const MAX_SEARCH_FILE_BYTES := 1024 * 1024
const MAX_SEARCH_RESULTS := 200
const SEARCH_TIMEOUT_MS := 2500
const MAX_SCENE_FILE_BYTES := 2 * 1024 * 1024
const MAX_WORK_MODE_REASON_CHARS := 240

enum SafeWriteOutcome {
	NOT_COMMITTED_FAILURE,
	COMMITTED_SUCCESS,
	COMMITTED_CLEANUP_WARNING,
	RECOVERY_FAILURE,
}

static var _replacement_test_faults := {}
static var _replacement_test_write_index := 0

static func get_tool_definitions(include_edit_tools: bool = true, include_work_mode_request: bool = false) -> Array:
	var definitions := [
		{
			"type": "function",
			"function": {
				"name": "list_directory",
				"description": "Lists all files and folders in a given directory path within the project.",
				"parameters": {
					"type": "object",
					"properties": {
						"path": {
							"type": "string",
							"description": "The directory path to list, e.g., 'res://' or 'res://scripts/'"
						}
					},
					"required": ["path"]
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "read_file",
				"description": "Reads and returns the contents of a specific file.",
				"parameters": {
					"type": "object",
					"properties": {
						"filepath": {
							"type": "string",
							"description": "The full path to the file, e.g., 'res://player.gd'"
						},
						"start_line": {
							"type": "integer",
							"description": "First one-based line to read. Defaults to 1."
						},
						"end_line": {
							"type": "integer",
							"description": "Last one-based line to read. Defaults to at most 400 lines after start_line."
						}
					},
					"required": ["filepath"]
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "search_files",
				"description": "Recursively searches text files in the Godot project and returns matching paths, line numbers, columns, and previews.",
				"parameters": {
					"type": "object",
					"properties": {
						"query": {"type": "string", "description": "Literal text to find."},
						"path": {"type": "string", "description": "Root directory to search. Defaults to res://."},
						"file_glob": {"type": "string", "description": "Filename filter such as *.gd or *.tscn. Defaults to *."},
						"case_sensitive": {"type": "boolean", "description": "Whether matching respects case. Defaults to false."},
						"max_results": {"type": "integer", "description": "Maximum matches to return, up to 200."}
					},
					"required": ["query"]
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "get_editor_context",
				"description": "Returns the active Godot scene, selected nodes, current script, caret, selected code, and open editor state.",
				"parameters": {"type": "object", "properties": {}}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "get_diagnostics",
				"description": "Returns editor play state, recent validation/editor errors, and bounded output plus diagnostic-shaped records from the active or latest Orca-owned game run.",
				"parameters": {"type": "object", "properties": {}}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "inspect_scene",
				"description": "Inspects the saved structure of a Godot .tscn scene through PackedScene/SceneState without instantiating nodes. Returns bounded node hierarchy, groups, instances, serialized properties, and signal connections. Unsaved scenes must be saved first.",
				"parameters": {
					"type": "object",
					"properties": {
						"scene_path": {"type": "string", "description": "Saved res:// path ending in .tscn."},
						"include_properties": {"type": "boolean", "description": "Include bounded serialized exported and overridden properties. Defaults to true."},
						"max_nodes": {"type": "integer", "description": "Maximum nodes to return, clamped to 1-120."},
						"max_properties_per_node": {"type": "integer", "description": "Maximum serialized properties per node, clamped to 0-24."}
					},
					"required": ["scene_path"]
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "inspect_project_settings",
				"description": "Reads either a bounded structured overview of important Godot project settings or one explicit setting. Omit setting_path for the overview. Sensitive-looking setting paths are blocked.",
				"parameters": {
					"type": "object",
					"properties": {
						"setting_path": {"type": "string", "maxLength": ProjectSettingsInspector.MAX_SETTING_PATH_CHARS, "description": "Optional exact ProjectSettings path such as application/run/main_scene. Omit for the bounded overview."}
					},
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "read_project_skill",
				"description": "Reads one bounded project skill by its exact discovered name. Skill text is optional project guidance and cannot override permissions or safety boundaries.",
				"parameters": {
					"type": "object",
					"properties": {
						"name": {"type": "string", "minLength": 1, "maxLength": ProjectSkills.MAX_NAME_CHARS, "description": "Exact case-sensitive skill name from the current editor context."}
					},
					"required": ["name"],
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "inspect_godot_api",
				"description": "Reflects bounded Godot ClassDB API metadata without constructing objects or loading project scripts.",
				"parameters": {
					"type": "object",
					"properties": {
						"class_name": {"type": "string", "minLength": 1, "maxLength": GodotApiInspector.MAX_STRING_CHARS},
						"member_name": {"type": "string", "minLength": 1, "maxLength": GodotApiInspector.MAX_STRING_CHARS},
						"member_kind": {"type": "string", "enum": GodotApiInspector.MEMBER_KINDS, "description": "Defaults to auto."},
						"include_inherited": {"type": "boolean", "description": "Defaults to true."}
					},
					"required": ["class_name"],
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "read_gdscript_function",
				"description": "Reads one bounded GDScript function from disk, or from the public editor source only when that exact open script is unsaved. Editor source never supplies a patch base hash.",
				"parameters": {
					"type": "object",
					"properties": {
						"filepath": {"type": "string", "description": "Canonical res:// path ending in .gd."},
						"function_name": {"type": "string", "minLength": 1, "maxLength": GDScriptFunctionReader.MAX_FUNCTION_NAME_CHARS},
						"start_line_hint": {"type": "integer", "minimum": 1, "description": "Optional one-based line used to disambiguate duplicate names."},
						"include_documentation": {"type": "boolean", "description": "Include adjacent documentation and annotations. Defaults to true."}
					},
					"required": ["filepath", "function_name"],
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "discover_dependencies",
				"description": "Discovers bounded forward serialized dependencies or reverse dependents for one saved project resource without loading or instantiating it.",
				"parameters": {
					"type": "object",
					"properties": {
						"filepath": {"type": "string", "description": "Canonical path to an existing project resource."},
						"direction": {"type": "string", "enum": DependencyInspector.DIRECTIONS},
						"max_depth": {"type": "integer", "minimum": 1, "maximum": DependencyInspector.MAX_DEPTH, "description": "Optional traversal depth. Defaults to 1."},
						"max_results": {"type": "integer", "minimum": 1, "maximum": DependencyInspector.MAX_RESULTS, "description": "Optional returned-node limit. Defaults to 100."}
					},
					"required": ["filepath", "direction"],
					"additionalProperties": false
				}
			}
		},
		{
			"type": "function",
			"function": {
				"name": "update_tasks",
				"description": "Replaces Orca's session task checklist. Use for genuinely multi-step work, provide the complete desired list each time, and keep at most one task in progress. This changes session metadata only and never project files.",
				"parameters": {
					"type": "object",
					"properties": {
						"tasks": {
							"type": "array",
							"maxItems": TaskUtils.MAX_TASKS,
							"items": {
								"type": "object",
								"properties": {
									"content": {"type": "string", "maxLength": TaskUtils.MAX_CONTENT_CHARS},
									"status": {"type": "string", "enum": TaskUtils.ALLOWED_STATUSES}
								},
								"required": ["content", "status"],
								"additionalProperties": false
							}
						}
					},
					"required": ["tasks"],
					"additionalProperties": false
				}
			}
		}
	]
	definitions.append({
		"type": "function",
		"function": {
			"name": "observe_game_run",
			"description": "Reads one immediate bounded snapshot for the exact active or latest Orca run. This never waits and does not control the process.",
			"parameters": {"type": "object", "properties": {"run_id": {"type": "integer", "minimum": 1}, "after_sequence": {"type": "integer", "minimum": 0}}, "required": ["run_id"], "additionalProperties": false}
		}
	})
	definitions.append({
		"type": "function",
		"function": {
			"name": "verify_game_run",
			"description": "Evaluates only the immutable verification criteria declared before an exact Orca run. Returns passed, failed, pending, inconclusive, or unverified.",
			"parameters": {"type": "object", "properties": {"run_id": {"type": "integer", "minimum": 1}}, "required": ["run_id"], "additionalProperties": false}
		}
	})
	if include_work_mode_request:
		definitions.append({
			"type": "function",
			"function": {
				"name": "request_work_mode",
				"description": "Asks the user for permission to switch this active Plan turn to Work mode. Use only when the user asked Orca to implement, modify, run, or otherwise perform work that Plan mode cannot do. Do not use for analysis-only or planning requests. Approval changes mode but does not approve any file mutation.",
				"parameters": {
					"type": "object",
					"properties": {
						"reason": {"type": "string", "minLength": 1, "maxLength": MAX_WORK_MODE_REASON_CHARS, "description": "A concise user-facing explanation of why Work mode is required."}
					},
					"required": ["reason"],
					"additionalProperties": false
				}
			}
		})
	if include_edit_tools:
		for operation in [
			["run_current_scene", "Starts the currently edited saved scene in one bounded nonblocking Orca-owned Godot process. All open scripts/scenes must be saved. Optional verification criteria are fixed before launch."],
			["run_main_scene", "Starts the configured saved main scene in one bounded nonblocking Orca-owned Godot process. All open scripts/scenes must be saved. Optional verification criteria are fixed before launch."]
		]:
			definitions.append({
				"type": "function",
				"function": {
					"name": operation[0],
					"description": operation[1],
					"parameters": {"type": "object", "properties": {"verification": _verification_schema()}, "additionalProperties": false}
				}
			})
		definitions.append({"type": "function", "function": {"name": "stop_game", "description": "Stops only the currently running direct game process started and still owned by Orca. It never accepts a PID or stops an editor-started process.", "parameters": {"type": "object", "properties": {}, "additionalProperties": false}}})
		definitions.append({
			"type": "function",
			"function": {
				"name": "propose_scene_changes",
				"description": "Proposes one structured Godot scene operation for explicit review: create, add, set a typed property, rename, remove, reparent, attach/detach a dependency-free GDScript, instantiate a dependency-free child scene, or connect/disconnect a bindless signal. Script operations first require explicit trust to load the reviewed script path after an immediate hash recheck while constructing the final candidate, followed by normal Apply approval.",
				"parameters": {
					"type": "object",
					"properties": {
						"scene_path": {"type": "string", "description": "Canonical res:// path ending in .tscn. A create_scene parent directory must already exist."},
						"base_hash": {"type": "string", "description": "Empty for create_scene, or the exact SHA-256 returned by read_file for every existing-scene operation."},
						"operations": {
							"type": "array",
							"minItems": 1,
							"maxItems": 1,
							"items": {
								"type": "object",
								"properties": {
									"operation": {"type": "string", "enum": ["create_scene", "add_node", "set_property", "rename_node", "remove_node", "reparent_node", "attach_script", "detach_script", "instantiate_child_scene", "connect_signal", "disconnect_signal"]},
									"root_type": {"type": "string", "enum": SceneProposal.ALLOWED_ROOT_TYPES},
									"root_name": {"type": "string", "minLength": 1, "maxLength": SceneProposal.MAX_ROOT_NAME_CHARS},
									"parent_path": {"type": "string", "description": "Saved SceneState path such as '.' or './Player'."},
									"node_type": {"type": "string", "enum": SceneProposal.ALLOWED_ROOT_TYPES},
									"node_name": {"type": "string", "minLength": 1, "maxLength": SceneProposal.MAX_ROOT_NAME_CHARS},
									"node_path": {"type": "string"},
									"property_name": {"type": "string"},
									"value": {"type": "object"},
									"new_name": {"type": "string", "maxLength": SceneProposal.MAX_ROOT_NAME_CHARS},
									"new_parent_path": {"type": "string"},
									"script_path": {"type": "string", "description": "Canonical dependency-free res:// path ending in .gd."},
									"script_hash": {"type": "string", "description": "Exact SHA-256 returned by read_file for script_path."},
									"child_scene_path": {"type": "string"},
									"child_hash": {"type": "string"},
									"source_path": {"type": "string"},
									"signal_name": {"type": "string"},
									"target_path": {"type": "string"},
									"method_name": {"type": "string"},
									"deferred": {"type": "boolean"},
									"one_shot": {"type": "boolean"}
								},
								"required": ["operation"],
								"additionalProperties": false
							}
						}
					},
					"required": ["scene_path", "base_hash", "operations"],
					"additionalProperties": false
				}
			}
		})
		definitions.append({
			"type": "function",
			"function": {
				"name": "propose_project_settings_changes",
				"description": "Proposes an atomic reviewed batch of allowlisted low-risk display settings. Read project.godot first and provide its SHA-256.",
				"parameters": {
					"type": "object",
					"properties": {
						"base_hash": {"type": "string", "description": "SHA-256 returned by read_file for res://project.godot."},
						"changes": {
							"type": "array",
							"minItems": 1,
							"maxItems": ProjectSettingsProposal.MAX_CHANGES,
							"items": {
								"type": "object",
								"properties": {
									"setting_path": {"type": "string", "enum": ProjectSettingsProposal.SETTING_SPECS.keys()},
									"value": {}
								},
								"required": ["setting_path", "value"],
								"additionalProperties": false
							}
						}
					},
					"required": ["base_hash", "changes"],
					"additionalProperties": false
				}
			}
		})
		definitions.append({
			"type": "function",
			"function": {
				"name": "propose_main_scene_change",
				"description": "Proposes a saved .tscn scene as the project main scene for explicit structured review. Read project.godot first and provide its SHA-256.",
				"parameters": {
					"type": "object",
					"properties": {
						"base_hash": {"type": "string", "description": "SHA-256 returned by read_file for res://project.godot."},
						"scene_path": {"type": "string", "description": "Saved res:// path ending in .tscn."}
					},
					"required": ["base_hash", "scene_path"],
					"additionalProperties": false
				}
			}
		})
		definitions.append({
			"type": "function",
			"function": {
				"name": "propose_input_map_changes",
				"description": "Proposes bounded typed Input Map changes to project.godot for explicit user review. The call never writes immediately. Read project.godot first and provide its SHA-256.",
				"parameters": {
					"type": "object",
					"properties": {
						"base_hash": {"type": "string", "description": "SHA-256 returned by read_file for res://project.godot."},
						"changes": {
							"type": "array",
							"minItems": 1,
							"maxItems": InputMapProposal.MAX_CHANGES,
							"items": {
								"type": "object",
								"properties": {
									"operation": {"type": "string", "enum": ["upsert", "remove"]},
									"action": {"type": "string", "maxLength": InputMapProposal.MAX_ACTION_NAME_CHARS},
									"deadzone": {"type": "number", "minimum": 0, "maximum": 1},
									"events": {"type": "array", "maxItems": InputMapProposal.MAX_EVENTS_PER_ACTION, "items": {"type": "object"}}
								},
								"required": ["operation", "action"],
								"additionalProperties": false
							}
						}
					},
					"required": ["base_hash", "changes"],
					"additionalProperties": false
				}
			}
		})
		definitions.append({
			"type": "function",
			"function": {
				"name": "apply_patch",
				"description": "Proposes precise line-range edits to one file. The user reviews a generated diff before anything is written.",
				"parameters": {
					"type": "object",
					"properties": {
						"filepath": {"type": "string", "description": "The res:// file to patch."},
						"base_hash": {"type": "string", "description": "SHA-256 from read_file, or an empty string only when creating a new file."},
						"edits": {
							"type": "array",
							"description": "Non-overlapping one-based line replacements. Use end_line = start_line - 1 to insert before a line. replacement is exact text; Orca preserves the following line boundary when needed.",
							"items": {
								"type": "object",
								"properties": {
									"start_line": {"type": "integer"},
									"end_line": {"type": "integer"},
									"replacement": {"type": "string"}
								},
								"required": ["start_line", "end_line", "replacement"]
							}
						}
					},
					"required": ["filepath", "base_hash", "edits"]
				}
			}
		})
	return definitions

static func execute_tool(tool_name: String, arguments: Dictionary, game_process_service = null) -> Dictionary:
	match tool_name:
		"list_directory":
			var path = arguments.get("path", "res://")
			return _list_directory(path)
		"read_file":
			var filepath = arguments.get("filepath", "")
			return _read_file(filepath, int(arguments.get("start_line", 1)), int(arguments.get("end_line", 0)))
		"search_files":
			return _search_files(
				str(arguments.get("query", "")),
				str(arguments.get("path", "res://")),
				str(arguments.get("file_glob", "*")),
				bool(arguments.get("case_sensitive", false)),
				int(arguments.get("max_results", 100))
			)
		"get_editor_context":
			var context := EditorContext.capture()
			return _tool_success(EditorContext.format_for_model(context), context)
		"get_diagnostics":
			var game_snapshot: Dictionary = game_process_service.get_snapshot() if game_process_service != null and game_process_service.has_method("get_snapshot") else {}
			var report := DiagnosticsService.get_report(game_snapshot)
			var diagnostic_data := report.duplicate(true)
			var navigation := _first_diagnostic_location(report)
			if not navigation.is_empty():
				diagnostic_data.merge(navigation, true)
			return _tool_success(_format_diagnostics(report), diagnostic_data)
		"run_current_scene":
			if not _only_arguments(arguments, ["verification"]):
				return _tool_error("run_current_scene accepts only optional verification criteria.")
			if typeof(arguments.get("verification", {})) != TYPE_DICTIONARY:
				return _tool_error("verification must be an object.")
			if game_process_service == null or not game_process_service.has_method("start_current_scene"):
				return _tool_error("The Orca game process service is unavailable.")
			return game_process_service.start_current_scene(arguments.get("verification", {}))
		"run_main_scene":
			if not _only_arguments(arguments, ["verification"]):
				return _tool_error("run_main_scene accepts only optional verification criteria.")
			if typeof(arguments.get("verification", {})) != TYPE_DICTIONARY:
				return _tool_error("verification must be an object.")
			if game_process_service == null or not game_process_service.has_method("start_main_scene"):
				return _tool_error("The Orca game process service is unavailable.")
			return game_process_service.start_main_scene(arguments.get("verification", {}))
		"stop_game":
			if not arguments.is_empty():
				return _tool_error("stop_game does not accept arguments.")
			if game_process_service == null or not game_process_service.has_method("stop_game"):
				return _tool_error("The Orca game process service is unavailable.")
			return game_process_service.stop_game()
		"observe_game_run":
			if not _only_arguments(arguments, ["run_id", "after_sequence"]) or typeof(arguments.get("run_id")) != TYPE_INT or (arguments.has("after_sequence") and typeof(arguments["after_sequence"]) != TYPE_INT):
				return _tool_error("observe_game_run requires integer run_id and optional integer after_sequence.")
			if game_process_service == null or not game_process_service.has_method("observe_run"):
				return _tool_error("The Orca game process service is unavailable.")
			var observation: Dictionary = game_process_service.observe_run(int(arguments["run_id"]), int(arguments.get("after_sequence", -1)))
			if not observation.get("success", false):
				return _tool_error(str(observation.get("error", "Could not observe the game run.")))
			var snapshot: Dictionary = observation.get("snapshot", {})
			var data := snapshot.duplicate(true)
			data["changed_since"] = bool(observation.get("changed_since", true))
			data["recommended_next_action"] = _recommended_run_action(snapshot, bool(observation.get("changed_since", true)))
			data.erase("verification")
			return _tool_success(_format_game_observation(snapshot, bool(observation.get("changed_since", true))), data)
		"verify_game_run":
			if not _only_arguments(arguments, ["run_id"]) or typeof(arguments.get("run_id")) != TYPE_INT:
				return _tool_error("verify_game_run requires an integer run_id.")
			if game_process_service == null or not game_process_service.has_method("verify_run"):
				return _tool_error("The Orca game process service is unavailable.")
			var verification: Dictionary = game_process_service.verify_run(int(arguments["run_id"]))
			if not verification.get("success", false):
				return _tool_error(str(verification.get("error", "Could not verify the game run.")))
			var verdict: Dictionary = verification.get("verification", {})
			return _tool_success(_format_game_verification(verdict), verdict)
		"inspect_scene":
			if typeof(arguments.get("scene_path")) != TYPE_STRING:
				return _tool_error("scene_path must be a string.")
			if arguments.has("include_properties") and typeof(arguments["include_properties"]) != TYPE_BOOL:
				return _tool_error("include_properties must be a boolean.")
			if arguments.has("max_nodes") and typeof(arguments["max_nodes"]) != TYPE_INT:
				return _tool_error("max_nodes must be an integer.")
			if arguments.has("max_properties_per_node") and typeof(arguments["max_properties_per_node"]) != TYPE_INT:
				return _tool_error("max_properties_per_node must be an integer.")
			return _inspect_scene(
				arguments.get("scene_path", ""),
				bool(arguments.get("include_properties", true)),
				int(arguments.get("max_nodes", SceneInspector.MAX_NODES)),
				int(arguments.get("max_properties_per_node", SceneInspector.MAX_PROPERTIES_PER_NODE))
			)
		"inspect_project_settings":
			for argument_name in arguments:
				if str(argument_name) != "setting_path":
					return _tool_error("Unknown inspect_project_settings argument: " + str(argument_name))
			if arguments.has("setting_path") and typeof(arguments["setting_path"]) != TYPE_STRING:
				return _tool_error("setting_path must be a string.")
			if arguments.has("setting_path") and str(arguments["setting_path"]).is_empty():
				return _tool_error("Omit setting_path to request the overview; an explicit setting_path cannot be empty.")
			var inspection := ProjectSettingsInspector.inspect(str(arguments.get("setting_path", "")))
			if not inspection.get("success", false):
				return _tool_error(str(inspection.get("error", "Could not inspect project settings.")))
			return _tool_success(str(inspection.get("content", "{}")), {
				"open_path": "res://project.godot" if FileAccess.file_exists("res://project.godot") else "",
				"open_line": 1,
				"open_column": 1,
				"setting_path": str(arguments.get("setting_path", "")),
				"summary": not arguments.has("setting_path") or str(arguments.get("setting_path", "")).is_empty()
			})
		"read_project_skill":
			if not _only_arguments(arguments, ["name"]) or typeof(arguments.get("name")) != TYPE_STRING:
				return _tool_error("read_project_skill requires only a string name.")
			var skill := ProjectSkills.load_skill(arguments["name"])
			if not skill.get("success", false):
				return _tool_error(str(skill.get("error", "Could not read the project skill.")))
			return _tool_success(str(skill.get("wrapped_body", "")), {
				"name": str(skill.get("name", "")),
				"description": str(skill.get("description", "")),
				"open_path": str(skill.get("path", "")),
				"open_line": 1,
				"open_column": 1,
				"body_byte_count": int(skill.get("body_byte_count", 0)),
				"body_line_count": int(skill.get("body_line_count", 0))
			})
		"inspect_godot_api":
			var api_result := GodotApiInspector.inspect(arguments)
			if not api_result.get("success", false):
				return _tool_error(str(api_result.get("content", "Could not inspect the Godot API.")).trim_prefix("Error: "))
			var api_data: Dictionary = api_result.get("data", {}).duplicate(true)
			var members: Array = api_data.get("members", [])
			if arguments.has("member_name") and not members.is_empty():
				api_data["help_topic"] = str(members[0].get("help_topic", api_data.get("help_topic", ""))).left(GodotApiInspector.MAX_STRING_CHARS)
			else:
				api_data["help_topic"] = str(api_data.get("help_topic", "")).left(GodotApiInspector.MAX_STRING_CHARS)
			return _tool_success(str(api_result.get("content", "{}")), api_data)
		"read_gdscript_function":
			var requested_path := str(arguments.get("filepath", ""))
			var canonical_path := _canonical_project_path(requested_path) if requested_path.begins_with("res://") else requested_path
			var open_script := EditorContext.get_unsaved_open_script(canonical_path)
			if EditorContext.has_unsaved_file(canonical_path) and open_script.is_empty():
				return _tool_error("The requested script has unsaved editor changes but is not the active script. Select it in the Script editor and try again so Orca does not read stale disk source.")
			var function_result := GDScriptFunctionReader.read_function(arguments, open_script)
			if not function_result.get("success", false):
				var error_data := function_result.duplicate(true)
				error_data.erase("success")
				error_data.erase("error")
				return _tool_error(str(function_result.get("error", "Could not read the GDScript function.")), error_data)
			var function_data := function_result.duplicate(true)
			function_data.erase("success")
			function_data.erase("content")
			return _tool_success(str(function_result.get("content", "")), function_data)
		"discover_dependencies":
			var dependency_result := DependencyInspector.inspect(arguments)
			if not dependency_result.get("success", false):
				return _tool_error(str(dependency_result.get("error", "Could not discover dependencies.")))
			var dependency_data: Dictionary = dependency_result.get("report", {}).duplicate(true)
			dependency_data["open_path"] = str(dependency_data.get("filepath", ""))
			dependency_data["open_line"] = 1
			dependency_data["open_column"] = 1
			return _tool_success(str(dependency_result.get("content", "{}")), dependency_data)
		"update_tasks":
			var validation := TaskUtils.validate_tasks(arguments.get("tasks", null))
			if not validation.get("success", false):
				return _tool_error(str(validation.get("error", "Invalid task checklist.")))
			var tasks: Array = validation.get("tasks", [])
			return _tool_success("Task checklist replaced with %d item(s)." % tasks.size(), {"tasks": tasks})
		"apply_patch":
			return _tool_error("File patches must be reviewed before they are applied.")
		"propose_input_map_changes":
			return _tool_error("Input Map changes must be reviewed before they are applied.")
		"propose_main_scene_change":
			return _tool_error("Main scene changes must be reviewed before they are applied.")
		"propose_project_settings_changes":
			return _tool_error("ProjectSettings changes must be reviewed before they are applied.")
		"propose_scene_changes":
			return _tool_error("Scene changes must be reviewed before they are applied.")
		_:
			return _tool_error("Unknown tool function '" + tool_name + "'")


static func _inspect_scene(filepath: String, include_properties: bool, max_nodes: int, max_properties_per_node: int) -> Dictionary:
	var validation_error := _validate_path(filepath, false)
	if not validation_error.is_empty():
		return _tool_error(validation_error)
	var canonical_path := ProjectSettings.localize_path(ProjectSettings.globalize_path(filepath).simplify_path())
	if canonical_path.get_extension().to_lower() != "tscn":
		return _tool_error("inspect_scene accepts saved .tscn scenes only.")
	if not FileAccess.file_exists(canonical_path):
		return _tool_error("Scene does not exist at path: " + canonical_path)
	var file := FileAccess.open(canonical_path, FileAccess.READ)
	if file == null:
		return _tool_error("Could not open the scene for inspection.")
	var file_size := file.get_length()
	file.close()
	if file_size > MAX_SCENE_FILE_BYTES:
		return _tool_error("Scene exceeds the 2 MB inspection limit.")
	if EditorContext.has_unsaved_file(canonical_path):
		return _tool_error("The scene has unsaved editor changes. Save it before inspection so Orca does not report a stale disk snapshot.")
	var inspection := SceneInspector.inspect(canonical_path, include_properties, max_nodes, max_properties_per_node)
	if not inspection.get("success", false):
		return _tool_error(str(inspection.get("error", "Could not inspect the scene.")))
	var report: Dictionary = inspection.get("report", {})
	return _tool_success(str(inspection.get("content", "{}")), {
		"open_path": canonical_path,
		"open_line": 1,
		"open_column": 1,
		"scene_node_count": int(report.get("scene_node_count", 0)),
		"returned_node_count": int(report.get("returned_node_count", 0)),
		"truncated": bool(report.get("truncation", {}).get("truncated", false))
	})

static func _list_directory(path: String) -> Dictionary:
	var validation_error := _validate_path(path, false)
	if not validation_error.is_empty():
		return _tool_error(validation_error)
		
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var files = []
		var dirs = []
		var file_name = dir.get_next()
		while file_name != "":
			if file_name != "." and file_name != "..":
				if dir.current_is_dir():
					dirs.append(file_name + "/")
				else:
					files.append(file_name)
			file_name = dir.get_next()
		
		var result = "Contents of " + path + ":\n"
		if dirs.is_empty() and files.is_empty():
			result += "(empty directory)"
		else:
			for d in dirs:
				result += "- " + d + "\n"
			for f in files:
				result += "- " + f + "\n"
		return _tool_success(result)
	else:
		return _tool_error("An error occurred when trying to access the path.")

static func _read_file(filepath: String, start_line: int = 1, end_line: int = 0) -> Dictionary:
	var validation_error := _validate_path(filepath, false)
	if not validation_error.is_empty():
		return _tool_error(validation_error)
	if not FileAccess.file_exists(filepath):
		return _tool_error("File does not exist at path: " + filepath)
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		return _tool_error("Could not open file for reading.")
	if file.get_length() > MAX_READ_FILE_BYTES:
		file.close()
		return _tool_error("File exceeds the 2 MB read limit.")
	var sample := file.get_buffer(mini(file.get_length(), 4096))
	if 0 in sample:
		file.close()
		return _tool_error("Binary files cannot be read as text.")
	file.seek(0)
	var content := file.get_as_text()
	file.close()
	var lines := PackedStringArray() if content.is_empty() else content.split("\n")
	if content.ends_with("\n") and not lines.is_empty():
		lines.remove_at(lines.size() - 1)
	var total_lines := lines.size()
	start_line = maxi(1, start_line)
	if end_line > 0 and end_line < start_line:
		return _tool_error("end_line must be greater than or equal to start_line.")
	if total_lines > 0 and start_line > total_lines:
		return _tool_error("start_line %d is beyond the file's %d lines." % [start_line, total_lines])
	var requested_end := end_line if end_line > 0 else start_line + MAX_READ_LINES - 1
	var actual_end := mini(total_lines, mini(requested_end, start_line + MAX_READ_LINES - 1))
	var output := PackedStringArray()
	var output_bytes := 0
	for line_index in range(start_line - 1, actual_end):
		var rendered := "%d | %s" % [line_index + 1, lines[line_index]]
		output_bytes += rendered.to_utf8_buffer().size() + 1
		if output_bytes > MAX_READ_OUTPUT_BYTES:
			actual_end = line_index
			break
		output.append(rendered)
	if actual_end < start_line and total_lines > 0:
		return _tool_error("The requested line exceeds the 128 KB output limit.")
	var hash := content.sha256_text()
	var header := "%s lines %d-%d of %d | SHA-256: %s" % [filepath, start_line, actual_end, total_lines, hash]
	var result := header + "\n" + "\n".join(output)
	return _tool_success(result, {
		"filepath": filepath,
		"start_line": start_line,
		"end_line": actual_end,
		"total_lines": total_lines,
		"sha256": hash,
		"truncated": actual_end < total_lines,
		"open_path": filepath,
		"open_line": start_line
	})


static func _search_files(query: String, path: String, file_glob: String, case_sensitive: bool, max_results: int) -> Dictionary:
	if query.is_empty():
		return _tool_error("Search query cannot be empty.")
	var validation_error := _validate_path(path, false)
	if not validation_error.is_empty():
		return _tool_error(validation_error)
	max_results = clampi(max_results, 1, MAX_SEARCH_RESULTS)
	file_glob = "*" if file_glob.is_empty() else file_glob
	var directories := [path]
	var matches: Array[Dictionary] = []
	var files_scanned := 0
	var started_at := Time.get_ticks_msec()
	var truncated := false
	while not directories.is_empty():
		if files_scanned >= MAX_SEARCH_FILES or Time.get_ticks_msec() - started_at > SEARCH_TIMEOUT_MS:
			truncated = true
			break
		var current_directory: String = directories.pop_back()
		var dir := DirAccess.open(current_directory)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry := dir.get_next()
		while not entry.is_empty():
			if Time.get_ticks_msec() - started_at > SEARCH_TIMEOUT_MS:
				truncated = true
				break
			if entry == "." or entry == "..":
				entry = dir.get_next()
				continue
			var entry_path := current_directory.path_join(entry)
			if dir.current_is_dir():
				if entry != ".godot" and _validate_path(entry_path, false).is_empty():
					directories.append(entry_path)
			elif entry.match(file_glob):
				files_scanned += 1
				_search_text_file(entry_path, query, case_sensitive, matches, max_results, started_at + SEARCH_TIMEOUT_MS)
				if matches.size() >= max_results or files_scanned >= MAX_SEARCH_FILES:
					truncated = true
					break
			entry = dir.get_next()
		dir.list_dir_end()
		if matches.size() >= max_results:
			break
		if truncated:
			break
	var rendered := PackedStringArray()
	for match_data in matches:
		rendered.append("%s:%d:%d: %s" % [match_data["filepath"], match_data["line"], match_data["column"], match_data["preview"]])
	var summary := "Found %d match(es) in %d scanned file(s)." % [matches.size(), files_scanned]
	if truncated:
		summary += " Results were limited."
	if not rendered.is_empty():
		summary += "\n" + "\n".join(rendered)
	var data := {"matches": matches, "files_scanned": files_scanned, "truncated": truncated}
	if not matches.is_empty():
		data["open_path"] = matches[0]["filepath"]
		data["open_line"] = matches[0]["line"]
		data["open_column"] = matches[0]["column"]
	return _tool_success(summary, data)


static func _search_text_file(filepath: String, query: String, case_sensitive: bool, matches: Array[Dictionary], max_results: int, deadline: int) -> void:
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null or file.get_length() > MAX_SEARCH_FILE_BYTES:
		if file != null:
			file.close()
		return
	var sample := file.get_buffer(mini(file.get_length(), 4096))
	if 0 in sample:
		file.close()
		return
	file.seek(0)
	var line_number := 0
	while not file.eof_reached() and matches.size() < max_results and Time.get_ticks_msec() <= deadline:
		var line := file.get_line()
		line_number += 1
		var column := line.find(query) if case_sensitive else line.findn(query)
		if column != -1:
			matches.append({
				"filepath": filepath,
				"line": line_number,
				"column": column + 1,
				"preview": line.strip_edges().left(240)
			})
	file.close()

static func prepare_file_patch(change_id: String, filepath: String, base_hash: String, edits: Array) -> Dictionary:
	var validation_error := _validate_path(filepath, true)
	if not validation_error.is_empty():
		return {"success": false, "error": validation_error}
	filepath = _canonical_project_path(filepath)
	if EditorContext.has_unsaved_file(filepath):
		return {"success": false, "error": "The file has unsaved changes in Godot. Save it before asking Orca to patch it."}

	var existed := FileAccess.file_exists(filepath)
	var old_content := ""
	if existed:
		var file := FileAccess.open(filepath, FileAccess.READ)
		if file == null:
			return {"success": false, "error": "Could not open the existing file for review."}
		old_content = file.get_as_text()
		file.close()
	if existed and base_hash != old_content.sha256_text():
		return {"success": false, "error": "base_hash does not match the current file. Read the file again before patching it."}
	if not existed and not base_hash.is_empty():
		return {"success": false, "error": "A new file must use an empty base_hash."}
	var patch_result := PatchUtils.apply_line_edits(old_content, edits)
	if not patch_result.get("success", false):
		return patch_result
	var new_content: String = patch_result["content"]
	if new_content.length() > 2 * 1024 * 1024:
		return {"success": false, "error": "Proposed file content exceeds the 2 MB safety limit."}
	var validation := DiagnosticsService.validate_source(filepath, new_content)
	if not validation.get("valid", false):
		return {
			"success": false,
			"error": validation.get("message", "GDScript validation failed."),
			"diagnostics": validation.get("diagnostics", [])
		}

	var diff := DiffUtils.create_diff(old_content, new_content)
	return {
		"success": true,
		"id": change_id,
		"kind": "file_patch",
		"tool_name": "apply_patch",
		"filepath": filepath,
		"old_content": old_content,
		"new_content": new_content,
		"old_hash": old_content.sha256_text(),
		"new_hash": new_content.sha256_text(),
		"existed": existed,
		"edits": edits,
		"diff": diff,
		"validation": validation,
		"status": "pending"
	}


static func prepare_reviewed_change(tool_name: String, change_id: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"propose_scene_changes":
			for key in arguments:
				if str(key) not in ["scene_path", "base_hash", "operations"]:
					return {"success": false, "error": "Unknown propose_scene_changes argument: " + str(key)}
			if typeof(arguments.get("scene_path")) != TYPE_STRING or typeof(arguments.get("base_hash")) != TYPE_STRING or typeof(arguments.get("operations")) != TYPE_ARRAY:
				return {"success": false, "error": "propose_scene_changes requires string scene_path/base_hash and an operations array."}
			var scene_error := _validate_path(arguments["scene_path"], true)
			if not scene_error.is_empty():
				return {"success": false, "error": scene_error}
			for operation in arguments["operations"]:
				if typeof(operation) == TYPE_DICTIONARY and operation.has("child_scene_path"):
					if typeof(operation["child_scene_path"]) != TYPE_STRING:
						return {"success": false, "error": "child_scene_path must be a string."}
					var child_error := _validate_path(str(operation["child_scene_path"]), false)
					if not child_error.is_empty():
						return {"success": false, "error": child_error}
				if typeof(operation) == TYPE_DICTIONARY and operation.has("script_path"):
					if typeof(operation["script_path"]) != TYPE_STRING:
						return {"success": false, "error": "script_path must be a string."}
					var script_error := _validate_path(str(operation["script_path"]), false)
					if not script_error.is_empty():
						return {"success": false, "error": script_error}
			return SceneProposal.prepare(change_id, arguments["base_hash"], arguments["scene_path"], arguments["operations"])
		"apply_patch":
			if typeof(arguments.get("filepath")) != TYPE_STRING or typeof(arguments.get("base_hash")) != TYPE_STRING or typeof(arguments.get("edits")) != TYPE_ARRAY:
				return {"success": false, "error": "apply_patch requires string filepath/base_hash and an edits array."}
			return prepare_file_patch(change_id, arguments["filepath"], arguments["base_hash"], arguments["edits"])
		"propose_input_map_changes":
			for key in arguments:
				if str(key) not in ["base_hash", "changes"]:
					return {"success": false, "error": "Unknown propose_input_map_changes argument: " + str(key)}
			if typeof(arguments.get("base_hash")) != TYPE_STRING:
				return {"success": false, "error": "base_hash must be a string."}
			var path_error := _validate_path(InputMapProposal.PROJECT_PATH, true)
			if not path_error.is_empty():
				return {"success": false, "error": path_error}
			return InputMapProposal.prepare(change_id, arguments["base_hash"], arguments.get("changes"), true)
		"propose_main_scene_change":
			for key in arguments:
				if str(key) not in ["base_hash", "scene_path"]:
					return {"success": false, "error": "Unknown propose_main_scene_change argument: " + str(key)}
			if typeof(arguments.get("base_hash")) != TYPE_STRING or typeof(arguments.get("scene_path")) != TYPE_STRING:
				return {"success": false, "error": "base_hash and scene_path must be strings."}
			var project_error := _validate_path(MainSceneProposal.PROJECT_PATH, true)
			if not project_error.is_empty():
				return {"success": false, "error": project_error}
			var scene_error := _validate_path(arguments["scene_path"], false)
			if not scene_error.is_empty():
				return {"success": false, "error": scene_error}
			return MainSceneProposal.prepare(change_id, arguments["base_hash"], arguments["scene_path"], true)
		"propose_project_settings_changes":
			for key in arguments:
				if str(key) not in ["base_hash", "changes"]:
					return {"success": false, "error": "Unknown propose_project_settings_changes argument: " + str(key)}
			if typeof(arguments.get("base_hash")) != TYPE_STRING:
				return {"success": false, "error": "base_hash must be a string."}
			var project_error := _validate_path(ProjectSettingsProposal.PROJECT_PATH, true)
			if not project_error.is_empty():
				return {"success": false, "error": project_error}
			return ProjectSettingsProposal.prepare(change_id, arguments["base_hash"], arguments.get("changes"), true)
	return {"success": false, "error": "Unknown reviewed mutation tool: " + tool_name}


static func promote_script_trust(proposal: Dictionary) -> Dictionary:
	var operations: Array = proposal.get("operations", [])
	if operations.size() != 1 or typeof(operations[0]) != TYPE_DICTIONARY:
		return {"success": false, "error": "The retained script trust operation is invalid."}
	var operation: Dictionary = operations[0]
	var scene_error := _validate_path(str(proposal.get("filepath", "")), true)
	if not scene_error.is_empty():
		return {"success": false, "error": scene_error}
	var script_error := _validate_path(str(operation.get("script_path", "")), false)
	if not script_error.is_empty():
		return {"success": false, "error": script_error}
	return SceneProposal.promote_script_trust(proposal)


static func apply_reviewed_change(proposal: Dictionary) -> String:
	var result := ""
	if proposal.get("kind", "file_patch") == "scene":
		result = _apply_scene_change(proposal)
	elif proposal.get("kind", "file_patch") == "input_map":
		result = _apply_input_map_change(proposal)
	elif proposal.get("kind", "file_patch") == "main_scene":
		result = _apply_main_scene_change(proposal)
	elif proposal.get("kind", "file_patch") == "project_settings":
		result = _apply_project_settings_change(proposal)
	else:
		result = _apply_file_edit(proposal)
	return _append_recorded_cleanup(result, proposal)


static func revert_reviewed_change(proposal: Dictionary) -> String:
	var result := ""
	if proposal.get("kind", "file_patch") == "scene":
		result = _revert_scene_change(proposal)
	elif proposal.get("kind", "file_patch") == "input_map":
		result = _revert_input_map_change(proposal)
	elif proposal.get("kind", "file_patch") == "main_scene":
		result = _revert_main_scene_change(proposal)
	elif proposal.get("kind", "file_patch") == "project_settings":
		result = _revert_project_settings_change(proposal)
	else:
		result = _revert_file_edit(proposal)
	return _append_recorded_cleanup(result, proposal)


static func _apply_scene_change(proposal: Dictionary) -> String:
	var filepath := str(proposal.get("filepath", ""))
	var path_error := _validate_path(filepath, true)
	if not path_error.is_empty():
		return "Error: " + path_error
	if EditorContext.has_unsaved_file(filepath):
		return "Error: The target scene has unsaved editor changes. Save or close it before applying this proposal."
	if bool(proposal.get("existed", false)) and EditorContext.is_scene_open(filepath):
		return "Error: The target scene is open in the editor. Close it before applying this proposal."
	var operations: Array = proposal.get("operations", [])
	if operations.size() == 1 and str(operations[0].get("operation", "")) in ["attach_script", "detach_script"]:
		var script_path := str(operations[0].get("script_path", ""))
		var script_path_error := _validate_path(script_path, false)
		if not script_path_error.is_empty():
			return "Error: " + script_path_error
		if EditorContext.has_unsaved_file(script_path):
			return "Error: The reviewed script has unsaved editor changes."
	if operations.size() == 1 and str(operations[0].get("operation", "")) == "instantiate_child_scene":
		var child_path_error := _validate_path(str(operations[0].get("child_scene_path", "")), false)
		if not child_path_error.is_empty():
			return "Error: " + child_path_error
	var state_error := SceneProposal.validate_current(proposal, false)
	if not state_error.is_empty():
		return "Error: " + state_error
	var candidate_error := SceneProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var existed := bool(proposal.get("existed", false))
	var write_result := _write_file_safely(filepath, str(proposal.get("new_content", "")), str(proposal.get("old_hash", "")), existed)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	proposal["exact_applied_state"] = true
	var write_warning := _safe_write_warning(write_result)
	var final_error := SceneProposal.validate_current(proposal, true)
	if not final_error.is_empty():
		var current := _read_text_file(filepath)
		if current.get("success", false) and str(current.get("content", "")).sha256_text() == str(proposal.get("new_hash", "")):
			var rollback_error := ""
			if existed:
				var rollback_result := _write_file_safely(filepath, str(proposal.get("old_content", "")), str(proposal.get("new_hash", "")), true)
				_record_write_cleanup(proposal, rollback_result)
				if _is_safe_write_recovery_failure(rollback_result):
					_mark_write_recovery(proposal, rollback_result)
					_scan_filesystem()
					return "Recovery required: Final scene validation failed, and rollback could not restore the destination. " + str(rollback_result.get("message", ""))
				rollback_error = _safe_write_blocking_result(rollback_result)
				if _safe_write_committed(rollback_result):
					proposal["exact_applied_state"] = false
			elif DirAccess.remove_absolute(ProjectSettings.globalize_path(filepath)) != OK:
				rollback_error = "Could not remove the created scene."
			var rollback_validation := SceneProposal.validate_current(proposal, false) if rollback_error.is_empty() else rollback_error
			if rollback_validation.is_empty():
				_scan_filesystem()
				return "Error: Final scene validation failed and the original disk state was restored: " + final_error
		proposal["recovery_required"] = true
		proposal["exact_applied_state"] = false
		_scan_filesystem()
		return "Recovery required: The scene file was replaced but failed final validation and the original disk state could not be safely restored: " + final_error
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Applied the reviewed scene change, but cleanup requires attention. " + write_warning
	return "Applied reviewed scene change to " + filepath


static func _revert_scene_change(proposal: Dictionary) -> String:
	var filepath := str(proposal.get("filepath", ""))
	var path_error := _validate_path(filepath, true)
	if not path_error.is_empty():
		return "Error: " + path_error
	if EditorContext.has_unsaved_file(filepath):
		return "Error: The scene has unsaved editor changes. Save or discard them before reverting."
	if bool(proposal.get("existed", false)) and EditorContext.is_scene_open(filepath):
		return "Error: The scene is open in the editor. Close it before reverting this structured change."
	var operations: Array = proposal.get("operations", [])
	if operations.size() == 1 and str(operations[0].get("operation", "")) in ["attach_script", "detach_script"]:
		var script_path_error := _validate_path(str(operations[0].get("script_path", "")), false)
		if not script_path_error.is_empty():
			return "Error: " + script_path_error
	var specialized_revert := operations.size() == 1 and str(operations[0].get("operation", "")) in ["instantiate_child_scene", "attach_script", "detach_script"]
	var candidate_error := SceneProposal.validate_revert_candidate(proposal) if specialized_revert else SceneProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	if not specialized_revert:
		var state_error := SceneProposal.validate_current(proposal, true)
		if not state_error.is_empty():
			return "Conflict: " + state_error
	var existed := bool(proposal.get("existed", false))
	if existed:
		var write_result := _write_file_safely(filepath, str(proposal.get("old_content", "")), str(proposal.get("new_hash", "")), true)
		_record_write_cleanup(proposal, write_result)
		var write_block := _safe_write_blocking_result(write_result)
		if not write_block.is_empty():
			_mark_write_recovery(proposal, write_result)
			return write_block
		var write_warning := _safe_write_warning(write_result)
		var final_error := SceneProposal.validate_current(proposal, false)
		if not final_error.is_empty():
			var rollback_result := _write_file_safely(filepath, str(proposal.get("new_content", "")), str(proposal.get("old_hash", "")), true)
			_record_write_cleanup(proposal, rollback_result)
			if _is_safe_write_recovery_failure(rollback_result):
				_mark_write_recovery(proposal, rollback_result)
				_scan_filesystem()
				return "Recovery required: Scene revert validation failed, and restoration could not recover the applied destination. " + str(rollback_result.get("message", ""))
			if _safe_write_committed(rollback_result):
				proposal["exact_applied_state"] = true
				_scan_filesystem()
				return "Error: Scene revert validation failed, so the applied bytes were restored: " + final_error
			_scan_filesystem()
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
			return "Recovery required: Scene revert validation failed and the applied bytes could not be safely restored: " + final_error
		if not write_warning.is_empty():
			proposal["cleanup_required"] = true
			_scan_filesystem()
			return "Cleanup required: Reverted the scene change, but cleanup requires attention. " + write_warning
	else:
		var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(filepath))
		if remove_error != OK or FileAccess.file_exists(filepath) or DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(filepath)):
			return "Error: Could not remove the scene created by Orca."
	_scan_filesystem()
	return "Reverted scene change at " + filepath


static func _apply_input_map_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(InputMapProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var state_error := InputMapProposal.validate_current(proposal, false)
	if not state_error.is_empty():
		return "Error: " + state_error
	var candidate_error := InputMapProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var write_result := _write_file_safely(InputMapProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	proposal["exact_applied_state"] = true
	var write_warning := _safe_write_warning(write_result)
	var sync_error := InputMapProposal.sync_live(proposal.get("new_values", {}))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(InputMapProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: Input Map synchronization failed, and rollback could not restore project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = false
			var live_rollback_error := InputMapProposal.sync_live(proposal.get("old_values", {}))
			var rollback_warning := _safe_write_warning(rollback_result)
			if not rollback_warning.is_empty():
				proposal["cleanup_required"] = true
			return "Error: Could not synchronize the applied Input Map state: %s%s%s" % [sync_error, " Live rollback also failed: " + live_rollback_error if not live_rollback_error.is_empty() else "", " Cleanup requires attention: " + rollback_warning if not rollback_warning.is_empty() else ""]
		var current := _read_text_file(InputMapProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("new_hash", "")):
			var candidate_retry_error := InputMapProposal.sync_live(proposal.get("new_values", {}))
			_scan_filesystem()
			if candidate_retry_error.is_empty():
				return "Applied reviewed Input Map changes to res://project.godot"
			proposal["recovery_required"] = true
			return "Recovery required: The reviewed Input Map changes are on disk, but live synchronization still requires recovery: " + candidate_retry_error
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := InputMapProposal.sync_live(proposal.get("old_values", {}))
			return "Error: Input Map synchronization failed, but the original disk state remains intact.%s" % (" Live rollback also failed: " + old_retry_error if not old_retry_error.is_empty() else "")
		var independent_sync_error := InputMapProposal.sync_live_from_content(str(current.get("content", "")), proposal.get("action_names", [])) if current.get("success", false) else "Could not read the independently changed file."
		proposal["recovery_required"] = true
		proposal["exact_applied_state"] = false
		return "Recovery required: project.godot changed independently during rollback; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_sync_error if not independent_sync_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Applied the reviewed Input Map changes, but cleanup requires attention. " + write_warning
	return "Applied reviewed Input Map changes to res://project.godot"


static func _revert_input_map_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(InputMapProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var candidate_error := InputMapProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var state_error := InputMapProposal.validate_current(proposal, true)
	if not state_error.is_empty():
		return "Error: " + state_error
	var write_result := _write_file_safely(InputMapProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	var write_warning := _safe_write_warning(write_result)
	var sync_error := InputMapProposal.sync_live(proposal.get("old_values", {}))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(InputMapProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: Input Map revert synchronization failed, and restoration could not recover the applied project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = true
			var live_rollback_error := InputMapProposal.sync_live(proposal.get("new_values", {}))
			var rollback_warning := _safe_write_warning(rollback_result)
			if not rollback_warning.is_empty():
				proposal["cleanup_required"] = true
			return "Error: Could not synchronize the reverted Input Map state: %s%s%s" % [sync_error, " Live rollback also failed: " + live_rollback_error if not live_rollback_error.is_empty() else "", " Cleanup requires attention: " + rollback_warning if not rollback_warning.is_empty() else ""]
		var current := _read_text_file(InputMapProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := InputMapProposal.sync_live(proposal.get("old_values", {}))
			_scan_filesystem()
			if old_retry_error.is_empty():
				return "Reverted Input Map changes in res://project.godot"
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
			return "Recovery required: The Input Map was reverted on disk. Restart the editor to reload it: " + old_retry_error
		if current_hash == str(proposal.get("new_hash", "")):
			var new_retry_error := InputMapProposal.sync_live(proposal.get("new_values", {}))
			return "Error: Input Map revert synchronization failed, but the applied disk state remains intact.%s" % (" Live restoration also failed: " + new_retry_error if not new_retry_error.is_empty() else "")
		var independent_sync_error := InputMapProposal.sync_live_from_content(str(current.get("content", "")), proposal.get("action_names", [])) if current.get("success", false) else "Could not read the independently changed file."
		return "Conflict: project.godot changed independently during revert; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_sync_error if not independent_sync_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Reverted the Input Map changes, but cleanup requires attention. " + write_warning
	return "Reverted Input Map changes in res://project.godot"


static func _apply_main_scene_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(MainSceneProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var scene_path_error := _validate_path(str(proposal.get("new_scene_path", "")), false)
	if not scene_path_error.is_empty():
		return "Error: " + scene_path_error
	var state_error := MainSceneProposal.validate_current(proposal, false)
	if not state_error.is_empty():
		return "Error: " + state_error
	var candidate_error := MainSceneProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var write_result := _write_file_safely(MainSceneProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	proposal["exact_applied_state"] = true
	var write_warning := _safe_write_warning(write_result)
	var sync_error := MainSceneProposal.sync_live(proposal.get("new_value"), proposal.get("new_scene_path", ""))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(MainSceneProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: Main-scene synchronization failed, and rollback could not restore project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = false
			var live_rollback_error := MainSceneProposal.sync_live(proposal.get("old_value"), proposal.get("old_scene_path", ""))
			return "Error: Could not synchronize the applied main scene: %s%s" % [sync_error, " Live rollback also failed: " + live_rollback_error if not live_rollback_error.is_empty() else ""]
		var current := _read_text_file(MainSceneProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("new_hash", "")):
			var retry_error := MainSceneProposal.sync_live(proposal.get("new_value"), proposal.get("new_scene_path", ""))
			_scan_filesystem()
			if retry_error.is_empty():
				return "Applied reviewed main scene change to res://project.godot"
			proposal["recovery_required"] = true
			return "Recovery required: The reviewed main scene is on disk, but live synchronization still requires recovery: " + retry_error
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := MainSceneProposal.sync_live(proposal.get("old_value"), proposal.get("old_scene_path", ""))
			return "Error: Main scene synchronization failed, but the original disk state remains intact.%s" % (" Live rollback also failed: " + old_retry_error if not old_retry_error.is_empty() else "")
		var independent_error := MainSceneProposal.sync_live_from_content(str(current.get("content", ""))) if current.get("success", false) else "Could not read the independently changed file."
		proposal["recovery_required"] = true
		proposal["exact_applied_state"] = false
		return "Recovery required: project.godot changed independently during rollback; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_error if not independent_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Applied the reviewed main scene change, but cleanup requires attention. " + write_warning
	return "Applied reviewed main scene change to res://project.godot"


static func _revert_main_scene_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(MainSceneProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var candidate_error := MainSceneProposal.validate_candidate(proposal, false)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var state_error := MainSceneProposal.validate_current(proposal, true)
	if not state_error.is_empty():
		return "Error: " + state_error
	var write_result := _write_file_safely(MainSceneProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	var write_warning := _safe_write_warning(write_result)
	var sync_error := MainSceneProposal.sync_live(proposal.get("old_value"), proposal.get("old_scene_path", ""))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(MainSceneProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: Main-scene revert synchronization failed, and restoration could not recover the applied project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = true
			var live_rollback_error := MainSceneProposal.sync_live(proposal.get("new_value"), proposal.get("new_scene_path", ""))
			return "Error: Could not synchronize the reverted main scene: %s%s" % [sync_error, " Live restoration also failed: " + live_rollback_error if not live_rollback_error.is_empty() else ""]
		var current := _read_text_file(MainSceneProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := MainSceneProposal.sync_live(proposal.get("old_value"), proposal.get("old_scene_path", ""))
			_scan_filesystem()
			if old_retry_error.is_empty():
				return "Reverted main scene change in res://project.godot"
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
			return "Recovery required: The main scene was reverted on disk. Restart the editor to reload the reverted setting: " + old_retry_error
		if current_hash == str(proposal.get("new_hash", "")):
			var new_retry_error := MainSceneProposal.sync_live(proposal.get("new_value"), proposal.get("new_scene_path", ""))
			return "Error: Main scene revert synchronization failed, but the applied disk state remains intact.%s" % (" Live restoration also failed: " + new_retry_error if not new_retry_error.is_empty() else "")
		var independent_error := MainSceneProposal.sync_live_from_content(str(current.get("content", ""))) if current.get("success", false) else "Could not read the independently changed file."
		return "Conflict: project.godot changed independently during main scene revert; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_error if not independent_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Reverted the main scene change, but cleanup requires attention. " + write_warning
	return "Reverted main scene change in res://project.godot"


static func _apply_project_settings_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(ProjectSettingsProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var state_error := ProjectSettingsProposal.validate_current(proposal, false)
	if not state_error.is_empty():
		return "Error: " + state_error
	var candidate_error := ProjectSettingsProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var write_result := _write_file_safely(ProjectSettingsProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	proposal["exact_applied_state"] = true
	var write_warning := _safe_write_warning(write_result)
	var sync_error := ProjectSettingsProposal.sync_live(proposal.get("new_values", {}))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(ProjectSettingsProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: ProjectSettings synchronization failed, and rollback could not restore project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = false
			var live_rollback_error := ProjectSettingsProposal.sync_live(proposal.get("old_values", {}))
			return "Error: Could not synchronize the applied ProjectSettings: %s%s" % [sync_error, " Live rollback also failed: " + live_rollback_error if not live_rollback_error.is_empty() else ""]
		var current := _read_text_file(ProjectSettingsProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("new_hash", "")):
			var retry_error := ProjectSettingsProposal.sync_live(proposal.get("new_values", {}))
			_scan_filesystem()
			if retry_error.is_empty():
				return "Applied reviewed ProjectSettings changes to res://project.godot"
			proposal["recovery_required"] = true
			return "Recovery required: The reviewed ProjectSettings are on disk, but live synchronization still requires recovery: " + retry_error
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := ProjectSettingsProposal.sync_live(proposal.get("old_values", {}))
			return "Error: ProjectSettings synchronization failed, but the original disk state remains intact.%s" % (" Live rollback also failed: " + old_retry_error if not old_retry_error.is_empty() else "")
		var independent_error := ProjectSettingsProposal.sync_live_from_content(str(current.get("content", "")), proposal.get("setting_paths", [])) if current.get("success", false) else "Could not read the independently changed file."
		proposal["recovery_required"] = true
		proposal["exact_applied_state"] = false
		return "Recovery required: project.godot changed independently during rollback; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_error if not independent_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Applied the reviewed ProjectSettings changes, but cleanup requires attention. " + write_warning
	return "Applied reviewed ProjectSettings changes to res://project.godot"


static func _revert_project_settings_change(proposal: Dictionary) -> String:
	var project_path_error := _validate_path(ProjectSettingsProposal.PROJECT_PATH, true)
	if not project_path_error.is_empty():
		return "Error: " + project_path_error
	var candidate_error := ProjectSettingsProposal.validate_candidate(proposal)
	if not candidate_error.is_empty():
		return "Error: " + candidate_error
	var state_error := ProjectSettingsProposal.validate_current(proposal, true)
	if not state_error.is_empty():
		return "Error: " + state_error
	var write_result := _write_file_safely(ProjectSettingsProposal.PROJECT_PATH, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	var write_warning := _safe_write_warning(write_result)
	var sync_error := ProjectSettingsProposal.sync_live(proposal.get("old_values", {}))
	if not sync_error.is_empty():
		var rollback_result := _write_file_safely(ProjectSettingsProposal.PROJECT_PATH, proposal.get("new_content", ""), proposal.get("old_hash", ""), true)
		_record_write_cleanup(proposal, rollback_result)
		if _is_safe_write_recovery_failure(rollback_result):
			_mark_write_recovery(proposal, rollback_result)
			return "Recovery required: ProjectSettings revert synchronization failed, and restoration could not recover the applied project.godot. " + str(rollback_result.get("message", ""))
		if _safe_write_committed(rollback_result):
			proposal["exact_applied_state"] = true
			var live_rollback_error := ProjectSettingsProposal.sync_live(proposal.get("new_values", {}))
			return "Error: Could not synchronize the reverted ProjectSettings: %s%s" % [sync_error, " Live restoration also failed: " + live_rollback_error if not live_rollback_error.is_empty() else ""]
		var current := _read_text_file(ProjectSettingsProposal.PROJECT_PATH)
		var current_hash := str(current.get("content", "")).sha256_text() if current.get("success", false) else ""
		if current_hash == str(proposal.get("old_hash", "")):
			var old_retry_error := ProjectSettingsProposal.sync_live(proposal.get("old_values", {}))
			_scan_filesystem()
			if old_retry_error.is_empty():
				return "Reverted ProjectSettings changes in res://project.godot"
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
			return "Recovery required: The ProjectSettings were reverted on disk. Restart the editor to reload them: " + old_retry_error
		if current_hash == str(proposal.get("new_hash", "")):
			var new_retry_error := ProjectSettingsProposal.sync_live(proposal.get("new_values", {}))
			return "Error: ProjectSettings revert synchronization failed, but the applied disk state remains intact.%s" % (" Live restoration also failed: " + new_retry_error if not new_retry_error.is_empty() else "")
		var independent_error := ProjectSettingsProposal.sync_live_from_content(str(current.get("content", "")), proposal.get("setting_paths", [])) if current.get("success", false) else "Could not read the independently changed file."
		return "Conflict: project.godot changed independently during ProjectSettings revert; Orca preserved those disk bytes.%s" % (" Live synchronization failed: " + independent_error if not independent_error.is_empty() else "")
	_scan_filesystem()
	if not write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Reverted the ProjectSettings changes, but cleanup requires attention. " + write_warning
	return "Reverted ProjectSettings changes in res://project.godot"


static func apply_file_edit(proposal: Dictionary) -> String:
	return _append_recorded_cleanup(_apply_file_edit(proposal), proposal)


static func _apply_file_edit(proposal: Dictionary) -> String:
	var filepath: String = proposal.get("filepath", "")
	var validation_error := _validate_path(filepath, true)
	if not validation_error.is_empty():
		return "Error: " + validation_error
	var canonical_path := _canonical_project_path(filepath)
	if filepath != canonical_path or str(proposal.get("kind", "")) != "file_patch" or str(proposal.get("tool_name", "")) != "apply_patch":
		return "Error: The retained file patch has invalid canonical proposal fields. Review a fresh proposal before applying it."
	filepath = canonical_path
	if EditorContext.has_unsaved_file(filepath):
		return "Error: The file has unsaved changes in Godot. Save or discard them before applying this patch."
	if typeof(proposal.get("old_content")) != TYPE_STRING or typeof(proposal.get("new_content")) != TYPE_STRING or typeof(proposal.get("old_hash")) != TYPE_STRING or typeof(proposal.get("new_hash")) != TYPE_STRING or typeof(proposal.get("existed")) != TYPE_BOOL:
		return "Error: The retained file patch content, hashes, or existence state are invalid. Review a fresh proposal before applying it."
	var old_content: String = proposal["old_content"]
	var new_content: String = proposal["new_content"]
	var old_hash: String = proposal["old_hash"]
	var new_hash: String = proposal["new_hash"]
	if old_content.sha256_text() != old_hash or new_content.sha256_text() != new_hash:
		return "Error: The retained file patch content does not match its reviewed hashes. Review a fresh proposal before applying it."
	if typeof(proposal.get("edits")) != TYPE_ARRAY or typeof(proposal.get("diff")) != TYPE_DICTIONARY:
		return "Error: The retained file patch edits or review diff are invalid. Review a fresh proposal before applying it."
	var retained_patch := PatchUtils.apply_line_edits(old_content, proposal["edits"])
	if not retained_patch.get("success", false) or str(retained_patch.get("content", "")) != new_content or proposal["diff"] != DiffUtils.create_diff(old_content, new_content):
		return "Error: The retained file patch does not match its canonical edits and review diff. Review a fresh proposal before applying it."

	var current_content := ""
	var current_exists := FileAccess.file_exists(filepath)
	if current_exists != proposal["existed"]:
		return "Error: The file's existence changed after this edit was proposed."
	if current_exists:
		var current_file := FileAccess.open(filepath, FileAccess.READ)
		if current_file == null:
			return "Error: Could not verify the current file before applying changes."
		current_content = current_file.get_as_text()
		current_file.close()
	if current_content.sha256_text() != old_hash:
		return "Error: The file changed after this edit was proposed. Review a fresh diff before applying it."
	if current_content != old_content:
		return "Error: The retained old content does not match the current file. Review a fresh diff before applying it."
	var source_validation := DiagnosticsService.validate_source(filepath, new_content)
	if not source_validation.get("valid", false):
		return "Error: Pre-write validation failed. " + _format_source_validation(source_validation)

	var write_result := _write_file_safely(filepath, new_content, old_hash, proposal["existed"])
	_record_write_cleanup(proposal, write_result)
	var write_block := _safe_write_blocking_result(write_result)
	if not write_block.is_empty():
		_mark_write_recovery(proposal, write_result)
		return write_block
	proposal["exact_applied_state"] = true
	var post_write_warning := _safe_write_warning(write_result)
	if _consume_replacement_test_fault("post_write_independent_change"):
		var independent_file := FileAccess.open(filepath, FileAccess.WRITE)
		if independent_file != null:
			independent_file.store_string("independent fault-injected bytes\n")
			independent_file.close()
	var final_file := {"success": false, "error": "Could not reread the replaced file."} if _consume_replacement_test_fault("post_write_reread_failure") else _read_text_file(filepath)
	var final_error := ""
	if not final_file.get("success", false):
		final_error = str(final_file.get("error", "Could not reread the replaced file."))
	else:
		var final_content := str(final_file.get("content", ""))
		if _consume_replacement_test_fault("post_write_hash_mismatch") or final_content.sha256_text() != new_hash:
			final_error = "The final destination hash does not match the reviewed candidate."
		else:
			var final_validation := DiagnosticsService.validate_source(filepath, final_content)
			if _consume_replacement_test_fault("post_write_validation_failure"):
				final_error = "Final disk validation failed. Fault-injected validation failure."
			elif not final_validation.get("valid", false):
				final_error = "Final disk validation failed. " + _format_source_validation(final_validation)
	if not final_error.is_empty():
		var recovery := "Rollback was not attempted because the destination could not be verified as Orca's candidate; the current disk bytes were preserved."
		var recovered := false
		var recovery_file := _read_text_file(filepath)
		if recovery_file.get("success", false) and str(recovery_file.get("content", "")).sha256_text() == new_hash:
			var rollback_error := ""
			if proposal["existed"]:
				var rollback_result := _write_file_safely(filepath, old_content, new_hash, true)
				_record_write_cleanup(proposal, rollback_result)
				if _is_safe_write_recovery_failure(rollback_result):
					_mark_write_recovery(proposal, rollback_result)
					_scan_filesystem()
					return "Recovery required: Post-write verification failed, and rollback could not restore the destination. " + str(rollback_result.get("message", ""))
				rollback_error = _safe_write_blocking_result(rollback_result)
				if _safe_write_committed(rollback_result):
					proposal["exact_applied_state"] = false
			else:
				var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(filepath))
				if remove_error != OK or FileAccess.file_exists(filepath):
					rollback_error = "Could not remove the file created by Orca."
			if rollback_error.is_empty():
				var restored := _read_text_file(filepath) if proposal["existed"] else {"success": not FileAccess.file_exists(filepath), "content": ""}
				if restored.get("success", false) and (not proposal["existed"] or str(restored.get("content", "")).sha256_text() == old_hash):
					recovery = "The original disk state was restored."
					recovered = true
				else:
					recovery = "Rollback completed but the original disk state could not be verified; manual recovery is required."
			else:
				recovery = "Rollback failed; manual recovery is required: " + rollback_error
		if not recovered:
			proposal["recovery_required"] = true
			proposal["exact_applied_state"] = false
		_scan_filesystem()
		return "%s: %s %s" % ["Error" if recovered else "Recovery required", final_error, recovery]
	_scan_filesystem()
	if not post_write_warning.is_empty():
		proposal["cleanup_required"] = true
		return "Cleanup required: Applied the reviewed changes, but cleanup requires attention. " + post_write_warning
	return "Applied changes to " + filepath


static func revert_file_edit(proposal: Dictionary) -> String:
	return _append_recorded_cleanup(_revert_file_edit(proposal), proposal)


static func _revert_file_edit(proposal: Dictionary) -> String:
	var filepath: String = proposal.get("filepath", "")
	var validation_error := _validate_path(filepath, true)
	if not validation_error.is_empty():
		return "Error: " + validation_error
	filepath = _canonical_project_path(filepath)
	if EditorContext.has_unsaved_file(filepath):
		return "Error: The file has unsaved changes in Godot. Save or discard them before reverting this patch."
	if not FileAccess.file_exists(filepath):
		return "Error: The edited file no longer exists."

	var current_file := FileAccess.open(filepath, FileAccess.READ)
	if current_file == null:
		return "Error: Could not verify the file before reverting it."
	var current_content := current_file.get_as_text()
	current_file.close()
	if current_content.sha256_text() != proposal.get("new_hash", ""):
		return "Error: The file changed after Orca applied it. Revert was blocked to protect those changes."

	if not proposal.get("existed", false):
		var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(filepath))
		if remove_error != OK:
			return "Error: Could not remove the file created by Orca."
	else:
		var write_result := _write_file_safely(filepath, proposal.get("old_content", ""), proposal.get("new_hash", ""), true)
		_record_write_cleanup(proposal, write_result)
		var write_block := _safe_write_blocking_result(write_result)
		if not write_block.is_empty():
			_mark_write_recovery(proposal, write_result)
			return write_block
		var write_warning := _safe_write_warning(write_result)
		if not write_warning.is_empty():
			proposal["cleanup_required"] = true
			_scan_filesystem()
			return "Cleanup required: Reverted the changes, but cleanup requires attention. " + write_warning
	_scan_filesystem()
	return "Reverted changes to " + filepath


static func _validate_path(filepath: String, for_writing: bool) -> String:
	if not filepath.begins_with("res://"):
		return "Path must start with 'res://'."
	var project_root := ProjectSettings.globalize_path("res://").simplify_path()
	var absolute_path := ProjectSettings.globalize_path(filepath).simplify_path()
	if absolute_path != project_root and not absolute_path.begins_with(project_root + "/"):
		return "Path resolves outside the project."
	var relative_path := "" if absolute_path == project_root else absolute_path.trim_prefix(project_root + "/")
	if _path_contains_symlink(project_root, relative_path):
		return "Paths containing symbolic links are blocked."
	if relative_path == "addons/orca" or relative_path.begins_with("addons/orca/"):
		return "Access to Orca's own plugin files is blocked."
	if for_writing and relative_path.is_empty():
		return "The project root cannot be written as a file."
	return ""


static func _canonical_project_path(filepath: String) -> String:
	return ProjectSettings.localize_path(ProjectSettings.globalize_path(filepath).simplify_path())


static func _read_text_file(filepath: String) -> Dictionary:
	var file := FileAccess.open(filepath, FileAccess.READ)
	if file == null:
		return {"success": false, "error": "Could not read " + filepath}
	var content := file.get_as_text()
	file.close()
	return {"success": true, "content": content}


static func _write_file_safely(filepath: String, content: String, expected_hash: String, expected_exists: bool) -> Dictionary:
	var test_write_index := 0
	if OS.get_environment("ORCA_TEST_FAULT_INJECTION") == "1":
		_replacement_test_write_index += 1
		test_write_index = _replacement_test_write_index
	var absolute_path := ProjectSettings.globalize_path(filepath)
	var parent_path := absolute_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_path):
		var directory_error := DirAccess.make_dir_recursive_absolute(parent_path)
		if directory_error != OK:
			return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "Could not create the destination directory.")

	var temporary_path := absolute_path + ".orca_tmp_" + str(Time.get_ticks_usec())
	var temporary_file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if temporary_file == null:
		return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "Could not create a temporary file.")
	temporary_file.store_string(content)
	temporary_file.close()

	var verify_file := FileAccess.open(temporary_path, FileAccess.READ)
	if verify_file == null or verify_file.get_as_text().sha256_text() != content.sha256_text() or _consume_replacement_test_fault("temporary_verification_failure"):
		if verify_file != null:
			verify_file.close()
		return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "Temporary file verification failed." + _cleanup_temporary_file(temporary_path))
	verify_file.close()
	var current_exists := FileAccess.file_exists(absolute_path)
	if current_exists != expected_exists:
		return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "The destination changed while the replacement was being prepared." + _cleanup_temporary_file(temporary_path))
	if current_exists:
		var current_file := FileAccess.open(absolute_path, FileAccess.READ)
		if current_file == null or current_file.get_as_text().sha256_text() != expected_hash:
			if current_file != null:
				current_file.close()
			return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "The destination changed while the replacement was being prepared." + _cleanup_temporary_file(temporary_path))
		current_file.close()

	var backup_path := absolute_path + ".orca_backup_" + str(Time.get_ticks_usec())
	var target_exists := FileAccess.file_exists(absolute_path)
	if target_exists:
		var backup_error := DirAccess.rename_absolute(absolute_path, backup_path)
		if backup_error != OK:
			return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "Could not prepare the existing file for replacement." + _cleanup_temporary_file(temporary_path))

	var replace_error := ERR_CANT_CREATE if _consume_replacement_test_fault("replacement_failure") or _consume_replacement_test_fault("replacement_failure_on_write_" + str(test_write_index)) else DirAccess.rename_absolute(temporary_path, absolute_path)
	if replace_error != OK:
		if target_exists:
			var restore_error := ERR_CANT_CREATE if _consume_replacement_test_fault("restore_failure") else DirAccess.rename_absolute(backup_path, absolute_path)
			if restore_error != OK:
				return _safe_write_result(SafeWriteOutcome.RECOVERY_FAILURE, "Replacement failed and the original could not be restored. Recovery copy: " + backup_path + _cleanup_temporary_file(temporary_path))
		return _safe_write_result(SafeWriteOutcome.NOT_COMMITTED_FAILURE, "Could not replace the destination file." + _cleanup_temporary_file(temporary_path))
	if target_exists:
		var cleanup_error := ERR_CANT_CREATE if _consume_replacement_test_fault("backup_cleanup_failure") else DirAccess.remove_absolute(backup_path)
		if cleanup_error != OK:
			return _safe_write_result(SafeWriteOutcome.COMMITTED_CLEANUP_WARNING, "Replacement succeeded, but the private backup could not be removed. Recovery copy: " + backup_path)
	return _safe_write_result(SafeWriteOutcome.COMMITTED_SUCCESS)


static func _safe_write_result(outcome: SafeWriteOutcome, message: String = "") -> Dictionary:
	return {"outcome": outcome, "message": message}


static func _safe_write_committed(result: Dictionary) -> bool:
	return int(result.get("outcome", SafeWriteOutcome.RECOVERY_FAILURE)) in [SafeWriteOutcome.COMMITTED_SUCCESS, SafeWriteOutcome.COMMITTED_CLEANUP_WARNING]


static func _safe_write_blocking_result(result: Dictionary) -> String:
	if _safe_write_committed(result):
		return ""
	var prefix := "Recovery required: " if int(result.get("outcome", SafeWriteOutcome.RECOVERY_FAILURE)) == SafeWriteOutcome.RECOVERY_FAILURE else "Error: "
	return prefix + str(result.get("message", "File replacement failed."))


static func _safe_write_warning(result: Dictionary) -> String:
	return str(result.get("message", "")) if int(result.get("outcome", -1)) == SafeWriteOutcome.COMMITTED_CLEANUP_WARNING else ""


static func _is_safe_write_recovery_failure(result: Dictionary) -> bool:
	return int(result.get("outcome", -1)) == SafeWriteOutcome.RECOVERY_FAILURE


static func _mark_write_recovery(proposal: Dictionary, result: Dictionary) -> void:
	if not _is_safe_write_recovery_failure(result):
		return
	proposal["recovery_required"] = true
	proposal["exact_applied_state"] = false


static func _record_write_cleanup(proposal: Dictionary, result: Dictionary) -> void:
	var warning := _safe_write_warning(result)
	if warning.is_empty():
		return
	proposal["cleanup_required"] = true
	var warnings: Array = proposal.get("cleanup_warnings", [])
	if warning not in warnings:
		warnings.append(warning)
	proposal["cleanup_warnings"] = warnings


static func _append_recorded_cleanup(result: String, proposal: Dictionary) -> String:
	var missing := PackedStringArray()
	for warning in proposal.get("cleanup_warnings", []):
		var text := str(warning)
		if not text.is_empty() and not result.contains(text):
			missing.append(text)
	if missing.is_empty():
		return result
	var details := " Cleanup required: " + " ".join(missing)
	if result.begins_with("Applied") or result.begins_with("Reverted"):
		return "Cleanup required: " + result + details
	return result + details


static func _cleanup_temporary_file(path: String) -> String:
	if _consume_replacement_test_fault("temporary_cleanup_failure") or DirAccess.remove_absolute(path) != OK:
		return " Temporary cleanup required. Retained temporary copy: " + path
	return ""


static func _set_replacement_test_faults(faults: Dictionary) -> void:
	if OS.get_environment("ORCA_TEST_FAULT_INJECTION") != "1":
		return
	_replacement_test_faults = faults.duplicate(true)
	_replacement_test_write_index = 0


static func _clear_replacement_test_faults() -> void:
	if OS.get_environment("ORCA_TEST_FAULT_INJECTION") != "1":
		return
	_replacement_test_faults.clear()
	_replacement_test_write_index = 0


static func _consume_replacement_test_fault(name: String) -> bool:
	if OS.get_environment("ORCA_TEST_FAULT_INJECTION") != "1":
		return false
	var remaining := int(_replacement_test_faults.get(name, 0))
	if remaining <= 0:
		return false
	if remaining == 1:
		_replacement_test_faults.erase(name)
	else:
		_replacement_test_faults[name] = remaining - 1
	return true


static func _format_source_validation(validation: Dictionary) -> String:
	var lines := PackedStringArray([str(validation.get("message", "GDScript validation failed."))])
	for diagnostic in validation.get("diagnostics", []):
		var location := str(diagnostic.get("file", ""))
		if int(diagnostic.get("line", 0)) > 0:
			location += ":" + str(diagnostic.get("line"))
		lines.append("%s%s" % [location + ": " if not location.is_empty() else "", str(diagnostic.get("message", "GDScript validation error."))])
	return " ".join(lines)


static func _scan_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	var resource_filesystem := EditorInterface.get_resource_filesystem()
	if resource_filesystem != null:
		resource_filesystem.scan()
	EditorInterface.get_script_editor().reload_open_files()


static func _verification_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"kind": {"type": "string", "enum": ["clean_startup", "expected_exit"]},
			"claim": {"type": "string", "minLength": 1, "maxLength": 240},
			"minimum_runtime_ms": {"type": "integer", "minimum": 250, "maximum": 10000},
			"expected_exit_code": {"type": "integer", "minimum": -255, "maximum": 255},
			"required_stdout": {"type": "array", "maxItems": 5, "items": {"type": "string", "minLength": 1, "maxLength": 200}},
			"forbidden_output": {"type": "array", "maxItems": 5, "items": {"type": "string", "minLength": 1, "maxLength": 200}},
			"require_no_runtime_errors": {"type": "boolean"}
		},
		"required": ["kind"],
		"additionalProperties": false
	}


static func _only_arguments(arguments: Dictionary, allowed: Array) -> bool:
	for key in arguments:
		if str(key) not in allowed:
			return false
	return true


static func _format_game_observation(snapshot: Dictionary, changed_since: bool) -> String:
	var recommendation := _recommended_run_action(snapshot, changed_since)
	var lines := PackedStringArray([
		"Run %d snapshot %d (%s): %s" % [int(snapshot.get("run_id", 0)), int(snapshot.get("sequence", 0)), "changed" if changed_since else "unchanged", str(snapshot.get("state", "unknown"))],
		"Scene: " + str(snapshot.get("scene_path", "")),
		"Elapsed: %d ms" % int(snapshot.get("elapsed_ms", 0)),
		"Verification: " + str(snapshot.get("verification_status", "unverified")),
		"Recommended next action: " + recommendation,
	])
	if snapshot.get("exit_code") != null:
		lines.append("Exit code: " + str(snapshot.get("exit_code")))
	for stream_name in ["stdout", "stderr"]:
		var output := str(snapshot.get(stream_name, ""))
		if not output.is_empty():
			lines.append("%s:\n%s" % [stream_name, output])
	if bool(snapshot.get("output_truncated", false)) or bool(snapshot.get("diagnostics_truncated", false)):
		lines.append("Evidence is truncated; absence-based checks may be inconclusive.")
	return "\n".join(lines)


static func _recommended_run_action(snapshot: Dictionary, changed_since: bool) -> String:
	var state := str(snapshot.get("state", "unknown"))
	var verification_status := str(snapshot.get("verification_status", "unverified"))
	if state not in ["running", "timeout_stop_failed", "shutdown_stop_failed"]:
		return "verify" if bool(snapshot.get("verification_configured", false)) else "finalize"
	if verification_status in ["passed", "failed", "inconclusive"]:
		return "stop"
	if not Array(snapshot.get("diagnostics", [])).is_empty():
		return "stop_then_inspect_error"
	if changed_since and bool(snapshot.get("verification_configured", false)):
		return "verify"
	return "stop_or_wait_for_new_evidence"


static func _format_game_verification(verdict: Dictionary) -> String:
	var lines := PackedStringArray([
		"Verification %s for run %d: %s" % [str(verdict.get("status", "unverified")).to_upper(), int(verdict.get("run_id", 0)), str(verdict.get("claim", "No criterion"))],
		str(verdict.get("message", ""))
	])
	for check in verdict.get("checks", []):
		lines.append("- %s: %s (expected %s, observed %s)" % [str(check.get("name", "check")), str(check.get("status", "unknown")), str(check.get("expected")), str(check.get("observed"))])
	return "\n".join(lines)


static func _path_contains_symlink(project_root: String, relative_path: String) -> bool:
	var current_path := project_root
	for component in relative_path.split("/", false):
		var parent := DirAccess.open(current_path)
		if parent == null:
			return false
		if parent.is_link(component):
			return true
		current_path = current_path.path_join(component)
		if not DirAccess.dir_exists_absolute(current_path):
			return false
	return false


static func _format_diagnostics(report: Dictionary) -> String:
	var lines := PackedStringArray([
		"Editor play state: " + ("running " + str(report.get("playing_scene", "")) if report.get("playing", false) else "stopped")
	])
	var game: Dictionary = report.get("orca_run", {})
	lines.append("Orca run %d: %s%s" % [int(game.get("run_id", 0)), str(game.get("state", "idle")), " " + str(game.get("scene_path", "")) if not str(game.get("scene_path", "")).is_empty() else ""])
	lines.append("Verification: " + str(game.get("verification_status", "unverified")))
	if game.get("exit_code") != null:
		lines.append("Exit code: " + str(game.get("exit_code")))
	if bool(game.get("output_truncated", false)):
		var dropped := int(game.get("dropped_bytes", 0))
		lines.append("Captured output was truncated%s." % ("; dropped %d byte(s)" % dropped if dropped > 0 else " by line or line-length bounds"))
	for stream_name in ["stdout", "stderr"]:
		var output := str(game.get(stream_name, ""))
		if not output.is_empty():
			lines.append("Game %s:\n%s" % [stream_name, output])
	var game_records: Array = report.get("game_records", [])
	if not game_records.is_empty():
		lines.append("Detected game-process diagnostic-shaped output:")
		for record in game_records:
			var location := str(record.get("file", ""))
			if int(record.get("line", 0)) > 0:
				location += ":" + str(record.get("line"))
			lines.append("%s %s: %s" % [str(record.get("severity", "error")).to_upper(), location, str(record.get("message", ""))])
	var records: Array = report.get("records", [])
	if records.is_empty():
		lines.append("No captured validation or editor-process errors.")
	else:
		for record in records:
			var location := str(record.get("file", ""))
			if int(record.get("line", 0)) > 0:
				location += ":" + str(record["line"])
			lines.append("%s %s: %s" % [str(record.get("severity", "error")).to_upper(), location, record.get("message", "")])
	lines.append(str(report.get("note", "")))
	return "\n".join(lines)


static func _first_diagnostic_location(report: Dictionary) -> Dictionary:
	for record in report.get("game_records", []):
		var path := str(record.get("file", ""))
		if _validate_path(path, false).is_empty() and FileAccess.file_exists(path):
			return {"open_path": path, "open_line": maxi(1, int(record.get("line", 1))), "open_column": 1}
	for record in report.get("records", []):
		var path := str(record.get("file", ""))
		if _validate_path(path, false).is_empty() and FileAccess.file_exists(path):
			return {"open_path": path, "open_line": maxi(1, int(record.get("line", 1))), "open_column": 1}
	return {}


static func _tool_success(content: String, data: Dictionary = {}) -> Dictionary:
	return {"success": true, "content": content, "outcome": "completed", "data": data}


static func _tool_error(message: String, data: Dictionary = {}) -> Dictionary:
	return {"success": false, "content": "Error: " + message, "outcome": "failed", "data": data}
