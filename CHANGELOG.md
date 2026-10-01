# Changelog

All notable changes to Orca are documented in this file.

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
