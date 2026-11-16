"""Synthetic stdio peer, or explicitly selected installed MCP + owned Blender."""
import ast
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "addons/orca/blender"))
from workspace_contract import catalog, parse_commands


def native_peer(blender, server):
    # Godot OS.kill uses SIGKILL on Linux, so Python signal/finally cleanup is
    # insufficient. Kernel ownership kills only these explicitly owned children.
    def parent_death():
        if ctypes.CDLL(None).prctl(1, int(signal.SIGKILL), 0, 0, 0) != 0:
            os._exit(2)
        if os.getppid() == 1:
            os._exit(2)

    parent = Path(os.environ["XDG_CACHE_HOME"])
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="orca-live-peer-", dir=parent) as directory:
        root = Path(directory)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        env = {**os.environ, "TMPDIR": directory, "BLENDER_USER_CONFIG": str(root / "config"),
               "BLENDER_USER_SCRIPTS": str(root / "scripts"), "BLENDER_MCP_HOST": "127.0.0.1", "BLENDER_MCP_PORT": str(port)}
        process = subprocess.Popen([blender, "--factory-startup", "--disable-autoexec", "--offline-mode", "--threads", "2", "--python", str(Path(__file__).with_name("blender_live_server.py")), "--", str(port), str(root / "ready")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=parent_death)
        bridge = None

        def stop(_signum=None, _frame=None):
            for child in (bridge, process):
                if child is not None and child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
            if _signum is not None:
                raise SystemExit(0)

        signal.signal(signal.SIGTERM, stop)
        try:
            deadline = time.monotonic() + 20
            while not (root / "ready").exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            if not (root / "ready").exists():
                raise RuntimeError("Owned Blender fixture did not start")
            bridge = subprocess.Popen([server], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, preexec_fn=parent_death)

            def forward():
                for line in bridge.stdout:
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()

            reader = threading.Thread(target=forward, daemon=True)
            reader.start()
            for line in sys.stdin.buffer:
                bridge.stdin.write(line)
                bridge.stdin.flush()
        finally:
            stop()


def glb():
    binary = struct.pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 2) + b"\0\0"
    data = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(binary)}], "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 6}], "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 0]}, {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}], "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}], "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
    text = json.dumps(data).encode()
    text += b" " * (-len(text) % 4)
    return struct.pack("<5I", 0x46546C67, 2, 28 + len(text) + len(binary), len(text), 0x4E4F534A) + text + struct.pack("<2I", len(binary), 0x004E4942) + binary


def synthetic():
    sessions = {}
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request.get("params", {})
        if method == "notifications/initialized":
            continue
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "Owned live fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ("get_objects_summary", "get_blendfile_summary_datablocks")] + [{"name": "execute_blender_code", "inputSchema": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}}]}
        else:
            assert method == "tools/call" and params["name"] == "execute_blender_code" and set(params["arguments"]) == {"code"}
            tree = ast.parse(params["arguments"]["code"])
            calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)]
            start = next((c for c in calls if c.func.attr == "start"), None)
            if start is not None:
                root, token, _hashes = [ast.literal_eval(arg) for arg in start.args]
                state = {"revision": 1, "sha256": "a" * 64, "live_token": token, "scene": "Scene", "document": "Fixture.blend", "dirty": True, "blender_version": "5.2.2", "objects": [{"name": "Cube", "type": "MESH"}], "actions": []}
                sessions[token] = (Path(root), state)
                encoded = json.dumps(catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)
                value = {"ok": True, "data": state, "catalog_sha256": hashlib.sha256(encoded.encode()).hexdigest()}
            elif any(c.func.attr == "command_catalog" for c in calls):
                value = {"ok": True, "catalog_json": json.dumps(catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False)}
            else:
                identity = next(c for c in calls if c.func.attr == "get")
                token = ast.literal_eval(identity.args[0]).removeprefix("_orca_live_")
                root, state = sessions[token]
                decoded = next(c for c in calls if c.func.attr == "loads")
                payload = json.loads(ast.literal_eval(decoded.args[0]))
                operation = payload["operation"]
                value = {"ok": True, "data": state}
                if operation == "edit":
                    commands = parse_commands(payload["commands"])
                    for command in commands:
                        if command["op"] == "primitive":
                            state["objects"].append({"name": command["name"], "type": "MESH"})
                    state["revision"] += 1
                    state["sha256"] = hashlib.sha256(json.dumps(state).encode()).hexdigest()
                elif operation in ("preview", "export"):
                    content = glb()
                    path = root / "asset-fixture.glb"
                    path.write_bytes(content)
                    artifact = {"file": path.name, "sha256": hashlib.sha256(content).hexdigest(), "revision": state["revision"]}
                    if operation == "preview":
                        def chunk(kind, data):
                            return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
                        image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\x20\x80\xff\xff")) + chunk(b"IEND", b"")
                        path = root / "preview-fixture.png"
                        path.write_bytes(image)
                        artifact = {"file": path.name, "sha256": hashlib.sha256(image).hexdigest(), "revision": state["revision"], "preview_3d": artifact}
                    value = {"ok": True, "data": artifact, "baseline": state}
                elif operation == "undo":
                    value = {"ok": True, "data": {"authoring_revoked": True}}
            result = {"content": [{"type": "text", "text": json.dumps({"status": "ok", "result": value})}]}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 3:
        native_peer(sys.argv[1], sys.argv[2])
    else:
        synthetic()
