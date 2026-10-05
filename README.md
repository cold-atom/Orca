<div align="center">

<img src="docs/assets/brand/orca.png" alt="Orca logo" width="132">

# Orca

**A safety first AI development agent for the Godot editor.**

<p>
  <a href="https://github.com/cold-atom/Orca/releases/latest"><img src="https://img.shields.io/github/v/release/cold-atom/Orca?style=for-the-badge&label=Latest&color=111111&labelColor=000000" alt="Latest release"></a>
  <a href="https://github.com/cold-atom/Orca/releases"><img src="https://img.shields.io/github/downloads/cold-atom/Orca/total?style=for-the-badge&color=111111&labelColor=000000" alt="Release downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-111111?style=for-the-badge&labelColor=000000" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/Godot-4.7.2-111111?style=for-the-badge&labelColor=000000" alt="Godot 4.7.2">
</p>

<a href="https://github.com/cold-atom/Orca/releases"><b>Download</b></a> &nbsp;|&nbsp;
<a href="#install">Install</a> &nbsp;|&nbsp;
<a href="#demo">Demo</a> &nbsp;|&nbsp;
<a href="#highlights">Highlights</a> &nbsp;|&nbsp;
<a href="CONTRIBUTING.md">Contributing</a> &nbsp;|&nbsp;
<a href="SECURITY.md">Security</a>

</div>

Orca helps developers inspect projects, understand editor context, propose Godot-aware changes, validate them, and apply them only after explicit review.

## Demo

[![Watch the Orca demo](https://img.youtube.com/vi/JZJ4gUgwPHw/maxresdefault.jpg)](https://www.youtube.com/watch?v=JZJ4gUgwPHw)

Watch Orca inspect a Godot project, propose reviewed changes, and validate the result.

## Status

This is Orca 1.2.0. The supported Godot version is **4.7.2**.

Orca is designed to assist with development work, not to replace source control, code review, backups, or normal project testing.

## Highlights

- Plan mode is read-only.
- Work mode can propose changes, but file and structured project changes require explicit approval.
- Proposed file edits are hash-bound, validated, conflict-checked, and can be reverted while their in-memory checkpoint remains valid.
- Orca can inspect saved scenes and selected project settings through bounded Godot-aware tools.
- A bounded root `res://AGENTS.md` and project-skill catalog can guide each request without becoming durable session history; skill bodies load only when the model explicitly calls `read_project_skill`.
- Read-only Godot Intelligence tools can reflect `ClassDB` signatures, open safe editor Help topics, read one focused GDScript function including exact unsaved editor source, and discover bounded serialized resource dependencies.
- Repetitive or no-progress tool activity triggers one final no-tools response request before the existing hard tool limits.
- It can propose reviewed Input Map, main-scene, selected display-setting, and constrained scene changes.
- Orca can launch one bounded process that it owns, capture limited stdout/stderr evidence, and evaluate narrow startup or exit criteria.
- Conversations are stored locally per project and can be restored safely.

## Install

1. Download the Orca release archive.
2. Extract its `addons/orca/` directory into your Godot project's `addons/` directory.
3. Open the project in Godot 4.7.2.
4. Enable **Orca** in **Project > Project Settings > Plugins**.
5. Open the Orca dock, select a provider, add an API key when required, choose a model, and start a session.

For development setup and test commands, see [DEVELOPMENT.md](DEVELOPMENT.md) and [tests/README.md](tests/README.md).

## Plan And Work

**Plan** is read-only. Orca can inspect supported project files, scenes, editor context, diagnostics, and project settings, but cannot change project files or run a game.

**Work** can prepare reviewed changes and run a saved scene in an Orca-owned process. Work does not grant automatic file writes: each model-requested change waits for your Apply or Reject decision.

Always review a proposal before applying it. Orca rejects stale proposals and protects known unsaved scripts and scenes, but it is not a substitute for version control.

## Providers And Data

Orca supports OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, Local OpenAI-compatible, and custom OpenAI-compatible endpoints through its current Chat Completions transport. Local and editable profiles start in Chat mode. A project-free two-step function-call probe must pass for the exact provider, origin, model, request configuration, and probe version before the user can separately enable Agent tools.

Ollama and LM Studio discovery uses their native model-list APIs to hide models explicitly identified as embeddings. Generic compatible lists use a conservative `embed` name filter. The manual Model ID field remains available as an override, and Orca reports plain chat-capability or local model-substitution errors instead of raw provider JSON.

Before submitting a request, make sure you trust the selected provider and endpoint. Prompts, relevant editor context, and project content returned by Orca's tools may be sent to that provider so it can answer your request. Authenticated model discovery sends the selected provider's API key to that provider. Public model metadata is requested from `models.dev` without API keys, prompts, or project content.

Editable LAN and remote endpoints require confirmation for their exact scheme, host, and port. Orca identifies unencrypted non-loopback HTTP connections and does not follow provider chat or model-discovery redirects. Confirmation does not prove that a server is trustworthy or prevent that server from forwarding received data.

When present, root `res://AGENTS.md` content and the `name`, `description`, slug, and path metadata of valid `res://skills/<slug>/SKILL.md` files are automatically included in private request-scoped model context. A selected skill body is sent only after an explicit `read_project_skill` call. These inputs are project guidance, cannot override Orca's permissions or approval rules, and are removed from stored continuation history after the turn.

API credentials are saved through Godot Editor Settings. Session history is stored locally as plaintext JSON under Godot's `user://` storage. Neither mechanism is an OS credential vault or encrypted secret store. See [SECURITY.md](SECURITY.md) for security reporting and operational limits.

## Important Limits

- Runtime verification is limited to bounded process output and predeclared startup or exit criteria. It does not prove visual or gameplay correctness.
- Pending approvals and revert checkpoints are not retained after restarting the editor or plugin.
- Structured scene operations deliberately support a constrained set of nodes, values, dependencies, and signals.
- Script attach/detach has an explicit Trust and Prepare step because Godot may execute project code while building a candidate. This is informed consent, not sandboxing.
- Custom OpenAI-compatible providers may not expose complete model or capability metadata.
- Godot API inspection exposes reflected signatures and safe Open Docs navigation, not scraped class-reference prose. Dependency discovery covers saved serialized `ResourceLoader` relationships, not dynamic `load()` calls or runtime-created resources.
- Progressive tool-schema disclosure is deferred; the current eligible tool schema remains sent with requests.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full safety model, test coverage, and known limitations.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request.

## License

Orca source code is released under the [MIT License](LICENSE).
