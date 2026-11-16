"""Fixed owned preview/export worker for a reviewed script-free live snapshot."""
import hashlib
import json
from pathlib import Path
import sys
import types

import bpy

sys.dont_write_bytecode = True
args = sys.argv[sys.argv.index("--") + 1:]
if len(args) != 2:
    raise ValueError("Invalid trusted worker invocation")
root, payload = Path(args[0]), json.loads(args[1])
if not root.is_absolute() or root.resolve() != root or not root.is_dir():
    raise ValueError("Invalid owned handoff directory")


def source(name):
    path = Path(__file__).with_name(name)
    if path.resolve() != path or path.is_symlink():
        raise ValueError("Invalid shipped worker helper")
    with path.open("rb") as file:
        data = file.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != payload["hashes"][name]:
        raise ValueError("The shipped worker helper changed")
    return path, data


contract = types.ModuleType("workspace_contract")
path, data = source("workspace_contract.py")
exec(compile(data, str(path), "exec"), contract.__dict__)
sys.modules["workspace_contract"] = contract
ops = types.ModuleType("orca_owned_export")
path, data = source("workspace_connector.py")
ops.__file__ = str(path)
exec(compile(data, str(path), "exec"), ops.__dict__)
ops.ROOT, ops.REVISION = root, payload["revision"]
file = root / payload["source"]
if file.parent != root or ops.digest(file) != payload["source_sha256"]:
    raise ValueError("The reviewed live snapshot changed")
bpy.ops.wm.open_mainfile(filepath=str(file), load_ui=False, use_scripts=False)
if bpy.data.libraries or bpy.data.texts or any(v.animation_data and v.animation_data.drivers for v in bpy.data.objects):
    raise ValueError("A live snapshot needs a separate execution-trust workflow")
scene = bpy.data.scenes.get(payload["scene"])
if scene is None:
    raise ValueError("The reviewed scene is unavailable")
bpy.context.window.scene = scene
names = set(payload["objects"])
if not 1 <= len(names) <= 16 or any(scene.objects.get(name) is None for name in names):
    raise ValueError("The reviewed asset selection changed")
for value in list(bpy.data.objects):
    if value.name not in names:
        bpy.data.objects.remove(value, do_unlink=True)
ops.summary()
if payload["operation"] == "export":
    data = ops.export()
elif payload["operation"] == "preview":
    data = ops.preview()
    try:
        data["preview_3d"] = ops.preview_export()
    except Exception:
        data["preview_3d_unavailable"] = True
else:
    raise ValueError("Unsupported fixed handoff operation")
data.pop("summary", None)
receipt = root / payload["receipt"]
if receipt.parent != root or receipt.exists() or receipt.is_symlink():
    raise ValueError("Invalid owned output receipt")
with receipt.open("x", encoding="utf-8") as file:
    json.dump({"ok": True, "data": data}, file, allow_nan=False)
