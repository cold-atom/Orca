# Orca Development Guide

Last updated: 2026-10-30

## Purpose

This document is the living technical source of truth for Orca. It records what the plugin currently does, how its systems fit together, which safety contracts must be preserved, how work is verified, and what remains to be built.

Read `AGENTS.md` first for mandatory repository rules, `HANDOVER.md` for the current continuation state, and `ORCA.md` for the shorter product overview.

## Release Candidate

This checkout prepares **Orca 1.4.1** for **Godot 4.7.2**. The version in
`addons/orca/plugin.cfg`, prepared changelog and current setup/privacy guidance
describe this candidate; dated milestone entries retain their historical versions.
1.4.1 is the binary-free packaging follow-up to the GitHub-published 1.4.0 release,
which was rejected by the Godot Asset Store for bundled executables. Its short
changelog entry links to 1.4.0 for the full feature list. Keep the published v1.4.0
tag/assets stable; users of 1.3.0 can upgrade directly to 1.4.1. Publication and
Asset Store approval remain pending, including reviewer confirmation of the
post-install helper flow and separate thumbnail/prior-download corrections.
The owner controls commit, push, tag, GitHub publication and Asset Library submission.
All four native build/acceptance jobs and binary-free packaging/artifact uploads
passed in [Tests run #49](https://github.com/cold-atom/Orca/actions/runs/41042858660)
at `502d838`. The full run failed in the editor-scale synthetic tooltip check.
This checkout corrects that fixture race; a new complete CI run remains required
before publication. Real downloaded-helper flow and Windows/macOS updater
acceptance remain pending.
Push-triggered builds now produce a binary-free `orca-package` ZIP/checksum plus
separate `orca-native-release-assets` after native acceptance. The complete Tests
run must pass before publication. Source-based Asset Store distributions require
the exact packaged helper catalog/update manifest and exclude compiled helpers.
The owner pushed the 1.4.1 candidate; the CI correction is local and no release
publication has been performed by this work.

## Product Direction

Orca is an AI game-development assistant integrated directly into the Godot editor. Its intended workflow is:

```text
Understand the user's editor and project context
-> inspect only the relevant files and Godot state
-> explain or plan the work
-> propose precise reviewed changes in Work mode
-> validate before writing
-> apply only after approval
-> eventually run, observe, fix, and verify the game
```

The current plugin is a functional development-stage agent. It is not yet a production release or a complete autonomous game-development environment.

## Current Capabilities

### Editor Integration

- Native `EditorPlugin` under `addons/orca/`.
- Toolbar toggle and right-side dock.
- Responsive structured chat feed rather than one monolithic text label.
- Completed assistant responses render fenced code as bounded, selectable blocks with language labels, Copy actions, and native GDScript highlighting in the editor.
- Response footers show only the full configured model ID on the left and the generating request's Plan/Work mode on the right. Readable muted metadata typography, existing orange/green accents, and one consistent editor-scaled gap keep the footer inside the response card. Long IDs wrap to at most two lines with the complete identifier in the tooltip. Plain/code answers, tool prefaces, and visible interrupted text share the same attribution; unrecorded legacy answers and local recovery notices remain unlabeled.
- Editor-scaled typography and custom geometry across the dock, settings, history, activity, task, and review surfaces.
- Compact line-height-driven composer, animated transparent branded empty state, descriptive Plan/Work selector, and a current-model shortcut into model settings.
- Transient five-square working states remain visible from submission until actual text or tool activity, distinguish initial thinking from post-tool response preparation, and reuse mode-aware animation for runtime observation and assessment.
- Active turns use multi-frame feed following so newly inserted or late-resizing working, response, tool, and review cards remain at the visible bottom; sequential approvals automatically advance to the next pending card.
- A Plan turn can show one inline, turn-bound Work-mode request with explicit `Stay in Plan` and `Switch to Work` actions. Approval continues the same task automatically; rejection stays in Plan and suppresses another request for that turn.
- Two-row compact header that keeps session context usage and cost visible at narrow dock widths.
- During active or locally blocked requests, the header shows `Request ~… / …` from the conservative preflight estimate. Its tooltip separates the latest completed provider usage from the outgoing input budget and output/tool reserves. Idle completed requests retain `Context …`; estimates are memory-only and do not replace billing/session usage. Narrow labels keep their existing clipping and complete tooltips.
- In-dock settings page with icon-based Provider, System, and About navigation, neutral charcoal selected surfaces and bright active icons, keyboard focus, and section tooltips. System currently displays English as the sole supported language with its selector disabled; localization and language persistence are not implemented. Provider settings include API key configuration, searchable model discovery, provider-reported or conservative known-model reasoning effort, model metadata, release information sourced from `plugin.cfg`, and a Done action.
- The About page can copy a memory-only strict-allowlist support report containing Orca/Godot versions and coarse provider/request lifecycle metadata without endpoint addresses, credentials, project or conversation content, model output, logs, process output, proposal data, or hashes.
- About includes compact Resources and Community & Development link rows for documentation, `aiorca.dev`, the GitHub repository, issue reporting, and discussions/feature requests. PanelContainer-driven minimum sizes keep titles, wrapped descriptions, padding, and browser arrows inside each clickable row at actual editor font sizes. Neutral hover surfaces, keyboard focus, and accessible names follow the dock's visual style. URLs are static user-provided destinations opened in the default browser only on explicit click; Orca appends no project, conversation, or diagnostic data. Editor-layout regressions verify text containment, no row/heading overlap, and narrow width with normal, 1.5×, and 2× font sizes after deferred container layout.
- First-class managed Orca Cloud, OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Microsoft Foundry / Azure, Ollama, LM Studio, and Local OpenAI-compatible profiles plus an advanced custom OpenAI-compatible profile.
- Separate credentials, model, and reasoning-effort selection per provider, with migration from the former global URL/key/model settings.

### Conversation And Streaming

#### Connection onboarding (1.4.0)

- The original **Work with Orca** empty state retains its scene/theme typography, 60px editor-scaled logo, unwrapped title and natural centered text width. Onboarding uses one independent conversation-area overlay with soft dimming and a restrained `connection_setup_panel.gd`, containing **Sign in / Sign up with Orca**, **Bring your own API key**, Close and **Set up later**. It contributes no feed/composer minimum size, never covers the composer, and uses bounded width plus internal vertical scrolling for narrow/larger-font layouts. Normal empty-state content is not rewritten or resized by connection state.
- Automatic setup is decided once per loaded dock on its first visible opening, after account restoration settles. An explicit plugin toolbar/fallback opening arms subsequent public Control visibility tracking; Godot's initial restored-tab visibility does not supply user intent or consume the decision. Configured users skip automatic setup. Close, Escape, Set up later, navigation or dock hiding dismiss it; subsequent setup-needed Send reopens the same panel. Dismissal/first-open state is memory-only and resets with a newly loaded dock. Setup actions close the overlay before navigating to existing Settings; incomplete setup returns to the retained draft without reopening automatically.
- `AgentController.connection_setup()` returns only coarse readiness (`ready`, `credentials`, `account`, `model`, `restoring`) and explanatory text. Submission enforces required credentials/account/model before turn activation, project-context reads or history changes; the UI checks before source-reference preparation, clearing any draft or writing session events. Keyless local profiles remain valid. This is configuration readiness, not network/model/tool verification; transport validation, exact compatibility and permissions remain authoritative.
- Setup-needed Send shows the overlay while preserving text, caret/selection and all attachments. Missing models get a focused picker action; restoration disables duplicate sign-in. Overlay data remains memory-only and excluded from conversation/session/model/support data. Complete setup dismisses it without automatically sending or replaying a request. Busy/approval state blocks setup navigation and suppresses automatic overlays; ordinary feed-follow and mode-menu behavior retain their separate ownership.
- `SettingsView.open_account_setup()` starts the existing browser pairing only from the user action, retaining progress/reopen/cancel and automatic included-model selection. Connected users choose Orca models instead. `open_provider_setup()` opens provider/key entry, including when the active provider is Cloud; selection is committed through normal Done, with existing endpoint confirmation. Ordinary settings construction/opening never initiates pairing. Busy/approval navigation locks remain. Public TextEdit `deselect_on_focus_loss_enabled=false` preserves selection through setup navigation.
- Permanent controller and `onboarding_editor_test.gd` regressions cover missing-key/account/model denial before a turn, keyless local profiles, first/existing-user state, restoration, actual Settings actions and BYOK saving, pairing cancellation/success, source-read/session/request absence, draft preservation, no automatic Send, action locks and 300px larger-font layouts. Configured-state regressions independently measure the full title width, original theme/logo/content structure and balanced description lines; snapshots verify overlay display/dismissal does not change feed/composer/empty-state geometry. Close/Escape/Later, hide/reopen and restoration waiting are covered, and the lifecycle suite exercises actual plugin open/hide notifications before and after re-enable. Tests suppress owner account restore/update checks, use synthetic transports and restore modified EditorSettings. Real browser/provider acceptance, light themes and additional platforms remain manual.

#### Plugin updates (1.4.0)

- One plugin-owned `update_service.gd` supplies a dismissible dock notice and General Settings check/version/release/progress/cancel/automatic-check/rollback controls through `update_panel.gd`. The settings card is created once below Language; About retains its installed-version/product/links/support content. Public unauthenticated GitHub metadata is checked at most daily and cached only after bounded exact official stable-asset normalization. Updating requires no Orca account and is user-owned maintenance, never a model tool.
- Update action rows use natural caption minimum sizes so flow layout wraps labeled buttons instead of shrinking them to empty padding-only blocks. Full-width column actions retain clipping when needed. Editor regressions independently measure caption width and containment in both General Settings/up-to-date and available-update notice states, with normal/1.5×/2× fonts, and verify action wiring without opening a real browser or installing an update.
- `update_package.gd` verifies the official SHA-256 ZIP, bounded central/local headers and file spans before decompression, a strict version/Godot/file manifest, per-file hashes, native helper permissions and complete installed/staged/backup file sets. Local changes, unknown files, symlinks, stale hashes and unsafe/unsupported archives block installation. Read-only checks and staged extraction never load downloaded scripts. Primary hashing/extraction runs on a background thread.
- Explicit confirmation precedes download/install. The current editor must have no dirty scenes/scripts, active Orca requests/approvals, game run, account transition or composer draft, and conversation saving must succeed before handoff. A project-scoped lock serializes cooperating updater instances. Other editors of the same project must be closed; public dirty-state checks cover only the current editor.
- The trusted copied `update_runner.gd` runs under the current Godot executable in `res://.orca-update/runner/`, a private minimal project outside the loaded addon. It waits for the initiating editor's exit before transactional directory replacement, retains one verified rollback copy and reopens the same project. Unix uses a fixed signal-0 process-existence probe because Godot's process API only tracks child PIDs, and a fixed positional-argument `exec` wrapper detaches closed installer pipes. Windows uses native Godot process APIs. This is never exposed as executable/argument/PID authority to the model.
- Handoff snapshots the public active display backend (`DisplayServer.get_name()`), preserving headless relaunch even without an available desktop. Godot consumes `--headless` before returning `OS.get_cmdline_args()`, so command-line membership cannot determine this state. The independent restart fixture removes inherited X11/Wayland display variables and verifies the new editor's headless backend.
- `res://.orca-update/` is import-isolated (`.gdignore`), Git-ignored and protected from agent reads/search/mutations/dependencies/script references. Its bounded ownership, lock, transaction and result records preserve recovery information. Verified rollback is explicit; a retained standalone launcher can restore the original even if the addon directory is absent. Modified/unknown bytes and locks are preserved for manual review.
- `scripts/package_release.py` produces deterministic addon-only ZIPs with an embedded `update_manifest.json` and checksum sidecar. `.github/workflows/release.yml` prepares an existing stable tag on manual dispatch and publishes only with its explicit checkbox. The first updater-equipped package is installed manually once; developer checkouts and older packages without manifests cannot auto-replace themselves. Plugin metadata is 1.4.1 for the prepared release candidate; publication remains pending owner-run CI and platform acceptance. Contract, operations, bounds and exact manual recovery command: [`docs/UPDATES.md`](docs/UPDATES.md).
- Release preparation retains all four native build/real-test jobs from the selected tag, but packaging now uses `--require-platform-helpers --helper-assets <directory>` to emit a **binary-free** plugin ZIP/checksum plus four separate raw helper assets. The generated `native_helpers.json` pins those exact bytes to the plugin version; the unchanged updater manifest records it as an ordinary non-executable addon file. Known helper build products are excluded from the ZIP; unexpected ELF/PE/Mach-O or compiled-library filenames elsewhere are refused. Native workflow outputs are `orca-package`, `orca-native-release-assets` and a local-preparation tar.gz. Publication attaches the ZIP/checksum and matching raw helpers; downloading Actions artifacts never publishes them. Compiled helpers are Git-ignored/export-excluded and the formerly tracked Linux executable is removed. Explicit `--write-manifest` writes both catalog and update manifest into source; source snapshots must match the accepted ZIP and separately published helpers. A pinned source catalog cannot silently change during a rebuild. Workflow permissions/publication ownership remain unchanged. Exact steps are in `docs/UPDATES.md`.
- The package artifact explicitly includes hidden files for its narrowly scoped `.ci/orca-v*.zip*` upload pattern; otherwise Actions excludes the hidden `.ci` directory during wildcard discovery, even after successful packaging. All four native build/vault/protocol/locking/cross-Godot-process jobs passed in [Tests run #42](https://github.com/cold-atom/Orca/actions/runs/40904709816); its aggregate upload and display-free updater test exposed these two subsequent failures. A new complete CI run and downloaded-package/platform updater acceptance remain required.
- Release publication supplies an explicit **Full Changelog** link to `CHANGELOG.md` at the selected release tag. The changelog must be finalized before tagging; the version-bound link stays stable as the default branch advances.
- Tests suppress automatic checking with `ORCA_DISABLE_UPDATE_CHECKS=1` alongside owner account restore suppression. Permanent service/editor/packaging/HTTP/independent-process tests cover notification preferences, narrow larger-font layouts, dirty/current-work denial, archive boundaries, local changes, stale proposals, failed/cancelled downloads, missing-addon recovery, locking, install/rollback and real fixture editor relaunch. Linux/Godot 4.7.2 headless acceptance is verified; real GitHub publication, graphical full-project relaunch, other editors, exhaustive power-loss boundaries and macOS/Windows remain manual gates.

#### Orca Account / Cloud (1.4.0)

- `credential_store.gd` owns one `native_helper_service.gd`, shared with its owning account service. Plugin enable quietly prepares a missing platform helper in the background, with no install button/disclosure/progress card or updater notice. The existing account/BYOK onboarding remains. Early explicit Cloud sign-in shows only **Preparing connection…** in Account status and shares the preparation operation; repeated clicks coalesce. Cancel/navigation invalidates that sign-in intent without stopping preparation. Background completion alone never opens a browser or sends a model request; plugin disable/shutdown cancels preparation and all waiters. BYOK/local use remains available during preparation; failures surface inline only when Cloud sign-in needs the component. Active preparation blocks updater handoff.
- Startup saved-account restoration waits for the helper and runs once under the existing account generation/scope guards. Explicit sign-in/cancellation supersedes queued restoration, so a late helper cannot switch identities or reopen a browser. Existing configured Cloud-model metadata is an onboarding hint only: wait for startup restoration before consuming first-open intent for returning users, while fresh onboarding remains available during helper preparation. Helper/profile/credential/capability authority is unchanged.
- The strict 8 KiB/four-entry `orca-native-helpers-v1` catalog binds plugin version, allowlisted platform/architecture/asset, size (64 bytes–8 MiB) and lowercase SHA-256. Download URLs use that version's official `cold-atom/Orca` release, never latest or editable origins. Public credential-free requests retain the 120-second/four-hop exact GitHub/CDN download contract inside a shared 150-second preparation deadline. Transient transport/429/5xx failures permit three attempts with bounded 1s/2s backoff; verified-cache reuse and live-owner lock waiting coalesce editors. Hash/architecture/redirect/path/changed-cache failures are not retried. Hash/native-format checks precede owner-only Unix permission setting and atomic rename. No unverified helper executes, and no plaintext credential fallback exists.
- Helpers live at `OS.get_data_dir()/Orca/native/<sha256>/<asset>`, outside `res://`, addon manifests, updater replacement and conversation data. Immutable hashes coexist across projects/editors and rollback versions. Every helper acquisition revalidates size/hash/native architecture. An atomic per-hash directory lock with bounded PID/token records coordinates installation; only recognized dead-owner locks/partials can be reclaimed, with unknown/symlinked/changed files preserved. Cache cleanup is explicit; missing execute permissions or modified cache bytes require user repair. The native credential scope, pipe commands, vault refresh lock and reaping/watchdog contracts are unchanged.
- Permanent packaging/catalog/header/real-HTTP/editor tests cover binary exclusion/separate hashes, malformed catalogs/platforms, automatic startup, redirects/size/hash/disconnect, bounded retries/deadline, cache reuse/tamper/symlinks, cooperating installers, saved-account restoration, early/cancelled sign-in, teardown and narrow inline Account status with no helper UI. The real native acceptance runner populates isolated verified caches and manifests before its vault/two-Godot-process checks. Ordinary tests/workflows set `ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1` alongside owner restore/update suppression; background fixtures opt in only through isolated test subclasses/transports. Linux isolated acceptance is verified; new GitHub assets, actual Store ZIP/snapshot paths and Windows/macOS downloaded-helper prompts remain manual. Updated production workflows require owner-run CI.
- Settings navigation is Provider → System → Account → About. Account uses the supplied `profile.svg`, browser Sign in / Sign up, bounded pairing/cancellation, display name, eligible plan, integer allowance/reservations, Console navigation and sign-out. Fresh sign-in activates an included recommended model automatically; Choose model opens the picker. Managed profiles use server defaults and expose no user reasoning/compatibility setup.
- One plugin-owned `account_service.gd` is shared by the dock, settings, controller and compatibility probe. Accounts outlive conversations. Login is restored directly from the OS vault on editor startup, with no password collection, automatic browser opening or account tokens in EditorSettings/project/session JSON.
- The independently implemented native `credential_helper.cpp` uses Linux Secret Service/libsecret, macOS Keychain or Windows Credential Manager. All four supported native builds and isolated CI acceptance jobs passed; real downloaded-plugin acceptance remains pending. A bounded private pipe carries records, and an OS lock serializes read/refresh/replacement across editors/projects. Access tokens remain in memory; refresh/session records are stored only in the OS vault. There is no plaintext fallback. Direct helpers are reaped on close/timeout and have a 180-second native crash watchdog.
- The native build workflow now covers Linux/Windows x86_64 and Apple Silicon/Intel macOS, reused by Tests and release preparation. `scripts/build_native_helper.py` selects a fixed native SDK build; Windows statically links the CRT and uses LF-only binary stdin/stdout. macOS uses current `SecItem` APIs with the existing generic-password service/account identity, targets macOS 11 and is ad-hoc signed. `scripts/install_ci_godot.py` installs the pinned editor. `scripts/test_native_credentials.py` runs real protocol/vault/locking plus separate-Godot-process persistence in minimal disposable projects: private Linux D-Bus/HOME/XDG keyrings, temporary unlocked Mac Keychain with restored default/search list, or random erased scopes on disposable Windows runner accounts. Native output/credentials are never logged. Linux isolated acceptance is verified locally, and all four Actions jobs passed in Tests run #42; real downloaded-plugin acceptance remains pending. Ad-hoc signing is not Developer ID/notarization.
- The owner-approved production origin is fixed `https://cloud.aiorca.dev`; API base is `/v1`, browser approval is `/activate?user_code=…`, and Console navigation is `/account`. Managed profile reads use the release-owned URL even if EditorSettings still contains the former localhost default. Managed credentials cannot use arbitrary confirmed endpoint overrides. Vault scopes and records remain origin-bound: localhost credentials are not migrated or sent to production, so upgrading requires a fresh browser sign-in against the deployed account database. Windows/macOS packaging acceptance remains pending.
- `orca_cloud_provider.gd` exposes authenticated, bounded model metadata and account eligibility without provider keys. Controller snapshots identity, model, capabilities, effort, image policy and rates; per-request serialized credential refresh cannot switch the active account. Stop during authentication cannot launch orphan inference.
- Cloud requests carry contract/idempotency headers, asserted capability/continuation revisions, explicit output limits and server-issued turn bindings through all continuations/finalization. Cloud requires validated SSE plus `[DONE]`; JSON fallback, EOF success and changed-payload retries are disabled. Errors/receipts are bounded and sanitized; accepted failures/cancellation never replay project tools. Account balances refresh on turn completion and opening Account.
- Hosted context policy `utf8-conservative-v2` estimates text at three UTF-8 bytes/token plus framing, reserves the selected output and a bounded future tool result, and counts opaque Responses continuation at full byte size. Backend billing admission separately retains its one-byte/token upper-bound input reserve; usage settlement remains authoritative. This fixes rejecting a greeting with the full 21 KiB root guide and 16 KiB Work schemas. These are estimates, not a provider tokenizer. Complete-turn compaction preserves canonical images/references and active protocol. The live vision-v2 profiles advertise image input for all four models and a bounded 65,536 context / 8,192 output cap, retaining a conservative 16,384-token reserve per image. The former 32k cap could not fit the real instructions/tools plus one image and response reserves. Multiple images/history remain subject to complete-turn compaction and safe input-budget denial.
- Hosted image support is driven by authenticated catalog `input_modalities`, not public model-name inference or Agent-tool compatibility. The initial live profiles omitted `image_input` and therefore correctly disabled attachment intake even for vision deployments. New immutable Cloud profile versions correct the declaration; Provider Refresh or Account Refresh updates the existing composer through the shared account-state signal. No addon runtime bypass or vision override was added. Real image/tool/follow-up transport passed for all four deployments; DeepSeek, Kimi and Sol identified a synthetic two-colour image, while Luna accepted/processed the request but failed that recognition check twice.
- Managed tools are automatic only for authenticated, allowed/available, operator-verified profiles with matching capability and supported tool/context contracts at the fixed service origin. No user probe/toggle is involved; local Plan/Work, approvals, hashes and validation remain authoritative. Editable/custom profiles still require the exact user-enabled probe. The backend's `orca_agent_probe(challenge:string)` remains available for operator/legacy testing but is not subscriber onboarding.
- Sol still uses downstream Chat: its private Responses JSON packet is copied exactly through `reasoning_content` under the declared profile and removed at turn end. It is not displayed/persisted or forwarded to another profile.
- Verification: account lifecycle/single-flight/identity-drift/Stop tests, native vault round-trip and cross-process lock, real Godot/FastAPI/PostgreSQL fixture, actual two-Godot-process persistence, exact probe/read-tool/receipt/private-state/error handling, editor layout at headless 1× and graphical Linux/X11/OpenGL 2× with larger fonts, plugin ownership and existing affected suites passed. Backend full regression: 218 passed, no skips. Synthetic fixtures used no live inference/payment/email. Real user browser/live hosted model acceptance and Windows/macOS remain manual. Existing editor-harness shutdown/progress diagnostics remain visible.

#### Microsoft Foundry / Azure (1.4.0)

- A dedicated editable `azure` profile uses the resource's `/openai/v1` base URL and exact deployment name. It defaults to Responses, with explicit Chat Completions selection. It does not copy credentials or enable tools from an existing Custom profile. Manual deployment entry is supported; Azure model discovery is not implemented.
- Azure and generic OpenAI-compatible settings expose explicit `none/minimal/low/medium/high/xhigh/max` reasoning choices plus Provider default. These are request options, not inferred deployment capabilities; unsupported values fail visibly. Generic Chat now sends selected `reasoning_effort`. Azure Responses uses `reasoning.effort`; Provider default omits the field and does not disable server reasoning. GPT deployments that reject reasoning with Chat tools can use explicit `none`, or Responses to retain reasoning.
- Azure has an explicit Standard/DeepSeek **Reasoning Continuation** setting for both APIs, including aliases/custom deployment names. DeepSeek Chat preserves returned `reasoning_content`; Responses preserves bounded private `reasoning_text` content parts when this setting is selected. Standard Responses rejects unsupported nonempty plain reasoning rather than silently dropping continuation. API mode, continuation style, and the scoped DeepSeek format version join the exact compatibility binding. Existing version-2 records without API/style fields remain valid only for their original Chat/Standard defaults; older DeepSeek passes need retesting while Standard/GPT bindings remain valid.
- `responses_protocol.gd` converts canonical messages/images and Orca-only function schemas into stateless Responses input, `function_call` and matching `function_call_output` records. Requests use `store=false`, `truncation=disabled`, `include=[reasoning.encrypted_content]`, and an 8192-token reasoning/output cap; no server response ID, hosted tool, background task, or automatic server compaction is used.
- `APIClient` reuses authorized endpoints, HTTPClient/SSE byte parsing, lifecycle identity, cancellation, and deadlines. It consumes Responses text/argument deltas and requires a successful completed response; final text and arguments must match emitted deltas. JSON fallback normalizes the same bounded contract. Incomplete/refused/unknown output, duplicate item/call IDs, malformed metadata, excessive calls, and missing completion fail before execution.
- At most 64 output items/content parts, 16 calls, 256-character IDs, and 2 MiB each of visible text, arguments, and combined encrypted/plain reasoning are normalized, within existing 1 MiB SSE-event/line and 16 MiB aggregate/request caps. Sanitized assistant phases and private output items replay only during the active turn through an exact provider/base/deployment/effort/style/format binding. The ordinary Chat-shaped controller call/result protocol, permissions, approval, batching, and compaction remain authoritative. Context estimates include private continuation bytes conservatively. Private envelopes are never displayed or persisted, are stripped from all Chat wire copies, and are removed before turn-end busy signals can begin another turn. Later user turns and restored sessions use visible conversation history rather than prior private reasoning/phase records.
- Compatibility failures retain the exact challenge gate. A final mismatch distinguishes extra formatting from missing/changed acknowledgement and shows at most 160 sanitized characters of synthetic visible output with the original challenge redacted. This feedback is memory-only; no project context, credentials, raw reasoning, or probe transcript is added to stored pass metadata or support reports.
- Permanent component/controller/session/settings tests and a 15-request localhost integration cover the reported Azure 400, explicit `none`, the real two-step Responses probe, multimodal/multi-tool/no-tools continuation, cached usage, JSON fallback, incomplete/error/disconnect/Stop, and DeepSeek retained-reasoning positive/negative controls. These fixtures establish transport behavior, not live deployment competence. Real Azure model/region/API acceptance remains a manual gate.

`deepseek_response_compatibility.gd` handles the observed Foundry DeepSeek `</think>ORCA_AGENT_PROBE_OK ...` artifact only for the explicit Azure DeepSeek profile. It removes exactly one lowercase closing delimiter at the start of visible output after at most 64 ASCII whitespace characters. Leading whitespace, all other text, inline/fenced markup, repeated delimiters, and wrong acknowledgements remain unchanged. The streaming filter buffers at most 72 candidate characters before resolving, flushes incomplete literal prefixes only at successful completion, and is discarded on cancellation/failure/retry. Chat JSON/SSE and Responses message parts use the same normalization; Responses validates final raw text against raw deltas before accepting normalized content. Canonical replay items match the cleaned assistant message without a second normalization pass. The exact probe check is unchanged. This does not parse full inline `<think>...</think>` blocks or infer whether arbitrary model text is private reasoning.

DeepSeek's public [Responses compatibility guide](https://api-docs.deepseek.com/guides/responses_api), checked 2026-10-19, documents private plain `reasoning_text` items and unsupported encrypted-content fields on its native endpoint. This contract is supported only through the explicit DeepSeek setting; Azure can differ and remains a live acceptance gate. Plain reasoning stays in the active private envelope, counts toward context and byte limits, and never enters the visible transcript, session storage, or support report. The new 13-request localhost fixture covers Chat/Responses SSE/JSON probes, fragmented delimiter/normalized replay, required plain reasoning, incorrect nonce denial, and unchanged Standard-profile behavior. No live DeepSeek request was made for implementation.

#### One-Click Agent Enablement (1.4.0)

- **Test & Enable Agent tools** combines explicit user enablement with the existing project-free probe. A matching success records the pass and turns on the existing toggle automatically; users can turn it off. Opening Settings, restoring a disabled pass, and duplicate success signals do not re-enable tools.
- Settings retains one memory-only intent fingerprint bound to normalized provider/base URL, exact model, reasoning effort, API mode, continuation style, and credential fingerprint. It survives unchanged exact-origin confirmation, is consumed once on success, and is discarded on profile edits, failure, cancellation, provider changes, or cancelled origin confirmation. The returned binding must still match the current form before the guarded enabled flag is written.
- `Config.record_agent_probe_pass()` still records a disabled pass by default. The Settings action separately calls guarded `set_agent_enabled()` using the captured user intent; a protocol pass alone never authorizes tools. Runtime exact-binding checks and project approvals are retained. No pending intent or credentials enter persisted compatibility metadata.
- URL edits immediately refresh visible compatibility state. Saving when switching providers retains Azure API/continuation selections so an enabled exact profile does not lose its binding on return. Real EditorSettings/UI regressions cover all five editable provider types, manual opt-out/restoration, duplicate/stale outcomes, model/credential/API/style drift, failure/cancellation, and origin-confirmation paths.

#### Script References (1.4.0)

- Drag up to four standalone project `.gd` files from the FileSystem dock or open-script list onto the composer. Compact removable chips float above the input/images/checklist without reserving conversation space. Clicking a chip explicitly opens the current script after rechecking project, symlink, protected-addon, and existence boundaries; full paths appear in tooltips. Submitted/restored user messages show non-removable reference chips.
- `script_references.gd` reads source at Send, not drop/hover. Disk input is bounded to 2 MiB, validated as UTF-8 without NUL, and normalized to LF. Each immutable source snapshot contains at most 300 lines / 16 KiB with explicit total/included lines, source provenance, and truncation. A 100 ms inter-file preparation deadline bounds batches alongside byte/count limits. Exact active unsaved CodeEdit text is accepted through public APIs without a disk hash; an inactive dirty script fails with activation/save guidance rather than using stale saved content. Built-in scripts, directories, external paths, symlinks, and Orca's own addon are excluded.
- Godot 4.7.2 open-script-list drags carry `script_list_element`, an internal editor-control identity rather than a file path. Orca only compares it to public `get_current_editor()` and resolves the already-open `get_current_script()` path. It never traverses the supplied control, invokes its methods, loads a resource for attachment intake, or persists object references. FileSystem drags use bounded `files`/`files_and_dirs` paths. Hover reads neither source nor resources; mixed unsupported batches reject atomically and duplicates do not add chips.
- The composer hover cue matches the accepted payload: **Drop scripts to attach** for scripts and **Drop images to attach** for project images.
- Canonical user messages retain text, images, and optional strict-allowlist `script_references` snapshots. `AgentController` snapshots/copies them at submission and restoration. `APIClient` validates canonical records before converting references into clearly labeled untrusted user text, then applies image projection/materialization; Chat and Responses receive no attachment metadata field. `ContextBudget` estimates the same outgoing representation while compaction retains canonical snapshots and complete turns. Chat-only/text-only profiles can use source context without enabling tools or vision.
- References belong to their original message and are not automatically refreshed or attached to later messages. Retained historical snapshots remain available until normal complete-turn compaction. Existing file mutation paths still require a fresh saved `read_file` hash and explicit approval. Draft paths are memory-only; submitted project paths and bounded source snapshots persist as plaintext local conversation data under the existing 16 MiB session limit and delete with the session. Invalid stored references mark restoration truncated/view-only. Support reports and historical tool events do not receive reference source.
- Busy turns accept next-message reference drafts. Preflight errors preserve drafts, successful submission clears only submitted attachments, and a provider failure before tools restores the submitted draft only if no newer text/image/reference draft exists. New Session/restoration clears pending reference paths. Script references coexist with image intake and the composer Tab shortcut. Actual open-list mouse-drag acceptance, live model usefulness, and additional platforms remain manual checks; permanent fixtures cover payload identity and real Control drop routing.

#### Image Attachments (1.3.0)

- User-selected PNG, JPEG, and WebP still images can be attached in Plan and Work through an Orca-owned attachment window (desktop drop or Browse), explicit clipboard-image Paste, or internal project-file drag-and-drop onto the composer. The image button is capability-aware; vision support is independent of Agent-tool compatibility. No automatic screenshots, image tools, OCR, or document extraction are included.
- `composer_input.gd` uses public `TextEdit._paste()` to handle both native Paste shortcuts (Ctrl/Cmd+V) and context-menu Paste. It checks clipboard image availability only on explicit Paste, reads pixel data only after capability/session/count checks, and normalizes images through the same bounded preparation. Image paste preserves text, caret, and selection; text-only clipboard content retains selection replacement and undo regardless of model vision. Image files copied in a file manager are not clipboard pixels. Platform clipboard decoding happens inside Godot before Orca can check returned dimensions; oversized returned images are rejected before Orca duplicates or encodes them.
- Internal Godot `files`/`files_and_dirs` payloads use public Control drag forwarding, preserve normal TextEdit text dragging, and show a temporary neutral cue over the input without changing layout. Hover validates only payload shape, local extensions, profile/session, and count; it never reads files or constructs resources. Picker, Paste, and drop recheck permission/count and storage before accepting an atomic batch. Draft intake remains available for the next message while a provider turn is active.
- `image_attachment_window.gd` is a compact, explicitly native (`force_native`) non-exclusive transient Window opened by the image action. Its own `files_dropped` signal handles desktop images; Browse opens the existing FileDialog parented to this Window. Native desktop drops in this separate Window do not route to the editor's root drop/import handler. Intake remains bound to the opening session ID, current capability, limits, and visible main view; close, New Session, History/Settings, model changes, and teardown invalidate/close the window, and late closed/stale selections are ignored. Errors and the attachment count appear inside this window. No project file is created by attachment preparation; draft image bytes stay in memory and submitted images persist only in project-scoped `user://` session data.
- Orca registers no desktop-drop listener on the main editor Window and never replaces editor callbacks or disconnects its listeners. Godot's root native-drop signal is not cancellable: desktop files dropped on the main editor/dock still trigger Godot's project import. The image-action tooltip directs desktop drops to the separate attachment Window. Clipboard pixels and internal FileSystem-dock drags remain direct composer intake. Native OS drag-hover cues are unavailable through the drop signal; the temporary cue applies to internal Godot drags only.
- Removable 56 px thumbnails float above the composer inside a non-container overlay host, so the dock's MarginContainer cannot stretch them across the conversation. The transparent 64 px row is sized to its thumbnails rather than the dock, with individual neutral thumbnail frames, subtle shadows, and compact close controls. It reserves no layout row: conversation, composer, and empty-state geometry remain unchanged, and conversation content scrolls behind the thumbnails. A visible task checklist shifts the overlay above the checklist without covering it. The composer image and Send actions use matching independently sized 22 px editor-scaled artwork. The image action has an explicit muted disabled tint; unavailable actions cannot open the picker or display hover feedback. Submitted and restored user messages contain clickable previews. Drafts remain editable during active turns; preflight failures preserve them, and provider failures before tools restore the submitted image draft only when no newer draft exists.
- `image_attachments.gd` reads at most 10 MiB per selected file, checks bounded format headers before decoding, rejects animation, and limits source images to 8192 pixels per side / 16 megapixels. Images are normalized to PNG, capped at 2048 pixels per side and 1 MiB each through bounded resizing. Up to four images are accepted atomically per selection/message. Absolute source paths and original metadata are not retained.
- `image_capability.gd` resolves supported/unsupported/unknown input using exact endpoint/credential-aware provider discovery, canonical hosted model metadata, and known fallbacks. Unknown profiles expose an explicit Provider setting bound to provider/base endpoint/case-sensitive model; it asserts compatibility, does not probe vision, cannot override known unsupported metadata, and does not enable Agent tools.
- DeepSeek capability is model-specific: its public [Vision guide](https://api-docs.deepseek.com/guides/vision) and [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing), checked 2026-10-12, document `deepseek-flash` and its retired Flash aliases as image-capable; `deepseek-v4-pro`, legacy `deepseek-chat`, and `deepseek-reasoner` have text-only fallbacks. Exact fallback names apply only to the canonical provider endpoint, never arbitrary aliases/servers. Available image-action tooltips name the selected model; unavailable controls retain a stronger muted tint and are tested through model-switch refresh and picker denial. This metadata check is not a live-provider vision test.
- Internal user history keeps text plus immutable image records. Model switching in 1.4.0 adapts only outgoing copies: `image_attachments.gd` projects earlier user images into explicit text placeholders for text-only/unconfirmed profiles, retaining original text and prior assistant descriptions. Returning to a confirmed vision profile rematerializes original images still in retained model context. The current user turn's images are never projected away. `APIClient` validates canonical records before projection, rechecks capability for inclusive requests, creates standard Chat Completions text/image_url parts when permitted, and rejects requests above 16 MiB before transport.
- Context budgeting excludes base64 from text estimates and reserves conservative per-image capacity (at least 4096 tokens, scaled by dimensions). Budgeting estimates the same turn-bound projection used by transport, counts placeholder text rather than omitted image reserves, and returns canonical history when compacting so retained images survive model switches. This is not provider-exact image token accounting; reported usage remains authoritative.
- New attachments still require confirmed image support and retain their text/image drafts on preflight rejection. Existing historical images no longer block text-only turns. The image-action tooltip gives non-blocking feedback that original images are preserved while text requests use placeholders/prior descriptions. The controller snapshots the image policy with the provider before turn signals; every follow-up/finalization passes the same private boolean to transport. Capability loss in an image-inclusive active turn fails rather than silently discarding that turn's images. Neither the private policy nor temporary placeholders are persisted.
- Session JSON stores hash-addressed image records once per conversation and references them from visible events and continuation. Storage is project-scoped, plaintext local data, bounded to 32 unique images / 8 MiB decoded image data per conversation and 16 MiB total session JSON. Images are removed through the existing conversation retention/deletion lifecycle. Existing text-only sessions remain readable. Missing/corrupt references make restoration truncated/view-only. Draft attachments and pending approvals are memory-only.
- Permanent image component and localhost integration tests cover preparation, corruption, capability drift, context estimates, deduplicated persistence/deletion, missing-image restoration, controller follow-ups, tray layout/removal, and actual two-request multimodal SSE transport. `image_intake_test.gd` covers explicit Paste/text undo, capability/count/view-only rejection before decoding, atomic drops, hover without reads, busy drafts, cue cleanup, owned-window/session/close guards, untouched main-editor listeners, teardown, and an actual forced Control drag over TextEdit. The editor-scale suite checks bounded overlay and unchanged conversation/composer geometry. `native_image_drop_test.py` drives real X11 XDND transfer into `image_attachment_window_editor_test.gd`, requires the actual editor root import handler to exist, validates accepted/unsupported native drops and cancelled late intake, and compares all non-generated project bytes before/after. Godot 4.7.2 Linux/X11/Vulkan passed with zero project-file changes. The native fixture retains editor progress-dialog and shutdown RID/ObjectDB diagnostics; early fixture teardown initially crashed and was corrected by waiting for editor filesystem/teardown completion. Windows, macOS, Wayland, OpenGL, live vision, actual OS clipboard, and detached-editor acceptance remain unverified.

- OpenAI-compatible streamed Chat Completions requests.
- UTF-8-safe Server-Sent Events parsing.
- Incremental assistant text updates.
- Fragmented streamed tool-call reconstruction.
- Stop/cancel behavior with stale-request protection.
- End-to-end lifecycle ownership: each provider call has a controller-issued request ID, while one monotonic turn ID spans its complete tool loop and request-scoped UI state.
- Maximum tool-round limit.
- Mode transition messages that override stale Plan/Work statements in history.
- Provider-reported token accounting across initial and follow-up tool requests.
- Best-effort context-window and session-cost estimates using provider-reported cost, cached public model metadata, and conservative built-in fallbacks.
- Request-scoped provider snapshots prevent endpoint, model, or reasoning changes in the middle of a tool loop.
- Known model context windows are budgeted before every initial and follow-up request using a conservative UTF-8 size estimate, explicit final-answer and tool-result reserves, and oldest-complete-turn compaction.
- Compaction never splits the active turn or an assistant tool-call batch from its complete matching tool results. If a completed tool continuation cannot fit with full schemas but fits without tools, Orca makes one safe finalization request. If even that protected request cannot fit, Orca stops locally and retains a deterministic sanitized checkpoint instead of sending a predictably oversized request.
- DeepSeek/xAI `reasoning_content` and OpenRouter `reasoning_details` are reconstructed and preserved for tool-call continuation without displaying private chain-of-thought.
- Bounded opaque streamed tool-call metadata is retained so Gemini thought signatures survive multi-round tool continuation.
- LM Studio, Ollama, and Local OpenAI-compatible adapters merge string system messages into one leading system message on the outgoing request copy, accommodating templates that reject multiple or later system messages. Fresh editor/project guidance, tasks, correction/budget/observation/cleanup/finalization notices retain their original section order; user, assistant, multimodal, and tool messages retain their order and matching IDs. Controller context indices, compaction, persistence, and permission checks remain based on the original history.
- Gemini's OpenAI-compatible endpoint may label a complete valid tool-call response with `finish_reason: stop`; its adapter explicitly permits that provider quirk while other providers retain strict contradictory-finish rejection.
- Every provider tool batch is preflighted atomically before execution. Each argument must decode to one JSON object, and multiple calls are permitted only when every call is a known independent read-only tool. Work-mode requests, task updates, reviewed mutations, run/stop operations, observations, verifications, and unknown tools require singleton batches. Invalid batches execute no tools, are excluded from protocol history, and receive at most one side-effect-free regeneration request; a second invalid batch ends visibly without replay.
- Transport failures retain structured category, phase, HTTP status, byte count, retryability, and partial-response metadata through the controller boundary.
- Failed partial responses are marked incomplete in the transcript and are not committed to model history.
- Completed conversations, bounded activity summaries, changed-file summaries, mode, and usage are persisted per project.
- History can restore and continue valid sessions and sanitized recovery checkpoints; unsafe, cancelled, dirty, or truncated sessions are view-only.
- New Session archives the current transcript and restores the empty state while preserving mode, settings, and already-applied files.
- Each turn automatically receives a bounded root `res://AGENTS.md` and bounded project-skill catalog metadata when present. Both are private request-scoped system context and are removed from stored continuation history after the turn.
- Repetitive tool activity is detected below the hard caps. Orca makes one final provider request with tools disabled; tool calls returned from that final request are denied without execution while preserving protocol-valid results.

Image model-switch regressions additionally exercise repeated text/vision transitions and real tool continuations across eight requests, extending the original two-request image fixture to ten. Component coverage includes projection, reserves, canonical compaction, restart restoration, draft preservation, cancellation/failure, and privacy boundaries. These deterministic fixtures use synthetic images and no live model inference.

### Godot Intelligence

- `res://AGENTS.md` is loaded automatically from the project root only, capped at 32 KiB and 400 lines, rejected on invalid UTF-8, NUL bytes, or symbolic-link traversal, and wrapped as untrusted guidance subordinate to system, user, mode, approval, and runtime safety rules.
- Immediate `res://skills/<slug>/SKILL.md` entries contribute only bounded `name`, `description`, slug, and path metadata automatically. A skill body is loaded only through `read_project_skill` using the exact discovered name and is wrapped as non-recursive, non-executable project guidance.
- `inspect_godot_api` reflects `ClassDB` and registered global-class metadata into bounded signatures, type records, hierarchy, properties, signals, constants, and enums. It produces validated Help topics for the editor's public `goto_help()` path but does not scrape documentation prose, load scripts, construct reflected objects, or instantiate scenes.
- `read_gdscript_function` performs bounded lexical extraction of one named function, optional adjacent documentation/annotations, nested-class scope, and one-based navigation. For the exact open unsaved script it uses public editor source and marks it `editor`; that source never carries a disk SHA-256 or becomes a patch base.
- `discover_dependencies` traverses deterministic breadth-first forward dependencies or reverse dependents from `ResourceLoader.get_dependencies()`. It reports saved serialized relationships only and does not load or instantiate resources.
- All four model-callable intelligence tools are read-only and available in Plan and Work.

### Live Scene Intelligence (1.4.0)

- `inspect_editor_scene` reads the actual current editor scene through public APIs, including unsaved node additions and native property changes. Its default `selection` scope reads selected nodes only; `scene` and `subtree` traverse bounded non-internal descendants.
- Fixed native values cover Control anchors/offsets/sizing/flags, parent Control/Container context, Node2D/Node3D transforms, visibility, processing, and selected container properties. Script and selected resource identities are reported without source, recursive expansion, or custom getters.
- Non-indexed values use `ClassDB.class_get_property()` against core-native classes. Indexed Control anchors/offsets use statically typed native method binds: Godot 4.7 generic indexed reflection can call a script override. An adversarial `@tool` fixture proves these reads bypass custom exports, `_get()`, `_get_property_list()`, `_get_minimum_size()`, and shadowed native methods.
- Snapshots identify `source: editor_scene`, scene path when present, selection, known unsaved state, and truncation. They never carry a disk hash or authorize a mutation. Optional `scene_path` binds inspection to the expected current scene; every call reacquires editor state without retained Node references.
- Activity cards group with other reads and show a scope target. Raw snapshot values are available in live details but never persisted as tool events; restoration shows a historical summary requiring fresh inspection, without a stale scene-opening action.

### Modes

| Mode | Capabilities | UI color |
| --- | --- | --- |
| Plan | Read-only exploration, context, diagnostics, and planning. | Orange |
| Work | Plan capabilities plus reviewed project proposals and bounded Orca-owned game process control. | Green |

Work is the default. Mode switching is blocked while a turn or edit approval is active. Its internal enum remains `BUILD` for session compatibility. Work allows immediate run/stop external operations; only project-file changes enter proposal approval.

Plain Tab toggles Plan/Work only in the focused, visible prompt box and uses the normal controller permission checks and session-saving path. It preserves focus, text, caret, selection, and draft images without opening the mode menu. Repeats and locked-state presses are consumed without inserting tabs; Shift/Ctrl/Alt/Meta+Tab retain native behavior. The mode tooltip advertises the shortcut. Other editor controls have no Orca Tab binding.

### Activity And Review UI

- Consecutive read-only tool calls are collapsed into aggregate activity groups with call count, combined status, and total duration.
- Expanding a group retains each tool card's target, outcome, duration, bounded live output, and navigation action.
- Mutation, unknown, and future non-allowlisted tools remain standalone; change proposals always use dedicated review cards.
- A bounded collapsible checklist above the composer tracks multi-step work with pending, active, completed, blocked, and cancelled states.
- Unified red/green diffs inside the dock.
- Expanded side-by-side Previous/Proposed diff view.
- Native code minimaps in both expanded review panes provide click/drag navigation and a viewport indicator, with synchronized vertical scrolling and preserved red/green change highlights. Width follows editor scale and adapts to pane width; miniature rows retain Godot's fixed 2 px ink/1 px gap so native change markers stay aligned at larger scales. Resizing a narrow review window stacks the panes. GDScript reviews use separate native syntax highlighters and the editor syntax palette. Dark-theme review surfaces use deep charcoal (`#1a1a1a`) instead of the lighter native control background; light-theme backgrounds are retained. Rounded, quiet pane borders frame the read-only code without a bright outline. This is display-only: exact proposal content and Apply/Reject handling remain authoritative.
- Apply, Reject, Revert, and Open File actions.
- Validation status on change cards.
- Scripts open at a relevant line and column.
- Scenes and resources open in their corresponding Godot editor.

### Current Tools

| Tool | Modes | Purpose |
| --- | --- | --- |
| `list_directory` | Plan, Work | Lists one project directory. |
| `read_file` | Plan, Work | Reads bounded one-based line ranges with line numbers and a SHA-256 hash. |
| `search_files` | Plan, Work | Recursively searches bounded project text files and returns path/line/column matches. |
| `inspect_scene` | Plan, Work | Reads bounded saved `PackedScene`/`SceneState` hierarchy, serialized properties, instances, groups, and signal connections without node instantiation. |
| `inspect_editor_scene` | Plan, Work | Reads bounded current editor scene/selection/subtree state, including unsaved native layout/transforms, without mutation, custom getters, or a disk patch hash. |
| `inspect_project_settings` | Plan, Work | Reads a bounded overview or one allowlisted typed ProjectSettings value with active feature overrides. |
| `read_project_skill` | Plan, Work | Loads one exact bounded skill body selected from the request-scoped project skill catalog. |
| `inspect_godot_api` | Plan, Work | Reflects bounded `ClassDB` signatures and safe editor Help topics without object construction or prose scraping. |
| `read_gdscript_function` | Plan, Work | Reads one bounded function from saved source or the exact unsaved editor source for that open script. |
| `discover_dependencies` | Plan, Work | Traverses bounded saved serialized dependencies or reverse dependents without resource loading. |
| `get_editor_context` | Plan, Work | Captures active scene, selected nodes, active script, caret, selected code, and open/unsaved state. |
| `get_diagnostics` | Plan, Work | Reports Orca validation records, observed editor-process errors, and play state. |
| `update_tasks` | Plan, Work | Atomically replaces bounded session task metadata without modifying project files. |
| `request_work_mode` | Plan only | Suspends once for explicit permission to continue the active task in Work mode. |
| `apply_patch` | Work only | Materializes precise line edits into a reviewed and validated file proposal. |
| `propose_input_map_changes` | Work only | Prepares bounded typed Input Map action changes for structured approval. |
| `propose_main_scene_change` | Work only | Proposes a validated saved scene as the project launch scene through structured review. |
| `propose_project_settings_changes` | Work only | Proposes an atomic batch of six allowlisted display settings through typed review. |
| `propose_scene_changes` | Work only | Proposes bounded typed scene creation, node, property, script, child-instance, and bindless signal operations. Script changes use preliminary execution trust followed by candidate approval. |
| `run_current_scene` | Work only | Starts the saved current scene in one bounded nonblocking Orca-owned process. |
| `run_main_scene` | Work only | Starts the configured saved main scene in one bounded nonblocking Orca-owned process. |
| `stop_game` | Work only | Stops only the currently retained direct process started by Orca. |
| `observe_game_run` | Plan, Work | Reads an immediate bounded snapshot for an exact Orca run ID. |
| `verify_game_run` | Plan, Work | Evaluates only criteria declared before an exact run and returns a scoped verdict. |

### File Safety

- Only `res://` paths are accepted.
- Simplified paths must remain under the project root.
- Paths containing symbolic links are rejected.
- Agent tools cannot access Orca's own `res://addons/orca/` directory.
- Binary and oversized reads are rejected.
- Search and read output are bounded.
- Scene inspection accepts saved `.tscn` files up to 2 MB, rejects unsaved editor state, and never instantiates scene nodes.
- Live inspection reads only the current scene's core-native, non-internal nodes; project, symlink, protected-addon, instance, and script/resource reference boundaries remain enforced. Unsaved inspection is read-only and does not relax saved-state mutation checks.
- Project settings inspection uses fixed summary categories, allowlists explicit paths, blocks sensitive-looking names, and caps valid JSON output at 64 KB.
- Automatic project instructions and skill metadata are bounded and request-scoped. Skill bodies require an explicit exact-name read and are never recursively loaded merely because their text references another file.
- Focused script reads enforce canonical `.gd` project paths, symlink and Orca-directory rejection, a 2 MiB source limit, and separate bounded output. Unsaved editor source deliberately omits a disk hash.
- Dependency discovery enforces canonical existing project resources, symlink and Orca-directory rejection, bounded graph traversal, and whole JSON output.
- Input Map proposals target only `res://project.godot`, require its current SHA-256, preserve unrelated bytes, and compare affected disk/live actions before review and apply.
- Main-scene proposals validate a saved `.tscn`, normalize path/UID identity, preserve unrelated project bytes, and synchronize the live ProjectSettings value.
- Low-risk ProjectSettings proposals use an exact six-path allowlist, strict scalar types, conservative dimension caps, and affected live/disk equality.
- Structured scene proposals support typed-root creation, add, typed property, leaf rename/remove/reparent, dependency-free script attach/detach and child instances, and bindless signal operations with hash binding and complete pack/save/load validation.
- Unsaved scripts and scenes cannot be patched.
- Existing files require the SHA-256 returned by `read_file`.
- File existence and hashes are checked during proposal and immediately before replacement.
- Writes use a verified temporary file and recoverable replacement sequence.
- Applied changes retain enough in-memory state for guarded revert.
- Run tools never accept executable, argument, environment, or PID input; they launch only the current Godot executable against this project and retain one owned direct process.

## Architecture

```text
EditorPlugin (orca.gd)
  -> ChatWindow
       -> UiMetrics (effective editor-scale conversion for authored geometry)
       -> structured message/activity/change feed
       -> ResponseAttribution (bounded model/mode-only display metadata)
       -> ChangeCard / InputMapChangeCard / MainSceneChangeCard / ProjectSettingsChangeCard / SceneChangeCard
       -> ToolActivityGroup -> ToolActivityCard children
       -> TaskListPanel
       -> ModeSwitchCard
       -> SettingsView -> AgentCompatibilityProbe -> isolated APIClient
       -> HistoryView
       -> SessionStore (project-keyed user:// JSON)
       -> DiagnosticsService
       -> SupportDiagnosticReport (strict allowlist and deterministic serialization)
       -> GameProcessService
       -> ModelCatalogService
       -> ProviderModelService
        -> AgentController
               -> APIClient (HTTPClient + SSE) -> EndpointPolicy
                     -> ResponsesProtocol (stateless input/output and bounded opaque active-turn continuation)
             -> ProviderRegistry
                    -> OpenAI / Gemini / xAI / DeepSeek / OpenRouter / Custom adapters
              -> ContextBudget (request estimate, reserves, complete-turn compaction)
              -> ScriptReferences (bounded explicit source snapshots and user-context projection)
             -> ProjectInstructions (request-scoped root guidance)
             -> ProjectSkills (request-scoped catalog and explicit body reads)
             -> ToolLoopGuard (repetition/no-progress finalization)
             -> Tools
                    -> EditorContext
                     -> SceneInspector
                     -> EditorSceneInspector (public live editor acquisition + bounded native snapshot)
                    -> ProjectSettingsInspector
                    -> GodotApiInspector
                    -> GDScriptFunctionReader
                    -> DependencyInspector
                    -> InputMapProposal
                    -> MainSceneProposal
                    -> ProjectSettingsProposal
                    -> SceneProposal
                    -> PatchUtils
                    -> DiffUtils
                    -> DiagnosticsService records
```

### Plugin Lifecycle

`addons/orca/orca.gd` initializes editor settings, instantiates the toolbar and chat dock, registers them with Godot, and removes them when the plugin exits.

### Request Lifecycle

```text
User submits prompt
-> AgentController snapshots the selected provider profile
-> AgentController captures request-scoped editor context
-> AgentController loads bounded root project instructions and skill catalog metadata
-> user message and temporary context are sent to APIClient
-> APIClient streams SSE deltas
-> ChatWindow updates one assistant card
-> complete tool calls are returned to AgentController
-> tools run sequentially
-> tool results are appended to protocol-valid history
-> model continues until a final response
-> temporary editor context is removed from stored history
```

The request-scoped context, including project instructions and skill catalog metadata, remains available through all tool rounds in one turn but does not pollute later turns with stale state. Skill bodies are not included automatically; `read_project_skill` returns one selected body as a normal bounded tool result.
The provider snapshot and image-inclusion policy are also retained through all tool rounds so settings changes cannot mix endpoints, models, or historical-image handling inside one protocol turn. The API client receives canonical messages plus the private `_orca_include_history_images` boolean, validates records, and builds a projected wire copy. Pixel-identical image records are validated once per request with exact ID/data/dimension matching; changed pixel records must revalidate, and at most 32 unique image identities are accepted, matching session bounds. Budget preparation estimates that same copy while retaining canonical messages and context-index mappings for complete-turn compaction. Placeholders alter existing user content only; they never add system messages or split tool-call/result groups.

Each user submission receives one monotonic controller turn ID. Every initial provider request and tool follow-up receives a distinct monotonic provider request ID through private request options; `APIClient` carries that ID on all stream and terminal signals without serializing it into provider payloads. The controller reserves request ownership before publishing thinking/finalizing state and rechecks the captured turn/request pair before transport, so synchronous cancellation cannot launch an orphan request. It claims matching terminal events once and invalidates ending ownership before any busy/terminal signal can synchronously start a new turn. Awaited approval and run-observation continuations remain bound to the originating turn. `ChatWindow` independently checks the turn ID before changing working/stream cards, tool or review cards, session persistence, composer state, or Send/Stop controls.

Before each initial/follow-up provider call, the controller captures the configured model ID and current request mode into a sanitized `{model, mode}` record. Thinking/finalizing workflow details carry a copy for streaming/tool-preface/interruption UI. `message_received` now has the internal four-argument contract `(turn_id, role, content, attribution)`; matching completion captures attribution before clearing ownership/provider state and carries that copy through terminal reentry. This labels the configured request model, not an independently verified server implementation or a substituted provider alias. Plan-to-Work approval updates attribution only on the next Work provider request. Local fallback/denied-tool reports emit empty attribution.

`response_attribution.gd` accepts only nonempty exact model strings of at most 512 characters without surrounding whitespace, newline/tab/NUL controls, and an integral mode 0/1 (including Godot's JSON float representation). Unknown fields are discarded; invalid records are omitted instead of backfilled from current/session settings. The visible assistant event may retain this optional record and its matching mode, but model continuation, provider payloads, usage, and strict-allowlist support reports do not receive it. Existing version-1 text/image sessions remain readable without migration.

Plan exposes `request_work_mode` only when normal Agent tools are available. The request contains one bounded user-facing reason, may suspend at most once per turn, and must be the only call in its provider batch. An exact approved decision changes the active mode and UI immediately. The primary system prompt is regenerated for Work and the exact tool result records approval without inserting a system message inside the active protocol turn; Orca then issues a new provider request with Work schemas. Rejection continues in Plan without exposing another escalation request; Stop cancels the pending decision and leaves the mode unchanged. Pending decisions and reasons are never persisted.

Before each provider request, `context_budget.gd` resolves the request-scoped model's known context window, preferring the provider-reported model identity during a tool continuation, and estimates the serialized messages and tool schemas conservatively from UTF-8 bytes plus structural overhead. It reserves bounded capacity for a final answer and, while tools are exposed, for a later tool result. If necessary it replaces the oldest contiguous completed turns with one system notice. Historical tool rounds are removable only when the assistant call, every matching tool result, and the terminal assistant response are complete. The active user turn, provider reasoning continuation, temporary editor/task context, and runtime observation remain protected. Unknown custom-model limits continue without speculative blocking. After complete tool protocol, a full-tools budget failure attempts one controller-owned no-tools finalization, including same-turn process cleanup; if the finalization request also cannot fit, no transport occurs and the turn becomes a deterministic sanitized local checkpoint.

Compaction changes only model continuation history. The visible session transcript remains intact, while later session snapshots naturally persist only retained user/assistant continuation. The internal compaction notice and request-scoped system messages are not persisted.

### Streaming Lifecycle

`api_client.gd` uses a nonblocking `HTTPClient` state machine. It parses SSE lines at byte boundaries so a UTF-8 code point split across transport chunks is not corrupted. Successful SSE bytes are counted but not retained as a duplicate raw response; only bounded JSON and HTTP error bodies are buffered. The raw transport allowance is 16 MiB so token-level JSON/SSE framing does not prematurely reject otherwise bounded model output. It accumulates separately bounded assistant content, provider reasoning, reasoning details, tool-call arguments, and opaque tool-call metadata, then emits a response shaped like a completed Chat Completions response for the controller.

The transport supports:

- Connection timeout.
- Inactivity timeout.
- Response and event size limits.
- Regular JSON fallback for compatible endpoints that ignore streaming.
- Explicit cancellation.
- Private transport generations that stop stale client coroutines, plus caller-owned lifecycle IDs on every stream and terminal signal.
- Streamed usage capture through `stream_options.include_usage`, including usage-only events with empty choices.
- One safe retry without `stream_options` when a provider rejects that option before streaming begins.
- One bounded retry for connection failures before the POST is submitted. Requests are not automatically replayed after submission or partial output.
- Positive SSE/JSON content-type handling, including `application/*+json`, and bounded rejection of unexpected successful response types.
- Separate aggregate-response, SSE-line, SSE-event, assistant-text, reasoning, reasoning-detail, tool-argument, and HTTP-error-body limits.

Each completed HTTP request contributes its reported input, output, and cached tokens to the current session, including every continuation in a multi-round tool loop. Stored `context_tokens` remains the latest provider-reported total-token value. Active/blocked preflight estimates are a separate memory-only `request_budget` display snapshot containing only token counts, selected context limit, reserve counts and prepared/blocked state; controller session snapshots exclude it. Cost prefers a provider-reported value and otherwise uses automatically resolved model metadata. Missing provider usage remains unavailable/partial and is never replaced with local estimates. Local budget errors now state the actual unsent estimate and reserves, avoiding the misleading impression that a previous 4.1k request exhausted the failed continuation's window.

`model_catalog_service.gd` infers known providers from the configured base URL, loads a compact selected-model cache from `EditorSettings`, and refreshes stale metadata from `https://models.dev/api.json` at most once every seven days per provider/model pair. The response is capped at 8 MB. Only public provider/model identifiers are requested; API keys, prompts, file contents, and project context are not sent. `model_metadata.gd` supplies conservative offline fallbacks and normalizes context windows and per-million-token rates. Unknown custom endpoints continue working, but cost or context limits remain unavailable when neither the provider nor a trusted catalog supplies them.

`provider_model_service.gd` requests the selected provider's model-discovery endpoint with a 30-second timeout and 8 MB response limit. Hosted profiles require authentication; local profiles omit Authorization when their optional key is empty and are contacted only after an explicit Refresh action. Ollama uses one same-origin `/api/tags` request, LM Studio uses `/api/v1/models`, generic compatible servers use `/v1/models`, and Gemini uses native `v1beta/models`. Native type/capability metadata excludes known embedding models; absent metadata falls back to a case-insensitive `embed` name filter while manual Model ID remains unrestricted. No per-model `/api/show` fan-out occurs. Normalization retains at most 200 models and bounds display/reasoning metadata and cached records. Model lists are cached for one hour in a v3 cache keyed by provider, final endpoint hash, and one-way API-key fingerprint. Discovery failures remain inline settings errors and do not alter the active provider profile.

`provider_registry.gd` is the extension point for provider support. Each adapter defines its canonical endpoint, key help URL, model-list normalization, request headers, reasoning request shape, provider-specific reasoning-history sanitation, and narrowly scoped response-compatibility capabilities. Gemini alone currently permits a valid tool-call response labeled with the otherwise contradictory `stop` finish reason; malformed calls and known incomplete finish reasons remain rejected. Native non-Chat-Completions providers still require separate transport adapters.

`local_openai_provider.gd` sanitizes a deep-copied wire message array after image materialization. It joins all string system content with blank-line separators into the first system record and places that record before the ordered non-system conversation. It neither converts user/tool content into system instructions nor invents a prompt for system-free input; malformed non-string system content is retained rather than silently coerced or dropped. Base reasoning sanitation still applies, while opaque tool metadata and multimodal parts are preserved. Normalization is idempotent and stays within the original conservative context estimate. Canonical hosted and advanced Custom adapters retain their own message layouts.

Agent Compatibility probe version 2 keeps the two-request, project-free challenge protocol and adds one fixed synthetic system notice after the matching tool result on request two. This exercises refreshed-context placement through the actual selected adapter. Stored version 1 passes cannot authorize tools: every editable or origin-overridden profile must pass the new exact binding and be explicitly enabled again. Cancellation, per-step request ownership, timeout, exact challenge/result acknowledgement, and project-data exclusion remain enforced. A pass establishes this bounded synthetic protocol, not arbitrary model competence or every template restriction.

`endpoint_policy.gd` is the shared trust boundary for editable provider URLs. It rejects userinfo, queries, fragments, ambiguous separators, malformed ports, dot segments, and already-complete chat/model endpoints; normalizes scheme, host, effective port, and path; and classifies loopback, LAN, or remote scope without DNS resolution. Loopback may use HTTP directly. LAN and remote origins require explicit confirmation persisted per provider as the normalized scheme/host/effective-port origin. Chat and discovery independently reauthorize before creating headers, validate that adapter-generated endpoints retain the authorized origin, and never follow provider redirects. Confirmation is informed consent rather than DNS or certificate pinning.

DeepSeek thinking is enabled at high effort by provider default and otherwise permits output far beyond Orca's response reserve. The DeepSeek adapter therefore sends an 8,192-token maximum for both thinking and non-thinking requests, aligned with the minimum final-answer reserve for its known 64K fallback context. This bounds cost and latency while leaving the user's selected reasoning effort intact.

### Tool Lifecycle

```text
Assistant emits tool call
-> controller validates JSON arguments
-> tool_started event creates activity card
-> tool executes or prepares approval
-> structured execution updates the card
-> text content alone is sent back to the model
```

Tool UI metadata is intentionally kept separate from model-facing content.

Editor context and saved/live scene inspections return readable `content` for activity details plus optional compact `model_content` produced directly from the same typed snapshot/report. The controller sends only that string as the matching tool result, preserving readable UI content, every inspected value, explicit truncation/provenance and the exact call ID. It neither re-parses JSON (which could lose integer precision), drops scene facts nor changes file-read/approval evidence. Other tools retain their existing content. Scene descriptions encourage hierarchy-first `include_properties=false` discovery followed by a focused subtree/property or script read. Failed read activity is summarized as an incomplete tool action; only explicit uncertain apply/revert outcomes claim that a change recovery record exists.

After each completed tool batch, `tool_loop_guard.gd` fingerprints normalized calls, arguments, outcomes, and results independently from the controller's semantic progress epoch. Runtime observation identity ignores elapsed time and observation cursors while retaining run ID, evidence sequence, state, verdict, exit code, output/diagnostic identity, and truncation state; verification identity uses verdict and check-status transitions rather than changing timers. The guard triggers after three identical call/results, an `ABABAB` call cycle, three identical complete rounds, or four rounds without semantic progress. At round eight the controller adds one temporary remaining-budget notice. Reaching the 12-round boundary uses the same finalization path instead of failing an otherwise successful turn. Any tool calls in the final response receive matching denied results. The independent 16-call limit per provider response remains authoritative.

Before loop, round-cap, or context-pressure finalization disables tools, the controller reserves one cleanup operation for an exact active run ID launched in the same user turn. It invokes the process service directly rather than exposing a general post-cap model tool, adds only a fixed coarse cleanup outcome to finalization context and visible fallback text, and never forwards automatic cleanup output or targets an editor-started process, arbitrary PID, newer replacement run, or retained run from an earlier turn.

Before a normal tool batch enters history or execution, `agent_controller.gd` parses every call's argument string and requires one JSON object. Multi-call batches are accepted only for the fixed allowlist of independent reads: directory/file/search, scene and settings inspection, project skill/API/function/dependency reads, editor context, and diagnostics. `request_work_mode`, `update_tasks`, every reviewed mutation, run/stop, observation, verification, and any unknown future tool must be the only call in its batch. Validation is atomic, so no valid read, mutation, approval, or external operation can run ahead of a malformed or unsafe sibling call. The rejected assistant response and arguments are not added to history. Orca may make one fresh correction request from the pre-batch state because no call in that batch executed; the correction notice is request-scoped and removed when the turn ends. A second invalid batch fails as a provider response error without another retry.

### Reviewed Change Lifecycle

```text
Model reads the target and receives SHA-256
-> model calls a Work-only reviewed mutation tool
-> the typed backend validates and materializes an immutable proposal
-> script attach/detach first asks permission to execute exact hash-bound code during candidate construction
-> a kind-specific review card waits for Apply or Reject
-> Apply rechecks mode, live state, disk hash, retained hashes, and validation
-> verified replacement and required live-state synchronization run
-> Revert remains available while the applied file matches the proposal hash
```

Reviewed mutations are singleton provider batches, so only one proposal can be prepared or awaited from a response.
Plan runtime checks reject every reviewed mutation independently of schema exposure, including revert of a previously applied proposal.

### Session Lifecycle

`session_store.gd` stores up to 50 versioned sessions under `user://orca/projects/<project-root-sha256>/sessions/`. Each session contains a bounded visible event log, a provider-independent user/assistant continuation history, mode, provider/model labels, aggregate usage, a sanitized task checklist, and non-actionable changed-file summaries. Writes use verified temporary files and recoverable backups. The index and each session are separate files so one corrupt transcript does not invalidate all history.

The active session is checkpointed after user submission, tool completion, edit resolution, normalized failure/cancellation, completed assistant response, session switching, and plugin teardown. The most recent active session is restored on startup. New Session saves the current conversation before rebuilding controller and feed state; the transition aborts if persistence fails. Starting a blank session clears the persisted active-session pointer until the first prompt is saved.

Restoration regenerates the current system prompt and uses only bounded user and visible assistant messages for model continuation. Historical tool and change records are display summaries and are never replayed. After a provider failure or an unsendable no-tools finalization, complete active-turn tool protocol is validated and collapsed into a bounded local assistant checkpoint containing only normalized tool receipts, current sanitized tasks, and coarse controller-cleanup outcome. Prior calls are never replayed automatically. The checkpoint excludes raw file contents, call IDs, arguments, tool results, process output/IDs, request-scoped editor context, API credentials, hidden reasoning, approval payloads, and revert checkpoints. The separate activity log keeps only its existing bounded display metadata. Unsafe, cancelled, dirty, malformed, or truncated turns remain view-only.

Task state is stored separately from tool protocol. `update_tasks` replaces the complete list atomically, accepts at most 20 items of 240 characters each, permits at most one `in_progress` item, and never requires approval because it cannot mutate project files. Current tasks use one separately tracked request-scoped system message that is refreshed only after a successful matching tool result, removed when cleared, remapped during compaction, and excluded from persisted continuation. Invalid live updates preserve both prior state and prior context; stored data is defensively sanitized.

### Diagnostics Lifecycle

`diagnostics_service.gd` reference-counts one shared public Godot `Logger` across active service instances so plugin reloads or fallback ownership cannot duplicate records. It keeps at most 100 observed editor-process records; messages, paths, and function names have independent character bounds, and warning severity is preserved. Logger callbacks write directly to the mutex-protected static sink without loading resources from a potentially non-main logging thread. Proposed GDScript is validated using a fresh `GDScript`, a path cache hint, and `reload()`. Orca API failures use ordinary stdout logging rather than stderr so transport failures do not feed back into project diagnostics.

The public GDScript plugin API does not expose:

- Historical Output dock contents.
- Complete built-in game-process output and debugger error records.
- Script editor warning/error collections.

Orca must not scrape private editor controls to imitate these APIs. The diagnostics tool states this limitation and reports only supported data. For a process started by `GameProcessService`, it additionally reports bounded stdout/stderr, conservative runtime-error records, elapsed state, timeout, and exit code from public process APIs.

The user-copied support diagnostic report is a separate privacy boundary and never consumes `DiagnosticsService`, game-process snapshots, logs, sessions, transcripts, or provider output. `AgentController` retains one memory-only snapshot of the latest owned provider request using closed provider, outcome, mode, stage, failure-category, and transport-phase enums plus bounded status and boolean fields. Stale callbacks cannot replace that snapshot. `support_diagnostic_report.gd` constructs a new allowlisted dictionary rather than redacting arbitrary input, and the About page copies its deterministic JSON serialization. Exact models, operating-system details, credentials, endpoint components, IDs, prompts, source, tool payloads, reasoning, raw errors, output streams, proposal data, and hashes are excluded.

### Game Process Lifecycle

`game_process_service.gd` is owned by the plugin rather than a conversation. In Work mode, `run_current_scene` and `run_main_scene` validate a saved `.tscn`, reject known unsaved scripts/scenes and concurrent editor or Orca runs, and launch the current Godot executable with internally constructed `--path` and `--scene` arguments through nonblocking `OS.execute_with_pipe()`.

The service retains one private PID, monotonic run ID and snapshot sequence, and separate stdout/stderr pipes. It drains at most 32 KB per stream per editor frame, retains at most 64 KB per stream and 128 KB combined, renders at most 1,000 lines with 4,096 characters per line, retains at most 100 conservative runtime diagnostics, and enforces a 120-second wall-clock timeout. Output beyond those limits is drained but discarded and reported as truncated so a full pipe cannot stall the game. A bounded stream-local parser associates Godot error/warning headers with following `at:` or backtrace locations, including project paths containing spaces.

`stop_game` accepts no PID and calls `OS.kill()` only for the current direct child retained from Orca's own successful launch. Its result includes bounded final state, verification status, output tails, and diagnostics so normal cleanup does not require an immediate diagnostics round; response-imposed diagnostic or output-tail limits are disclosed as truncation. Natural exit records the child exit code. Stop, timeout, launch failure, kill failure, and plugin shutdown have explicit states. New Session does not stop the game, process ownership is never persisted, and plugin teardown attempts to stop an active direct child.

Run/stop operations are external-state mutations, so their schemas are omitted in Plan and independently denied at runtime. They execute immediately in Work mode and do not use file-change cards because they do not alter project files. Selecting Work mode is the permission boundary for these process operations; project file changes continue to require proposal approval. `observe_game_run` and `verify_game_run` are read-only and remain available in both modes.

After a successful singleton run call, the controller appends its matching result and then enters a cancellable observation checkpoint before the next provider request. It waits on editor frames for a terminal transition, meaningful evidence after a 1.5-second settle period, an evaluable criterion, or a five-second ceiling. The resulting request-scoped snapshot identifies this as the first automatic observation, includes one bounded recommended next action, and tells the model not to immediately poll again. Cancelling this pause cancels the model turn but does not stop the independently owned game process.

Each user turn allows at most three successful run attempts, in addition to the existing 12 tool-round limit and the 16-tool-call-per-response transport/controller limit. The first run fixes the turn's verification criteria, including the absence of criteria; later runs cannot introduce or change them. Orca never automatically applies a fix or launches a rerun.

## Tool Contracts

### `list_directory`

Input:

- `path`: `res://` directory.

Output:

- Immediate child directories and files.
- Structured success or failure.

### `read_file`

Input:

- `filepath`: `res://` file.
- `start_line`: Optional one-based first line, default `1`.
- `end_line`: Optional one-based inclusive final line.

Limits:

- Maximum source file size: 2 MB.
- Maximum returned lines: 400.
- Maximum returned text: 128 KB.

Output includes actual range, total lines, truncation state, SHA-256, and navigation metadata.

### `search_files`

Input:

- `query`: Literal text.
- `path`: Search root, default `res://`.
- `file_glob`: Filename pattern, default `*`.
- `case_sensitive`: Default `false`.
- `max_results`: Clamped to 1-200.

Limits:

- Maximum matching files scanned: 500.
- Maximum individual file size: 1 MB.
- Maximum execution window: approximately 2.5 seconds.
- Binary files, `.godot`, Orca's directory, and symbolic links are skipped.

Output includes matches with path, one-based line, one-based column, preview, truncation state, and first-match navigation metadata.

### `inspect_scene`

Input:

- `scene_path`: Saved `res://` path ending in `.tscn`.
- `include_properties`: Optional boolean, default `true`.
- `max_nodes`: Optional requested node bound, clamped to 1-120.
- `max_properties_per_node`: Optional requested serialized-property bound, clamped to 0-24.

The tool loads a `PackedScene` with cache bypass, reads its public `SceneState`, and never calls `instantiate()`. It returns saved node paths, parent and owner paths, types, sibling indexes, up to 32 groups per node, child-scene references, instance placeholders, serialized exported or overridden properties, and up to 100 saved signal connections. It does not report all Inspector defaults, runtime-generated nodes, or recursively expanded child/inherited scenes.

Hard limits include a 2 MB source scene, 120 nodes, 24 properties per node, 500 properties overall, 100 connections, 16 connection binds, 16 collection entries per summarized Variant, four levels of Variant recursion, 256 characters per string value, and 128 KB of valid JSON output. Truncation removes complete records rather than cutting JSON and is reported with explicit reasons.

Optional saved-scene limits accept finite mathematical integers from either Godot integer values or JSON-decoded floats. Fractions, booleans, strings and non-finite values are rejected before inspection; valid numbers are clamped before conversion to prevent overflow on enormous integral inputs. This fixes valid model `max_nodes:120`/`60` calls failing because Godot parses JSON numbers as floats. The JSON schema's integer/clamp contract and path/dirty-state/resource restrictions remain authoritative.

Successful results include scene navigation metadata. Paths outside `res://`, symbolic links, Orca's own directory, missing files, non-`.tscn` targets, oversized scenes, malformed resources, and scenes with unsaved editor changes fail without navigation metadata.

### `inspect_editor_scene`

Input (all fields optional except `node_path` when scope is `subtree`):

- `scope`: `selection` (default; selected nodes only), `scene`, or `subtree`.
- `node_path`: Subtree root relative to the edited scene, e.g. `.` or `Menu/Panel`; absolute paths, `..`, unique-name lookup, property subnames, and empty segments are rejected. Accepted only for `subtree`.
- `scene_path`: Optional expected current project scene path; canonical matching is required. Omit for a new unnamed scene.
- `include_properties`: Boolean, default `true`; false omits native properties, layout context, and resource-property reads while retaining node/script identities.
- `max_nodes`: Integer 1–120, default `60`.
- `max_depth`: Integer 0–16, default `4`; descendant depth from the scope root, unused for selection-only scope.
- `max_properties_per_node`: Integer 0–32, default `32`.

Invalid types, ranges, unknown arguments, missing targets, mismatched scene identity, absent selection, non-editor acquisition, and non-main-thread acquisition fail visibly. The backend reads existing nodes only and never saves, instantiates, changes selection, or calls script-defined property/method hooks. Extension/editor-native classes and protected instance/script branches are excluded. References disclose only core resource type, storage kind, and allowed canonical project identity; external, symlinked, and Orca-owned references are redacted or rejected.

Integer limits follow JSON Schema integer semantics: Godot's JSON decoder represents numeric literals as floats, so finite whole numbers in range are accepted and normalized before use. Strings, booleans, fractional/non-finite values, and out-of-range limits remain rejected. Both wire-shaped component/editor tests and history round trips cover this boundary.

Hard bounds include 20 selected nodes, 240 scheduled/visited nodes, 64 ancestry steps, 512 total native properties, 32 group entries per node, 512-character paths, 256-character labels, and 64 KiB of whole JSON. A cooperative 50 ms deadline bounds traversal between native reads; synchronous engine APIs/path-policy calls cannot be interrupted. Node/depth/selection/property/reference/path/output/time omissions are disclosed as truncation. Child acquisition uses bounded indexed reads rather than materializing the full child array.

Output identifies live editor provenance, known unsaved state, scene identity when available, scope roots, selected paths, node hierarchy/ownership, allowlisted native values, and Control-parent context. Values retain native type names with JSON-safe numeric components. It does not expose a hash, represent runtime game state, enumerate custom exports/signals, expand resources, or compute custom effective minimum sizes. Existing saved inspection and approval/mutation requirements are unchanged. UI metadata contains only source/scope/count/dirty/truncation fields. Persisted activity retains bounded query controls and a historical summary, not node snapshots or actionable editor identities.

### `inspect_project_settings`

Input:

- `setting_path`: Optional exact ProjectSettings path. Omit it for the bounded overview; an explicit empty value is rejected.

The overview reports selected application values, main scene, display/window settings, input actions, autoloads, rendering settings, and physics settings. Explicit reads are limited to those low-risk families rather than allowing arbitrary custom settings. Sensitive-looking paths are rejected. Values use active Godot feature overrides and retain their Variant type in JSON-safe form.

Hard limits include 64 input actions, 12 events per action, 64 autoloads, 4,096 scanned property records, 16 entries per summarized collection, three levels of Variant recursion, 256 characters per string, and 64 KB of valid JSON output. Truncation preserves whole JSON and reports reasons.

The tool is read-only in Plan and Work, never enters approval, and can navigate to `project.godot`. Sessions persist only the optional setting path and navigation summary, never returned setting values. It does not enumerate arbitrary settings, inspect editor settings, or reveal disallowed custom configuration paths.

### Automatic Project Instructions

At the start of each turn, Orca checks only the project-root `res://AGENTS.md`. Missing instructions are optional and do not fail the request. Valid content is wrapped with its SHA-256 and explicit precedence language, appended to private request-scoped system context, retained through that turn's tool rounds, and removed before resumable history is stored.

Hard limits and rejection rules:

- Exact fixed path only; no ancestor or nested instruction discovery.
- Maximum 32 KiB and 400 lines.
- Valid UTF-8 text with no NUL bytes.
- Any symbolic-link component is rejected.
- Project guidance cannot authorize tool access, execution, mutation, disclosure, or weaker safety behavior.

### `read_project_skill`

Project skill discovery scans only immediate directories matching the lowercase slug grammar under `res://skills/`. Each valid entry must use `res://skills/<slug>/SKILL.md` with bounded YAML-like frontmatter containing one `name` and `description`. Automatic request context receives catalog metadata only: name, description, slug, and path. It does not receive skill bodies.

Input:

- `name`: Exact case-sensitive discovered name, 1-64 characters. Duplicate exact names fail rather than selecting one.

Hard limits:

- At most 64 immediate directories scanned and 32 skills returned, in deterministic slug order.
- Frontmatter must close within 8 KiB and 80 lines.
- Description maximum: 240 characters.
- Body maximum: 32 KiB and 400 lines; complete skill file maximum is 40 KiB.
- Invalid UTF-8, NUL bytes, invalid slugs/frontmatter, symbolic links, missing exact names, and ambiguous names are rejected.

The returned body is wrapped as subordinate, non-recursive, non-executable project guidance. References in a skill are plain text and do not cause automatic file reads or command execution. The tool is read-only in Plan and Work; only bounded target/navigation metadata persists, not the body.

### `inspect_godot_api`

Input:

- `class_name`: Required native `ClassDB` class or registered global class name, maximum 256 characters.
- `member_name`: Optional exact member name; omit for a class overview.
- `member_kind`: Optional `auto`, `method`, `property`, `signal`, `constant`, or `enum`; default `auto`.
- `include_inherited`: Optional boolean, default `true`.

The tool reports engine version, native hierarchy, reflected declaring class, method/signal signatures and arguments, property types/getters/setters, integer constants, enums, and registered global-class metadata. A global script class exposes its registration and native base metadata but does not claim unloaded script-declared members. Successful results include a validated `class_*` Help topic used by the activity card's Open Docs action and `EditorInterface.get_script_editor().goto_help()`.

Hard limits include 80 overview members, 16 exact matches, 16 hierarchy levels, 32 arguments per method/signal, 256 characters per string, and 64 KiB of whole JSON output. The tool uses reflection only: it does not construct objects, instantiate scenes, load project scripts, scrape `EditorHelp`, or return class-reference prose. It is read-only in Plan and Work.

### `read_gdscript_function`

Input:

- `filepath`: Canonical existing `res://` path ending in `.gd`.
- `function_name`: Valid GDScript identifier, maximum 128 characters.
- `start_line_hint`: Optional positive one-based line to resolve duplicate names.
- `include_documentation`: Optional boolean, default `true`, for adjacent `##` documentation and annotations.

The reader masks comments and string contents while locating declarations, multiline signatures, indentation boundaries, static functions, and nested class scope, then returns exact selected source with one-based navigation. Duplicate names fail with bounded candidate summaries unless the line hint selects one uniquely. This is focused lexical extraction, not semantic symbol resolution.

Saved source includes a disk SHA-256. If the exact script is open and unsaved, Orca instead reads its public `ScriptEditor` source, labels the result `source_kind: editor`, and deliberately omits `disk_sha256`; that content cannot authorize or seed a patch. Hard limits are 2 MiB source, 300 returned lines, 96 KiB returned text, and 20 candidate summaries. Canonical path, `.gd`, project boundary, symbolic-link, Orca-directory, UTF-8, and NUL checks apply. The tool is read-only in Plan and Work.

### `discover_dependencies`

Input:

- `filepath`: Canonical existing saved project resource.
- `direction`: Required `forward` or `reverse`.
- `max_depth`: Optional, clamped to 1-3; default `1`.
- `max_results`: Optional, clamped to 1-100; default `100`.

Forward traversal follows serialized `ResourceLoader.get_dependencies()` relationships breadth-first. Reverse traversal builds a bounded project index, then reports direct and transitive dependents in deterministic breadth-first order while preserving real source-to-dependency edge direction. UID descriptors are resolved when registered, with canonical `res://` fallbacks where available.

Hard limits include 3 traversal levels, 100 returned nodes, 200 graph edges, 500 scanned files, 256 scanned directories, 100 indexed graph nodes, 200 indexed serialized edges, approximately 2.5 seconds for reverse scanning, and 96 KiB of whole JSON output. `.godot`, symbolic links, Orca's addon, unsafe/unresolved dependencies, and missing/noncanonical targets are excluded or rejected with truncation reasons. The tool does not load or instantiate resources and cannot discover dynamic `load()` calls, arbitrary code references, runtime-created resources, or unsaved editor state. It is read-only in Plan and Work.

### `get_editor_context`

Output may include:

- Active scene name, path, and root type.
- Up to 20 selected nodes with type, scene-relative path, script, and groups.
- Active script path.
- One-based caret line and column.
- Source excerpt around the caret.
- Selected source text, capped at 12,000 characters.
- Selected FileSystem paths.
- Open and unsaved scenes.
- Unsaved scripts.

### `get_diagnostics`

Output includes:

- Bounded validation and editor-process error records.
- Error file and line when publicly available.
- Current play state and playing scene.
- Explicit note about unavailable private Output/debugger history.

### `update_tasks`

Input:

- `tasks`: Complete replacement list, limited to 20 items.
- Each item contains `content`, limited to 240 characters, and one of `pending`, `in_progress`, `completed`, `blocked`, or `cancelled`.
- At most one item may be `in_progress`.

The tool is available in Plan and Work, changes session metadata only, never enters the patch approval path, and returns the normalized list to the controller. An empty list clears the checklist.

### `request_work_mode`

Input:

- `reason`: One non-empty user-facing line, limited to 240 characters.

This controller-owned tool is exposed only in Plan when the selected provider has Agent tools available. It is appropriate only when the user asked for implementation, execution, or another operation requiring Work. The controller permits one valid request per user turn and waits for an exact call/turn-bound `Stay in Plan` or `Switch to Work` decision. Approval changes mode but does not approve any mutation. The original response remains Plan-bound, including calls after the request; Work tools appear only on the next provider continuation. Rejection, malformed arguments, stale decisions, duplicate decisions, and cancellation cannot grant Work permission. Only a bounded resolved summary persists.

### `apply_patch`

Input:

- `filepath`: Target `res://` file.
- `base_hash`: SHA-256 from `read_file`; empty only for a new file.
- `edits`: Non-overlapping one-based line edits.

Each edit contains:

- `start_line`.
- `end_line`.
- `replacement` exact text.

`end_line = start_line - 1` inserts before `start_line`. Appending after the final line uses `start_line = line_count + 1` and `end_line = line_count`.

Patch materialization preserves LF or CRLF boundaries and rejects malformed, overlapping, duplicate-position, or out-of-range edits.

### `propose_input_map_changes`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `changes`: 1-16 complete action operations.
- Each operation is `upsert` with a deadzone and up to 16 typed events, or `remove` with an action name.

Action names are limited to 64 ASCII letters, numbers, underscores, periods, or hyphens. Supported initial events are key, mouse button, joypad button, and joypad motion with strict fields, device ranges, Godot enum bounds, modifier types, direction values, and Unicode scalar validation. Duplicate actions and unknown fields are rejected.

Preparation parses `project.godot`, checks affected live ProjectSettings values against disk, and materializes only requested `input/<action>` entries. Unrelated bytes, comments, sections, and Input Map entries remain exact. The candidate is reparsed, requested values are verified, and old/new action summaries plus exact private bytes and hashes are retained. No-op proposals skip approval.

The structured card shows each add, update, or remove operation, old/new deadzone, event type, all key representations, modifiers, device, button, and axis details. Apply rechecks the disk hash, retained old/new hashes, affected live state, and candidate before verified replacement. It then synchronizes ProjectSettings and InputMap and verifies complete affected action values. Revert is hash-guarded and synchronizes the old values. Rollback failures preserve a status consistent with the bytes left on disk so recovery remains visible.

Only bounded kind/action summaries persist. Raw event payloads, proposal bytes, typed resources, pending approval, and revert state do not survive restart.

### `propose_main_scene_change`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `scene_path`: Existing saved `res://` path ending in `.tscn`.

The target must remain inside the project, contain no symbolic-link traversal, remain outside Orca's own addon, have no unsaved editor changes, stay within 2 MB, and load as a `PackedScene` without instantiation. The path and fixed `project.godot` target are revalidated immediately before apply or revert.

Existing `res://` and valid `uid://` main-scene values are resolved to canonical resource identity for live/disk comparison and no-op detection. New values prefer a registered UID that resolves back to the requested scene and otherwise use the canonical resource path. Broken previous values are shown explicitly as unresolved and remain restorable.

Only the `[application] run/main_scene` assignment is materialized. Valid UTF-8, LF/CRLF consistency, candidate parsing, retained hashes, scene validity, and live/disk state are checked before verified replacement. A dedicated card shows the previous and proposed canonical scene and provides project-file and scene navigation. Apply and revert synchronize ProjectSettings, classify independent conflicts, and expose `applied_recovery` or `reverted_recovery` when disk and live state require user attention.

Sessions persist only a bounded main-scene summary and status. Raw UID values, proposal hashes, exact project bytes, pending approval, and revert checkpoints remain private and in memory.

### `propose_project_settings_changes`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `changes`: Atomic batch of 1-6 objects containing exact `setting_path` and `value` fields.

The initial mutation allowlist is deliberately smaller than the read inspector:

- `display/window/size/viewport_width`: integer 1-7680.
- `display/window/size/viewport_height`: integer 1-4320.
- `display/window/size/window_width_override`: integer 0-7680.
- `display/window/size/window_height_override`: integer 0-4320.
- `display/window/stretch/mode`: `disabled`, `canvas_items`, or `viewport`.
- `display/window/stretch/aspect`: `ignore`, `keep`, `keep_width`, `keep_height`, or `expand`.

The numeric maxima are intentional Orca safety caps rather than Godot engine limits. Rendering backends, fullscreen mode, physics timing, project identity, plugins, autoloads, executable paths, feature overrides, export settings, and arbitrary custom paths remain excluded.

Absent disk entries resolve to documented Godot built-in defaults for no-op and live/disk comparison. Values require exact Variant types without coercion. Unknown fields, duplicate paths, invalid enums, and out-of-range values fail atomically.

Only requested `[display]` assignments are materialized, preserving unrelated valid UTF-8 bytes and comments. Apply and revert rederive the complete allowlisted old/new delta from hash-bound files, validate retained metadata, recheck the fixed target, synchronize concrete live ProjectSettings values, and classify conflicts or recovery states. The dedicated card shows typed previous and proposed values; sessions persist only bounded labels and status.

### `propose_scene_changes`

Input:

- `scene_path`: Canonical `res://` path ending in `.tscn`. A new scene's parent directory must already exist.
- `base_hash`: Empty for `create_scene`; exact `read_file` SHA-256 for every existing-scene operation.
- `operations`: Exactly one supported structured operation.

Supported operations:

- `create_scene`: Creates a new scene with an allowlisted `Node`, `Node2D`, `Node3D`, or `Control` root.
- `add_node`: Adds one allowlisted native node under a canonical local parent and assigns scene-root ownership.
- `set_property`: Sets one stored, writable property using an explicit typed wire value. Initial values are bool, int, finite float, bounded String/StringName, Vector2/Vector2i, Vector3/Vector3i, Color, and Rect2.
- `rename_node`: Renames a local leaf node, or the root, after duplicate-name checks.
- `remove_node`: Removes exactly one local non-root leaf.
- `reparent_node`: Moves exactly one local leaf to a different canonical local parent while preserving root ownership.
- `attach_script`: Attaches one exact hash-bound, dependency-free `.gd` script with a compatible native Node base after preliminary execution trust.
- `detach_script`: Detaches the exact hash-bound script from one node after preliminary execution trust.
- `instantiate_child_scene`: Adds one independently hash-bound dependency-free `.tscn` as a real child-scene instance.
- `connect_signal`: Adds one persistent bindless built-in signal-to-method connection with optional deferred and one-shot flags.
- `disconnect_signal`: Removes exactly one matching supported persistent bindless connection.

Names are bounded to 128 characters and reject control characters, reserved path names, surrounding whitespace, and characters Godot would silently replace. Structural operations reject scenes with saved connections or NodePath properties rather than guessing how references should be remapped. Signal operations are limited to local built-in endpoints with compatible signatures. Property collections, resources, NodePaths, callables, and arbitrary object values are excluded.

Preparation constructs native nodes through `ClassDB`, packs with `PackedScene.pack()`, serializes to bounded short-lived `user://orca/tmp/*.tscn` scratch storage, reloads with deep cache bypass, and verifies the complete result through `SceneState`. Existing-scene operations are restricted to at most 60 local nodes, 240 serialized properties, and 100 connections. Before loading, the parent scene rejects all external dependencies and built-in subresources; after loading, it also rejects inheritance, unreviewed child instances or scripts, non-core node types, serialized object values, open editor scenes, and any candidate that changes unrelated semantic records. `instantiate_child_scene` permits exactly its reviewed child dependency after separately validating and hash-binding a dependency-free child scene. Script operations initially permit exactly one reviewed attachment, no other scripts or scene dependencies, and a dependency-free `.gd` with a compatible native Node base. Scratch names include process, time, and random components, normal cleanup is synchronous, and stale known scratch files are scavenged during plugin startup and later scene operations.

Script attach/detach uses two decisions inside one protocol tool call. The first card validates only canonical paths, saved bytes, unsaved/open state, and exact scene/script hashes without loading the scene or compiling the script. Its explicit Trust and Prepare action authorizes compilation, loading, initialization, candidate construction, and later revalidation after immediate hash checks; it does not write the scene. Orca then validates GDScript and dependencies, checks native-base compatibility, constructs an immutable candidate, and reuses the card for normal Apply/Reject. Rejection or cancellation at either stage completes the original tool call exactly once and releases retained private state.

Apply repeats path, dependency, existence, open/unsaved state, operation, hash, pack/save/load, and complete candidate validation before verified replacement. Failed final validation restores the original bytes only while the target still matches the reviewed candidate. Revert rejects open, unsaved, or independently changed parent scenes; it removes a newly created file or restores exact retained bytes for an existing scene. Child dependency drift blocks Apply but does not block restoring exact pre-instance parent bytes. The dedicated structured card receives only bounded operation-specific summaries; candidate/script bytes, trust bindings, dependency hashes, authoritative operations, pending approval, and revert checkpoints are not persisted.

Godot has no public way to construct and pack script candidates without potentially executing `_init`, member/static initialization, or `@tool` behavior. The preliminary trust review makes that execution explicit and binds it to exact scene/script hashes, but it is informed consent rather than sandboxing. Candidate construction remains synchronous on the editor thread and cannot be interrupted until Godot returns control.

### `run_current_scene`, `run_main_scene`, And `stop_game`

All three tools are exposed only in Work mode. The run tools accept only an optional bounded verification object; `stop_game` accepts an empty object. `run_current_scene` resolves the active editor scene and requires it to be saved. `run_main_scene` resolves the active feature-overridden `application/run/main_scene`. Both require a canonical existing `.tscn` outside Orca's addon, reject symbolic links, reject all known unsaved scripts and scenes, reject concurrent editor play or an existing Orca run, and launch the current Godot executable without a shell.

Launch returns immediately after process creation and the controller performs one bounded automatic observation. Later `observe_game_run` calls are for new run-specific evidence, while `get_diagnostics` is for editor or runtime errors rather than routine polling. `stop_game` stops only the in-memory direct PID retained by the current plugin instance; it never accepts a PID and cannot stop an editor-started game. A successful launch means only that the process started, not that the game passed validation or ran correctly.

Run calls may include one optional bounded `verification` object. Initial kinds are `clean_startup`, with a 250-10,000 ms minimum runtime, and `expected_exit`, with an exact exit code. Both may declare up to five required stdout markers, five forbidden stdout/stderr markers, and whether diagnostic-shaped runtime errors are forbidden. Claims are limited to 240 characters and markers to 200 characters. Matching is literal and criteria never become process arguments.

### `observe_game_run` And `verify_game_run`

`observe_game_run` accepts an exact positive `run_id` and optional prior snapshot sequence. It never waits or changes process state. It returns current bounded evidence, whether the snapshot advanced, and one recommended next action. Repeated observations with only elapsed-time or cursor changes are treated as the same loop state. Stale or unknown run IDs fail rather than reading a newer run accidentally.

`verify_game_run` accepts one exact run ID and evaluates only criteria fixed before launch. Results are `passed`, `failed`, `pending`, `inconclusive`, or `unverified`, with per-check evidence. Truncated evidence makes absence-based checks inconclusive. A nonzero exit cannot pass clean-startup verification, and stopped/timed-out processes cannot pass expected-exit verification. A pass is explicitly scoped to startup or process-exit criteria and is never general visual/gameplay proof.

## Security And Privacy

- API credentials are stored in Godot `EditorSettings`. This is persistence, not an encrypted OS credential store.
- Session transcripts are stored as plaintext JSON under project-keyed `user://` storage. They can contain user prompts, assistant text, and task descriptions, including source text quoted in those fields.
- Session records exclude API keys, automatic editor-context snapshots, hidden reasoning, patch contents, complete tool output, and durable revert data.
- The configured API endpoint receives the API key using the selected adapter's authentication headers. Current chat adapters use bearer tokens.
- Authenticated provider model-discovery endpoints receive that provider's API key; Gemini discovery uses Google's `x-goog-api-key` header.
- Orca requests public model metadata from `models.dev` without sending the API key, prompts, file contents, or project context.
- Project context and file contents may be sent to the configured model provider.
- When present, root `res://AGENTS.md` content and bounded project-skill catalog metadata are automatically sent to the configured provider with each turn. A skill body is sent only after an explicit `read_project_skill` call. These values remain private request context/tool results and are not persisted in resumable session continuation or raw activity output.
- Project instructions and skills are untrusted input. Wrapping and prompt precedence are defense in depth; runtime mode, approval, path, execution, and disclosure checks remain the security boundary.
- Unsaved editor source returned by `read_gdscript_function` has no disk hash and cannot be used as an `apply_patch` base. It may still be sent to the selected provider as tool output.
- `inspect_godot_api` uses reflection and safe Help topics rather than prose scraping or object construction. `discover_dependencies` reads serialized dependency metadata without loading resources, but its reverse scan still enumerates bounded project resource paths on the editor thread.
- Editable LAN and remote endpoints require explicit exact-origin confirmation before credentials or project context can be sent. Orca does not maintain a general host allowlist, pin DNS answers or certificates, or control whether a confirmed server proxies data elsewhere.
- GDScript `reload()` is a compiler/loader validation mechanism, not a sandbox. Trusted generated source may reach tool-script static initialization.
- `PackedScene` loading for inspection is read-only and does not instantiate nodes, but referenced resources and scripts may still be loaded by Godot; dependency loading is not a sandbox or independently size-bounded.
- Existing-scene structured mutation requires `PackedScene.instantiate()` after rejecting unreviewed dependencies, subresources, scripts, inheritance, non-core nodes, object properties, and unsupported size. This is deliberately narrower than read-only inspection and is not a general scene sandbox. Script attach/detach requires explicit preliminary trust because candidate construction can execute exact reviewed project code; that execution is not sandboxed.
- Godot exposes no locked resource-load API. Child-scene preparation rechecks exact bytes and dependencies immediately before canonical load and compares the loaded state with the validated scratch state, but a hostile external process could still replace the dependency within that final read/load interval.
- The same no-lock limitation applies to trusted script loading. Orca rechecks the script hash before and after canonical loads and refuses to write on drift, but a hostile external process could replace script bytes in the interval and cause unreviewed code to execute before the post-load mismatch is detected. Preliminary trust is informed consent, not a sandbox against hostile local races.
- Temporary replacement and in-memory revert state reduce accidental data loss but are not durable version control.
- `OS.kill()` addresses only Orca's direct Godot child, not subprocesses that project code may spawn. Godot exposes no cross-platform process-tree/job ownership API in GDScript.
- On Unix-like platforms Godot's forceful `OS.kill()` implementation may wait for the direct child to exit. Launch and capture are nonblocking, but a pathological child stuck in uninterruptible kernel I/O could delay Stop, timeout handling, or plugin teardown.

Do not describe the current credential storage or execution model as fully secure.

## UI Conventions

- Preserve Godot's editor visual language and scaling.
- Use `ui_metrics.gd` for plugin-authored pixel dimensions. Values obtained from the editor theme, including fonts and `EditorIcons`, are already scaled and must not be multiplied again.
- Recompute scaled dimensions from immutable base values; never multiply a control's current dimensions during repeated notifications.
- Keep incomplete streamed text lightweight and literal; create rich code controls only after a response or tool preface is complete.
- Prompt text derives from the editor theme rather than a fixed physical size.
- The composer uses the editor accent color for focus, derives its height from visible line metrics, and keeps its action rail usable at the 300 px-equivalent minimum dock width.
- Use orange for Plan assistant headings and green for Work headings.
- Mode choices pair those accents with explicit capability descriptions; color is not the only indicator.
- Keep custom dock menus inside the dock's `Control` tree so positioning and sizing use the same editor-scaled coordinate system.
- Use compact collapsed activity cards by default.
- Derive read-only activity groups from consecutive flat tool events so persisted sessions remain compatible and independently bounded.
- Close groups at every visible message, change, mutation, unknown-tool, request-completion, and session boundary.
- Keep one transient mode-colored working indicator visible while a provider request has not produced text or tool activity. Transport headers alone are not visible progress and must not replace it with an empty assistant card.
- Keep active-turn scrolling attached to the latest activity across delayed container and rich-text layout. A single deferred scrollbar assignment is insufficient for controls whose final height is calculated later.
- Use unified diffs in the narrow dock and side-by-side views when expanded.
- Keep dangerous actions explicit and label their final state.
- Mode, request, tool, and approval state must agree visually with controller state.

## Testing

### Current Automated State

A committed automated suite exists under `tests/`:

- `api_client_test.gd` verifies media-type recognition, fragmented SSE reconstruction, clean-EOF event flushing, bounded opaque tool-call metadata, provider-scoped finish-reason compatibility, structured failure metadata, raw-buffer behavior, tool-call validation, terminal ownership, and lifecycle signal IDs.
- `provider_test.gd` verifies hosted/local registration, native Ollama/LM Studio discovery URLs and filtering, generic embedding-name fallback, loaded context selection, required/optional authentication, bounded model normalization, reasoning options, pricing conversion, endpoint-aware cache identities, public metadata mapping, and leading-system normalization with source-history isolation, multimodal/opaque tool preservation, stable ordering, idempotence, and conservative budget coverage.
- `context_budget_test.gd` verifies unknown-limit behavior, conservative reserves, complete-turn removal, historical and active tool-group integrity, repeated compaction, malformed protocol refusal, oversized protected-turn failure, and the budget range where tools do not fit but no-tools finalization does.
- `image_attachments_test.gd` verifies bounded normalization, source headers, record integrity, exact model capability, base64-free image reserves, retained tool-follow-up images, deduplicated persistence/deletion, missing-image view-only restoration, and floating previews/draft recovery.
- `image_model_switch_test.gd` verifies immutable/idempotent historical projection, current-image protection, truthful placeholders, projected budgeting and canonical compaction, supported/unsupported/unknown model transitions, turn-bound policy through tools, malformed/corrupt record denial, persistence/restoration, failure/cancellation, draft preservation, and non-blocking narrow-composer feedback.
- `script_references_test.gd` verifies confined saved-source preparation, UTF-8 truncation/NUL/count/type limits, strict snapshot records, canonical history/projection/compaction, Chat-only and Responses/multimodal payloads, actual read-tool continuation, persistence/invalid restoration, real Control drop routing, duplicate/atomic intake, narrow chips, per-message restoration, and preflight/provider draft recovery. Real editor dirty-state tests verify active source and script-list identity with no disk mutation, plus inactive dirty denial. Editor-scale tests verify chips above images/checklists and Tab preservation. The two-request multimodal SSE fixture requires exact script source on initial and matching tool-result requests.
- `image_intake_test.gd` verifies image and normal text Paste/undo, rejected intake before reads, native context-menu Paste, forced Control image/text drag routing, atomic intake, cue cleanup, and attachment-window ownership/session/close/lifecycle guards.
- `image_attachments_integration_test.gd` validates standard inline image_url payloads over actual localhost SSE transport and retains images across a matching assistant-call/tool-result continuation.
- The same image integration now uses ten requests: the original two-request image round plus eight stateful text/vision switches, checking exact prior descriptions, pixel-free text requests, unchanged original image bytes after switching back, and matching tool continuations. Unsupported current drafts remain locally rejected and the private policy is never sent to the provider.
- `native_image_drop_test.py` drives real X11 XDND transfer into the fixture-only `image_attachment_window_editor_test.gd`, verifies native-window isolation while the real editor import listener exists, and checks zero non-generated project-file changes for accepted/rejected drops. This requires X11 and python-xlib and is not part of headless CI.
- `api_client_integration_test.gd` uses `http_test_server.py` on `127.0.0.1` to verify successful SSE, keyless local chat without an Authorization header, exact Gemini, DeepSeek, xAI, and OpenRouter assistant-call/tool-result continuations, fragmented thought-signature, reasoning-content, and indexed reasoning-detail reconstruction, provider-specific history sanitation, mid-stream disconnect metadata, aggregate response limits, buffer cleanup, and unexpected content types.
- `provider_model_service_integration_test.gd` verifies keyless native Ollama/LM Studio discovery, embedding exclusion, loaded context, absent Authorization headers, redirect rejection, stale-request ownership, and cached-record sanitation against localhost fixtures.
- `agent_compatibility_probe_integration_test.gd` verifies the complete isolated two-request function-call and matching tool-result continuation through real local HTTP/SSE transport, requiring one leading system message and retained fixed synthetic refresh context on the second request.
- `local_provider_integration_test.gd` verifies the reported strict-template HTTP 500 with an unnormalized negative control, then five-request initial/second-turn/read-tool/continuation/no-tools-finalization sequences for all three local profiles. The fixture checks exact context and conversation/tool payloads and absent keyless Authorization. It loads no model and executes no project tool.
- `patch_utils_test.gd` verifies replacement, insertion, deletion, append, empty-file creation, multiple edits, overlap rejection, and LF/CRLF preservation.
- `tools_test.gd` verifies Plan/Work tool-schema separation, direct-mutation denial, project and plugin path boundaries, symbolic-link rejection, immutable proposals, base hashes, stale application and revert guards, safe application, and new/existing-file revert behavior.
- `agent_controller_test.gd` verifies Plan/Work schema and runtime enforcement, request-scoped project guidance and refreshed checklist context, exact compatibility-bound local Agent gating, mode locking, explicit approval and rejection, cancellation while awaiting approval, turn/provider ownership, stale and duplicate terminal rejection, synchronous workflow cancellation, terminal reentry, tool-loop and context-pressure finalization, task-aware local checkpoints, the complete inspect/fix/run/fail/stop/fix/rerun/pass workflow, applied-change non-replay, unsafe-protocol refusal, and matching protocol-valid tool results.
- `agent_compatibility_probe_test.gd` verifies the isolated synthetic two-step tool-call protocol, fixed refreshed system context, prior-version binding denial, distinct owned request IDs, stale callback rejection, exact challenge/call-ID continuation, opaque metadata preservation, strict acknowledgement, disabled request fallback, failure, timeout, and cancellation. Controller tests separately deny old-version tool execution before side effects.
- `session_store_test.gd` verifies project isolation, recovery-checkpoint persistence, schema redaction, backup recovery, retention, truncation, deletion cleanup, and controller state restoration.
- `history_view_test.gd` verifies that the History page remains within the 300 px minimum dock width.
- `settings_view_test.gd` verifies icon-based Provider/System/About switching, English-only language presentation, static resource-link destinations, local-profile presentation, explicit keyless discovery, endpoint-change cleanup, compatibility controls/default denial, version metadata, branding, compatibility, license presentation, and the 300 px dock-width constraint.
- `chat_window_test.gd` verifies editor-scale conversion math, the animated empty-state logo resource, compact line-based composer sizing, narrow action containment, working-state animation, first-token transitions, turn-scoped stale event rejection, delayed-layout auto-follow, sequential review navigation, fenced-code parsing, BBCode isolation, exact code preservation, expanded previous/proposed diff content, safe line highlighting, exclusive-window release before Apply/Reject callbacks, bounded code-block layout, streaming-to-final transitions, tool-preface handling, recoverable/unsafe interruption composer state, restoration rules, structured review cards, and the 300 px dock-width constraint.
- `response_attribution_test.gd` verifies the exact model/mode metadata allowlist, full bounded identifier preservation, malformed-record denial, and JSON mode round trips. Controller tests verify terminal reentry, stale callbacks, settings changes, Plan-to-Work refresh, and non-attribution of local reports. Chat/session tests verify plain/code/footer parity, replacement without duplicates, interrupted provenance, restoration, and legacy omission. The real editor-scale suite verifies model/mode containment, non-overlap, complete tooltips, and bounded wrapping at normal, 1.5×, and 2× metadata fonts.
- `editor_ui_scale_test.gd` runs in editor mode and verifies that dock margins, branding, composer controls, and prompt sizing use Godot's effective editor scale without double-scaling theme fonts. It also verifies unchanged conversation/composer geometry for floating image overlays, matching image/Send artwork, disabled states, and About-link containment/non-overlap at normal, 1.5×, and 2× font sizes.
- The same real-editor suite dispatches Tab through the focused TextEdit to verify mode round trips, draft/caret/selection/image preservation, session saving, repeat suppression, modified/outside/hidden input, active-response/view-only locks, and controller approval denial. Its session store is memory-only and the shortcut fixture makes no provider request.
- Expanded-review coverage in that suite includes long/unequal/empty files, preserved exact read-only content and red/green highlights, synchronized scrolling, responsive stacked layouts, bounded minimap widths, extreme splitter limits, and larger code fonts. Running the same suite on a real display additionally exercises native minimap click/drag in both panes using Window pointer coordinates; headless mode verifies layout/programmatic scrolling without claiming native pointer coverage. Godot 4.7.2 Linux/X11/OpenGL passed at 2× editor scale, and a synthetic GDScript review was rendered and visually inspected. Other platforms and light-theme acceptance remain manual checks.
- `logo_asset_test.gd` verifies that the Orca mark has no opaque white tile and retains transparent corners after import.
- `tool_activity_group_test.gd` verifies aggregate status and duration, expansion, append closure, forwarded navigation, and the 300 px width constraint.
- `task_list_panel_test.gd` verifies status presentation, bounded height, collapse/expand behavior, clearing, and the 300 px width constraint.
- `scene_inspector_test.gd` verifies saved hierarchy, serialized properties, groups, instances, signal connections, JSON-safe Variant summaries, structural-only reads, bounds, invalid targets, and navigation metadata.
- `editor_scene_inspector_test.gd` verifies live native layout/transforms, selection/subtree behavior, unnamed roots, callback/getter isolation, strict arguments, canonical/expected scene identity, path/symlink/instance/resource/internal-node boundaries, and selection/depth/node/property/output/time limits.
- `editor_scene_inspector_editor_test.gd` verifies actual unsaved node/layout/2D/3D changes, public selection, Container context, getter isolation, unchanged project bytes/editor state, stale-scene rejection, and a canonical menu inspect/save/hash-bound review/Apply/reinspect/exact-Revert workflow. The harness settles deferred editor work between scene switches/closing and disables fixture-save thumbnail previews before cleanup. Early rapid-switch/teardown attempts crashed; settled runs pass with the existing headless RID/ObjectDB shutdown diagnostics. Headless Node3D data is inspected through subtree scope rather than opening the dummy renderer's 3D workspace.
- `project_settings_inspector_test.gd` verifies bounded overviews, explicit typed values, feature overrides, input actions, output limits, allowlists, privacy rejections, and navigation metadata.
- `project_instructions_test.gd` verifies optional root loading, exact content/hash metadata, safety wrapping, byte/line/NUL bounds, and symlink rejection.
- `project_skills_test.gd` verifies deterministic immediate-directory metadata discovery, exact-name body loading, frontmatter/slug/body bounds, non-recursive safety wrapping, truncation, and symlink rejection.
- `godot_api_inspector_test.gd` verifies reflected class/member kinds, inheritance, signatures, global-class metadata, limits, Help-topic formats, failures, and absence of construction or private Help scraping.
- `gdscript_function_reader_test.gd` verifies saved and unsaved source provenance, documentation and annotation inclusion, multiline signatures, nested classes, ambiguity hints, CRLF preservation, output bounds, path protection, and absent hashes for editor source.
- `dependency_inspector_test.gd` verifies deterministic forward/reverse breadth-first serialized graphs, depths, UID fallback normalization, scan/result/output bounds, and invalid/protected targets.
- `tool_loop_guard_test.gd` verifies identical successful and failed calls, alternating cycles, repeated rounds, changing results, progress resets, no-progress thresholds, and stable canonical fingerprints.
- `input_map_proposal_test.gd` verifies typed event validation, exact unrelated-byte preservation, no-op and stale guards, immutable reviewed hashes, affected live/disk consistency, application, synchronization, and guarded revert.
- `main_scene_proposal_test.gd` verifies path and PackedScene validation, path/UID semantics, exact unrelated-content preservation, no-op and stale guards, private hash binding, live synchronization, application, and guarded revert.
- `project_settings_proposal_test.gd` verifies the exact allowlist, strict types/ranges/enums, built-in defaults, atomic batches, exact preservation, complete-delta integrity, stale/live conflicts, synchronization, application, and guarded revert.
- `scene_proposal_test.gd` verifies typed-root creation; add, property, rename, remove, reparent, script, child-instance, and signal operations; non-executing script trust preparation; strict paths/types/dependencies; semantic preservation; scratch cleanup; stale targets; exact-byte restoration; conflicts; and guarded revert.
- `game_process_service_test.gd` verifies fixed launch arguments, one-process ownership, direct-PID stop, natural exit codes, timeout and kill-failure states, shutdown failure honesty, separate stdout/stderr bounds, safe diagnostic navigation, launch failure, and real nonblocking Godot pipe integration.
- The same suite verifies monotonic run identity/sequence, strict criteria normalization, clean-startup and expected-exit verdicts, nonzero-exit failure, truncation-driven inconclusive results, stale run rejection, and genuine multiline Godot diagnostic locations.
- `diagnostics_service_test.gd` verifies validation contracts, warning/error normalization, stderr filtering, bounded oldest-to-newest retention of the latest records, field sanitation, monotonic sequences, and deep-copy report isolation.
- `support_diagnostic_report_test.gd` verifies exact report key allowlists, closed-enum normalization, deterministic valid JSON, coarse endpoint classification, and adversarial exclusion of credentials, endpoints, project/session content, model output, tool payloads, reasoning, logs, proposal bytes, and hashes.
- `mode_switch_card_test.gd` verifies explicit decisions, single emission, resolved non-actionable state, and the 300 px dock-width constraint. Controller and chat suites cover Plan-only disclosure, same-turn continuation, rejection, Stop, stale/mismatched decisions, singleton-batch enforcement, protocol ordering, and reason redaction.
- `editor_unsaved_state_test.gd` uses public editor APIs to dirty real script and scene buffers and verifies exact current-editor source provenance, absent disk hashes, patch/apply/revert rejection, stale scene-inspection and structured-proposal rejection, and run blocking.
- `diagnostics_editor_integration_test.gd` verifies real editor logger capture and proves that simultaneous diagnostics service instances share one logger without duplicate records.
- `plugin_lifecycle_test.gd` verifies actual enable, disable, and re-enable behavior, single toolbar/dock/service ownership, dependency injection identity, and dock registration.
- `provider_settings_editor_test.gd` verifies isolated editable endpoints, models, optional credentials, reasoning settings, compatibility-pass persistence, explicit one-click test/enable intent, manual opt-out, stale/duplicate/cancelled outcomes, origin confirmation, and binding invalidation through real EditorSettings.

Run instructions are in `tests/README.md`. `.github/workflows/tests.yml` runs the permanent suites, editor-scale and editor-state integration, localhost transport integration, replacement-artifact checks, and headless plugin initialization on Godot 4.7.2. Authenticated provider-setting interactions still require deeper permanent coverage. Visual dock placement, focus, and theme checks remain manual.

### Required Headless Check

```bash
"$GODOT_BIN" --headless --editor --path . --quit
```

Expected result: project scan, plugin initialization, and editor layout complete without script or initialization errors.

### Manual Smoke Matrix

| Area | Scenarios |
| --- | --- |
| Streaming | Normal response, delayed first token, header-only working state, late card growth, active-turn bottom following, UTF-8 text, tool follow-up preparation, Stop, follow-up after Stop, HTTP failure. |
| Response attribution | Full model ID + response mode only; model switches, Plan-to-Work preface/final modes, interrupted text, no local/legacy guess, restored labels, long IDs, plain/code spacing, narrow widths and editor fonts. |
| Usage | Usage-only SSE event, cached tokens, multi-round totals, provider cost, catalog fallback, unavailable usage. |
| Metadata | Fresh/stale cache, offline fallback, unknown provider/model, response-size limit. |
| Providers | Legacy migration, per-provider credentials, switching, custom endpoint preservation, Gemini/xAI model discovery, discovery errors. |
| UI scaling | 100%, 125%, 150%, and 200% editor scale after restart; 300 px-equivalent narrow dock; 1280x720 short display; dark and light themes. |
| Reasoning | Capability-driven effort, provider body mapping, DeepSeek/xAI content continuity, OpenRouter detail reconstruction, Gemini thought signatures, and bounds. |
| Modes | Plan read-only, Work patch access, Plan-to-Work switch, focused-composer Tab round trip and draft/focus preservation, repeat/modified/outside input, mode locked while busy or awaiting approval; intelligence tools available read-only in both modes. |
| Project guidance | Missing/valid/oversized/symlinked root instructions; bounded skill catalog; exact skill selection; request cleanup; no automatic body loading. |
| Godot intelligence | Class/member reflection and Open Docs; saved/unsaved focused functions; forward/reverse saved dependencies; truncation and protected paths. |
| Tool-loop guard | Identical calls/results, alternating cycles, repeated rounds, no-progress rounds, one no-tools final request, denial of further calls, hard-cap fallback. |
| Reads | Valid range, default range, invalid range, empty file, oversized file, binary file. |
| Search | Match, no match, glob, case sensitivity, result limit, timeout, skipped plugin path. |
| Scene inspection | Saved hierarchy, properties on/off, node/property truncation, child instances, signal connections, malformed/missing/oversized targets, unsaved scene rejection. |
| Live scene inspection | Selected node(s), current hierarchy/subtree, unnamed scenes, unsaved additions/layout/transforms, Control/Container parents, callback isolation, strict paths and scene-switch rejection, truncation, historical activity restoration, narrow dock. |
| Project settings | Overview, explicit allowlisted path, feature override, input actions, autoloads, sensitive/custom path rejection, output truncation. |
| Input Map proposals | Add/update/remove, typed events, no-op, stale hash, affected live/disk mismatch, approval, rejection, cancellation, apply, synchronization, revert, Plan denial. |
| Main scene proposals | Valid/invalid scene, UID/path equivalence, no-op, stale hash, live/disk mismatch, approval, apply, synchronization, revert, conflict, Plan denial. |
| ProjectSettings proposals | Every allowlisted type/range, defaults, duplicates, atomic width/height, no-op, stale hash, live mismatch, metadata tampering, approval, apply, synchronization, revert, Plan denial. |
| Scene proposals | Every exposed operation, typed values, root/nested paths, ownership, stale parent/dependency hashes, restricted dependency/script rejection, approval, apply, exact-byte revert, conflict, Plan denial. |
| Context | No scene, active scene, selected nodes, active script, selection, unsaved script/scene. |
| Script references | Drag from FileSystem/open-script list, duplicate/count/unsupported rejection, removable/openable chips, source refreshed at Send, active/inactive unsaved buffers, text-only/Chat-only/Responses/mixed images, tool continuation, restored message references, failed/cancelled turns and newer drafts, narrow layouts. |
| Patches | Replacement, insertion, deletion, append, new file, LF, CRLF, overlapping edits. |
| Approval | Apply, Reject, Stop while waiting, multiple sequential tool calls. |
| History | Restart restore, switch, continue, delete, Delete All, retention, interrupted view-only, narrow layout. |
| Conflicts | Changed hash, changed existence, unsaved editor file, symlink path. |
| Validation | Valid GDScript, parse error, revalidation failure before write. |
| Revert | Existing file, newly created file, independently modified file, retry after failure. |
| Navigation | Script line/column, scene, resource, first search result, missing path. |

### Test Hygiene

- Put temporary runners outside the repository, such as `/tmp/opencode/`.
- Remove every temporary runner after verification.
- Remove test project files even when assertions fail.
- Check for `.orca_tmp_*`, `.orca_backup_*`, and test files before completion.
- Do not send live provider requests during tests unless explicitly authorized because they may expose code or incur cost.

## Known Limitations

### Agent And Context

- Resumable persisted history contains user and visible assistant messages rather than historical tool-call protocol details. Complete failed tool turns may be replaced by sanitized recovery checkpoints; unsafe or crash-interrupted turns remain view-only.
- Context budgeting uses a conservative byte-based estimate rather than a provider tokenizer. Unknown custom-model limits cannot be enforced automatically, and compaction omits old complete turns rather than generating a potentially lossy model summary.
- Pending approval state is not persisted; task checklists are persisted independently.
- Saved `.tscn` inspection reports serialized scene state, not all Inspector defaults, unsaved live-tree changes, runtime-generated nodes, or recursively expanded inherited/instanced scenes.
- Live scene inspection covers existing editor nodes and a fixed native property allowlist, not all Inspector values, custom script exports/getters, extension-native classes, signal state, runtime-generated game nodes, or effective minimum sizes. Deferred Container layout may still be settling. Detailed snapshots are requested on demand, not continuously refreshed. Unnamed roots have component coverage; actual New Scene UI, interactive provider/dock acceptance, non-headless 3D selection, and other platforms remain manual gates.
- Search is literal text search rather than a symbol or semantic index.
- Explicit references currently accept standalone project `.gd` scripts only, at most four / 300 lines / 16 KiB each. Only the exact active unsaved editor source is available; inactive dirty scripts require activation or saving. History retains submitted snapshots rather than silently rereading current files. Actual native script-list mouse dragging and live model acceptance remain manual checks.
- Root project instructions are limited to one fixed `res://AGENTS.md`; nested or ancestor instruction inheritance is not implemented.
- Skills use a deliberately small frontmatter format, immediate directories only, exact-name loading, and no recursive reference resolution. Skill bodies are not automatically selected or summarized.
- `inspect_godot_api` exposes reflected signatures and safe editor Help navigation, not class-reference prose, examples, tutorials, annotations/default argument values unavailable from `ClassDB`, or script-declared members from unloaded global classes.
- `read_gdscript_function` is an indentation-aware lexical extractor, not a parser, semantic index, call hierarchy, or reference search. Only the exact open unsaved script can use editor source.
- Dependency discovery reports only saved serialized references known to `ResourceLoader`; dynamic `load()` calls, arbitrary code references, runtime objects, unsaved state, and complete project-wide graphs beyond hard bounds are unavailable.
- Progressive tool-schema disclosure is deferred. Orca still sends the full mode-eligible schema on each request, so Godot Intelligence adds schema cost despite bounded outputs.
- Structured ProjectSettings reads intentionally cover selected low-risk families rather than arbitrary custom settings or EditorSettings.

### Editing

- Patches are line-range operations, not a full unified-diff parser.
- Raw file patches receive semantic validation only for GDScript; structured scene and configuration tools provide their own typed semantic validation.
- Structured scene operations use deliberately narrow first contracts: structural changes are leaf-only, values exclude references/resources/collections, scripts and child scenes must be dependency-free, script operations permit exactly one reviewed attachment, and signals are bindless and built-in.
- Revert checkpoints are in memory and do not survive editor restart.
- Public Godot APIs expose no Project Settings dirty flag; Input Map proposals enforce affected-action live/disk equality but cannot identify unrelated pending Project Settings UI edits as dirty.
- Multi-file changes are approved one file at a time rather than as a transaction.

### Diagnostics And Execution

- Historical Output dock contents are unavailable through public GDScript APIs.
- Built-in game-process debugger output is not comprehensively captured.
- Orca performs one bounded automatic observation after each run, can objectively evaluate narrow predeclared startup/exit criteria, and can use the normal reviewed edit loop for fixes and explicit reruns. It does not autonomously apply fixes or rerun without another model tool decision.
- Captured runtime diagnostics are conservative stdout/stderr parsing, not full debugger state.

### UI And Sessions

- Prompt enhancement remains a visual placeholder. Image attachments support a separate native drop/Browse window, clipboard pixel Paste, and internal project-file drops. Linux/X11 native attachment drops have permanent acceptance coverage; other native platforms and OS clipboard need platform checks. Document attachments and automated screenshot observation remain deferred. Desktop drops on the main editor Window still invoke Godot import, so use Orca's attachment Window instead.
- Conversations cannot yet be renamed or exported.
- History is keyed by the canonical project path, so moving the project does not automatically migrate its saved sessions.
- Session history is plaintext local data and has no configurable retention count beyond the built-in limit of 50.
- Search cards open the first match rather than presenting an interactive action for every match.

### Providers And Distribution

- First-class OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, and Local OpenAI-compatible profiles use the shared Chat Completions transport. Local profiles support optional authentication, editable endpoints, explicit keyless model discovery, manual model fallback, and endpoint-aware discovery caches.
- Custom OpenAI-compatible endpoints remain available, but their model capabilities cannot always be discovered.
- Native Anthropic Messages and Gemini `generateContent` adapters are absent. Foundry supports stateless Responses; the other hosted providers still use Chat Completions. Responses phase/opaque reasoning records are active-turn-only and not restored from session history. Azure model discovery and live deployment acceptance remain outstanding.
- Gemini's OpenAI-compatibility surface is beta, and Gemini/xAI have not been exercised against live credentials in the permanent automated suite.
- GitHub issue #2 reports LM Studio 0.4.26 / llama.cpp 2.60.0 rejecting later system messages with a Qwen-labeled 27B IQ2_S model. A user-run Qwen3-4B-Instruct-2507 chat test did not reproduce the error, and that model's Agent probe failed exact challenge arguments. The leading-system fix is verified against a deterministic strict-template transport fixture; the reporter's exact GGUF/template and live Agent continuation remain an acceptance gate.
- Editable profiles and fixed-provider origin overrides start Chat-only. Tools are exposed and runtime-permitted only when the request-scoped profile contains a persisted compatibility pass and explicit enablement matching the exact provider, origin, base/chat endpoint, case-sensitive model, reasoning effort, API mode, continuation style, and probe version. The disclosed Test & Enable action supplies enablement intent before the check and enables only after a matching pass; restoring a disabled pass does not enable it.
- BYOK provider credentials remain in EditorSettings. Managed Orca account refresh/session records use the OS vault; access tokens stay in memory. Earlier native build/acceptance jobs passed on all four platforms; complete 1.4.1 CI and real downloaded-package acceptance remain pending.
- Cost is an estimate unless directly reported by the provider. Catalog prices may become stale, provider markups may differ, and unknown custom models may show unavailable cost or context limits.
- Plugin metadata declares version 1.4.1 for the prepared packaging-fix release candidate. Public release documentation, an MIT license, add-on-only Git export rules and a manually dispatched release-packaging/publication workflow are present. Complete candidate CI, downloaded-package/update acceptance, actual publication, Asset Store approval, broader platform compatibility and third-party asset attribution records remain outstanding. Historical milestone versions describe their original verification state.

## Roadmap

### P0: Reliability And Persistence

- Expand provider-settings coverage for credential isolation, migration, custom endpoint preservation, discovery failures, and active-request lockout. Editor-only unsaved conflicts, diagnostics contracts/logger integration, editor scaling, and deeper plugin lifecycle coverage are permanent.
- Expand CI when additional Godot versions enter the supported compatibility matrix; Godot 4.7.2 is currently covered.
- Continue tuning token/context reserves from real-provider beta evidence; automatic complete-turn compaction is implemented for models with known context windows.
- Add durable pending-approval recovery after editor restart without weakening stale-state checks.
- Add session rename/export, configurable retention, and project-move migration.

### P1: Deeper Godot Integration

- Expand the implemented bounded live current-scene/selection/subtree inspection with further native properties only where public APIs preserve non-executing reads and project confinement.
- Broaden current structural, value, script, instance, and signal contracts only through dedicated safety review.
- Expand structured Godot scene operations and add further settings only through dedicated risk review.
- Expand reflected Godot API metadata only where public stable APIs provide trustworthy additional detail; prose scraping remains excluded.
- Add project symbol indexing and reference search.
- Add progressive tool-schema disclosure only after provider compatibility, context budgeting, restoration, and deterministic tool-availability behavior are designed and tested.
- Expand semantic validation beyond the structured scene path to remaining raw `.tscn` and `.tres` patch proposals.
- Expand verification beyond text/process evidence only when a bounded visual or input-observation capability exists.

### P2: Review And Workflow

- Add multi-file change batches and transactional approval.
- Persist revert checkpoints.
- Add an interactive search-results card with Open actions for every match.
- Add richer changed-file summaries and context-budget warnings.
- Implement prompt enhancement and expand image context toward bounded screenshot observation; user image attachments are implemented in 1.3.0.
- Future release: investigate a public cancellable native-drop routing API for seamless desktop image drops directly onto the composer. If unavailable, design/propose a Godot engine enhancement allowing editor controls to consume native drops before project import. Retain Orca's separate native attachment window until direct routing is supported and verified with zero project-file changes, rejected/cancelled intake, and platform/lifecycle coverage.

### P2: Providers And Privacy

- Expand the implemented Foundry Responses transport to additional compatible providers only with dedicated capability/continuation coverage; add native Anthropic Messages and Gemini `generateContent` where Chat Completions is insufficient.
- Expand provider capability detection and add more community-maintained provider adapters.
- Support explicitly keyless local endpoints.
- Continue refining endpoint trust presentation from real user feedback without weakening exact-origin transport enforcement.
- Expand the implemented managed-account OS credential store to BYOK provider keys where appropriate; complete Windows/macOS native execution and distribution acceptance.
- Add post-response retry controls, rate-limit backoff, proxy support, and configurable timeout behavior. Pre-submit connection retry is already bounded to one attempt.

### P3: Release Readiness

- Expand the supported compatibility matrix beyond Godot 4.7.2 when permanent coverage is available.
- Run/accept the four-platform native helper workflow, publish a complete updater-equipped GitHub Release and test graphical full-project restart and Asset Library installs. Complete Windows/macOS native-vault/downloaded-package/update acceptance and macOS signing/notarization decisions.

## Decision Log

### External Project Research

Decision: other projects may be studied to identify user problems, workflows, capabilities, and architectural tradeoffs, but they are research sources rather than code donors by default. Useful concepts must be independently designed for Orca's visual language and rebuilt through its bounded tool contracts, Plan/Work permissions, explicit approval, conflict detection, validation, cancellation, persistence, and testing architecture.

Read-only ideas should remain Plan-safe where appropriate. Any project mutation must still produce an immutable reviewed proposal, and any external-state operation must preserve Orca's ownership and boundedness rules. Research must not be used to justify copying another project's prompts, UI, naming, source structure, or weaker safety assumptions, and Orca's invariants must never be relaxed to match another product's feature count.

Direct source reuse is exceptional rather than the default. When compatible licensed material is intentionally reused, its provenance, license and attribution obligations, reason for reuse, and integration implications must be documented explicitly.

### Request-Scoped Project Guidance

Decision: automatically load only the bounded root `res://AGENTS.md` and bounded skill catalog metadata. Treat both as untrusted project guidance beneath higher-priority instructions and runtime controls, keep them through one turn's tool rounds, and remove them from resumable history. Do not automatically load skill bodies; require an explicit exact-name `read_project_skill` call and do not recursively follow references from its text.

### Reflected Godot API Information

Decision: expose stable `ClassDB` signatures and registered global-class metadata plus validated public editor Help topics. Do not construct reflected objects, load project scripts to discover members, or scrape prose from private Help controls. Open Docs delegates to Godot's own Help UI; the model receives reflected metadata, not the documentation page text.

### Unsaved Focused Source

Decision: a focused function read may use the exact unsaved source publicly exposed for the matching open script because it is read-only context. Such a result must identify editor provenance and omit a disk SHA-256, so it can never be confused with the saved base required for a patch.

### Live Editor Scene Reads

Decision: acquire only the public current edited scene and selection, read a fixed native allowlist without project getter callbacks, and expose on-demand bounded snapshots in Plan and Work. Use typed native binds for indexed layout getters because generic indexed reflection can dispatch scripts. Keep source provenance, optional expected-scene matching, project/reference boundaries, and truncation explicit. Never turn live state into a disk patch base or persist raw live snapshots as tool events.

### Capability-Aware Image History

Decision: a session is provider-independent; an earlier image must not permanently restrict its models. Preserve original image records and messages, project only earlier user attachments into fixed text placeholders for non-vision requests, and keep existing assistant descriptions without generating new captions or making extra provider calls. Validate canonical images before transport, keep new/current attachments capability-gated, bind inclusion to the active turn, and budget the projected request without changing compaction's canonical history. Returning to vision restores retained images; already-compacted turns are not automatically replayed from the visible transcript.

### Response Model And Mode Attribution

Decision: use a restrained model-left/mode-right footer inside each attributed assistant card. Capture the configured full model ID and generating request mode before lifecycle cleanup; persist only bounded visible-event metadata. Keep provider/reasoning details and additional badges out of the footer/tooltip, preserve interrupted completion state, and omit unknown/local identities rather than guessing from the current selector or session's last model. Attribution remains display data, not an instruction or permission boundary.

### Serialized Dependency Discovery

Decision: use bounded `ResourceLoader.get_dependencies()` traversal for saved resource relationships. Reverse lookup may build a bounded project index, but results must explicitly exclude dynamic code loads, runtime-created resources, unsaved state, and completeness beyond scan limits.

### Tool-Loop Finalization

Decision: detect stable repeated or no-progress activity before the existing hard caps and permit one no-tools request so the model can report partial findings and a safe next step. Further tool calls from that request are denied with protocol-valid results. Keep the 12-round and 16-calls-per-response limits as independent hard failures.

### Progressive Schema Disclosure

Decision: progressive tool-schema disclosure is deferred. Orca continues sending the complete schema eligible for the active mode; future disclosure must preserve deterministic availability, Plan/Work boundaries, context budgeting, provider compatibility, and protocol-valid continuation.

### Plan And Work Names

Decision: Plan is strictly read-only; Work can inspect, debug, and propose approved changes. Work remains the default because approval still protects every mutation. The internal `BUILD` identifier is retained to preserve stored session compatibility.

### Explicit Approval

Decision: model tool calls create proposals, not immediate writes. This keeps the user in control and supports diff review, conflict detection, validation, and revert.

### Line Patches

Decision: replace whole-file model output with bounded line edits and a base hash. Orca still materializes complete old/new content internally for validation, review, application, and revert.

### Request-Scoped Editor Context

Decision: capture context automatically for each turn but remove the snapshot from persistent message history when the turn ends. The model can call `get_editor_context` to refresh it during a task.

### Supported Diagnostics Only

Decision: use public `Logger`, validation, and play-state APIs. Do not scrape private Output, Script Editor, or Debugger controls because those structures are unstable and incomplete.

### Diff Presentation

Decision: use a compact unified diff in the narrow dock and an expanded side-by-side Previous/Proposed viewer. This preserves readability without requiring a wide dock.

## Milestone Log

### 2026-10-01: Orca 1.1.0 Godot Intelligence

- Added automatic bounded root project instructions and bounded project-skill catalog metadata as private request-scoped guidance, with explicit exact-name skill-body loading and no recursive execution semantics.
- Added read-only Plan/Work tools for reflected Godot API signatures and Help topics, focused saved or unsaved GDScript functions, and bounded serialized forward/reverse dependencies.
- Added early repeated/no-progress tool-loop detection and one no-tools finalization request beneath existing hard caps.
- Preserved path, symlink, Orca-directory, output, privacy, and protocol boundaries; unsaved editor source never supplies a patch hash, API reflection never constructs objects, and dependency discovery never loads resources.
- Registered six permanent suites in CI and documented contracts, hard limits, security, testing, and known limitations.
- Included the post-1.0 responsive scaling, compact composer, transparent branding, expanded-diff sizing, active-turn auto-follow, and sequential approval visibility fixes in 1.1.0.
- Deferred progressive tool-schema disclosure rather than claiming it as implemented.

### 2026-09-29: In-Dock About Page

- Added a narrow-dock Provider/About switch to Settings without adding another crowded header action.
- Added an About page with the Orca mark, version sourced from `plugin.cfg`, a concise product and safety explanation, Godot compatibility, and MIT attribution.
- Preserved Provider as the default tab and the current-model shortcut into model configuration.
- Added permanent tab, release-metadata, branding, and 300 px layout coverage.

### 2026-09-27: Foundational Agent

- Established the Godot editor dock, settings, OpenAI-compatible API calls, conversation history, and initial list/read/edit tool loop.

### 2026-09-27: Composer And Header Cleanup

- Increased action targets, improved composer spacing and prompt readability, and repaired send-button presentation.

### 2026-09-27: Dock Visual Polish

- Added a branded empty state and clearer header hierarchy.
- Reworked the prompt composer with editor-themed focus treatment, compact actions, empty-prompt send state, and subdued unavailable actions.
- Replaced the basic mode menu with a responsive in-dock overlay and container-sized, icon-led Plan and Work choices that explain their permissions.

### 2026-09-27: Streaming And Cancellation

- Replaced buffered responses with nonblocking SSE streaming, reconstructed fragmented tool calls, added Stop behavior, and protected against stale requests.

### 2026-09-27: Structured Activity And Safe Review

- Replaced the text-only transcript with message and activity controls.
- Added collapsed tool cards, unified and side-by-side diffs, explicit Apply/Reject, conflict-aware writes, and Revert.

### 2026-09-27: Plan And Work Modes

- Added enforced read-only Plan mode and approved-change Work mode.
- Added mode-specific colors, prompts, tool schemas, and authoritative transition messages.

### 2026-09-27: Godot-Aware Coding Loop

- Added bounded recursive search and line-ranged reads with hashes.
- Added active scene, selected node, active script, caret, selection, and unsaved-state context.
- Replaced full-file model writes with precise line patches.
- Added GDScript validation before proposal and application.
- Added supported diagnostics and play-state reporting.
- Added Open File actions to tool and change cards.

### 2026-09-27: Sessions And Usage Visibility

- Enabled New Session with confirmation, full in-memory conversation reset, and empty-state restoration.
- Added provider-reported session token accounting across tool rounds and compact context usage in the dock header.
- Added session cost using provider values first, then automatic public model metadata with built-in offline fallbacks.
- Removed the small header logo to make room for session metrics at narrow dock widths.
- Removed manual pricing fields, added bounded weekly `models.dev` metadata refreshes, and moved metrics to a dedicated header row.

### 2026-09-27: Provider-Aware Settings

- Replaced the modal URL/key/model form with a responsive in-dock provider settings page.
- Added first-class OpenAI, DeepSeek, and OpenRouter profiles, provider-specific credentials, authenticated model discovery, searchable selection, and capability-driven reasoning effort.
- Preserved custom OpenAI-compatible endpoints and migrated existing global settings into provider profiles.
- Added request-scoped provider snapshots and provider-specific reasoning continuation for multi-round tool calls.

### 2026-09-28: Transport Failure Hardening

- Removed duplicate raw buffering for successful SSE streams and added separate bounded accumulators for visible output, reasoning, reasoning details, tool arguments, events, and error bodies.
- Added structured transport failure metadata, one safe pre-submit connection retry, strict content-type handling, clean-EOF SSE flushing, and tool-call ID validation.
- Marked failed partial responses as incomplete, preserved protocol-valid history, and stopped Orca transport errors from feeding back into project diagnostics.
- Added committed parser and local HTTP integration tests for clean streams, disconnects, oversized responses, cleanup, and malformed content types.

### 2026-09-28: Project Session History

- Enabled the History action with an in-dock browser for opening, continuing, deleting, and clearing project conversations.
- Added bounded project-keyed `user://` persistence with schema validation, 50-session retention, verified atomic replacement, backup recovery, and startup restoration.
- Persisted visible messages, sanitized tool activity, non-actionable change summaries, mode, model labels, and aggregate usage without credentials, hidden reasoning, editor snapshots, patch contents, or raw tool output.
- Added provider-independent continuation restoration and made interrupted tool sessions or truncated histories view-only to prevent duplicated side effects.
- Added permanent persistence, redaction, recovery, retention, controller restoration, and narrow-history-layout tests.

### 2026-09-28: Work Mode Naming

- Renamed the user-facing Build mode to Work to cover editing, debugging, and future run/fix/verify workflows without implying compilation or export.
- Preserved the internal `BUILD` enum and stored numeric mode value for session compatibility.
- Made the composer model pill open Settings at the provider-appropriate model control while preserving request-time settings lockout.

### 2026-09-28: Safety Regression Coverage

- Added permanent patch-materialization coverage for line operations, malformed and overlapping edits, and LF/CRLF preservation.
- Added tool safety coverage for mode schemas, direct mutation denial, path and symbolic-link boundaries, proposal immutability, stale conflicts, safe application, and guarded revert.
- Added controller coverage for Plan runtime enforcement, explicit approval and rejection, cancellation during approval, and protocol-valid results for every assistant tool call.
- Corrected project-root path normalization so `res://` cannot be treated as a writable file target.
- Added Godot 4.7.2 CI for all permanent suites, localhost transport integration, plugin initialization, and replacement-artifact hygiene.

### 2026-09-28: Rich Code Presentation

- Added line-aware fenced-code parsing that keeps malformed or incomplete fences as literal text and isolates code from Markdown and BBCode transformations.
- Added bounded selectable code blocks with language labels, Copy actions, horizontal scrolling, and public `GDScriptSyntaxHighlighter` integration.
- Reused the finalized renderer for streamed completions, tool-preface text, non-streaming responses, and restored complete sessions while leaving interrupted responses literal.
- Added permanent parser, rendering, streaming-finalization, restoration, safety, and 300 px layout coverage.

### 2026-09-28: Grouped Tool Activity

- Grouped consecutive allowlisted read-only tools into compact activity cards with aggregate status, total duration, and expandable per-call details.
- Kept mutation and unknown tools standalone and preserved dedicated change-card review for every patch proposal.
- Derived live and restored groups from the same flat tool-event sequence without changing session schema or persisting raw tool output.
- Persisted only bounded search labels and normalized navigation metadata needed to restore useful activity targets and Open actions.
- Added permanent aggregate, grouping-boundary, restoration, mutation-isolation, navigation, and 300 px layout coverage.

### 2026-09-28: Persistent Task Checklist

- Added `update_tasks` in Plan and Work as an atomic session-metadata operation with strict item, content, status, and single-active-task validation.
- Added a compact collapsible task panel above the composer with text and color status indicators and bounded narrow-dock layout.
- Persisted sanitized task state independently from tool protocol, restored it per project session, included it only in request-scoped model context, and cleared it for new sessions.
- Kept successful task updates out of the activity feed, surfaced failed updates as bounded activity, and excluded raw task arguments from persisted events.
- Added permanent tool validation, controller state, request-context, session sanitation/restoration, panel behavior, failure, and 300 px layout coverage.

### 2026-09-28: Saved Scene Inspection

- Added `inspect_scene` in Plan and Work using public `PackedScene`/`SceneState` metadata without node instantiation or raw `.tscn` parsing.
- Added bounded hierarchy, ownership, groups, child-scene references, serialized property, signal-connection, and JSON-safe Variant summaries with valid whole-record output truncation.
- Rejected outside-project, symbolic-link, Orca-owned, missing, non-scene, oversized, malformed, and unsaved scene targets before exposing navigation metadata.
- Integrated scene inspection into grouped activity, session-safe target metadata, scene navigation, and model guidance while persisting no raw scene output.
- Added permanent fixture coverage for structure, Godot values, child instances, connections, bounds, strict argument types, failures, Plan execution, and no-approval behavior.

### 2026-09-28: Structured Project Settings Inspection

- Added `inspect_project_settings` in Plan and Work for a bounded configuration overview or one allowlisted explicit setting without mutation or approval.
- Reported selected application, main-scene, window, Input Map, autoload, rendering, and physics values with active feature overrides and typed JSON-safe summaries.
- Added sensitive-path and low-risk-family restrictions, strict runtime arguments, fixed enumeration and Variant bounds, and a 64 KB whole-JSON output limit.
- Integrated grouped activity, `project.godot` navigation, safe session restoration metadata, model guidance, permanent tests, and CI coverage without persisting returned values.

### 2026-09-28: Reviewed Input Map Proposals

- Added Work-only `propose_input_map_changes` with typed add/update/remove operations for key, mouse, and joypad events.
- Generalized the controller's reviewed mutation path while preserving mandatory approval, protocol-valid cancellation, and runtime Plan denial; Plan now also blocks revert.
- Bound proposals to exact `project.godot` and retained-content hashes, preserved every unrelated byte, compared affected live/disk state, reparsed candidates, and verified synchronized InputMap values.
- Added a dedicated structured review card, safe non-actionable session summaries, guarded apply/revert with recovery-aware rollback behavior, permanent tests, and CI coverage.

### 2026-09-28: Reviewed Main Scene Proposals

- Added Work-only `propose_main_scene_change` for setting a validated saved `.tscn` as the project launch scene through explicit approval.
- Normalized valid UID/resource representations, detected semantic no-ops, disclosed unresolved previous values, and preserved every unrelated valid UTF-8 project byte.
- Revalidated target and project paths, live/disk state, retained hashes, PackedScene loading, and candidate configuration immediately before verified replacement.
- Added live ProjectSettings synchronization, guarded revert, conflict/recovery statuses, a dedicated narrow review card, private proposal boundaries, permanent tests, and CI coverage.

### 2026-09-28: Allowlisted Project Settings Proposals

- Added Work-only `propose_project_settings_changes` for atomic typed changes to six low-risk viewport, window-override, and stretch settings.
- Enforced exact path allowlisting, strict Variant types, conservative finite dimensions, enums, duplicate rejection, built-in defaults, and affected live/disk equality.
- Materialized only requested assignments, rebound retained metadata to the complete old/new allowlisted delta, and preserved unrelated valid UTF-8 project bytes.
- Added a dedicated typed review card, private/redacted persistence boundaries, synchronized apply/revert with conflict and recovery handling, permanent tests, and CI coverage.

### 2026-09-28: Structured Scene Proposal Foundation

- Added Work-only `propose_scene_changes` with an initial `create_scene` operation for `Node`, `Node2D`, `Node3D`, and `Control` roots.
- Constructed candidates through `ClassDB` and `PackedScene`, then saved and reloaded bounded `user://` scratch scenes before review and immediately before application.
- Bound proposals to absent targets and exact candidate hashes, rechecked path, existence, unsaved state, and semantic root identity, and added verified creation plus guarded deletion revert.
- Added a dedicated structured review card, Plan runtime denial, private proposal redaction, bounded session summaries, permanent tests, and CI coverage.

### 2026-09-28: Structured Scene Add Node

- Extended `propose_scene_changes` with hash-bound `add_node` operations targeting root or nested canonical parent paths.
- Reconstructed bounded compatible scenes with editor generation state, assigned scene-root ownership, and rejected scripts, instances, inheritance, Resource properties, open scenes, and unrelated serialization drift before review.
- Added existing-file verified replacement, final semantic verification, exact-byte guarded revert, structured hierarchy review, schema coverage, and permanent stale/conflict tests.
- Added dependency pre-screening, process/randomized scratch names, plugin-startup stale scratch cleanup, and prompt release of private proposal bytes after rejection, cancellation, failure, or successful revert.

### 2026-09-28: Expanded Structured Scene Operations

- Added typed property, leaf rename/remove/reparent, dependency-free child-scene instance, and persistent bindless signal connect/disconnect operations to the existing reviewed scene envelope.
- Added strict Variant decoding, canonical local paths, semantic before/after checks, dependency hashes, ownership and signature validation, operation-specific review summaries, exact-byte restoration, and permanent lifecycle coverage.
- Kept script attach/detach unavailable after confirming that Godot candidate construction would instantiate project scripts before user approval; documented the required future trust-boundary redesign instead of weakening review guarantees.

### 2026-09-28: Two-Stage Scene Script Operations

- Added dependency-free GDScript attach/detach to `propose_scene_changes` without loading or compiling project code during initial preparation.
- Added an explicit hash-bound Trust and Prepare review before candidate construction, followed by the normal immutable candidate Apply/Reject review inside one protocol-valid tool call.
- Rechecked scene/script paths, hashes, unsaved state, dependency freedom, GDScript validity, native-base compatibility, complete scene semantics, and exact-byte revert state before mutation.
- Reused one structured card and one sanitized session event across both stages; script bytes, hashes, trust bindings, operations, and pending approvals remain private and non-persistent.
- Added attach/detach lifecycle, stale script, invalid source, incompatible base, two-stage rejection/cancellation, privacy, and narrow-card regression coverage.

### 2026-09-28: Wave 4 Process Foundation

- Added Work-only `run_current_scene`, `run_main_scene`, and `stop_game` tools backed by one plugin-owned nonblocking Godot child process.
- Added fixed executable/project/scene arguments, active feature-aware main-scene resolution, unsaved-state checks, editor-run exclusion, private PID ownership, natural exit status, a 120-second timeout, and explicit kill-failure states.
- Added separately bounded stdout/stderr capture, continued pipe draining after retention limits, conservative project-local runtime diagnostics, and merged `get_diagnostics` reporting without private editor control scraping.
- Added standalone run/stop activity, Work-mode disclosure, sanitized persistence, deterministic lifecycle tests, and a real nested-Godot pipe/exit-code integration check.

### 2026-09-28: Bounded Run, Observe, Fix, Verify Loop

- Added immutable pre-launch `clean_startup` and `expected_exit` criteria, monotonic run IDs and snapshot sequences, read-only observation, and scoped machine-evaluated verification verdicts.
- Added a cancellable controller observation checkpoint after complete protocol-valid tool batches, with a 1.5-second settle period, five-second ceiling, three-run-per-turn limit, and request-scoped non-persistent evidence.
- Replaced single-line diagnostics with bounded stream-local parsing for Godot error/warning headers and following project-local `at:` or backtrace locations, including diagnostics beyond raw-output retention.
- Prevented criterion goalpost changes within a turn, nonzero-exit startup false passes, generic persisted success labels for failed verification, and oversized or malformed JSON/SSE tool-call batches.
- Kept fixes behind existing review approval and reruns explicit; no timer or diagnostic automatically changes files or starts another game.

### 2026-09-28: Protocol-Aware Context Budgeting

- Added conservative request estimation for known model context windows before initial requests and every tool follow-up, including tool-schema cost and bounded reserves for tool results and final answers.
- Added deterministic oldest-complete-turn compaction with one model-visible notice while preserving the active turn, request-scoped editor/runtime context, provider reasoning continuation, and complete assistant-call/tool-result protocol groups.
- Added fail-before-transport behavior when protected request state alone exceeds the safe budget; unknown custom-model limits continue without guessed enforcement.
- Rehydrated cached provider model metadata so discovered context limits remain available after cache reuse.
- Added permanent boundary, malformed-history, repeated-compaction, persistence, controller-index-remapping, and oversized-active-turn regression coverage.

### 2026-09-28: Animated Working States

- Added a mode-aware five-square bioluminescent tide indicator for initial thinking, post-tool response preparation, runtime observation, and assessment.
- Kept the transient indicator visible across successful SSE response headers and replaced it only when actual assistant text or tool activity begins, eliminating empty `Orca:` cards during first-token delays.
- Added explicit controller workflow state for every initial and follow-up provider request, deterministic animation cleanup, non-persistent status behavior, and narrow-dock regression coverage.

### 2026-09-28: Active Conversation Auto-Follow

- Replaced the one-frame bottom jump with bounded multi-frame following that survives deferred rich-text, container, code-block, and review-card layout.
- Kept active turns attached to the newest working, streamed response, tool, and approval activity, including automatic movement from one resolved proposal to the next pending proposal.
- Added regression coverage that expands a card after the initial scroll frame and verifies sequential review cards remain visible at the feed bottom.

### 2026-09-28: Gemini And xAI Providers

- Added first-class Google Gemini and xAI profiles using their OpenAI-compatible Chat Completions endpoints, separate credentials, authenticated model discovery, searchable model selection, and capability-driven reasoning effort.
- Normalized Gemini's native model list and xAI context, pricing, and reasoning capabilities while mapping their public metadata to the `google` and `xai` catalog namespaces.
- Preserved bounded opaque streamed tool-call metadata so Gemini thought signatures remain attached through tool-result continuation, and preserved xAI `reasoning_content` without displaying it.
- Added permanent adapter, metadata, parser, and localhost transport coverage without sending live provider requests.

### 2026-09-28: Release Documentation Baseline

- Declared Orca plugin version 1.0.0 and its user-facing description.
- Added MIT licensing, public installation and safety documentation, contributor and security guidance, a release changelog, and Godot-specific Git ignores.
- Recorded third-party SVG asset provenance as a release blocker until each source license and attribution requirement is verified.

### 2026-09-29: Responsive Editor Scaling

- Added one effective editor-scale policy for plugin-authored geometry while preserving Godot's already-scaled theme fonts and editor icons.
- Replaced the fixed-height composer with compact line-height-driven growth, removed unavailable image-action width, and corrected the 300 px-equivalent action-row budget.
- Scaled shell, settings, history, activity, task, and review-card geometry; bounded expanded diffs to the available editor window and stacked panes when narrow.
- Reworked the Orca mark as a transparent high-resolution SVG that remains visible on dark and light backgrounds.
- Added compact-composer, narrow-action, scale-conversion, editor-integration, and logo-transparency regression coverage.

### 2026-10-02: DeepSeek Stream Budget Alignment

- Bounded DeepSeek responses to 8,192 generated tokens, aligned with Orca's minimum known-context final-answer reserve, instead of inheriting the provider's substantially larger defaults.
- Raised the raw streamed transport allowance to 16 MiB while retaining tighter limits for accumulated assistant text, reasoning, tool arguments, metadata, SSE lines, and SSE events.
- Added provider-option coverage and a localhost regression proving that valid framing-heavy streams above the former 4 MiB threshold complete while oversized streams remain bounded.
- Restored the documented controller integration for repetitive/no-progress tool-loop detection and made the 12-round boundary request one tool-free summary instead of raising a system error after completed work.

### 2026-10-04: Orca 1.2 Editor Reliability Foundation

- Added permanent Godot 4.7.2 editor integration for real dirty script/scene state, exact unsaved current-editor source, patch/apply/revert conflict protection, saved-scene inspection/proposal rejection, and run blocking.
- Canonicalized reviewed file paths before editor-state, hash, and write checks; file reverts now reject dirty editor buffers rather than overwriting their saved backing file.
- Bounded diagnostic record fields, preserved warning severity, removed resource loading from logger callbacks, and reference-counted one shared logger so multiple services cannot duplicate records.
- Added diagnostics contract/editor integration and actual plugin enable/disable/re-enable suites, and registered all editor integration suites, including the previously omitted editor-scale suite, in CI.

### 2026-10-04: Orca 1.2 Local Provider Foundation

- Added first-class Ollama, LM Studio, and Local OpenAI-compatible profiles over the bounded shared Chat Completions transport, with editable conventional endpoints, truly optional bearer authentication, explicit keyless model discovery, and manual model fallback.
- Moved provider model discovery to an endpoint- and credential-aware cache and bounded model count, names, IDs, and reasoning metadata.
- Enforced local profiles as Chat-only at both schema and runtime boundaries; unsolicited tool calls fail before any project or process action unless an exact compatibility-bound opt-in is active.
- Added hermetic settings coverage, real EditorSettings profile-isolation coverage, keyless chat transport coverage, and keyless `/models` integration that verifies no Authorization header is sent.

### 2026-10-04: Orca 1.2 Endpoint Trust Hardening

- Added one strict endpoint policy for URL normalization, loopback/LAN/remote classification, exact-origin confirmation, and generated chat/discovery endpoint validation.
- Added Settings disclosure and confirmation bound to scheme, host, and effective port; stale confirmations, changed dialog text, malformed URLs, and partial profile saves fail closed.
- Chat and discovery reauthorize before constructing credential headers. Discovery disables redirects, while the low-level chat transport continues treating redirect responses as terminal HTTP failures.
- Bound Chat-only behavior to every editable OpenAI-compatible profile and fixed-provider origin override so DNS aliases, alternate IP forms, or provider labels cannot bypass the endpoint/model compatibility requirement.

### 2026-10-04: Orca 1.2 Compatibility-Checked Local Agents

- Added an isolated two-step synthetic function-call probe that sends no project, editor, session, task, instruction, skill, or real-tool context and requires exact call metadata, challenge arguments, matching tool-result continuation, and final acknowledgement.
- Persisted only bounded compatibility metadata in EditorSettings. A pass always starts disabled; a separate checkbox is required to enable Agent tools for the exact binding, and runtime recomputes the binding from the request snapshot.
- Kept canonical hosted providers unchanged while requiring probe plus opt-in for every editable profile and fixed-provider origin override. Provider, origin, base/chat endpoint, model, reasoning effort, or probe-version drift fails closed.
- Disabled the stream-options compatibility retry on probe requests and every normal continuation after a real tool round so post-tool failures cannot silently resend a changed request.

### 2026-10-05: Native Local Model Filtering

- Switched Ollama discovery to `/api/tags` and LM Studio discovery to `/api/v1/models`; known embeddings are excluded using native capabilities/types, with a conservative `embed` fallback only when metadata is absent.
- Preserved unrestricted manual Model ID override, reset normalized discovery cache to v3, sanitized cached records, and fixed stale request ownership and programmatic model-selection signal handling.
- Added bounded provider error extraction and local embedding-selection model-substitution detection. Live LM Studio testing showed that requesting its embedding ID returned HTTP 200 from the loaded Llama model; after the fix, Orca returns `model_mismatch` before emitting assistant text.

### 2026-10-05: Orca 1.2.0 Release Preparation

- Finalized 1.2.0 plugin metadata, public release notes, supported-version documentation, and About-page coverage.
- Kept editable-provider Settings within the 300 px dock constraint by preventing the Agent opt-in control from imposing a wide non-wrapping minimum.
- Retained add-on-only Git export rules and documented that release packaging automation remains future work.

### 2026-10-06: Orca 1.2.1 Reliability Wave 1

- Required every completed provider response to contain visible non-whitespace assistant text or at least one valid tool call. Empty, whitespace-only, reasoning-only, usage-only, known truncated/filtered, and contradictory responses now fail visibly.
- Added a ten-minute total provider-generation deadline alongside the existing connection and inactivity bounds, plus terminal-signal ownership checks that prevent stale request paths from completing twice.
- Made loop finalization a distinct visible workflow state, retained the bounded trigger class, improved denied-call wording, preserved bounded useful provider text, and added explicit non-replay continuation guidance.
- Verified retained raw-patch fields, content hashes, canonical edits, and review diff immediately before Apply; final destination bytes are reread, hash-checked, and revalidated, with guarded rollback or an explicit retained recovery state on failure.
- Added permanent transport, controller, UI, real GDScript patch lifecycle, and duplicate-variable regressions. All permanent unit/component and real-editor suites, all three localhost integrations, `git diff --check`, and Godot 4.7.2 editor/plugin initialization pass; live Gemini/DeepSeek checks and deterministic post-write fault injection remain release gates.

### 2026-10-06: Orca 1.2.1 Deterministic Recovery Verification

- Replaced ambiguous write-error strings with explicit not-committed, committed, committed-with-cleanup-warning, and recovery-failure outcomes across every reviewed mutation and revert path.
- Separated successful cleanup attention from uncertain recovery: cleanup-only states remain safely revertible without bypassing live-state conflict checks, while uncertain apply/revert outcomes are unsuccessful, retain private proposal state, hide unsafe Revert, and persist bounded project-relative recovery guidance.
- Added environment-gated deterministic fault injection for temporary verification/cleanup, replacement/restore, backup cleanup, post-write reread/hash/validation, independent destination change, and rollback failure paths. The model tool surface cannot configure these test faults.
- Preserved one absolute provider-generation deadline across connection and `stream_options` compatibility retries and added active localhost SSE fixtures proving continuous hidden reasoning cannot extend it.
- Added controller, card, session, file patch, structured mutation, and transport regressions for the new outcome contracts. Live Gemini and DeepSeek multi-round checks remain manual release gates.

### 2026-10-06: Orca 1.2.1 Provider Request Ownership

- Added caller-owned lifecycle IDs to all `APIClient` stream and terminal signals while preserving its separate private coroutine serial.
- Added monotonic controller turn and provider-request ownership, distinct IDs for tool follow-ups, single-claim terminal handling, and turn-bound awaited continuations.
- Added independent ChatWindow turn guards before request-scoped card, session, composer, and Send/Stop changes, plus focused stale, duplicate, cancellation, follow-up, probe, and synchronous-failure regressions.
- Hardened synchronous signal reentrancy by reserving request ownership before workflow signals, rechecking before transport, and invalidating ending ownership before busy or terminal emissions.

### 2026-10-07: Orca 1.2.1 Composer And Support Diagnostics

- Kept the composer multiline while a turn is active, made the turn-owned UI state authoritative for Send/Stop presentation, and preserved typed follow-up drafts across matching completion, failure, cancellation, and stale callbacks.
- Added a memory-only last-request support snapshot protected by provider-request ownership and a separate strict-positive-allowlist report builder; no session, diagnostics, process, transcript, or provider-output state is consumed.
- Added an About-page copy action with explicit privacy disclosure plus permanent active-composer, Stop-path, request-lifecycle, exact-schema, adversarial-secret, and narrow-layout regressions.

### 2026-10-07: Explicit Plan-To-Work Escalation

- Added one bounded Plan-only `request_work_mode` decision per turn with explicit stay/switch actions, exact turn/call ownership, cancellation, and no persisted pending state or reason.
- Bound every tool call to the mode under which its provider response was generated, preventing approval from authorizing later mutation calls smuggled into the original Plan batch. Approval regenerates the primary Work prompt and uses the matching tool result without splitting active protocol history.
- Approval continues the same task with a fresh Work-schema provider request while preserving normal mutation approvals; rejection remains in Plan and users can switch manually after the turn without automatic replay.

### 2026-10-07: Gemini Tool Finish Compatibility

- Accepted Gemini's observed OpenAI-compatible `stop` finish reason when the same response contains structurally valid tool calls, allowing Plan-mode `request_work_mode` calls to reach the existing confirmation flow.
- Kept the exception adapter-scoped: other providers still reject `stop` plus tool calls, while malformed, empty, truncated, filtered, and blocked responses remain failures.
- Added unit and localhost SSE regressions that preserve Gemini's raw finish reason and opaque thought signature.

### 2026-10-07: Atomic Malformed Tool-Batch Recovery

- Added whole-batch argument preflight before tool activity, requiring every provider-supplied argument string to decode to one JSON object before any read, mutation, approval, or external operation begins.
- Rejected malformed batches are excluded from protocol history and receive at most one request-scoped regeneration attempt from the pre-batch state; repeated invalid output fails visibly without replay.
- Added controller regressions for successful regeneration, repeated invalid output, temporary-notice cleanup, and mixed batches that contain a valid mutation alongside a malformed call.
- Added a stateful localhost Gemini regression that accepts final generation only after the exact reconstructed thought signature, assistant tool call, matching tool result, and protocol order survive a real second HTTP request.
- Added a stateful DeepSeek continuation regression that requires bounded high-effort request options, reconstructed `reasoning_content`, incompatible reasoning-field removal, exact tool protocol, and final hidden-reasoning reconstruction across two real HTTP requests.
- Added equivalent xAI continuation coverage and an OpenRouter regression that reconstructs indexed fragmented `reasoning_details`, including text and signatures, then requires their verbatim replay with the matching tool result.

### 2026-10-07: Long-Task Runtime Loop Hardening

- Decoupled repetition fingerprints from semantic progress and normalized runtime observations so changing elapsed time or cursors cannot conceal unchanged polling; verification progress now follows verdict and check-status transitions.
- Added an early round-eight consolidation notice, first-observation next-action guidance, and one controller-owned cleanup of an exact same-turn Orca process before tool-free safety finalization.
- Extended `stop_game` with bounded final evidence and added real-shaped progress, cleanup ownership, finalization visibility, recommendation, and stop-evidence regressions.

### 2026-10-07: Conservative Tool-Batch Barriers

- Restricted multi-call provider batches to a fixed allowlist of independent read-only tools. Work-mode requests, task updates, reviewed mutations, process operations, observations, verifications, and unknown future tools now require singleton batches.
- Reused the atomic pre-execution correction path so unsafe mixed batches produce no activity, side effects, approval prompts, or protocol history and receive at most one fresh bounded regeneration request.
- Added controller coverage for successful read-only batching, every singleton-only tool category, unknown-tool fail-closed behavior, mixed Plan escalation rejection, atomic mutation/read rejection, and protocol-valid continuation.

### 2026-10-07: Final Deterministic Reliability Gates

- Split checklist state from immutable editor/project context and refresh exactly one model-facing checklist only after a successful matching `update_tasks` result, including clearing, compaction remapping, recovery, and no-tools finalization.
- Added context-pressure finalization: complete tool turns retry once without schemas when only the full-tools request exceeds budget, otherwise stop locally with a deterministic task-aware non-replay checkpoint and normalized same-turn cleanup outcome.
- Added one deterministic ten-round orchestration scenario covering inspection, a required post-failure reread, two separately hash-bound approved fixes, failed and passed same-criteria runs, automatic observations, explicit stop, checklist reconciliation, and scoped final response.
- Tightened finalization cleanup to the exact same-turn run ID, replaced automatic raw stop evidence with a fixed privacy-safe outcome, and made bounded `stop_game` output disclose diagnostic and stream-tail truncation introduced by response limits.
- Fixed Expanded Diff Apply/Reject ordering so the exclusive window hides before synchronous mutation callbacks can trigger editor reload dialogs; component coverage verifies ownership is released inside each callback.
- All 31 unit/component suites, all five editor suites, all three localhost integrations, Godot 4.7.2 headless editor/plugin initialization, `git diff --check`, and replacement/cache artifact checks pass after these changes. Deliberately invalid GDScript fixtures and known headless editor RID/ObjectDB shutdown warnings remain expected and non-failing.
- Live DeepSeek passed high-effort reasoning, requested-empty rejection, cancellation, and total-generation timeout checks through the configured adapter and selected model. Live Gemini produced malformed empty tool/final output and a response-start timeout across three bounded attempts; this remains a documented provider/model risk as the user advances the locally dogfooded 1.2.1 release candidate.

### 2026-10-07: Orca 1.2.1 Release Candidate

- Advanced plugin, installable add-on, public README, architecture, About-page tests, support-report fixture, and dated changelog metadata to 1.2.1 after deterministic gates and user dogfooding.
- Preserved the historical 1.2.0 release record and documented the unresolved selected-model Gemini risk without claiming that live gate passed.
- Release archive construction remains user-owned for this candidate; no commit, tag, push, GitHub Release, or Asset Library update was performed during metadata preparation.

### 2026-10-13: Orca 1.3.0 Release Preparation

- Prepared 1.3.0 plugin/About/installable add-on metadata, dated release notes, public usage/privacy documentation, and security release-line metadata for image attachments and refreshed settings.
- Image attachment delivery includes floating previews, clipboard Paste, internal project-file drags, a separate native desktop-drop/Browse window, per-model capability, bounded normalization/context reserves, retained tool-follow-up images, and deduplicated local conversation persistence.
- Completed all 33 unit/component suites, all five editor suites, all four localhost integrations, Godot 4.7.2 headless editor/plugin initialization, and `git diff --check`. Invalid-source and simulated process fixtures emit expected diagnostics; editor suites retain known shutdown RID/ObjectDB/scan warnings.
- Real Linux/X11/Vulkan XDND accepted and unsupported-model drops passed with zero non-generated project-file changes. Native editor fixture progress-dialog and shutdown diagnostics remain visible and documented; no live provider request was made.
- Verified `/tmp/opencode/orca-1.3.0-addon.zip` from the full working-tree add-on (including new source and icons): 141 files, 1,260,571 bytes, only `addons/orca/`, no generated `.import` files, valid ZIP, and successful clean-host asset import followed by plugin initialization. The first harness attempt enabled the plugin before asset import and emitted loader errors; the corrected install-order check imports assets before enabling the plugin.
- No replacement, test-fixture, or Python cache artifacts remain in the workspace. Commit/push/publication are user-owned and have not been performed. Further live vision, OS clipboard, other native platforms/renderers, and detached-window acceptance remain manual gates; selected-model Gemini continuation risk is retained. Seamless desktop drops onto the main dock remain future engine-integration work.

### 2026-10-18: Local Chat Template Compatibility

- Addressed the message-placement incompatibility behind issue #2 by combining local-profile string system messages into one leading wire record without modifying request-scoped controller history, tool-call/result ordering, image parts, or permission boundaries.
- Expanded the project-free two-request Agent probe with fixed refreshed system context; version 2 invalidates old passes until the user retests and explicitly enables tools again.
- Added a strict localhost fixture that rejects the original later-system layout with the reported HTTP 500 and accepts five-request chat/tool/finalization sequences for LM Studio, Ollama, and Local OpenAI-compatible profiles. Registered the new permanent integration and its script UID in CI/source.
- Passed eight focused unit/component suites (provider, API client, controller, context budget, compatibility probe, settings, images, sessions), all five localhost integrations, the real EditorSettings suite, Godot 4.7.2 headless editor/plugin initialization, and diff/artifact checks. Controller/image fixtures emit expected synthetic diagnostics; the editor-settings harness retains documented scan-abort/RID/ObjectDB shutdown warnings.
- The user's smaller Qwen chat test passed before this fix but failed the exact-argument Agent probe. No live model requests were made for implementation; the reporter's exact model/template reproduction and interactive acceptance remain outstanding. Changes are unreleased; plugin metadata remains 1.3.0.

### 2026-10-19: Live Editor Scene Intelligence

- Added `inspect_editor_scene` for bounded selected-node, current-scene, and subtree inspection, including unsaved hierarchy changes, UI layout, 2D/3D transforms, native state, parent layout context, and confined script/resource identities.
- Integrated Plan/Work schemas, independent-read batching, model guidance, grouped activity, strict query-only persistence, and historical restoration without stale editor actions or patch hashes.
- Added adversarial native-getter isolation and real-editor coverage, including the saved menu review/Apply/reinspect/Revert workflow. Early harness runs exposed deferred scene-switch/teardown races; settling public editor operations and avoiding dummy-renderer thumbnail/3D-workspace paths corrected them.
- Eleven focused unit/component suites, four editor suites, the 29-request localhost transport integration, Godot 4.7.2 headless editor/plugin initialization, and diff/artifact checks pass. Integral provider JSON limits and stored-history numeric round trips are covered. Editor fixtures retain documented non-failing RID/ObjectDB shutdown diagnostics; invalid-source and simulated provider fixtures remain expected. Live model/UI and additional-platform acceptance remain outstanding. Plugin metadata remains 1.3.0; work is Unreleased.

### 2026-10-19: Provider-Independent Image Conversations

- Removed conversation-wide image capability lockout. Prior images become fixed text placeholders only in non-vision outgoing copies, while original messages/previews remain intact and retained images return when vision is selected again.
- Bound image inclusion to the active provider turn, kept current/new attachments capability-gated, and made budgeting use the exact historical projection while compaction retains canonical records and complete tool protocol.
- Added request-scoped pixel-validation deduplication with exact ID/data/dimension matching and a 32-unique-image bound. Corrupt/malformed records still fail before transport, even when historical pixels would be omitted.
- Added `image_model_switch_test.gd` for projection, reserve/compaction, model transitions, tool follow-ups, restart, failure/cancellation, preserved drafts, and non-blocking composer feedback. Expanded the image SSE integration to ten requests with eight repeated text/vision transition requests after its existing two-request image round. CI includes the new suite and updated fixture count.
- Eleven focused component suites, all five localhost integrations, editor scaling/plugin lifecycle suites, and Godot 4.7.2 headless editor/plugin initialization pass. Synthetic failure and documented non-failing editor shutdown/scan diagnostics remain visible. Live-provider acceptance is still manual; plugin metadata remains 1.3.0 and work is Unreleased.

### 2026-10-19: Model And Mode Response Footers

- Added request-bound model/mode attribution carried through completion before provider-state cleanup, including terminal reentry, per-request Plan-to-Work mode refresh, and existing interruption/tool-preface flows.
- Added an Orca-native borderless footer with full model ID, colored mode, consistent spacing for plain/code cards, two-line long-ID wrapping, and exact identifier tooltips. Visible history retains sanitized per-answer attribution without changing model continuation or inventing legacy/local identities.
- Added shared metadata validation and permanent controller/UI/session/editor-font regressions. Ten focused component suites, editor-scale/plugin lifecycle suites, and Godot 4.7.2 headless initialization pass. Expected synthetic failures and documented non-failing headless shutdown diagnostics remain visible. Live-provider/visual acceptance remains a manual gate; metadata stays 1.3.0 with notes under Unreleased.

### 2026-10-19: Foundry Reasoning And Tool Compatibility

- Added a Microsoft Foundry / Azure profile and stateless Responses transport to address deployed GPT models rejecting reasoning plus Chat Completions tools. Added explicit reasoning effort (including `none`) for Azure and generic compatible Chat, plus opt-in Azure DeepSeek reasoning continuation with custom deployment names.
- Bound compatibility to API and continuation style, preserved controller permissions/approvals and call IDs, and isolated bounded encrypted reasoning and assistant phases to the active turn. Added bounded, challenge-redacted synthetic final-acknowledgement diagnostics without relaxing the probe.
- Permanent tests cover conversion/status/limits, fragmented SSE, profile isolation, context accounting, controller cleanup, session redaction, settings persistence, editor containment, and a 15-request real localhost integration. Live Azure acceptance on the user's exact deployments remains required; no live requests were made. Plugin metadata stays 1.3.0 and changes are Unreleased.
- Fourteen focused unit/component suites, three editor suites, all six localhost integrations, and Godot 4.7.2 headless editor/plugin initialization pass. Same-chunk Stop/reentry guards prevent stale SSE work from repopulating cancelled or newer request state. Expected synthetic errors and documented non-failing editor shutdown/scan diagnostics remain visible; diff/artifact checks are clean.

### 2026-10-19: One-Click Compatibility And Agent Enablement

- Replaced the separate test/enable UI sequence with the disclosed **Test & Enable Agent tools** action. Matching success turns on the toggle; manual opt-out, restored disabled records, failures, cancellations, and stale/duplicate callbacks cannot silently enable tools.
- Bound memory-only intent to the exact form and credentials through origin confirmation, retained disabled-by-default pass storage and guarded runtime enablement, and fixed Azure API/style persistence when switching providers. Project mutation approvals remain enforced.
- Settings, compatibility-probe, controller, real EditorSettings, editor-scale, plugin-lifecycle, and headless editor initialization checks pass. Synthetic errors and documented non-failing editor shutdown/scan diagnostics remain visible. Live click-through acceptance is pending; plugin metadata remains 1.3.0 and changes are Unreleased.

### 2026-10-19: Azure DeepSeek Delimiter And Reasoning Compatibility

- Reproduced the user's exact `</think>ORCA_AGENT_PROBE_OK ...` failure on both APIs and added explicit Azure DeepSeek-only single-delimiter normalization shared by streaming and JSON/completed output. Raw Responses parity and exact challenge/function checks remain intact; generic profiles retain literal markup behavior.
- Added bounded private plain Responses reasoning continuation, exact style/format binding, and the Reasoning Continuation selector for both Azure APIs. Plain state is budgeted, confined to the active turn, and excluded from UI/session/support data. Older DeepSeek passes need retesting; Standard-mode passes retain their binding semantics.
- Fourteen focused component suites, three editor suites, all seven localhost integrations (including the new 13-request Chat/Responses SSE/JSON/negative-control fixture), Godot 4.7.2 headless initialization, and diff/artifact checks pass. Expected synthetic and documented non-failing editor shutdown diagnostics remain visible. User-reported GPT setup works, but live DeepSeek acceptance after this fix remains pending. Changes are Unreleased at plugin metadata 1.3.0.

### 2026-10-22: Explicit Project Script References

- Added composer drops for project `.gd` files and exact public current-editor script-list identity, removable/navigable chips, saved/active-unsaved source capture at Send, and per-message history restoration. References work in Plan/Work and Chat-only/text-only profiles alongside images.
- Added strict 2 MiB source / 300-line / 16 KiB snapshot / four-reference bounds, UTF-8/path/symlink/protected-addon checks, canonical snapshot persistence, outgoing user-context materialization, matching context estimation, and draft recovery. Inactive dirty buffers require activation/save and snapshots never supply patch hashes or tool authorization.
- Passed ten focused component suites (references, image preparation/intake/model switching, chat, controller, API client, context budget, session store, support reports), both affected editor suites, the ten-request image/reference/model-switch localhost integration, Godot 4.7.2 headless editor/plugin initialization, and diff/artifact checks. Real Control drag routing, actual active unsaved source, controller/tool continuations, and project-file symlink rejection are covered. Expected synthetic failure diagnostics and documented non-failing editor shutdown warnings remain visible.
- Actual script-list mouse dragging, live-model usefulness, broader platforms, and additional source languages remain manual/future work. Plugin metadata stays 1.3.0 with Unreleased notes; no publication action occurred.

### 2026-10-26: Account and hosted-model integration

Implemented the Account tab, browser pairing, global per-user OS-vault persistence,
cross-editor refresh locking, managed Cloud provider, strict metered transport,
turn binding, capability handshake, private continuation, and approved backend
probe contract. Verified with 218 backend tests and real two-process Godot/native
vault fixtures, plus affected component/editor suites. Owner services/credentials
were not changed or restarted and no live inference was made. Restart the backend
API to load the additive contract update, update/restart the test-host addon, then
Account → Sign in / Sign up → Use Orca models → Test & Enable → Done. Linux helper
is included; other platform binaries, live browser/model and deployed HTTPS gates
remain outstanding. Plugin metadata remains 1.3.0; publication is user-owned.

### 2026-10-26: Managed defaults and full-context regression

- Corrected the owner-reported fresh `hi` failure: contextual byte estimates were incorrectly sharing the stricter billing reservation metric. Text context now follows the versioned estimate; billing upper-bound reservations, output limits, opaque byte bounds and safe finalization remain.
- Removed all hosted compatibility/reasoning controls, enabled operator-verified managed tools through exact authenticated capability contracts, and activated an included model after sign-in. Local/custom compatibility remains unchanged.
- The original fixture had overridden root instructions and missed the real failure. The regression now runs actual editor context, root instructions and full Work schemas without a user probe record. Full backend regression: 221 passed/no skips, including isolated native persistence. Managed settings tests verify automatic selection, no setup controls and locked-model eligibility. Owner services, credentials, billing jobs and live inference were not modified or invoked.

### 2026-10-26: Hosted image capability and full-context image regression

- Diagnosed the owner-reported attachment denial as missing `image_input` in all four backend live profiles. Published new immutable vision-v2 versions and raised the bounded service context cap to 65,536 so real editor/root instructions, full Work tools, one prepared image and response reserves fit without lowering image/output reserves. Old turn-bound profile versions remain intact.
- Extended real Godot/FastAPI/PostgreSQL acceptance with each actual live profile's limits, image policy, effort and continuation style, verifying identical PNG wire data across the read-tool/follow-up. Account/editor tests cover catalog refresh enabling the real narrow composer, text-only/locked/unknown denial, retained draft images and fixed turn snapshots. Backend fixtures cover image preservation through Chat and native Responses, and text-only denial without an admitted receipt.
- Verification: final backend **226 passed, no skips**, including five actual Godot cases and isolated native-vault persistence; Ruff lint/format and mypy passed. Godot 4.7.2 headless editor/plugin initialization, account service, managed settings/composer and image component suites passed. Editor-harness shutdown RID/ObjectDB diagnostics remain visible; clean editor initialization produced no script/init errors. Diff/artifact checks found no replacement files.
- Owner approved publication, local API/worker restart and capped live tests. Ten authenticated image/tool requests on disposable accounts/schemas settled **3,425 micro-USD ($0.003425)**. All four accepted images; Luna's visual answer failed the synthetic colour check twice, so transport acceptance does not imply recognition accuracy. Larger real upstream contexts, actual desktop clipboard/native image drops and broader platforms were not re-tested for this backend-profile correction. Next: refresh the Cloud catalog in the existing user editor and retry attachment intake.

### 2026-10-26: Scene numeric arguments and continuation-budget feedback

- Investigated the owner's archived Luna turn using its bounded saved receipts. Both saved-scene calls supplied valid integer `max_nodes` values, which Godot decoded as floats and the dispatcher incorrectly rejected. The succeeding broad live snapshot then caused a local context-pressure stop. The 4.1k header was the last completed provider request, not the blocked follow-up estimate; the newer 66k picker metadata was a subsequent catalog refresh.
- Corrected finite integral-number handling/clamp-before-conversion for saved-scene limits. Added exact compact model strings for editor context and saved/live scenes while retaining readable activity text and all values. Updated scene guidance toward structure-first/focused reads. Added memory-only active/blocked budget display and explicit error counts, with last reported usage/cost kept distinct; ordinary failed tools no longer claim file recovery is required. Complete-turn compaction, no-tools finalization, approvals, private continuation and non-replay checkpoints remain intact.
- Verification: nine focused Godot component suites passed (`scene_inspector`, `hosted_defaults`, `agent_controller`, `chat_window`, `tools`, `context_budget`, `session_store`, `support_diagnostic_report`, `account_service`). Clean Godot 4.7.2 headless editor initialization, native live-scene editor regression and narrow editor UI/large-font checks passed. The 300px header stayed contained at 1× editor scale with 1×/1.5×/2× label fonts. Existing expected invalid-source and editor shutdown RID/ObjectDB diagnostics remain visible. Backend's real Godot/FastAPI/PostgreSQL fixture: **5 passed, no skips** via `tests/test_godot_client.py` with isolated fixture settings and `ORCA_DISABLE_ACCOUNT_RESTORE=1`; no live inference or owner authentication was used.
- The realistic bounded scene fixture reduced full-tools estimated input from **39,863 to 28,284 tokens**, retaining identical scene JSON values. Compact results permit safe no-tools finalization under the old 32k cap and normal tool continuation under the current 64k cap; large protected turns can still be denied honestly. A first test incorrectly expected the full-tools request itself to fit 32k and was corrected to verify these two distinct supported paths without lowering reserves.
- User chose **development repository only**. Runtime changes are `addons/orca/scripts/tools.gd`, `agent_controller.gd`, and `chat_window.gd`; copy the updated addon into the game project and reload Orca before checking a fresh unfinished-work request. Historical recovery cards remain historical. Live Luna task-quality acceptance and other platforms/editor scales were not exercised in this fix.

### 2026-10-28: Production Cloud origin cutover

- Switched the release-owned managed origin from localhost to `https://cloud.aiorca.dev`, with `/v1` API, `/activate` browser pairing and `/account` Console navigation. Managed provider-config reads ignore stale saved development URLs; the normal fixed-origin authorization and redirect denial remain enforced. Updated pairing failure copy and setup/test documentation.
- Retained origin-bound native-vault scopes/records without migrating local credentials. Upgrading requires fresh browser sign-in against the separate deployed account database. Added regressions for production URLs, confirmed noncanonical/downgraded endpoints, localhost credential isolation and actual EditorSettings cutover.
- Adapted the existing Godot/backend fixture only: its synthetic device-code reply uses the canonical browser URL, while test subclasses direct account and inference transport to the disposable localhost HTTP server. Production profile authorization, capability gates, full context, tool continuations and image policies still execute. No runtime development override was introduced.
- Verification on Godot 4.7.2: clean headless editor/plugin initialization and six focused suites (`account_service`, `endpoint_policy`, `provider`, `api_client`, `hosted_defaults`, `managed_settings_editor`) passed. Backend `tests/test_godot_client.py`: **5 passed, no skips**, covering full editor/Work context, four model-profile image/tool continuations, restore/rotation, receipts, private-state privacy, EOF/JSON/error/credit denial and logout. Tests used `ORCA_DISABLE_ACCOUNT_RESTORE=1`, synthetic inference and an ephemeral PostgreSQL 17.7 `orca_test` database; the test container was stopped/removed afterward. Managed editor teardown emitted the previously documented non-failing RID/ObjectDB diagnostics.
- Both production public health endpoints returned HTTP 200 with expected JSON through Godot's actual HTTPS `HTTPRequest`, with redirects disabled; the temporary smoke script was removed. This establishes Godot TLS/reachability, not authenticated pairing or live inference. `git diff --check` and replacement/test-project artifact checks passed. Production account/browser sign-in, live model requests and other platform acceptance remain manual; no owner credentials, production database, backend files or deployed services were changed.

Reproduce the focused checks with `GODOT_BIN` set to Godot 4.7.2:

```bash
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --editor --path . --quit
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --path . --script res://tests/account_service_test.gd
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --path . --script res://tests/endpoint_policy_test.gd
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --path . --script res://tests/provider_test.gd
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --path . --script res://tests/api_client_test.gd
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --path . --script res://tests/hosted_defaults_test.gd
ORCA_DISABLE_ACCOUNT_RESTORE=1 "$GODOT_BIN" --headless --editor --path . --script res://tests/managed_settings_editor_test.gd
```

From the backend repository, set `TEST_DATABASE_URL` to a disposable PostgreSQL database ending in `_test`, `GODOT_BIN`, and `ORCA_GODOT_PLUGIN_PATH` to this plugin repository, then run:

```bash
ORCA_ENV_FILE='' ORCA_RUNTIME_FILE='' ORCA_IDENTITY_ADAPTER=local ORCA_BILLING_ADAPTER=local ORCA_INFERENCE_ADAPTER=synthetic ORCA_DISABLE_ACCOUNT_RESTORE=1 uv run --no-sync pytest -q tests/test_godot_client.py
```

Next owner action: restart the updated editor, open **Settings → Account → Sign in / Sign up**, sign in/register on `cloud.aiorca.dev`, approve the matching editor code, and check the included model plus **Open Console**. Plugin metadata remains 1.3.0 Unreleased.

### 2026-10-28: User-owned plugin updates and release packaging

- Implemented the owner-approved daily stable GitHub release checks, validated persistent metadata/dismissal, a compact dock notice and About check/release/preferences/progress/cancel/confirmed update/rollback controls. The public updater works without an Orca account and exposes no model tool. Current editor requests/approvals, dirty scripts/scenes, game/account activity, drafts and failed conversation saving block restart.
- Added an exact official asset/digest and bounded ZIP/manifest/file-hash contract, executable-helper permissions, local-change/stale-hash/backup protection, exclusive project update locks and transactional replacement/recovery. The isolated `.orca-update` workspace is import/Git ignored and protected across agent tool paths, serialized dependency discovery and script references.
- A trusted independent Godot installer waits for the initiating editor to exit, installs or restores, retains one original addon and reopens the same project. The first prototype incorrectly used Godot's Unix child-only process API for a parent PID; actual acceptance caught it. Fixed signal-0 existence probing and positional-argument relaunch with detached private pipes now pass the real wait/replace/reopen fixture. Unknown/modified files are preserved; missing-addon interruptions have a retained manual recovery launcher.
- Added deterministic addon-only manifest/checksum packaging and a manual existing-tag workflow whose publish checkbox defaults off. Prepared source, workflows and documentation only; no GitHub Release/tag/commit/push or Asset Library submission occurred. Plugin metadata remains 1.3.0 Unreleased; the first updater-equipped official package must be installed manually once. Development checkouts without a release manifest are deliberately not overwritten by the updater.
- Verification: Godot 4.7.2 clean headless editor/plugin initialization; nine focused suites (`update_service`, `update_editor`, `plugin_lifecycle`, `chat_window`, `settings_view`, `tools`, `dependency_inspector`, `script_references`, `agent_controller`) passed. Six Python updater/package tests passed with no skips, including actual-source package validation, real HTTP redirect/download/failure/cancellation, unsafe ZIP/path/header/size/checksum cases, modified current/backup refusal, stale hashes, interrupted/missing-addon recovery, exclusive locking and an actual independent editor relaunch. Update UI checks use 280px width and 1.5×/2× fonts plus actual dirty script/scene state. Workflow YAML parsing and diff/artifact checks passed. Existing synthetic negative-control parse/errors and documented editor RID/ObjectDB/scan shutdown warnings remain visible.
- A separate read-only live Godot HTTPS request to the official GitHub API returned `up_to_date` for installed/latest stable 1.3.0. The temporary smoke script and disposable test projects/processes were removed. Tests use `ORCA_DISABLE_ACCOUNT_RESTORE=1` and `ORCA_DISABLE_UPDATE_CHECKS=1`; no owner credentials, hosted inference, payment, backend deployment or other project was changed.
- Remaining manual gates: actual GitHub workflow publication, graphical update/relaunch in a full user project, other editors of the same project, exhaustive OS termination/power-loss boundaries and macOS/Windows permissions/locks/process handling. A general public API does not enumerate every resource-inspector dirty state, so users save all editor work and close other editors before confirming. Detailed bounds, release commands and retained recovery invocation are in [`docs/UPDATES.md`](docs/UPDATES.md).

### 2026-10-28: Readable updater buttons and action regression

- Corrected the owner-reported two empty blocks in About: `clip_text=true` excluded caption width from each flow child's minimum size, collapsing Check for updates and What's new to padding. Flow actions now use their natural text minimums and wrap; full-width column actions retain their existing clipping. The same correction covers Update & Restart/What's new/Later in the main notice.
- Expanded `update_editor_test.gd` to reproduce the original failure using independent font/padding measurements, check complete caption containment at 280px with normal/1.5×/2× fonts, exercise the screenshot's up-to-date About state, and verify manual check/cancel, official notes navigation, confirmation-before-install and Later dismissal. A memory-only browser opener allows navigation assertions without external browser actions.
- Verification: corrected editor regression, `settings_view_test.gd`, `chat_window_test.gd`, and clean Godot 4.7.2 headless editor initialization passed. A native Linux/X11/OpenGL visual fixture showed both About and main-notice captions clearly; its script/image were removed afterward. Existing graphical progress-dialog and fixture teardown RID/ObjectDB diagnostics remain visible. Diff and replacement-artifact checks passed. Installation/transport behavior did not change; existing platform/relaunch acceptance gates remain documented above.

### 2026-10-28: Plugin updates in General Settings

- Moved the single settings update card from About to General Settings, below Language and a separator. The existing shared updater, main-window notice, check/progress/cancel/confirmation/rollback actions and installed-version About content retain their behavior. Updated current navigation/recovery guidance and architecture references.
- Settings/editor regressions verify one card, placement below Language, absence from About, updater identity and an active check surviving tab switches. The actual 300px settings view is checked with normal/1.5×/2× fonts and complete action captions; slightly tighter horizontal card insets keep the 2× layout within that width.
- Verification: `settings_view_test.gd`, `update_editor_test.gd`, `chat_window_test.gd`, clean Godot 4.7.2 headless editor initialization and diff/artifact checks passed. Tests suppressed owner account restore and automatic update checks. Existing editor-test teardown RID/ObjectDB diagnostics and chat synthetic failures remain visible. This relocation did not exercise another live installation or platform-specific relaunch; those manual acceptance gates remain in the updater documentation.

### 2026-10-29: Draft-preserving connection onboarding

- Implemented the approved in-dock welcome and shared setup-needed card, with Orca browser pairing, BYOK/local-provider setup and focused model navigation. Missing required keys/accounts/models are rejected before accepting a turn or reading reference source; no setup card enters session/model/support data and successful setup never sends automatically. Existing configured users retain ordinary chat, and keyless local profiles remain supported.
- Real-editor regressions caught native focus-loss deselection and CenterContainer squeezing wrapped welcome content. Public TextEdit selection preservation, viewport-bound welcome width and compact short-height layout correct both. Added the permanent editor test/UID/CI entry; synthetic controller/image fixtures now declare explicit test credentials where required by preflight. Early graphical fixture shutdown crashed during unsettled editor cleanup; settled startup/deferred teardown now exits normally, with existing editor-harness progress/RID/ObjectDB diagnostics still visible.
- Verification: ten focused component suites (`agent_controller`, `api_client`, `settings_view`, `chat_window`, `account_service`, `image_attachments`, `image_model_switch`, `image_intake`, `script_references`, `session_store`), five editor suites (`onboarding_editor`, `managed_settings_editor`, `provider_settings_editor`, `editor_ui_scale`, `plugin_lifecycle`) and clean Godot 4.7.2 headless editor/plugin initialization passed. Onboarding passed headless scale 1× and graphical Linux/X11/OpenGL scale 2×, including 300px normal/1.5×/2× action fonts and short-dock visibility. A synthetic rendered welcome/setup card was visually inspected; temporary preview assets were removed. Real browser/provider setup, light themes and other platforms remain manual acceptance. Plugin metadata stays 1.3.0 Unreleased.

### 2026-10-29: Original empty-state restoration and dismissible connection overlay

- Owner screenshots exposed a configured-user regression: wrapping the title while resetting the hidden welcome's width let CenterContainer collapse the normal content to a tiny column. Removed all onboarding children and typography/geometry overrides from the empty state, restoring its original title/description/mode hint and natural text-driven width.
- Owner selected **first visible open + setup-needed Send** for a separate dismissible overlay. Implemented conversation-only dimming, bounded centered card, Close/Escape/Set up later, one memory-only first-open decision after restoration, configured-user suppression and actual dock-opening notifications. Actions reuse existing Settings; the full draft and explicit-Send requirement remain. Overlay visibility never inserts history or replaces/resizes the original feed/composer. Narrow-height/large-font cases scroll within the overlay rather than widening the dock.
- Verification: four headless editor suites (`onboarding_editor`, `editor_ui_scale`, `plugin_lifecycle`, `managed_settings_editor`), six focused component suites (`chat_window`, `settings_view`, `image_intake`, `script_references`, `account_service`, `agent_controller`) and clean Godot 4.7.2 headless editor initialization passed. Onboarding also passed native Linux/X11/OpenGL at 2× scale, including configured-state width/typography and unchanged layout snapshots, first-open/restoration/dismissal/reopen, draft/Settings paths and 300px normal/1.5×/2× fonts. Original empty-state and first-open/Send overlay renders were visually inspected. The settled lifecycle fixture exposed restored-tab visibility consuming first-open intent; explicit opening now arms visibility tracking, and the corrected actual initial/re-enabled plugin checks pass. Existing editor-harness progress/RID/ObjectDB shutdown diagnostics remain; real browser/provider and other theme/platform acceptance remain manual. Temporary preview assets were removed; version remains 1.3.0 Unreleased.

### 2026-10-29: Cross-platform credential builds and complete release assembly

- Implemented a reusable/manual native Actions workflow for Linux/Windows x86_64 and macOS arm64/x86_64. Builds use native SDKs, a static Windows CRT and ad-hoc Mac signing; Windows pipes are LF-only binary and Mac storage uses current `SecItem` APIs with the original service/account identity. Tests and release preparation reuse the workflow, and every native job must pass before aggregate helpers/test ZIP or release assembly can proceed.
- Added fixed build/pinned-Godot/isolated acceptance scripts. Real Godot tests cover protocol bytes/limits, save/read/delete, two-helper lock serialization, and save/restore/rotation in separate Godot processes. Linux uses a private D-Bus/HOME/XDG vault; Mac restores an ephemeral default/search-list Keychain; Windows always erases its random synthetic scope. No owner credential, real Cloud request or inference is used, and native vault output is not logged.
- Packaging requires four correctly named/architectured helpers in release jobs, preserves executable ZIP modes, rejects unknown helper names and output inside the addon, and supports explicit source `--write-manifest` for commit-based Asset Library releases. Added assembly regressions and exact owner build/artifact/local packaging/commit/tag/manual publication documentation. Rebuilt the Linux helper locally. Version remains 1.3.0 Unreleased; prior work and the owner's existing test ZIP are retained.
- Verification: Linux isolated native acceptance passed all four stages; four native packaging tests and all six existing Python updater/package tests passed without skips, including actual-source archive validation and independent fixture editor relaunch. Account service, update service and update editor suites passed; clean Godot 4.7.2 headless editor/plugin initialization passed. Actionlint 1.7.12 validated all three workflows; Python syntax and diff/artifact checks passed. Existing update-editor shutdown RID/ObjectDB diagnostics remain visible.
- Read-only GitHub API confirmed repository Actions enabled with all actions allowed. No workflow push/dispatch, commit/tag/publication, backend change or owner authentication occurred. Next: owner pushes the source/workflows, lets Tests/native jobs run (manual dispatch appears after the workflow is on the default branch), and collects the complete test ZIP/helper bundle. Windows/macOS actual native jobs, downloaded-plugin/Asset Library permission checks, real Keychain prompts, Developer ID/notarization and full-project updater acceptance remain pending. This milestone completes local infrastructure, not cross-platform distribution acceptance.

### 2026-10-29: Orca 1.4.0 release-candidate preparation

- Bumped `addons/orca/plugin.cfg` to 1.4.0, prepared dated release-candidate notes, and updated current README/addon/product/security/update/development/test guidance. Account/provider choices, source/image references, live editor context, Foundry continuation, review UI, onboarding and update/build packaging are documented as 1.4.0 capabilities. Publication/native-platform acceptance remains explicitly pending; historical 1.3.0 milestones and upgrade/rollback fixtures retain their versions.
- Updated the two About/support-report expectations that depend on the actual plugin version. Runtime About/updater/packaging version reads already use `plugin.cfg`; no permission, transport, credential, updater or model-tool behavior was changed for release preparation.
- Verification on Godot 4.7.2: all **42 component suites**, **9 headless editor suites** and **7 localhost transport integrations** listed in `.github/workflows/tests.yml` passed. All **10 Python updater/native-packaging tests** passed without skips, including actual-source 1.4.0 archive validation, independent fixture editor relaunch and complete-platform/manifest checks. Isolated Linux native protocol/vault/locking/cross-Godot-process persistence passed all four stages. Clean headless editor/plugin initialization, Actionlint 1.7.12, Python syntax, current documentation references and diff/artifact checks passed. Expected invalid-source/synthetic-provider fixtures and known non-failing editor shutdown RID/ObjectDB/scan diagnostics remain visible.
- Tests used `ORCA_DISABLE_ACCOUNT_RESTORE=1` and `ORCA_DISABLE_UPDATE_CHECKS=1`; native/updater projects were disposable and no live inference, backend service or owner account was used. Graphical full-project updater relaunch, new Windows/macOS native jobs/downloaded-package acceptance, actual browser/model workflows and Asset Library installation remain owner/platform gates. All changes remain uncommitted; no staging/commit/push/tag/publication occurred. The owner's existing test ZIP was not replaced. Next: owner reviews and pushes the complete candidate source, accepts GitHub native/full Tests results, then prepares the final release/Asset Library commit and tag as documented in `docs/UPDATES.md`.

### 2026-10-29: Release CI artifact discovery and display-free updater correction

- Investigated [Tests run #42](https://github.com/cold-atom/Orca/actions/runs/40904709816) for candidate commit `c59c965`. All four native builds and their real vault/protocol/locking/cross-Godot-process tests passed. The later package artifact upload failed because wildcard discovery excluded `.ci`, and the updater round-trip installed successfully but tried a graphical editor on a display-free runner.
- Added narrowly scoped hidden-file discovery to the package upload. Replaced consumed `--headless` argument detection with the public actual display backend in updater handoff. The restart fixture now removes inherited X11/Wayland display variables and checks the newly installed plugin's reported headless backend/PID. The original display-free failure was reproduced before changing runtime behavior; permission, approval, hash, archive, transaction and rollback contracts are retained.
- Verification: all six Python updater/package tests and four native packaging tests passed with no skips on Godot 4.7.2, including independent wait/replace/reopen with no display. Update service and editor suites passed; clean headless editor/plugin initialization, Actionlint 1.7.12 for all three workflows and diff/artifact checks passed. Existing update-editor teardown RID/ObjectDB diagnostics remain visible. Tests suppressed owner account restore and update checks and used disposable updater projects. Full graphical/platform updater acceptance and the corrected GitHub upload remain pending a new owner-pushed complete CI run.

### 2026-10-30: Binary-free plugin distribution and verified native-helper installation

- Retained all four native compilation/vault acceptance jobs, split bundling/publication into a binary-free addon ZIP/checksum and exact separate raw helper assets, and generated a version/size/SHA-256 catalog from those tested bytes. Compiled helper build products are ignored/export-excluded; the tracked Linux executable was removed. Existing source catalogs cannot silently drift from rebuilt assets.
- Added plugin-owned helper installation through Account **Install & continue**, with public exact-release downloads, bounded redirects/deadline, native/hash verification, content-addressed external user cache, atomic install locking, cancellation/teardown and per-launch revalidation. Browser pairing follows only the surviving explicit install intent. BYOK/local providers and startup require no download. Vault identity/pipes/refresh locking, model permissions and updater file/rollback safeguards are retained.
- Verification: clean Godot 4.7.2 headless editor initialization; eight native packaging tests; catalog/native-header suite; fourteen real HTTP/cache/account scenarios (including redirect/hash/size/disconnect/cancel/teardown/synchronous cancellation); native-helper editor disclosure/progress/navigation/larger-font suite; isolated rebuilt Linux helper vault round-trip/locking and separate-Godot-process save/restore/erase; seven updater/package tests including legacy bundled-helper rollback; account, API, controller, settings, hosted-defaults, chat, update service/editor, onboarding and plugin lifecycle suites; Actionlint 1.7.12 for all three workflows; diff and temporary-artifact checks. Fixtures suppressed owner restoration/update checks and used disposable caches/projects/private vaults. Existing editor-suite shutdown RID/ObjectDB diagnostics remain visible; ordinary initialization is clean.
- Updated public addon/product/security/release/testing guidance. No commit/push/tag/workflow dispatch/publication or Asset Store submission occurred. Next: owner selects a new version/tag, runs complete CI and publishes the ZIP plus its matching helpers; verify actual GitHub downloads, Windows/macOS prompts/execution, graphical full-project update and actual Store ZIP/snapshot acceptance. The reviewer must confirm the post-install component flow; prior Store downloads and thumbnail correction remain owner moderation work.

### 2026-10-30: Seamless background native-helper preparation

- Replaced the extra Account install prompt with quiet plugin-enable preparation. The existing account/BYOK onboarding remains; early explicit Cloud sign-in waits with **Preparing connection…**, repeated clicks coalesce, and Cancel/navigation invalidates only that sign-in intent. Preparation continues independently for BYOK/dock use and cannot open a browser by itself. Plugin disable/shutdown cancels downloads and waiters.
- Added single-flight preparation, three bounded transient attempts, deadline-clamped backoff/lock polling and reuse of a cooperating editor's verified installation. Saved-account restoration waits once for readiness under the existing generation/scope checks. Returning Cloud-model hints defer first-open onboarding until restoration settles, while fresh onboarding remains available. Exact catalog/URL/hash/native/path/cache protections and binary-free packaging remain intact. Ordinary tests/workflows now also set `ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1`; isolated background fixtures opt in through test subclasses only.
- Verification on Godot 4.7.2: clean headless editor initialization; 23 real HTTP/background/account scenarios, including startup, early/cancelled sign-in, retries/exhaustion, normal sign-in retry, cooperating cache installation, saved/missing/cancelled restoration and teardown; catalog/header/deadline/retry-cancel component tests; no-helper-UI/narrow Account status editor suite; updated onboarding, plugin lifecycle and updater editor suites; eight native packaging and seven updater/package tests; isolated rebuilt Linux vault round-trip/locking and separate-Godot-process persistence; account, API, controller, chat, hosted-defaults, settings and update service suites; Actionlint 1.7.12 and diff/artifact checks. Existing editor-suite shutdown RID/ObjectDB diagnostics remain visible. Owner authentication, live inference and public helper downloads were suppressed in ordinary fixtures.
- Updated product/addon/security/release/test guidance for automatic preparation. No commit/push/tag/publication or Store submission occurred. New official Release assets/catalogs, actual Store installation, graphical/full-project relaunch and Windows/macOS downloaded-helper execution/prompts remain owner/platform acceptance gates.

### 2026-10-30: Orca 1.4.1 packaging-fix release preparation

- Prepared 1.4.1 plugin/About/support-report metadata and current release/setup/security/test guidance after the GitHub-published 1.4.0 package was rejected by the Godot Asset Store for bundled executables. The concise changelog records only the packaging/helper-delivery follow-up and links to 1.4.0 for the full feature list. Historical entries and synthetic version fixtures retain their versions. Existing v1.4.0 GitHub tag/assets are not replaced.
- Release notes now link directly to `CHANGELOG.md` at the selected tag. Build/archive/catalog naming remains derived from `plugin.cfg`. Extended update metadata checks verify 1.4.1 is newer than both 1.3.0 and 1.4.0, while an installed 1.4.1 receives no same-version update. Project permissions, approvals, vault scope and update protections are retained.
- Verification on Godot 4.7.2: clean `--headless --editor --path . --quit`; `settings_view_test.gd`, `support_diagnostic_report_test.gd`, `update_service_test.gd`, `native_helper_service_test.gd`, `update_editor_test.gd` and `native_helper_editor_test.gd` passed. All eight `native_helper_packaging_test.py` and seven `update_package_test.py` tests passed without skips, including actual-source 1.4.1 manifest validation, historical install/rollback and independent display-free editor relaunch. Actionlint 1.7.12 for all three workflows and diff/artifact checks passed. Tests set `ORCA_DISABLE_ACCOUNT_RESTORE=1`, `ORCA_DISABLE_UPDATE_CHECKS=1`, `ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1`; Python tests used disposable `/tmp/opencode` projects with bytecode writing disabled. Existing editor-fixture shutdown RID/ObjectDB diagnostics remain; ordinary initialization is clean.
- Publication, complete 1.4.1 native CI/package/catalog generation, real downloaded-helper/platform acceptance and Store approval remain pending owner actions. Reviewer confirmation of post-install downloads, corrected thumbnail and previous affected Store downloads remain separate. No commit, push, tag, workflow dispatch, published-release edit or Store submission occurred.

### 2026-10-30: Editor-scale synthetic usage refresh race correction

- Read-only inspection of [Tests run #49](https://github.com/cold-atom/Orca/actions/runs/41042858660), commit `502d838`, confirmed successful four-platform native acceptance, binary-free packaging/artifact uploads and component tests. Editor integration stopped at two request-estimate tooltip assertions; subsequent editor/localhost/final checks were skipped.
- The test injected a synthetic blocked-request summary directly into the UI, but normal asynchronous model-metadata completion refreshed the real idle controller and replaced it during deferred font sizing. Forcing the deferred metadata signal reproduced the zero-usage tooltip failure before the correction. The fixture now disconnects only its controller-to-UI usage callback while measuring synthetic data, forces the race at every 1×/1.5×/2× font size, retains strict tooltip/containment assertions, reconnects and verifies subsequent signal delivery. Production request/usage/tooltip behavior and permissions are unchanged.
- Verification on Godot 4.7.2 with all three startup suppressions: `--headless --editor --path . --script res://tests/editor_ui_scale_test.gd` passed with the forced race; all nine remaining editor suites in `.github/workflows/tests.yml` passed in their existing order. `--headless --path . --script res://tests/chat_window_test.gd` and clean `--headless --editor --path . --quit` passed. Diff and replacement-artifact checks passed. Existing editor-fixture RID/ObjectDB/scan shutdown diagnostics remain visible; ordinary initialization is clean. No owner authentication, native-helper download or live inference was used. Graphical/platform checks and localhost transport suites were not rerun for this fixture-only correction.
- Correction and verification guidance remain local/uncommitted. The owner must push it for a new complete CI run before tagging/preparing 1.4.1; rerunning `502d838` retains the race. No commit, push, tag, workflow dispatch or release publication occurred in this correction.

## Handoff Checklist

Before another agent takes over, it should be able to answer:

- What user problem is currently being solved?
- Which architecture and safety invariants are involved?
- What code paths and tool schemas will change?
- How will Plan and Work differ after the change?
- What success, failure, cancellation, and stale-state paths need testing?
- What can be verified automatically and what still requires manual editor testing?
- Which known limitation or roadmap item changes when the task is complete?

At handoff, record the result, affected files, verification, residual risk, and next recommended action.
