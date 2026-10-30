# Changelog

All notable changes to Orca are documented in this file.

## Unreleased

## 1.4.1 - 2026-10-30

Packaging follow-up to [1.4.0](#140---2026-10-29), which was published on GitHub
but rejected by the Godot Asset Store because its ZIP included compiled executables.
This release candidate retains the 1.4.0 features; users upgrading from 1.3.0 should
read that entry for the full feature list. GitHub publication and Asset Store
approval of 1.4.1 remain pending.

### Fixed

- Plugin ZIPs and Git source exports exclude compiled native helpers. Release builds publish the four platform helpers separately alongside the plugin ZIP/checksum, with an exact version/size/SHA-256 catalog generated from the tested assets.
- Orca quietly downloads and verifies a missing platform helper on plugin enable, caching it outside projects/addons. Early Cloud sign-in waits with **Preparing connection…**; BYOK/local providers remain usable. Saved-account restoration waits for readiness, retries are bounded, and plugin shutdown cancels preparation.
- GitHub release notes now link **Full Changelog** directly to the released version's `CHANGELOG.md`.

### Changed

- Plugin/About/support-report metadata and release guidance now identify 1.4.1, giving existing 1.4.0 GitHub installations a newer version without replacing published assets. Godot Asset Store users can upgrade directly from 1.3.0.

## 1.4.0 - 2026-10-29

Published on GitHub; the Godot Asset Store submission was rejected for bundled
compiled executables. See [1.4.1](#141---2026-10-30) for the packaging follow-up.
The entries below describe the original 1.4.0 release.

### Added

- Native GitHub Actions builds for Linux/Windows x86_64 and macOS arm64/x86_64, real isolated vault/protocol/locking/cross-Godot-process acceptance, aggregate helper downloads and a complete versioned plugin ZIP. Release preparation requires all four tested builds and packages them together.
- Strict complete-platform packaging checks and explicit `--write-manifest` generation for commit-based Godot Asset Library releases, with documented Actions download/local build/manual publication steps.
- Dismissible in-dock connection overlay with **Sign in / Sign up with Orca**, **Bring your own API key** (including local models), Close and **Set up later**. New unconfigured users see it on their first visible dock opening after account restoration; setup-needed Send reopens it. Drafts remain intact and actions use existing Account/Provider Settings.
- Connection/account/model preflight before turn activation, referenced-source reads or conversation entries, with distinct restoration feedback and keyless-local support. Setup completion never automatically sends the draft; composer selection survives settings navigation.
- Daily stable GitHub release checks, a cached dismissible dock update notice, and General Settings manual checking, release notes, automatic-check preference, progress/cancellation and explicit Update & Restart/rollback controls.
- Bounded official ZIP/file-manifest verification, local-change/stale-hash protection, a project-exclusive updater lock, transactional replacement and a retained verified previous addon. A trusted independent Godot installer waits for editor exit and reopens the same project; a standalone recovery launcher handles missing-addon interruptions.
- Deterministic addon-only release packaging with an embedded update manifest and checksum, plus a manually dispatched existing-tag package/publish workflow. Existing users install the first updater-equipped package manually once.
- Account settings tab after System using the supplied profile icon; browser sign-up/sign-in, pairing feedback/cancellation, plan/usage, Console navigation and sign-out.
- Persistent Orca account connection using a native OS-vault helper and cross-editor refresh locking. Linux x86_64 is packaged/verified; other platform builds remain pending.
- Managed Orca Cloud provider with an authenticated model catalog, strict metered SSE/idempotency/turn-binding transport, capability-bound Agent checks and private Sol continuation.

- Drag project `.gd` scripts from Godot's FileSystem dock or open-script list into the composer as removable reference chips. Send includes bounded saved/active-unsaved source snapshots for text-only and Chat-only models, retains references with each message/history, and preserves drafts on preflight or pre-tool provider failures. Up to four scripts are supported alongside images; source is capped at 300 lines / 16 KiB per script.
- Press Tab in the focused prompt box to toggle Plan/Work without changing the draft, selection, caret, or attachments. Held-key repeats are ignored, active turns/approvals and view-only sessions stay locked, and modified Tab retains native behavior. The mode tooltip includes the shortcut.
- Native code minimaps in both expanded Previous/Proposed diff panes, with click/drag navigation, synchronized scrolling, editor-scaled adaptive widths, GDScript syntax colors, and refined pane frames. Narrow resized review windows stack the panes.
- One-click **Test & Enable Agent tools**: a successful user-started compatibility check automatically enables the exact profile. The toggle still permits manual opt-out; failure, cancellation, changed profiles, duplicate results, and restored disabled passes do not enable tools.
- Microsoft Foundry / Azure profile with exact deployment names, Responses/Chat Completions selection, explicit reasoning effort, and DeepSeek Chat continuation settings. Generic OpenAI-compatible requests also support explicit reasoning effort, including `none` for tool-enabled GPT deployments that reject default reasoning on Chat Completions.
- Stateless streamed Responses API transport with bounded Orca function calls, multimodal inputs, usage normalization, no-tools finalization, and active-turn encrypted reasoning/assistant-phase replay. Requests disable server storage and automatic truncation; internal continuation state is removed at turn end and excluded from saved sessions.
- Assistant response footers show the full configured model identifier and the generating request's Plan/Work mode using Orca's metadata typography and existing mode accents. Attribution stays accurate through model switches, tool follow-ups, interrupted text, and restored history; legacy answers and local reports are not guessed.
- Read-only live editor scene inspection for selected nodes, current scene hierarchy, or one subtree, including unsaved node additions and property changes. Supports bounded native UI layout, 2D/3D transforms, visibility/processing values, parent Control/Container context, and script/resource identities.
- Explicit live-editor provenance, optional expected-scene binding, and bounded/truncated results without a disk patch hash. Live activity groups retain only historical query summaries; saved-scene inspection and mutation guards remain enforced.

### Changed

- Complete native build downloads now use the `orca-package` artifact with `orca-v<version>.zip` and checksum filenames read from `plugin.cfg`, matching release naming without a test suffix.
- Plugin update controls now live below Language in General Settings. About retains product/version information, links and support; the main-window update notice remains available.
- Orca Cloud now uses the fixed production HTTPS origin `https://cloud.aiorca.dev` for accounts, browser pairing, Console and the `/v1` API. Managed settings ignore stale saved localhost URLs. Origin-bound credentials require fresh sign-in after upgrading from local development.

### Fixed

- Windows helper pipes now explicitly use LF-only binary mode to match the Godot wrapper. macOS uses current `SecItem` Keychain APIs while preserving the existing service/account record identity; Mac builds are ad-hoc signed, not notarized.
- Restored the original empty-state title, logo, typography and centered text width after onboarding caused configured users' text to collapse into a narrow vertical column. Setup now lives outside the chat feed, preserves its layout, and leaves the composer available. Dismissal and returning from incomplete setup do not reopen it automatically.
- Update action buttons display their captions instead of collapsing into blank blocks. About and main-notice actions use text-sized flow layout with wrapping, with readability and click-handler regressions for narrow/larger-font views.
- Managed models now work after account connection/model selection without subscriber compatibility probes or reasoning configuration; operator-verified capabilities retain runtime origin/account/version and project-approval protections.
- Fresh hosted greetings no longer fail because UTF-8 byte-based billing reserves were treated as context token limits. Full root instructions/editor context/Work schemas are now exercised by the integration regression; billing remains conservatively reserved separately.

- Azure DeepSeek compatibility handles the observed leaked leading `</think>` delimiter consistently in Chat/Responses streaming and JSON output. Exactly one bounded leading marker is consumed only with explicit DeepSeek compatibility; inline/code markup, repeated markers, wrong challenges, and unrelated profiles retain strict behavior.
- The Azure Reasoning Continuation selector is available for both APIs. DeepSeek Responses preserves bounded private plain reasoning parts through tool follow-ups, budgets them, and excludes them from visible/stored history. Scoped format-version binding requires older DeepSeek passes to retest without invalidating Standard/GPT passes.
- Preserve Azure API/continuation selections when saving during provider switches, and refresh compatibility state immediately after URL edits. Explicit check/enable intent is bound to the selected profile and credentials through origin confirmation and discarded if they change.
- Compatibility checks now bind API mode and continuation style. Azure DeepSeek Chat can explicitly retain `reasoning_content` across tool follow-ups, including custom deployment names. Failed final acknowledgements distinguish extra formatting from changed/missing acknowledgement and show a bounded synthetic reply with the original challenge redacted.
- Conversations with earlier images can now switch between vision-capable and text-only models in either direction. Text-only requests retain conversation text and prior descriptions with explicit historical-image placeholders; original images/previews remain intact and are sent again when retained context returns to a vision model.
- Image handling is bound to each active turn, and context budgeting counts the projected request without charging omitted image reserves. New unsupported draft images remain rejected and preserved; model switching feedback is a non-blocking image-action tooltip instead of a conversation-wide error.
- LM Studio, Ollama, and Local OpenAI-compatible requests now combine Orca's system instructions and refreshed context into one leading system message. This addresses templates that reject follow-up chats or tool continuations with `System message must be at the beginning`, while preserving conversation/tool order and controller-owned history.
- Agent Compatibility now exercises a fixed, project-free system-context refresh after its synthetic tool result. Probe version 2 requires older editable/overridden-profile passes to be retested and explicitly re-enabled before tools are available.

### Tests

- Updated About-page and privacy-safe support-report expectations for plugin version 1.4.0. Historical 1.3.0 → 1.4.0 updater fixtures remain explicit upgrade/rollback tests.
- Added controller setup denial and real-editor overlay/Settings/pairing/BYOK/model-selection/draft/no-request regressions, including configured empty-state width/typography, unchanged feed/composer snapshots, first-visible-open/restoration waiting, Close/Escape/Later and hide/reopen, actual plugin opening notifications and 300px normal/1.5×/2× fonts. Fixtures isolate provider credentials, suppress account restoration/update checks and restore preferences.
- Added update service/metadata/preference/cancellation, actual dirty-editor/workflow/confirmation/narrow-font, archive/path/hash/permission/locking/recovery and real HTTP failure/cancel regressions. Disposable-project acceptance verifies the independent wait/replace/reopen process and validates an actual-source release package without executing downloaded scripts.
- Added production pairing/Console URL, managed endpoint protection, localhost credential isolation and saved-settings cutover regressions. Adapted the Godot/backend integration's test-only transport to stay on disposable localhost HTTP with the production default.
- Added script-reference validation/preparation, UTF-8 boundaries, canonical history/projection/budget/compaction, Chat/Responses and mixed-image transport, real tool continuation, persistence/redaction, forced Control drag routing, draft recovery, and narrow chip coverage. Real editor tests cover exact active unsaved source, inactive dirty denial, script-list identity, unchanged disk/dirty state, image/checklist layout, and Tab preservation. The existing two-request image SSE fixture now requires exact script source on both requests.
- Expanded editor review coverage for long/unequal/empty content, preserved read-only text/highlights, synchronized navigation, responsive layouts, extreme splitter limits, and larger fonts. The same suite verifies actual native minimap click/drag on a display; headless mode checks layout/programmatic scrolling. Linux/X11/OpenGL passed at 2× editor scale, with a rendered synthetic GDScript review visually inspected.
- Added delimiter split/limit/literal/parity/cancellation, plain-reasoning replay/isolation/bounds/budget/session-redaction, scoped binding, and 13-request localhost Chat/Responses SSE/JSON probe regressions. Exact wrong-acknowledgement and Standard-profile negative controls remain denied.
- Added real EditorSettings/UI coverage for combined enablement across local/custom/Azure profiles, manual disable/restoration, duplicate/stale results, failure/cancellation, profile/credential/API/style drift, and cancelled/unchanged origin confirmation.
- Added Responses conversion, output bounds/status/refusal/call identity, byte-fragmented SSE, reasoning isolation, API/style binding, context accounting, controller cleanup, session redaction, settings persistence/narrow layout, and 15-request localhost integration. Covers the Azure 400 negative control, explicit `none`, real synthetic Responses probe, image/multi-tool/no-tools continuation, JSON fallback, incomplete/error/disconnect/Stop, and DeepSeek reasoning retention. No live Azure inference gate was exercised.
- Added bounded model/mode metadata, terminal reentry, stale callback, Plan-to-Work refresh, plain/code footer, interrupted/restored answer, and legacy omission regressions. Real editor layout checks cover long IDs and normal/1.5×/2× metadata fonts without mode overlap or dock widening.
- Added model-switch/projection/budget/compaction/restoration/cancellation/failure/draft regressions and expanded the image HTTP/SSE fixture to ten requests, including repeated text → vision → text → vision transitions, exact image-byte retention, matching tool continuations, and pixel-free text-only payloads.
- Added native-getter isolation, argument/path/reference/internal-node boundaries, selection/depth/node/output/time limits, and real-editor unsaved-state regressions. Added a deterministic menu inspect/save/review/Apply/reinspect/Revert workflow and live-activity history redaction checks.
- Added local-provider message-layout, source-history isolation, multimodal/opaque tool metadata preservation, and old-probe permission regressions.
- Added a strict localhost template fixture that rejects the original layout with HTTP 500 and accepts second user turns, tool continuations, and no-tools finalization for all three local profiles. The existing probe integration now also enforces one leading system message and retained synthetic refresh context.

### Known Limits

- Linux native-vault and headless updater installation/rollback/relaunch are verified. Windows/macOS native CI execution and downloaded-plugin/update acceptance remain pending. Mac helpers are ad-hoc signed, not Developer ID signed or notarized.
- The first updater-equipped package must be installed manually once. Updates require explicit user confirmation and preserve locally modified addons. Commit-based Asset Library downloads need the tested helper binaries and matching generated manifest in the selected release commit.
- Vision/tool capability declarations and synthetic compatibility probes do not establish model quality. Live model/project workflows, actual script-list mouse dragging, OS clipboard behavior and broader theme/platform acceptance remain separate checks.
- Desktop images still use the separate native attachment window; dropping them onto the main editor invokes Godot import. Private reasoning and revert checkpoints remain active-turn/in-memory only, respectively.

## 1.3.0 - 2026-10-13

### Added

- Image attachments for vision-capable models: PNG, JPEG, and WebP still images, up to four per message, with floating thumbnails, removal, larger previews, and previews in submitted/restored messages.
- Image clipboard Paste through keyboard shortcuts and the context menu, plus existing project-image drag-and-drop from Godot's FileSystem dock.
- A separate native attachment window with desktop drag-and-drop and Browse, keeping attachments outside project files.
- Model/endpoint-specific supported, unsupported, and unknown image capability, with an explicit exact-profile setting for unconfirmed input support independent of Agent tools.
- Multimodal Chat Completions requests, conservative image context reserves, and deduplicated project-scoped conversation image persistence.
- A System settings section with English shown as the sole supported language.
- About-page links to Orca documentation, website, GitHub, issue reporting, and community feature discussions.

### Changed

- Replaced Settings text tabs with neutral icon-based Provider, System, and About navigation, tooltips, and keyboard focus.
- Balanced image and Send artwork at the same 22 px editor-scaled size and made unavailable image input visibly dimmed and non-clickable.
- Draft attachments float above the composer without shrinking the conversation or moving the input; individual thumbnail frames use a transparent surrounding surface.
- Image preparation checks bounded source headers before decoding, normalizes metadata-free PNG data, and caps prepared images at 2048 pixels per side and 1 MiB each.
- Saved conversations retain at most 32 unique images / 8 MiB decoded image data within a 16 MiB session JSON limit; missing or corrupt image references make restoration view-only.
- DeepSeek image support is model-specific: current Flash supports vision, while Pro and legacy Chat/Reasoner have text-only fallbacks on the canonical endpoint.

### Fixed

- Fixed attachment trays stretching across the dock during deferred editor layout.
- Fixed About link descriptions overflowing their clickable backgrounds and overlapping adjacent rows under editor fonts; content drives row height and descriptions wrap.
- Guarded attachment-window intake against changed sessions, unsupported profiles, modal/hidden views, and late selections after close while preserving existing drafts.

### Tests

- Added preparation/corruption, model capability, budgeting, persistence/deletion, draft lifecycle, clipboard/text undo, atomic intake, and real Control drag-routing regressions.
- Added real localhost multimodal SSE transport coverage retaining image context across a tool continuation.
- Added a Linux/X11 native desktop-drop fixture verifying accepted/rejected transfers and cancelled late intake with zero project-file changes.
- Expanded editor layout checks for thumbnail overlays, matching icon sizes, unavailable controls, and About link containment at normal, 1.5×, and 2× font sizes.

### Known Limits

- Desktop images must be dropped into Orca's separate attachment window. Files dropped directly onto the main Godot editor/dock still invoke Godot's import handler; seamless cancellable routing is future work.
- Native desktop-drop isolation was verified on Linux/X11/Vulkan. Other platforms/renderers, detached editor windows, and real OS clipboard behavior need further acceptance testing.
- Image capability metadata and explicit overrides do not establish live-model vision quality. No new live-provider vision gate was run for this release preparation; the previously documented selected-model Gemini continuation risk remains unresolved.
- Document/PDF attachment, OCR, automated screenshots, and additional UI languages are not included. Pending draft attachments remain memory-only; submitted images are plaintext local conversation data and are sent to the selected AI endpoint with the request.

## 1.2.1 - 2026-10-07

### Changed

- Provider responses must now contain visible non-whitespace assistant text or at least one valid tool call; empty, whitespace-only, reasoning-only, usage-only, truncated, filtered, and contradictory completions fail visibly instead of silently ending a turn.
- Active provider generation now has a ten-minute total deadline in addition to the existing connection and inactivity timeouts.
- The total generation deadline is preserved across connection and `stream_options` compatibility retries; deterministic localhost coverage keeps the stream active while proving the original deadline still wins.
- Tool-loop finalization now has a distinct `Finalizing safely` state, retains the safety trigger reason, explains denied post-finalization tool calls accurately, and gives explicit non-replay continuation guidance.
- Raw file patches now verify retained proposal integrity before Apply and reread, hash-check, and revalidate exact destination bytes after replacement.
- Verified replacement now has explicit not-committed, committed, committed-with-cleanup-warning, and recovery-failure outcomes across file, scene, Input Map, main-scene, and ProjectSettings mutations.
- The About page can copy a strict-allowlist diagnostic report containing Orca/Godot versions and coarse provider/request state without credentials, endpoint addresses, project data, conversation content, model output, logs, or file changes.
- Plan turns can request one explicit, turn-bound transition to Work mode when the user asked for implementation or execution. Approval continues the same task with Work tools on the next provider request; rejection remains in Plan, and every project mutation still requires its normal separate approval.
- Runtime loop detection now ignores elapsed-time and observation-cursor churn, warns before the tool-round boundary, gives each observation a recommended next action, and performs one controller-owned cleanup of an exact same-turn Orca process before safe finalization.
- `stop_game` now returns bounded final run output, diagnostics, state, and verification evidence so routine cleanup does not require another diagnostics round.
- Multi-call tool batches are now limited to known independent read-only operations. Work-mode requests, task updates, reviewed mutations, process control, observations, verifications, and unknown tools require singleton batches and are rejected atomically otherwise.
- Successful task updates now refresh exactly one request-scoped checklist before continuation or finalization, while failed and cleared updates preserve or remove that context correctly.
- Completed tool turns that exceed the full-schema context budget now attempt one no-tools safe finalization; if that cannot fit, Orca emits a deterministic sanitized local checkpoint containing only bounded receipts, tasks, and coarse cleanup outcome.
- Automatic finalization cleanup is now bound to the exact active run ID launched in that turn, exposes only a fixed coarse outcome, and cannot stop a newer replacement run. Bounded `stop_game` evidence explicitly labels omitted diagnostics and truncated output tails.

### Fixed

- Fixed DeepSeek-compatible reasoning-only or empty completions removing the working state without displaying an answer or error.
- Fixed empty tool-loop finalization responses ending without a visible outcome.
- Fixed file-patch recovery states hiding the guarded Revert action.
- Fixed committed writes being reported as failed when private-backup cleanup failed, and fixed uncertain replacement failures being reported or persisted as successful mutations.
- Cleanup-only warnings no longer weaken typed live-state conflict checks; recovery-copy guidance is retained as bounded project-relative session metadata.
- Fixed delayed stream and terminal callbacks from an older provider request being able to mutate a newer controller turn or chat UI state. Tool follow-ups now receive distinct provider request IDs while retaining one turn ID.
- Fixed synchronous workflow and terminal signal handlers being able to launch an orphan request or have an ending turn clear ownership belonging to a reentrantly started turn.
- Fixed plain Enter being silently swallowed while a request is active; follow-up drafts now remain editable and survive matching completion, failure, and cancellation while Stop remains explicit.
- Fixed Expanded Diff retaining exclusive window ownership while Apply or Reject synchronously triggered editor work, which could collide with Godot reload or confirmation dialogs.

### Tests

- Added empty, whitespace-only, reasoning-only, tool-only, truncated, filtered, and terminal-ownership transport regressions.
- Added real GDScript patch lifecycle coverage and exact duplicate class/local variable validation regressions.
- Added tool-loop trigger, finalization-state, denied-provider-text, explicit-continuation, and empty-finalization coverage.
- Added deterministic replacement, restoration, temporary-cleanup, post-write verification, cleanup-warning, recovery-classification, and retry-deadline fault coverage.
- Added transport, compatibility-probe, controller, and chat-window ownership regressions for stale and duplicate callbacks, follow-up identity, cancellation, and synchronous configuration failures.
- Added thinking/finalizing cancellation, terminal reentry, duplicate history/usage/message, and stale second-step probe failure/cancellation regressions.
- Added active-composer, real Stop-button, draft-preservation, stale-control-state, request diagnostic lifecycle, and adversarial diagnostic privacy regressions.
- Added Plan-to-Work schema, approval, rejection, cancellation, stale-decision, one-request, mixed-batch permission, protocol-ordering, session-redaction, and narrow-card regressions.
- Added real-shaped volatile-observation, semantic-progress, early round-budget, exact-process cleanup, and bounded stop-evidence regressions.
- Added successful read-only batching, singleton-only category, unknown-tool, mixed escalation, atomic rejection, and correction-request regressions.
- Added checklist refresh/finalization, context-pressure fallback, complete inspect/fix/run/fail/stop/reread/fix/rerun/pass orchestration, exact cleanup ownership/privacy, stop-evidence truncation, and expanded-dialog ownership regressions.

## 1.2.0 - 2026-10-05

### Added

- Added first-class Ollama, LM Studio, and Local OpenAI-compatible profiles with editable conventional endpoints, optional bearer authentication, explicit keyless model discovery, and manual Model ID fallback.
- Added native Ollama `/api/tags` and LM Studio `/api/v1/models` discovery with bounded model metadata and filtering for models identified as embeddings.
- Added strict endpoint normalization, loopback/LAN/remote disclosure, exact-origin confirmation, and generated-endpoint validation for editable profiles and provider origin overrides.
- Added an isolated project-free two-step function-call compatibility probe and separate Agent-tool opt-in bound to the exact provider, origin, endpoints, model, reasoning configuration, and probe version.
- Added permanent Godot 4.7.2 editor integration coverage for dirty scripts and scenes, exact unsaved source, diagnostics logging, editor scaling, and plugin enable/disable/re-enable ownership.

### Changed

- Local and editable profiles now start in Chat mode and expose Agent tools only after a matching compatibility pass and explicit user enablement.
- Provider discovery now uses bounded endpoint- and credential-aware caches; the normalized cache format was advanced to v3 for native local-provider metadata and stronger sanitation.
- Unsaved focused GDScript reads now use the exact current editor text, while reviewed file paths are canonicalized before editor-state, hash, revert, and write checks.
- Diagnostics services now share one reference-counted Godot logger, preserve warning severity, deep-copy caller records, and bound retained fields.

### Fixed

- Fixed normalized path aliases and dirty editor buffers bypassing reviewed edit or revert protections.
- Fixed duplicate diagnostics and resource loading from logger callbacks during plugin reload and fallback-service ownership.
- Fixed native Ollama and LM Studio discovery exposing known embedding-only models while preserving unrestricted manual Model ID override.
- Fixed stale discovery-request ownership and programmatic model selection clearing or replacing the active local model list.
- Added bounded plain provider-error extraction and detection when a local endpoint silently serves a different model; Orca now returns `model_mismatch` before emitting assistant text.
- Fixed editable-provider Settings controls widening narrow docks and clipping the Done, About, and model actions.

### Security And Privacy

- Editable non-loopback endpoints require confirmation bound to normalized scheme, host, and effective port; endpoint drift invalidates prior confirmation.
- Chat and discovery reauthorize endpoint trust before credential headers are constructed and reject provider redirects.
- Compatibility probes contain no project instructions, skills, editor context, task list, session history, project path, or real Orca tool schema.
- Compatibility passes persist only bounded binding metadata, start disabled, and are recomputed from each request snapshot before schema exposure and runtime execution.
- Probe requests and post-tool continuations cannot silently retry with altered stream options, preventing completed tool activity from being replayed.

### Known Limits

- Orca does not bundle inference, install or download models, or manage Ollama or LM Studio processes.
- A successful compatibility probe verifies one narrow synthetic exchange; it does not guarantee planning quality or reliable Agent behavior on real projects.
- The tested `qwen2.5-coder:3b` Ollama model supported Chat but failed the first probe step, and the tested `llama-3.2-3b-instruct` LM Studio model supported Chat but repeated the tool call in the second probe step.
- Generic compatible servers may expose incomplete metadata. Conservative embedding-name filtering and manual Model ID override remain available.
- Progressive tool-schema disclosure remains deferred, and runtime verification still cannot establish visual or gameplay correctness.

## 1.1.1 - 2026-10-02

### Fixed

- Recovered provider failures after complete tool rounds through bounded, sanitized, non-replayable checkpoints instead of making the conversation permanently view-only.
- Activated repetitive/no-progress tool-loop detection in the controller and changed the 12-round boundary from a system error into one tool-free finalization request.
- Raised the raw SSE transport allowance to accommodate provider framing while retaining strict accumulated-content limits, and bounded DeepSeek thinking output to 8,192 tokens.
- Connected bounded root project instructions and project-skill catalog metadata to the request-scoped controller context as originally documented for 1.1.0.

### Security And Privacy

- Recovery never automatically retries tools, and its model-continuation checkpoint never persists hidden reasoning, raw tool output, call IDs, arguments, source content, hashes, process identifiers, or approval payloads. The separate visible activity log retains only its existing bounded display metadata.
- Incomplete, malformed, cancelled, pending-approval, dirty, and truncated turns remain non-resumable when Orca cannot prove complete tool protocol.

## 1.1.0 - 2026-10-01

### Added

- Automatic bounded loading of root `res://AGENTS.md` as subordinate, private request-scoped project guidance.
- Bounded metadata discovery for `res://skills/<slug>/SKILL.md` and explicit `read_project_skill` loading for one exact skill body.
- Read-only `inspect_godot_api` reflection for `ClassDB` signatures, hierarchy, properties, signals, constants, enums, and safe editor Open Docs topics without prose scraping or object construction.
- Read-only `read_gdscript_function` extraction from saved scripts or exact unsaved editor source, with provenance and no patch hash for editor source.
- Read-only `discover_dependencies` traversal for bounded forward serialized dependencies and reverse dependents.
- Tool-loop thrashing detection for repeated calls/results, alternating cycles, repeated rounds, and no-progress rounds, followed by one no-tools finalization request beneath existing hard caps.
- Permanent automated suites for project instructions, project skills, Godot API reflection, focused function reads, dependency discovery, and tool-loop guarding.

### Changed

- Improved post-1.0 responsive editor scaling, compact composer sizing, narrow action containment, transparent branding, expanded diff sizing, and active-turn auto-follow for delayed content and sequential approvals.
- Updated release metadata and About-page coverage to 1.1.0.

### Security And Privacy

- Project guidance remains subordinate to system, user, mode, approval, path, and runtime safety checks and is removed from stored continuation history after each turn.
- Skill bodies are not automatically loaded, symlink traversal is rejected, and instruction/skill text and metadata use strict byte, line, and count limits.
- Unsaved editor source is never represented as a disk patch base, API reflection does not construct reflected objects, and dependency discovery does not load or instantiate resources.

### Known Limits

- Godot API inspection returns reflected metadata and Help navigation topics, not class-reference prose.
- Dependency discovery covers saved serialized relationships only, not dynamic `load()` calls, code references, runtime-created resources, or unsaved editor state.
- Focused function extraction is a bounded lexical reader, not a full GDScript semantic index.
- Progressive tool-schema disclosure is deferred and is not part of 1.1.0.

## 1.0.0 - 2026-09-28

### Added

- Safety-first Plan and Work modes with explicit approval for model-requested project changes.
- Hash-bound file patch proposals with validation, stale-state protection, review diffs, and guarded revert.
- Bounded project exploration, editor context, diagnostics, saved-scene inspection, and project-settings inspection.
- Reviewed Input Map, main-scene, selected display-setting, and constrained structured scene proposals.
- Streaming Chat Completions transport with cancellation, bounded tool calls, protocol-safe continuation, and context budgeting.
- Provider profiles for OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, and custom OpenAI-compatible endpoints.
- Project-scoped session history, task checklists, grouped tool activity, code rendering, and responsive dock UI.
- Orca-owned nonblocking game launch, bounded stdout/stderr capture, observation, and narrow startup/exit verification.

### Security

- Plan mode remains read-only.
- Work-mode project changes require explicit user approval before writing.
- Project paths, hashes, unsaved editor state, proposal validation, and process ownership are checked before sensitive operations.

### Known Limits

- Runtime verification does not establish visual or gameplay correctness.
- Pending approvals and revert checkpoints do not survive an editor restart.
- API credentials use Godot Editor Settings and sessions are plaintext local data; neither is an OS credential store.
- See [README.md](README.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for complete limitations.
