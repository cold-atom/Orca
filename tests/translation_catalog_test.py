"""Validate shipped PO catalogs and directly authored Orca interface strings."""

import ast
from collections import Counter
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1] / "addons" / "orca"
UI_FILES = (
    "settings_view", "chat_window", "history_view", "change_card",
    "input_map_change_card", "main_scene_change_card", "project_settings_change_card",
    "scene_change_card", "tool_activity_card", "tool_activity_group", "card_header", "task_list_panel",
    "mode_switch_card", "image_attachment_window", "image_attachment_tray",
    "script_reference_tray", "connection_setup_panel", "update_panel", "support_card",
)
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
PLACEHOLDER = re.compile(r"%(?:[-+0-9.# ]*)[sdifuxX]")


def parse_po(text):
    """The deliberately small shipped format: headers and singular UTF-8 entries."""
    entries = {}
    current = None
    target = None
    for line in text.splitlines():
        if not line.strip():
            if current:
                if current in entries:
                    raise ValueError(f"Duplicate message: {current}")
                entries[current] = target
            current = target = None
        elif line.startswith("msgid "):
            current = ast.literal_eval(line[6:])
        elif line.startswith("msgstr "):
            target = ast.literal_eval(line[7:])
        elif line.startswith('"'):
            if target is None:
                raise ValueError("Unexpected continuation")
            target += ast.literal_eval(line)
        elif not line.startswith("#"):
            raise ValueError(f"Unsupported PO line: {line}")
    if current:
        if current in entries:
            raise ValueError(f"Duplicate message: {current}")
        entries[current] = target
    return entries


class TranslationCatalogTest(unittest.TestCase):
    maxDiff = None

    def test_catalog_parity_and_format_contracts(self):
        catalogs = [parse_po((ROOT / "translations" / name).read_text(encoding="utf-8"))
                    for name in ("zh_CN.po", "es.po", "ja.po", "ko.po")]
        for catalog in catalogs:
            self.assertEqual(catalogs[0].keys(), catalog.keys())
            for source, translated in catalog.items():
                with self.subTest(source=source, translated=translated):
                    self.assertTrue(translated and translated.strip())
                    self.assertEqual(PLACEHOLDER.findall(source), PLACEHOLDER.findall(translated))
                    self.assertEqual(Counter(re.findall(r"</?[a-z]+>", source)),
                                     Counter(re.findall(r"</?[a-z]+>", translated)))

    def test_fixed_ui_text_has_translations(self):
        catalog = parse_po((ROOT / "translations" / "es.po").read_text(encoding="utf-8"))
        # Technical identities and original user/source data are intentional.
        unchanged = {"ORCA", "Orca", "API", "Chat Completions", "GitHub", "GDScript",
                     "English", "简体中文", "Español", "日本語", "한국어", "s", "gpt-4o", "Unknown model",
                     "Conversation", "No prompt preview", "Image", "Pasted image.png", "Free", "Godot "}
        markers = re.compile(r"\.(?:text|tooltip_text|placeholder_text|dialog_text|ok_button_text|accessibility_name|title)\s*=|(?:_field_label|_about_heading|add_item|Localization\.bind)\(")
        missing = set()
        for name in UI_FILES:
            for line in (ROOT / "scripts" / f"{name}.gd").read_text(encoding="utf-8").splitlines():
                if not markers.search(line):
                    continue
                for token in STRING.findall(line):
                    value = ast.literal_eval(token)
                    if not value or value in unchanged or value.startswith(("res://", "http", "[", "#")):
                        continue
                    if not (value[0].isupper() and (value.isupper() or " " in value or value[1:].islower())):
                        continue
                    if value not in catalog:
                        missing.add(value)
        for scene in (ROOT / "scenes").glob("*.tscn"):
            for match in re.finditer(r'^(?:text|tooltip_text|placeholder_text) = ("(?:[^"\\]|\\.)*")', scene.read_text(encoding="utf-8"), re.M):
                value = ast.literal_eval(match[1])
                if value and value not in unchanged and value not in catalog:
                    missing.add(value)
        self.assertEqual(sorted(missing), [])

    def test_duplicate_messages_are_rejected(self):
        with self.assertRaises(ValueError):
            parse_po('msgid "Apply"\nmsgstr "Aplicar"\n\nmsgid "Apply"\nmsgstr "Aplicar"\n')


if __name__ == "__main__":
    unittest.main()
