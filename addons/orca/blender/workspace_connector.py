"""Orca-owned Blender workspace MCP peer, run with Blender's bundled Python.

This independently implemented toolkit accepts declarative native operations, not
Python supplied by a model. It edits only an owned workspace and saves immutable
revisions. It is a constrained tool contract, not an OS execution sandbox.
"""

import hashlib
import json
import math
import os
from pathlib import Path
import sys
import uuid

import bpy
import bmesh
from mathutils import Vector

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    sys.dont_write_bytecode = True
from workspace_contract import catalog, parse_commands

MAX_FILE = 32 * 1024 * 1024
MAX_VERTICES = 100000
MAX_POLYGONS = 200000
MAX_OBJECTS = 128

ROOT = None
REVISION = 0
CURRENT = None
HASH = ""


def initialize():
    """User-owned workspace startup. Importing helpers never launches/resets/saves."""
    global OUT, IN, ROOT, LEASE
    # Preserve just the MCP output pipe; drain native status output on stderr.
    OUT = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    IN = os.fdopen(0, "rb", closefd=False)
    args = sys.argv[sys.argv.index("--") + 1:]
    if len(args) != 2 or args[0] != "--workspace":
        raise RuntimeError("Invalid trusted connector arguments")
    ROOT = Path(args[1])
    if not ROOT.is_absolute() or ROOT.resolve() != ROOT or not ROOT.is_dir():
        raise RuntimeError("Workspace must be a real absolute directory")
    lock_path = ROOT / "workspace.lock"
    if lock_path.is_symlink(): raise RuntimeError("Invalid workspace lease")
    LEASE = lock_path.open("a+b")
    if os.name == "nt":
        import msvcrt
        if LEASE.seek(0, 2) == 0:
            LEASE.write(b"0")
            LEASE.flush()
        LEASE.seek(0)
        msvcrt.locking(LEASE.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(LEASE.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    # The OS releases this exclusive lease on exit/kill, including wrapped builds.
    resume()


def digest(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_FILE:
        raise ValueError("Invalid or oversized workspace artifact")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checkpoint():
    global REVISION, CURRENT, HASH
    next_revision = REVISION + 1
    target = ROOT / f"revision-{next_revision:06d}.blend"
    receipt = ROOT / f"revision-{next_revision:06d}.json"
    if target.exists() or receipt.exists():
        raise ValueError("An immutable workspace revision already exists")
    bpy.ops.wm.save_as_mainfile(filepath=str(target), check_existing=False, copy=True)
    checksum = digest(target)
    # A receipt is durable before the edit can be reported as completed. Only
    # connector-owned filenames are written; no caller controls paths.
    with receipt.open("x", encoding="utf-8") as file:
        json.dump({"version": 1, "revision": next_revision, "file": target.name, "sha256": checksum}, file)
        file.flush()
        os.fsync(file.fileno())
    REVISION, CURRENT, HASH = next_revision, target, checksum


def resume():
    global REVISION, CURRENT, HASH
    receipts = sorted(ROOT.glob("revision-*.json"))
    if len(receipts) > 128:
        raise ValueError("Workspace revision limit reached; start a new asset")
    if receipts:
        receipt = receipts[-1]
        if receipt.is_symlink() or receipt.stat().st_size > 1024:
            raise ValueError("Invalid workspace recovery receipt")
        state = json.loads(receipt.read_text(encoding="utf-8"))
        revision = state.get("revision")
        if type(revision) is not int or not 1 <= revision <= 128 or state.get("file") != f"revision-{revision:06d}.blend":
            raise ValueError("Invalid workspace revision identity")
        path = ROOT / state["file"]
        if digest(path) != state.get("sha256"):
            raise ValueError("Saved workspace bytes changed; preserve them and start a new asset")
        bpy.ops.wm.open_mainfile(filepath=str(path), load_ui=False, use_scripts=False)
        REVISION, CURRENT, HASH = revision, path, state["sha256"]
    else:
        template = ROOT / "template.blend"
        if template.exists():
            receipt = ROOT / "template.json"
            if receipt.is_symlink() or receipt.stat().st_size > 1024 or digest(template) != json.loads(receipt.read_text(encoding="utf-8")).get("sha256"): raise ValueError("Template copy changed")
            bpy.ops.wm.open_mainfile(filepath=str(template), load_ui=False, use_scripts=False)
            if bpy.data.libraries or bpy.data.texts or any(value.animation_data and value.animation_data.drivers for value in bpy.data.objects): raise ValueError("Templates with linked libraries, embedded scripts or drivers need a separate trust workflow")
            summary()
        else:
            for obj in list(bpy.data.objects):
                bpy.data.objects.remove(obj, do_unlink=True)
        checkpoint()


def select(obj):
    if bpy.context.object is not None and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def obj(name, kind=None):
    value = bpy.data.objects.get(name)
    if value is None or (kind is not None and value.type != kind):
        raise ValueError(f"Missing workspace {kind or 'object'}: {name}")
    return value


def unique(name):
    if bpy.data.objects.get(name) is not None:
        raise ValueError(f"Object already exists: {name}")


def transform(value, command):
    if "location" in command:
        value.location = command["location"]
    if "rotation" in command:
        value.rotation_mode = "XYZ"
        value.rotation_euler = [math.radians(n) for n in command["rotation"]]
    if "scale" in command:
        value.scale = command["scale"]


def linked(name, data, command):
    unique(name)
    value = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(value)
    transform(value, command)
    return value


def graph_budget(command):
    definitions = {node["name"]: node["type"] for node in command["nodes"]}
    incoming = {name: [] for name in definitions}
    for link in command["links"]:
        if link["from"] not in definitions or link["to"] not in definitions: raise ValueError("Unknown Geometry Nodes link")
        incoming[link["to"]].append(link)
    memo = {}
    def count(name, visiting):
        if name in visiting: raise ValueError("Geometry Nodes cycles are unsupported")
        if name in memo: return memo[name]
        kind = definitions[name]
        primitive = {"GeometryNodeMeshCube": 8, "GeometryNodeMeshUVSphere": 2048, "GeometryNodeMeshIcoSphere": 642, "GeometryNodeMeshCylinder": 512, "GeometryNodeMeshCone": 512}
        inputs = [(link["input"], count(link["from"], visiting | {name})) for link in incoming[name]]
        if kind in primitive: value = primitive[kind]
        elif kind == "GeometryNodeJoinGeometry": value = sum(n for _, n in inputs)
        elif kind == "GeometryNodeInstanceOnPoints": value = max((n for socket, n in inputs if socket == 0), default=0) * max((n for socket, n in inputs if socket == 2), default=0)
        else: value = max((n for _, n in inputs), default=0)
        if value > MAX_VERTICES: raise ValueError("Geometry Nodes output exceeds its estimated geometry budget")
        memo[name] = value
        return value
    if command["output"] not in definitions: raise ValueError("Invalid graph output")
    return count(command["output"], set())


def mesh_budget(value):
    count = max(len(value.data.vertices), int(value.get("_orca_geometry_budget", 0)))
    for modifier in value.modifiers:
        if modifier.type == "SUBSURF": count *= 4 ** max(modifier.levels, modifier.render_levels)
        elif modifier.type in {"MIRROR", "SOLIDIFY"}: count *= 2
        elif modifier.type == "BEVEL": count *= 4 + 6 * modifier.segments
        elif modifier.type == "BOOLEAN":
            if modifier.object is not None and len(modifier.object.data.polygons) + len(value.data.polygons) > 20000: raise ValueError("Boolean geometry exceeds its budget")
            count += len(modifier.object.data.vertices) if modifier.object else 0
    return count


def apply_command(c):
    op = c["op"]
    if op == "reset":
        for value in list(bpy.data.objects):
            bpy.data.objects.remove(value, do_unlink=True)
        bpy.context.scene.name = c.get("name", "Orca Asset")
    elif op == "primitive":
        unique(c["name"])
        n, radius = c.get("segments", 24), c.get("radius", 1)
        if c["kind"] == "cube": bpy.ops.mesh.primitive_cube_add(size=2 * radius)
        elif c["kind"] == "plane": bpy.ops.mesh.primitive_plane_add(size=2 * radius)
        elif c["kind"] == "sphere": bpy.ops.mesh.primitive_uv_sphere_add(segments=n, ring_count=max(3, n // 2), radius=radius)
        elif c["kind"] == "icosphere": bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=min(4, max(1, n // 12)), radius=radius)
        elif c["kind"] == "cylinder": bpy.ops.mesh.primitive_cylinder_add(vertices=n, radius=radius)
        elif c["kind"] == "cone": bpy.ops.mesh.primitive_cone_add(vertices=n, radius1=radius)
        elif c["kind"] == "torus": bpy.ops.mesh.primitive_torus_add(major_segments=n, minor_segments=max(3, n // 2), major_radius=radius, minor_radius=radius / 4)
        value = bpy.context.object
        value.name = c["name"]
        transform(value, c)
    elif op == "mesh":
        unique(c["name"])
        if any(index >= len(c["vertices"]) for face in c["faces"] for index in face):
            raise ValueError("Mesh face index is outside its vertex array")
        data = bpy.data.meshes.new(c["name"])
        data.from_pydata(c["vertices"], [], c["faces"])
        data.validate()
        data.update()
        linked(c["name"], data, c)
    elif op == "transform": transform(obj(c["name"]), c)
    elif op == "mesh_edit":
        value = obj(c["name"], "MESH")
        if value.data.shape_keys: raise ValueError("Mesh topology edits require a mesh without shape keys")
        mesh = bmesh.new()
        try:
            mesh.from_mesh(value.data)
            mesh.faces.ensure_lookup_table()
            mesh.verts.ensure_lookup_table()
            if any(i >= len(mesh.faces) for i in c.get("faces", [])) or any(i >= len(mesh.verts) for i in c.get("vertices", [])): raise ValueError("Mesh element index is outside its current geometry")
            faces = [mesh.faces[i] for i in c["faces"]] if "faces" in c else list(mesh.faces)
            verts = [mesh.verts[i] for i in c["vertices"]] if "vertices" in c else list(mesh.verts)
            kind = c["kind"]
            if kind == "extrude":
                result = bmesh.ops.extrude_face_region(mesh, geom=faces)
                bmesh.ops.translate(mesh, verts=[v for v in result["geom"] if isinstance(v, bmesh.types.BMVert)], vec=Vector(c.get("offset", [0, 0, c.get("amount", 0.2)])))
            elif kind == "inset": bmesh.ops.inset_region(mesh, faces=faces, thickness=max(0.001, c.get("amount", 0.1)), depth=0)
            elif kind == "subdivide":
                if len(mesh.faces) * (c.get("cuts", 1) + 1) ** 2 > MAX_POLYGONS: raise ValueError("Subdivision exceeds mesh budget")
                bmesh.ops.subdivide_edges(mesh, edges=list(mesh.edges), cuts=c.get("cuts", 1), use_grid_fill=True)
            elif kind == "merge_by_distance": bmesh.ops.remove_doubles(mesh, verts=verts, dist=max(0.00001, c.get("amount", 0.001)))
            elif kind == "recalculate_normals": bmesh.ops.recalc_face_normals(mesh, faces=faces)
            elif kind == "reverse_faces": bmesh.ops.reverse_faces(mesh, faces=faces)
            elif kind == "smooth": bmesh.ops.smooth_vert(mesh, verts=verts, factor=max(0, min(1, c.get("amount", 0.5))), use_axis_x=True, use_axis_y=True, use_axis_z=True)
            if len(mesh.verts) > MAX_VERTICES or len(mesh.faces) > MAX_POLYGONS: raise ValueError("Mesh operation exceeds geometry budget")
            mesh.to_mesh(value.data)
            value.data.update()
        finally: mesh.free()
    elif op == "delete": bpy.data.objects.remove(obj(c["name"]), do_unlink=True)
    elif op == "duplicate":
        unique(c["new_name"])
        value = obj(c["name"]).copy()
        if value.data: value.data = value.data.copy()
        value.name = c["new_name"]
        bpy.context.scene.collection.objects.link(value)
        transform(value, c)
    elif op in {"collider", "lod"}:
        unique(c["new_name"])
        source = obj(c["name"], "MESH")
        if mesh_budget(source) > MAX_VERTICES: raise ValueError("Evaluated mesh exceeds its budget")
        graph = bpy.context.evaluated_depsgraph_get()
        mesh = bpy.data.meshes.new_from_object(source.evaluated_get(graph), depsgraph=graph)
        value = linked(c["new_name"], mesh, {})
        value.matrix_world = source.matrix_world.copy()
        if op == "lod":
            select(value)
            modifier = value.modifiers.new("Orca LOD", "DECIMATE")
            modifier.ratio = max(0.01, c["ratio"])
            bpy.ops.object.modifier_apply(modifier=modifier.name)
    elif op == "rigid_body":
        value = obj(c["name"], "MESH")
        select(value)
        if value.rigid_body is None: bpy.ops.rigidbody.object_add()
        value.rigid_body.type = c["kind"]
        value.rigid_body.mass = c.get("mass", 1)
        value.rigid_body.friction, value.rigid_body.restitution = c.get("friction", 0.5), c.get("restitution", 0)
        bpy.context.scene.rigidbody_world.point_cache.use_disk_cache = False
    elif op == "cloth":
        value = obj(c["name"], "MESH")
        if len(value.data.vertices) > 5000: raise ValueError("Cloth mesh exceeds its simulation budget")
        modifier = value.modifiers.new("Orca Cloth", "CLOTH")
        modifier.settings.quality = c.get("quality", 2)
        modifier.point_cache.use_disk_cache = False
    elif op == "join":
        values = [obj(name, "MESH") for name in c["objects"]]
        select(values[0])
        for value in values: value.select_set(True)
        bpy.ops.object.join()
        values[0].name = c["name"]
    elif op == "modifier":
        value = obj(c["name"], "MESH")
        select(value)
        types = {"bevel": "BEVEL", "subdivision": "SUBSURF", "mirror": "MIRROR", "solidify": "SOLIDIFY", "decimate": "DECIMATE", "boolean": "BOOLEAN", "triangulate": "TRIANGULATE"}
        mod = value.modifiers.new("Orca " + c["kind"], types[c["kind"]])
        if c["kind"] == "bevel": mod.width, mod.segments = max(0, c.get("amount", 0.1)), c.get("segments", 2)
        elif c["kind"] == "subdivision":
            levels = min(3, c.get("segments", 1))
            if len(value.data.polygons) * 4 ** levels > MAX_POLYGONS: raise ValueError("Subdivision exceeds polygon budget")
            mod.levels = mod.render_levels = levels
        elif c["kind"] == "solidify": mod.thickness = c.get("amount", 0.1)
        elif c["kind"] == "decimate": mod.ratio = max(0.01, min(1, c.get("amount", 0.5)))
        elif c["kind"] == "boolean":
            if "target" not in c: raise ValueError("Boolean needs a target object")
            mod.object, mod.operation = obj(c["target"], "MESH"), "DIFFERENCE"
        if c.get("apply", False): bpy.ops.object.modifier_apply(modifier=mod.name)
    elif op == "material":
        value = obj(c["name"], "MESH")
        material = bpy.data.materials.get(c["material"]) or bpy.data.materials.new(c["material"])
        if any(other != value and other.type == "MESH" and material in list(other.data.materials) for other in bpy.context.scene.objects): material = material.copy()
        material.use_nodes = True
        shader = next(node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
        if "color" in c: shader.inputs["Base Color"].default_value = c["color"]
        if "metallic" in c: shader.inputs["Metallic"].default_value = c["metallic"]
        if "roughness" in c: shader.inputs["Roughness"].default_value = c["roughness"]
        if "emission" in c:
            shader.inputs["Emission Color"].default_value = c["emission"]
            shader.inputs["Emission Strength"].default_value = 1
        value.data.materials.clear()
        value.data.materials.append(material)
    elif op == "texture":
        value = obj(c["name"], "MESH")
        texture_id = c["texture_id"]
        if len(texture_id) != 64 or any(n not in "0123456789abcdef" for n in texture_id): raise ValueError("Invalid user texture identity")
        path = ROOT / ("texture-" + texture_id + ".png")
        if digest(path) != texture_id: raise ValueError("Attached texture changed or is unavailable")
        if not value.data.materials: raise ValueError("Assign a material before its texture")
        material = value.data.materials[0]
        if material.users > 1:
            material = material.copy()
            value.data.materials[0] = material
        shader = next(n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
        image = bpy.data.images.load(str(path), check_existing=True)
        image.pack()
        image_node = material.node_tree.nodes.new("ShaderNodeTexImage")
        image_node.image = image
        if c["kind"] == "normal":
            image.colorspace_settings.name = "Non-Color"
            normal = material.node_tree.nodes.new("ShaderNodeNormalMap")
            material.node_tree.links.new(image_node.outputs["Color"], normal.inputs["Color"])
            material.node_tree.links.new(normal.outputs["Normal"], shader.inputs["Normal"])
        else:
            if c["kind"] == "roughness": image.colorspace_settings.name = "Non-Color"
            material.node_tree.links.new(image_node.outputs["Color"], shader.inputs["Base Color" if c["kind"] == "base_color" else "Roughness"])
    elif op == "bake":
        value = obj(c["name"], "MESH")
        if not value.data.uv_layers or not value.data.materials: raise ValueError("Baking requires UVs and a material")
        select(value)
        image = bpy.data.images.new("Orca Bake " + c["kind"], width=512, height=512)
        for slot in value.material_slots:
            if slot.material is None: continue
            slot.material = slot.material.copy()
            node = slot.material.node_tree.nodes.new("ShaderNodeTexImage")
            node.image = image
            slot.material.node_tree.nodes.active = node
        bpy.context.scene.render.engine = "CYCLES"
        bpy.context.scene.cycles.device, bpy.context.scene.cycles.samples = "CPU", 8
        bpy.ops.object.bake(type=c["kind"], pass_filter={"COLOR"} if c["kind"] == "DIFFUSE" else set())
        image.pack()
    elif op == "uv_unwrap":
        select(obj(c["name"], "MESH"))
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.smart_project()
        bpy.ops.object.mode_set(mode="OBJECT")
    elif op == "armature":
        data = bpy.data.armatures.new(c["name"])
        value = linked(c["name"], data, c)
        select(value)
        bpy.ops.object.mode_set(mode="EDIT")
        for bone in c["bones"]:
            if data.edit_bones.get(bone["name"]): raise ValueError("Duplicate bone name")
            if Vector(bone["head"]) == Vector(bone["tail"]): raise ValueError("Bone needs nonzero length")
            edit = data.edit_bones.new(bone["name"])
            edit.head, edit.tail = bone["head"], bone["tail"]
        for bone in c["bones"]:
            if "parent" in bone:
                parent = data.edit_bones.get(bone["parent"])
                if parent is None or parent.name == bone["name"]: raise ValueError("Invalid bone parent")
                cursor = parent
                for _ in range(65):
                    if cursor is None: break
                    if cursor.name == bone["name"]: raise ValueError("Bone parent cycle")
                    cursor = cursor.parent
                edit = data.edit_bones[bone["name"]]
                edit.parent, edit.use_connect = parent, bone.get("connected", False)
        bpy.ops.object.mode_set(mode="OBJECT")
    elif op == "skin":
        mesh, rig = obj(c["name"], "MESH"), obj(c["armature"], "ARMATURE")
        select(rig)
        mesh.select_set(True)
        if c.get("automatic", False): bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        else:
            mesh.parent = rig
            mod = mesh.modifiers.new("Orca Skin", "ARMATURE")
            mod.object = rig
        for weight in c.get("weights", []):
            if weight["vertex"] >= len(mesh.data.vertices) or rig.data.bones.get(weight["bone"]) is None: raise ValueError("Invalid skin weight target")
            group = mesh.vertex_groups.get(weight["bone"]) or mesh.vertex_groups.new(name=weight["bone"])
            group.add([weight["vertex"]], weight["weight"], "REPLACE")
    elif op == "constraint":
        owner = obj(c["name"])
        if "bone" in c:
            if owner.type != "ARMATURE" or owner.pose.bones.get(c["bone"]) is None: raise ValueError("Invalid constraint bone")
            owner = owner.pose.bones[c["bone"]]
        if c["kind"] == "IK" and "bone" not in c: raise ValueError("IK requires a pose bone")
        constraint = owner.constraints.new(c["kind"])
        constraint.target = obj(c["target"])
        if "target_bone" in c: constraint.subtarget = c["target_bone"]
        if c["kind"] == "IK": constraint.chain_count = c.get("chain_length", 2)
    elif op == "keyframes":
        value = obj(c["name"])
        value.animation_data_create()
        action = bpy.data.actions.get(c["action"]) or bpy.data.actions.new(c["action"])
        value.animation_data.action = action
        for key in c["keys"]:
            target = value
            if "bone" in key:
                if value.type != "ARMATURE" or value.pose.bones.get(key["bone"]) is None: raise ValueError("Invalid keyframe bone")
                target = value.pose.bones[key["bone"]]
            transform(target, key)
            for field, data_path in [("location", "location"), ("rotation", "rotation_euler"), ("scale", "scale")]:
                if field in key: target.keyframe_insert(data_path=data_path, frame=key["frame"])
        # Preserve multiple actions for glTF export rather than losing older clips.
        if not any(strip.action == action for track in value.animation_data.nla_tracks for strip in track.strips):
            track = value.animation_data.nla_tracks.new()
            track.name = action.name
            track.strips.new(action.name, int(action.frame_range[0]), action)
            track.mute = True
        action.use_fake_user = True
        curves = list(getattr(action, "fcurves", []))
        for layer in getattr(action, "layers", []):
            for strip in layer.strips:
                for bag in getattr(strip, "channelbags", []): curves.extend(bag.fcurves)
        for curve in curves:
            for key in curve.keyframe_points: key.interpolation = c.get("interpolation", "LINEAR")
    elif op == "shape_key":
        value = obj(c["name"], "MESH")
        if len(c["offsets"]) != len(value.data.vertices): raise ValueError("Shape-key offsets must match all mesh vertices")
        if value.data.shape_keys is None: value.shape_key_add(name="Basis")
        if value.data.shape_keys.key_blocks.get(c["key"]): raise ValueError("Shape key already exists")
        key = value.shape_key_add(name=c["key"])
        for point, offset in zip(key.data, c["offsets"]): point.co += Vector(offset)
        key.value = c.get("value", 0)
    elif op == "bake_animation":
        value = obj(c["name"])
        if c["end"] < c["start"] or c["end"] - c["start"] > 119: raise ValueError("Animation baking supports at most 120 frames")
        select(value)
        bpy.ops.nla.bake(frame_start=c["start"], frame_end=c["end"], step=1, only_selected=False, visual_keying=True, clear_constraints=c.get("clear_constraints", False), use_current_action=False, bake_types={"POSE"} if value.type == "ARMATURE" else {"OBJECT"})
        if value.animation_data is None or value.animation_data.action is None: raise ValueError("Animation baking did not create an action")
        value.animation_data.action.name = c["action"]
        value.animation_data.action.use_fake_user = True
    elif op == "geometry_nodes":
        value = obj(c["name"], "MESH")
        estimate = graph_budget(c)
        graph = bpy.data.node_groups.new("Orca Geometry", "GeometryNodeTree")
        graph.interface.new_socket(name="Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
        output = graph.nodes.new("NodeGroupOutput")
        nodes = {}
        for definition in c["nodes"]:
            if definition["name"] in nodes: raise ValueError("Duplicate Geometry Nodes identity")
            node = graph.nodes.new(definition["type"])
            node.name = definition["name"]
            if "value" in definition:
                socket = next((s for s in node.inputs if s.type == "VECTOR"), None)
                if socket is None: raise ValueError("Node has no vector input")
                socket.default_value = definition["value"]
            nodes[node.name] = node
        for link in c["links"]:
            source, target = nodes.get(link["from"]), nodes.get(link["to"])
            if source is None or target is None or link["output"] >= len(source.outputs) or link["input"] >= len(target.inputs): raise ValueError("Invalid Geometry Nodes link")
            graph.links.new(source.outputs[link["output"]], target.inputs[link["input"]])
        final = nodes.get(c["output"])
        socket = next((s for s in final.outputs if s.type == "GEOMETRY"), None) if final else None
        if socket is None: raise ValueError("Output node needs geometry")
        graph.links.new(socket, output.inputs[0])
        mod = value.modifiers.new("Orca Geometry", "NODES")
        mod.node_group = graph
        value["_orca_geometry_budget"] = estimate
        if c.get("apply", False):
            select(value)
            bpy.ops.object.modifier_apply(modifier=mod.name)
            value["_orca_geometry_budget"] = 0
    elif op == "curve":
        data = bpy.data.curves.new(c["name"], "CURVE")
        data.dimensions, data.bevel_depth = "3D", c.get("radius", 0.02)
        spline = data.splines.new("POLY")
        spline.points.add(len(c["points"]) - 1)
        for point, coord in zip(spline.points, c["points"]): point.co = [*coord, 1]
        value = linked(c["name"], data, c)
        if c.get("convert", False):
            select(value)
            bpy.ops.object.convert(target="MESH")
    elif op == "light":
        data = bpy.data.lights.new(c["name"], c["kind"])
        data.energy, data.color = c.get("energy", 100), c.get("color", [1, 1, 1])
        linked(c["name"], data, c)
    elif op == "camera":
        data = bpy.data.cameras.new(c["name"])
        data.lens = c.get("lens", 50)
        bpy.context.scene.camera = linked(c["name"], data, c)
    elif op == "scene":
        scene = bpy.context.scene
        scene.frame_start, scene.frame_end = c.get("start", scene.frame_start), c.get("end", scene.frame_end)
        if scene.frame_start > scene.frame_end: raise ValueError("Invalid frame range")
        scene.render.fps = c.get("fps", scene.render.fps)
        if "frame" in c: scene.frame_set(c["frame"])


def summary():
    scene = bpy.context.scene
    records = []
    vertices = polygons = bones = 0
    estimated = 0
    for value in sorted(scene.objects, key=lambda o: o.name):
        entry = {"name": value.name, "type": value.type, "location": list(value.location), "rotation": [math.degrees(n) for n in value.rotation_euler], "scale": list(value.scale), "parent": value.parent.name if value.parent else ""}
        if value.type == "MESH":
            entry.update(vertices=len(value.data.vertices), polygons=len(value.data.polygons), materials=[m.name for m in value.data.materials if m])
            vertices += entry["vertices"]
            polygons += entry["polygons"]
            entry["evaluated_vertex_upper_bound"] = mesh_budget(value)
            estimated += entry["evaluated_vertex_upper_bound"]
        if value.type == "ARMATURE":
            entry["bones"] = [bone.name for bone in value.data.bones]
            bones += len(entry["bones"])
        records.append(entry)
    if len(records) > MAX_OBJECTS or vertices > MAX_VERTICES or estimated > MAX_VERTICES or polygons > MAX_POLYGONS or bones > 256 or len(bpy.data.actions) > 64 or len(bpy.data.materials) > 128 or len(bpy.data.node_groups) > 128 or len(bpy.data.images) > 32:
        raise ValueError("Workspace exceeds object/geometry/bone/action budgets")
    return {"revision": REVISION, "sha256": HASH, "blend_file": CURRENT.name if CURRENT else "", "blender_version": bpy.app.version_string, "scene": scene.name, "objects": records, "vertices": vertices, "polygons": polygons, "actions": [a.name for a in bpy.data.actions], "frame_start": scene.frame_start, "frame_end": scene.frame_end, "fps": scene.render.fps}


def preview():
    original = bpy.context.scene
    scene = original.copy()
    scene.name = "Orca Preview"
    made = []
    try:
        points = [value.matrix_world @ Vector(corner) for value in original.objects if value.type == "MESH" for corner in value.bound_box]
        center = sum(points, Vector()) / max(1, len(points))
        radius = max((point - center).length for point in points) if points else 1
        camera_data = bpy.data.cameras.new("Orca Preview Camera")
        camera = bpy.data.objects.new("Orca Preview Camera", camera_data)
        made.append(camera)
        scene.collection.objects.link(camera)
        camera.location = center + Vector((1.5, -2.0, 1.4)) * max(1, radius)
        camera.rotation_euler = (center - camera.location).to_track_quat("-Z", "Y").to_euler()
        scene.camera = camera
        for direction, energy in [((3, -4, 5), 1000), ((-4, -1, 3), 700)]:
            data = bpy.data.lights.new("Orca Preview Light", "AREA")
            data.energy, data.size = energy, max(2, radius * 3)
            light = bpy.data.objects.new("Orca Preview Light", data)
            made.append(light)
            scene.collection.objects.link(light)
            light.location = center + Vector(direction) * max(1, radius)
            light.rotation_euler = (center - light.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.engine = "CYCLES"
        scene.cycles.device, scene.cycles.samples = "CPU", 8
        scene.render.resolution_x = scene.render.resolution_y = 384
        scene.render.resolution_percentage = 100
        scene.render.film_transparent = True
        scene.render.image_settings.file_format = "PNG"
        path = ROOT / ("preview-" + uuid.uuid4().hex + ".png")
        scene.render.filepath = str(path)
        bpy.ops.render.render(write_still=True, scene=scene.name)
        return {"file": path.name, "sha256": digest(path), "revision": REVISION}
    finally:
        bpy.data.scenes.remove(scene)
        for value in made:
            data = value.data
            bpy.data.objects.remove(value, do_unlink=True)
            if isinstance(data, bpy.types.Camera): bpy.data.cameras.remove(data)
            else: bpy.data.lights.remove(data)


def export():
    path = ROOT / ("asset-" + uuid.uuid4().hex + ".glb")
    properties = bpy.ops.export_scene.gltf.get_rna_type().properties
    options = {"filepath": str(path), "export_format": "GLB", "export_yup": True, "export_animations": True, "export_skins": True, "export_morph": True, "export_cameras": True, "export_lights": True}
    if "export_animation_mode" in properties: options["export_animation_mode"] = "ACTIONS"
    if "export_bake_animation" in properties: options["export_bake_animation"] = True
    bpy.ops.export_scene.gltf(**options)
    return {"file": path.name, "sha256": digest(path), "size": path.stat().st_size, "revision": REVISION, "summary": summary(), "conversion_notes": ["Blender physics, cloth, unsupported shaders and simulation behavior are not automatically Godot gameplay components. Bake/convert where supported, then configure and verify Godot behavior."]}


def preview_export():
    """Static evaluated geometry for Orca's native-only viewer, never an import ID."""
    summary()
    path = ROOT / ("preview-model-" + uuid.uuid4().hex + ".glb")
    options = {"filepath": str(path), "export_format": "GLB", "export_yup": True,
               "export_animations": False, "export_skins": False, "export_morph": False,
               "export_apply": True, "export_current_frame": True,
               "export_cameras": False, "export_lights": False, "export_extras": False}
    bpy.ops.export_scene.gltf(**options)
    if path.stat().st_size > 16 * 1024 * 1024:
        path.unlink()
        raise ValueError("Preview geometry exceeds its budget")
    return {"file": path.name, "sha256": digest(path), "revision": REVISION}


def run(operation, arguments):
    if operation == "help":
        if arguments: raise ValueError("Help takes no arguments")
        value = summary()
        return {"catalog_json": json.dumps(catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False), "workspace": {key: value[key] for key in ["revision", "sha256", "blend_file", "blender_version", "scene"]}, "units": "metres", "rotation": "degrees", "max_commands": 16, "max_bytes": 6000}
    if set(arguments) - {"revision", "sha256", "commands", "restore_revision"}: raise ValueError("Unsupported workspace arguments")
    if arguments.get("revision") != REVISION or arguments.get("sha256") != HASH or digest(CURRENT) != HASH:
        raise ValueError("Workspace revision changed; reconnect and review a fresh baseline")
    if operation != "edit" and "commands" in arguments: raise ValueError("Only edit accepts commands")
    if operation != "restore" and "restore_revision" in arguments: raise ValueError("Only explicit restore accepts a revision")
    if operation == "restore":
        previous = arguments.get("restore_revision")
        if type(previous) not in (int, float) or previous != int(previous) or not 1 <= previous < REVISION: raise ValueError("Invalid previous revision")
        path = ROOT / f"revision-{int(previous):06d}.blend"
        receipt = ROOT / f"revision-{int(previous):06d}.json"
        if receipt.is_symlink() or receipt.stat().st_size > 1024: raise ValueError("Invalid recovery receipt")
        saved = json.loads(receipt.read_text(encoding="utf-8"))
        if saved.get("sha256") != digest(path): raise ValueError("Previous revision bytes changed")
        bpy.ops.wm.open_mainfile(filepath=str(path), load_ui=False, use_scripts=False)
        checkpoint()
        return summary()
    if operation == "inspect": return summary()
    if operation == "preview":
        value = preview()
        try:
            value["preview_3d"] = preview_export()
        except Exception:
            # Preserve a successful render even when core geometry cannot export.
            value["preview_3d_unavailable"] = True
        return value
    if operation == "export": return export()
    if operation != "edit": raise ValueError("Unknown fixed workspace operation")
    commands = parse_commands(arguments.get("commands"))
    if REVISION >= 128: raise ValueError("Start a new asset after 128 immutable revisions")
    before = CURRENT
    try:
        for command in commands:
            apply_command(command)
            summary()
        if bpy.context.object is not None and bpy.context.object.mode != "OBJECT": bpy.ops.object.mode_set(mode="OBJECT")
        checkpoint()
        return summary()
    except Exception:
        bpy.ops.wm.open_mainfile(filepath=str(before), load_ui=False, use_scripts=False)
        raise


def send(message):
    data = (json.dumps(message, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
    if len(data) > 120000: raise ValueError("Workspace response exceeds transport budget")
    OUT.write(data)


def main():
    initialize()
    initialized = False
    for line in iter(lambda: IN.readline(8193), b""):
        request_id = None
        try:
            if len(line) > 8192 or not line.endswith(b"\n"): raise ValueError("Invalid request framing")
            request = json.loads(line)
            if request.get("jsonrpc") != "2.0": raise ValueError("Invalid JSON-RPC")
            method, request_id = request.get("method"), request.get("id")
            if method == "notifications/initialized":
                initialized = True
                continue
            if type(request_id) is not int: raise ValueError("Invalid request identity")
            params = request.get("params", {})
            if method == "initialize":
                result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "Orca Blender Workspace", "version": "1"}}
            elif method == "tools/list" and initialized:
                result = {"tools": [{"name": "orca_workspace_" + operation, "inputSchema": {"type": "object"}} for operation in ["help", "inspect", "edit", "preview", "export", "restore"]]}
            elif method == "tools/call" and initialized:
                name = params.get("name", "")
                if name not in ["orca_workspace_" + op for op in ["help", "inspect", "edit", "preview", "export", "restore"]]: raise ValueError("Unsupported tool")
                data = run(name.removeprefix("orca_workspace_"), params.get("arguments", {}))
                result = {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False, allow_nan=False)}]}
            else: raise ValueError("Unsupported client capability")
            send({"jsonrpc": "2.0", "id": request_id, "result": result})
        except Exception as error:
            text = str(error)[:256] if isinstance(error, ValueError) else "Native Blender operation failed; the prior revision was restored."
            if request_id is not None:
                send({"jsonrpc": "2.0", "id": request_id, "result": {"isError": True, "content": [{"type": "text", "text": text}]}})
            else: break


if __name__ == "__main__":
    main()
