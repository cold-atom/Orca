"""Project-free synthetic stdio peer for editor approval/lifecycle tests."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "addons/orca/blender"))
from workspace_contract import catalog, parse_commands

root = Path(sys.argv[1])
current = {"revision": 1, "sha256": "a" * 64, "blend_file": "revision-000001.blend", "objects": [], "actions": []}


def glb(unsupported=False):
    binary = struct.pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 2) + b"\0\0"
    data = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(binary)}], "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 6}], "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}], "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
    if unsupported:
        data["extensionsRequired"] = ["EXT_fixture_material"]
    source = json.dumps(data).encode()
    source += b" " * (-len(source) % 4)
    return struct.pack("<5I", 0x46546C67, 2, 28 + len(source) + len(binary), len(source), 0x4E4F534A) + source + struct.pack("<2I", len(binary), 0x004E4942) + binary


for line in sys.stdin:
    request = json.loads(line)
    if request["method"] == "notifications/initialized": continue
    result = {}
    method, params = request["method"], request.get("params", {})
    if method == "initialize": result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "Fixture workspace", "version": "1"}}
    elif method == "tools/list": result = {"tools": [{"name": "orca_workspace_" + op, "inputSchema": {"type": "object"}} for op in ["help", "inspect", "edit", "preview", "export", "restore"]]}
    elif method == "tools/call":
        operation = params["name"].removeprefix("orca_workspace_")
        arguments = params["arguments"]
        data = current
        if operation == "help": data = {"catalog_json": json.dumps(catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False), "workspace": current}
        elif operation == "edit":
            commands = parse_commands(arguments["commands"])
            if any(command["op"] == "delete" and not any(obj["name"] == command["name"] for obj in current["objects"]) for command in commands):
                data = {"error": "Native Blender operation failed."}
            else:
                for command in commands:
                    if command["op"] == "primitive": current["objects"].append({"name": command["name"], "type": "MESH"})
                current["revision"] += 1
                current["sha256"] = hashlib.sha256(json.dumps(commands).encode()).hexdigest()
                current["blend_file"] = f'revision-{current["revision"]:06d}.blend'
        elif operation in {"export", "preview"}:
            content = glb(operation == "export" and any(obj["name"] == "ExtensionFixture" for obj in current["objects"]))
            path = root / "asset-fixture.glb"
            path.write_bytes(content)
            data = {"file": path.name, "sha256": hashlib.sha256(content).hexdigest(), "revision": current["revision"]}
            if operation == "preview":
                def chunk(kind, payload):
                    return struct.pack("!I", len(payload)) + kind + payload + struct.pack("!I", zlib.crc32(kind + payload))
                image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\x20\x80\xff\xff")) + chunk(b"IEND", b"")
                image_path = root / "preview-fixture.png"
                image_path.write_bytes(image)
                data = {"file": image_path.name, "sha256": hashlib.sha256(image).hexdigest(), "revision": current["revision"], "preview_3d": data}
        elif operation == "restore":
            current["revision"] += 1
            current["blend_file"] = f'revision-{current["revision"]:06d}.blend'
        result = {"isError": True, "content": [{"type": "text", "text": data["error"]}]} if "error" in data else {"content": [{"type": "text", "text": json.dumps(data)}]}
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
