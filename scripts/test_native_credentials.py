#!/usr/bin/env python3
"""Real helper/Godot acceptance in disposable projects and isolated native vaults."""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from build_native_helper import helper_name

ROOT = Path(__file__).resolve().parents[1]


def command(arguments: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, capture_output=True, check=True, timeout=180, **kwargs)


@contextlib.contextmanager
def macos_vault(directory: Path):
    def security(*arguments: str) -> str:
        return command(["security", *arguments], text=True).stdout

    previous_default = shlex.split(security("default-keychain", "-d", "user"))
    previous_search = shlex.split(security("list-keychains", "-d", "user"))
    keychain = str(directory / "orca-test.keychain-db")
    password = secrets.token_hex(32)  # Disposable Keychain password, never an account credential.
    created = False
    try:
        security("create-keychain", "-p", password, keychain)
        created = True
        security("set-keychain-settings", "-lut", "21600", keychain)
        security("unlock-keychain", "-p", password, keychain)
        security("list-keychains", "-d", "user", "-s", keychain)
        security("default-keychain", "-d", "user", "-s", keychain)
        yield
    finally:
        try:
            if previous_default:
                security("default-keychain", "-d", "user", "-s", previous_default[0])
        finally:
            try:
                security("list-keychains", "-d", "user", "-s", *previous_search)
            finally:
                if created:
                    security("delete-keychain", keychain)


@contextlib.contextmanager
def linux_vault():
    daemon = subprocess.Popen(["gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        daemon.stdin.write(secrets.token_hex(32).encode())
        daemon.stdin.close()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            owner = command(["gdbus", "call", "--session", "--dest", "org.freedesktop.DBus", "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner", "org.freedesktop.secrets"], text=True)
            if "true" in owner.stdout:
                break
            if daemon.poll() is not None:
                raise RuntimeError("Private Secret Service exited during startup")
            time.sleep(0.1)
        else:
            raise RuntimeError("Private Secret Service did not start")
        yield
    finally:
        if daemon.poll() is None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
                daemon.wait(timeout=5)


def acceptance(godot: str, directory: Path) -> None:
    project = directory / "project"
    native = project / "addons/orca/native"
    scripts = project / "addons/orca/scripts"
    tests = project / "tests"
    for path in (native, scripts, tests):
        path.mkdir(parents=True, exist_ok=True)
    helper = native / helper_name()
    shutil.copy2(ROOT / "addons/orca/native" / helper.name, helper)
    helper.chmod(0o755)
    shutil.copy2(ROOT / "addons/orca/scripts/credential_store.gd", scripts)
    for name in ("native_helper_service.gd", "update_package.gd"):
        shutil.copy2(ROOT / "addons/orca/scripts" / name, scripts)
    shutil.copy2(ROOT / "tests/credential_store_test.gd", tests)
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    cache = directory / "native-cache"
    cached = cache / digest / helper.name
    cached.parent.mkdir(parents=True)
    shutil.copy2(helper, cached)
    system, arch = helper.name.removeprefix("credential_helper_").removesuffix(".exe").split(".")
    (project / "addons/orca/plugin.cfg").write_text('[plugin]\nname="Orca"\nversion="1.4.0"\nscript="orca.gd"\n')
    (project / "addons/orca/native_helpers.json").write_text(json.dumps({"format": "orca-native-helpers-v1", "version": "1.4.0", "helpers": [{"platform": system, "architecture": arch, "asset": helper.name, "size": helper.stat().st_size, "sha256": digest}]}))
    (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Orca native vault fixture"\n', encoding="utf-8")
    scope = secrets.token_hex(32)
    environment = {**os.environ, "ORCA_DISABLE_ACCOUNT_RESTORE": "1", "ORCA_DISABLE_UPDATE_CHECKS": "1", "ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS": "1", "ORCA_TEST_VAULT_SCOPE": scope, "ORCA_TEST_HELPER_CACHE": str(cache)}
    arguments = [godot, "--headless", "--path", str(project), "--script", "res://tests/credential_store_test.gd"]
    try:
        # Exact bytes catch CRT CRLF conversion before exercising the GDScript pipe.
        for payload in (b"release\n", b"put\rfixture\n", b"put " + b"A" * 16385 + b"\n"):
            result = command([str(helper), scope], input=payload)
            if result.stdout != b"READY\n":
                raise RuntimeError("Helper violated the bounded LF-only pipe protocol")
        invalid = subprocess.run([str(helper), "invalid-scope"], input=b"release\n", capture_output=True, timeout=10)
        if invalid.returncode != 1 or invalid.stdout:
            raise RuntimeError("Helper accepted an invalid namespace")
        for phase in ("", "save", "restore", "erase"):
            result = command(arguments, env={**environment, "ORCA_TEST_VAULT_PHASE": phase}, text=True)
            if "PASS" not in result.stdout or "SCRIPT ERROR" in result.stdout + result.stderr:
                raise RuntimeError("Native Godot vault fixture did not pass")
            print(f"Native {platform.system()} vault: {phase or 'round-trip/locking'} PASS")
    finally:
        # Even a failed Windows fixture deletes only this random synthetic record.
        command(arguments, env={**environment, "ORCA_TEST_VAULT_PHASE": "cleanup"}, text=True)
        if platform.system() != "Windows":
            (Path("/tmp") / f"orca-vault-{os.getuid()}-{scope}.lock").unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN"))
    parser.add_argument("--private-linux-session", action="store_true", help=argparse.SUPPRESS)
    options = parser.parse_args()
    if not options.godot:
        parser.error("Set GODOT_BIN or pass --godot")
    godot = str(Path(options.godot).resolve())
    parent = os.environ.get("ORCA_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
    with tempfile.TemporaryDirectory(prefix="orca-native-test-", dir=parent) as temporary:
        directory = Path(temporary)
        if platform.system() == "Linux" and not options.private_linux_session:
            environment = {**os.environ, "HOME": str(directory), "ORCA_PRIVATE_VAULT_SESSION": "1"}
            for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
                path = directory / name.lower()
                path.mkdir(mode=0o700)
                environment[name] = str(path)
            for name in ("DBUS_SESSION_BUS_ADDRESS", "DBUS_STARTER_ADDRESS", "DBUS_STARTER_BUS_TYPE", "GNOME_KEYRING_CONTROL", "DISPLAY", "SESSION_MANAGER"):
                environment.pop(name, None)
            return subprocess.run(["dbus-run-session", "--", sys.executable, str(Path(__file__).resolve()), "--godot", godot, "--private-linux-session"], env=environment, timeout=900).returncode
        if platform.system() == "Linux":
            if os.environ.get("ORCA_PRIVATE_VAULT_SESSION") != "1":
                raise RuntimeError("Refusing a non-isolated Linux credential test")
            with linux_vault():
                acceptance(godot, directory)
        elif platform.system() == "Darwin":
            with macos_vault(directory):
                acceptance(godot, directory)
        else:
            # Windows Credential Manager is per runner user; scopes are random and erased.
            acceptance(godot, directory)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        # Commands/SDK replies can contain vault data or a temporary Keychain password.
        print(f"Native credential acceptance failed ({type(error).__name__}); no vault output logged.", file=sys.stderr)
        sys.exit(1)
