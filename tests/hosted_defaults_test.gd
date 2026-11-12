extends SceneTree

const Controller = preload("res://addons/orca/scripts/agent_controller.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")
const Instructions = preload("res://addons/orca/scripts/project_instructions.gd")
const Budget = preload("res://addons/orca/scripts/context_budget.gd")
const LiveScene = preload("res://addons/orca/scripts/editor_scene_inspector.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var controller := Controller.new()
	root.add_child(controller)
	var primary := controller._get_system_prompt()
	var guidance := Instructions.load_project_instructions()
	var wrapped := str(guidance.get("wrapped_content", ""))
	var tools: Array = Tools.get_tool_definitions(true)
	var messages := [{"role": "system", "content": primary}, {"role": "system", "content": wrapped}, {"role": "user", "content": "hi"}]
	var result := Budget.prepare(messages, tools, 32768, false, 8192)
	print("Hosted production-request sizes: prompt=%d guidance=%d schemas=%d estimate=%d input_budget=%d" % [primary.to_utf8_buffer().size(), wrapped.to_utf8_buffer().size(), JSON.stringify(tools).to_utf8_buffer().size(), result["estimated_tokens"], result["input_budget"]])
	controller.free()
	if not result.get("success", false):
		push_error("A fresh hosted greeting must fit with real instructions and Work tools")
		quit(1)
		return
	var opaque := "opaque".repeat(6000)
	var private_estimate := Budget.estimate_tokens([{"role": "assistant", "content": "", "reasoning_content": opaque}], [], false, true, {"opaque_reasoning_bytes": true})
	if private_estimate < opaque.to_utf8_buffer().size():
		push_error("Opaque continuation must keep its full byte pressure")
		quit(1)
		return
	var scene := Node2D.new()
	scene.name = "SceneBudgetFixture"
	for index in 40:
		var control := Control.new()
		control.name = "Panel%d" % index
		scene.add_child(control)
	var snapshot := LiveScene.snapshot(scene, [], {"scope": "scene", "max_nodes": 100, "max_depth": 8}, true, func(_path, _allow_root): return "")
	if not snapshot.get("success", false):
		scene.free()
		push_error("Live budget fixture must produce a bounded native scene snapshot")
		quit(1)
		return
	var report: Dictionary = snapshot["report"]
	var pretty := str(snapshot["content"])
	var compact := JSON.stringify(report)
	var followup := messages.duplicate(true)
	followup.append({"role": "assistant", "content": "", "tool_calls": [{"id": "live_scene", "type": "function", "function": {"name": "inspect_editor_scene", "arguments": "{\"scope\":\"scene\"}"}}]})
	followup.append({"role": "tool", "tool_call_id": "live_scene", "content": pretty})
	var pretty_budget := Budget.prepare(followup, tools, 32768, false, 8192)
	var pretty_final_budget := Budget.prepare(followup, [], 32768, false, 8192)
	followup[-1]["content"] = compact
	var compact_budget := Budget.prepare(followup, tools, 32768, false, 8192)
	var compact_final_budget := Budget.prepare(followup, [], 32768, false, 8192)
	var current_budget := Budget.prepare(followup, tools, 65536, false, 8192)
	print("Hosted scene follow-up: readable=%d compact=%d tokens; input_budget=%d" % [pretty_budget["estimated_tokens"], compact_budget["estimated_tokens"], compact_budget["input_budget"]])
	print("Hosted scene finalization: compact=%d/%d; 64k continuation=%d/%d" % [compact_final_budget["estimated_tokens"], compact_final_budget["input_budget"], current_budget["estimated_tokens"], current_budget["input_budget"]])
	scene.free()
	if pretty_final_budget.get("success", false) or not compact_final_budget.get("success", false) or not current_budget.get("success", false) or JSON.parse_string(pretty) != JSON.parse_string(compact):
		push_error("Compact complete scene results must permit old 32k safe finalization and full 64k continuation without dropping properties, tool protocol or response reserves")
		quit(1)
		return
	print("Hosted defaults: PASS")
	quit()
