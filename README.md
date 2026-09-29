<p align="center">
  <img src="docs/assets/brand/orca.png" alt="Orca logo" width="132">
</p>

<h1 align="center">Orca</h1>

<p align="center">
  <strong>A safety-first AI development assistant for the Godot editor.</strong>
</p>

<p align="center">
  Godot 4.7.2 &middot; MIT License &middot; Review-first project changes
</p>

Orca helps developers inspect projects, understand editor context, propose Godot-aware changes, validate them, and apply them only after explicit review.

## Status

This is Orca 1.0.0. The supported Godot version is **4.7.2**.

Orca is designed to assist with development work, not to replace source control, code review, backups, or normal project testing.

## Highlights

- Plan mode is read-only.
- Work mode can propose changes, but file and structured project changes require explicit approval.
- Proposed file edits are hash-bound, validated, conflict-checked, and can be reverted while their in-memory checkpoint remains valid.
- Orca can inspect saved scenes and selected project settings through bounded Godot-aware tools.
- It can propose reviewed Input Map, main-scene, selected display-setting, and constrained scene changes.
- Orca can launch one bounded process that it owns, capture limited stdout/stderr evidence, and evaluate narrow startup or exit criteria.
- Conversations are stored locally per project and can be restored safely.

## Install

1. Download the Orca release archive.
2. Extract its `addons/orca/` directory into your Godot project's `addons/` directory.
3. Open the project in Godot 4.7.2.
4. Enable **Orca** in **Project > Project Settings > Plugins**.
5. Open the Orca dock, select a provider, add your API key, choose a model, and start a session.

For development setup and test commands, see [DEVELOPMENT.md](DEVELOPMENT.md) and [tests/README.md](tests/README.md).

## Plan And Work

**Plan** is read-only. Orca can inspect supported project files, scenes, editor context, diagnostics, and project settings, but cannot change project files or run a game.

**Work** can prepare reviewed changes and run a saved scene in an Orca-owned process. Work does not grant automatic file writes: each model-requested change waits for your Apply or Reject decision.

Always review a proposal before applying it. Orca rejects stale proposals and protects known unsaved scripts and scenes, but it is not a substitute for version control.

## Providers And Data

Orca supports OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, and custom OpenAI-compatible endpoints through its current Chat Completions transport.

Before submitting a request, make sure you trust the selected provider and endpoint. Prompts, relevant editor context, and project content returned by Orca's tools may be sent to that provider so it can answer your request. Authenticated model discovery sends the selected provider's API key to that provider. Public model metadata is requested from `models.dev` without API keys, prompts, or project content.

API credentials are saved through Godot Editor Settings. Session history is stored locally as plaintext JSON under Godot's `user://` storage. Neither mechanism is an OS credential vault or encrypted secret store. See [SECURITY.md](SECURITY.md) for security reporting and operational limits.

## Important Limits

- Runtime verification is limited to bounded process output and predeclared startup or exit criteria. It does not prove visual or gameplay correctness.
- Pending approvals and revert checkpoints are not retained after restarting the editor or plugin.
- Structured scene operations deliberately support a constrained set of nodes, values, dependencies, and signals.
- Script attach/detach has an explicit Trust and Prepare step because Godot may execute project code while building a candidate. This is informed consent, not sandboxing.
- Custom OpenAI-compatible providers may not expose complete model or capability metadata.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full safety model, test coverage, and known limitations.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue or pull request.

## License

Orca source code is released under the [MIT License](LICENSE).