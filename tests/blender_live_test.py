"""Opt-in disposable interactive Blender live-authoring acceptance."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("ORCA_TEST_BLENDER_BIN") and os.environ.get("DISPLAY"), "Explicit Blender executable and graphical display required")
class NativeLiveTest(unittest.TestCase):
    def test_live_authoring_native_cases(self):
        for case in ("model", "guards", "undo", "failure", "shared"):
            with self.subTest(case=case), tempfile.TemporaryDirectory(prefix="orca-live-native-", dir=os.environ.get("ORCA_TEST_TMPDIR")) as directory:
                root = Path(directory)
                env = {**os.environ, "TMPDIR": directory, "BLENDER_USER_CONFIG": str(root / "config"), "BLENDER_USER_SCRIPTS": str(root / "scripts"), "PYTHONDONTWRITEBYTECODE": "1"}
                command = [env["ORCA_TEST_BLENDER_BIN"], "--factory-startup", "--disable-autoexec", "--offline-mode", "--threads", "2", "--python", str(ROOT / "tests/blender_live_native.py"), "--", str(root), case]
                result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("blender_live_native: PASS " + case, result.stdout, result.stdout)
                self.assertNotIn("Traceback", result.stdout, result.stdout)


if __name__ == "__main__":
    unittest.main()
