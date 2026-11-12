# Orca

Orca is a safety-first AI development assistant integrated into the Godot editor.

The published baseline is **Orca 1.7.0 — Multilingual UI & Focused Godot Inspection**
for Godot 4.7.2. It adds English/Simplified Chinese/Spanish/Japanese/Korean
interface localization, focused scene/animation exploration and a quiet community
invitation to 1.6.0's session-authorized script edits and durable recovery.
This checkout additionally contains unreleased card readability, longer-task and
Undo-preserving current-scene script attachment improvements. **Apply in editor**
keeps the scene open and leaves saving to the user; both trust and change approval
remain required. The expanded checklist offers same-conversation task Resume.
Plugin ZIPs are binary-free. On enable, Orca quietly downloads and verifies this
platform's credential helper from the matching official GitHub Release if missing.
Helpers are cached outside the project, with no install prompt or update notice.
Early Cloud sign-in waits in the existing Account page; BYOK/local providers stay
usable. Release-commit Tests/native packaging and publication passed for 1.7.0;
the new source changes require their own CI/package run. Native-speaker review, real-model
language/inspection acceptance, broader platforms and Asset Store moderation
remain separate. See the
[1.7.0 changelog entry](https://github.com/cold-atom/Orca/blob/main/CHANGELOG.md#170---2026-11-06)
for the published release, the
[1.6.0 changelog entry](https://github.com/cold-atom/Orca/blob/main/CHANGELOG.md#160---2026-11-05)
for the published baseline, the
[1.5.0 changelog entry](https://github.com/cold-atom/Orca/blob/main/CHANGELOG.md#150---2026-11-02)
for code navigation and the
[1.4.0 changelog entry](https://github.com/cold-atom/Orca/blob/main/CHANGELOG.md#140---2026-10-29)
for the earlier full feature list.

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

## Focused Godot inspection (1.7.0)

This source checkout adds exact-node/subtree saved-scene inspection, read-only
animation library/track/keyframe reads, bounded compact directory listing,
Inspector-target context and individually clickable text-search results. Original
evidence stays unchanged across language selection. Extended Cloud tools require
matching backend API rollout and a model-catalog refresh; older catalogs retain
the original schemas. Animation reads never load scenes/scripts or play animations.
These additions shipped in 1.7.0.

## Interface languages (1.7.0)

**Settings → System → Language** offers **English**, **简体中文**, **Español**,
**日本語** and **한국어**.
The choice is remembered locally across editor restarts/projects and refreshes
Orca without clearing drafts, attachments, conversations or reviews. Translations
are bundled and work offline. Godot's editor/project locale is independent.
Replies follow explicit requests and the message language, using the selected
interface language when unclear; the preference is held through each active turn.
Original messages, code, model/path identities and raw evidence remain intact.
See the
[localization guide](https://github.com/cold-atom/Orca/blob/main/docs/LOCALIZATION.md).

## Quiet community invitation (1.7.0)

After sustained use, a small dismissible card may invite you to star Orca on
GitHub or review it on the Godot Store. It waits for idle time and keeps the
welcome/feed/composer layout intact. Links open only on click. Don't ask again
or either support-link click retires it permanently; otherwise at most one later
reminder can appear after sixty days and further use. Only bounded local usage
counters are stored, without project/account identity, conversation data or telemetry.

## Safety Model

- Plan mode is read-only.
- A Plan turn can ask once to switch to Work, but it waits for an explicit user decision and the switch does not approve a file change.
- Work defaults to Review edits. Explicit Auto apply can authorize bounded project `.gd` patches for one session or be remembered locally for this project; other changes retain original-proposal approval.
- File proposals use content hashes, validation, stale-state checks, and guarded revert data.
- Project access, tool output, network inactivity, and Orca-owned game processes are bounded.
- Root project instructions and skill catalog metadata are request-scoped guidance; skill bodies load only through the read-only `read_project_skill` tool.
- Godot API reflection, focused GDScript function reads, and serialized dependency discovery are read-only in Plan and Work.
- Provider failures after complete tool rounds are collapsed into sanitized recovery checkpoints, allowing the conversation to continue without replaying prior actions.

Review recorded changes and use source control. Orca does not replace code review, backups, or project testing.

## Auto Apply & Script Recovery (1.6.0)

Click **Review edits** in an empty chat, or the small edit icon beside **ORCA** in an existing conversation, and confirm
**Allow edits**, in idle Work or while reviewing an eligible script. Orca will
apply validated project `.gd` patches automatically and continue, retaining
inline red/green diff cards with Open File, Expand Diff and guarded Revert. Click
the green edit icon beside **ORCA** to revoke before the next write, including during a request.
The large floating chip disappears when Auto apply is enabled or the conversation
starts; the compact header icon leaves response text and diffs unobstructed.

Leave **Remember for this project** unchecked for one session, or check it to use
Auto apply in future Work conversations and editor restarts for this project.
**Settings → System → Script edits** exposes the same confirmed choice. Clicking
the green header edit icon immediately revokes permission and clears the remembered default.
The preference lives in local EditorSettings outside project files/history.

Old runtime grants clear on New Session, History restoration, Plan selection and
reload; only resumable Work sessions may reacquire the exact remembered default.
Plan and view-only history remain read-only. Scripts in `addons/`, scene/configuration changes and
script-execution trust keep explicit review. Dirty files, stale hashes and invalid
source remain blocked. Each automatic source version is limited to 256 KiB / 8000
lines; larger patches use review.

Automatic edits require a durable previous/proposed-source checkpoint before
writing. History can expand the recorded diff and explicitly revert after restart,
provided current disk/editor state still matches. Interrupted records offer
**Check recovery** and never replay a write. The journal is plaintext local data,
bounded to 64 records / 4 MiB per conversation and deleted with that conversation.
It does not enter model continuation/support reports or restore permission.
Stop keeps completed edits; Revert is a separate idle-Work action.

## Live Scene Context

Ask about the selected nodes or current scene to inspect native UI layout, 2D/3D transforms, visibility/processing, parent Control/Container context, and script/resource identities. `inspect_editor_scene` works with unsaved changes in Plan and Work; specify scene or subtree scope for hierarchy reads. Detailed snapshots are bounded and requested on demand. Saved-state checks and reviewed project changes still apply; live snapshots never provide a patch hash. Restored tool activity is a historical summary rather than current editor state.

### Current-scene property editing (unreleased)

In Work, ask Orca to change a Node2D position/rotation/scale/skew or a Control
anchor/offset in the saved current scene. Review the typed previous/proposed
values and any derived anchor-preset transition, then choose **Apply in editor**.
The scene stays open with native Undo/Redo; save it before running. **Revert in
editor** adds a conflict-checked inverse action. Script Auto apply does not approve
native properties. Node2D transforms accept local nodes and instance roots with
non-@tool GDScript, resources and signals using text-only saved provenance. Control
layout retains scriptless/resource-free/connection-free and non-Container limits.
Save first; @tool scenes and internal non-editable instance nodes need separate support.

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

## Project Code Navigation (1.5.0)

`find_project_symbols` locates saved `.gd` classes, functions, signals, members,
constants and named enums. `find_symbol_references` returns whole-identifier
lexical use candidates excluding comments/strings. Both work in Plan and Work,
report bounded excerpts/locations and offer clickable result rows. Dirty scripts
are omitted with incomplete coverage; explicit dirty files require saving. There
is no semantic/dynamic/scene-connection coverage, persistent index or patch hash.
Cloud additionally requires the new authenticated catalog advertisement after
backend deployment/refresh; old catalogs retain existing tools. These tools are
included in published 1.5.0 and absent from the older 1.4.1 ZIP.

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
the matching platform helper. Complete 1.4.1 CI/native acceptance passed; real
downloaded-helper/browser and graphical platform acceptance remain separate.
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

The **Request Timeouts** card in **Settings → Provider** groups response timing separately from model and compatibility settings. Ollama, LM Studio and Local OpenAI-compatible expose **Response start** and **Stream inactivity** directly, defaulting to 300/60 seconds. Values display seconds, accept 10–600, and persist per provider. Response start spans headers and initial data; inactivity limits subsequent pauses.

Hosted BYOK profiles use Orca's original 30-second response-header wait, 60-second body-inactivity wait and 45-second Agent test by default. Enable **Use custom timeouts** to reveal/use your own limits; turning it off retains custom values and restores the original policy. Local/customized two-step checks get one bounded total budget based on the selected waits, without invalidating protocol passes. Full requests remain capped at ten minutes and can be stopped. Orca Cloud keeps fixed timing and hides the whole card.

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
