# Documentation Assets

This directory contains public documentation media used by the repository README, release notes, and future product documentation. It is not part of the Godot plugin installation.

## Layout

```text
docs/
└── assets/
    ├── brand/
    │   ├── orca-animated.svg
    │   └── orca.png
    ├── screenshots/
    │   ├── 2026-09-29_12-35_1.png
    │   ├── 2026-09-29_14-39.png
    │   ├── 2026-09-29_14-40.png
    │   └── 2026-09-29_14-40_1.png
    └── videos/
        ├── error-fix.mp4
        ├── plan-work-mode.gif
        ├── plan-work-mode.mp4
        └── rename.mp4
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
- Prefer descriptive workflow names for new screenshots instead of dates or screen numbers.

## Release Packaging

GitHub documentation can reference media with paths such as:

```md
![Orca screenshot](docs/assets/screenshots/2026-09-29_14-40.png)
```

The Godot Asset Library and user-installable release archive must package only:

```text
addons/orca/
```

Do not include `docs/`, tests, GitHub workflow files, local Godot caches, or other repository-level files in the plugin archive.

Use `scripts/package_release.py` for updater-equipped ZIPs. The native Actions
workflow builds/tests four platform helpers and supplies a complete test ZIP plus
a helper bundle. Commit-based Asset Library snapshots also need those binaries and
their generated manifest in the selected commit. Exact local/manual/Actions steps:
[Plugin release and Asset Library packaging](UPDATES.md#builds-and-downloads-from-github-actions).
