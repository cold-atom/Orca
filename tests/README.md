# Orca Tests

Set `ORCA_DISABLE_ACCOUNT_RESTORE=1`, `ORCA_DISABLE_UPDATE_CHECKS=1` and
`ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1` for ordinary editor tests so startup neither
restores owner credentials nor sends update checks/background component downloads.

## Normal-editor fixture runner

`auto_apply_editor_test.gd`, `remembered_edit_editor_test.gd`, `editor_ui_scale_test.gd`, `localization_editor_test.gd`
and `update_editor_test.gd` extend the tool Node in
`editor_test_case.gd`. Run them through `run_editor_test.py`, which enables a
test-only EditorPlugin in a disposable project and uses the editor's existing
SceneTree. It imports the actual addon and only the selected case's dependencies,
isolates Linux `XDG_CONFIG_HOME`, `XDG_DATA_HOME` **and `XDG_CACHE_HOME`**, sets all
three startup suppressions, bounds both processes, and removes the entire fixture.
It requires the case's completion marker, exit code 0, and no engine errors or
warnings, including shutdown diagnostics. Five runner regressions reject native
crashes, missing completion and error/leak output even after `0 failures`.

```bash
python3 -m unittest discover -s tests -p editor_test_runner_test.py -v
python3 tests/run_editor_test.py auto_apply_editor_test.gd
python3 tests/run_editor_test.py auto_apply_editor_test.gd --graphical
python3 tests/run_editor_test.py remembered_edit_editor_test.gd
python3 tests/run_editor_test.py remembered_edit_editor_test.gd --graphical
python3 tests/run_editor_test.py editor_ui_scale_test.gd
python3 tests/run_editor_test.py editor_ui_scale_test.gd --graphical
python3 tests/run_editor_test.py update_editor_test.gd
python3 tests/run_editor_test.py update_editor_test.gd --graphical
python3 tests/run_editor_test.py localization_editor_test.gd
python3 tests/run_editor_test.py localization_editor_test.gd --graphical
```

Set `GODOT_BIN` to Godot 4.7.2; `--godot` and `--temp-parent` are optional.
The graphical path is Linux/X11/OpenGL. This runner currently supports Linux
isolation; it does not claim Windows/macOS fixture acceptance. Do not launch
these Node cases with `--editor --script`. Other legacy editor cases below
retain their existing entry points until separately migrated.

## Interface localization (unreleased)

```bash
python3 -m unittest discover -s tests -p translation_catalog_test.py -v
python3 tests/run_editor_test.py localization_editor_test.gd
python3 tests/run_editor_test.py localization_editor_test.gd --graphical
```

Catalog tests enforce matching Chinese/Spanish/Japanese/Korean keys, nonempty translations,
ordered formatting/markup placeholders, duplicate rejection and fixed authored
UI coverage. The editor case runs three clean processes sharing isolated settings
to verify live English/Chinese/Spanish/Japanese/Korean switching, saved Japanese
restoration and then saved Korean restoration.
It covers 300-unit normal/1.5×/2× System/Provider/About and review/activity/History
layouts, original messages/model/code/evidence, drafts/selection/images/scripts,
an open expanded diff, execution-trust presentation, unchanged authorization,
actual Work review/apply/Revert, turn-fixed language across reentry/Plan-to-Work/
tool follow-ups (including Japanese and Korean), matching original receipts and cancellation cleanup.
Headless and Linux/X11/OpenGL acceptance pass with clean exits and no diagnostics.
Independent native-speaker review, other platforms/themes and live-model language
adherence remain manual. Details: [`docs/LOCALIZATION.md`](../docs/LOCALIZATION.md).

## Session Auto apply and recovery (1.6.0)

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/auto_apply_test.gd
python3 tests/run_editor_test.py auto_apply_editor_test.gd
python3 tests/run_editor_test.py auto_apply_editor_test.gd --graphical
```

The runner isolates Linux editor preferences, user data, cache and project files.
Startup suppression alone does not isolate saved provider settings. Use disposable
editor configuration/project data on other platforms too; teardown restoration is
additional protection, not a substitute for isolation after a fixture failure.

The component fixture uses synthetic provider responses, real validated script
replacement and isolated session storage. It checks default review/Plan denial,
consecutive automatic edits and valid tool results, turn/grant revocation,
pre/post-checkpoint failure, cancellation before/during commit, stale independent
edits, invalid source, protected paths, singleton batches, bounded strict journal
records and non-replaying recovery. A separate headless Godot process loads the
durable record, restores no permission, and explicitly reverts/checkpoints the
exact script. Negative-source validation emits an expected parser diagnostic.

The real editor fixture exercises empty-state-chip and compact-header confirmation/dismissal, stale
session decisions, active-turn revocation, matching automatic/manual inline diff cards,
actual History restoration and lazy expanded diffs, real dirty editor-buffer denial
for automatic apply and restored revert, and actual 300-unit layouts at
normal/1.5×/2× fonts. It checks empty-state overlay placement and replacement by
a fixed 24-unit icon-only header control after Auto apply or conversation content,
unchanged header/feed/composer/empty-state geometry when state/fonts/visibility change,
caption/icon containment at 300 units and a bounded header at 220 units,
unobstructed conversation/diff space, actual wheel scrolling/text selection, mouse-click
header revocation/confirmation (including active-turn clicks while modes/settings are locked),
green/muted state, keyboard accessibility and Settings/History hiding,
the original two-child composer, bounded first/repeated dialog
openings, scrolling-body bounds and visible non-overlapping confirmation actions.
Checkpoint-only recovery after visible-event compaction also uses the header,
without restoring an empty-state logo or floating chip over the review cards.
It uses a private session root and synthetic client, restores provider settings,
closes/removes its scripts and performs no live model/account/browser request.
Both full headless and graphical runs exit cleanly with no RID/ObjectDB/GL warnings.
Manual acceptance covers real project usefulness, light themes, other platforms and power-loss boundaries;
component downloads and owner authentication remain suppressed.

The remembered-preference editor case runs **five separate clean editor processes**
with the same isolated configuration: enable, restart/verify, a different project
root, revoke, and restart/verify revoked. It exercises the actual shared checkbox
and System setting, unchecked/cancelled/stale confirmation, session and pending
script authorization, normal startup, new sessions, resumable/view-only/Plan
restoration, rejected/approved Plan-to-Work requests, strict malformed/root/revision
denial, checkpoint-failure pause, revision drift before writing, valid tool receipts
and real durable pending-proposal application. Different/copied project roots
cannot inherit authority. The preference never enters conversation snapshots.
The runner verifies every process's marker, exit and diagnostics and deletes both
projects/configuration/data/cache. UI scale checks include System script-edit
controls and the visible remember checkbox above fixed dialog actions at larger fonts.

For a layout-only subset, pass `--ui-only` to the runner.
This path exercises real first/repeated permission popups, scrolling explanation
and fixed footer at larger fonts, empty/compact permission presentation and rendered inline/expanded
cards using synthetic data; it performs no project writes or filesystem rescan.
It does not replace the full editing/dirty-buffer/recovery suite. On 2026-11-04,
the new runner passed both complete cases headlessly and on Linux/X11/OpenGL at
2× editor scale, with zero errors/warnings and clean exit codes. The previous
`--editor --script` harness created an orphan SceneTree in Godot 4.7.2, causing
`current_window is null` and resource leaks. GDB also identified a background
script-documentation traversal reading freed filesystem memory during rapid
rescans/teardown. The normal-editor, focused-project runner corrects the fixture
lifecycle and avoids that early-teardown workload. The engine itself is not
patched; the independently reproduced large-project/early-quit race remains
an upstream Godot limitation. Diagnosis and exact source references are in
`DEVELOPMENT.md` under editor-fixture lifecycle.

## Connection onboarding

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/agent_controller_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/onboarding_editor_test.gd
```

The controller rejects missing credentials/account/model before any accepted turn.
The editor fixture uses actual overlay/composer/Settings controls with synthetic
account/model/request services and memory-only conversation storage. It checks
first-run versus existing-user state, keyless local providers, restoration,
single-card repeated Send, pairing cancellation and automatic managed-model
selection, actual BYOK Done saving, focused model navigation, unchanged draft
text/selection/images/script paths, zero pre-setup source reads/history/requests,
and busy/approval lockout. It restores provider EditorSettings and performs no
owner authentication, real browser navigation or inference.

Layout checks independently verify the original configured empty-state title
width/typography/logo/content structure and balanced description lines. Rect
snapshots prove the overlay leaves feed/composer/empty-state layout untouched.
They cover conversation-only bounds, wrapped actions, heading/close containment,
300px normal/1.5×/2× fonts and short-height confinement. Timing checks exercise
hidden initialization, restoration waiting, first-visible-open, configured-user
suppression and Close/Escape/Later/hide/reopen. The plugin lifecycle suite also
uses actual dock opening notifications after settled startup and re-enable.
The fixture can also run without `--headless` using
`--rendering-method gl_compatibility` on a display. Editor startup/deferred cleanup are settled before
exit; documented editor-harness progress/RID/ObjectDB diagnostics may remain.
Manual acceptance: a fresh installation, real browser pairing/provider setup,
draft Send after returning, light themes and other native platforms.

## Configurable request timeouts (1.4.1)

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/api_client_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/agent_compatibility_probe_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/agent_controller_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/provider_settings_editor_test.gd
python3 tests/run_editor_test.py editor_ui_scale_test.gd
```

With a fresh `ORCA_TEST_REQUESTS=17 python3 tests/http_test_server.py` process:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/timeout_integration_test.gd
```

The localhost fixture covers delayed headers, headers before silent initial data,
one shared response-start budget, short/long inter-chunk waits, active reasoning,
absolute generation expiry, Stop in both startup phases, JSON and Responses. Four
hosted-default cases additionally verify the original separate header/body waits,
including initial data arriving after the header deadline and ignored retained
custom values. A test-only client subclass shortens the validated production
durations; no new
runtime override is added. Every path requires one owned terminal signal, no
submitted-request replay, and cleared transport/private buffers. Component tests
reject malformed/nonfinite/disabled/over-limit values and nonboolean opt-ins before
connection; controller tests retain values and default/custom policy through
read-tool follow-ups and refresh them after success/failure/Stop. Probe tests
exercise actual timer expiry across both
steps, default hosted 45-second versus explicitly customized budgets, and strict
challenge/enablement binding.

Real EditorSettings/UI tests cover defaults, typed values without Enter, atomic
invalid saves, per-provider persistence, opt-in switching with retained typed values,
safe migration of pre-toggle non-default preferences, corrupt-record fallback,
fixed managed timing and cancelled/stale probe enablement. Card layout checks cover
local/default/custom states, all text/control bounds, exterior separation, readable
seconds units and normal/1.5×/2× fonts. They constrain the owned dock to an actual
300-unit width independently of a native editor Window's larger enforced minimum.
Editor fixtures restore timeout preferences along with their other owned settings.
Manual acceptance: a genuinely unloaded Ollama model on the reporter's hardware,
live Agent-tool usefulness, light themes and additional native platforms.

## Plugin updater

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/update_service_test.gd
python3 tests/run_editor_test.py update_editor_test.gd
python3 -m unittest discover -s tests -p update_package_test.py -v
```

The service fixture covers numeric stable versions, exact official asset/digest
metadata, bounded CDN redirects, daily preferences, dismissal and stale/cancelled
checks. The editor fixture uses actual dirty script/scene state and checks shared
plugin ownership, user confirmation, active-request/approval/draft denial, progress
and 280-unit layouts with 1.5×/2× fonts. Action-row checks also measure complete caption/padding fit and
panel containment independently of Button minimum-size settings, covering both
up-to-date General Settings and available-update notices. Actual Settings navigation
checks the single shared card below Language and Script edits, its absence from
About, and an active check surviving tab switches. General Settings remains within
300 editor-scaled units at both 850- and 600-unit heights with normal/1.5×/2×
fonts, including a visible vertical scrollbar. Assertions check actual view width,
scrollbar clearance and full action captions after deferred layout. The normal-editor
runner isolates project/XDG state and rejects shutdown errors/warnings as well as
assertion failures. Synthetic activation verifies manual
checking, cancellation, official release navigation, confirmation-before-install,
and Later dismissal without real browser or installation side effects.

The Python suite builds deterministic addon-only manifests, rejects unsafe
paths/symlinks/ZIP/header/size/checksum cases, and invokes
Godot in disposable projects for real failed/cancelled HTTP downloads, stale hashes,
replacement, missing-addon interruption recovery, rollback and exclusive locking.
One round trip launches the actual independent updater, verifies it waits for the
parent exit, and observes a new editor load the new fixture addon. Actual-source
release ZIPs are validated without executing their scripts. These tests use no
live model, account or payment; set `ORCA_TEST_TMPDIR` to select a temporary parent.

Graphical user-project relaunch, real release publication, other active editors,
OS-level power-loss at every boundary and macOS/Windows remain manual checks.
See [update/release/recovery documentation](../docs/UPDATES.md).

## Orca Account / Cloud

`account_service_test.gd` verifies saved-session restore, credential rotation,
single-flight refresh, account/capability drift denial, chat-only gating, and Stop
during auth without orphan inference. CI runs this component suite and a separate
four-platform native-helper workflow. `hosted_defaults_test.gd` uses the actual root guide and full Work
schemas; `managed_settings_editor_test.gd` checks automatic included-model selection
and the absence of subscriber compatibility/reasoning controls. Use all three
startup-suppression flags during ordinary editor tests.

Production-origin regressions verify `https://cloud.aiorca.dev` pairing/Console
URLs, isolation from localhost vault records, rejection of confirmed noncanonical
managed endpoints, and ignoring saved development URLs in managed provider settings.
The Godot/backend fixture projects only its synthetic pairing reply onto the fixed
origin and redirects transport through test subclasses to its disposable localhost
server, including the HTTP scheme/host/port. Production authorization still runs;
ordinary addon code has no localhost override.

The hosted-default fixture also exercises a bounded large native scene report with
the actual root guide and Work schemas. Compact model content preserves every JSON
value, enables 32k no-tools finalization and fits normal 64k continuation without
reducing reserves. `scene_inspector_test.gd` passes actual JSON-decoded numeric limits
and rejects fractions/non-finite/wrong-type inputs; controller tests use the real
saved inspector to verify compact tool history, readable activity output, exact call
IDs, budget-signal cancellation and memory-only request estimates. Chat/editor-scale
tests distinguish a blocked follow-up estimate from the last provider-reported
usage and keep the clipped header/cost inside a 300px dock with larger label fonts.
The editor-scale layout check injects UI-only usage and temporarily disconnects
the controller's usage renderer while measuring it. A deferred model-metadata
refresh is forced at every font size to reproduce the idle-usage overwrite race;
strict estimate/budget tooltip checks remain, and reconnection is verified with a
subsequent controller usage signal. This does not change production signal wiring.

```bash
"$GODOT_BIN" --headless --path . --script res://tests/account_service_test.gd
```

Run the credential-store fixture through the isolated Python runner, which supplies
a disposable project, verified test cache/catalog and private vault scope:

```bash
python3 scripts/build_native_helper.py
GODOT_BIN=/path/to/Godot python3 scripts/test_native_credentials.py
python3 -m unittest discover -s tests -p native_helper_packaging_test.py -v
"$GODOT_BIN" --headless --path . --script res://tests/native_helper_service_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/native_helper_editor_test.gd
python3 -m unittest discover -s tests -p native_helper_download_test.py -v
```

The native workflow runs on Linux/Windows x86_64 and macOS arm64/x86_64. Its Python
runner creates a minimal disposable Godot project (no owner plugin/account startup),
checks exact LF/bounded helper bytes, runs the ordinary vault fixture, then runs
save/restore/rotate/erase in separate Godot processes using a random test scope.
Linux gets a private D-Bus session and temporary HOME/XDG keyring; macOS gets an
ephemeral unlocked default/search-list Keychain with settings restored on cleanup;
Windows uses its disposable runner user's vault and erases the synthetic record
even on failure. Test scope/phase environment variables belong only to this fixture.
No live authentication, owner credential or inference is used. Set `ORCA_TEST_TMPDIR`
to choose a temporary parent. All native jobs must pass before aggregate artifacts
or release packaging are allowed. Native Windows/macOS execution remains pending
until Actions runs; compilation/header checks do not establish platform acceptance.

The packaging suite proves binary-free ZIPs, separate exact-hash assets/catalogs,
native header checks, disguised executable denial, output/overwrite protection and
explicit source manifest/catalog regeneration. Header fixtures never execute.
The helper component/editor/HTTP fixtures cover catalog/platform validation,
automatic quiet startup, early sign-in coalescing, sign-in cancellation/navigation
without stopping preparation, saved-account restoration and narrow inline status.
HTTP fixtures cover redirects/hash/size/disconnect, transient bounded retries,
shutdown/cancellation, cache reuse/tamper/symlinks and cooperating installer waits.
Deadline fixtures also bound lock polling/backoff and cancellation during retry.
Native tests execute only real helpers in isolated caches.
`ORCA_TEST_HELPER_CACHE` belongs only to the vault fixture subclass, not production
path configuration. Background fixtures opt in only through test subclasses and
isolated transports. Production startup-download suppression remains required.

Real Godot/FastAPI/PostgreSQL acceptance lives in the backend's
`tests/test_godot_client.py`. From that repository, use its disposable test database
and explicit fixture environment, then set `GODOT_BIN`, `ORCA_GODOT_PLUGIN_PATH`
to this repository, and optionally `ORCA_TEST_NATIVE_VAULT=1`. The latter pairs in
one actual Godot process and restores in another using an isolated real vault
record, then checks automatic operator-verified readiness, actual editor/root context,
full Work schemas, file read/continuation, receipts, private-state
privacy, EOF/JSON/error/exhaustion denial and logout. It cleans its native record
and disposable schema. No live model, payment or email is used.

The same fixture suite now also loads all four real profiles from the backend's
`foundry-live.json` (synthetic transport and disposable entitlement), asserting
image input and testing one prepared image with actual live context/output/image
reserves, full editor/root instructions and Work schemas. It checks identical PNG
parts through the tool continuation for both hosted continuation styles. This
reproduces both the missing capability declaration and the former 32k image-budget
failure. Account/composer suites exercise refreshed vision metadata, text-only and
locked-model denial, and draft preservation without restoring owner credentials.

Editor scale/lifecycle suites cover four-tab order/icon, Account states/allowance,
large fonts/narrow width and shared plugin ownership. Manual acceptance remains
real user browser registration/verification, live hosted models, OS-vault unlock,
other platforms, session expiry and deployed HTTPS pairing/inference. Public HTTPS
health responses establish reachability only, not authenticated or metered acceptance.

## 1.6.0 release regression verification

The About/support-report expectations follow plugin version 1.6.0. Synthetic
1.3.0 → 1.4.0 installation/rollback fixtures intentionally retain both versions.
Historical 1.4.1 update/catalog fixtures remain explicit. Current update metadata
checks retain 1.5.0 coverage and verify 1.6.0 upgrades from
1.3.0/1.4.0/1.4.1/1.5.0, exact official asset naming,
same-version suppression and no downgrade from 1.6.0. Actual-source
packaging reads the current version from `plugin.cfg`.
For this release preparation, run the version-sensitive settings/support checks, updater
component/editor/package tests, native helper acceptance and clean initialization
with all three startup suppressions and isolated editor configuration/data/cache.
Run the updater editor case through `python3 tests/run_editor_test.py update_editor_test.gd`,
as both Tests and Prepare Orca release now do. The final-commit
[Tests run at `0d53255`](https://github.com/cold-atom/Orca/actions/runs/41872899730)
and release preparation passed, including all four native-helper platforms and
binary-free packaging; 1.6.0 is published. Unreleased localization requires a new
complete CI and same-revision helper/package run before release. Include the Auto apply and
five-process remembered-default editor cases above. Real-model acceptance should
exercise a small automatic script task, its inline diff, active-turn revocation,
remembered startup and History/Revert with and without an independent edit.
Real browser/downloaded-helper/graphical platform
acceptance is not established by metadata, CI or release notes.

## Project code navigation (1.5.0)

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/project_code_navigation_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/tools_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/agent_controller_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/account_service_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/tool_activity_group_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/chat_window_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/session_store_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/editor_unsaved_state_test.gd
python3 tests/run_editor_test.py editor_ui_scale_test.gd
```

The scanner suite uses disposable `.gdignore` fixtures and checks nested/annotated
declarations, multiline signatures, lambdas/accessors, Unicode/CRLF locations,
whole-identifier candidates, comments/strings/substrings/shadowing, no edit hashes,
fresh changed/new/deleted disk source, protected/symlink/dirty boundaries and scan
limits. Tool/controller tests include provider-JSON integer limits and complete
four-call read-only batching. Account tests verify old-catalog schema omission,
strict advertisement types, direct runtime denial and immutable turn snapshots.
Activity tests click each result, reject stale/deleted paths and keep only safe
historical query summaries. Editor tests dirty real scripts without changing their
buffers/disk, and measure actual 300-unit result-list layouts at normal/1.5×/2× fonts.

The authorized backend's `tests/test_code_navigation_contract.py` validates exact
vocabulary/schema types and malformed streamed arguments. Its Godot fixture adds
one two-tool fragmented SSE/private-continuation case alongside the existing five
account/full-context/image cases. Use a disposable `TEST_DATABASE_URL`, `GODOT_BIN`
and `ORCA_GODOT_PLUGIN_PATH` from that repository; no live model or owner account
is used. Production availability requires backend API rollout and catalog refresh.
Real model usefulness, light themes, native clicks in other platform editors and
broader project-size evidence remain manual acceptance.

GitHub Actions runs all commands below on Godot 4.7.2 through `.github/workflows/tests.yml`.

Run parser, response-contract, terminal-ownership, and lifecycle-ID checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/api_client_test.gd
```

Run provider registration, model normalization, local leading-system message layout, history isolation, reasoning, and metadata-mapping checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/provider_test.gd
```

Foundry Responses conversion, opaque continuation isolation, status/output bounds, call IDs, UTF-8 SSE, exact API/style binding, context accounting, and DeepSeek continuation checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/responses_protocol_test.gd
```

Azure DeepSeek leading-delimiter normalization, split/whitespace limits, literal markup preservation, raw/visible parity, cancellation, strict acknowledgement, and private plain-reasoning replay/isolation/bounds/budget checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/deepseek_compatibility_test.gd
```

With `ORCA_TEST_REQUESTS=13 python3 tests/http_test_server.py` running:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/deepseek_compatibility_integration_test.gd
```

The fixture reproduces the exact leading `</think>` acknowledgement artifact in four two-request probe sequences (Chat/Responses × SSE/JSON), verifies private reasoning and normalized assistant replay, then checks Standard Responses denial of unsupported plain reasoning, wrong-nonce denial, and unchanged Standard Chat delimiter handling. Prefix buffers and private state must clear at every terminal. These are synthetic model-free requests; live Foundry DeepSeek acceptance remains pending. Select Reasoning Continuation = DeepSeek reasoning for either API, restart after updating the addon, and rerun Test & Enable because older DeepSeek format passes cannot authorize the changed contract.

With `ORCA_TEST_REQUESTS=15 python3 tests/http_test_server.py` running:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/responses_integration_test.gd
```

The 15 localhost requests reproduce default-reasoning GPT Chat HTTP 400, verify explicit `none` on both reported GPT deployment names, execute the isolated two-request Responses compatibility probe, preserve image/phase/encrypted reasoning across multi-call/no-tools continuation, normalize cached usage and JSON fallback, and verify incomplete/error/disconnect/Stop cleanup. Azure DeepSeek Chat has retained/missing `reasoning_content` positive/negative controls. Controller/session suites verify active-turn retention, settings snapshots, turn-end cleanup, no protocol-changed tool authorization, and no opaque session persistence. Settings/editor suites check API/style/effort persistence and narrow containment. No model is loaded and no live Azure requests are made.

Manual acceptance: configure the Foundry resource URL and exact GPT deployment, keep Responses selected, run the probe, enable tools, and exercise Plan reads, Work approvals/rejection, Stop, and a resumed visible conversation. Use Chat + explicit None only when the deployment requires it. For DeepSeek Chat select DeepSeek reasoning continuation, rerun the probe, and inspect challenge-redacted synthetic failure feedback if it still fails. Check the exact deployment/version/region; fixtures do not establish model competence, live vision, or Azure-specific service availability.

Run strict endpoint parsing, normalization, scope classification, and exact-origin trust checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/endpoint_policy_test.gd
```

Run protocol-aware context estimation, reserve, compaction-boundary, oversized-active-turn, and no-tools-finalization budget checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/context_budget_test.gd
```

Image preparation, capability, storage/restoration, controller continuation, and narrow tray lifecycle checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/image_attachments_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/image_intake_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/image_model_switch_test.gd
```

With `ORCA_TEST_REQUESTS=10 python3 tests/http_test_server.py` running, verify actual multimodal SSE transport, retained images across a tool continuation, and repeated model switching:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/image_attachments_integration_test.gd
```

The fixture checks the original two-request image continuation plus eight text → vision → text → vision requests. It requires exact tool IDs/results/order and prior descriptions, unchanged original PNG data when vision returns, no attachment pixels/image_url parts in text-only payloads, and no serialized private policy. New unsupported image drafts are rejected before another network request. The component model-switch suite also covers canonical compaction, restart, cancellation/failure, and preserved drafts. All images/models are synthetic; these are transport-contract tests, not live vision acceptance.

The first two image requests also carry one synthetic project-script snapshot. The server requires its exact source/path/provenance/line metadata in user text on both requests, alongside the image and matching tool result; canonical `script_references` metadata must not leak into provider fields.

Script-reference preparation, path/UTF-8/count/record bounds, projection/budget/compaction, Chat-only/Responses/multimodal bodies, real read-tool continuation, persistence/restoration, forced Control drop routing, duplicate/atomic intake, narrow chips, and draft recovery:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/script_references_test.gd
```

`editor_unsaved_state_test.gd` additionally verifies exact active unsaved snapshots and public script-list identity, inactive dirty rejection, and unchanged disk/dirty state. `editor_ui_scale_test.gd` verifies chips above image/checklist overlays and Tab preservation. Manual acceptance: drag saved `.gd` files from FileSystem and the open-script list, inspect/remove/open chips, modify before Send, send references with/without prompt/images through Chat and an Agent tool loop, switch the active dirty script, fail/cancel with a newer draft, and restore History. Source is capped at 300 lines / 16 KiB per script and carries explicit truncation. No live model request is made by these tests; actual script-list mouse dragging and additional platforms remain manual checks.

Manual model-switch acceptance: start with either a text-only or vision model, discuss an image, switch to text-only, and send a text follow-up in the same session. Check that prior text/descriptions are usable, previews remain clickable, and the image-action tooltip explains placeholders without an error card. Switch back to vision and ask about the retained image. Exercise a tool loop, settings changes during a turn, saved/restored history, and rejection/removal of unsupported new drafts. Normal compaction can remove old turns from model context while their visible transcript previews remain saved.

Manual image gates: select PNG/JPEG/WebP using Browse in Orca's attachment window, inspect thumbnail/remove/preview behavior at narrow widths and different editor scales, send to a live vision-capable profile, exercise tool follow-ups, switch to a text-only profile, fail/cancel with a newer draft, restart and inspect saved previews, and delete the conversation. Paste real screenshot pixels with Ctrl/Cmd+V and context-menu Paste; verify normal text replacement/undo and text-only-model behavior. Drag project files from Godot's FileSystem dock onto the input and desktop files into the separate attachment window, confirming no project copies are created. Check close, session/profile change, full tray, malformed files, hidden Settings/History, and detached-editor behavior. Desktop files dropped on the main editor still trigger Godot import; the separate native window is required to isolate desktop intake. Headless tests use a fake clipboard; localhost tests do not establish live-provider vision quality.

Native Linux/X11 drop regression (requires a real or virtual X11 display and `python-xlib`; not a headless suite):

```bash
python3 tests/native_image_drop_test.py
```

Set `GODOT_BIN` first. This launches a fixture-only Godot editor, sends real XDND file transfers to the owned native window, verifies accepted/unsupported drops and close invalidation, and hashes all non-generated project files to prove there are no project-file changes. It uses a temporary synthetic PNG outside the project, does not send provider requests, and cleans its temporary directory. CI does not currently install the X11 prerequisites. Verified on Godot 4.7.2 Linux/X11/Vulkan; other platforms/renderers remain manual gates. The native editor harness emits visible progress-dialog/RID/ObjectDB diagnostics; it waits for filesystem and teardown completion before exiting.

Run line-patch materialization and newline-preservation checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/patch_utils_test.gd
```

Run filesystem path, proposal, conflict, application, and revert safety checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tools_test.gd
```

Run Plan/Work permission, approval, rejection, cancellation, conservative tool-batch barriers, checklist reconciliation, request/turn ownership, synchronous reentrancy, full run/fix/verify orchestration, context-pressure finalization, tool-loop, and recoverable-interruption protocol checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/agent_controller_test.gd
```

Run isolated two-step synthetic tool-call compatibility, refreshed system context, old-version binding denial, per-step request ownership, continuation, failure, and cancellation checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/agent_compatibility_probe_test.gd
```

With `ORCA_TEST_REQUESTS=16 python3 tests/http_test_server.py` running, verify local message-layout compatibility over real HTTP/SSE:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/local_provider_integration_test.gd
```

The strict synthetic template rejects multiple/later system messages with the reported HTTP 500 as a negative control. LM Studio, Ollama, and Local OpenAI-compatible profiles must preserve fresh context, tasks, exact user/assistant and tool-call/result order, runtime notices, and no-tools finalization across five requests each. No model is loaded and no project tool is executed. This verifies the transport contract, not the reporter's exact model/template or inference quality. The probe integration below uses the same leading-system restriction and requires its fixed synthetic refresh notice to survive normalization. Probe version 2 invalidates older compatibility passes; **Test & Enable Agent tools** retests and automatically enables the exact profile after success.

Manual local-provider acceptance: use an unchanged default model template, test at least two messages in a fresh Chat-only session, then run the updated probe and enable tools only after it passes. In Plan, exercise a read-only tool continuation; in Work, check approved editing and a bounded run/observation if the model supports them. Record LM Studio/runtime versions, exact model/GGUF and template identity, and server errors. Compare the reporter's failing model/template when available; a successful different Qwen model does not establish that gate.

Run project-scoped session persistence, recovery-checkpoint retention, redaction, and controller restoration checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/session_store_test.gd
```

Run the narrow History layout check:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/history_view_test.gd
```

Run icon-based Provider/System/About switching, the five-language selector, release metadata, and narrow settings-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/settings_view_test.gd
```

Run transparent, background-free logo asset checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/logo_asset_test.gd
```

Run the editor-scale integration check using the active editor display scale:

```bash
python3 tests/run_editor_test.py editor_ui_scale_test.gd
```

This suite also sends actual focused-composer Tab events to verify Plan/Work switching, draft/caret/selection/image preservation, normal mode persistence through a memory-only session store, repeat suppression, modifier/outside/hidden scope, and response/approval/view-only locks. Manual acceptance: focus the prompt, press Tab twice, hold Tab, then try it during streaming and an approval; check the mode tooltip and unchanged draft/focus. Shift+Tab and Tab elsewhere retain native behavior.

Expanded-diff checks cover long/unequal/empty files, exact read-only text and change highlights, synchronized scrolling, wide/stacked resized layouts, splitter limits, and larger code fonts. Native minimap click/drag reads real Window mouse coordinates, so the headless fixture checks scrolling/layout while the same suite exercises actual minimap GUI events when run on a display:

```bash
python3 tests/run_editor_test.py editor_ui_scale_test.gd --graphical
```

This graphical fixture temporarily warps the pointer into its own review window. Manual review: expand a `.gd` and `.tscn` proposal, use both minimaps, resize and drag the splitter, inspect red/green overview marks, select/copy text, and check Apply/Reject and reopening an applied diff. Check light/dark themes and other native platforms separately.

Run real editor dirty-script and dirty-scene conflict checks, including unsaved source provenance and patch/run/revert protection:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/editor_unsaved_state_test.gd
```

Run editor logger capture, shared registration, and duplicate-record prevention checks:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/diagnostics_editor_integration_test.gd
```

Run actual plugin enable, disable, re-enable, service ownership, dock, and toolbar lifecycle checks:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/plugin_lifecycle_test.gd
```

Run isolated local-provider URL, model, optional-key, and reasoning persistence checks against real EditorSettings:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/provider_settings_editor_test.gd
```

This suite also connects Settings to a synthetic probe and verifies one-click enablement for all five editable provider types, exact persisted enabled state, manual disable/reopening, duplicate/stale outcomes, failure/cancellation, model/credential/API/style drift, and unchanged/cancelled origin confirmation. It restores its owned settings and makes no live provider requests. Azure API/style settings must survive provider switches. Headless Settings tests verify the combined action's disclosure and narrow layout; controller/probe tests retain exact-binding runtime enforcement. Manual acceptance: restart, click **Test & Enable Agent tools**, observe the toggle turn on after a live pass, click Done, and exercise a Plan read. Turn tools off, reopen Settings, and confirm the opt-out is retained.

Run working-state animation, first-token lifecycle, active-turn auto-follow, sequential review navigation, finalized assistant code-block, expanded diff, streaming-finalization, recoverable-interruption UI, restoration, structured review-card, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/chat_window_test.gd
```

Run bounded model/mode-only response metadata and JSON restoration checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/response_attribution_test.gd
```

Controller/chat/session suites additionally cover model switches, terminal reentry, Plan-to-Work request attribution, stale callbacks, local/legacy omission, interrupted text, and plain/code footer parity. `editor_ui_scale_test.gd` checks long full model names, mode containment/non-overlap, bounded wrapping, and complete tooltips at normal, 1.5×, and 2× fonts. Manual acceptance: discuss a task using two models, verify each answer keeps its model + mode, approve a Plan-to-Work transition, Stop a streamed reply, and restart/restore history. Check appearance in a narrow dock and light/dark editor themes. These fixtures make no live inference requests.

Run explicit Plan-to-Work decision-card, duplicate-decision, resolved-state, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/mode_switch_card_test.gd
```

Run grouped tool aggregate, expansion, navigation, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tool_activity_group_test.gd
```

Run persistent task-panel status, collapse, clearing, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/task_list_panel_test.gd
```

Run saved-scene structure, Variant normalization, connection, bounds, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/scene_inspector_test.gd
```

Run live scene/selection/subtree native layout and transform checks, getter/callback isolation, unnamed roots, strict argument/path/symlink/resource/internal-node boundaries, and bounded output:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/editor_scene_inspector_test.gd
```

Run actual editor unsaved hierarchy/layout/2D/3D state, selection preservation, expected-scene switching, saved mutation guards, and the menu inspect/save/review/Apply/reinspect/Revert workflow:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/editor_scene_inspector_editor_test.gd
```

The editor harness owns and removes only its uniquely named scene fixtures. It waits for startup/deferred scene work, clears fixture selection before closing, saves fixture scenes without thumbnail previews, and waits before teardown. Early rapid scene-switch/cleanup runs crashed; settled runs pass with the existing headless RID/ObjectDB shutdown diagnostics. Node3D values are inspected in the actual editor tree by subtree, avoiding the dummy renderer's 3D workspace. These tests do not send provider requests. Unnamed roots are component fixtures rather than a real New Scene UI interaction.

Manual live-inspection acceptance: select a Control in a real menu, change anchors/offsets/size flags without saving, and ask Orca to explain the layout. Check selected nodes versus scene/subtree scope, Container parents, an unnamed scene, 2D/3D selections, stale scene identity, and narrow grouped activity. Confirm reads preserve dirty state; save explicitly before a normally reviewed correction. Restart/restore activity and confirm historical summaries do not imply current values. Live provider behavior, actual New Scene UI, non-headless 3D selection, and other platforms remain manual gates.

Run bounded ProjectSettings overview, explicit typed value, input action, privacy, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_settings_inspector_test.gd
```

Run root project-instruction loading, bounds, wrapping, and symlink-rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_instructions_test.gd
```

Run project-skill catalog, frontmatter, exact on-demand loading, bounds, and symlink-rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_skills_test.gd
```

Run reflected ClassDB class/member signature, inheritance, bound, and Help-topic checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/godot_api_inspector_test.gd
```

Run focused GDScript function extraction, unsaved editor-source provenance, ambiguity, and output-bound checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/gdscript_function_reader_test.gd
```

Run serialized forward/reverse resource dependency traversal, ordering, limit, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/dependency_inspector_test.gd
```

Run repeated-call, alternating-cycle, repeated-round, semantic-progress, volatile-runtime-observation, and no-progress tool-loop guard checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tool_loop_guard_test.gd
```

Run typed Input Map proposal, validation, application, live synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/input_map_proposal_test.gd
```

Run reviewed main-scene path/UID validation, exact materialization, live synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/main_scene_proposal_test.gd
```

Run allowlisted typed ProjectSettings validation, exact materialization, atomic application, synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_settings_proposal_test.gd
```

Run typed-root creation, node/property/structure operations, two-stage dependency-free script attach/detach, dependency-free child instances, bindless signals, pack/save/load validation, semantic preservation, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/scene_proposal_test.gd
```

Run Orca-owned nonblocking process lifecycle, output bounds, multiline diagnostics, run identity, immutable verification criteria, bounded final stop evidence, timeout, ownership, and real pipe integration checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/game_process_service_test.gd
```

Run bounded diagnostic retention, validation, sanitation, and report-isolation checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/diagnostics_service_test.gd
```

Run privacy-safe support-report allowlist, normalization, and secret-exclusion checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/support_diagnostic_report_test.gd
```

Run the deterministic local transport checks by starting the server in one terminal:

```bash
python3 tests/http_test_server.py
```

Then run the integration test in another terminal:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/api_client_integration_test.gd
```

The chat transport server accepts twenty-nine requests and exits. It receives only synthetic test keys and prompts, checks lifecycle IDs on every observed API signal, enforces exact two-request Gemini, DeepSeek, xAI, and OpenRouter tool-call continuations with fragmented thought-signature or reasoning reconstruction and provider-specific history sanitation, covers malformed and incomplete assistant completions, active SSE streams exceeding short internal total-generation deadlines both directly and after a `stream_options` compatibility retry, plain embedding errors, and local model substitution, and accepts no network traffic from outside `127.0.0.1`.

Run keyless native Ollama/LM Studio discovery, embedding filtering, cache sanitation, stale-request ownership, and redirect-rejection integration against a fresh three-request fixture:

```bash
ORCA_TEST_REQUESTS=3 python3 tests/http_test_server.py
"$GODOT_BIN" --headless --path . --script res://tests/provider_model_service_integration_test.gd
```

Run the isolated two-request compatibility probe through the real local HTTP/SSE transport:

```bash
ORCA_TEST_REQUESTS=2 python3 tests/http_test_server.py
"$GODOT_BIN" --headless --path . --script res://tests/agent_compatibility_probe_integration_test.gd
```
