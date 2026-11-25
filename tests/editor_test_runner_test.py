import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

import run_editor_test as runner
from run_editor_test import failure_reason


class EditorTestRunnerTest(unittest.TestCase):
    MARKER = "auto_apply_editor_test: 0 failures"

    def test_clean_completion(self):
        self.assertEqual(failure_reason(0, self.MARKER, self.MARKER), "")

    def test_zero_assertions_do_not_accept_a_crash(self):
        self.assertTrue(failure_reason(-11, self.MARKER, self.MARKER))

    def test_zero_exit_does_not_accept_shutdown_errors(self):
        for diagnostic in [
            "ERROR: Parameter current_window is null.",
            "SCRIPT ERROR: Parse Error: bad source",
            "WARNING: 6 RIDs of type Canvas were leaked.",
            "WARNING: ObjectDB instances leaked at exit.",
        ]:
            with self.subTest(diagnostic=diagnostic):
                self.assertTrue(failure_reason(0, self.MARKER + "\n" + diagnostic, self.MARKER))

    def test_missing_completion_is_not_a_pass(self):
        self.assertTrue(failure_reason(0, "Editor opened", self.MARKER))

    def test_ansi_colored_errors_are_still_errors(self):
        self.assertTrue(failure_reason(0, self.MARKER + "\n\x1b[31mERROR:\x1b[0m leaked", self.MARKER))

    def test_ci_import_restores_exact_plugin_settings_after_success_failure_and_exception(self):
        for newline in (b"\n", b"\r\n"):
            for outcome in (True, False, RuntimeError("synthetic launch failure")):
                with self.subTest(newline=newline, outcome=outcome), tempfile.TemporaryDirectory(dir=os.environ.get("ORCA_TEST_TMPDIR")) as folder:
                    project = Path(folder)
                    settings = project / "project.godot"
                    prefix = b"config_version=5" + newline
                    plugins = b"[editor_plugins]" + newline + b'enabled=PackedStringArray("res://addons/orca/plugin.cfg")' + newline
                    rendering = b"[rendering]" + newline + b'renderer/rendering_method="mobile"' + newline
                    original = prefix + plugins + rendering
                    settings.write_bytes(original)

                    def execute(command, env):
                        self.assertEqual(settings.read_bytes(), prefix + rendering)
                        self.assertIn("--import", command)
                        # Godot can rewrite configuration while importing; the
                        # subsequent normal editor must still see original bytes.
                        settings.write_bytes(prefix + rendering + b"# rewritten during import")
                        if isinstance(outcome, Exception):
                            raise outcome
                        return outcome

                    with mock.patch.object(runner, "execute", side_effect=execute):
                        if isinstance(outcome, Exception):
                            with self.assertRaisesRegex(RuntimeError, "synthetic launch failure"):
                                runner.import_ci_project(project, "/synthetic/godot", {})
                        else:
                            self.assertEqual(runner.import_ci_project(project, "/synthetic/godot", {}), outcome)
                    self.assertEqual(settings.read_bytes(), original)

    def test_clean_source_fixtures_import_before_enabling_all_project_plugins(self):
        # Exercise the actual primary/secondary-project orchestration against a
        # tiny source tree that includes deliberately stale local import metadata.
        multi_project_cases = {"blender_workspace_editor_test.gd", "remembered_edit_editor_test.gd"}
        for case in (
            "card_status_editor_test.gd", *sorted(multi_project_cases),
            "editor_unsaved_state_test.gd", "editor_scene_inspector_editor_test.gd",
            "diagnostics_editor_integration_test.gd", "plugin_lifecycle_test.gd",
            "managed_settings_editor_test.gd", "onboarding_editor_test.gd",
            "native_helper_editor_test.gd",
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory(dir=os.environ.get("ORCA_TEST_TMPDIR")) as folder:
                root = Path(folder)
                addon = root / "addons/orca"
                addon.mkdir(parents=True)
                (addon / "icon.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
                (addon / "icon.svg.import").write_text("stale local metadata")
                tests = root / "tests"
                tests.mkdir()
                for relative in [case, "editor_test_case.gd", "editor_test_bootstrap.gd", *runner.CASES[case]]:
                    source = tests / relative
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_text("# synthetic fixture")
                imports = []
                runs = []

                def execute(command, env, marker=""):
                    project = Path(command[command.index("--path") + 1])
                    settings = (project / "project.godot").read_text()
                    self.assertNotIn("--script", command)
                    for key in ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
                        self.assertTrue(Path(env[key]).is_relative_to(project.parent))
                    for key in ("ORCA_DISABLE_ACCOUNT_RESTORE", "ORCA_DISABLE_UPDATE_CHECKS", "ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS"):
                        self.assertEqual(env[key], "1")
                    if "--import" in command:
                        self.assertNotIn("[editor_plugins]", settings)
                        self.assertNotIn("ORCA_EDITOR_TEST_CASE", env)
                        self.assertTrue((project / "addons/orca/icon.svg").is_file())
                        self.assertFalse((project / "addons/orca/icon.svg.import").exists())
                        imports.append(project)
                    else:
                        self.assertIn(project, imports)
                        self.assertIn(runner.plugin_settings(), settings)
                        self.assertEqual(env["ORCA_EDITOR_TEST_CASE"], case)
                        self.assertTrue(marker)
                        runs.append(project)
                    return True

                with mock.patch.object(runner, "ROOT", root), mock.patch.object(runner, "execute", side_effect=execute), \
                     mock.patch.object(runner.shutil, "which", return_value="/synthetic/godot"), \
                     mock.patch("sys.argv", ["run_editor_test.py", case, "--godot", "godot", "--temp-parent", folder]), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(runner.main(), 0)
                self.assertEqual(len(imports), 2 if case in multi_project_cases else 1)
                self.assertEqual(set(runs), set(imports))
                self.assertTrue(all(not project.exists() for project in imports))

    def test_zip_fixture_also_starts_with_plugins_disabled(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("ORCA_TEST_TMPDIR")) as folder:
            root = Path(folder)
            tests = root / "tests"
            tests.mkdir()
            for name in ("card_status_editor_test.gd", "editor_test_case.gd", "editor_test_bootstrap.gd"):
                (tests / name).write_text("# synthetic fixture")
            archive = root / "addon.zip"
            with zipfile.ZipFile(archive, "w") as writer:
                writer.writestr("addons/orca/icon.svg", '<svg xmlns="http://www.w3.org/2000/svg"/>')
            project = root / "project"
            project.mkdir()
            with mock.patch.object(runner, "ROOT", root):
                runner.prepare_project(project, "card_status_editor_test.gd", archive)
            self.assertNotIn("[editor_plugins]", (project / "project.godot").read_text())
            runner.enable_plugins(project)
            self.assertIn(runner.plugin_settings(), (project / "project.godot").read_text())


if __name__ == "__main__":
    unittest.main()
