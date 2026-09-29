# Changelog

All notable changes to Orca are documented in this file.

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
