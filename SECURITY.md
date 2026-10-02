# Security Policy

## Supported Version

Security fixes are applied to the current 1.1.x release line.

## Reporting A Vulnerability

Do not report suspected vulnerabilities in a public GitHub issue.

Use GitHub's private vulnerability reporting for this repository when it is enabled. Until then, contact the repository owner privately through GitHub and include:

- A clear description of the issue and its impact.
- Reproduction steps or a minimal project when safe to share.
- The Orca version, Godot version, operating system, and provider type involved.
- Whether project files, credentials, or an externally reachable endpoint may be affected.

Please allow time for investigation and a coordinated fix before public disclosure.

## Security Model And Limits

Orca is designed to reduce accidental project changes, not to sandbox arbitrary code or providers.

- Plan mode does not expose project mutation or game-process operations.
- Work-mode project changes require explicit approval and are checked against hashes and editor state before application.
- Project paths are restricted to `res://`; symbolic links and Orca's own addon directory are rejected by agent tools.
- API credentials are stored in Godot Editor Settings, which is not an encrypted OS credential manager.
- Session transcripts are stored locally as plaintext JSON and can contain prompts and visible assistant responses.
- Project context and file contents may be sent to the configured model provider. Use only providers and endpoints you trust.
- A root `res://AGENTS.md` and bounded skill catalog metadata are automatically added to each request when present. They are treated as untrusted project guidance, cannot grant permissions, and are removed from durable continuation history after the turn; an exact skill body is sent only after `read_project_skill` is called.
- Project instructions and skill files reject symbolic-link traversal and enforce UTF-8, byte, line, and metadata bounds. These controls limit exposure and editor work but do not make model providers trusted.
- `inspect_godot_api` reflects public `ClassDB` metadata and creates validated editor Help topics without constructing reflected objects or scraping documentation prose.
- Unsaved source returned by `read_gdscript_function` is read-only editor context and never supplies a disk hash for patching. Serialized dependency discovery does not load or instantiate resources and does not claim dynamic or runtime references.
- Repetitive tool activity and the 12-round execution boundary receive one no-tools finalization request; attempts to call tools again are denied without execution. The independent limit of 16 calls per provider response remains authoritative.
- Loading or validating Godot scenes and scripts is not a security sandbox. Script preparation has an explicit trust step, but Godot may execute project code during candidate construction.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full documented threat model and limitations.
