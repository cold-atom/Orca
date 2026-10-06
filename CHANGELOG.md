# Changelog

All notable changes to Orca are documented in this file.

## Unreleased

### Changed

- Provider responses must now contain visible non-whitespace assistant text or at least one valid tool call; empty, whitespace-only, reasoning-only, usage-only, truncated, filtered, and contradictory completions fail visibly instead of silently ending a turn.
- Active provider generation now has a ten-minute total deadline in addition to the existing connection and inactivity timeouts.
- The total generation deadline is preserved across connection and `stream_options` compatibility retries; deterministic localhost coverage keeps the stream active while proving the original deadline still wins.
- Tool-loop finalization now has a distinct `Finalizing safely` state, retains the safety trigger reason, explains denied post-finalization tool calls accurately, and gives explicit non-replay continuation guidance.
- Raw file patches now verify retained proposal integrity before Apply and reread, hash-check, and revalidate exact destination bytes after replacement.
- Verified replacement now has explicit not-committed, committed, committed-with-cleanup-warning, and recovery-failure outcomes across file, scene, Input Map, main-scene, and ProjectSettings mutations.

### Fixed

- Fixed DeepSeek-compatible reasoning-only or empty completions removing the working state without displaying an answer or error.
- Fixed empty tool-loop finalization responses ending without a visible outcome.
- Fixed file-patch recovery states hiding the guarded Revert action.
- Fixed committed writes being reported as failed when private-backup cleanup failed, and fixed uncertain replacement failures being reported or persisted as successful mutations.
- Cleanup-only warnings no longer weaken typed live-state conflict checks; recovery-copy guidance is retained as bounded project-relative session metadata.

### Tests

- Added empty, whitespace-only, reasoning-only, tool-only, truncated, filtered, and terminal-ownership transport regressions.
- Added real GDScript patch lifecycle coverage and exact duplicate class/local variable validation regressions.
- Added tool-loop trigger, finalization-state, denied-provider-text, explicit-continuation, and empty-finalization coverage.
- Added deterministic replacement, restoration, temporary-cleanup, post-write verification, cleanup-warning, recovery-classification, and retry-deadline fault coverage.

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
