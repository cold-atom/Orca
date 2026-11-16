"""Reviewed live Blender authoring. Only pinned Orca helpers and typed JSON data.

The host Blender environment is user-trusted, not an execution sandbox. This
adapter never accepts Python, arbitrary operators, executables or caller paths.
It never opens/reloads/saves over the user's document, including on failure.
"""

import array
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import types
import uuid

import bpy
from bpy.app.handlers import persistent

SUPPORTED = (
    "primitive", "mesh", "transform", "mesh_edit", "delete", "duplicate",
    "collider", "lod", "rigid_body", "cloth", "join", "modifier", "material",
    "texture", "bake", "uv_unwrap", "armature", "skin", "constraint", "keyframes",
    "bake_animation", "shape_key", "geometry_nodes", "curve", "light", "camera",
)
ROOT = None
TOKEN = ""
SCENE = None
DOCUMENT = ""
OPS = None
REVISION = 1
EPOCH = 0
REVOKED = False
BUSY = False
UNDO_BASELINE = None
PENDING = None
EDIT_RESULT = None
OPERATOR = None
HASHES = {}
CHECKPOINTS = 0


def trusted_source(path, expected):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path or path.is_symlink():
        raise ValueError("The shipped live-authoring helper is unavailable")
    with path.open("rb") as file:
        data = file.read(1024 * 1024 + 1)
    if not data or len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("The shipped live-authoring helper changed")
    return data


@persistent
def changed(*args):
    global EPOCH
    if len(args) > 1 and hasattr(args[1], "updates") and not args[1].updates:
        return
    EPOCH += 1


@persistent
def loaded(*_args):
    global REVOKED
    REVOKED = True
    changed()


@persistent
def undo_changed(*_args):
    global REVOKED
    REVOKED = True
    changed()


def close():
    global REVOKED
    REVOKED = True
    owner = sys.modules.get("_orca_live_authoring_owner")
    if owner is not None and getattr(owner, "close", None) is close:
        sys.modules.pop("_orca_live_authoring_owner", None)
    for handlers, callback in (
        (bpy.app.handlers.depsgraph_update_post, changed),
        (bpy.app.handlers.undo_post, undo_changed), (bpy.app.handlers.redo_post, undo_changed),
        (bpy.app.handlers.load_post, loaded),
    ):
        if callback in handlers:
            handlers.remove(callback)
    if OPERATOR is not None:
        try:
            bpy.utils.unregister_class(OPERATOR)
        except RuntimeError:
            pass
    module = sys.modules.get(__name__)
    if module is not None and getattr(module, "close", None) is close:
        sys.modules.pop(__name__, None)


def preflight():
    global REVOKED
    if ROOT is None or ROOT.resolve() != ROOT or not ROOT.is_dir():
        raise ValueError("The private live-authoring directory changed")
    if REVOKED or SCENE is None or bpy.context.scene != SCENE or bpy.data.filepath != DOCUMENT:
        REVOKED = True
        raise ValueError("The live Blender document changed; explicitly enable authoring again")
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        raise ValueError("Finish the current Blender Edit/Pose/Sculpt operation before authoring")
    if bpy.data.libraries or bpy.data.texts:
        raise ValueError("Linked libraries and embedded scripts need a separate trust workflow")
    if len(bpy.data.objects) > 256 or len(bpy.data.actions) > 64 or len(bpy.data.materials) > 128 or len(bpy.data.node_groups) > 128 or len(bpy.data.images) > 32:
        raise ValueError("The live document exceeds its bounded inspection budget")
    if sum(len(m.vertices) for m in bpy.data.meshes) > 200000 or sum(len(m.loops) for m in bpy.data.meshes) > 1200000:
        raise ValueError("The complete live document exceeds its checkpoint geometry budget")
    geometry_bytes = 0
    for mesh in bpy.data.meshes:
        geometry_bytes += len(mesh.vertices) * 64 + len(mesh.loops) * (32 + 8 * len(mesh.uv_layers))
        if mesh.shape_keys:
            geometry_bytes += sum(len(key.data) * 16 for key in mesh.shape_keys.key_blocks)
        if geometry_bytes > 24 * 1024 * 1024:
            raise ValueError("The live document exceeds its checkpoint source-data budget")
    pixels = packed = 0
    for image in bpy.data.images:
        pixels += image.size[0] * image.size[1]
        if len(image.packed_files) > 16:
            raise ValueError("The live image exceeds its packed-file budget")
        packed += sum(p.packed_file.size for p in image.packed_files)
    if pixels > 16 * 1024 * 1024 or packed > 16 * 1024 * 1024 or packed + geometry_bytes > 24 * 1024 * 1024:
        raise ValueError("Live textures exceed their checkpoint size budget")
    for ids in (bpy.data.objects, bpy.data.materials, bpy.data.node_groups, bpy.data.scenes, bpy.data.worlds, bpy.data.meshes, bpy.data.armatures, bpy.data.curves, bpy.data.shape_keys):
        if len(ids) > 256:
            raise ValueError("The live document exceeds its data-block budget")
        for value in ids:
            if value.library or (value.animation_data and value.animation_data.drivers):
                raise ValueError("Linked data and scripted drivers need a separate trust workflow")
    if len(SCENE.objects) > 128:
        raise ValueError("The live scene exceeds 128 objects")
    vertices = polygons = bones = estimated = 0
    for value in SCENE.objects:
        if len(value.users_scene) != 1 or value.library or (value.data and value.data.library):
            raise ValueError("Objects shared with other scenes or linked libraries are unsupported")
        if value.type == "MESH":
            if len(value.data.loops) > 600000:
                raise ValueError("Live mesh topology exceeds its scan budget")
            vertices += len(value.data.vertices)
            polygons += len(value.data.polygons)
            estimated += mesh_budget(value)
            if len(value.data.uv_layers) > 8 or (value.data.shape_keys and len(value.data.shape_keys.key_blocks) > 32):
                raise ValueError("Mesh UV/shape-key inspection exceeds its budget")
        if value.type == "ARMATURE":
            bones += len(value.data.bones)
            if any(len(bone.constraints) > 32 for bone in value.pose.bones):
                raise ValueError("Pose constraints exceed their inspection budget")
        if value.type == "CURVE":
            if len(value.data.splines) > 64 or sum(len(s.points) + len(s.bezier_points) for s in value.data.splines) > 10000 or value.data.bevel_resolution > 6 or value.data.resolution_u > 64:
                raise ValueError("Live curve evaluation exceeds its fixed budget")
        if len(value.modifiers) > 32 or len(value.constraints) > 32:
            raise ValueError("Object modifier/constraint inspection exceeds its budget")
    if vertices > 100000 or estimated > 100000 or polygons > 200000 or bones > 256:
        raise ValueError("The live scene exceeds its geometry/rig budget")


def mesh_budget(value):
    count = len(value.data.vertices)
    allowed = {"BEVEL", "SUBSURF", "MIRROR", "SOLIDIFY", "DECIMATE", "BOOLEAN", "TRIANGULATE", "ARMATURE", "CLOTH", "NODES"}
    for modifier in value.modifiers:
        if modifier.type not in allowed:
            raise ValueError("The live mesh has an unsupported evaluation modifier")
        if modifier.type == "NODES":
            graph = modifier.node_group
            if graph is None or len(graph.nodes) > 17 or len(graph.links) > 33:
                raise ValueError("Geometry Nodes exceed the fixed live evaluation budget")
            definitions, links, output = [], [], None
            native_types = OPS.catalog()["geometry_nodes"]["properties"]["nodes"]["items"]["properties"]["type"]["enum"]
            for node in graph.nodes:
                if node.bl_idname == "NodeGroupOutput":
                    if output is not None:
                        raise ValueError("Multiple Geometry Nodes outputs are unsupported")
                    output = node
                elif node.bl_idname in native_types:
                    definitions.append({"name": node.name, "type": node.bl_idname})
                else:
                    raise ValueError("The live mesh uses unsupported Geometry Nodes")
            final = None
            for link in graph.links:
                if link.to_node == output:
                    if final is not None:
                        raise ValueError("Multiple geometry output links are unsupported")
                    final = link.from_node.name
                else:
                    links.append({"from": link.from_node.name, "to": link.to_node.name,
                                  "output": list(link.from_node.outputs).index(link.from_socket),
                                  "input": list(link.to_node.inputs).index(link.to_socket)})
            if output is None or final is None:
                raise ValueError("The live Geometry Nodes output is unavailable")
            count = max(count, OPS.graph_budget({"nodes": definitions, "links": links, "output": final}))
        elif modifier.type == "SUBSURF":
            if max(modifier.levels, modifier.render_levels) > 3:
                raise ValueError("Live subdivision exceeds three levels")
            count *= 4 ** max(modifier.levels, modifier.render_levels)
        elif modifier.type == "MIRROR":
            count *= 2 ** sum(modifier.use_axis)
        elif modifier.type == "SOLIDIFY":
            count *= 2
        elif modifier.type == "BEVEL":
            if modifier.segments > 6:
                raise ValueError("Live bevel exceeds its segment budget")
            count *= 4 + 6 * modifier.segments
        elif modifier.type == "BOOLEAN":
            target = modifier.object
            if target is None or target not in SCENE.objects.values() or target.type != "MESH" or len(target.data.polygons) + len(value.data.polygons) > 20000:
                raise ValueError("Live Boolean evaluation exceeds its target/geometry budget")
            count += len(target.data.vertices)
        elif modifier.type == "CLOTH" and (len(value.data.vertices) > 5000 or modifier.settings.quality > 5):
            raise ValueError("Live cloth exceeds its fixed simulation budget")
    return count


def scene_object(name, kind=None):
    value = SCENE.objects.get(name)
    if value is None or (kind and value.type != kind):
        raise ValueError("The reviewed live-scene object is unavailable")
    return value


def snapshot():
    preflight()
    bpy.context.view_layer.update()
    digest = hashlib.sha256()
    deadline = time.monotonic() + 1.0
    work = 0

    def add(value):
        nonlocal work
        work += 1
        if work > 250000 or time.monotonic() > deadline:
            raise ValueError("Live-state inspection exceeded its work budget")
        digest.update(json.dumps(value, allow_nan=False, separators=(",", ":")).encode())

    def floats(collection, field, count):
        if count > 1200000:
            raise ValueError("Live-state geometry inspection exceeded its budget")
        values = array.array("f", [0]) * count
        collection.foreach_get(field, values)
        if not all(math.isfinite(v) for v in values):
            raise ValueError("Live geometry contains non-finite values")
        digest.update(values.tobytes())

    records = []
    add([TOKEN, EPOCH, SCENE.as_pointer(), SCENE.name, DOCUMENT, SCENE.frame_current,
         SCENE.frame_start, SCENE.frame_end, SCENE.render.fps])
    for value in sorted(SCENE.objects, key=lambda item: item.name):
        record = {"name": value.name, "type": value.type, "location": list(value.location),
                  "rotation": [math.degrees(v) for v in value.rotation_euler], "scale": list(value.scale),
                  "parent": value.parent.name if value.parent else ""}
        add([value.as_pointer(), record, list(value.rotation_quaternion), value.rotation_mode,
             [list(row) for row in value.matrix_parent_inverse], value.hide_render, value.hide_viewport])
        for mod in value.modifiers:
            add([mod.as_pointer(), mod.name, mod.type, mod.show_viewport, mod.show_render])
        for constraint in value.constraints:
            add([constraint.as_pointer(), constraint.name, constraint.type, constraint.influence])
        if value.type == "MESH":
            mesh = value.data
            record.update(vertices=len(mesh.vertices), polygons=len(mesh.polygons),
                          materials=[m.name for m in mesh.materials if m])
            add([mesh.as_pointer(), record["materials"]])
            floats(mesh.vertices, "co", len(mesh.vertices) * 3)
            indices = array.array("i", [0]) * len(mesh.loops)
            mesh.loops.foreach_get("vertex_index", indices)
            digest.update(indices.tobytes())
            for polygon in mesh.polygons:
                add([polygon.loop_start, polygon.loop_total, polygon.material_index, polygon.use_smooth])
            for layer in mesh.uv_layers:
                add(layer.name)
                floats(layer.data, "uv", len(layer.data) * 2)
            if mesh.shape_keys:
                for key in mesh.shape_keys.key_blocks:
                    add([key.name, key.value])
                    floats(key.data, "co", len(key.data) * 3)
        elif value.type == "ARMATURE":
            record["bones"] = [bone.name for bone in value.data.bones]
            for bone in value.data.bones:
                add([bone.name, bone.parent.name if bone.parent else "", list(bone.head_local), list(bone.tail_local)])
            for bone in value.pose.bones:
                add([bone.name, list(bone.location), list(bone.rotation_quaternion), list(bone.rotation_euler), list(bone.scale)])
        records.append(record)
    for material in bpy.data.materials:
        add([material.as_pointer(), material.name, list(material.diffuse_color), material.use_nodes])
        if material.node_tree:
            if len(material.node_tree.nodes) > 128 or len(material.node_tree.links) > 256:
                raise ValueError("Material inspection exceeds its node budget")
            for node in material.node_tree.nodes:
                add([node.as_pointer(), node.bl_idname, node.name])
                if node.type == "BSDF_PRINCIPLED":
                    for name in ("Base Color", "Metallic", "Roughness", "Emission Color", "Emission Strength"):
                        v = node.inputs[name].default_value
                        add(list(v) if hasattr(v, "__len__") else v)
    key_count = 0
    for action in bpy.data.actions:
        add([action.as_pointer(), action.name])
        curves = list(getattr(action, "fcurves", []))
        for layer in getattr(action, "layers", []):
            for strip in layer.strips:
                for bag in getattr(strip, "channelbags", []):
                    curves.extend(bag.fcurves)
        for curve in curves:
            key_count += len(curve.keyframe_points)
            if key_count > 10000:
                raise ValueError("Animation inspection exceeds its key budget")
            add([curve.data_path, curve.array_index])
            for key in curve.keyframe_points:
                add([list(key.co), list(key.handle_left), list(key.handle_right), key.interpolation])
    return {"revision": REVISION, "sha256": digest.hexdigest(), "live_token": TOKEN,
            "scene": SCENE.name, "document": Path(DOCUMENT).name if DOCUMENT else "Unsaved Blender document",
            "dirty": bpy.data.is_dirty, "blender_version": bpy.app.version_string,
            "objects": records, "actions": [a.name for a in bpy.data.actions],
            "frame_start": SCENE.frame_start, "frame_end": SCENE.frame_end, "fps": SCENE.render.fps}


def checkpoint():
    global CHECKPOINTS
    if CHECKPOINTS >= 128:
        raise ValueError("Enable a fresh live-authoring session after 128 recovery copies")
    name = "checkpoint-" + uuid.uuid4().hex + ".blend"
    path = ROOT / name
    original, dirty = bpy.data.filepath, bpy.data.is_dirty
    bpy.ops.wm.save_as_mainfile(filepath=str(path), check_existing=False, copy=True)
    checksum = OPS.digest(path)
    if bpy.data.filepath != original or bpy.data.is_dirty != dirty:
        raise ValueError("Blender did not preserve the live document's save state")
    receipt = path.with_suffix(".json")
    with receipt.open("x", encoding="utf-8") as file:
        json.dump({"version": 1, "file": name, "sha256": checksum, "revision": REVISION}, file)
        file.flush()
        os.fsync(file.fileno())
    CHECKPOINTS += 1
    return {"file": name, "sha256": checksum}


def preserve_context():
    return ([value.name for value in bpy.context.selected_objects],
            bpy.context.view_layer.objects.active.name if bpy.context.view_layer.objects.active else "",
            SCENE.frame_current, SCENE.render.engine,
            (SCENE.cycles.device, SCENE.cycles.samples) if hasattr(SCENE, "cycles") else None)


def restore_context(saved):
    selected, active, frame, engine, cycles = saved
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    for value in SCENE.objects:
        value.select_set(value.name in selected)
    bpy.context.view_layer.objects.active = SCENE.objects.get(active)
    SCENE.frame_set(frame)
    SCENE.render.engine = engine
    if cycles is not None:
        SCENE.cycles.device, SCENE.cycles.samples = cycles
    bpy.context.view_layer.update()


def edit_body(commands):
    global REVISION, EDIT_RESULT, UNDO_BASELINE
    recovery = checkpoint()
    completed = 0
    saved = preserve_context()
    try:
        for original in commands:
            command = dict(original)
            op = command["op"]
            if op not in SUPPORTED:
                raise ValueError("Unsupported live-authoring command")
            names = command.get("objects", []) if op == "join" else [command["name"]] if op not in ("primitive", "mesh", "armature", "curve", "light", "camera") else []
            for name in names:
                value = scene_object(name)
                if value.data and value.data.users > 1 and op not in ("transform", "delete", "constraint", "keyframes", "bake_animation"):
                    value.data = value.data.copy()
            if op == "material":
                material = bpy.data.materials.get(command["material"])
                if material and material.users > 1:
                    command["material"] = material.copy().name
            if op == "keyframes":
                action = bpy.data.actions.get(command["action"])
                owner = scene_object(command["name"])
                if action and any(v != owner and v.animation_data and (v.animation_data.action == action or any(s.action == action for t in v.animation_data.nla_tracks for s in t.strips)) for v in bpy.data.objects):
                    command["action"] = action.copy().name
            if op == "join" and bpy.data.objects.get(command["name"]) and command["name"] not in names:
                raise ValueError("The joined-object name conflicts with existing artwork")
            OPS.apply_command(command)
            completed += 1
            preflight()
        restore_context(saved)
        REVISION += 1
        state = snapshot()
        UNDO_BASELINE = state["sha256"]
        EDIT_RESULT = {"ok": True, "data": state, "recovery": recovery, "save_pending": True}
    except Exception as error:
        restore_context(saved)
        REVISION += 1
        EDIT_RESULT = {"ok": False, "message": str(error)[:240] if isinstance(error, ValueError) else "A native live edit failed",
                       "completed_commands": completed, "uncertain": True, "recovery": recovery}


def start(root, token, hashes):
    global ROOT, TOKEN, SCENE, DOCUMENT, OPS, OPERATOR, HASHES
    if bpy.app.background or not bpy.context.preferences.edit.use_global_undo:
        raise ValueError("Live authoring requires an interactive Blender session with native Undo enabled")
    if bpy.app.version < (5, 2, 0):
        raise ValueError("Live authoring requires Blender 5.2 or newer")
    ROOT = Path(root)
    if not ROOT.is_absolute() or ROOT.resolve() != ROOT or not ROOT.is_dir():
        raise ValueError("The private live-authoring cache is unavailable")
    TOKEN, SCENE, DOCUMENT = token, bpy.context.scene, bpy.data.filepath
    HASHES = dict(hashes)
    contract = types.ModuleType("_orca_contract_" + token)
    contract_path = Path(__file__).with_name("workspace_contract.py")
    exec(compile(trusted_source(contract_path, hashes["workspace_contract.py"]), str(contract_path), "exec"), contract.__dict__)
    OPS = types.ModuleType("_orca_ops_" + token)
    ops_path = Path(__file__).with_name("workspace_connector.py")
    OPS.__file__ = str(ops_path)
    previous = sys.modules.get("workspace_contract")
    sys.modules["workspace_contract"] = contract
    try:
        exec(compile(trusted_source(ops_path, hashes["workspace_connector.py"]), str(ops_path), "exec"), OPS.__dict__)
    finally:
        if previous is None:
            sys.modules.pop("workspace_contract", None)
        else:
            sys.modules["workspace_contract"] = previous
    OPS.ROOT = ROOT
    OPS.obj = scene_object
    OPS.mesh_budget = mesh_budget
    preflight()
    # An explicit new Enable replaces the previous Orca authoring session in
    # this Blender process, including orphaned helpers after an editor crash.
    # No registry record can authorize a dispatch or survive as model authority.
    prior = sys.modules.get("_orca_live_authoring_owner")
    if prior is not None:
        prior.close()
    owner = types.ModuleType("_orca_live_authoring_owner")
    owner.close = close
    sys.modules[owner.__name__] = owner
    for handlers, callback in (
        (bpy.app.handlers.depsgraph_update_post, changed),
        (bpy.app.handlers.undo_post, undo_changed), (bpy.app.handlers.redo_post, undo_changed),
        (bpy.app.handlers.load_post, loaded),
    ):
        handlers.append(callback)

    class LiveOperation(bpy.types.Operator):
        bl_idname = "orca.live_" + token
        bl_label = "Orca live asset edit"
        bl_options = {"UNDO", "INTERNAL"}

        def execute(self, _context):
            edit_body(PENDING)
            return {"FINISHED"}

    OPERATOR = LiveOperation
    bpy.utils.register_class(OPERATOR)
    encoded = json.dumps(contract.catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {"ok": True, "data": snapshot(), "catalog_sha256": hashlib.sha256(encoded.encode()).hexdigest()}


def command_catalog():
    """Pinned local schemas, kept separate from potentially large live state."""
    return {"ok": True, "catalog_json": json.dumps(OPS.catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)}


def dispatch(arguments):
    global BUSY, PENDING, EDIT_RESULT, REVOKED, UNDO_BASELINE
    if BUSY or not isinstance(arguments, dict) or set(arguments) - {"operation", "revision", "sha256", "commands", "objects"}:
        return {"ok": False, "message": "Unsupported or concurrent live operation"}
    operation = arguments.get("operation")
    recovery = None
    mutation_started = False
    try:
        state = snapshot()
        if operation == "inspect":
            return {"ok": True, "data": state}
        if arguments.get("revision") != REVISION or arguments.get("sha256") != state["sha256"]:
            raise ValueError("The live Blender baseline changed; inspect and review again")
        if operation not in ("edit", "preview", "export", "undo"):
            raise ValueError("Unsupported live operation")
        BUSY = True
        if operation == "edit":
            if REVISION >= 128:
                raise ValueError("Enable a fresh authoring session after 128 edits")
            commands = OPS.parse_commands(arguments.get("commands"))
            if any(c["op"] not in SUPPORTED for c in commands):
                raise ValueError("This operation is not part of the live-authoring contract")
            PENDING, EDIT_RESULT = commands, None
            # Establish the exact pre-operation live state, including earlier unsaved work.
            bpy.ops.ed.undo_push(message="Before Orca live asset edit")
            mutation_started = True
            getattr(bpy.ops.orca, "live_" + TOKEN)("EXEC_DEFAULT", True)
            result = EDIT_RESULT
            if not result or not result.get("ok"):
                REVOKED = True
            else:
                result["data"] = snapshot()
                result["save_pending"] = bpy.data.is_dirty
                UNDO_BASELINE = result["data"]["sha256"]
            return result or {"ok": False, "message": "The live edit returned no receipt", "uncertain": True}
        if operation == "undo":
            if UNDO_BASELINE != state["sha256"]:
                raise ValueError("Newer live changes prevent undoing this Orca edit")
            bpy.ops.ed.undo()
            # Undo restores Blender IDs. Old live references must never be reused.
            REVOKED = True
            return {"ok": True, "data": {"authoring_revoked": True}}
        names = arguments.get("objects")
        if not isinstance(names, list) or not 1 <= len(names) <= 16 or any(type(n) is not str for n in names) or len(set(names)) != len(names):
            raise ValueError("Select one to sixteen exact live-scene objects for preview/export")
        values = [scene_object(name) for name in names]
        for value in values:
            if value.parent and value.parent not in values:
                raise ValueError("Include the asset's parent/rig in the preview/export selection")
            for modifier in value.modifiers:
                if modifier.type == "ARMATURE" and modifier.object not in values:
                    raise ValueError("Include the asset's armature in the preview/export selection")
                if modifier.type == "BOOLEAN" and modifier.object not in values:
                    raise ValueError("Include the Boolean target in the preview/export selection")
            constraints = list(value.constraints)
            if value.type == "ARMATURE":
                constraints.extend(c for bone in value.pose.bones for c in bone.constraints)
            if any(getattr(c, "target", None) is not None and c.target not in values for c in constraints):
                raise ValueError("Include the asset's constraint targets in the handoff selection")
        # Live scene overrides are unsafe for native glTF skin export. A fixed,
        # bounded owned worker evaluates only a private script-free saved copy.
        # It never imports/reloads/saves over the interactive document.
        worker = Path(__file__).with_name("live_export.py")
        trusted_source(worker, HASHES["live_export.py"])
        recovery = checkpoint()
        receipt = ROOT / ("handoff-" + uuid.uuid4().hex + ".json")
        payload = {"source": recovery["file"], "source_sha256": recovery["sha256"],
                   "scene": SCENE.name, "objects": names, "operation": operation,
                   "revision": REVISION, "hashes": HASHES, "receipt": receipt.name}
        try:
            mutation_started = True
            subprocess.run([bpy.app.binary_path, "--quiet", "--background", "--factory-startup",
                            "--disable-autoexec", "--offline-mode", "--threads", "2",
                            "--python-exit-code", "2", "--python", str(worker), "--", str(ROOT), json.dumps(payload)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=25, check=True)
        except (subprocess.SubprocessError, OSError):
            raise ValueError("The owned preview/export worker failed or exceeded its time budget")
        if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_size > 32768:
            raise ValueError("Invalid native asset-handoff receipt")
        result = json.loads(receipt.read_text(encoding="utf-8"))
        if result.get("ok") is not True:
            raise ValueError("The native preview/export worker did not complete")
        data = result["data"]
        return {"ok": True, "data": data, "baseline": snapshot()}
    except Exception as error:
        return {"ok": False, "message": str(error)[:240] if isinstance(error, ValueError) else "The native live operation failed",
                "uncertain": mutation_started, "authoring_revoked": REVOKED, "recovery": recovery}
    finally:
        BUSY = False
        PENDING = None
