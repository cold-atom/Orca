# Documentation Assets

This directory contains public documentation media used by the repository README, release notes, and future product documentation. It is not part of the Godot plugin installation.

## Layout

```text
docs/
└── assets/
    ├── brand/
    │   ├── orca.png
    │   ├── orca-logo.svg
    │   ├── orca-mark.svg
    │   └── orca-wordmark.svg
    ├── hero/
    │   └── orca-editor-overview.png
    └── screenshots/
        ├── settings.png
        ├── plan-mode.png
        ├── change-review.png
        ├── structured-scene-review.png
        ├── run-verification.png
        └── session-history.png
```

Add files only when they are final, accurate, and cleared for public use. Do not commit empty placeholder images.

## Brand Assets

- `assets/brand/orca.png` is the current public Orca mark used in the repository README.
- Prefer original SVG source files for the Orca mark, wordmark, and combined logo when a vector brand package is available.
- Ensure every logo is legible on GitHub's light and dark themes.
- Keep the source, creator, and license for any non-original asset in a documented, verifiable form.
- Do not reuse plugin UI icons as public product branding unless their ownership and intended use are confirmed.

## Screenshots

- Capture the real Orca UI in Godot 4.7.2.
- Use a clean synthetic demo project with no customer code, API keys, personal paths, or private session content visible.
- Show actual supported workflows only; do not create mockups that imply unavailable capabilities.
- Use PNG for UI screenshots. Keep each image as small as practical while preserving readable interface text.
- Name screenshots by the workflow they demonstrate, not by date or screen number.

## Release Packaging

GitHub documentation can reference media with paths such as:

```md
![Orca reviewing a change](docs/assets/screenshots/change-review.png)
```

The Godot Asset Library and user-installable release archive must package only:

```text
addons/orca/
```

Do not include `docs/`, tests, GitHub workflow files, local Godot caches, or other repository-level files in the plugin archive.
