"""Disposable interactive Blender acceptance; never uses an owner's document."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import traceback

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
root, case = Path(args[0]), args[1]
source = Path(__file__).resolve().parents[1] / "addons/orca/blender/live_session.py"
sys.dont_write_bytecode = True


def check(value, message):
    if not value:
        raise AssertionError(message)


def run():
    module = None
    try:
        spec = importlib.util.spec_from_file_location("orca_live_fixture", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        before_names = set(bpy.data.objects.keys())
        before_paths = list(sys.path)
        cube = bpy.data.objects["Cube"]
        cube.location.x = 2.0
        bpy.context.view_layer.update()
        before = (bpy.data.filepath, bpy.data.is_dirty, cube.as_pointer(), cube.location.x)
        hashes = {name: hashlib.sha256(source.with_name(name).read_bytes()).hexdigest() for name in ("workspace_connector.py", "workspace_contract.py", "live_export.py")}
        started = module.start(str(root), "a" * 32, hashes)
        check(started["ok"], "live start")
        check(set(bpy.data.objects.keys()) == before_names, "import/start must preserve existing objects")
        check(sys.path == before_paths, "helper reuse must not alter the user's Python search path")
        check((bpy.data.filepath, bpy.data.is_dirty, cube.as_pointer(), cube.location.x) == before, "startup preserves unsaved document and identities")
        current = started["data"]

        def call(operation, **fields):
            return module.dispatch({"operation": operation, "revision": current["revision"], "sha256": current["sha256"], **fields})

        def edit(commands):
            nonlocal current
            current = module.snapshot()
            result = call("edit", commands=json.dumps(commands))
            check(result["ok"], "edit: " + repr(result))
            current = result["data"]
            check(result["save_pending"], "live edit is save pending")
            checkpoint = root / result["recovery"]["file"]
            check(checkpoint.exists() and hashlib.sha256(checkpoint.read_bytes()).hexdigest() == result["recovery"]["sha256"], "immutable pre-write recovery bytes")
            return result

        if case == "model":
            edit([
                {"op": "primitive", "name": "Body", "kind": "cube"},
                {"op": "material", "name": "Body", "material": "Blue", "color": [0.1, 0.4, 0.9, 1]},
                {"op": "uv_unwrap", "name": "Body"},
                {"op": "armature", "name": "Rig", "bones": [{"name": "Root", "head": [0, 0, 0], "tail": [0, 0, 2]}]},
                {"op": "skin", "name": "Body", "armature": "Rig", "automatic": True},
                {"op": "keyframes", "name": "Rig", "action": "Idle", "keys": [{"frame": 1, "bone": "Root", "rotation": [0, 0, 0]}, {"frame": 20, "bone": "Root", "rotation": [0, 10, 0]}]},
            ])
            check(bpy.data.filepath == before[0] and cube.location.x == before[3], "authoring preserves original path and earlier unsaved edits")
            current = module.snapshot()
            result = call("export", objects=["Body", "Rig"])
            check(result["ok"], "export: " + repr(result))
            binary = (root / result["data"]["file"]).read_bytes()
            document = json.loads(binary[20:20 + int.from_bytes(binary[12:16], "little")])
            check(document.get("skins") and document.get("animations"), "export retains skin and animation")
            check({n.get("name") for n in document["nodes"]}.isdisjoint({"Cube", "Camera", "Light"}), "export confines selection")
            current = result["baseline"]
            result = call("preview", objects=["Body", "Rig"])
            check(result["ok"], "preview: " + repr(result))
            check((root / result["data"]["file"]).read_bytes().startswith(b"\x89PNG"), "real PNG preview")
            check("preview_3d" in result["data"], "static interactive preview")
            check(set(bpy.data.objects.keys()) == before_names | {"Body", "Rig"}, "preview cleans temporary scene/camera/light")
        elif case == "guards":
            for commands in [[{"op": "reset"}], [{"op": "transform", "name": "Cube", "filepath": "/tmp/unowned"}], [{"op": "execute_blender_code", "code": "evil"}]]:
                result = call("edit", commands=json.dumps(commands))
                check(not result["ok"] and set(bpy.data.objects.keys()) == before_names, "invalid authority denied before mutation")
            cube.location.y = 3
            result = call("edit", commands=json.dumps([{"op": "transform", "name": "Cube", "location": [0, 0, 0]}]))
            check(not result["ok"] and cube.location.y == 3, "manual edits invalidate review")
            bpy.data.texts.new("User script")
            check(not call("inspect")["ok"], "embedded scripts require separate trust")
        elif case == "undo":
            edit([{"op": "primitive", "name": "Prop", "kind": "cube"}])
            current = module.snapshot()
            result = call("undo")
            check(result["ok"], "native Undo: " + repr(result))
            check(set(bpy.data.objects.keys()) == before_names and bpy.data.objects["Cube"].location.x == before[3], "Undo preserves earlier dirty work")
            check(module.REVOKED, "Undo revokes old native identities")
        elif case == "failure":
            result = call("edit", commands=json.dumps([{"op": "primitive", "name": "Partial", "kind": "cube"}, {"op": "delete", "name": "Missing"}]))
            check(not result["ok"] and result["uncertain"] and result["recovery"], "partial failure retains honest recovery receipt")
            check(bpy.data.filepath == before[0] and bpy.data.objects["Cube"].location.x == before[3], "failure never reloads or overwrites original document")
            bpy.ops.ed.undo()
            check("Partial" not in bpy.data.objects and bpy.data.objects["Cube"].location.x == before[3], "failed batch has native Undo")
        elif case == "shared":
            other = cube.copy()
            other.name = "SharedMesh"
            bpy.context.scene.collection.objects.link(other)
            original = list(cube.data.vertices[0].co)
            edit([{"op": "mesh_edit", "name": "SharedMesh", "kind": "smooth", "amount": 0.5}])
            check(cube.data != other.data and list(cube.data.vertices[0].co) == original, "mesh edits isolate shared data")
            current = module.snapshot()
            bpy.ops.ed.undo_push(message="Later user action")
            cube.location.y = 7
            bpy.ops.ed.undo_push(message="Later user action complete")
            check(not call("undo")["ok"] and bpy.data.objects["Cube"].location.y == 7, "inverse cannot rewind newer work")
        else:
            raise AssertionError("Unknown native case")
        print("blender_live_native: PASS " + case, flush=True)
    except Exception:
        traceback.print_exc()
        print("blender_live_native: FAIL " + case, flush=True)
    finally:
        if module:
            module.close()
        bpy.ops.wm.quit_blender()
    return None


bpy.app.timers.register(run, first_interval=0.5)
