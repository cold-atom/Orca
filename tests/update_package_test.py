"""Real bounded ZIP/transaction and independent Godot restart acceptance."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


def addon(path: Path, version: str, restart_marker: bool = False) -> None:
    path.mkdir(parents=True)
    (path / "plugin.cfg").write_text(f'[plugin]\nname="Orca"\nversion="{version}"\nscript="orca.gd"\n')
    script = "@tool\nextends EditorPlugin\n"
    if restart_marker:
        script += f'''\nfunc _enter_tree() -> void:
    var file := FileAccess.open("res://restart-marker.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({{"version": "{version}", "pid": OS.get_process_id(), "display": DisplayServer.get_name()}}))
    file.close()
    call_deferred("_done")
func _done() -> void:
    get_tree().quit()
'''
    (path / "orca.gd").write_text(script)
    (path / "native").mkdir()
    (path / "native/credential_helper_linux.x86_64").write_bytes(b"synthetic-not-executed")


def install_archive(archive: Path, project: Path) -> None:
    with zipfile.ZipFile(archive) as reader:
        reader.extractall(project)


class UpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="orca-update-test-", dir=os.environ.get("ORCA_TEST_TMPDIR"))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def archives(self, marker: bool = False) -> tuple[Path, Path, Path, dict]:
        old, new = self.root / "old", self.root / "new"
        addon(old, "1.3.0")
        addon(new, "1.4.0", marker)
        a, b = self.root / "old.zip", self.root / "new.zip"
        packaging.build(old, a)
        result = packaging.build(new, b)
        project = self.root / "project"
        project.mkdir()
        install_archive(a, project)
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Updater fixture"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/orca/plugin.cfg")\n')
        (project / "user-game.txt").write_bytes(b"unrelated project work")
        return project, a, b, result

    def godot(self, setup: dict) -> subprocess.CompletedProcess:
        binary = os.environ.get("GODOT_BIN")
        if not binary:
            self.skipTest("Set GODOT_BIN for actual Godot updater acceptance")
        env = {**os.environ, "ORCA_DISABLE_ACCOUNT_RESTORE": "1", "ORCA_DISABLE_UPDATE_CHECKS": "1", "ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS": "1"}
        # Match display-free CI even when these tests run on a developer desktop.
        # A mistakenly graphical relaunch must fail rather than masking the bug.
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)
        result = subprocess.run(
            [binary, "--headless", "--path", str(ROOT), "--script", "res://tests/update_package_fixture.gd"],
            input=json.dumps(setup) + "\n", text=True, capture_output=True, timeout=120, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("SCRIPT ERROR", result.stdout + result.stderr)
        return result

    def test_deterministic_addon_manifest_and_permissions(self) -> None:
        source = self.root / "addon"
        addon(source, "1.4.0")
        (source / "asset.svg.import").write_text("generated")
        first, second = self.root / "first.zip", self.root / "second.zip"
        a = packaging.build(source, first)
        b = packaging.build(source, second)
        self.assertEqual(a, b)
        with zipfile.ZipFile(first) as archive:
            self.assertTrue(all(name.startswith("addons/orca/") for name in archive.namelist()))
            self.assertNotIn("addons/orca/asset.svg.import", archive.namelist())
            manifest = json.loads(archive.read("addons/orca/update_manifest.json"))
            self.assertEqual(manifest["version"], "1.4.0")
            for entry in manifest["files"]:
                data = archive.read("addons/orca/" + entry["path"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])
            self.assertNotIn("addons/orca/native/credential_helper_linux.x86_64", archive.namelist())
            self.assertTrue(all(not entry["executable"] for entry in manifest["files"]))
        self.assertFalse((source / "update_manifest.json").exists())

    def test_packaging_refuses_bad_versions_symlinks_and_overwrite(self) -> None:
        source = self.root / "addon"
        addon(source, "1.4.0")
        with self.assertRaises(ValueError):
            packaging.build(source, self.root / "bad.zip", "1.5.0")
        (source / "linked.gd").symlink_to(source / "orca.gd")
        with self.assertRaises(ValueError):
            packaging.build(source, self.root / "link.zip")
        (source / "linked.gd").unlink()
        packaging.build(source, self.root / "good.zip")
        with self.assertRaises(ValueError):
            packaging.build(source, self.root / "good.zip")

    def test_real_godot_archive_install_and_rollback(self) -> None:
        project, _, archive, result = self.archives()
        bad = []
        for name in ["addons/orca/../../user-game.txt", "addons/orca/NUL.gd", "other/file.gd"]:
            path = self.root / f"bad-{len(bad)}.zip"
            with zipfile.ZipFile(path, "w") as writer:
                writer.writestr(name, b"bad")
            bad.append(str(path))
        duplicate = self.root / "duplicate.zip"
        with zipfile.ZipFile(duplicate, "w") as writer:
            writer.writestr("addons/orca/Orca.gd", b"a")
            writer.writestr("addons/orca/orca.gd", b"b")
        bad.append(str(duplicate))
        for kind in ["expanded", "encrypted", "symlink", "header"]:
            data = bytearray(archive.read_bytes())
            central = data.index(b"PK\x01\x02")
            if kind == "expanded":
                struct.pack_into("<I", data, central + 24, 129 * 1024 * 1024)
            elif kind == "encrypted":
                struct.pack_into("<H", data, central + 8, 1)
            elif kind == "symlink":
                struct.pack_into("<I", data, central + 38, (stat.S_IFLNK | 0o777) << 16)
            else:
                struct.pack_into("<I", data, 18, 100000)
            path = self.root / f"{kind}.zip"
            path.write_bytes(data)
            bad.append(str(path))
        self.godot({"project": str(project), "archive": str(archive), "digest": result["sha256"], "bad_archives": bad})
        self.assertEqual((project / "user-game.txt").read_bytes(), b"unrelated project work")

    def test_legacy_bundled_helper_survives_guarded_rollback(self) -> None:
        project, old, new, result = self.archives()
        legacy_name = "addons/orca/native/credential_helper_linux.x86_64"
        legacy_bytes = b"old-reviewed-helper-never-executed"
        with zipfile.ZipFile(old) as reader:
            files = {name: reader.read(name) for name in reader.namelist()}
        manifest = json.loads(files["addons/orca/update_manifest.json"])
        manifest["files"].append({"path": legacy_name.removeprefix("addons/orca/"), "size": len(legacy_bytes), "sha256": hashlib.sha256(legacy_bytes).hexdigest(), "executable": True})
        files["addons/orca/update_manifest.json"] = json.dumps(manifest).encode()
        files[legacy_name] = legacy_bytes
        with zipfile.ZipFile(old, "w", compression=zipfile.ZIP_DEFLATED) as writer:
            for name, data in files.items():
                info = zipfile.ZipInfo(name)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | (0o755 if name == legacy_name else 0o644)) << 16
                writer.writestr(info, data)
        install_archive(old, project)
        (project / legacy_name).chmod(0o755)
        self.godot({"project": str(project), "archive": str(new), "digest": result["sha256"], "bad_archives": []})
        self.assertEqual((project / legacy_name).read_bytes(), legacy_bytes)

    def test_actual_repository_release_package(self) -> None:
        archive = self.root / "repository.zip"
        result = packaging.build(ROOT / "addons/orca", archive)
        project = self.root / "validation-project"
        project.mkdir()
        self.godot({"operation": "validate", "project": str(project), "archive": str(archive), "digest": result["sha256"], "version": result["version"]})

    def test_failed_and_cancelled_downloads_preserve_installation(self) -> None:
        base = self.root
        for kind in ("checksum", "redirect", "disconnect", "cancel"):
            with self.subTest(kind=kind):
                self.root = base / kind
                self.root.mkdir()
                project, _, archive, package = self.archives()
                release = {
                    "draft": False, "prerelease": False, "tag_name": "v1.4.0",
                    "assets": [{"name": "orca-v1.4.0.zip", "size": package["size"], "digest": "sha256:" + ("0" * 64 if kind == "checksum" else package["sha256"]),
                                "browser_download_url": "https://github.com/cold-atom/Orca/releases/download/v1.4.0/orca-v1.4.0.zip"}],
                }

                class Handler(BaseHTTPRequestHandler):
                    def log_message(self, *_args): pass
                    def do_GET(self):
                        if self.path == "/download" and kind == "redirect":
                            self.send_response(302)
                            self.send_header("Location", "https://attacker.example/package.zip")
                            self.send_header("Content-Length", "0")
                            self.end_headers()
                            return
                        data = json.dumps(release).encode() if self.path == "/latest" else archive.read_bytes()
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(data)))
                        self.end_headers()
                        if self.path != "/latest" and kind == "disconnect":
                            self.wfile.write(data[:10])
                            self.close_connection = True
                        else:
                            if self.path != "/latest" and kind == "cancel":
                                time.sleep(0.5)
                            try: self.wfile.write(data)
                            except (BrokenPipeError, ConnectionResetError): pass

                server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    self.godot({"project": str(project), "origin": f"http://127.0.0.1:{server.server_port}", "operation": "cancel-download" if kind == "cancel" else "download-failure"})
                    self.assertEqual((project / "user-game.txt").read_bytes(), b"unrelated project work")
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join()
        self.root = base

    def test_real_download_handoff_wait_exit_replace_restart(self) -> None:
        project, _, archive, package = self.archives(marker=True)
        events = []
        release = {
            "draft": False, "prerelease": False, "tag_name": "v1.4.0",
            "assets": [{"name": "orca-v1.4.0.zip", "size": package["size"], "digest": "sha256:" + package["sha256"],
                        "browser_download_url": "https://github.com/cold-atom/Orca/releases/download/v1.4.0/orca-v1.4.0.zip"}],
        }

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args): pass
            def do_GET(self):
                events.append((self.path, dict(self.headers)))
                if self.path == "/download":
                    self.send_response(302)
                    self.send_header("Location", "https://release-assets.githubusercontent.com/fixture/package.zip?sig=synthetic")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                data = json.dumps(release).encode() if self.path == "/latest" else archive.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Type", "application/json" if self.path == "/latest" else "application/octet-stream")
                self.end_headers()
                self.wfile.write(data)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.godot({"project": str(project), "origin": f"http://127.0.0.1:{server.server_port}", "operation": "roundtrip"})
            marker = project / "restart-marker.json"
            deadline = time.monotonic() + 90
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            diagnostics = {name: (project / ".orca-update" / name).read_text() if (project / ".orca-update" / name).exists() else "missing" for name in ("worker.json", "result.json", "transaction.json")}
            self.assertTrue(marker.exists(), "Independent updater did not reopen the new addon: " + str(diagnostics))
            receipt = json.loads(marker.read_text())
            self.assertEqual(receipt["version"], "1.4.0")
            self.assertEqual(receipt["display"], "headless")
            self.assertGreater(receipt["pid"], 0)
            # Wait for the fixture's newly opened editor to finish teardown.
            time.sleep(2)
            manifest = json.loads((project / "addons/orca/update_manifest.json").read_text())
            backup = json.loads((project / ".orca-update/backup/update_manifest.json").read_text())
            self.assertEqual(manifest["version"], "1.4.0")
            self.assertEqual(backup["version"], "1.3.0")
            self.assertEqual((project / "user-game.txt").read_bytes(), b"unrelated project work")
            self.assertFalse((project / "addons/orca/native/credential_helper_linux.x86_64").exists())
            self.assertEqual([path for path, _ in events], ["/latest", "/download", "/cdn"])
            self.assertTrue(all("Authorization" not in headers for _, headers in events))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
            worker_path = project / ".orca-update/worker.json"
            if worker_path.exists():
                pid = json.loads(worker_path.read_text()).get("pid", 0)
                if pid:
                    try: os.kill(pid, 15)
                    except ProcessLookupError: pass


if __name__ == "__main__":
    unittest.main()
