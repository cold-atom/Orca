"""Owned interactive Blender listener for installed official MCP acceptance.

Implements the documented local execute framing independently, only in disposable
test processes. No server/add-on source is copied into the plugin.
"""
import json
from pathlib import Path
import queue
import socket
import sys
import threading
import traceback

import bpy

port, marker = sys.argv[sys.argv.index("--") + 1:]
jobs = queue.Queue()


def listen():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", int(port)))
        listener.listen(4)
        Path(marker).write_text("ready")
        while True:
            connection, _address = listener.accept()
            with connection:
                payload = bytearray()
                while b"\0" not in payload and len(payload) <= 131072:
                    chunk = connection.recv(16384)
                    if not chunk:
                        break
                    payload.extend(chunk)
                if len(payload) > 131072:
                    continue
                task = {"request": json.loads(payload.split(b"\0")[0]), "done": threading.Event()}
                jobs.put(task)
                if task["done"].wait(40):
                    connection.sendall(json.dumps(task["response"], default=repr).encode() + b"\0")


def pump():
    try:
        task = jobs.get_nowait()
    except queue.Empty:
        return 0.02
    try:
        request = task["request"]
        if request.get("type") != "execute" or type(request.get("code")) is not str:
            raise ValueError("Unsupported fixture request")
        namespace = {"result": {}}
        exec(compile(request["code"], "<owned MCP fixture>", "exec"), namespace)
        task["response"] = {"status": "ok", "result": namespace["result"]}
    except Exception:
        traceback.print_exc()
        task["response"] = {"status": "error", "message": "Owned fixture execution failed"}
    task["done"].set()
    return 0.02


bpy.app.timers.register(pump, first_interval=0.5)
threading.Thread(target=listen, daemon=True).start()
