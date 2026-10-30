"""Real HTTP, cancellation, cache and account-gating tests in isolated helper caches."""
from __future__ import annotations

import hashlib
import json
import os
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def native_bytes() -> bytes:
    data = bytearray(128)
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<HH", data, 16, 2, 62)
    return bytes(data)  # Never executed; native-vault acceptance uses real compiled helpers.


class HelperDownloadTests(unittest.TestCase):
    def test_download_verification_cancellation_cache_and_account_gate(self) -> None:
        binary = os.environ.get("GODOT_BIN")
        if not binary:
            self.skipTest("Set GODOT_BIN for helper download acceptance")
        data = native_bytes()
        entry = {"platform": "linux", "architecture": "x86_64", "asset": "credential_helper_linux.x86_64", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        catalog = {"format": "orca-native-helpers-v1", "version": "1.4.0", "helpers": [entry]}
        with tempfile.TemporaryDirectory(prefix="orca-helper-download-", dir=os.environ.get("ORCA_TEST_TMPDIR")) as temporary:
            for kind in ("background", "success", "redirect", "checksum", "oversized", "disconnect", "bad_redirect", "duplicate_redirect", "cancel", "shutdown", "teardown", "cancel_before_download", "cancel_before_auth", "lock", "cached", "symlink", "retry", "retry_exhausted", "retry_signin", "restore", "restore_missing", "startup_cancelled", "suppressed"):
                if os.environ.get("ORCA_TEST_HELPER_KIND") and kind != os.environ["ORCA_TEST_HELPER_KIND"]:
                    continue
                with self.subTest(kind=kind):
                    root = Path(temporary) / kind
                    root.mkdir()
                    cache = root / "cache"
                    if kind == "cached":
                        target = cache / entry["sha256"] / entry["asset"]
                        target.parent.mkdir(parents=True)
                        target.write_bytes(data)
                        target.chmod(0o700)
                    if kind == "symlink":
                        outside = root / "outside"
                        outside.mkdir()
                        cache.symlink_to(outside, target_is_directory=True)
                    requests = []

                    class Handler(BaseHTTPRequestHandler):
                        def do_GET(self) -> None:
                            requests.append((self.path, dict(self.headers)))
                            if kind == "retry_exhausted" or (kind == "retry" and len(requests) == 1) or (kind == "retry_signin" and len(requests) <= 3):
                                self.send_response(503)
                                self.send_header("Content-Length", "0")
                                self.end_headers()
                                return
                            if kind in ("redirect", "bad_redirect", "duplicate_redirect") and self.path == "/download":
                                self.send_response(302)
                                self.send_header("Location", "https://release-assets.githubusercontent.com/fixture" if kind != "bad_redirect" else "https://attacker.example/download")
                                if kind == "duplicate_redirect":
                                    self.send_header("Location", "https://release-assets.githubusercontent.com/other")
                                self.end_headers()
                                return
                            if kind == "lock":
                                time.sleep(0.3)
                            payload = data + (b"extra" if kind == "oversized" else b"")
                            if kind == "checksum":
                                payload = payload[:-1] + b"!"
                            self.send_response(200)
                            self.send_header("Content-Length", str(len(payload)))
                            self.end_headers()
                            if kind in ("cancel", "shutdown", "teardown"):
                                self.wfile.flush()
                                time.sleep(0.3)
                            try:
                                self.wfile.write(payload[:16] if kind == "disconnect" else payload)
                            except (BrokenPipeError, ConnectionResetError):
                                pass
                            self.close_connection = True

                        def log_message(self, *_args) -> None:
                            pass

                    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                    worker = threading.Thread(target=server.serve_forever, daemon=True)
                    worker.start()
                    try:
                        setup = {"kind": kind, "cache": str(cache), "catalog": catalog, "server": f"http://127.0.0.1:{server.server_port}"}
                        try:
                            result = subprocess.run([binary, "--headless", "--path", str(ROOT), "--script", "res://tests/native_helper_fixture.gd"], input=json.dumps(setup) + "\n", text=True, capture_output=True, timeout=20, env={**os.environ, "ORCA_DISABLE_ACCOUNT_RESTORE": "1", "ORCA_DISABLE_UPDATE_CHECKS": "1", "ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS": "1"})
                        except subprocess.TimeoutExpired as error:
                            self.fail(f"Helper fixture timed out: {error.stdout!r} {error.stderr!r}")
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertNotIn("SCRIPT ERROR", result.stdout + result.stderr)
                        self.assertIn("PASS", result.stdout)
                        if kind == "disconnect":
                            self.assertTrue(1 <= len(requests) <= 3)
                        else:
                            expected = 0 if kind in ("cached", "symlink", "cancel_before_download", "suppressed") else 2 if kind in ("redirect", "retry") else 3 if kind == "retry_exhausted" else 4 if kind == "retry_signin" else 1
                            self.assertEqual(len(requests), expected)
                        for _, headers in requests:
                            self.assertFalse(any(name.lower() in ("authorization", "cookie", "api-key") for name in headers))
                        if kind == "symlink":
                            self.assertEqual(list(outside.iterdir()), [])
                    finally:
                        server.shutdown()
                        server.server_close()
                        worker.join()


if __name__ == "__main__":
    unittest.main()
