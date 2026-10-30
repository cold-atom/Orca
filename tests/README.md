# Orca Tests

Set `ORCA_DISABLE_ACCOUNT_RESTORE=1`, `ORCA_DISABLE_UPDATE_CHECKS=1` and
`ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1` for ordinary editor tests so startup neither
restores owner credentials nor sends update checks/background component downloads.

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

## Plugin updater

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --path . --script res://tests/update_service_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/update_editor_test.gd
python3 -m unittest discover -s tests -p update_package_test.py -v
```

The service fixture covers numeric stable versions, exact official asset/digest
metadata, bounded CDN redirects, daily preferences, dismissal and stale/cancelled
checks. The editor fixture uses actual dirty script/scene state and checks shared
plugin ownership, user confirmation, active-request/approval/draft denial, progress
and 280px layouts with 1.5×/2× fonts. Action-row checks also measure complete caption/padding fit and
panel containment independently of Button minimum-size settings, covering both
up-to-date General Settings and available-update notices. Actual Settings navigation
checks the single shared card below Language, its absence from About, and an active
check surviving tab switches. Synthetic activation verifies manual
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

## 1.4.1 release-candidate verification

The About/support-report expectations follow plugin version 1.4.1. Synthetic
1.3.0 → 1.4.0 installation/rollback fixtures intentionally retain both versions.
Update metadata checks also verify that 1.4.1 is newer than both 1.3.0 and 1.4.0,
and actual-source packaging reads the current version from `plugin.cfg`.
Before publication, run the version-sensitive settings/support checks, updater
component/editor/package tests, native helper acceptance and clean initialization
with all three startup suppressions. GitHub's complete Tests workflow and Windows/Mac
native jobs remain required after the owner pushes the candidate. Native/graphical
acceptance is not established by changing metadata or preparing release notes.

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

Run icon-based Provider/System/About switching, English-only language presentation, release metadata, and narrow settings-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/settings_view_test.gd
```

Run transparent, background-free logo asset checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/logo_asset_test.gd
```

Run the editor-scale integration check using the active editor display scale:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/editor_ui_scale_test.gd
```

This suite also sends actual focused-composer Tab events to verify Plan/Work switching, draft/caret/selection/image preservation, normal mode persistence through a memory-only session store, repeat suppression, modifier/outside/hidden scope, and response/approval/view-only locks. Manual acceptance: focus the prompt, press Tab twice, hold Tab, then try it during streaming and an approval; check the mode tooltip and unchanged draft/focus. Shift+Tab and Tab elsewhere retain native behavior.

Expanded-diff checks cover long/unequal/empty files, exact read-only text and change highlights, synchronized scrolling, wide/stacked resized layouts, splitter limits, and larger code fonts. Native minimap click/drag reads real Window mouse coordinates, so the headless fixture checks scrolling/layout while the same suite exercises actual minimap GUI events when run on a display:

```bash
"$GODOT_BIN" --editor --path . --script res://tests/editor_ui_scale_test.gd
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
