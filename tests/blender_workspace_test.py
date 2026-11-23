"""Declarative contract tests and opt-in actual owned-Blender acceptance."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SCRIPT = ROOT / "addons/orca/blender/workspace_connector.py"
spec = importlib.util.spec_from_file_location("workspace_contract", SCRIPT.with_name("workspace_contract.py"))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class ContractTest(unittest.TestCase):
    def test_shipped_contract_digest_matches_editor_gate(self):
        source = (ROOT / "addons/orca/scripts/blender_workspace_service.gd").read_text()
        expected = re.search(r'COMMAND_CONTRACT_SHA256 := "([0-9a-f]{64})"', source).group(1)
        encoded = json.dumps(contract.catalog(), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        self.assertEqual(hashlib.sha256(encoded).hexdigest(), expected)
        self.assertLess(len(encoded), 24000)

    def test_typed_mesh_material_rig_animation(self):
        commands = [
            {"op": "primitive", "name": "Body", "kind": "cube", "location": [0, 0, 1]},
            {"op": "material", "name": "Body", "material": "BodyMaterial", "color": [0.2, 0.6, 0.9, 1]},
            {"op": "armature", "name": "Rig", "bones": [{"name": "Root", "head": [0, 0, 0], "tail": [0, 0, 2]}]},
            {"op": "skin", "name": "Body", "armature": "Rig", "automatic": True},
            {"op": "keyframes", "name": "Rig", "action": "Idle", "keys": [{"frame": 1, "bone": "Root", "rotation": [0, 0, 0]}, {"frame": 20, "bone": "Root", "rotation": [0, 10, 0]}]},
        ]
        self.assertEqual(contract.parse_commands(json.dumps(commands)), commands)

    def test_execution_file_and_invalid_fields_are_denied(self):
        invalid = [
            [{"op": "execute_blender_code", "code": "import os"}],
            [{"op": "primitive", "name": "Body", "kind": "cube", "filepath": "/tmp/unowned.blend"}],
            [{"op": "primitive", "name": "Body", "kind": "cube", "location": [0, 0]}],
            [{"op": "modifier", "name": "Body", "kind": "scripted"}],
            [{"op": "transform", "name": "Body", "scale": [-1, 1, 1]}],
            [{"op": "reset", "name": "bad\nname"}],
            [{"op": "primitive", "name": "Body", "kind": "sphere", "segments": 100000}],
        ]
        for commands in invalid:
            with self.subTest(commands=commands), self.assertRaises(ValueError):
                contract.parse_commands(json.dumps(commands))

    def test_byte_command_and_nan_limits(self):
        for text in ["[]", '[{"op":"reset"}]' * 17, '[{"op":"transform","name":"Body","location":[NaN,0,0]}]', " " * 6001]:
            with self.subTest(text=text[:80]), self.assertRaises(ValueError):
                contract.parse_commands(text)


@unittest.skipUnless(os.environ.get("ORCA_TEST_BLENDER_BIN"), "Explicit installed Blender path required for live acceptance")
class BlenderTest(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.TemporaryDirectory(prefix="orca-blender-live-", dir=os.environ.get("ORCA_TEST_TMPDIR"))
        self.addCleanup(self.state.cleanup)
        # System temp roots may use /var aliases or Windows short paths. The
        # trusted connector requires the actual canonical directory identity.
        self.path = Path(self.state.name).resolve(strict=True)
        self.process = subprocess.Popen([os.environ["ORCA_TEST_BLENDER_BIN"], "--quiet", "--background", "--factory-startup", "--disable-autoexec", "--offline-mode", "--threads", "2", "--python-exit-code", "2", "--python", str(SCRIPT), "--", "--workspace", str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self._stop_process)
        self.lines = queue.Queue()
        self.errors = []
        self.output_thread = threading.Thread(target=self._read_output, daemon=True)
        self.error_thread = threading.Thread(target=lambda: [self.errors.append(line) for line in iter(self.process.stderr.readline, b"")], daemon=True)
        self.output_thread.start()
        self.error_thread.start()
        self.serial = 0
        self.rpc("initialize", {})
        self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        self.current = self.call("help", {})["workspace"]

    def _read_output(self):
        try:
            for line in iter(self.process.stdout.readline, b""):
                self.lines.put(line)
        finally:
            self.lines.put(None)  # Wake a request immediately when startup exits.

    def _stop_process(self):
        try:
            self.process.stdin.close()
        except OSError:
            pass  # A failed startup may already have closed the input pipe.
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        for name in ("output_thread", "error_thread"):
            thread = getattr(self, name, None)
            if thread is not None and thread.ident is not None:
                thread.join(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()

    def rpc(self, method, params):
        self.serial += 1
        try:
            self.process.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.serial, "method": method, "params": params}) + "\n").encode())
            self.process.stdin.flush()
        except OSError:
            self.error_thread.join(timeout=2)
            self.fail("Owned Blender closed its input before replying: " + b"".join(self.errors[-10:]).decode(errors="replace"))
        try:
            raw = self.lines.get(timeout=45)
        except queue.Empty:
            self.fail("Owned Blender request did not complete: " + b"".join(self.errors[-10:]).decode(errors="replace"))
        if raw is None:
            self.error_thread.join(timeout=2)
            self.fail("Owned Blender closed its output before replying: " + b"".join(self.errors[-10:]).decode(errors="replace"))
        reply = json.loads(raw)
        self.assertEqual(reply["id"], self.serial)
        return reply["result"]

    def call(self, operation, arguments=None, expect_error=False):
        if arguments is None:
            arguments = {"revision": self.current["revision"], "sha256": self.current["sha256"]}
        result = self.rpc("tools/call", {"name": "orca_workspace_" + operation, "arguments": arguments})
        if expect_error:
            self.assertTrue(result.get("isError"))
            return result
        self.assertFalse(result.get("isError"), result)
        data = json.loads(result["content"][0]["text"])
        if operation in {"edit", "inspect", "restore"}: self.current = data
        return data

    def edit(self, commands):
        return self.call("edit", {"revision": self.current["revision"], "sha256": self.current["sha256"], "commands": json.dumps(commands)})

    def test_model_rig_animate_preview_export_and_recover(self):
        before = self.current.copy()
        self.edit([
            {"op": "primitive", "name": "Body", "kind": "cube", "scale": [0.5, 0.3, 1], "location": [0, 0, 1]},
            {"op": "material", "name": "Body", "material": "Blue", "color": [0.1, 0.4, 0.9, 1], "roughness": 0.6},
            {"op": "uv_unwrap", "name": "Body"},
            {"op": "armature", "name": "Rig", "bones": [{"name": "Root", "head": [0, 0, 0], "tail": [0, 0, 2]}]},
            {"op": "skin", "name": "Body", "armature": "Rig", "automatic": True},
            {"op": "keyframes", "name": "Rig", "action": "Idle", "keys": [{"frame": 1, "bone": "Root", "rotation": [0, 0, 0]}, {"frame": 20, "bone": "Root", "rotation": [0, 15, 0]}]},
            {"op": "scene", "end": 20},
        ])
        self.assertEqual({obj["name"] for obj in self.current["objects"]}, {"Body", "Rig"})
        self.assertIn("Idle", self.current["actions"])
        self.assertTrue((self.path / before["blend_file"]).exists())
        preview_before = self.current.copy()
        image = self.call("preview")
        self.assertTrue((self.path / image["file"]).read_bytes().startswith(b"\x89PNG"))
        self.assertIn("preview_3d", image, "Preview must produce real geometry, not just a PNG")
        snapshot = (self.path / image["preview_3d"]["file"]).read_bytes()
        self.assertEqual(hashlib.sha256(snapshot).hexdigest(), image["preview_3d"]["sha256"])
        preview_document = json.loads(snapshot[20:20 + int.from_bytes(snapshot[12:16], "little")])
        self.assertTrue(preview_document.get("meshes"))
        self.assertFalse(preview_document.get("animations"), "Preview is a static evaluated snapshot")
        self.assertFalse(preview_document.get("skins"))
        self.assertEqual(image["preview_3d"]["revision"], self.current["revision"])
        self.assertEqual(self.call("inspect"), preview_before, "Preview never changes the asset revision")
        exported = self.call("export")
        binary = (self.path / exported["file"]).read_bytes()
        self.assertTrue(binary.startswith(b"glTF"))
        document = json.loads(binary[20:20 + int.from_bytes(binary[12:16], "little")])
        self.assertTrue(document.get("skins"), "Export must retain the native rig/skin")
        self.assertTrue(document.get("animations"), "Export must retain the authored animation")
        old = self.current.copy()
        self.call("edit", {"revision": old["revision"], "sha256": old["sha256"], "commands": json.dumps([{"op": "delete", "name": "Body"}, {"op": "delete", "name": "Missing"}])}, expect_error=True)
        self.call("inspect")
        self.assertEqual(self.current, old)
        self.call("edit", {"revision": old["revision"], "sha256": "0" * 64, "commands": '[{"op":"reset"}]'}, expect_error=True)
        self.call("restore", {"revision": old["revision"], "sha256": old["sha256"], "restore_revision": before["revision"]})
        self.assertEqual(self.current["objects"], [])
        self.assertGreater(self.current["revision"], old["revision"])

    def test_custom_mesh_shape_keys_modifiers_and_curve(self):
        self.edit([
            {"op": "mesh", "name": "Triangle", "vertices": [[0, 0, 0], [1, 0, 0], [0, 1, 0]], "faces": [[0, 1, 2]]},
            {"op": "shape_key", "name": "Triangle", "key": "Lift", "offsets": [[0, 0, 0], [0, 0, 0], [0, 0, 0.5]], "value": 0.5},
            {"op": "primitive", "name": "Prop", "kind": "cube"},
            {"op": "modifier", "name": "Prop", "kind": "bevel", "amount": 0.1, "segments": 2, "apply": True},
            {"op": "duplicate", "name": "Prop", "new_name": "Prop2", "location": [3, 0, 0]},
            {"op": "join", "objects": ["Prop", "Prop2"], "name": "Joined"},
            {"op": "curve", "name": "Cable", "points": [[0, 0, 0], [0, 0, 2]], "radius": 0.1, "convert": True},
        ])
        self.assertEqual({o["name"] for o in self.current["objects"]}, {"Triangle", "Joined", "Cable"})
        self.call("export")

    def test_lit_prop_preview_and_export_use_different_extension_contracts(self):
        self.edit([{"op": "primitive", "name": "Lantern", "kind": "cube"},
                   {"op": "light", "name": "Glow", "kind": "POINT"}])
        for result, lit in [(self.call("preview")["preview_3d"], False), (self.call("export"), True)]:
            binary = (self.path / result["file"]).read_bytes()
            document = json.loads(binary[20:20 + int.from_bytes(binary[12:16], "little")])
            self.assertIn("Lantern", [node.get("name") for node in document["nodes"]])
            self.assertEqual("KHR_lights_punctual" in document.get("extensionsRequired", []), lit)
            if lit:
                self.assertEqual(document["extensions"]["KHR_lights_punctual"]["lights"][0]["type"], "point")

    def test_checkpoint_failure_preserves_owned_baseline(self):
        self.call("inspect")
        before = self.current.copy()
        checksum = hashlib.sha256((self.path / before["blend_file"]).read_bytes()).hexdigest()
        # A failed durable receipt cannot be reported as a completed revision.
        (self.path / "revision-000002.json").mkdir()
        self.call("edit", {"revision": before["revision"], "sha256": before["sha256"], "commands": '[{"op":"primitive","name":"Uncommitted","kind":"cube"}]'}, expect_error=True)
        self.assertEqual(self.call("inspect"), before)
        self.assertEqual(hashlib.sha256((self.path / before["blend_file"]).read_bytes()).hexdigest(), checksum)

    def test_mesh_edit_geometry_nodes_lod_collision_and_physics(self):
        self.edit([
            {"op": "primitive", "name": "Prop", "kind": "cube"},
            {"op": "mesh_edit", "name": "Prop", "kind": "inset", "faces": [0], "amount": 0.1},
            {"op": "mesh_edit", "name": "Prop", "kind": "extrude", "faces": [0], "offset": [0, 0, 0.2]},
            {"op": "mesh_edit", "name": "Prop", "kind": "recalculate_normals"},
            {"op": "lod", "name": "Prop", "new_name": "Low", "ratio": 0.5},
            {"op": "collider", "name": "Prop", "new_name": "Prop-convcolonly"},
            {"op": "rigid_body", "name": "Low", "kind": "ACTIVE", "mass": 1},
            {"op": "primitive", "name": "Procedural", "kind": "cube"},
            {"op": "geometry_nodes", "name": "Procedural", "nodes": [{"name": "Cube", "type": "GeometryNodeMeshCube"}, {"name": "Move", "type": "GeometryNodeTransform", "value": [0, 0, 1]}], "links": [{"from": "Cube", "output": 0, "to": "Move", "input": 0}], "output": "Move", "apply": True},
            {"op": "primitive", "name": "Cloth", "kind": "plane"},
            {"op": "cloth", "name": "Cloth", "quality": 1},
        ])
        self.assertEqual(len(self.current["objects"]), 5)
        self.call("export")

    def test_bake_material_and_animation(self):
        self.edit([
            {"op": "primitive", "name": "Prop", "kind": "cube"},
            {"op": "material", "name": "Prop", "material": "Material", "color": [0.2, 0.3, 0.9, 1]},
            {"op": "uv_unwrap", "name": "Prop"},
            {"op": "bake", "name": "Prop", "kind": "DIFFUSE"},
            {"op": "keyframes", "name": "Prop", "action": "Move", "keys": [{"frame": 1, "location": [0, 0, 0]}, {"frame": 4, "location": [1, 0, 0]}]},
            {"op": "bake_animation", "name": "Prop", "action": "Baked", "start": 1, "end": 4},
        ])
        self.assertIn("Baked", self.current["actions"])
        exported = self.call("export")
        self.assertTrue((self.path / exported["file"]).is_file())

    def test_texture_and_exclusive_workspace_lease(self):
        def chunk(kind, data):
            return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
        import struct
        image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\x20\x80\xff\xff")) + chunk(b"IEND", b"")
        checksum = hashlib.sha256(image).hexdigest()
        (self.path / ("texture-" + checksum + ".png")).write_bytes(image)
        self.edit([
            {"op": "primitive", "name": "Prop", "kind": "cube"},
            {"op": "material", "name": "Prop", "material": "Textured"},
            {"op": "texture", "name": "Prop", "texture_id": checksum, "kind": "base_color"},
        ])
        self.call("export")
        other = subprocess.run(self.process.args, input=b"", capture_output=True, timeout=10)
        self.assertNotEqual(other.returncode, 0, "A second writer must not acquire the active workspace")
        self.call("inspect")
        self.assertEqual(len(self.current["objects"]), 1)

    def test_template_copy_preserves_source(self):
        self.edit([{"op": "primitive", "name": "TemplateProp", "kind": "cube"}])
        source = self.path / self.current["blend_file"]
        checksum = hashlib.sha256(source.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix="orca-template-", dir=os.environ.get("ORCA_TEST_TMPDIR")) as directory:
            target = Path(directory).resolve(strict=True)
            shutil.copyfile(source, target / "template.blend")
            (target / "template.json").write_text(json.dumps({"sha256": checksum}))
            command = [*self.process.args[:-1], str(target)]
            requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "orca_workspace_help", "arguments": {}}}]
            result = subprocess.run(command, input=("\n".join(json.dumps(request) for request in requests) + "\n").encode(), capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace")[-500:])
            self.assertTrue((target / "revision-000001.blend").exists())
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), checksum)


class HarnessTest(unittest.TestCase):
    def test_startup_exit_fails_promptly_and_cleans_up_failed_setup(self):
        # Python rejects the Blender flags and exits without a protocol reply.
        # This exercises the real pipes/reader and cleanup even when setUp fails.
        fixture = BlenderTest("test_template_copy_preserves_source")
        started = time.monotonic()
        try:
            with mock.patch.dict(os.environ, {"ORCA_TEST_BLENDER_BIN": sys.executable}):
                with self.assertRaisesRegex(AssertionError, "Owned Blender closed its .* before replying"):
                    fixture.setUp()
        finally:
            self.assertTrue(fixture.doCleanups())
        self.assertLess(time.monotonic() - started, 10, "Startup exit must not wait for the 45-second RPC timeout")
        self.assertFalse(fixture.path.exists())
        self.assertIsNotNone(fixture.process.poll())
        self.assertTrue(fixture.process.stdin.closed)
        self.assertTrue(fixture.process.stdout.closed)
        self.assertTrue(fixture.process.stderr.closed)


if __name__ == "__main__":
    unittest.main()
