#!/usr/bin/env python3
"""Run selected editor cases in a normal editor with disposable project/XDG state."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "auto_apply_editor_test.gd": ["auto_apply_test.gd"],
    "editor_ui_scale_test.gd": ["fixtures/gdscript_function_reader_fixture.gd"],
    "remembered_edit_editor_test.gd": ["auto_apply_test.gd"],
    "update_editor_test.gd": [],
    "localization_editor_test.gd": [],
    "project_inspection_editor_test.gd": ["fixtures/project_inspection_editor_scene.tscn", "fixtures/animation_inspector_fixture.tscn"],
}
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
DIAGNOSTIC = re.compile(r"(?m)^(?:ERROR:|SCRIPT ERROR:|WARNING:|handle_crash:)")


def failure_reason(code: int, output: str, marker: str = "") -> str:
    output = ANSI_ESCAPE.sub("", output)
    if code != 0:
        return f"Godot exited with code {code}"
    if DIAGNOSTIC.search(output):
        return "Godot emitted an error or warning, including during shutdown"
    if marker and marker not in output:
        return "The editor case did not report successful completion"
    return ""


def execute(command: list[str], env: dict[str, str], marker: str = "") -> bool:
    try:
        result = subprocess.run(
            command,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        print("run_editor_test: FAIL: Godot exceeded the process deadline", file=sys.stderr)
        return False
    reason = failure_reason(result.returncode, result.stdout, marker)
    if result.stdout.strip():
        print(result.stdout.rstrip())
    if reason:
        print(f"run_editor_test: FAIL: {reason}", file=sys.stderr)
        return False
    return True


def prepare_project(project: Path, case: str) -> None:
    # Release-like source scope: load the actual addon and the selected case's
    # dependencies, not every unrelated suite in Godot's script-doc generator.
    shutil.copytree(ROOT / "addons" / "orca", project / "addons" / "orca")
    tests = project / "tests"
    tests.mkdir()
    for relative in [case, "editor_test_case.gd", *CASES[case]]:
        destination = tests / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "tests" / relative, destination)
    bootstrap = project / "addons" / "editor_fixture"
    bootstrap.mkdir()
    shutil.copy2(ROOT / "tests" / "editor_test_bootstrap.gd", bootstrap / "bootstrap.gd")
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Orca editor test fixture"\n'
        'description="Disposable test entry point"\nauthor="Orca"\n'
        'version="1"\nscript="bootstrap.gd"\n',
        encoding="utf-8",
    )
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Orca isolated editor fixture"\n'
        'config/features=PackedStringArray("4.7")\n[editor_plugins]\n'
        'enabled=PackedStringArray("res://addons/orca/plugin.cfg", '
        '"res://addons/editor_fixture/plugin.cfg")\n[rendering]\n'
        'renderer/rendering_method="gl_compatibility"\n',
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=CASES)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN"))
    parser.add_argument("--graphical", action="store_true", help="Use Linux/X11/OpenGL")
    parser.add_argument("--temp-parent", type=Path, default=os.environ.get("ORCA_TEST_TMPDIR"))
    parser.add_argument("--ui-only", action="store_true", help="Auto-apply layout subset")
    args = parser.parse_args()
    if not args.godot:
        parser.error("Set GODOT_BIN or pass --godot")
    if sys.platform != "linux":
        parser.error("This runner currently isolates Linux XDG editor state only")
    if args.ui_only and args.case != "auto_apply_editor_test.gd":
        parser.error("--ui-only is supported only by auto_apply_editor_test.gd")
    if args.temp_parent is not None and not args.temp_parent.is_dir():
        parser.error("--temp-parent must be an existing directory")
    binary = shutil.which(args.godot)
    if binary is None:
        parser.error("The Godot executable could not be found")
    with tempfile.TemporaryDirectory(prefix="orca-editor-", dir=args.temp_parent) as folder:
        state = Path(folder)
        project = state / "project"
        project.mkdir()
        prepare_project(project, args.case)
        env = dict(os.environ)
        env.update(
            ORCA_DISABLE_ACCOUNT_RESTORE="1",
            ORCA_DISABLE_UPDATE_CHECKS="1",
            ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS="1",
            XDG_CONFIG_HOME=str(state / "config"),
            XDG_DATA_HOME=str(state / "data"),
            XDG_CACHE_HOME=str(state / "cache"),
        )
        env.pop("ORCA_EDITOR_TEST_CASE", None)
        common = [binary, "--editor", "--path", str(project), "--no-header", "--audio-driver", "Dummy"]
        if not execute([*common, "--headless", "--import", "--quiet"], env):
            return 1
        env["ORCA_EDITOR_TEST_CASE"] = args.case
        display = ["--display-driver", "x11", "--rendering-method", "gl_compatibility"] if args.graphical else ["--headless"]
        if args.case == "remembered_edit_editor_test.gd":
            # Clean editor shutdown saves real EditorSettings; each later process
            # reopens the same configuration, including a distinct project root.
            other_project = state / "other-project"
            other_project.mkdir()
            prepare_project(other_project, args.case)
            import_env = dict(env)
            import_env.pop("ORCA_EDITOR_TEST_CASE", None)
            other_common = [binary, "--editor", "--path", str(other_project), "--no-header", "--audio-driver", "Dummy"]
            if not execute([*other_common, "--headless", "--import", "--quiet"], import_env):
                return 1
            env["ORCA_REMEMBERED_PROJECT_ROOT"] = str(project)
            for phase in ["enable", "verify", "other_project", "revoke", "verify_revoked"]:
                env["ORCA_REMEMBERED_EDIT_TEST_PHASE"] = phase
                command = [*(other_common if phase == "other_project" else common), *display]
                if not execute(command, env, f"remembered_edit_editor_test: 0 failures ({phase})"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (five clean editor processes; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
        if args.case == "localization_editor_test.gd":
            for phase in ["exercise", "restart", "restart_ko"]:
                env["ORCA_LOCALIZATION_TEST_PHASE"] = phase
                if not execute([*common, *display], env, f"localization_editor_test: 0 failures ({phase})"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (three clean editor processes; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
        command = [*common, *display]
        if args.ui_only:
            command += ["--", "--ui-only"]
        marker = {
            "auto_apply_editor_test.gd": "auto_apply_editor_test: 0 failures",
            "editor_ui_scale_test.gd": "editor_ui_scale_test: PASS",
            "update_editor_test.gd": "Update editor: PASS",
            "project_inspection_editor_test.gd": "project_inspection_editor_test: PASS",
        }[args.case]
        if not execute(command, env, marker):
            return 1
        print(f"run_editor_test: PASS {args.case} ({'X11/OpenGL' if args.graphical else 'headless'}; clean exit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
