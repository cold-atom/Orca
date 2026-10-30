# Orca

Orca is a safety-first AI development assistant integrated into the Godot editor.

This directory contains the Orca 1.4.1 release-candidate addon for Godot 4.7.2,
a packaging follow-up to 1.4.0's Godot Asset Store rejection for bundled executables.
Plugin ZIPs are binary-free. On enable, Orca quietly downloads and verifies this
platform's credential helper from the matching official GitHub Release if missing.
Helpers are cached outside the project, with no install prompt or update notice.
Early Cloud sign-in waits in the existing Account page; BYOK/local providers stay
usable. Publication, Asset Store approval and Windows/macOS downloaded-helper
acceptance remain pending. For the full feature list, see the
[1.4.0 changelog entry](https://github.com/cold-atom/Orca/blob/main/CHANGELOG.md#140---2026-10-29).

## Install

1. Copy `addons/orca/` into your Godot project's `addons/` directory.
2. Open the project in Godot 4.7.2.
3. Enable **Orca** in **Project > Project Settings > Plugins**.
4. Open the Orca dock and connect an account or provider.

### Connection setup overlay

The original **Work with Orca** empty state stays intact. On a new unconfigured
dock's first visible opening, a separate overlay offers **Sign in / Sign up with
Orca** to start browser pairing or **Bring your own API key** for hosted/local
Provider Settings. Close, Escape or **Set up later** dismisses it; it reappears
when you press Send without setup. Account restoration settles before automatic
display. The composer remains available, with text, selection and attachments kept.
Missing models open the picker; configured local providers can work without keys.
Finish setup with **Done**, then press **Send** when ready. Setup never sends your
draft automatically. Existing configured users retain the normal chat empty state.

## Safety Model

- Plan mode is read-only.
- A Plan turn can ask once to switch to Work, but it waits for an explicit user decision and the switch does not approve a file change.
- Work mode can prepare changes, but every model-requested project change requires explicit approval.
- File proposals use content hashes, validation, stale-state checks, and guarded revert data.
- Project access, tool output, network inactivity, and Orca-owned game processes are bounded.
- Root project instructions and skill catalog metadata are request-scoped guidance; skill bodies load only through the read-only `read_project_skill` tool.
- Godot API reflection, focused GDScript function reads, and serialized dependency discovery are read-only in Plan and Work.
- Provider failures after complete tool rounds are collapsed into sanitized recovery checkpoints, allowing the conversation to continue without replaying prior actions.

Always review proposed changes and use source control. Orca does not replace code review, backups, or project testing.

## Live Scene Context

Ask about the selected nodes or current scene to inspect native UI layout, 2D/3D transforms, visibility/processing, parent Control/Container context, and script/resource identities. `inspect_editor_scene` works with unsaved changes in Plan and Work; specify scene or subtree scope for hierarchy reads. Detailed snapshots are bounded and requested on demand. Saved-state checks and reviewed project changes still apply; live snapshots never provide a patch hash. Restored tool activity is a historical summary rather than current editor state.

## Response Attribution

Assistant cards show the full configured model ID on the left and the generating request's Plan/Work mode on the right. Footers use Orca's metadata styling, wrap long identifiers with complete tooltips, and restore from per-answer history. Settings changes do not relabel earlier answers; unknown legacy and locally generated reports have no fabricated model attribution.

## Image Attachments

- Choose a vision-capable model, click the image icon, and use Browse or drop PNG/JPEG/WebP still images into Orca's separate attachment window. Up to four images can be attached per message.
- Paste copied screenshot/image pixels into the input with Ctrl/Cmd+V or context-menu Paste. Existing project images can also be dragged from Godot's FileSystem dock.
- Thumbnails float above the input with Remove and larger-preview actions; submitted images restore with conversation history.
- **Drop desktop files into the attachment window, not the main editor.** Godot imports desktop files dropped on its main window/dock into the selected project folder.
- Image capability is model/endpoint-specific. Unconfirmed profiles offer an explicit setting under Provider; vision support does not enable Agent tools.
- Sessions can switch between vision and text-only models. Earlier images become placeholders only in text-only request copies; original previews/history remain intact and images return to vision requests when retained in context. New drafts still require confirmed image input, and active tool turns retain one model/image policy.
- Source images are bounded to 10 MiB and 16 megapixels, resized to at most 2048 pixels per side, and normalized to at most 1 MiB each. Documents, PDFs, animation, and automatic screenshots are not supported.

## Script References

Drag up to four project `.gd` scripts from the FileSystem dock or open-script list onto the composer. Removable file chips appear above the input; click to open or hover for the full path. Press Send to include bounded source alongside your prompt, including with text-only/Chat-only models or image attachments. Source is captured at Send and capped at 300 lines / 16 KiB per script. Active unsaved text is supported; activate or save an inactive dirty script before submitting. Submitted references and source snapshots remain attached to their message and restore with History as plaintext local data. Referencing a script does not approve edits or enable Agent tools.

## Plugin Updates

Stable GitHub Releases are checked daily; a small notice offers **What's new**,
**Update & Restart**, and **Later**. General Settings includes manual checking, the automatic
check preference, progress/cancellation and rollback. Save editor work and finish
Orca/game activity before confirming a restart. The updater verifies the official
ZIP and release manifest, preserves local addon modifications, and replaces only
this project's addon after the editor exits. One verified previous version is kept
for rollback. Account credentials/history remain in their existing storage.

Install the first updater-equipped official package manually once. Development
checkouts and older packages without a manifest use manual installation. See the
[update/release/recovery guide](https://github.com/cold-atom/Orca/blob/main/docs/UPDATES.md).

## Providers And Data

### Orca Account

1. Update the addon and restart the editor. Orca Cloud uses `https://cloud.aiorca.dev`;
   its API base is `https://cloud.aiorca.dev/v1`.
2. Open **Settings → Account**, then **Sign in / Sign up**. Sign in/register in the
   browser and approve the matching editor code. Expired pairing can be restarted.
3. An included model activates automatically. Use **Choose model** to switch and
   **Done** to return to chat. Managed profiles use tested server defaults and
   operator-verified tool capability; no Test & Enable or reasoning configuration
   is required. Account access is checked by the backend and project edits retain
   normal Plan/Work and approval checks.
4. Your connection restores across projects/restarts. Access tokens stay in memory;
   refresh credentials are stored in the native OS vault, not EditorSettings or
   conversation JSON. Refresh rotation is locked across editors. Sign-out erases
   the owned saved connection and attempts backend revocation with a current token.

Linux x86_64 needs a running Secret Service/libsecret collection. Unlock the OS
vault if requested. There is no plaintext fallback. The native GitHub Actions
workflow builds/tests Linux/Windows x86_64 and Apple Silicon/Intel Mac helpers,
then publishes them separately from the binary-free addon ZIP. Orca downloads only
the matching platform helper. Earlier native build/acceptance jobs passed; complete
1.4.1 CI and real downloaded-plugin acceptance remain pending.
See [native bridge builds](native/README.md).
The HTTPS origin is fixed in the
hosted adapter. **Open Console** opens `https://cloud.aiorca.dev/account`.
Saved credentials are bound to this origin: after switching from local development,
sign in again. The deployed service has its own account database, so a development
account may need registration there.

Cloud sends relevant context through Orca Cloud to its selected provider. Its
downstream transport is Chat even for Sol's server-side Responses bridge. Private
continuation is active-turn-only. Accepted failures/Stop never replay tool work;
remaining/reserved allowance is visible in Account/Console. Backend sessions
currently have an absolute lifetime, so expiry/revocation can require reauthentication.

Orca supports managed Orca Cloud accounts and BYOK/local OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, Local OpenAI-compatible, and custom OpenAI-compatible endpoints through Chat Completions, plus Microsoft Foundry / Azure Responses support. Editable profiles start in Chat mode. Click **Test & Enable Agent tools** to run the project-free compatibility probe and automatically enable tools after a matching pass. Users can turn tools off with the toggle; failures, cancellation, and changed profiles do not enable them.

### Microsoft Foundry / Azure

1. Select **Microsoft Foundry / Azure**, enter your API key, the resource base URL `https://<resource>.openai.azure.com/openai/v1`, and the exact **deployment name**.
2. For GPT deployments such as `gpt-6-luna` and `gpt-6.1-sol`, use **Responses (reasoning + tools)** and Provider default or a supported explicit effort. Responses requests use `store=false`; Orca retains opaque reasoning only during the active tool turn, not in saved history.
3. If using **Chat Completions** with a GPT deployment whose error requires it, select **Reasoning Effort: None**. Provider default does not disable reasoning. Generic OpenAI-compatible profiles also expose this explicit option.
4. For Azure DeepSeek deployments, select **Reasoning Continuation: DeepSeek reasoning**. This retains private reasoning through Chat or Responses tool follow-ups and handles the observed leaked leading `</think>` delimiter. Standard remains the choice for other models. This setting works with custom deployment names; changing it requires retesting.
5. Confirm the exact endpoint origin and run **Test & Enable Agent tools**. A matching pass turns the toggle on automatically; click **Done** to save the provider form. Changing API, continuation style, effort, deployment, or endpoint invalidates the corresponding pass. Existing Custom credentials/passes are not migrated to Azure.

A failed final acknowledgement shows a bounded, challenge-redacted synthetic reply and distinguishes formatting from a missing/changed acknowledgement. DeepSeek handling consumes only one exact leading delimiter; it does not loosen the acknowledgement check. Private reasoning (encrypted or DeepSeek plain content) is retained only during the active turn, never in visible/stored history. A pass verifies one synthetic exchange, not arbitrary model competence. Live deployment and region acceptance are still required; automatic model discovery, server-stored conversations, hosted Responses tools, and cross-turn reasoning persistence are not included.

Native Ollama and LM Studio discovery hides models identified as embeddings. The manual Model ID remains available for unusual or unclassified models.

Prompts, attached images, relevant editor context, and project content returned by Orca's tools may be sent to the selected provider. BYOK API keys are saved through Godot Editor Settings; managed account refresh/session credentials use the OS vault and access tokens stay in memory. Project-scoped session history (including submitted images/script snapshots) is plaintext JSON under Godot's `user://` storage. Submitted attachments are removed with conversation deletion/retention; pending drafts are memory-only. Provider EditorSettings and conversation JSON are not encrypted OS credential-vault storage.

If present, `res://AGENTS.md` and skill catalog metadata from `res://skills/<slug>/SKILL.md` are automatically sent as private request context. A skill body is sent only after an explicit tool call. Request-scoped guidance is not retained in resumable conversation history.

## Resources

- Website: https://www.aiorca.dev/
- Documentation: https://www.aiorca.dev/docs/
- Source and releases: https://github.com/cold-atom/Orca
- Issues: https://github.com/cold-atom/Orca/issues
- Ideas and feature requests: https://github.com/cold-atom/Orca/discussions

## License

Orca source code is distributed under the MIT License included in this directory. Bundled third-party assets may carry their own license terms and attribution requirements.
