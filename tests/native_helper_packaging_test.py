"""Release assembly checks; synthetic headers do not stand in for native execution."""
from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import stat
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


def headers() -> dict[str, bytes]:
    linux = bytearray(64)
    linux[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<HH", linux, 16, 3, 62)
    windows = bytearray(128)
    windows[:2] = b"MZ"
    struct.pack_into("<I", windows, 60, 64)
    windows[64:68] = b"PE\0\0"
    struct.pack_into("<H", windows, 68, 0x8664)
    result = {"native/credential_helper_linux.x86_64": bytes(linux), "native/credential_helper_windows.x86_64.exe": bytes(windows)}
    for architecture, cpu in (("arm64", 0x100000C), ("x86_64", 0x1000007)):
        macos = bytearray(64)
        macos[:4] = b"\xcf\xfa\xed\xfe"
        struct.pack_into("<I", macos, 4, cpu)
        struct.pack_into("<I", macos, 12, 2)
        result[f"native/credential_helper_macos.{architecture}"] = bytes(macos)
    return result


class NativePackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="orca-native-package-", dir=os.environ.get("ORCA_TEST_TMPDIR"))
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "addon"
        (self.source / "native").mkdir(parents=True)
        (self.source / "plugin.cfg").write_text('[plugin]\nname="Orca"\nversion="1.4.0"\nscript="orca.gd"\n')
        (self.source / "orca.gd").write_text("@tool\nextends EditorPlugin\n")
        for name, data in headers().items():
            (self.source / name).write_bytes(data)

    def test_binary_free_zip_pins_separately_published_assets(self) -> None:
        archive = self.root / "complete.zip"
        assets = self.root / "assets"
        packaging.build(self.source, archive, require_platform_helpers=True, write_manifest=True, helper_assets=assets)
        with zipfile.ZipFile(archive) as reader:
            manifest = reader.read("addons/orca/update_manifest.json")
            self.assertEqual(manifest, (self.source / packaging.MANIFEST).read_bytes())
            entries = {entry["path"]: entry for entry in json.loads(manifest)["files"]}
            catalog_bytes = reader.read("addons/orca/native_helpers.json")
            self.assertEqual(catalog_bytes, (self.source / packaging.HELPER_CATALOG).read_bytes())
            catalog = json.loads(catalog_bytes)
            self.assertEqual(catalog["format"], "orca-native-helpers-v1")
            self.assertEqual(catalog["version"], "1.4.0")
            descriptors = {item["asset"]: item for item in catalog["helpers"]}
            for name, data in headers().items():
                self.assertNotIn("addons/orca/" + name, reader.namelist())
                self.assertNotIn(name, entries)
                descriptor = descriptors[Path(name).name]
                self.assertEqual((assets / descriptor["asset"]).read_bytes(), data)
                self.assertEqual(descriptor["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(descriptor["size"], len(data))
            for item in reader.infolist():
                self.assertEqual(stat.S_IMODE(item.external_attr >> 16), 0o644)
                self.assertFalse(packaging.native_binary(reader.read(item)))
            self.assertTrue(all(not item["executable"] for item in entries.values()))
            self.assertNotIn(packaging.MANIFEST, entries)
        # Regenerate a previously committed manifest after bytes change, explicitly.
        (self.source / "orca.gd").write_text("@tool\nextends EditorPlugin\n# revised release\n")
        packaging.build(self.source, self.root / "revised.zip", require_platform_helpers=True, write_manifest=True, helper_assets=self.root / "revised-assets")
        self.assertNotEqual(manifest, (self.source / packaging.MANIFEST).read_bytes())

    def test_every_missing_platform_blocks_release_without_writing_manifest(self) -> None:
        for missing, data in headers().items():
            with self.subTest(missing=missing):
                (self.source / missing).unlink()
                archive = self.root / "missing.zip"
                with self.assertRaisesRegex(ValueError, "Missing required platform helpers"):
                    packaging.build(self.source, archive, require_platform_helpers=True, write_manifest=True, helper_assets=self.root / "assets")
                self.assertFalse(archive.exists())
                self.assertFalse((self.source / packaging.MANIFEST).exists())
                (self.source / missing).write_bytes(data)

    def test_wrong_native_format_architecture_and_truncated_pe_are_rejected(self) -> None:
        good = headers()
        for name in good:
            bad = {**good, name: b"not a native executable"}
            with self.subTest(name=name), self.assertRaises(ValueError):
                packaging.validate_platform_helpers(bad)
        bad = {**good, "native/credential_helper_macos.arm64": good["native/credential_helper_macos.x86_64"]}
        with self.assertRaises(ValueError):
            packaging.validate_platform_helpers(bad)
        for offset in (0, 127, 0xFFFFFFFF):
            broken = bytearray(good["native/credential_helper_windows.x86_64.exe"])
            struct.pack_into("<I", broken, 60, offset)
            with self.assertRaises(ValueError):
                packaging.validate_platform_helpers({**good, "native/credential_helper_windows.x86_64.exe": bytes(broken)})

    def test_unknown_helper_names_and_in_addon_output_are_rejected(self) -> None:
        (self.source / "native/credential_helper_macos.aarch64").write_bytes(b"wrong filename")
        with self.assertRaisesRegex(ValueError, "Unknown credential helper filename"):
            packaging.build(self.source, self.root / "wrong.zip")
        with self.assertRaisesRegex(ValueError, "outside the source addon"):
            packaging.build(self.source, self.source / "release.zip", write_manifest=True)
        self.assertFalse((self.source / "release.zip").exists())

    def test_extensionless_and_disguised_native_files_are_rejected(self) -> None:
        for name, data in [("hidden-tool", headers()["native/credential_helper_linux.x86_64"]), ("asset.png", b"MZ" + bytes(64)), ("extra.dll", b"not text source")]:
            path = self.source / name
            path.write_bytes(data)
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Compiled native files"):
                packaging.build(self.source, self.root / "bad.zip")
            path.unlink()

    def test_plain_packaging_excludes_helpers_and_official_packaging_requires_assets(self) -> None:
        archive = self.root / "plain.zip"
        packaging.build(self.source, archive)
        with zipfile.ZipFile(archive) as reader:
            self.assertFalse(any("credential_helper_" in name for name in reader.namelist()))
        with self.assertRaisesRegex(ValueError, "separate --helper-assets"):
            packaging.build(self.source, self.root / "official.zip", require_platform_helpers=True)
        with self.assertRaisesRegex(ValueError, "outside the addon"):
            packaging.build(self.source, self.root / "inside.zip", helper_assets=self.source / "assets")

    def test_partial_developer_catalog_and_no_overwrite(self) -> None:
        for name in headers():
            if "linux" not in name:
                (self.source / name).unlink()
        assets = self.root / "assets"
        packaging.build(self.source, self.root / "local.zip", helper_assets=assets)
        with zipfile.ZipFile(self.root / "local.zip") as reader:
            self.assertEqual(len(json.loads(reader.read("addons/orca/native_helpers.json"))["helpers"]), 1)
        with self.assertRaisesRegex(ValueError, "overwrite an existing helper"):
            packaging.build(self.source, self.root / "again.zip", helper_assets=assets)

    def test_pinned_source_catalog_cannot_silently_change(self) -> None:
        packaging.build(self.source, self.root / "first.zip", helper_assets=self.root / "assets", require_platform_helpers=True, write_manifest=True)
        helper = self.source / "native/credential_helper_linux.x86_64"
        helper.write_bytes(helper.read_bytes() + b"rebuild")
        with self.assertRaisesRegex(ValueError, "Source helper catalog differs"):
            packaging.build(self.source, self.root / "changed.zip", helper_assets=self.root / "changed-assets", require_platform_helpers=True)
        self.assertFalse((self.root / "changed.zip").exists())


if __name__ == "__main__":
    unittest.main()
