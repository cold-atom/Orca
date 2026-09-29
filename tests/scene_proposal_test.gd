extends SceneTree

const SceneProposal = preload("res://addons/orca/scripts/scene_proposal.gd")
const Tools = preload("res://addons/orca/scripts/tools.gd")

var _failures := PackedStringArray()
var _fixture_path := ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture_path = "res://.orca_scene_proposal_test_%d" % Time.get_ticks_usec()
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_fixture_path)) == OK, "fixture directory should be created")
	_test_scratch_cleanup()
	_test_contract_validation()
	_test_candidate_integrity()
	_test_apply_and_revert()
	_test_stale_and_conflict_guards()
	_test_add_node_lifecycle()
	_test_add_node_validation()
	_test_typed_property_lifecycle()
	_test_structural_lifecycles()
	_test_script_lifecycles()
	_test_child_scene_lifecycle()
	_test_signal_lifecycles()
	_expect(_scratch_files().is_empty(), "scene validation should leave no scratch .tscn files")
	_expect(not _has_replacement_artifacts(ProjectSettings.globalize_path(_fixture_path)), "scene proposal tests should leave no replacement artifacts")
	_remove_tree(ProjectSettings.globalize_path(_fixture_path))
	_finish()


func _test_scratch_cleanup() -> void:
	_expect(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SceneProposal.SCRATCH_DIRECTORY)) == OK, "scratch directory should be available")
	var stale_path := SceneProposal.SCRATCH_DIRECTORY.path_join("candidate_stale_test.tscn")
	_write(stale_path, "private scratch bytes")
	SceneProposal.cleanup_stale_scratch(0)
	_expect(not FileAccess.file_exists(stale_path), "startup cleanup should remove stale structured-scene scratch files")


func _test_contract_validation() -> void:
	var target := _fixture_path.path_join("valid.tscn")
	for root_type in SceneProposal.ALLOWED_ROOT_TYPES:
		var proposal := SceneProposal.prepare("valid_" + root_type, "", target, [_operation(root_type, "Root")])
		_expect(proposal.get("success", false), "allowlisted root should produce a proposal: " + root_type)
		_expect(not FileAccess.file_exists(target), "preparation must not create the project scene")
		if proposal.get("success", false):
			_expect(proposal.get("scene_summary", {}).get("root_type") == root_type, "summary should retain the reviewed root type")
			_expect(SceneProposal.validate_candidate(proposal).is_empty(), "fresh candidate should pass integrity validation")
	for invalid_type in ["", "Resource", "Window", "MissingClass"]:
		_expect(not SceneProposal.prepare("bad_type", "", target, [_operation(invalid_type, "Root")]).get("success", true), "disallowed root type should fail: " + invalid_type)
	for invalid_name in ["", " Root", "Root/Child", "Root.Name", "x".repeat(SceneProposal.MAX_ROOT_NAME_CHARS + 1)]:
		_expect(not SceneProposal.prepare("bad_name", "", target, [_operation("Node2D", invalid_name)]).get("success", true), "invalid root name should fail")
	_expect(not SceneProposal.prepare("hash", "not-empty", target, [_operation("Node2D", "Root")]).get("success", true), "new scenes should require an empty base hash")
	_expect(not SceneProposal.prepare("extension", "", _fixture_path.path_join("scene.res"), [_operation("Node2D", "Root")]).get("success", true), "non-tscn targets should fail")
	_expect(not SceneProposal.prepare("missing_parent", "", _fixture_path.path_join("missing/scene.tscn"), [_operation("Node2D", "Root")]).get("success", true), "missing parent directories should fail")
	_expect(not SceneProposal.prepare("multiple", "", target, [_operation("Node2D", "Root"), _operation("Node", "Other")]).get("success", true), "multiple initial operations should fail")
	_expect(not SceneProposal.prepare("unknown", "", target, [{"operation": "create_scene", "root_type": "Node", "root_name": "Root", "script": "res://x.gd"}]).get("success", true), "unknown operation fields should fail")
	var protected := Tools.prepare_reviewed_change("propose_scene_changes", "protected", {"scene_path": "res://addons/orca/blocked.tscn", "base_hash": "", "operations": [_operation("Node", "Root")]})
	_expect(not protected.get("success", true), "public preparation should enforce Orca path protection")


func _test_candidate_integrity() -> void:
	var target := _fixture_path.path_join("integrity.tscn")
	var proposal := SceneProposal.prepare("integrity", "", target, [_operation("Node2D", "World")])
	_expect(proposal.get("success", false), "integrity fixture should prepare")
	if not proposal.get("success", false):
		return
	_expect(str(proposal.get("old_content", "")) == "" and str(proposal.get("old_hash", "")) == "".sha256_text(), "proposal should bind the absent base state")
	_expect(str(proposal.get("new_content", "")).sha256_text() == str(proposal.get("new_hash", "")), "proposal should bind exact candidate bytes")
	var tampered_bytes := proposal.duplicate(true)
	tampered_bytes["new_content"] = str(tampered_bytes["new_content"]) + "\n"
	_expect(not SceneProposal.validate_candidate(tampered_bytes).is_empty(), "candidate-byte tampering should fail")
	var tampered_operation := proposal.duplicate(true)
	tampered_operation["operations"][0]["root_name"] = "Changed"
	_expect(not SceneProposal.validate_candidate(tampered_operation).is_empty(), "operation tampering should fail")
	var tampered_summary := proposal.duplicate(true)
	tampered_summary["scene_summary"]["root_type"] = "Control"
	_expect(not SceneProposal.validate_candidate(tampered_summary).is_empty(), "summary tampering should fail")


func _test_apply_and_revert() -> void:
	var target := _fixture_path.path_join("created.tscn")
	var arguments := {"scene_path": target, "base_hash": "", "operations": [_operation("Node3D", "Level")]}
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "create", arguments)
	_expect(proposal.get("success", false), "reviewed scene creation should prepare")
	_expect(not FileAccess.file_exists(target), "reviewed preparation must not write the target")
	if not proposal.get("success", false):
		return
	_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "approved scene creation should apply")
	_expect(FileAccess.file_exists(target), "application should create the scene")
	var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(packed is PackedScene, "applied target should load as PackedScene")
	if packed is PackedScene:
		var state: SceneState = packed.get_state()
		_expect(state.get_node_count() == 1 and str(state.get_node_type(0)) == "Node3D" and str(state.get_node_name(0)) == "Level", "applied scene should contain exactly the reviewed root")
	_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted"), "unchanged created scene should revert")
	_expect(not FileAccess.file_exists(target), "revert should remove the created scene")


func _test_stale_and_conflict_guards() -> void:
	var stale_target := _fixture_path.path_join("stale.tscn")
	var stale := Tools.prepare_reviewed_change("propose_scene_changes", "stale", {"scene_path": stale_target, "base_hash": "", "operations": [_operation("Control", "Menu")]})
	_expect(stale.get("success", false), "stale fixture should prepare")
	_write(stale_target, "independent")
	_expect(Tools.apply_reviewed_change(stale).begins_with("Error:"), "a target appearing before apply should block creation")
	_expect(_read(stale_target) == "independent", "blocked apply should preserve the independent target")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(stale_target))

	var conflict_target := _fixture_path.path_join("conflict.tscn")
	var conflict := Tools.prepare_reviewed_change("propose_scene_changes", "conflict", {"scene_path": conflict_target, "base_hash": "", "operations": [_operation("Node", "Root")]})
	_expect(Tools.apply_reviewed_change(conflict).begins_with("Applied"), "conflict fixture should apply")
	_write(conflict_target, "newer user bytes")
	_expect(Tools.revert_reviewed_change(conflict).begins_with("Conflict:"), "independently changed scenes should block revert")
	_expect(_read(conflict_target) == "newer user bytes", "blocked revert should preserve independent bytes")


func _test_add_node_lifecycle() -> void:
	var target := _fixture_path.path_join("existing.tscn")
	var original := "[gd_scene format=3]\n\n[node name=\"World\" type=\"Node2D\"]\nmetadata/title = \"Preserve me\"\n\n[node name=\"Container\" type=\"Node\" parent=\".\" groups=[\"layout\"]]\n\n[node name=\"Existing\" type=\"Node2D\" parent=\"Container\"]\n"
	_write(target, original)
	var operation := {"operation": "add_node", "parent_path": "./Container", "node_type": "Node2D", "node_name": "SpawnPoint"}
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "add", {"scene_path": target, "base_hash": original.sha256_text(), "operations": [operation]})
	_expect(proposal.get("success", false), "add_node should prepare against a valid saved scene: " + str(proposal.get("error", "")))
	_expect(_read(target) == original, "add_node preparation must not modify the saved scene")
	if not proposal.get("success", false):
		return
	var summary: Dictionary = proposal.get("scene_summary", {})
	_expect(proposal.get("existed", false), "add_node should retain existing-file replacement semantics")
	_expect(summary.get("operation") == "add_node" and summary.get("before_node_count") == 3 and summary.get("after_node_count") == 4, "add_node review should show complete node counts")
	_expect(summary.get("added_node", {}).get("path") == "./Container/SpawnPoint" and summary.get("added_node", {}).get("owner_path") == ".", "add_node review should show the resulting path and root ownership")
	_expect(SceneProposal.validate_candidate(proposal).is_empty(), "fresh add_node candidates should pass complete semantic validation")
	_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "approved add_node should replace the saved scene")
	var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(packed is PackedScene, "add_node result should remain a PackedScene")
	if packed is PackedScene:
		var state: SceneState = packed.get_state()
		var added_index := _state_node_index(state, "./Container/SpawnPoint")
		_expect(state.get_node_count() == 4 and added_index >= 0, "add_node should serialize exactly one additional node")
		if added_index >= 0:
			_expect(str(state.get_node_type(added_index)) == "Node2D" and str(state.get_node_owner_path(added_index)) == ".", "added node should retain reviewed type and root owner")
	_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted"), "unchanged add_node result should revert")
	_expect(_read(target) == original, "add_node revert should restore exact original scene bytes")


func _test_add_node_validation() -> void:
	var target := _fixture_path.path_join("validation_existing.tscn")
	var original := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"Existing\" type=\"Node\" parent=\".\"]\n"
	_write(target, original)
	var valid_operation := {"operation": "add_node", "parent_path": ".", "node_type": "Control", "node_name": "Panel"}
	_expect(not SceneProposal.prepare("stale_add", "wrong", target, [valid_operation]).get("success", true), "add_node should require the exact saved-scene hash")
	for parent_path in ["", "Root", "./", "../Root", "./Missing/", "./A//B", "%Unique", "./A:property"]:
		var invalid := valid_operation.duplicate(true)
		invalid["parent_path"] = parent_path
		_expect(not SceneProposal.prepare("bad_parent", original.sha256_text(), target, [invalid]).get("success", true), "noncanonical or missing parent paths should fail: " + parent_path)
	var duplicate := valid_operation.duplicate(true)
	duplicate["node_name"] = "Existing"
	_expect(not SceneProposal.prepare("duplicate", original.sha256_text(), target, [duplicate]).get("success", true), "duplicate direct child names should fail")
	var proposal := SceneProposal.prepare("tamper_add", original.sha256_text(), target, [valid_operation])
	_expect(proposal.get("success", false), "add-node tamper fixture should prepare: " + str(proposal.get("error", "")))
	if proposal.get("success", false):
		_expect(proposal.get("scene_summary", {}).get("added_node", {}).get("path") == "./Panel", "root-parent add_node should produce a canonical child path")
		var tampered := proposal.duplicate(true)
		tampered["scene_summary"]["added_node"]["owner_path"] = "./Existing"
		_expect(not SceneProposal.validate_candidate(tampered).is_empty(), "tampered add-node ownership summaries should fail")
		_write(target, original + "\n")
		_expect(Tools.apply_reviewed_change(proposal).begins_with("Error:"), "stale existing scene bytes should block add-node apply")
		_write(target, original)
		_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "fresh add-node conflict fixture should apply")
		_write(target, "independent scene bytes")
		_expect(Tools.revert_reviewed_change(proposal).begins_with("Conflict:"), "independent scene edits should block add-node revert")
		_expect(_read(target) == "independent scene bytes", "blocked add-node revert should preserve independent bytes")

	var script_path := _fixture_path.path_join("attached.gd")
	_write(script_path, "extends Node\n")
	var scripted_path := _fixture_path.path_join("scripted.tscn")
	var scripted := "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"%s\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node\"]\nscript = ExtResource(\"1\")\n" % script_path
	_write(scripted_path, scripted)
	var scripted_result := SceneProposal.prepare("scripted", scripted.sha256_text(), scripted_path, [valid_operation])
	_expect(not scripted_result.get("success", true) and str(scripted_result.get("error", "")).contains("script"), "scripted scenes should be rejected before instantiation: " + str(scripted_result.get("error", "")))
	var resource_scene := _read("res://tests/fixtures/inspect_scene_fixture.tscn")
	var resource_result := SceneProposal.prepare("resource", resource_scene.sha256_text(), "res://tests/fixtures/inspect_scene_fixture.tscn", [valid_operation])
	_expect(not resource_result.get("success", true), "scenes with child instances or Resource properties should be rejected before mutation")
	var instance_path := _fixture_path.path_join("instance.tscn")
	var instance_scene := "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"PackedScene\" path=\"res://tests/fixtures/inspect_scene_child.tscn\" id=\"1\"]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"Child\" parent=\".\" instance=ExtResource(\"1\")]\n"
	_write(instance_path, instance_scene)
	var instance_result := SceneProposal.prepare("instance", instance_scene.sha256_text(), instance_path, [valid_operation])
	_expect(not instance_result.get("success", true) and (str(instance_result.get("error", "")).contains("instances") or str(instance_result.get("error", "")).contains("dependencies")), "child-scene instances should be rejected before instantiation: " + str(instance_result.get("error", "")))
	var drift_path := _fixture_path.path_join("drift.tscn")
	var drift_scene := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"ExistingControl\" type=\"Control\" parent=\".\"]\n"
	_write(drift_path, drift_scene)
	var drift_result := SceneProposal.prepare("drift", drift_scene.sha256_text(), drift_path, [valid_operation])
	_expect(not drift_result.get("success", true) and str(drift_result.get("error", "")).contains("unrelated"), "scenes that do not round-trip without unrelated serialization drift should be rejected")


func _test_typed_property_lifecycle() -> void:
	var target := _fixture_path.path_join("property.tscn")
	var original := _structural_scene()
	_write(target, original)
	var operation := {"operation": "set_property", "node_path": "./A", "property_name": "position", "value": {"type": "Vector2", "x": 30.0, "y": 40.0}}
	var proposal := SceneProposal.prepare("property", original.sha256_text(), target, [operation])
	_expect(proposal.get("success", false), "typed property proposal should prepare: " + str(proposal.get("error", "")))
	if proposal.get("success", false):
		_expect(proposal.get("scene_summary", {}).get("before") == {"type": "Vector2", "x": 1.0, "y": 2.0}, "property review should expose the exact previous typed value")
		_expect(SceneProposal.validate_candidate(proposal).is_empty(), "typed property candidate should revalidate")
		_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "typed property proposal should apply")
		var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		var root = packed.instantiate() if packed is PackedScene else null
		_expect(root != null and root.get_node("A").position == Vector2(30, 40), "applied scene should retain the exact typed property")
		if root != null:
			root.free()
		_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted"), "typed property proposal should revert")
		_expect(_read(target) == original, "typed property revert should restore exact bytes")
	var wrong_type := operation.duplicate(true)
	wrong_type["value"] = {"type": "String", "value": "wrong"}
	_expect(not SceneProposal.prepare("wrong_property", original.sha256_text(), target, [wrong_type]).get("success", true), "property Variant type mismatches should fail")
	var unsafe := operation.duplicate(true)
	unsafe["value"] = {"type": "NodePath", "value": "../B"}
	_expect(not SceneProposal.prepare("unsafe_property", original.sha256_text(), target, [unsafe]).get("success", true), "unsupported reference property values should fail")


func _test_structural_lifecycles() -> void:
	var target := _fixture_path.path_join("structural.tscn")
	var original := _structural_scene()
	var operations := [
		{"operation": "rename_node", "node_path": "./A/Leaf", "new_name": "Renamed"},
		{"operation": "remove_node", "node_path": "./A/Leaf"},
		{"operation": "reparent_node", "node_path": "./A/Leaf", "new_parent_path": "./B"}
	]
	for operation in operations:
		_write(target, original)
		var proposal := SceneProposal.prepare(str(operation["operation"]), original.sha256_text(), target, [operation])
		_expect(proposal.get("success", false), str(operation["operation"]) + " should prepare: " + str(proposal.get("error", "")))
		if not proposal.get("success", false):
			continue
		_expect(SceneProposal.validate_candidate(proposal).is_empty(), str(operation["operation"]) + " candidate should revalidate")
		_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), str(operation["operation"]) + " should apply")
		var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		var state: SceneState = packed.get_state() if packed is PackedScene else null
		if operation["operation"] == "rename_node":
			_expect(state != null and _state_node_index(state, "./A/Renamed") >= 0, "rename_node should change the saved leaf path")
		elif operation["operation"] == "remove_node":
			_expect(state != null and state.get_node_count() == 3 and _state_node_index(state, "./A/Leaf") < 0, "remove_node should remove exactly the reviewed leaf")
		else:
			_expect(state != null and _state_node_index(state, "./B/Leaf") >= 0, "reparent_node should move the reviewed leaf")
		_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted"), str(operation["operation"]) + " should revert")
		_expect(_read(target) == original, str(operation["operation"]) + " revert should restore exact bytes")
	_write(target, original)
	_expect(not SceneProposal.prepare("remove_parent", original.sha256_text(), target, [{"operation": "remove_node", "node_path": "./A"}]).get("success", true), "remove_node should reject non-leaf targets")
	_expect(not SceneProposal.prepare("reparent_parent", original.sha256_text(), target, [{"operation": "reparent_node", "node_path": "./A", "new_parent_path": "./B"}]).get("success", true), "reparent_node should reject non-leaf targets")


func _structural_scene() -> String:
	return "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node2D\"]\n\n[node name=\"A\" type=\"Node2D\" parent=\".\"]\nposition = Vector2(1, 2)\n\n[node name=\"Leaf\" type=\"Node\" parent=\"A\"]\n\n[node name=\"B\" type=\"Node\" parent=\".\"]\n"


func _test_script_lifecycles() -> void:
	var script_path := _fixture_path.path_join("actor.gd")
	var script_content := "extends Node2D\n"
	_write(script_path, script_content)
	var target := _fixture_path.path_join("script_target.tscn")
	var original := "[gd_scene format=3]\n\n[node name=\"Actor\" type=\"Node2D\"]\n"
	_write(target, original)
	var attach := {"operation": "attach_script", "node_path": ".", "script_path": script_path, "script_hash": script_content.sha256_text()}
	var detach := {"operation": "detach_script", "node_path": ".", "script_path": script_path, "script_hash": script_content.sha256_text()}
	var trust := Tools.prepare_reviewed_change("propose_scene_changes", "attach", {"scene_path": target, "base_hash": original.sha256_text(), "operations": [attach]})
	_expect(trust.get("success", false) and trust.get("approval_stage") == "script_trust", "attach_script should first produce a non-executing trust review: " + str(trust.get("error", "")))
	_expect(not trust.has("new_content") and _read(target) == original, "trust preparation must not construct a candidate or modify the scene")
	if not trust.get("success", false):
		return
	var attach_proposal := Tools.promote_script_trust(trust)
	_expect(attach_proposal.get("success", false) and attach_proposal.get("approval_stage") == "candidate", "trusted attach_script should construct a candidate: " + str(attach_proposal.get("error", "")))
	if not attach_proposal.get("success", false):
		return
	_expect(SceneProposal.validate_candidate(attach_proposal).is_empty(), "fresh attach_script candidate should revalidate")
	_expect(Tools.apply_reviewed_change(attach_proposal).begins_with("Applied"), "approved attach_script should apply")
	var attached_content := _read(target)
	var attached = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	_expect(attached is PackedScene and _state_script_path(attached.get_state(), ".") == script_path, "applied scene should retain the exact reviewed script")
	_write(script_path, script_content + "# independently changed after attach\n")
	_expect(Tools.revert_reviewed_change(attach_proposal).begins_with("Reverted"), "attach_script should restore the exact scriptless scene even if the attached script changed later")
	_expect(_read(target) == original, "attach_script revert should restore exact original bytes")
	_write(script_path, script_content)

	_write(target, attached_content)
	var detach_trust := SceneProposal.prepare("detach", attached_content.sha256_text(), target, [detach])
	_expect(detach_trust.get("success", false) and detach_trust.get("approval_stage") == "script_trust", "detach_script should inspect intent without loading the scripted scene")
	var detach_proposal := SceneProposal.promote_script_trust(detach_trust) if detach_trust.get("success", false) else {}
	_expect(detach_proposal.get("success", false), "trusted detach_script should construct a candidate: " + str(detach_proposal.get("error", "")))
	if detach_proposal.get("success", false):
		_expect(Tools.apply_reviewed_change(detach_proposal).begins_with("Applied"), "approved detach_script should apply")
		var detached = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		_expect(detached is PackedScene and _state_script_path(detached.get_state(), ".").is_empty(), "detach_script should remove exactly the reviewed script")
		_expect(Tools.revert_reviewed_change(detach_proposal).begins_with("Reverted"), "detach_script should revert")
		_expect(_read(target) == attached_content, "detach_script revert should restore exact scripted scene bytes")

	_write(target, original)
	var stale_trust := SceneProposal.prepare("stale_script", original.sha256_text(), target, [attach])
	_write(script_path, script_content + "# changed\n")
	_expect(not SceneProposal.promote_script_trust(stale_trust).get("success", true), "script drift before trusted construction should fail")
	_write(script_path, script_content)
	var bad_hash := attach.duplicate(true)
	bad_hash["script_hash"] = "0".repeat(64)
	_expect(not SceneProposal.prepare("bad_script_hash", original.sha256_text(), target, [bad_hash]).get("success", true), "script trust should require the exact saved hash")
	var incompatible_path := _fixture_path.path_join("control.gd")
	var incompatible_content := "extends Control\n"
	_write(incompatible_path, incompatible_content)
	var incompatible := {"operation": "attach_script", "node_path": ".", "script_path": incompatible_path, "script_hash": incompatible_content.sha256_text()}
	var incompatible_trust := SceneProposal.prepare("incompatible", original.sha256_text(), target, [incompatible])
	_expect(incompatible_trust.get("success", false) and not SceneProposal.promote_script_trust(incompatible_trust).get("success", true), "trusted construction should reject an incompatible native script base")
	var invalid_path := _fixture_path.path_join("invalid.gd")
	var invalid_content := "extends Node2D\nfunc broken(\n"
	_write(invalid_path, invalid_content)
	var invalid := {"operation": "attach_script", "node_path": ".", "script_path": invalid_path, "script_hash": invalid_content.sha256_text()}
	var invalid_trust := SceneProposal.prepare("invalid", original.sha256_text(), target, [invalid])
	_expect(invalid_trust.get("success", false), "invalid script source should still reach trust review without pre-approval compilation")
	_expect(not SceneProposal.promote_script_trust(invalid_trust).get("success", true), "invalid GDScript should fail only after trusted validation")


func _test_child_scene_lifecycle() -> void:
	var child_path := _fixture_path.path_join("child.tscn")
	var child_content := "[gd_scene format=3]\n\n[node name=\"ChildRoot\" type=\"Node2D\"]\n\n[node name=\"Visual\" type=\"Node\" parent=\".\"]\n"
	_write(child_path, child_content)
	var target := _fixture_path.path_join("parent.tscn")
	var original := "[gd_scene format=3]\n\n[node name=\"World\" type=\"Node\"]\n\n[node name=\"Instances\" type=\"Node\" parent=\".\"]\n"
	_write(target, original)
	var operation := {"operation": "instantiate_child_scene", "parent_path": "./Instances", "child_scene_path": child_path, "child_hash": child_content.sha256_text(), "node_name": "Enemy"}
	var proposal := Tools.prepare_reviewed_change("propose_scene_changes", "instance_child", {"scene_path": target, "base_hash": original.sha256_text(), "operations": [operation]})
	_expect(proposal.get("success", false), "instantiate_child_scene should prepare: " + str(proposal.get("error", "")))
	if not proposal.get("success", false):
		return
	_expect(SceneProposal.validate_candidate(proposal).is_empty(), "child-instance candidate should revalidate against its dependency hash")
	_expect(proposal.get("scene_summary", {}).get("instance", {}).get("path") == "./Instances/Enemy", "child-instance review should expose the resulting local instance path")
	_expect(Tools.apply_reviewed_change(proposal).begins_with("Applied"), "instantiate_child_scene should apply")
	var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var state: SceneState = packed.get_state() if packed is PackedScene else null
	var instance_index := _state_node_index(state, "./Instances/Enemy") if state != null else -1
	_expect(instance_index >= 0 and state.get_node_instance(instance_index) != null and state.get_node_instance(instance_index).resource_path == child_path, "applied child should remain a PackedScene instance rather than flattening")
	_write(child_path, child_content + "\n")
	_expect(Tools.revert_reviewed_change(proposal).begins_with("Reverted"), "child-scene instance should revert")
	_expect(_read(target) == original, "child-scene revert should restore exact parent bytes")
	_write(child_path, child_content)
	_expect(not SceneProposal.prepare("self_instance", original.sha256_text(), target, [{"operation": "instantiate_child_scene", "parent_path": ".", "child_scene_path": target, "child_hash": original.sha256_text(), "node_name": "Self"}]).get("success", true), "a scene must not instantiate itself")
	var stale := SceneProposal.prepare("stale_child", original.sha256_text(), target, [operation])
	_expect(stale.get("success", false), "child dependency stale fixture should prepare")
	_write(child_path, child_content + "\n")
	_expect(not SceneProposal.validate_candidate(stale).is_empty(), "child dependency changes should invalidate the retained proposal")
	_write(child_path, child_content)


func _test_signal_lifecycles() -> void:
	var target := _fixture_path.path_join("signals.tscn")
	var original := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"Timer\" type=\"Timer\" parent=\".\"]\n"
	_write(target, original)
	var connect_operation := {"operation": "connect_signal", "source_path": "./Timer", "signal_name": "timeout", "target_path": ".", "method_name": "queue_free", "deferred": true, "one_shot": false}
	var connect_proposal := SceneProposal.prepare("connect", original.sha256_text(), target, [connect_operation])
	_expect(connect_proposal.get("success", false), "connect_signal should prepare: " + str(connect_proposal.get("error", "")))
	if not connect_proposal.get("success", false):
		return
	_expect(SceneProposal.validate_candidate(connect_proposal).is_empty(), "connect_signal candidate should revalidate")
	_expect(int(connect_proposal.get("scene_summary", {}).get("connection", {}).get("flags", 0)) == (Object.CONNECT_PERSIST | Object.CONNECT_DEFERRED), "connect_signal should force persistence and retain reviewed safe flags")
	_expect(Tools.apply_reviewed_change(connect_proposal).begins_with("Applied"), "connect_signal should apply")
	var connected_content := _read(target)
	var packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(packed is PackedScene and packed.get_state().get_connection_count() == 1, "applied signal should persist in SceneState")
	_expect(Tools.revert_reviewed_change(connect_proposal).begins_with("Reverted"), "connect_signal should revert")
	_expect(_read(target) == original, "connect_signal revert should restore exact bytes")

	_write(target, connected_content)
	var disconnect_operation := {"operation": "disconnect_signal", "source_path": "./Timer", "signal_name": "timeout", "target_path": ".", "method_name": "queue_free"}
	var disconnect_proposal := SceneProposal.prepare("disconnect", connected_content.sha256_text(), target, [disconnect_operation])
	_expect(disconnect_proposal.get("success", false), "disconnect_signal should prepare: " + str(disconnect_proposal.get("error", "")))
	if disconnect_proposal.get("success", false):
		_expect(Tools.apply_reviewed_change(disconnect_proposal).begins_with("Applied"), "disconnect_signal should apply")
		packed = ResourceLoader.load(target, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
		_expect(packed is PackedScene and packed.get_state().get_connection_count() == 0, "disconnect_signal should remove exactly the reviewed connection")
		_expect(Tools.revert_reviewed_change(disconnect_proposal).begins_with("Reverted"), "disconnect_signal should revert")
		_expect(_read(target) == connected_content, "disconnect_signal revert should restore exact connected bytes")
	_write(target, original)
	_expect(not SceneProposal.prepare("duplicate_disconnect", original.sha256_text(), target, [disconnect_operation]).get("success", true), "disconnect_signal should reject a missing connection")
	var missing_signal := connect_operation.duplicate(true)
	missing_signal["signal_name"] = "missing_signal"
	_expect(not SceneProposal.prepare("missing_signal", original.sha256_text(), target, [missing_signal]).get("success", true), "connect_signal should reject missing signals")
	var type_mismatch := {"operation": "connect_signal", "source_path": ".", "signal_name": "child_entered_tree", "target_path": ".", "method_name": "set_process"}
	_expect(not SceneProposal.prepare("signal_type_mismatch", original.sha256_text(), target, [type_mismatch]).get("success", true), "connect_signal should reject incompatible signal and method argument types")
	var object_scene := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"UI\" type=\"Control\" parent=\".\"]\n"
	_write(target, object_scene)
	var object_mismatch := {"operation": "connect_signal", "source_path": "./UI", "signal_name": "gui_input", "target_path": ".", "method_name": "add_child"}
	_expect(not SceneProposal.prepare("signal_object_mismatch", object_scene.sha256_text(), target, [object_mismatch]).get("success", true), "connect_signal should reject incompatible object argument classes")
func _operation(root_type: String, root_name: String) -> Dictionary:
	return {"operation": "create_scene", "root_type": root_type, "root_name": root_name}


func _state_node_index(state: SceneState, path: String) -> int:
	for index in range(state.get_node_count()):
		if str(state.get_node_path(index)) == path:
			return index
	return -1


func _state_script_path(state: SceneState, path: String) -> String:
	var node_index := _state_node_index(state, path)
	if node_index < 0:
		return ""
	for property_index in range(state.get_node_property_count(node_index)):
		if str(state.get_node_property_name(node_index, property_index)) == "script":
			var value = state.get_node_property_value(node_index, property_index)
			return str(value.resource_path) if value is Script else ""
	return ""


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	_expect(file != null, "fixture should open for writing: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _scratch_files() -> PackedStringArray:
	var result := PackedStringArray()
	var directory := DirAccess.open(SceneProposal.SCRATCH_DIRECTORY)
	if directory == null:
		return result
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if not directory.current_is_dir() and name.get_extension().to_lower() == "tscn":
			result.append(name)
		name = directory.get_next()
	directory.list_dir_end()
	return result


func _has_replacement_artifacts(path: String) -> bool:
	var directory := DirAccess.open(path)
	if directory == null:
		return false
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name.contains(".orca_tmp_") or name.contains(".orca_backup_"):
			directory.list_dir_end()
			return true
		name = directory.get_next()
	directory.list_dir_end()
	return false


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
		print("scene_proposal_test: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("scene_proposal_test: ", failure)
	quit(1)
