# Orca interface languages

Published Orca **1.7.0** added **English**, **简体中文 (Simplified Chinese)**,
**Español (Spanish)**, **日本語 (Japanese)** and **한국어 (Korean)** under
**Settings → System → Language**. The **1.8.0 candidate** extends localized
card layouts, task Resume, current-scene reviews and live-baseline disclosures.
See the [1.7.0 changelog](../CHANGELOG.md#170---2026-11-06) for the published
language feature and [1.8.0](../CHANGELOG.md#180---2026-11-13) for the candidate.

## User behavior

- English is the initial default. Selection updates existing Orca controls without
  restarting the editor, rebuilding the conversation or dismissing a review.
- The exact supported locale (`en`, `zh_CN`, `es`, `ja`, `ko`) is saved under
  `orca/interface/language` in local Godot EditorSettings. It is an editor-wide
  preference across projects, not project metadata or a conversation setting.
- Bundled catalogs work offline. Orca's domain and locale override do not change
  the Godot editor language, project locale or project translation resources.
- Replies follow an explicit requested language, otherwise the language of the
  current user message. When unclear, Orca asks the model to use the selected
  interface language. Models may still fail to follow this instruction.
- Response-language guidance is captured before request-start callbacks and held
  through tool continuations, Plan-to-Work and finalization. The next user turn
  captures the new selection. It is removed from persisted continuation.
- Original prompts, responses, task descriptions, script/code/diff bytes, model
  names, paths and raw diagnostic/tool evidence retain their original text.
  Interface captions, summaries and known Orca-owned notices are localized.
- Language selection does not change Plan/Work, provider compatibility, approval,
  execution trust, Auto apply or remembered project edit authorization.

## Implementation

`addons/orca/scripts/localization.gd` registers the private `orca.interface`
TranslationDomain. Owned top-level surfaces attach before child construction;
descendants inherit the domain. Weak surface references and exit hooks release
the domain when the last attached surface exits.

Native control auto-translation retains original English labels and refreshes
them via a translation-change notification restricted to Orca's surfaces.
Formatted labels use `Localization.bind()` or `bind_parts()` with a source
template and immutable display arguments. Bindings refresh owned internal
controls too, such as OptionButton's public PopupMenu, and discard superseded
values. No provider form loading, remote discovery, session restoration or
approval callbacks are triggered by refresh.

Mark a known Orca-owned string argument with `Localization.source()` when it
needs translation. Leave user/model/source arguments unmarked. Disable native
auto-translation on message bodies, model names, code/diffs, task text and raw
evidence so a user string equal to an interface key is not accidentally translated.
Internal tool schemas, result strings, statuses, IDs and permission checks remain
canonical; localized captions must never determine runtime outcomes.

The source catalogs are:

- `addons/orca/translations/zh_CN.po`
- `addons/orca/translations/es.po`
- `addons/orca/translations/ja.po`
- `addons/orca/translations/ko.po`

English source strings are the keys and fallback, so no English catalog is needed.
The first catalogs use singular entries; counts select complete singular/plural
templates rather than appending English suffixes. Chinese, Japanese and Korean
translate both forms identically where no plural distinction is needed. Languages requiring
additional plural categories need extended count contracts before advertising support.

## Updating translations

1. Add or update the English interface source/template at its construction site.
2. Add the matching `msgid` and translated `msgstr` to all bundled catalogs. Preserve the
   ordered `%s`, `%d`, numeric-format and literal markup placeholders exactly.
3. Translate complete phrases, including permission scope, approval stages and
   recovery limitations. Preserve Godot/API identifiers, brand names and paths.
4. Check labels, wrapping, tooltips, accessible names, dialogs and larger fonts.
5. Run the catalog checks and isolated editor case:

   ```bash
   python3 -m unittest discover -s tests -p translation_catalog_test.py -v
   python3 tests/run_editor_test.py localization_editor_test.gd
   python3 tests/run_editor_test.py localization_editor_test.gd --graphical
   ```

Set `GODOT_BIN` to Godot 4.7.2. The runner isolates project/configuration/data/cache,
suppresses account restore/update checks/helper downloads, and verifies three clean
editor processes for switching, Japanese restart persistence, then Korean restart
persistence. It rejects errors, warnings,
crashes and missing completion. CI includes both catalog and headless editor checks.

## Acceptance and limits

The case covers five-language switching, Japanese/Korean restart persistence and
300-unit layouts at normal/1.5×/2× fonts, System/Provider/About, History and
activity/review surfaces, exact model and source
identity, retained drafts/selection/attachments, an open expanded diff, execution
trust presentation, a real reviewed patch/Revert, turn-fixed language, matching
English tool receipts, Japanese/Korean tool continuations and cancellation.

Linux/X11/OpenGL acceptance and synthetic Chinese/Spanish/Japanese/Korean Settings
renders are verified. Translations have not had independent native-speaker review. Other
platforms, themes and real-model response-language adherence remain manual.
Unknown messages fall back to English; raw engine/provider/process diagnostics,
external browser pages and platform-native dialogs retain their original language.
No translation downloads, screenshot intake or automatic transcript translation
are introduced.
