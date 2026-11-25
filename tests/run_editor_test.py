#!/usr/bin/env python3
"""Run selected editor cases in a normal editor with disposable project/XDG state."""

from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "provider_settings_editor_test.gd": [],
    "provider_adapter_editor_test.gd": [],
    "blender_session_editor_test.gd": ["auto_apply_test.gd", "blender_live_fixture.py", "blender_live_server.py", "fixtures/blender_workspace_scene.tscn"],
    "blender_workspace_editor_test.gd": ["auto_apply_test.gd", "blender_workspace_fixture.py", "fixtures/blender_workspace_scene.tscn"],
    "mcp_editor_test.gd": ["auto_apply_test.gd", "mcp_fixture.py"],
    "editor_transform_test.gd": ["auto_apply_test.gd", "fixtures/editor_transform_game.tscn", "fixtures/editor_transform_coin.tscn", "fixtures/editor_transform_coin.gd", "fixtures/editor_attach_script.gd"],
    "editor_scene_property_test.gd": ["auto_apply_test.gd", "fixtures/editor_property_scene.tscn", "fixtures/editor_attach_other.tscn"],
    "card_status_editor_test.gd": [],
    "task_resume_editor_test.gd": ["auto_apply_test.gd"],
    "editor_scene_script_test.gd": ["auto_apply_test.gd", "fixtures/editor_attach_scene.tscn", "fixtures/editor_attach_other.tscn", "fixtures/editor_attach_script.gd", "fixtures/editor_attach_tool.gd"],
    "auto_apply_editor_test.gd": ["auto_apply_test.gd"],
    "editor_ui_scale_test.gd": ["fixtures/gdscript_function_reader_fixture.gd"],
    "remembered_edit_editor_test.gd": ["auto_apply_test.gd"],
    "update_editor_test.gd": [],
    "localization_editor_test.gd": [],
    "support_reminder_editor_test.gd": [],
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


def import_ci_project(project: Path, binary: str, env: dict[str, str]) -> bool:
    """Import a disposable CI checkout with plugins disabled, then restore exact settings."""
    settings = project / "project.godot"
    original = settings.read_bytes()
    # Recovery mode still parses plugin preloads on Godot 4.7.2. Remove only the
    # editor-plugin section for this import, keeping LF/CRLF and all other bytes.
    disabled = re.sub(rb"(?ms)^\[editor_plugins\]\r?\n.*?(?=^\[|\Z)", b"", original)
    command = [binary, "--headless", "--editor", "--path", str(project), "--import", "--quiet"]
    try:
        settings.write_bytes(disabled)
        return execute(command, env)
    finally:
        settings.write_bytes(original)


def prepare_project(project: Path, case: str, addon_archive: Path | None = None) -> None:
    # Release-like source scope: load the actual addon and the selected case's
    # dependencies, not every unrelated suite in Godot's script-doc generator.
    if addon_archive is None:
        shutil.copytree(ROOT / "addons" / "orca", project / "addons" / "orca",
                        ignore=shutil.ignore_patterns("*.import", "__pycache__", "*.pyc"))
    else:
        # This is a trusted archive freshly produced from the local source by
        # the release packager, not an arbitrary ZIP supplied to this runner.
        with zipfile.ZipFile(addon_archive) as archive:
            archive.extractall(project)
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
        'config/features=PackedStringArray("4.7")\n'
        '[rendering]\n'
        'renderer/rendering_method="gl_compatibility"\n',
        encoding="utf-8",
    )


def plugin_settings() -> str:
    return ('[editor_plugins]\nenabled=PackedStringArray("res://addons/orca/plugin.cfg", '
            '"res://addons/editor_fixture/plugin.cfg")\n')


def enable_plugins(project: Path) -> None:
    # Both clean Git checkouts and release ZIPs need their initial asset import
    # before plugin preloads can resolve SVG/PNG resources.
    settings = project / "project.godot"
    settings.write_text(settings.read_text(encoding="utf-8") + plugin_settings(), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=CASES)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN"))
    parser.add_argument("--graphical", action="store_true", help="Use Linux/X11/OpenGL")
    parser.add_argument("--temp-parent", type=Path, default=os.environ.get("ORCA_TEST_TMPDIR"))
    parser.add_argument("--ui-only", action="store_true", help="Auto-apply layout subset")
    parser.add_argument("--blender-lab-executable", type=Path, help="Opt-in MCP acceptance against an installed official server and an already open default Blender scene")
    parser.add_argument("--blender-workspace-executable", type=Path, help="Opt-in owned Blender workspace acceptance; starts only a disposable workspace")
    parser.add_argument("--blender-session-executable", type=Path, help="Opt-in live-authoring acceptance in an owned disposable interactive Blender")
    args = parser.parse_args()
    if not args.godot:
        parser.error("Set GODOT_BIN or pass --godot")
    if sys.platform != "linux":
        parser.error("This runner currently isolates Linux XDG editor state only")
    if args.ui_only and args.case != "auto_apply_editor_test.gd":
        parser.error("--ui-only is supported only by auto_apply_editor_test.gd")
    if args.blender_session_executable is not None:
        if args.case != "blender_session_editor_test.gd" or args.blender_lab_executable is None or not args.graphical:
            parser.error("Live authoring requires its editor case, --graphical and explicit Blender/MCP executables")
        if not args.blender_session_executable.is_absolute() or not args.blender_session_executable.is_file():
            parser.error("Choose an absolute installed Blender executable")
    if args.blender_lab_executable is not None:
        if args.case not in {"mcp_editor_test.gd", "blender_session_editor_test.gd"}:
            parser.error("--blender-lab-executable is supported only by mcp_editor_test.gd")
        if not args.blender_lab_executable.is_absolute() or not args.blender_lab_executable.is_file() or not os.access(args.blender_lab_executable, os.X_OK):
            parser.error("The Blender Lab executable must be an installed executable at an absolute path")
    if args.blender_workspace_executable is not None:
        if args.case != "blender_workspace_editor_test.gd" or not args.blender_workspace_executable.is_absolute() or not args.blender_workspace_executable.is_file():
            parser.error("--blender-workspace-executable requires the workspace case and an absolute installed Blender path")
    if args.temp_parent is not None and not args.temp_parent.is_dir():
        parser.error("--temp-parent must be an existing directory")
    binary = shutil.which(args.godot)
    if binary is None:
        parser.error("The Godot executable could not be found")
    with tempfile.TemporaryDirectory(prefix="orca-editor-", dir=args.temp_parent) as folder:
        state = Path(folder).resolve(strict=True)
        project = state / "project"
        project.mkdir()
        addon_archive = None
        if args.case == "mcp_editor_test.gd":
            spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
            packaging = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(packaging)
            addon_archive = state / "orca-test.zip"
            packaging.build(ROOT / "addons/orca", addon_archive)
        prepare_project(project, args.case, addon_archive)
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
        env.pop("ORCA_BLENDER_LAB_LIVE_EXECUTABLE", None)
        env.pop("ORCA_BLENDER_WORKSPACE_LIVE_EXECUTABLE", None)
        env.pop("ORCA_BLENDER_SESSION_LIVE_EXECUTABLE", None)
        env.pop("ORCA_BLENDER_SESSION_MCP_EXECUTABLE", None)
        env.pop("ORCA_BLENDER_EDITOR_PHASE", None)
        if args.blender_workspace_executable is not None:
            env["ORCA_BLENDER_WORKSPACE_LIVE_EXECUTABLE"] = str(args.blender_workspace_executable)
        if args.blender_lab_executable is not None:
            env["ORCA_BLENDER_LAB_LIVE_EXECUTABLE"] = str(args.blender_lab_executable)
        if args.blender_session_executable is not None:
            env["ORCA_BLENDER_SESSION_LIVE_EXECUTABLE"] = str(args.blender_session_executable)
            env["ORCA_BLENDER_SESSION_MCP_EXECUTABLE"] = str(args.blender_lab_executable)
        common = [binary, "--editor", "--path", str(project), "--no-header", "--audio-driver", "Dummy"]
        if not execute([*common, "--headless", "--import", "--quiet"], env):
            return 1
        enable_plugins(project)
        env["ORCA_EDITOR_TEST_CASE"] = args.case
        display = ["--display-driver", "x11", "--rendering-method", "gl_compatibility"] if args.graphical else ["--headless"]
        if args.case == "provider_adapter_editor_test.gd":
            for phase in ["exercise", "restart"]:
                env["ORCA_PROVIDER_EDITOR_PHASE"] = phase
                if not execute([*common, *display], env, "provider_adapter_editor_test: PASS"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (two clean editor processes; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
        if args.case == "blender_workspace_editor_test.gd":
            other_project = state / "other-project"
            other_project.mkdir()
            prepare_project(other_project, args.case)
            import_env = dict(env)
            import_env.pop("ORCA_EDITOR_TEST_CASE", None)
            other_common = [binary, "--editor", "--path", str(other_project), "--no-header", "--audio-driver", "Dummy"]
            if not execute([*other_common, "--headless", "--import", "--quiet"], import_env):
                return 1
            enable_plugins(other_project)
            env["ORCA_BLENDER_ORIGINAL_ROOT"] = str(project)
            for phase in ["exercise", "restart", "other_project", "revoke", "verify_revoked"]:
                env["ORCA_BLENDER_EDITOR_PHASE"] = phase
                command = other_common if phase == "other_project" else common
                if not execute([*command, *display], env, "blender_workspace_editor_test: PASS"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (five clean editor processes, two projects; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
        if args.case == "mcp_editor_test.gd":
            other_project = state / "other-project"
            other_project.mkdir()
            prepare_project(other_project, args.case, addon_archive)
            import_env = dict(env)
            import_env.pop("ORCA_EDITOR_TEST_CASE", None)
            other_common = [binary, "--editor", "--path", str(other_project), "--no-header", "--audio-driver", "Dummy"]
            if not execute([*other_common, "--headless", "--import", "--quiet"], import_env):
                return 1
            enable_plugins(other_project)
            env["ORCA_MCP_ORIGINAL_ROOT"] = str(project)
            for phase in ["migration", "exercise", "restart", "other_project", "other_restart", "original_verify", "after_remove"]:
                env["ORCA_MCP_EDITOR_PHASE"] = phase
                command = other_common if phase in {"other_project", "other_restart"} else common
                if not execute([*command, *display], env, "mcp_editor_test: PASS"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (seven clean editor processes, two ZIP-installed project roots; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
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
            enable_plugins(other_project)
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
        if args.case == "support_reminder_editor_test.gd":
            for phase in ["exercise", "restart"]:
                env["ORCA_SUPPORT_TEST_PHASE"] = phase
                if not execute([*common, *display], env, f"support_reminder_editor_test: PASS ({phase})"):
                    return 1
            print(f"run_editor_test: PASS {args.case} (two clean editor processes; {'X11/OpenGL' if args.graphical else 'headless'})")
            return 0
        command = [*common, *display]
        if args.ui_only:
            command += ["--", "--ui-only"]
        marker = {
            "provider_settings_editor_test.gd": "provider_settings_editor_test: PASS",
            "provider_adapter_editor_test.gd": "provider_adapter_editor_test: PASS",
            "blender_session_editor_test.gd": "blender_session_editor_test: PASS",
            "blender_workspace_editor_test.gd": "blender_workspace_editor_test: PASS",
            "mcp_editor_test.gd": "mcp_editor_test: PASS",
            "editor_transform_test.gd": "editor_transform_test: PASS",
            "editor_scene_property_test.gd": "editor_scene_property_test: PASS",
            "card_status_editor_test.gd": "card_status_editor_test: PASS",
            "task_resume_editor_test.gd": "task_resume_editor_test: PASS",
            "editor_scene_script_test.gd": "editor_scene_script_test: PASS",
            "auto_apply_editor_test.gd": "auto_apply_editor_test: 0 failures",
            "editor_ui_scale_test.gd": "editor_ui_scale_test: PASS",
            "update_editor_test.gd": "Update editor: PASS",
            "project_inspection_editor_test.gd": "project_inspection_editor_test: PASS",
            "support_reminder_editor_test.gd": "support_reminder_editor_test: PASS",
        }[args.case]
        if not execute(command, env, marker):
            return 1
        print(f"run_editor_test: PASS {args.case} ({'X11/OpenGL' if args.graphical else 'headless'}; clean exit)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
