"""Independent, declarative Blender asset operations. No executable user expressions."""

import json
import math

MAX_COMMAND_BYTES = 6000
MAX_COMMANDS = 16
NAME = {"type": "string", "minLength": 1, "maxLength": 64}
NUMBER = {"type": "number", "minimum": -10000, "maximum": 10000}
POSITIVE = {"type": "number", "minimum": 0.001, "maximum": 1000}
UNIT = {"type": "number", "minimum": 0, "maximum": 1}


def array(item, maximum, minimum=0):
    return {"type": "array", "items": item, "maxItems": maximum, "minItems": minimum}


def vector(size, minimum=-10000, maximum=10000):
    return array({"type": "number", "minimum": minimum, "maximum": maximum}, size, size)


def enum(*values):
    return {"type": "string", "enum": list(values)}


def integer(minimum, maximum):
    return {"type": "integer", "minimum": minimum, "maximum": maximum}


def record(properties, required):
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


TRANSFORM = {"location": vector(3), "rotation": vector(3, -3600, 3600), "scale": vector(3, 0.001, 1000)}
BONE = record({"name": NAME, "parent": NAME, "head": vector(3), "tail": vector(3), "connected": {"type": "boolean"}}, ["name", "head", "tail"])
KEY = record({"frame": integer(1, 10000), **TRANSFORM, "bone": NAME}, ["frame"])
WEIGHT = record({"vertex": integer(0, 99999), "bone": NAME, "weight": UNIT}, ["vertex", "bone", "weight"])
NODE = record({"name": NAME, "type": enum("GeometryNodeMeshCube", "GeometryNodeMeshUVSphere", "GeometryNodeMeshIcoSphere", "GeometryNodeMeshCylinder", "GeometryNodeMeshCone", "GeometryNodeTransform", "GeometryNodeJoinGeometry", "GeometryNodeSetMaterial", "GeometryNodeInstanceOnPoints", "GeometryNodeRealizeInstances", "GeometryNodeMeshToPoints", "GeometryNodeSetPosition"), "value": vector(3)}, ["name", "type"])
LINK = record({"from": NAME, "output": integer(0, 16), "to": NAME, "input": integer(0, 16)}, ["from", "output", "to", "input"])

# Each entry contains an independently authored public schema and human-readable
# meaning. Both the connector and the editor obtain this exact shipped contract.
OPERATIONS = {
    "reset": ({"name": NAME}, [], "Start a new empty asset; earlier immutable revisions remain available."),
    "primitive": ({"name": NAME, "kind": enum("cube", "sphere", "icosphere", "cylinder", "cone", "plane", "torus"), **TRANSFORM, "segments": integer(3, 64), "radius": POSITIVE}, ["name", "kind"], "Create a mesh primitive. Rotations are degrees; units are metres."),
    "mesh": ({"name": NAME, "vertices": array(vector(3), 128, 3), "faces": array(array(integer(0, 127), 16, 3), 128, 1), **TRANSFORM}, ["name", "vertices", "faces"], "Create a custom mesh from vertices and polygon indices."),
    "transform": ({"name": NAME, **TRANSFORM}, ["name"], "Set local object location/rotation/scale."),
    "mesh_edit": ({"name": NAME, "kind": enum("extrude", "inset", "subdivide", "merge_by_distance", "recalculate_normals", "smooth", "reverse_faces"), "faces": array(integer(0, 199999), 128), "vertices": array(integer(0, 99999), 128), "amount": NUMBER, "offset": vector(3), "cuts": integer(1, 3)}, ["name", "kind"], "Bounded native mesh editing on selected face/vertex indices; omitted indices select all."),
    "delete": ({"name": NAME}, ["name"], "Delete this workspace object, never an external file."),
    "duplicate": ({"name": NAME, "new_name": NAME, **TRANSFORM}, ["name", "new_name"], "Duplicate object and mesh data."),
    "collider": ({"name": NAME, "new_name": NAME}, ["name", "new_name"], "Create an evaluated collision mesh; use Godot's -convcolonly/-colonly naming conventions."),
    "lod": ({"name": NAME, "new_name": NAME, "ratio": UNIT}, ["name", "new_name", "ratio"], "Create a decimated lower-detail copy of a mesh."),
    "rigid_body": ({"name": NAME, "kind": enum("ACTIVE", "PASSIVE"), "mass": POSITIVE, "friction": UNIT, "restitution": UNIT}, ["name", "kind"], "Configure native Blender rigid-body physics. Physics settings need corresponding Godot configuration after import."),
    "cloth": ({"name": NAME, "quality": integer(1, 5)}, ["name"], "Add a bounded native cloth modifier (at most 5000 source vertices). Simulation needs baking/conversion for game export."),
    "join": ({"objects": array(NAME, 16, 2), "name": NAME}, ["objects", "name"], "Join mesh objects into a single mesh."),
    "modifier": ({"name": NAME, "kind": enum("bevel", "subdivision", "mirror", "solidify", "decimate", "boolean", "triangulate"), "amount": NUMBER, "segments": integer(1, 6), "target": NAME, "apply": {"type": "boolean"}}, ["name", "kind"], "Add/apply a fixed native modifier. Subdivision is limited to three levels."),
    "material": ({"name": NAME, "material": NAME, "color": vector(4, 0, 1), "metallic": UNIT, "roughness": UNIT, "emission": vector(4, 0, 1)}, ["name", "material"], "Create/update and assign a native PBR material; shared materials are copied."),
    "texture": ({"name": NAME, "texture_id": {"type": "string", "minLength": 64, "maxLength": 64}, "kind": enum("base_color", "roughness", "normal")}, ["name", "texture_id", "kind"], "Assign an explicitly user-attached workspace texture by its hash ID, never an external file path."),
    "bake": ({"name": NAME, "kind": enum("DIFFUSE", "NORMAL", "ROUGHNESS")}, ["name", "kind"], "Bake a 512px native material/normal texture in the owned workspace. Requires UVs."),
    "uv_unwrap": ({"name": NAME}, ["name"], "Smart UV unwrap a workspace mesh."),
    "armature": ({"name": NAME, "bones": array(BONE, 64, 1), **TRANSFORM}, ["name", "bones"], "Create an armature with explicitly named bones and parents."),
    "skin": ({"name": NAME, "armature": NAME, "automatic": {"type": "boolean"}, "weights": array(WEIGHT, 128)}, ["name", "armature"], "Parent a mesh to the rig using automatic or explicit vertex weights."),
    "constraint": ({"name": NAME, "bone": NAME, "kind": enum("COPY_LOCATION", "COPY_ROTATION", "COPY_TRANSFORMS", "TRACK_TO", "IK"), "target": NAME, "target_bone": NAME, "chain_length": integer(1, 16)}, ["name", "kind", "target"], "Add a fixed object/pose-bone constraint. Export requires baking unsupported constraints."),
    "keyframes": ({"name": NAME, "action": NAME, "keys": array(KEY, 64, 1), "interpolation": enum("LINEAR", "BEZIER", "CONSTANT")}, ["name", "action", "keys"], "Create a named object or pose-bone animation action; key rotations are degrees."),
    "bake_animation": ({"name": NAME, "action": NAME, "start": integer(1, 10000), "end": integer(1, 10000), "clear_constraints": {"type": "boolean"}}, ["name", "action", "start", "end"], "Bake visual object/pose transforms into an action over at most 120 frames; optional constraint removal is explicit."),
    "shape_key": ({"name": NAME, "key": NAME, "offsets": array(vector(3), 128), "value": UNIT}, ["name", "key", "offsets"], "Create a shape key with one offset per mesh vertex."),
    "geometry_nodes": ({"name": NAME, "nodes": array(NODE, 16, 1), "links": array(LINK, 32, 1), "output": NAME, "apply": {"type": "boolean"}}, ["name", "nodes", "links", "output"], "Build a bounded native Geometry Nodes graph; links use socket indices. Apply to realize exportable mesh geometry."),
    "curve": ({"name": NAME, "points": array(vector(3), 64, 2), "radius": POSITIVE, "convert": {"type": "boolean"}, **TRANSFORM}, ["name", "points"], "Create a 3D poly curve with bevel, optionally convert to mesh."),
    "light": ({"name": NAME, "kind": enum("POINT", "SUN", "AREA", "SPOT"), "energy": {"type": "number", "minimum": 0, "maximum": 10000}, "color": vector(3, 0, 1), **TRANSFORM}, ["name", "kind"], "Create a native light for the asset."),
    "camera": ({"name": NAME, **TRANSFORM, "lens": POSITIVE}, ["name"], "Create a camera and select it as the workspace render camera."),
    "scene": ({"start": integer(1, 10000), "end": integer(1, 10000), "fps": integer(1, 120), "frame": integer(1, 10000)}, [], "Set frame range, frame and FPS."),
}


def validate(value, schema, path="command"):
    kind = schema["type"]
    good = {"object": type(value) is dict, "array": type(value) is list, "string": type(value) is str,
            "number": type(value) in (int, float), "integer": type(value) in (int, float) and math.isfinite(value) and value == int(value), "boolean": type(value) is bool}[kind]
    if not good:
        raise ValueError(f"{path}: expected {kind}")
    if kind in ("number", "integer") and (not math.isfinite(value) or value < schema.get("minimum", -math.inf) or value > schema.get("maximum", math.inf)):
        raise ValueError(f"{path}: number outside supported range")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError(f"{path}: unsupported value")
    if kind == "string" and (not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", 1024) or any(ord(c) < 32 for c in value)):
        raise ValueError(f"{path}: invalid text")
    if kind == "array":
        if not schema.get("minItems", 0) <= len(value) <= schema["maxItems"]:
            raise ValueError(f"{path}: invalid list size")
        for index, child in enumerate(value):
            validate(child, schema["items"], f"{path}[{index}]")
    if kind == "object":
        if value.keys() - schema["properties"].keys() or set(schema["required"]) - value.keys():
            raise ValueError(f"{path}: missing or unsupported fields")
        for key, child in value.items():
            validate(child, schema["properties"][key], f"{path}.{key}")


def command_schema(op):
    fields, required, description = OPERATIONS[op]
    return {**record({"op": enum(op), **fields}, ["op", *required]), "description": description}


def parse_commands(text):
    if type(text) is not str or len(text.encode("utf-8")) > MAX_COMMAND_BYTES:
        raise ValueError("Commands exceed 6000 UTF-8 bytes")
    commands = json.loads(text, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
    if type(commands) is not list or not 1 <= len(commands) <= MAX_COMMANDS:
        raise ValueError("Supply between one and sixteen commands")
    for command in commands:
        if type(command) is not dict or command.get("op") not in OPERATIONS:
            raise ValueError("Unknown Blender operation; request workspace help")
        validate(command, command_schema(command["op"]))
    return commands


def catalog():
    return {name: command_schema(name) for name in OPERATIONS}
