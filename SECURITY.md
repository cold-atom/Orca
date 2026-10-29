# Security Policy

## Supported Version

Security work targets the 1.4.x release line. Orca 1.4.0 is released; Windows/macOS
distribution acceptance remains pending.

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
- BYOK provider API keys are stored in Godot Editor Settings, which is not an encrypted OS credential manager.
- Orca account refresh/session credentials instead use the native OS vault; access tokens remain in memory. The fixed helper uses bounded private pipes and an OS refresh lock, with no shared client secret/plaintext fallback. Native CI covers Linux/Windows x86_64 and macOS arm64/x86_64; Linux is verified locally, while Windows/macOS execution and downloaded-package acceptance remain pending. Windows uses LF-only binary pipes and a static CRT; Mac builds are ad-hoc signed, not notarized. Account credentials cannot be saved as BYOK keys or sent through arbitrary endpoint overrides. Managed tools are automatically available only through authenticated operator-verified capability/tool-contract records and fixed-origin runtime checks. Local/custom probe requirements and all project approvals remain; subscription metadata is not project authorization. Context estimates do not replace byte-upper-bound billing reservation. Unknown/accepted usage is never assumed zero or replayed.
- Session transcripts are stored locally as plaintext JSON and can contain prompts and visible assistant responses.
- Per-answer attribution retains only the bounded configured model ID and response mode in visible history. It is separate from model continuation/provider payloads, and the strict-allowlist support report still excludes exact model identifiers and conversation metadata.
- Submitted image attachments are sent to the selected AI endpoint and retained as bounded, deduplicated plaintext session data under `user://`; conversation deletion and retention remove them. Pending image drafts are memory-only. Source paths and original image metadata are not retained.
- Explicit project-script references send project paths and bounded source snapshots to the selected endpoint, including in Chat-only profiles, and persist as plaintext local user-message context. Preparation rejects external/symlink/protected-addon paths, invalid UTF-8/NUL and oversized files; each of at most four scripts is capped at 300 lines / 16 KiB. Only exact active unsaved text is accepted, never as a patch hash. Inactive dirty buffers cannot silently fall back to saved source. Script-list payload controls are compared only to public current-editor identity and never scraped. Hover/drop do not read source or load/execute referenced scripts; clicking Open is an explicit navigation action. References do not enable tools, authorize mutations, or enter support reports; deletion/retention removes submitted snapshots.
- Model-switch adaptation preserves original history and projects earlier images into fixed text placeholders for non-vision requests. Prior text/descriptions are still sent, but attachment pixels are omitted. Canonical records are validated before projection; current/new images remain capability-gated, and turn-bound image policy is private request metadata rather than provider payload or durable session state.
- Image intake is explicit (picker, Paste, or drop), checks format/dimension/count/size limits, and prepares normalized PNG data. Vision support is checked separately from Agent-tool compatibility; an explicit unknown-profile setting is a user assertion, not a vision-quality probe. Godot decodes clipboard pixels before Orca can check the returned dimensions.
- Desktop attachments use an Orca-owned separate native drop/Browse window. Desktop files dropped onto the main editor/dock still follow Godot's own project import behavior. Orca does not replace editor drop callbacks, delete imported project assets, or silently redirect project writes.
- Project context and file contents may be sent to the configured model provider. Use only providers and endpoints you trust.
- Editable endpoints are strictly parsed and normalized. Loopback endpoints may use HTTP without confirmation; LAN and remote endpoints require explicit confirmation bound to their exact scheme, host, and effective port before credentials, prompts, or project context can be sent.
- Changing a confirmed endpoint's scheme, host, or port requires confirmation again. Plain HTTP outside loopback is explicitly identified as unencrypted. Confirmation is informed consent, not certificate pinning, DNS pinning, or proof that the server will not forward received data.
- Provider chat and model discovery do not follow HTTP redirects, preventing Orca from forwarding provider credentials to redirect targets.
- Plugin updates are explicitly confirmed user maintenance, never agent tools. Automatic checks disclose only ordinary public GitHub request metadata; no account/provider credentials or project/conversation data are sent. Installation requires an exact official stable asset URL/digest, bounded ZIP/manifest validation, clean current-editor work, unchanged installed files and exclusive updater ownership. The trusted independent installer replaces only the addon after editor exit, retains verified rollback/recovery data and refuses modified backups. The `.orca-update` workspace is inaccessible to agent tools. Other editors must be closed and graphical/Windows/macOS acceptance remains separate; checksums verify the selected GitHub release, not an independent code-signing authority.
- Editable OpenAI-compatible endpoints and fixed-provider origin overrides start Chat-only. **Test & Enable Agent tools** supplies explicit user intent before the isolated synthetic round trip and enables only after an exact matching provider/origin/model/request/probe-version pass. The toggle permits manual opt-out; restored disabled passes, stale results, cancelled actions, and changed profiles do not automatically enable tools. A probe pass does not guarantee planning quality or reliable behavior on real tasks.
- The compatibility probe sends no project instructions, skills, editor context, tasks, conversation history, or real tool schema. Ordinary Chat requests may still include the disclosed bounded request-scoped editor context and prior visible conversation needed to answer the user.
- Foundry Responses requests use only Orca function tools, `store=false`, disabled server truncation, and bounded active-turn encrypted reasoning replay. Opaque continuation is exact-profile-bound, excluded from session/support data, stripped from Chat requests, and cleared at turn end. No server conversation IDs, hosted tools, or automatic server compaction are used. API mode and continuation style are part of Agent compatibility. Synthetic mismatch previews are memory-only, bounded, and redact the original challenge; they do not relax the acknowledgement gate.
- Explicit Azure DeepSeek compatibility additionally retains bounded plain reasoning only in active private continuation and consumes one exact bounded leading closing delimiter. It does not display/persist private reasoning, parse arbitrary inline reasoning blocks, strip general markup, or loosen exact tool/challenge validation. Format-version binding invalidates older DeepSeek passes; Standard profiles retain their prior behavior.
- Native local model discovery performs one same-origin redirect-free list request and does not issue per-model detail probes. Known embedding models are hidden for usability, not as a security guarantee; manual model IDs remain permitted and are still subject to transport and compatibility checks.
- A root `res://AGENTS.md` and bounded skill catalog metadata are automatically added to each request when present. They are treated as untrusted project guidance, cannot grant permissions, and are removed from durable continuation history after the turn; an exact skill body is sent only after `read_project_skill` is called.
- Project instructions and skill files reject symbolic-link traversal and enforce UTF-8, byte, line, and metadata bounds. These controls limit exposure and editor work but do not make model providers trusted.
- `inspect_godot_api` reflects public `ClassDB` metadata and creates validated editor Help topics without constructing reflected objects or scraping documentation prose.
- Unsaved source returned by `read_gdscript_function` is read-only editor context and never supplies a disk hash for patching. Serialized dependency discovery does not load or instantiate resources and does not claim dynamic or runtime references.
- `inspect_editor_scene` reads only bounded existing current-scene native state, including unsaved changes, through fixed core getter paths without script-defined getter callbacks. Scene/instance/script/resource identities retain project, symlink, and protected-addon boundaries. It never saves or instantiates nodes, supplies a patch hash, or persists raw node snapshots as activity data.
- Repetitive tool activity and the 12-round execution boundary receive one no-tools finalization request; attempts to call tools again are denied without execution. The independent limit of 16 calls per provider response remains authoritative.
- Loading or validating Godot scenes and scripts is not a security sandbox. Script preparation has an explicit trust step, but Godot may execute project code during candidate construction.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the full documented threat model and limitations.
