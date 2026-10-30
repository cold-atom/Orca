# Orca Agent Guide

This file applies to the entire repository. Read `DEVELOPMENT.md` before making architectural changes.

## Mission

Orca is an AI game-development assistant embedded in the Godot editor. It should combine a coding agent's project exploration and change workflow with Godot-specific scene, script, selection, validation, and debugging context.

The product goal is not merely a chatbot inside a dock. Orca should safely inspect a project, understand the user's current editor context, propose precise changes, explain its work, validate results, and support a future run/fix/verify loop.

## Documentation

- `ORCA.md`: Product overview and high-level capabilities.
- `DEVELOPMENT.md`: Architecture, current state, tool contracts, safety model, testing, decisions, limitations, roadmap, and milestone history.
- `HANDOVER.md`: Current session decisions, completed waves, verification, residual risks, and exact continuation plan.
- `AGENTS.md`: Mandatory working rules and quick repository orientation.

Update `DEVELOPMENT.md` whenever a change alters architecture, tool behavior, safety guarantees, testing requirements, or roadmap status. Add only meaningful completed milestones to its milestone log.

## Technology

- Engine: Godot 4.7.2.
- Language: GDScript with `@tool` editor scripts.
- Plugin root: `addons/orca/`.
- Model transport: streamed OpenAI-compatible Chat Completions and opt-in Foundry Responses over `HTTPClient` and SSE.
- Configuration: Godot `EditorSettings`.
- Current project is a development host for the editor plugin.

## Architecture Map

| Path | Responsibility |
| --- | --- |
| `addons/orca/orca.gd` | `EditorPlugin` lifecycle, toolbar integration, and dock registration. |
| `addons/orca/scenes/chat_window.tscn` | Main Orca dock layout and composer. |
| `addons/orca/scripts/chat_window.gd` | Structured conversation feed, streaming UI, modes, tool cards, approvals, and navigation actions. |
| `addons/orca/scripts/response_attribution.gd` | Shared bounded model/mode-only response metadata validation for controller, UI, and visible history. |
| `addons/orca/scripts/api_client.gd` | Nonblocking HTTP transport, SSE parsing, streaming tool-call reconstruction, timeouts, and cancellation. |
| `addons/orca/scripts/responses_protocol.gd` | Stateless Responses projection and bounded output normalization; exact-profile opaque reasoning continuation with no session persistence. |
| `addons/orca/scripts/deepseek_response_compatibility.gd` | Explicit Azure DeepSeek-only bounded leading-delimiter normalization shared by streaming and completed output. |
| `addons/orca/scripts/endpoint_policy.gd` | Strict endpoint parsing, normalization, network-scope classification, exact-origin confirmation, and generated-endpoint validation. |
| `addons/orca/scripts/agent_compatibility_probe.gd` | Isolated project-free two-step function-call probe and exact provider/origin/model/version compatibility binding. |
| `addons/orca/scripts/agent_controller.gd` | Message history, Plan/Work permissions, request-scoped context, tool loop, approval suspension, and cancellation. |
| `addons/orca/scripts/context_budget.gd` | Conservative request estimation, response/tool reserves, and protocol-aware complete-turn compaction. |
| `addons/orca/scripts/image_attachments.gd` | Bounded still-image preparation, immutable records, capability-aware historical request projection, multimodal materialization, and image reserves. |
| `addons/orca/scripts/image_capability.gd` | Exact-profile image-input capability and explicit unknown-profile configuration. |
| `addons/orca/scripts/image_attachment_tray.gd` | Composer and message thumbnail trays with removal and preview actions. |
| `addons/orca/scripts/script_references.gd` | Explicit project-script path validation, bounded saved/active-unsaved source snapshots, canonical records, and outgoing user-context materialization. |
| `addons/orca/scripts/script_reference_tray.gd` | Compact removable composer and navigable message script-reference chips. |
| `addons/orca/scripts/image_attachment_window.gd` | Separate native image drop/Browse window that isolates desktop attachment intake from editor import. |
| `addons/orca/scripts/composer_input.gd` | Public TextEdit paste interception for explicit image clipboard intake and normal text fallback. |
| `addons/orca/scripts/project_instructions.gd` | Bounded automatic loading of root `res://AGENTS.md` into private request-scoped context. |
| `addons/orca/scripts/project_skills.gd` | Bounded `res://skills/<slug>/SKILL.md` metadata discovery and explicit skill-body loading. |
| `addons/orca/scripts/godot_api_inspector.gd` | Read-only `ClassDB` API signatures, hierarchy, constants, enums, and safe editor Help topics. |
| `addons/orca/scripts/gdscript_function_reader.gd` | Focused GDScript function extraction from saved files or exact unsaved editor source. |
| `addons/orca/scripts/dependency_inspector.gd` | Bounded forward and reverse traversal of serialized `ResourceLoader` dependencies. |
| `addons/orca/scripts/tool_loop_guard.gd` | Repetitive/no-progress tool-loop detection and one no-tools finalization request below hard caps. |
| `addons/orca/scripts/tools.gd` | Tool schemas, bounded filesystem operations, search, patch preparation, validation, safe application, and revert. |
| `addons/orca/scripts/editor_context.gd` | Active scene, selected nodes, active script, caret, selected code, unsaved-state checks, and editor navigation. |
| `addons/orca/scripts/scene_inspector.gd` | Bounded read-only `PackedScene`/`SceneState` extraction with JSON-safe serialized property and connection summaries. |
| `addons/orca/scripts/editor_scene_inspector.gd` | Bounded live current-scene/selection/subtree inspection with native getter isolation, unsaved provenance, and project/reference confinement. |
| `addons/orca/scripts/project_settings_inspector.gd` | Bounded read-only ProjectSettings overview and explicit typed setting inspection. |
| `addons/orca/scripts/input_map_proposal.gd` | Typed Input Map proposal preparation, validation, live/disk consistency checks, and synchronization. |
| `addons/orca/scripts/main_scene_proposal.gd` | Reviewed main-scene proposal preparation with UID/path normalization and ProjectSettings synchronization. |
| `addons/orca/scripts/project_settings_proposal.gd` | Allowlisted low-risk ProjectSettings proposal validation, materialization, and synchronization. |
| `addons/orca/scripts/scene_proposal.gd` | Structured saved-scene proposal construction, two-stage script execution trust, pack/save/load validation, application checks, and guarded creation semantics. |
| `addons/orca/scripts/patch_utils.gd` | Strict one-based line edit materialization with LF/CRLF handling. |
| `addons/orca/scripts/diff_utils.gd` | Old/new line diff generation for review. |
| `addons/orca/scripts/diagnostics_service.gd` | GDScript validation, observed editor-process errors, and play-state reporting. |
| `addons/orca/scripts/support_diagnostic_report.gd` | Strict-allowlist, memory-only support report containing versions and coarse provider/request state. |
| `addons/orca/scripts/game_process_service.gd` | Nonblocking Orca-owned game launch, run identity, bounded stdout/stderr diagnostics, immutable verification criteria, timeout, and direct-process stop. |
| `addons/orca/scripts/model_catalog_service.gd` | Bounded public model-metadata refresh and selected-model cache management. |
| `addons/orca/scripts/model_metadata.gd` | Provider inference, model context/pricing normalization, fallback metadata, and cost calculation. |
| `addons/orca/scripts/provider_registry.gd` | Provider adapter registration and lookup. |
| `addons/orca/scripts/provider_model_service.gd` | Authenticated, bounded provider model discovery and caching. |
| `addons/orca/scripts/providers/` | Provider-specific endpoints, headers, model normalization, reasoning options, and history sanitation. |
| `addons/orca/scripts/settings_view.gd` | Responsive in-dock provider, credential, model, effort, and metadata settings page. |
| `addons/orca/scripts/connection_setup_panel.gd` | Dismissible conversation-area connection overlay card with first-open/Send setup choices and draft-preserving navigation. |
| `addons/orca/scripts/account_service.gd` | Browser pairing, persistent account lifecycle, single-flight token refresh, sanitized account/catalog state and fixed-origin hosted authorization. |
| `addons/orca/scripts/update_service.gd` | Public daily GitHub release checks, cached bounded metadata, verified staging, cancellation and explicit updater handoff. |
| `addons/orca/scripts/update_package.gd` | Strict release ZIP/manifest checks, local-change detection, project-scoped update locks, transactional replacement and guarded rollback. |
| `addons/orca/scripts/update_runner.gd` | Trusted independent Godot installer; waits for editor exit, installs/restores and reopens the same project. |
| `addons/orca/scripts/update_panel.gd` | Dismissible dock notice and General Settings update/check/progress/rollback controls. |
| `addons/orca/scripts/credential_store.gd` | Bounded private-pipe OS-vault bridge with cross-editor refresh locking. |
| `addons/orca/scripts/native_helper_service.gd` | Quiet background platform-helper preparation, exact release/catalog verification, bounded retries, immutable per-user cache and installation coordination. |
| `addons/orca/native/` | Independently implemented fixed credential helper; native Actions builds/tests cover Linux/Windows x86_64 and macOS arm64/x86_64. Linux is locally verified; other platforms require actual CI/distribution acceptance. |
| `addons/orca/scripts/providers/orca_cloud_provider.gd` | Managed account provider, bounded catalog normalization and exact-profile private continuation. |
| `addons/orca/scripts/history_view.gd` | Project conversation browser, restoration, and deletion UI. |
| `addons/orca/scripts/session_store.gd` | Versioned project-scoped session persistence, bounds, atomic replacement, retention, and recovery. |
| `addons/orca/scripts/tool_activity_card.gd` | Collapsible read/search/context/diagnostic activity cards. |
| `addons/orca/scripts/tool_activity_group.gd` | Aggregate status and collapsible grouping for consecutive read-only activity cards. |
| `addons/orca/scripts/task_utils.gd` | Shared strict validation and defensive sanitation for bounded session task lists. |
| `addons/orca/scripts/task_list_panel.gd` | Collapsible persistent checklist for multi-step session work. |
| `addons/orca/scripts/mode_switch_card.gd` | Turn-bound Plan-to-Work approval card with explicit stay/switch decisions. |
| `addons/orca/scripts/change_card.gd` | Unified diff, expanded side-by-side review, Apply/Reject/Revert, validation state, and file opening. |
| `addons/orca/scripts/input_map_change_card.gd` | Structured Input Map action review with Apply/Reject/Revert and project settings navigation. |
| `addons/orca/scripts/main_scene_change_card.gd` | Structured previous/proposed main-scene review and navigation. |
| `addons/orca/scripts/project_settings_change_card.gd` | Structured typed ProjectSettings review with guarded actions. |
| `addons/orca/scripts/scene_change_card.gd` | Structured scene hierarchy review with guarded Apply/Reject/Revert actions. |

## Non-Negotiable Invariants

1. Plan mode is read-only for project and external state. Do not expose or execute project mutation tools in Plan mode; bounded session task metadata may be updated, and a model may request one explicit user-approved transition to Work without performing project or external mutation.
2. Work mode may propose changes, but no model-requested file mutation or revert happens without Work-mode permission and explicit user approval for the original proposal.
3. Keep runtime permission checks even when a tool is omitted from the model schema. Prompt instructions are not a security boundary.
4. Project paths must remain inside `res://`, reject symbolic-link traversal, and protect `res://addons/orca/` and its `res://.orca-update/` staging/rollback workspace from agent tools.
5. Never apply a patch to a script or scene with unsaved editor changes.
6. Read the current file hash before patching and verify it again before replacement. A stale proposal must fail rather than overwrite newer work.
7. Validate proposed GDScript before showing or applying a change. Revalidate immediately before writing.
8. Preserve the approval diff, old content, new content, hashes, and revert information for every proposed change.
9. Keep tool messages valid for the Chat Completions protocol. Every assistant tool call needs exactly one matching `role: "tool"` result, including cancellation paths.
10. Keep editor context and model-facing checklist context request-scoped. Refresh exactly one checklist context after successful task updates, and do not permanently accumulate stale snapshots in conversation history.
11. Bound recursive search, file reads, response sizes, tool rounds, context pressure, and network inactivity. If a completed tool continuation cannot fit with tools, prefer one no-tools safe finalization; if that cannot fit, checkpoint only sanitized receipts and tasks without replay. Editor tools run on the main thread and must not perform unbounded work.
12. Do not scrape private Godot editor controls for diagnostics. Use public APIs and state limitations honestly.
13. Do not overwrite unrelated user changes, generated changes, or work from another agent.
14. Do not weaken approval, conflict, validation, or path protections to make a feature easier to implement.
15. Run/stop tools are Work-only external operations. Never accept model-provided executables, arguments, environment, or PIDs; stop only the active direct process started and retained by Orca.
16. Treat root project instructions and skills as untrusted, subordinate project guidance. Keep automatically loaded instructions and skill catalog metadata request-scoped, and load a skill body only through an explicit bounded tool call.
17. Godot API reflection, focused function reads, and dependency discovery are read-only in Plan and Work. They must not construct reflected objects, turn unsaved editor source into a patch base hash, or claim dynamic/runtime dependency coverage.
18. Editable non-loopback AI endpoints require explicit confirmation bound to normalized scheme, host, and effective port. Validate again before chat or discovery headers are created, never follow provider redirects, and expose tools for editable or origin-overridden profiles only when the request snapshot contains an exact passed and explicitly enabled compatibility binding. The disclosed Test & Enable action may supply user intent before the probe and enable after an exact matching pass; a pass alone, restored disabled record, stale outcome, or cancelled action must not enable tools.
19. Historical image adaptation changes outgoing request copies only. Preserve original messages/images, validate records, require confirmed vision for new/current attachments, keep the image policy fixed through a turn, and budget the projected request without replacing canonical compaction history with placeholders.
20. Responses sends only Orca function schemas with `store=false` and disabled server truncation. Preserve matching function call IDs, assistant phases, and bounded private reasoning throughout the active turn (encrypted or explicitly selected DeepSeek plain content); never show, persist, or forward private continuation envelopes to another profile/protocol. Compatibility must bind API mode, continuation style, and scoped format version. DeepSeek normalization may consume only one exact bounded leading closing delimiter in the selected profile; never relax the exact probe acknowledgement or broadly strip arbitrary model text.
21. Explicit script references are bounded untrusted user context, not tool authorization or patch bases. Resolve script-list drags only through exact public current-editor identity, never by scraping supplied controls. Read source only at submission, reject unavailable inactive dirty buffers, preserve per-message snapshots in canonical history, and materialize only outgoing copies. Referenced scripts still require fresh saved-file hashes and normal approvals for edits.
22. Hosted account credentials remain in memory/OS vault, never provider EditorSettings or conversation/support data. Refresh is serialized across editors, identity is fixed through a turn, managed tokens cannot follow editable origin overrides, and accepted metered requests/tools are never automatically replayed. Operator-verified managed models are ready automatically through a fixed-origin, account/capability/contract-bound runtime gate; users do not run a compatibility probe or configure reasoning for these models. Editable/custom/origin-overridden profiles retain their exact passed-and-enabled probe requirements. Context estimates and byte-upper-bound billing reservations are separate; keep complete-turn/opaque-state safeguards. Tests must suppress owner startup authentication with `ORCA_DISABLE_ACCOUNT_RESTORE=1`, suppress background component downloads with `ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1`, and use isolated native-vault scopes/backend databases.
23. Plugin updating is explicit user-owned maintenance, never a model tool. Automatic checks send only public unauthenticated release requests. Installation/rollback require user confirmation, exact official asset/manifest validation, clean current-editor state, unchanged installed/backup bytes and exclusive project update ownership. Downloaded scripts are never executed during preparation. Retain a rollback/recovery record and run replacement only after the initiating editor exits. Tests must set `ORCA_DISABLE_UPDATE_CHECKS=1` and use disposable projects for installation/relaunch.

## Agent Modes

### Plan

- May list directories, search files, read line ranges, inspect editor context, and read supported diagnostics.
- May inspect reflected Godot API signatures, focused GDScript functions, serialized dependencies, and explicitly selected project skills.
- May inspect bounded live editor scene state, including unsaved changes, through fixed native reads; live snapshots never supply a disk patch base.
- May maintain the bounded session task checklist; this does not modify project files or external state.
- May request one explicit user-approved transition to Work for the active turn without performing project or external mutation.
- Must not propose, apply, or revert project changes.
- Uses orange assistant headings in the UI.

### Work

- Includes all Plan capabilities.
- May call `apply_patch` to create a reviewed proposal.
- May call typed structured mutation tools such as `propose_input_map_changes`; every proposal still requires review.
- May start a saved current/main scene in one bounded Orca-owned process and stop only that retained direct process.
- Every proposal waits for Apply or Reject.
- Uses green assistant headings in the UI.
- Is the default mode.

Manual mode changes are disabled while a request or approval is active. During a Plan turn, `request_work_mode` may suspend once for an exact turn-bound user decision and must be the only call in its provider batch. Approval affects only the next provider request; rejection or cancellation remains in Plan. Approval regenerates the primary Work prompt and returns an explicit matching tool result without inserting a system message inside the active protocol turn.

## Development Workflow

1. Inspect the relevant implementation and its callers before editing.
2. Preserve the smallest correct architecture. Avoid adding abstractions without a concrete need.
3. When changing a tool, update its schema, execution result, controller handling, activity card, prompts, tests, and documentation together.
4. When changing request state, verify success, failure, cancellation, malformed response, and multi-tool paths.
5. When changing mutation behavior, verify Plan denial, Work approval, rejection, stale hashes, unsaved files, validation failure, application, and revert.
6. When changing editor integration, use public Godot 4.7 APIs and guard editor-only calls with `Engine.is_editor_hint()`.
7. Run headless editor initialization and relevant focused tests before reporting completion.
8. Remove temporary test files and confirm no `.orca_tmp_*`, `.orca_backup_*`, or test project files remain.
9. Update `DEVELOPMENT.md` when the completed work changes the documented system.

## External Project Research

Other projects are research sources, not code donors. Study them to understand user problems, workflows, capabilities, and architectural tradeoffs. Reimplement useful concepts independently through Orca's visual language, bounded tool contracts, Plan/Work permissions, explicit approval flow, conflict protection, validation, cancellation, persistence, and testing standards.

Do not copy another project's source structure, prompts, UI, naming, or unsafe assumptions. Never weaken Orca's invariants to match another product's feature count. If source code is intentionally reused under a compatible license, document its provenance, license obligations, and reason instead of presenting it as an independent implementation.

## Validation

Set `GODOT_BIN` to a Godot 4.7.2 executable, then run:

```bash
"$GODOT_BIN" --headless --editor --path . --quit
```

This catches GDScript parse/compile failures and plugin initialization errors. It is necessary but not sufficient.

A committed automated suite exists under `tests/` and runs in `.github/workflows/tests.yml`. Run the relevant permanent suites and the manual checks documented in `DEVELOPMENT.md`; never claim coverage for editor-only scenarios that were not exercised.

## Definition Of Done

- Godot loads the project and plugin without script or initialization errors.
- The requested behavior works in the editor, including narrow dock layouts where relevant.
- Plan and Work permissions remain correct.
- Streaming, Stop, and follow-up tool rounds still work.
- Tool-call history remains protocol-valid after errors and cancellation.
- File changes require approval, validate successfully, and can be reverted when applicable.
- No temporary test or replacement artifacts remain.
- Known limitations and untested behavior are stated explicitly.
- `DEVELOPMENT.md` is updated for significant architectural or roadmap changes.

## Handoff Format

When handing work to another agent or developer, report:

- Goal and user-visible result.
- Files changed.
- Important implementation decisions.
- Safety or compatibility implications.
- Validation commands and scenarios executed.
- Anything not tested.
- Known follow-up work.
