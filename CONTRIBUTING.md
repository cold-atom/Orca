# Contributing To Orca

## Community

Participation in Orca's issues, pull requests, and Discussions follows our [Code of Conduct](CODE_OF_CONDUCT.md). Send conduct reports privately to [support@aiorca.dev](mailto:support@aiorca.dev).

## Before You Start

Read [AGENTS.md](AGENTS.md) and [DEVELOPMENT.md](DEVELOPMENT.md). Orca's permission boundaries, proposal approval, path confinement, stale-state detection, validation, and protocol-valid tool history are safety requirements.

Do not weaken them to simplify a feature.

## Development Setup

- Use Godot 4.7.2.
- Open this directory as a Godot project.
- Enable the local Orca plugin through **Project Settings > Plugins** when testing in the editor.
- Set `GODOT_BIN` to the Godot 4.7.2 executable for headless tests.

Run the complete documented test suite and headless plugin initialization before proposing a change. Individual commands are listed in [tests/README.md](tests/README.md).

```bash
"$GODOT_BIN" --headless --editor --path . --quit
```

Do not send live provider requests during automated tests unless explicitly authorized. Use synthetic fixtures and the localhost transport test instead.

## Pull Requests

- Use the pull request template to summarize the change, related issues, verification, and relevant design considerations.
- Keep changes focused and include tests for behavior changes.
- Features inspired by another project must be independently designed for Orca. Describe the user problem and relevant research, preserve Orca's safety model and visual language, and disclose any directly reused licensed material.
- Preserve Plan/Work runtime enforcement even when a tool is omitted from a schema.
- Update `DEVELOPMENT.md` when architecture, safety behavior, supported tools, testing requirements, or roadmap status changes.
- Do not include `.godot/`, `.ci/`, `.import` files, API keys, session data, temporary replacement files, or test artifacts.
- Keep README logos, screenshots, and other public documentation media under `docs/assets/`. Release archives for users and the Godot Asset Library must contain only `addons/orca/`.
- Explain manual editor testing that cannot be covered headlessly.

## Issues

Use the [issue forms](https://github.com/cold-atom/Orca/issues/new/choose) for bugs and feature requests. Include reproduction steps, Orca/Godot versions, operating system, and provider/model details when relevant. The support diagnostic report in Orca Settings → About can help with bug reports; review any additional logs, screenshots, or project attachments for private information before sharing.

Documentation problems can use a blank issue. Use [Discussions](https://github.com/cold-atom/Orca/discussions) for questions and early ideas.

Do not post potential security vulnerabilities publicly; follow [SECURITY.md](SECURITY.md).
