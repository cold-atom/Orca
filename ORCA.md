# Orca: The Godot AI Assistant

## Overview
Orca (formerly GodoPilot) is an autonomous AI coding assistant integrated directly into the Godot Engine. It acts as an Editor Plugin, providing a docked chat interface where developers can interact with an AI agent powered by Large Language Models (LLMs). 

Instead of just answering questions, Orca uses **Function Calling** to actively participate in the development process. It can browse the project, read scripts, and propose reviewed code changes within the Godot workspace.

## Development Documentation

- [`AGENTS.md`](AGENTS.md) contains mandatory repository instructions and a quick architecture map for coding agents.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) contains the current implementation state, architecture, tool contracts, safety model, testing process, limitations, decisions, roadmap, and milestone log.

## What We Have (Current State)
Orca 1.4.0 is released for Godot 4.7.2 in `addons/orca/`. Windows/macOS native CI and downloaded-plugin/update acceptance remain pending.

### Key Features & Components
1. **Editor Integration (`orca.gd`, `orca.tscn`, `chat_window.tscn`)**
   - Registers as a Godot `@tool` plugin.
   - Adds a toggle button to the main editor toolbar.
   - Docks a chat UI to the right-hand side of the editor for seamless interaction.
2. **Agent Controller (`agent_controller.gd`)**
   - Manages the conversational context (message history) and system prompts.
   - Acts as the orchestrator, intercepting tool call requests from the AI, executing them, and sending the results back to the LLM to continue its thought process.
3. **API Client (`api_client.gd`)**
   - Handles streamed `HTTPClient` communication with OpenAI-compatible APIs, including OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, and compatible local servers.
   - Streams text and tool calls incrementally and supports cancellation.
   - Uses request-scoped provider profiles so one turn cannot switch endpoint, model, or reasoning configuration during tool follow-ups.
   - Binds every transport event to a controller-owned provider request ID and every request-scoped UI event to one turn ID, preventing delayed callbacks from changing a newer turn.
   - Strictly normalizes editable endpoints, allows loopback directly, requires exact-origin confirmation for LAN/remote destinations, and refuses provider redirects.
    - LM Studio, Ollama, and Local OpenAI-compatible requests combine system instructions and fresh context into one leading system message for strict local chat templates, preserving controller history and conversation/tool ordering.
     - Microsoft Foundry / Azure supports stateless Responses for reasoning-enabled GPT tool use, plus explicit Chat Completions/`none` reasoning and DeepSeek continuation settings. Explicit DeepSeek mode preserves private plain reasoning and normalizes one leaked leading `</think>` delimiter in both APIs. API/style/format changes require a matching compatibility probe. Bounded private reasoning and assistant phases are replayed only within the active turn, never saved or displayed.
4. **Autonomous Tools (`tools.gd`)**
   - Provides specific capabilities to the AI:
      - `list_directory`: Lists all folders and files inside a specified `res://` directory.
      - `read_file`: Reads bounded, numbered line ranges and returns a content hash.
      - `search_files`: Recursively searches project text files with bounded output.
       - `inspect_scene`: Reads bounded saved scene hierarchy, serialized properties, instances, groups, and signal connections through `PackedScene`/`SceneState` without instantiating nodes.
        - `inspect_editor_scene` (1.4.0): Reads the actual current scene, selection, or subtree, including unsaved native layout/transforms and confined script/resource identities. Live snapshots never provide a disk patch hash or change editor state.
      - `inspect_project_settings`: Reads a bounded configuration overview or one allowlisted typed ProjectSettings value without modifying the project.
      - `read_project_skill`: Loads one exact bounded skill body selected from request-scoped metadata discovered at `res://skills/<slug>/SKILL.md`.
      - `inspect_godot_api`: Reflects bounded `ClassDB` signatures, types, inheritance, constants, and enums and provides safe Open Docs navigation without scraping prose.
      - `read_gdscript_function`: Returns one focused function from saved source or the exact unsaved source exposed by the script editor; unsaved source never provides a patch base hash.
      - `discover_dependencies`: Traverses bounded forward dependencies or reverse dependents from saved serialized `ResourceLoader` metadata without loading or instantiating resources.
      - `get_editor_context`: Reads the active scene, selected nodes, active script, caret, and selected code.
      - `get_diagnostics`: Reports Orca validation errors, observed editor errors, and play state.
      - `apply_patch`: Proposes targeted line edits for explicit review and approval.
      - `propose_input_map_changes`: Proposes typed Input Map action and event changes through a dedicated structured review card.
      - `propose_main_scene_change`: Proposes a validated saved scene as the project launch scene with path/UID normalization and guarded revert.
      - `propose_project_settings_changes`: Proposes an atomic typed batch of allowlisted viewport and stretch settings.
      - `propose_scene_changes`: Proposes reviewed typed-root creation, node/property/structure changes, two-stage dependency-free script attach/detach, dependency-free child instances, and bindless signal changes.
      - `run_current_scene` / `run_main_scene`: Start one saved scene in a bounded nonblocking process owned by Orca.
      - `stop_game`: Stops only the active direct process started by Orca.
      - `observe_game_run`: Reads bounded evidence for an exact Orca run without waiting or changing process state.
      - `verify_game_run`: Evaluates immutable pre-launch startup or expected-exit criteria with explicit passed, failed, pending, inconclusive, or unverified results.
   - **Built-in Safety:** Canonical path and symlink checks keep access inside the project and protect Orca's own plugin directory. Writes use conflict checks, validation, diff review, temporary-file replacement, explicit committed/recovery outcomes, final disk verification, and reversible checkpoints. Cleanup warnings remain distinct from uncertain recovery and never weaken live-state conflict checks. Game runs accept no arbitrary commands or PIDs and are bounded to one Orca-owned direct process.
   - **Project Guidance:** Orca automatically loads a bounded root `res://AGENTS.md` and bounded skill catalog metadata into private request-scoped context. Guidance is subordinate to Orca's permissions and safety rules, removed after the turn, and skill bodies require an explicit read-only tool call.
5. **Agent Modes and Review**
   - Plan mode exposes only read-only tools plus one explicit `request_work_mode` escalation when the user asked for implementation or execution. Orca waits for `Stay in Plan` or `Switch to Work`; approval applies only to the next provider continuation and does not approve a project change.
   - Work mode can propose patches, but every change requires explicit user approval.
   - Consecutive read-only activity is grouped with aggregate status and duration while retaining each call's details and navigation.
   - Unified diffs, expanded side-by-side review, and file navigation make agent work visible.
   - Completed responses render fenced code in bounded selectable blocks with language labels, Copy actions, and native GDScript highlighting.
    - Compact per-answer footers show the full configured model ID and generating Plan/Work mode, preserving attribution through switches and restored history. Long names wrap with full identifier tooltips; no provider/reasoning detail is added.
    - Native minimaps and synchronized scrolling in expanded reviews use the Godot code palette; narrow windows stack the panes. Plain Tab in the focused composer toggles Plan/Work when idle while preserving the draft and attachments.
   - A mode-colored five-square working indicator shows initial thinking, post-tool response preparation, and runtime observation without creating empty assistant messages during first-token delays.
   - Active turns automatically follow late-sizing response, tool, and review cards so the newest activity and sequential approvals remain visible.
    - Repeated identical calls/results, alternating cycles, repeated rounds, sustained no-progress rounds, or the 12-round boundary trigger one visibly identified safe-finalization request with tools disabled. A provider that still requests tools is denied and the user receives explicit non-replay continuation guidance.
6. **Sessions and Usage**
   - Conversations are automatically saved in bounded, project-scoped local history and the most recent session is restored when the editor reopens.
   - The History page can open, continue, or delete prior sessions. Provider failures after complete tool rounds use sanitized, non-replayable recovery checkpoints; unsafe, cancelled, dirty, or truncated sessions remain view-only.
   - The header New Session action archives the current conversation and restores the empty state without undoing already-applied project changes.
    - Provider-reported token usage is accumulated across all model requests in a session, including tool follow-up rounds.
    - The header shows current context use and session cost when model metadata is available.
    - Known model context windows are budgeted conservatively before every request, with capacity reserved for tool results and a final answer. Old complete turns are omitted atomically when needed without splitting tool-call/result groups.
    - Provider completions require visible non-whitespace text or a valid tool call, and a total generation deadline bounds continuously active hidden reasoning in addition to connection and inactivity timeouts.
     - Orca prefers provider-reported cost, then automatically resolves public model context and pricing metadata from a cached `models.dev` catalog with built-in offline fallbacks.
    - Multi-step work can maintain a bounded persistent checklist with pending, active, completed, blocked, and cancelled states.
7. **Configuration (`config.gd`, `settings_view.gd`)**
    - Provides an in-dock settings page for managed Orca Cloud accounts and BYOK/local OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Microsoft Foundry / Azure, Ollama, LM Studio, Local OpenAI-compatible, and custom OpenAI-compatible endpoints.
   - Stores separate API key, endpoint, model, and reasoning-effort selections per provider and discovers bounded model lists from provider APIs. Editable profiles start in Chat mode; **Test & Enable Agent tools** runs the isolated synthetic function-call probe and enables only after an exact matching pass. The toggle preserves manual opt-out, including when reopening Settings.
   - The version 2 compatibility probe includes synthetic refreshed system context after its tool result. Older passes require retesting and explicit tool enablement; no project context is used by the probe.
   - Uses Ollama `/api/tags` and LM Studio `/api/v1/models` metadata to hide known embedding models, with a conservative name fallback and unrestricted manual Model ID override.
   - Integrates with Godot's Editor Settings for persistence. Editor Settings is not an encrypted OS credential store.
    - The About page copies a memory-only strict-allowlist support report with Orca/Godot versions and coarse provider/request state while excluding endpoint addresses, credentials, model IDs, project and conversation data, model output, logs, file changes, and hashes.
     - Provider, System, Account, and About use icon navigation. System currently shows English only; About links to Orca docs, website, source, issues, and feature discussions. Managed account credentials use the OS vault rather than EditorSettings.
8. **Image References (1.3.0)**
    - Attach up to four bounded PNG/JPEG/WebP still images with floating previews, removal, and larger preview actions. Vision capability is model/endpoint-specific and independent of Agent-tool support.
    - Paste screenshot pixels into the composer or drag existing project images from Godot's FileSystem dock. Desktop files use the image button's separate native drop/Browse window; dropping them onto the main editor still invokes Godot import.
     - Images are normalized and included in multimodal requests throughout tool follow-ups, with conservative image context reserves and deduplicated project-scoped local history. Submitted images restore after restart and are deleted with the conversation; pending drafts are memory-only.
      - Switch between vision and text-only models within the same session. Text-only requests use explicit placeholders for earlier images and retain prior descriptions; original images/previews stay intact and return to vision requests when still in retained context. New images require confirmed input support, and model/image policy changes apply to the next turn.

9. **Script References (1.4.0)**
    - Drag standalone project `.gd` files from Godot's FileSystem dock or open-script list into the composer as compact removable/navigable chips.
    - Include up to four bounded 300-line / 16 KiB source snapshots at Send, with saved/active-unsaved provenance and explicit truncation. Inactive dirty source requires activation or saving.
    - References work with Chat-only/text-only models and images. Canonical per-message snapshots persist in project history; outgoing copies materialize untrusted user context and budgeting counts it. Normal fresh hashes and approvals remain required for edits.

## Account, Onboarding And Updates (1.4.0)

### Connection onboarding

The original empty state remains intact. First-visible-open setup for unconfigured
users and setup-needed Send share one conversation-area overlay with **Sign in /
Sign up with Orca**, **Bring your own API key** (including local models), Close and
**Set up later**. Restoration settles before automatic display. Dismissal keeps it
closed until setup-needed Send; the composer stays available. Preflight occurs
before source-reference reads or conversation entries, preserving draft text,
selection and attachments. Account actions reuse
browser pairing and automatic managed selection; provider/model actions open the
existing Settings flows. Setup never automatically sends the draft. Configured
users retain the ordinary empty state, and keyless local profiles remain supported.

### Plugin updates

Daily stable GitHub release checks and a dismissible dock notice help users discover
updates before Asset Library moderation completes. General Settings provides manual checking,
release notes, an automatic-check preference and confirmed Update & Restart/rollback.
Official packages are bounded and verified against release/file manifests; local
changes are preserved. A trusted independent installer waits for editor exit, retains
the original addon and reopens the same project. The first updater-equipped package
is installed manually once. This is user-owned maintenance, separate from agent tools.
Complete build downloads use `orca-package`, containing `orca-v1.4.0.zip` and its
checksum. The optional helper bundle supports local source packaging; commit-based
Asset Library releases need the tested helpers and generated manifest in their
selected commit. See `docs/UPDATES.md` for manual and workflow publication steps.

### Orca Account integration

Settings includes an Account tab with browser sign-up/sign-in, persistent OS-vault
credentials, allowance/plan display, Console navigation and sign-out. One managed
Orca Cloud provider discovers account-eligible models from `https://cloud.aiorca.dev`.
Hosted requests retain exact tool compatibility, turn binding, private continuation
and normal project approvals. Linux native persistence and real two-process
Godot/FastAPI fixtures are verified, and Godot HTTPS health checks pass. The native
Actions workflow now builds/tests Linux/Windows x86_64 and Apple Silicon/Intel Mac
helpers and assembles one complete plugin ZIP plus a reusable helper bundle.
Windows/macOS CI execution and downloaded-plugin acceptance remain pending.
After the localhost-to-production switch, sign in again against the deployed
account database. See the addon setup guide for the account workflow.

Managed profiles are now ready automatically after sign-in/model selection through
operator-verified capability records. Subscriber compatibility/effort controls are
removed; custom/local profiles retain their checks. Full-context regression covers
the previous greeting-budget failure with context and billing estimates separated.

## What We Are Building (The Vision)

We are building a truly autonomous copilot for game development in Godot, similar to GitHub Copilot or Roo Code (formerly Cline), but deeply integrated into the Godot ecosystem. The goal is to move beyond simple chat interfaces to an AI agent that understands the full context of a Godot project.

### Future Goals
- **Expanded Toolset:** Broaden current reflected Godot API lookup and constrained scene/configuration capabilities without weakening review boundaries.
- **Deeper Context Awareness:** Expand the implemented live scene-tree/native-property inspection and add project symbol indexing.
- **Structured Godot Operations:** Reviewed Input Map, project configuration, and scene-tree proposals built on bounded typed inspection.
- **Debugging Assistant:** Bounded automatic post-launch observation, conservative runtime diagnostics, reviewed fixes, explicit reruns, and scoped startup/exit verification without claiming visual gameplay correctness.
- **Local-First Focus:** Ensuring the plugin works flawlessly with locally-hosted, fast open-source models (like Llama 3 or Qwen) for privacy-conscious developers.
- **Robustness:** Refining error handling for complex edge cases (e.g., massive files, connection timeouts) and creating better syntax parsing.
- **Seamless Desktop Attachment Drops:** Investigate public cancellable Godot drop routing or propose an engine enhancement; retain the separate native window until direct composer drops can be proven not to import project files.

Progressive tool-schema disclosure remains a future optimization and is not currently implemented.

Orca aims to be an essential sidekick for Godot developers, handling boilerplate code, exploring unfamiliar APIs, and accelerating the game development workflow securely and efficiently.
