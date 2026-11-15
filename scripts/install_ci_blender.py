"""Install pinned official Blender for disposable CI acceptance, never plugin startup."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

VERSION = "5.2.2"
ASSETS = {
    "Linux": ("blender-5.2.2-linux-x64.tar.xz", "84098912789dc450e95697c4184fb8a90acbe5111c2ba4aede3fecb57806a168"),
    "Windows": ("blender-5.2.2-windows-x64.zip", "3849d17a682cba006075aaa3f3597ecb5c9c30ec31035b2e092c53e40679b535"),
    "Darwin": ("blender-5.2.2-macos-arm64.dmg", "dc4125399b8bfefe283cc1624d6cfc7809d1cac20ace51072127eb371f31f210"),
}


def main():
    system = platform.system()
    if system not in ASSETS or (system == "Darwin" and platform.machine() != "arm64"):
        raise SystemExit("No official pinned Blender 5.2.2 asset for this CI platform")
    filename, expected = ASSETS[system]
    root = Path(".ci/blender").resolve()
    if root.exists():
        raise SystemExit("Refusing to replace an existing CI Blender directory")
    root.mkdir(parents=True)
    archive = root / filename
    request = urllib.request.urlopen("https://download.blender.org/release/Blender5.2/" + filename, timeout=60)
    digest = hashlib.sha256()
    size = 0
    with archive.open("xb") as output:
        while chunk := request.read(1024 * 1024):
            size += len(chunk)
            if size > 512 * 1024 * 1024:
                raise SystemExit("Official Blender archive exceeds the CI download budget")
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != expected:
        raise SystemExit("Official Blender checksum mismatch")
    if system == "Linux":
        with tarfile.open(archive) as package:
            package.extractall(root, filter="data")
        binary = root / "blender-5.2.2-linux-x64/blender"
    elif system == "Windows":
        with zipfile.ZipFile(archive) as package:
            for info in package.infolist():
                if not (root / info.filename).resolve().is_relative_to(root):
                    raise SystemExit("Unsafe official ZIP path")
            package.extractall(root)
        binary = root / "blender-5.2.2-windows-x64/blender.exe"
    else:
        mount = root / "mounted"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", str(archive), "-nobrowse", "-mountpoint", str(mount)], check=True)
        try:
            shutil.copytree(mount / "Blender.app", root / "Blender.app", symlinks=True)
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True)
        binary = root / "Blender.app/Contents/MacOS/Blender"
    if "GITHUB_ENV" in os.environ:
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as output:
            output.write("ORCA_TEST_BLENDER_BIN=" + str(binary) + "\n")
    print(binary)


if __name__ == "__main__":
    main()
