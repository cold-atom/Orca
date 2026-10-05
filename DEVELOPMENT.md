# Orca Development Guide

Last updated: 2026-10-05

## Purpose

This document is the living technical source of truth for Orca. It records what the plugin currently does, how its systems fit together, which safety contracts must be preserved, how work is verified, and what remains to be built.

Read `AGENTS.md` first for mandatory repository rules, `HANDOVER.md` for the current continuation state, and `ORCA.md` for the shorter product overview.

## Product Direction

Orca is an AI game-development assistant integrated directly into the Godot editor. Its intended workflow is:

```text
Understand the user's editor and project context
-> inspect only the relevant files and Godot state
-> explain or plan the work
-> propose precise reviewed changes in Work mode
-> validate before writing
-> apply only after approval
-> eventually run, observe, fix, and verify the game
```

The current plugin is a functional development-stage agent. It is not yet a production release or a complete autonomous game-development environment.

## Current Capabilities

### Editor Integration

- Native `EditorPlugin` under `addons/orca/`.
- Toolbar toggle and right-side dock.
- Responsive structured chat feed rather than one monolithic text label.
- Completed assistant responses render fenced code as bounded, selectable blocks with language labels, Copy actions, and native GDScript highlighting in the editor.
- Editor-scaled typography and custom geometry across the dock, settings, history, activity, task, and review surfaces.
- Compact line-height-driven composer, transparent branded empty state, descriptive Plan/Work selector, and a current-model shortcut into model settings.
- Transient five-square working states remain visible from submission until actual text or tool activity, distinguish initial thinking from post-tool response preparation, and reuse mode-aware animation for runtime observation and assessment.
- Active turns use multi-frame feed following so newly inserted or late-resizing working, response, tool, and review cards remain at the visible bottom; sequential approvals automatically advance to the next pending card.
- Two-row compact header that keeps session context usage and cost visible at narrow dock widths.
- In-dock settings page with Provider and About tabs, API key configuration, searchable model discovery, provider-reported or conservative known-model reasoning effort, model metadata, release information sourced from `plugin.cfg`, and a Done action.
- First-class OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, and Local OpenAI-compatible profiles plus an advanced custom OpenAI-compatible profile.
- Separate credentials, model, and reasoning-effort selection per provider, with migration from the former global URL/key/model settings.

### Conversation And Streaming

- OpenAI-compatible streamed Chat Completions requests.
- UTF-8-safe Server-Sent Events parsing.
- Incremental assistant text updates.
- Fragmented streamed tool-call reconstruction.
- Stop/cancel behavior with stale-request protection.
- Maximum tool-round limit.
- Mode transition messages that override stale Plan/Work statements in history.
- Provider-reported token accounting across initial and follow-up tool requests.
- Best-effort context-window and session-cost estimates using provider-reported cost, cached public model metadata, and conservative built-in fallbacks.
- Request-scoped provider snapshots prevent endpoint, model, or reasoning changes in the middle of a tool loop.
- Known model context windows are budgeted before every initial and follow-up request using a conservative UTF-8 size estimate, explicit final-answer and tool-result reserves, and oldest-complete-turn compaction.
- Compaction never splits the active turn or an assistant tool-call batch from its complete matching tool results. If the protected request alone exceeds the safe budget, Orca fails before transport rather than sending a predictably oversized request.
- DeepSeek/xAI `reasoning_content` and OpenRouter `reasoning_details` are reconstructed and preserved for tool-call continuation without displaying private chain-of-thought.
- Bounded opaque streamed tool-call metadata is retained so Gemini thought signatures survive multi-round tool continuation.
- Transport failures retain structured category, phase, HTTP status, byte count, retryability, and partial-response metadata through the controller boundary.
- Failed partial responses are marked incomplete in the transcript and are not committed to model history.
- Completed conversations, bounded activity summaries, changed-file summaries, mode, and usage are persisted per project.
- History can restore and continue valid sessions and sanitized recovery checkpoints; unsafe, cancelled, dirty, or truncated sessions are view-only.
- New Session archives the current transcript and restores the empty state while preserving mode, settings, and already-applied files.
- Each turn automatically receives a bounded root `res://AGENTS.md` and bounded project-skill catalog metadata when present. Both are private request-scoped system context and are removed from stored continuation history after the turn.
- Repetitive tool activity is detected below the hard caps. Orca makes one final provider request with tools disabled; tool calls returned from that final request are denied without execution while preserving protocol-valid results.

### Godot Intelligence

- `res://AGENTS.md` is loaded automatically from the project root only, capped at 32 KiB and 400 lines, rejected on invalid UTF-8, NUL bytes, or symbolic-link traversal, and wrapped as untrusted guidance subordinate to system, user, mode, approval, and runtime safety rules.
- Immediate `res://skills/<slug>/SKILL.md` entries contribute only bounded `name`, `description`, slug, and path metadata automatically. A skill body is loaded only through `read_project_skill` using the exact discovered name and is wrapped as non-recursive, non-executable project guidance.
- `inspect_godot_api` reflects `ClassDB` and registered global-class metadata into bounded signatures, type records, hierarchy, properties, signals, constants, and enums. It produces validated Help topics for the editor's public `goto_help()` path but does not scrape documentation prose, load scripts, construct reflected objects, or instantiate scenes.
- `read_gdscript_function` performs bounded lexical extraction of one named function, optional adjacent documentation/annotations, nested-class scope, and one-based navigation. For the exact open unsaved script it uses public editor source and marks it `editor`; that source never carries a disk SHA-256 or becomes a patch base.
- `discover_dependencies` traverses deterministic breadth-first forward dependencies or reverse dependents from `ResourceLoader.get_dependencies()`. It reports saved serialized relationships only and does not load or instantiate resources.
- All four model-callable intelligence tools are read-only and available in Plan and Work.

### Modes

| Mode | Capabilities | UI color |
| --- | --- | --- |
| Plan | Read-only exploration, context, diagnostics, and planning. | Orange |
| Work | Plan capabilities plus reviewed project proposals and bounded Orca-owned game process control. | Green |

Work is the default. Mode switching is blocked while a turn or edit approval is active. Its internal enum remains `BUILD` for session compatibility. Work allows immediate run/stop external operations; only project-file changes enter proposal approval.

### Activity And Review UI

- Consecutive read-only tool calls are collapsed into aggregate activity groups with call count, combined status, and total duration.
- Expanding a group retains each tool card's target, outcome, duration, bounded live output, and navigation action.
- Mutation, unknown, and future non-allowlisted tools remain standalone; change proposals always use dedicated review cards.
- A bounded collapsible checklist above the composer tracks multi-step work with pending, active, completed, blocked, and cancelled states.
- Unified red/green diffs inside the dock.
- Expanded side-by-side Previous/Proposed diff view.
- Apply, Reject, Revert, and Open File actions.
- Validation status on change cards.
- Scripts open at a relevant line and column.
- Scenes and resources open in their corresponding Godot editor.

### Current Tools

| Tool | Modes | Purpose |
| --- | --- | --- |
| `list_directory` | Plan, Work | Lists one project directory. |
| `read_file` | Plan, Work | Reads bounded one-based line ranges with line numbers and a SHA-256 hash. |
| `search_files` | Plan, Work | Recursively searches bounded project text files and returns path/line/column matches. |
| `inspect_scene` | Plan, Work | Reads bounded saved `PackedScene`/`SceneState` hierarchy, serialized properties, instances, groups, and signal connections without node instantiation. |
| `inspect_project_settings` | Plan, Work | Reads a bounded overview or one allowlisted typed ProjectSettings value with active feature overrides. |
| `read_project_skill` | Plan, Work | Loads one exact bounded skill body selected from the request-scoped project skill catalog. |
| `inspect_godot_api` | Plan, Work | Reflects bounded `ClassDB` signatures and safe editor Help topics without object construction or prose scraping. |
| `read_gdscript_function` | Plan, Work | Reads one bounded function from saved source or the exact unsaved editor source for that open script. |
| `discover_dependencies` | Plan, Work | Traverses bounded saved serialized dependencies or reverse dependents without resource loading. |
| `get_editor_context` | Plan, Work | Captures active scene, selected nodes, active script, caret, selected code, and open/unsaved state. |
| `get_diagnostics` | Plan, Work | Reports Orca validation records, observed editor-process errors, and play state. |
| `update_tasks` | Plan, Work | Atomically replaces bounded session task metadata without modifying project files. |
| `apply_patch` | Work only | Materializes precise line edits into a reviewed and validated file proposal. |
| `propose_input_map_changes` | Work only | Prepares bounded typed Input Map action changes for structured approval. |
| `propose_main_scene_change` | Work only | Proposes a validated saved scene as the project launch scene through structured review. |
| `propose_project_settings_changes` | Work only | Proposes an atomic batch of six allowlisted display settings through typed review. |
| `propose_scene_changes` | Work only | Proposes bounded typed scene creation, node, property, script, child-instance, and bindless signal operations. Script changes use preliminary execution trust followed by candidate approval. |
| `run_current_scene` | Work only | Starts the saved current scene in one bounded nonblocking Orca-owned process. |
| `run_main_scene` | Work only | Starts the configured saved main scene in one bounded nonblocking Orca-owned process. |
| `stop_game` | Work only | Stops only the currently retained direct process started by Orca. |
| `observe_game_run` | Plan, Work | Reads an immediate bounded snapshot for an exact Orca run ID. |
| `verify_game_run` | Plan, Work | Evaluates only criteria declared before an exact run and returns a scoped verdict. |

### File Safety

- Only `res://` paths are accepted.
- Simplified paths must remain under the project root.
- Paths containing symbolic links are rejected.
- Agent tools cannot access Orca's own `res://addons/orca/` directory.
- Binary and oversized reads are rejected.
- Search and read output are bounded.
- Scene inspection accepts saved `.tscn` files up to 2 MB, rejects unsaved editor state, and never instantiates scene nodes.
- Project settings inspection uses fixed summary categories, allowlists explicit paths, blocks sensitive-looking names, and caps valid JSON output at 64 KB.
- Automatic project instructions and skill metadata are bounded and request-scoped. Skill bodies require an explicit exact-name read and are never recursively loaded merely because their text references another file.
- Focused script reads enforce canonical `.gd` project paths, symlink and Orca-directory rejection, a 2 MiB source limit, and separate bounded output. Unsaved editor source deliberately omits a disk hash.
- Dependency discovery enforces canonical existing project resources, symlink and Orca-directory rejection, bounded graph traversal, and whole JSON output.
- Input Map proposals target only `res://project.godot`, require its current SHA-256, preserve unrelated bytes, and compare affected disk/live actions before review and apply.
- Main-scene proposals validate a saved `.tscn`, normalize path/UID identity, preserve unrelated project bytes, and synchronize the live ProjectSettings value.
- Low-risk ProjectSettings proposals use an exact six-path allowlist, strict scalar types, conservative dimension caps, and affected live/disk equality.
- Structured scene proposals support typed-root creation, add, typed property, leaf rename/remove/reparent, dependency-free script attach/detach and child instances, and bindless signal operations with hash binding and complete pack/save/load validation.
- Unsaved scripts and scenes cannot be patched.
- Existing files require the SHA-256 returned by `read_file`.
- File existence and hashes are checked during proposal and immediately before replacement.
- Writes use a verified temporary file and recoverable replacement sequence.
- Applied changes retain enough in-memory state for guarded revert.
- Run tools never accept executable, argument, environment, or PID input; they launch only the current Godot executable against this project and retain one owned direct process.

## Architecture

```text
EditorPlugin (orca.gd)
  -> ChatWindow
       -> UiMetrics (effective editor-scale conversion for authored geometry)
       -> structured message/activity/change feed
       -> ChangeCard / InputMapChangeCard / MainSceneChangeCard / ProjectSettingsChangeCard / SceneChangeCard
       -> ToolActivityGroup -> ToolActivityCard children
       -> TaskListPanel
       -> SettingsView -> AgentCompatibilityProbe -> isolated APIClient
       -> HistoryView
       -> SessionStore (project-keyed user:// JSON)
       -> DiagnosticsService
       -> GameProcessService
       -> ModelCatalogService
       -> ProviderModelService
       -> AgentController
              -> APIClient (HTTPClient + SSE) -> EndpointPolicy
             -> ProviderRegistry
                    -> OpenAI / Gemini / xAI / DeepSeek / OpenRouter / Custom adapters
             -> ContextBudget (request estimate, reserves, complete-turn compaction)
             -> ProjectInstructions (request-scoped root guidance)
             -> ProjectSkills (request-scoped catalog and explicit body reads)
             -> ToolLoopGuard (repetition/no-progress finalization)
             -> Tools
                    -> EditorContext
                    -> SceneInspector
                    -> ProjectSettingsInspector
                    -> GodotApiInspector
                    -> GDScriptFunctionReader
                    -> DependencyInspector
                    -> InputMapProposal
                    -> MainSceneProposal
                    -> ProjectSettingsProposal
                    -> SceneProposal
                    -> PatchUtils
                    -> DiffUtils
                    -> DiagnosticsService records
```

### Plugin Lifecycle

`addons/orca/orca.gd` initializes editor settings, instantiates the toolbar and chat dock, registers them with Godot, and removes them when the plugin exits.

### Request Lifecycle

```text
User submits prompt
-> AgentController snapshots the selected provider profile
-> AgentController captures request-scoped editor context
-> AgentController loads bounded root project instructions and skill catalog metadata
-> user message and temporary context are sent to APIClient
-> APIClient streams SSE deltas
-> ChatWindow updates one assistant card
-> complete tool calls are returned to AgentController
-> tools run sequentially
-> tool results are appended to protocol-valid history
-> model continues until a final response
-> temporary editor context is removed from stored history
```

The request-scoped context, including project instructions and skill catalog metadata, remains available through all tool rounds in one turn but does not pollute later turns with stale state. Skill bodies are not included automatically; `read_project_skill` returns one selected body as a normal bounded tool result.
The provider snapshot is also retained through all tool rounds so settings changes cannot mix endpoints or models inside one protocol turn.

Before each provider request, `context_budget.gd` resolves the request-scoped model's known context window, preferring the provider-reported model identity during a tool continuation, and estimates the serialized messages and tool schemas conservatively from UTF-8 bytes plus structural overhead. It reserves bounded capacity for a final answer and, while tools are exposed, for a later tool result. If necessary it replaces the oldest contiguous completed turns with one system notice. Historical tool rounds are removable only when the assistant call, every matching tool result, and the terminal assistant response are complete. The active user turn, provider reasoning continuation, temporary editor context, and runtime observation remain protected. Unknown custom-model limits continue without speculative blocking; an oversized protected request for a known limit fails before transport.

Compaction changes only model continuation history. The visible session transcript remains intact, while later session snapshots naturally persist only retained user/assistant continuation. The internal compaction notice and request-scoped system messages are not persisted.

### Streaming Lifecycle

`api_client.gd` uses a nonblocking `HTTPClient` state machine. It parses SSE lines at byte boundaries so a UTF-8 code point split across transport chunks is not corrupted. Successful SSE bytes are counted but not retained as a duplicate raw response; only bounded JSON and HTTP error bodies are buffered. The raw transport allowance is 16 MiB so token-level JSON/SSE framing does not prematurely reject otherwise bounded model output. It accumulates separately bounded assistant content, provider reasoning, reasoning details, tool-call arguments, and opaque tool-call metadata, then emits a response shaped like a completed Chat Completions response for the controller.

The transport supports:

- Connection timeout.
- Inactivity timeout.
- Response and event size limits.
- Regular JSON fallback for compatible endpoints that ignore streaming.
- Explicit cancellation.
- Request generations that prevent stale callbacks.
- Streamed usage capture through `stream_options.include_usage`, including usage-only events with empty choices.
- One safe retry without `stream_options` when a provider rejects that option before streaming begins.
- One bounded retry for connection failures before the POST is submitted. Requests are not automatically replayed after submission or partial output.
- Positive SSE/JSON content-type handling, including `application/*+json`, and bounded rejection of unexpected successful response types.
- Separate aggregate-response, SSE-line, SSE-event, assistant-text, reasoning, reasoning-detail, tool-argument, and HTTP-error-body limits.

Each completed HTTP request contributes its reported input, output, and cached tokens to the current session, including every continuation in a multi-round tool loop. Current context is the latest provider-reported total-token value. Cost prefers a provider-reported value and otherwise uses automatically resolved model metadata. Missing usage is represented as unavailable or partial rather than estimated locally.

`model_catalog_service.gd` infers known providers from the configured base URL, loads a compact selected-model cache from `EditorSettings`, and refreshes stale metadata from `https://models.dev/api.json` at most once every seven days per provider/model pair. The response is capped at 8 MB. Only public provider/model identifiers are requested; API keys, prompts, file contents, and project context are not sent. `model_metadata.gd` supplies conservative offline fallbacks and normalizes context windows and per-million-token rates. Unknown custom endpoints continue working, but cost or context limits remain unavailable when neither the provider nor a trusted catalog supplies them.

`provider_model_service.gd` requests the selected provider's model-discovery endpoint with a 30-second timeout and 8 MB response limit. Hosted profiles require authentication; local profiles omit Authorization when their optional key is empty and are contacted only after an explicit Refresh action. Ollama uses one same-origin `/api/tags` request, LM Studio uses `/api/v1/models`, generic compatible servers use `/v1/models`, and Gemini uses native `v1beta/models`. Native type/capability metadata excludes known embedding models; absent metadata falls back to a case-insensitive `embed` name filter while manual Model ID remains unrestricted. No per-model `/api/show` fan-out occurs. Normalization retains at most 200 models and bounds display/reasoning metadata and cached records. Model lists are cached for one hour in a v3 cache keyed by provider, final endpoint hash, and one-way API-key fingerprint. Discovery failures remain inline settings errors and do not alter the active provider profile.

`provider_registry.gd` is the extension point for provider support. Each adapter defines its canonical endpoint, key help URL, model-list normalization, request headers, reasoning request shape, and provider-specific reasoning-history sanitation. Native non-Chat-Completions providers still require separate transport adapters.

`endpoint_policy.gd` is the shared trust boundary for editable provider URLs. It rejects userinfo, queries, fragments, ambiguous separators, malformed ports, dot segments, and already-complete chat/model endpoints; normalizes scheme, host, effective port, and path; and classifies loopback, LAN, or remote scope without DNS resolution. Loopback may use HTTP directly. LAN and remote origins require explicit confirmation persisted per provider as the normalized scheme/host/effective-port origin. Chat and discovery independently reauthorize before creating headers, validate that adapter-generated endpoints retain the authorized origin, and never follow provider redirects. Confirmation is informed consent rather than DNS or certificate pinning.

DeepSeek thinking is enabled at high effort by provider default and otherwise permits output far beyond Orca's response reserve. The DeepSeek adapter therefore sends an 8,192-token maximum for both thinking and non-thinking requests, aligned with the minimum final-answer reserve for its known 64K fallback context. This bounds cost and latency while leaving the user's selected reasoning effort intact.

### Tool Lifecycle

```text
Assistant emits tool call
-> controller validates JSON arguments
-> tool_started event creates activity card
-> tool executes or prepares approval
-> structured execution updates the card
-> text content alone is sent back to the model
```

Tool UI metadata is intentionally kept separate from model-facing content.

After each completed tool batch, `tool_loop_guard.gd` fingerprints normalized calls, arguments, outcomes, and results together with a controller progress epoch. It triggers after three identical call/results, an `ABABAB` call cycle, three identical complete rounds, or four rounds without observed progress. The controller then appends a bounded notice and sends exactly one request with no tool schema. Reaching the 12-round execution boundary uses the same finalization path instead of failing an otherwise successful turn. Any tool calls in that response receive matching denied tool results and end the turn without execution. The independent 16-call limit for one provider response remains authoritative.

### Reviewed Change Lifecycle

```text
Model reads the target and receives SHA-256
-> model calls a Work-only reviewed mutation tool
-> the typed backend validates and materializes an immutable proposal
-> script attach/detach first asks permission to execute exact hash-bound code during candidate construction
-> a kind-specific review card waits for Apply or Reject
-> Apply rechecks mode, live state, disk hash, retained hashes, and validation
-> verified replacement and required live-state synchronization run
-> Revert remains available while the applied file matches the proposal hash
```

Only one proposal is awaited at a time. Multiple model tool calls are processed sequentially.
Plan runtime checks reject every reviewed mutation independently of schema exposure, including revert of a previously applied proposal.

### Session Lifecycle

`session_store.gd` stores up to 50 versioned sessions under `user://orca/projects/<project-root-sha256>/sessions/`. Each session contains a bounded visible event log, a provider-independent user/assistant continuation history, mode, provider/model labels, aggregate usage, a sanitized task checklist, and non-actionable changed-file summaries. Writes use verified temporary files and recoverable backups. The index and each session are separate files so one corrupt transcript does not invalidate all history.

The active session is checkpointed after user submission, tool completion, edit resolution, normalized failure/cancellation, completed assistant response, session switching, and plugin teardown. The most recent active session is restored on startup. New Session saves the current conversation before rebuilding controller and feed state; the transition aborts if persistence fails. Starting a blank session clears the persisted active-session pointer until the first prompt is saved.

Restoration regenerates the current system prompt and uses only bounded user and visible assistant messages for model continuation. Historical tool and change records are display summaries and are never replayed. After a provider failure, complete active-turn tool protocol is validated and collapsed into a bounded local assistant checkpoint containing only tool names and normalized outcomes; prior calls are never replayed automatically. The model-continuation checkpoint excludes raw file contents, call IDs, arguments, tool results, request-scoped editor context, API credentials, hidden reasoning, approval payloads, and revert checkpoints. The separate activity log keeps only its existing bounded display metadata. Unsafe, cancelled, dirty, malformed, or truncated turns remain view-only.

Task state is stored separately from tool protocol. `update_tasks` replaces the complete list atomically, accepts at most 20 items of 240 characters each, permits at most one `in_progress` item, and never requires approval because it cannot mutate project files. Current tasks are added only to request-scoped model context, restored with the session, and cleared for a new session. Invalid live updates fail without changing prior state; stored data is defensively sanitized.

### Diagnostics Lifecycle

`diagnostics_service.gd` reference-counts one shared public Godot `Logger` across active service instances so plugin reloads or fallback ownership cannot duplicate records. It keeps at most 100 observed editor-process records; messages, paths, and function names have independent character bounds, and warning severity is preserved. Logger callbacks write directly to the mutex-protected static sink without loading resources from a potentially non-main logging thread. Proposed GDScript is validated using a fresh `GDScript`, a path cache hint, and `reload()`. Orca API failures use ordinary stdout logging rather than stderr so transport failures do not feed back into project diagnostics.

The public GDScript plugin API does not expose:

- Historical Output dock contents.
- Complete built-in game-process output and debugger error records.
- Script editor warning/error collections.

Orca must not scrape private editor controls to imitate these APIs. The diagnostics tool states this limitation and reports only supported data. For a process started by `GameProcessService`, it additionally reports bounded stdout/stderr, conservative runtime-error records, elapsed state, timeout, and exit code from public process APIs.

### Game Process Lifecycle

`game_process_service.gd` is owned by the plugin rather than a conversation. In Work mode, `run_current_scene` and `run_main_scene` validate a saved `.tscn`, reject known unsaved scripts/scenes and concurrent editor or Orca runs, and launch the current Godot executable with internally constructed `--path` and `--scene` arguments through nonblocking `OS.execute_with_pipe()`.

The service retains one private PID, monotonic run ID and snapshot sequence, and separate stdout/stderr pipes. It drains at most 32 KB per stream per editor frame, retains at most 64 KB per stream and 128 KB combined, renders at most 1,000 lines with 4,096 characters per line, retains at most 100 conservative runtime diagnostics, and enforces a 120-second wall-clock timeout. Output beyond those limits is drained but discarded and reported as truncated so a full pipe cannot stall the game. A bounded stream-local parser associates Godot error/warning headers with following `at:` or backtrace locations, including project paths containing spaces.

`stop_game` accepts no PID and calls `OS.kill()` only for the current direct child retained from Orca's own successful launch. Natural exit records the child exit code. Stop, timeout, launch failure, kill failure, and plugin shutdown have explicit states. New Session does not stop the game, process ownership is never persisted, and plugin teardown attempts to stop an active direct child.

Run/stop operations are external-state mutations, so their schemas are omitted in Plan and independently denied at runtime. They execute immediately in Work mode and do not use file-change cards because they do not alter project files. Selecting Work mode is the permission boundary for these process operations; project file changes continue to require proposal approval. `observe_game_run` and `verify_game_run` are read-only and remain available in both modes.

After a successful run call, the controller completes every tool call in the provider batch, appends exactly one matching result for each call, and then enters a cancellable observation checkpoint before the next provider request. It waits on editor frames for a terminal transition, meaningful evidence after a 1.5-second settle period, an evaluable criterion, or a five-second ceiling. The resulting snapshot is request-scoped system context and is removed when the turn ends. Cancelling this pause cancels the model turn but does not stop the independently owned game process.

Each user turn allows at most three successful run attempts, in addition to the existing 12 tool-round limit and the 16-tool-call-per-response transport/controller limit. The first run fixes the turn's verification criteria, including the absence of criteria; later runs cannot introduce or change them. Orca never automatically applies a fix or launches a rerun.

## Tool Contracts

### `list_directory`

Input:

- `path`: `res://` directory.

Output:

- Immediate child directories and files.
- Structured success or failure.

### `read_file`

Input:

- `filepath`: `res://` file.
- `start_line`: Optional one-based first line, default `1`.
- `end_line`: Optional one-based inclusive final line.

Limits:

- Maximum source file size: 2 MB.
- Maximum returned lines: 400.
- Maximum returned text: 128 KB.

Output includes actual range, total lines, truncation state, SHA-256, and navigation metadata.

### `search_files`

Input:

- `query`: Literal text.
- `path`: Search root, default `res://`.
- `file_glob`: Filename pattern, default `*`.
- `case_sensitive`: Default `false`.
- `max_results`: Clamped to 1-200.

Limits:

- Maximum matching files scanned: 500.
- Maximum individual file size: 1 MB.
- Maximum execution window: approximately 2.5 seconds.
- Binary files, `.godot`, Orca's directory, and symbolic links are skipped.

Output includes matches with path, one-based line, one-based column, preview, truncation state, and first-match navigation metadata.

### `inspect_scene`

Input:

- `scene_path`: Saved `res://` path ending in `.tscn`.
- `include_properties`: Optional boolean, default `true`.
- `max_nodes`: Optional requested node bound, clamped to 1-120.
- `max_properties_per_node`: Optional requested serialized-property bound, clamped to 0-24.

The tool loads a `PackedScene` with cache bypass, reads its public `SceneState`, and never calls `instantiate()`. It returns saved node paths, parent and owner paths, types, sibling indexes, up to 32 groups per node, child-scene references, instance placeholders, serialized exported or overridden properties, and up to 100 saved signal connections. It does not report all Inspector defaults, runtime-generated nodes, or recursively expanded child/inherited scenes.

Hard limits include a 2 MB source scene, 120 nodes, 24 properties per node, 500 properties overall, 100 connections, 16 connection binds, 16 collection entries per summarized Variant, four levels of Variant recursion, 256 characters per string value, and 128 KB of valid JSON output. Truncation removes complete records rather than cutting JSON and is reported with explicit reasons.

Successful results include scene navigation metadata. Paths outside `res://`, symbolic links, Orca's own directory, missing files, non-`.tscn` targets, oversized scenes, malformed resources, and scenes with unsaved editor changes fail without navigation metadata.

### `inspect_project_settings`

Input:

- `setting_path`: Optional exact ProjectSettings path. Omit it for the bounded overview; an explicit empty value is rejected.

The overview reports selected application values, main scene, display/window settings, input actions, autoloads, rendering settings, and physics settings. Explicit reads are limited to those low-risk families rather than allowing arbitrary custom settings. Sensitive-looking paths are rejected. Values use active Godot feature overrides and retain their Variant type in JSON-safe form.

Hard limits include 64 input actions, 12 events per action, 64 autoloads, 4,096 scanned property records, 16 entries per summarized collection, three levels of Variant recursion, 256 characters per string, and 64 KB of valid JSON output. Truncation preserves whole JSON and reports reasons.

The tool is read-only in Plan and Work, never enters approval, and can navigate to `project.godot`. Sessions persist only the optional setting path and navigation summary, never returned setting values. It does not enumerate arbitrary settings, inspect editor settings, or reveal disallowed custom configuration paths.

### Automatic Project Instructions

At the start of each turn, Orca checks only the project-root `res://AGENTS.md`. Missing instructions are optional and do not fail the request. Valid content is wrapped with its SHA-256 and explicit precedence language, appended to private request-scoped system context, retained through that turn's tool rounds, and removed before resumable history is stored.

Hard limits and rejection rules:

- Exact fixed path only; no ancestor or nested instruction discovery.
- Maximum 32 KiB and 400 lines.
- Valid UTF-8 text with no NUL bytes.
- Any symbolic-link component is rejected.
- Project guidance cannot authorize tool access, execution, mutation, disclosure, or weaker safety behavior.

### `read_project_skill`

Project skill discovery scans only immediate directories matching the lowercase slug grammar under `res://skills/`. Each valid entry must use `res://skills/<slug>/SKILL.md` with bounded YAML-like frontmatter containing one `name` and `description`. Automatic request context receives catalog metadata only: name, description, slug, and path. It does not receive skill bodies.

Input:

- `name`: Exact case-sensitive discovered name, 1-64 characters. Duplicate exact names fail rather than selecting one.

Hard limits:

- At most 64 immediate directories scanned and 32 skills returned, in deterministic slug order.
- Frontmatter must close within 8 KiB and 80 lines.
- Description maximum: 240 characters.
- Body maximum: 32 KiB and 400 lines; complete skill file maximum is 40 KiB.
- Invalid UTF-8, NUL bytes, invalid slugs/frontmatter, symbolic links, missing exact names, and ambiguous names are rejected.

The returned body is wrapped as subordinate, non-recursive, non-executable project guidance. References in a skill are plain text and do not cause automatic file reads or command execution. The tool is read-only in Plan and Work; only bounded target/navigation metadata persists, not the body.

### `inspect_godot_api`

Input:

- `class_name`: Required native `ClassDB` class or registered global class name, maximum 256 characters.
- `member_name`: Optional exact member name; omit for a class overview.
- `member_kind`: Optional `auto`, `method`, `property`, `signal`, `constant`, or `enum`; default `auto`.
- `include_inherited`: Optional boolean, default `true`.

The tool reports engine version, native hierarchy, reflected declaring class, method/signal signatures and arguments, property types/getters/setters, integer constants, enums, and registered global-class metadata. A global script class exposes its registration and native base metadata but does not claim unloaded script-declared members. Successful results include a validated `class_*` Help topic used by the activity card's Open Docs action and `EditorInterface.get_script_editor().goto_help()`.

Hard limits include 80 overview members, 16 exact matches, 16 hierarchy levels, 32 arguments per method/signal, 256 characters per string, and 64 KiB of whole JSON output. The tool uses reflection only: it does not construct objects, instantiate scenes, load project scripts, scrape `EditorHelp`, or return class-reference prose. It is read-only in Plan and Work.

### `read_gdscript_function`

Input:

- `filepath`: Canonical existing `res://` path ending in `.gd`.
- `function_name`: Valid GDScript identifier, maximum 128 characters.
- `start_line_hint`: Optional positive one-based line to resolve duplicate names.
- `include_documentation`: Optional boolean, default `true`, for adjacent `##` documentation and annotations.

The reader masks comments and string contents while locating declarations, multiline signatures, indentation boundaries, static functions, and nested class scope, then returns exact selected source with one-based navigation. Duplicate names fail with bounded candidate summaries unless the line hint selects one uniquely. This is focused lexical extraction, not semantic symbol resolution.

Saved source includes a disk SHA-256. If the exact script is open and unsaved, Orca instead reads its public `ScriptEditor` source, labels the result `source_kind: editor`, and deliberately omits `disk_sha256`; that content cannot authorize or seed a patch. Hard limits are 2 MiB source, 300 returned lines, 96 KiB returned text, and 20 candidate summaries. Canonical path, `.gd`, project boundary, symbolic-link, Orca-directory, UTF-8, and NUL checks apply. The tool is read-only in Plan and Work.

### `discover_dependencies`

Input:

- `filepath`: Canonical existing saved project resource.
- `direction`: Required `forward` or `reverse`.
- `max_depth`: Optional, clamped to 1-3; default `1`.
- `max_results`: Optional, clamped to 1-100; default `100`.

Forward traversal follows serialized `ResourceLoader.get_dependencies()` relationships breadth-first. Reverse traversal builds a bounded project index, then reports direct and transitive dependents in deterministic breadth-first order while preserving real source-to-dependency edge direction. UID descriptors are resolved when registered, with canonical `res://` fallbacks where available.

Hard limits include 3 traversal levels, 100 returned nodes, 200 graph edges, 500 scanned files, 256 scanned directories, 100 indexed graph nodes, 200 indexed serialized edges, approximately 2.5 seconds for reverse scanning, and 96 KiB of whole JSON output. `.godot`, symbolic links, Orca's addon, unsafe/unresolved dependencies, and missing/noncanonical targets are excluded or rejected with truncation reasons. The tool does not load or instantiate resources and cannot discover dynamic `load()` calls, arbitrary code references, runtime-created resources, or unsaved editor state. It is read-only in Plan and Work.

### `get_editor_context`

Output may include:

- Active scene name, path, and root type.
- Up to 20 selected nodes with type, scene-relative path, script, and groups.
- Active script path.
- One-based caret line and column.
- Source excerpt around the caret.
- Selected source text, capped at 12,000 characters.
- Selected FileSystem paths.
- Open and unsaved scenes.
- Unsaved scripts.

### `get_diagnostics`

Output includes:

- Bounded validation and editor-process error records.
- Error file and line when publicly available.
- Current play state and playing scene.
- Explicit note about unavailable private Output/debugger history.

### `update_tasks`

Input:

- `tasks`: Complete replacement list, limited to 20 items.
- Each item contains `content`, limited to 240 characters, and one of `pending`, `in_progress`, `completed`, `blocked`, or `cancelled`.
- At most one item may be `in_progress`.

The tool is available in Plan and Work, changes session metadata only, never enters the patch approval path, and returns the normalized list to the controller. An empty list clears the checklist.

### `apply_patch`

Input:

- `filepath`: Target `res://` file.
- `base_hash`: SHA-256 from `read_file`; empty only for a new file.
- `edits`: Non-overlapping one-based line edits.

Each edit contains:

- `start_line`.
- `end_line`.
- `replacement` exact text.

`end_line = start_line - 1` inserts before `start_line`. Appending after the final line uses `start_line = line_count + 1` and `end_line = line_count`.

Patch materialization preserves LF or CRLF boundaries and rejects malformed, overlapping, duplicate-position, or out-of-range edits.

### `propose_input_map_changes`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `changes`: 1-16 complete action operations.
- Each operation is `upsert` with a deadzone and up to 16 typed events, or `remove` with an action name.

Action names are limited to 64 ASCII letters, numbers, underscores, periods, or hyphens. Supported initial events are key, mouse button, joypad button, and joypad motion with strict fields, device ranges, Godot enum bounds, modifier types, direction values, and Unicode scalar validation. Duplicate actions and unknown fields are rejected.

Preparation parses `project.godot`, checks affected live ProjectSettings values against disk, and materializes only requested `input/<action>` entries. Unrelated bytes, comments, sections, and Input Map entries remain exact. The candidate is reparsed, requested values are verified, and old/new action summaries plus exact private bytes and hashes are retained. No-op proposals skip approval.

The structured card shows each add, update, or remove operation, old/new deadzone, event type, all key representations, modifiers, device, button, and axis details. Apply rechecks the disk hash, retained old/new hashes, affected live state, and candidate before verified replacement. It then synchronizes ProjectSettings and InputMap and verifies complete affected action values. Revert is hash-guarded and synchronizes the old values. Rollback failures preserve a status consistent with the bytes left on disk so recovery remains visible.

Only bounded kind/action summaries persist. Raw event payloads, proposal bytes, typed resources, pending approval, and revert state do not survive restart.

### `propose_main_scene_change`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `scene_path`: Existing saved `res://` path ending in `.tscn`.

The target must remain inside the project, contain no symbolic-link traversal, remain outside Orca's own addon, have no unsaved editor changes, stay within 2 MB, and load as a `PackedScene` without instantiation. The path and fixed `project.godot` target are revalidated immediately before apply or revert.

Existing `res://` and valid `uid://` main-scene values are resolved to canonical resource identity for live/disk comparison and no-op detection. New values prefer a registered UID that resolves back to the requested scene and otherwise use the canonical resource path. Broken previous values are shown explicitly as unresolved and remain restorable.

Only the `[application] run/main_scene` assignment is materialized. Valid UTF-8, LF/CRLF consistency, candidate parsing, retained hashes, scene validity, and live/disk state are checked before verified replacement. A dedicated card shows the previous and proposed canonical scene and provides project-file and scene navigation. Apply and revert synchronize ProjectSettings, classify independent conflicts, and expose `applied_recovery` or `reverted_recovery` when disk and live state require user attention.

Sessions persist only a bounded main-scene summary and status. Raw UID values, proposal hashes, exact project bytes, pending approval, and revert checkpoints remain private and in memory.

### `propose_project_settings_changes`

Input:

- `base_hash`: SHA-256 returned by `read_file` for `res://project.godot`.
- `changes`: Atomic batch of 1-6 objects containing exact `setting_path` and `value` fields.

The initial mutation allowlist is deliberately smaller than the read inspector:

- `display/window/size/viewport_width`: integer 1-7680.
- `display/window/size/viewport_height`: integer 1-4320.
- `display/window/size/window_width_override`: integer 0-7680.
- `display/window/size/window_height_override`: integer 0-4320.
- `display/window/stretch/mode`: `disabled`, `canvas_items`, or `viewport`.
- `display/window/stretch/aspect`: `ignore`, `keep`, `keep_width`, `keep_height`, or `expand`.

The numeric maxima are intentional Orca safety caps rather than Godot engine limits. Rendering backends, fullscreen mode, physics timing, project identity, plugins, autoloads, executable paths, feature overrides, export settings, and arbitrary custom paths remain excluded.

Absent disk entries resolve to documented Godot built-in defaults for no-op and live/disk comparison. Values require exact Variant types without coercion. Unknown fields, duplicate paths, invalid enums, and out-of-range values fail atomically.

Only requested `[display]` assignments are materialized, preserving unrelated valid UTF-8 bytes and comments. Apply and revert rederive the complete allowlisted old/new delta from hash-bound files, validate retained metadata, recheck the fixed target, synchronize concrete live ProjectSettings values, and classify conflicts or recovery states. The dedicated card shows typed previous and proposed values; sessions persist only bounded labels and status.

### `propose_scene_changes`

Input:

- `scene_path`: Canonical `res://` path ending in `.tscn`. A new scene's parent directory must already exist.
- `base_hash`: Empty for `create_scene`; exact `read_file` SHA-256 for every existing-scene operation.
- `operations`: Exactly one supported structured operation.

Supported operations:

- `create_scene`: Creates a new scene with an allowlisted `Node`, `Node2D`, `Node3D`, or `Control` root.
- `add_node`: Adds one allowlisted native node under a canonical local parent and assigns scene-root ownership.
- `set_property`: Sets one stored, writable property using an explicit typed wire value. Initial values are bool, int, finite float, bounded String/StringName, Vector2/Vector2i, Vector3/Vector3i, Color, and Rect2.
- `rename_node`: Renames a local leaf node, or the root, after duplicate-name checks.
- `remove_node`: Removes exactly one local non-root leaf.
- `reparent_node`: Moves exactly one local leaf to a different canonical local parent while preserving root ownership.
- `attach_script`: Attaches one exact hash-bound, dependency-free `.gd` script with a compatible native Node base after preliminary execution trust.
- `detach_script`: Detaches the exact hash-bound script from one node after preliminary execution trust.
- `instantiate_child_scene`: Adds one independently hash-bound dependency-free `.tscn` as a real child-scene instance.
- `connect_signal`: Adds one persistent bindless built-in signal-to-method connection with optional deferred and one-shot flags.
- `disconnect_signal`: Removes exactly one matching supported persistent bindless connection.

Names are bounded to 128 characters and reject control characters, reserved path names, surrounding whitespace, and characters Godot would silently replace. Structural operations reject scenes with saved connections or NodePath properties rather than guessing how references should be remapped. Signal operations are limited to local built-in endpoints with compatible signatures. Property collections, resources, NodePaths, callables, and arbitrary object values are excluded.

Preparation constructs native nodes through `ClassDB`, packs with `PackedScene.pack()`, serializes to bounded short-lived `user://orca/tmp/*.tscn` scratch storage, reloads with deep cache bypass, and verifies the complete result through `SceneState`. Existing-scene operations are restricted to at most 60 local nodes, 240 serialized properties, and 100 connections. Before loading, the parent scene rejects all external dependencies and built-in subresources; after loading, it also rejects inheritance, unreviewed child instances or scripts, non-core node types, serialized object values, open editor scenes, and any candidate that changes unrelated semantic records. `instantiate_child_scene` permits exactly its reviewed child dependency after separately validating and hash-binding a dependency-free child scene. Script operations initially permit exactly one reviewed attachment, no other scripts or scene dependencies, and a dependency-free `.gd` with a compatible native Node base. Scratch names include process, time, and random components, normal cleanup is synchronous, and stale known scratch files are scavenged during plugin startup and later scene operations.

Script attach/detach uses two decisions inside one protocol tool call. The first card validates only canonical paths, saved bytes, unsaved/open state, and exact scene/script hashes without loading the scene or compiling the script. Its explicit Trust and Prepare action authorizes compilation, loading, initialization, candidate construction, and later revalidation after immediate hash checks; it does not write the scene. Orca then validates GDScript and dependencies, checks native-base compatibility, constructs an immutable candidate, and reuses the card for normal Apply/Reject. Rejection or cancellation at either stage completes the original tool call exactly once and releases retained private state.

Apply repeats path, dependency, existence, open/unsaved state, operation, hash, pack/save/load, and complete candidate validation before verified replacement. Failed final validation restores the original bytes only while the target still matches the reviewed candidate. Revert rejects open, unsaved, or independently changed parent scenes; it removes a newly created file or restores exact retained bytes for an existing scene. Child dependency drift blocks Apply but does not block restoring exact pre-instance parent bytes. The dedicated structured card receives only bounded operation-specific summaries; candidate/script bytes, trust bindings, dependency hashes, authoritative operations, pending approval, and revert checkpoints are not persisted.

Godot has no public way to construct and pack script candidates without potentially executing `_init`, member/static initialization, or `@tool` behavior. The preliminary trust review makes that execution explicit and binds it to exact scene/script hashes, but it is informed consent rather than sandboxing. Candidate construction remains synchronous on the editor thread and cannot be interrupted until Godot returns control.

### `run_current_scene`, `run_main_scene`, And `stop_game`

All three tools accept an empty object and are exposed only in Work mode. `run_current_scene` resolves the active editor scene and requires it to be saved. `run_main_scene` resolves the active feature-overridden `application/run/main_scene`. Both require a canonical existing `.tscn` outside Orca's addon, reject symbolic links, reject all known unsaved scripts and scenes, reject concurrent editor play or an existing Orca run, and launch the current Godot executable without a shell.

Launch returns immediately after process creation. The model uses `get_diagnostics` in later tool rounds to observe status and bounded output. `stop_game` stops only the in-memory direct PID retained by the current plugin instance; it never accepts a PID and cannot stop an editor-started game. A successful launch means only that the process started, not that the game passed validation or ran correctly.

Run calls may include one optional bounded `verification` object. Initial kinds are `clean_startup`, with a 250-10,000 ms minimum runtime, and `expected_exit`, with an exact exit code. Both may declare up to five required stdout markers, five forbidden stdout/stderr markers, and whether diagnostic-shaped runtime errors are forbidden. Claims are limited to 240 characters and markers to 200 characters. Matching is literal and criteria never become process arguments.

### `observe_game_run` And `verify_game_run`

`observe_game_run` accepts an exact positive `run_id` and optional prior snapshot sequence. It never waits or changes process state. It returns current bounded evidence and whether the snapshot advanced. Stale or unknown run IDs fail rather than reading a newer run accidentally.

`verify_game_run` accepts one exact run ID and evaluates only criteria fixed before launch. Results are `passed`, `failed`, `pending`, `inconclusive`, or `unverified`, with per-check evidence. Truncated evidence makes absence-based checks inconclusive. A nonzero exit cannot pass clean-startup verification, and stopped/timed-out processes cannot pass expected-exit verification. A pass is explicitly scoped to startup or process-exit criteria and is never general visual/gameplay proof.

## Security And Privacy

- API credentials are stored in Godot `EditorSettings`. This is persistence, not an encrypted OS credential store.
- Session transcripts are stored as plaintext JSON under project-keyed `user://` storage. They can contain user prompts, assistant text, and task descriptions, including source text quoted in those fields.
- Session records exclude API keys, automatic editor-context snapshots, hidden reasoning, patch contents, complete tool output, and durable revert data.
- The configured API endpoint receives the API key using the selected adapter's authentication headers. Current chat adapters use bearer tokens.
- Authenticated provider model-discovery endpoints receive that provider's API key; Gemini discovery uses Google's `x-goog-api-key` header.
- Orca requests public model metadata from `models.dev` without sending the API key, prompts, file contents, or project context.
- Project context and file contents may be sent to the configured model provider.
- When present, root `res://AGENTS.md` content and bounded project-skill catalog metadata are automatically sent to the configured provider with each turn. A skill body is sent only after an explicit `read_project_skill` call. These values remain private request context/tool results and are not persisted in resumable session continuation or raw activity output.
- Project instructions and skills are untrusted input. Wrapping and prompt precedence are defense in depth; runtime mode, approval, path, execution, and disclosure checks remain the security boundary.
- Unsaved editor source returned by `read_gdscript_function` has no disk hash and cannot be used as an `apply_patch` base. It may still be sent to the selected provider as tool output.
- `inspect_godot_api` uses reflection and safe Help topics rather than prose scraping or object construction. `discover_dependencies` reads serialized dependency metadata without loading resources, but its reverse scan still enumerates bounded project resource paths on the editor thread.
- Editable LAN and remote endpoints require explicit exact-origin confirmation before credentials or project context can be sent. Orca does not maintain a general host allowlist, pin DNS answers or certificates, or control whether a confirmed server proxies data elsewhere.
- GDScript `reload()` is a compiler/loader validation mechanism, not a sandbox. Trusted generated source may reach tool-script static initialization.
- `PackedScene` loading for inspection is read-only and does not instantiate nodes, but referenced resources and scripts may still be loaded by Godot; dependency loading is not a sandbox or independently size-bounded.
- Existing-scene structured mutation requires `PackedScene.instantiate()` after rejecting unreviewed dependencies, subresources, scripts, inheritance, non-core nodes, object properties, and unsupported size. This is deliberately narrower than read-only inspection and is not a general scene sandbox. Script attach/detach requires explicit preliminary trust because candidate construction can execute exact reviewed project code; that execution is not sandboxed.
- Godot exposes no locked resource-load API. Child-scene preparation rechecks exact bytes and dependencies immediately before canonical load and compares the loaded state with the validated scratch state, but a hostile external process could still replace the dependency within that final read/load interval.
- The same no-lock limitation applies to trusted script loading. Orca rechecks the script hash before and after canonical loads and refuses to write on drift, but a hostile external process could replace script bytes in the interval and cause unreviewed code to execute before the post-load mismatch is detected. Preliminary trust is informed consent, not a sandbox against hostile local races.
- Temporary replacement and in-memory revert state reduce accidental data loss but are not durable version control.
- `OS.kill()` addresses only Orca's direct Godot child, not subprocesses that project code may spawn. Godot exposes no cross-platform process-tree/job ownership API in GDScript.
- On Unix-like platforms Godot's forceful `OS.kill()` implementation may wait for the direct child to exit. Launch and capture are nonblocking, but a pathological child stuck in uninterruptible kernel I/O could delay Stop, timeout handling, or plugin teardown.

Do not describe the current credential storage or execution model as fully secure.

## UI Conventions

- Preserve Godot's editor visual language and scaling.
- Use `ui_metrics.gd` for plugin-authored pixel dimensions. Values obtained from the editor theme, including fonts and `EditorIcons`, are already scaled and must not be multiplied again.
- Recompute scaled dimensions from immutable base values; never multiply a control's current dimensions during repeated notifications.
- Keep incomplete streamed text lightweight and literal; create rich code controls only after a response or tool preface is complete.
- Prompt text derives from the editor theme rather than a fixed physical size.
- The composer uses the editor accent color for focus, derives its height from visible line metrics, and keeps its action rail usable at the 300 px-equivalent minimum dock width.
- Use orange for Plan assistant headings and green for Work headings.
- Mode choices pair those accents with explicit capability descriptions; color is not the only indicator.
- Keep custom dock menus inside the dock's `Control` tree so positioning and sizing use the same editor-scaled coordinate system.
- Use compact collapsed activity cards by default.
- Derive read-only activity groups from consecutive flat tool events so persisted sessions remain compatible and independently bounded.
- Close groups at every visible message, change, mutation, unknown-tool, request-completion, and session boundary.
- Keep one transient mode-colored working indicator visible while a provider request has not produced text or tool activity. Transport headers alone are not visible progress and must not replace it with an empty assistant card.
- Keep active-turn scrolling attached to the latest activity across delayed container and rich-text layout. A single deferred scrollbar assignment is insufficient for controls whose final height is calculated later.
- Use unified diffs in the narrow dock and side-by-side views when expanded.
- Keep dangerous actions explicit and label their final state.
- Mode, request, tool, and approval state must agree visually with controller state.

## Testing

### Current Automated State

A committed automated suite exists under `tests/`:

- `api_client_test.gd` verifies media-type recognition, fragmented SSE reconstruction, clean-EOF event flushing, bounded opaque tool-call metadata, structured failure metadata, raw-buffer behavior, and tool-call ID validation.
- `provider_test.gd` verifies hosted/local registration, native Ollama/LM Studio discovery URLs and filtering, generic embedding-name fallback, loaded context selection, required/optional authentication, bounded model normalization, reasoning options, pricing conversion, endpoint-aware cache identities, and public metadata mapping.
- `context_budget_test.gd` verifies unknown-limit behavior, conservative reserves, complete-turn removal, historical and active tool-group integrity, repeated compaction, malformed protocol refusal, and oversized protected-turn failure.
- `api_client_integration_test.gd` uses `http_test_server.py` on `127.0.0.1` to verify successful SSE, keyless local chat without an Authorization header, Gemini thought-signature reconstruction, xAI reasoning requests, mid-stream disconnect metadata, aggregate response limits, buffer cleanup, and unexpected content types.
- `provider_model_service_integration_test.gd` verifies keyless native Ollama/LM Studio discovery, embedding exclusion, loaded context, absent Authorization headers, redirect rejection, stale-request ownership, and cached-record sanitation against localhost fixtures.
- `agent_compatibility_probe_integration_test.gd` verifies the complete isolated two-request function-call and matching tool-result continuation through the real local HTTP/SSE transport.
- `patch_utils_test.gd` verifies replacement, insertion, deletion, append, empty-file creation, multiple edits, overlap rejection, and LF/CRLF preservation.
- `tools_test.gd` verifies Plan/Work tool-schema separation, direct-mutation denial, project and plugin path boundaries, symbolic-link rejection, immutable proposals, base hashes, stale application and revert guards, safe application, and new/existing-file revert behavior.
- `agent_controller_test.gd` verifies Plan/Work schema and runtime enforcement, request-scoped project guidance, exact compatibility-bound local Agent gating, mode locking, explicit approval and rejection, cancellation while awaiting approval, skipped remaining calls, tool-loop finalization, recoverable provider failures, applied-change non-replay, unsafe-protocol refusal, and matching protocol-valid tool results.
- `agent_compatibility_probe_test.gd` verifies the isolated synthetic two-step tool-call protocol, exact challenge/call-ID continuation, opaque metadata preservation, strict acknowledgement, disabled request fallback, failure, timeout, and cancellation.
- `session_store_test.gd` verifies project isolation, recovery-checkpoint persistence, schema redaction, backup recovery, retention, truncation, deletion cleanup, and controller state restoration.
- `history_view_test.gd` verifies that the History page remains within the 300 px minimum dock width.
- `settings_view_test.gd` verifies Provider/About tab switching, local-profile presentation, explicit keyless discovery, endpoint-change cleanup, compatibility controls/default denial, version metadata, branding, compatibility, license presentation, and the 300 px dock-width constraint.
- `chat_window_test.gd` verifies editor-scale conversion math, compact line-based composer sizing, narrow action containment, working-state animation, first-token transitions, delayed-layout auto-follow, sequential review navigation, fenced-code parsing, BBCode isolation, exact code preservation, expanded previous/proposed diff content and safe line highlighting, bounded code-block layout, streaming-to-final transitions, tool-preface handling, recoverable/unsafe interruption composer state, restoration rules, structured review cards, and the 300 px dock-width constraint.
- `editor_ui_scale_test.gd` runs in editor mode and verifies that dock margins, branding, composer controls, and prompt sizing use Godot's effective editor scale without double-scaling theme fonts.
- `logo_asset_test.gd` verifies that the Orca mark has no opaque white tile and retains transparent corners after import.
- `tool_activity_group_test.gd` verifies aggregate status and duration, expansion, append closure, forwarded navigation, and the 300 px width constraint.
- `task_list_panel_test.gd` verifies status presentation, bounded height, collapse/expand behavior, clearing, and the 300 px width constraint.
- `scene_inspector_test.gd` verifies saved hierarchy, serialized properties, groups, instances, signal connections, JSON-safe Variant summaries, structural-only reads, bounds, invalid targets, and navigation metadata.
- `project_settings_inspector_test.gd` verifies bounded overviews, explicit typed values, feature overrides, input actions, output limits, allowlists, privacy rejections, and navigation metadata.
- `project_instructions_test.gd` verifies optional root loading, exact content/hash metadata, safety wrapping, byte/line/NUL bounds, and symlink rejection.
- `project_skills_test.gd` verifies deterministic immediate-directory metadata discovery, exact-name body loading, frontmatter/slug/body bounds, non-recursive safety wrapping, truncation, and symlink rejection.
- `godot_api_inspector_test.gd` verifies reflected class/member kinds, inheritance, signatures, global-class metadata, limits, Help-topic formats, failures, and absence of construction or private Help scraping.
- `gdscript_function_reader_test.gd` verifies saved and unsaved source provenance, documentation and annotation inclusion, multiline signatures, nested classes, ambiguity hints, CRLF preservation, output bounds, path protection, and absent hashes for editor source.
- `dependency_inspector_test.gd` verifies deterministic forward/reverse breadth-first serialized graphs, depths, UID fallback normalization, scan/result/output bounds, and invalid/protected targets.
- `tool_loop_guard_test.gd` verifies identical successful and failed calls, alternating cycles, repeated rounds, changing results, progress resets, no-progress thresholds, and stable canonical fingerprints.
- `input_map_proposal_test.gd` verifies typed event validation, exact unrelated-byte preservation, no-op and stale guards, immutable reviewed hashes, affected live/disk consistency, application, synchronization, and guarded revert.
- `main_scene_proposal_test.gd` verifies path and PackedScene validation, path/UID semantics, exact unrelated-content preservation, no-op and stale guards, private hash binding, live synchronization, application, and guarded revert.
- `project_settings_proposal_test.gd` verifies the exact allowlist, strict types/ranges/enums, built-in defaults, atomic batches, exact preservation, complete-delta integrity, stale/live conflicts, synchronization, application, and guarded revert.
- `scene_proposal_test.gd` verifies typed-root creation; add, property, rename, remove, reparent, script, child-instance, and signal operations; non-executing script trust preparation; strict paths/types/dependencies; semantic preservation; scratch cleanup; stale targets; exact-byte restoration; conflicts; and guarded revert.
- `game_process_service_test.gd` verifies fixed launch arguments, one-process ownership, direct-PID stop, natural exit codes, timeout and kill-failure states, shutdown failure honesty, separate stdout/stderr bounds, safe diagnostic navigation, launch failure, and real nonblocking Godot pipe integration.
- The same suite verifies monotonic run identity/sequence, strict criteria normalization, clean-startup and expected-exit verdicts, nonzero-exit failure, truncation-driven inconclusive results, stale run rejection, and genuine multiline Godot diagnostic locations.
- `diagnostics_service_test.gd` verifies validation contracts, warning/error normalization, stderr filtering, bounded oldest-to-newest retention of the latest records, field sanitation, monotonic sequences, and deep-copy report isolation.
- `editor_unsaved_state_test.gd` uses public editor APIs to dirty real script and scene buffers and verifies exact current-editor source provenance, absent disk hashes, patch/apply/revert rejection, stale scene-inspection and structured-proposal rejection, and run blocking.
- `diagnostics_editor_integration_test.gd` verifies real editor logger capture and proves that simultaneous diagnostics service instances share one logger without duplicate records.
- `plugin_lifecycle_test.gd` verifies actual enable, disable, and re-enable behavior, single toolbar/dock/service ownership, dependency injection identity, and dock registration.
- `provider_settings_editor_test.gd` verifies isolated editable endpoints, models, optional credentials, reasoning settings, compatibility-pass persistence, separate opt-in, and binding invalidation through real EditorSettings.

Run instructions are in `tests/README.md`. `.github/workflows/tests.yml` runs the permanent suites, editor-scale and editor-state integration, localhost transport integration, replacement-artifact checks, and headless plugin initialization on Godot 4.7.2. Authenticated provider-setting interactions still require deeper permanent coverage. Visual dock placement, focus, and theme checks remain manual.

### Required Headless Check

```bash
"$GODOT_BIN" --headless --editor --path . --quit
```

Expected result: project scan, plugin initialization, and editor layout complete without script or initialization errors.

### Manual Smoke Matrix

| Area | Scenarios |
| --- | --- |
| Streaming | Normal response, delayed first token, header-only working state, late card growth, active-turn bottom following, UTF-8 text, tool follow-up preparation, Stop, follow-up after Stop, HTTP failure. |
| Usage | Usage-only SSE event, cached tokens, multi-round totals, provider cost, catalog fallback, unavailable usage. |
| Metadata | Fresh/stale cache, offline fallback, unknown provider/model, response-size limit. |
| Providers | Legacy migration, per-provider credentials, switching, custom endpoint preservation, Gemini/xAI model discovery, discovery errors. |
| UI scaling | 100%, 125%, 150%, and 200% editor scale after restart; 300 px-equivalent narrow dock; 1280x720 short display; dark and light themes. |
| Reasoning | Capability-driven effort, provider body mapping, DeepSeek/xAI content continuity, OpenRouter detail reconstruction, Gemini thought signatures, and bounds. |
| Modes | Plan read-only, Work patch access, Plan-to-Work switch, mode locked while busy; intelligence tools available read-only in both modes. |
| Project guidance | Missing/valid/oversized/symlinked root instructions; bounded skill catalog; exact skill selection; request cleanup; no automatic body loading. |
| Godot intelligence | Class/member reflection and Open Docs; saved/unsaved focused functions; forward/reverse saved dependencies; truncation and protected paths. |
| Tool-loop guard | Identical calls/results, alternating cycles, repeated rounds, no-progress rounds, one no-tools final request, denial of further calls, hard-cap fallback. |
| Reads | Valid range, default range, invalid range, empty file, oversized file, binary file. |
| Search | Match, no match, glob, case sensitivity, result limit, timeout, skipped plugin path. |
| Scene inspection | Saved hierarchy, properties on/off, node/property truncation, child instances, signal connections, malformed/missing/oversized targets, unsaved scene rejection. |
| Project settings | Overview, explicit allowlisted path, feature override, input actions, autoloads, sensitive/custom path rejection, output truncation. |
| Input Map proposals | Add/update/remove, typed events, no-op, stale hash, affected live/disk mismatch, approval, rejection, cancellation, apply, synchronization, revert, Plan denial. |
| Main scene proposals | Valid/invalid scene, UID/path equivalence, no-op, stale hash, live/disk mismatch, approval, apply, synchronization, revert, conflict, Plan denial. |
| ProjectSettings proposals | Every allowlisted type/range, defaults, duplicates, atomic width/height, no-op, stale hash, live mismatch, metadata tampering, approval, apply, synchronization, revert, Plan denial. |
| Scene proposals | Every exposed operation, typed values, root/nested paths, ownership, stale parent/dependency hashes, restricted dependency/script rejection, approval, apply, exact-byte revert, conflict, Plan denial. |
| Context | No scene, active scene, selected nodes, active script, selection, unsaved script/scene. |
| Patches | Replacement, insertion, deletion, append, new file, LF, CRLF, overlapping edits. |
| Approval | Apply, Reject, Stop while waiting, multiple sequential tool calls. |
| History | Restart restore, switch, continue, delete, Delete All, retention, interrupted view-only, narrow layout. |
| Conflicts | Changed hash, changed existence, unsaved editor file, symlink path. |
| Validation | Valid GDScript, parse error, revalidation failure before write. |
| Revert | Existing file, newly created file, independently modified file, retry after failure. |
| Navigation | Script line/column, scene, resource, first search result, missing path. |

### Test Hygiene

- Put temporary runners outside the repository, such as `/tmp/opencode/`.
- Remove every temporary runner after verification.
- Remove test project files even when assertions fail.
- Check for `.orca_tmp_*`, `.orca_backup_*`, and test files before completion.
- Do not send live provider requests during tests unless explicitly authorized because they may expose code or incur cost.

## Known Limitations

### Agent And Context

- Resumable persisted history contains user and visible assistant messages rather than historical tool-call protocol details. Complete failed tool turns may be replaced by sanitized recovery checkpoints; unsafe or crash-interrupted turns remain view-only.
- Context budgeting uses a conservative byte-based estimate rather than a provider tokenizer. Unknown custom-model limits cannot be enforced automatically, and compaction omits old complete turns rather than generating a potentially lossy model summary.
- Pending approval state is not persisted; task checklists are persisted independently.
- Saved `.tscn` inspection reports serialized scene state, not all Inspector defaults, unsaved live-tree changes, runtime-generated nodes, or recursively expanded inherited/instanced scenes.
- Search is literal text search rather than a symbol or semantic index.
- Root project instructions are limited to one fixed `res://AGENTS.md`; nested or ancestor instruction inheritance is not implemented.
- Skills use a deliberately small frontmatter format, immediate directories only, exact-name loading, and no recursive reference resolution. Skill bodies are not automatically selected or summarized.
- `inspect_godot_api` exposes reflected signatures and safe editor Help navigation, not class-reference prose, examples, tutorials, annotations/default argument values unavailable from `ClassDB`, or script-declared members from unloaded global classes.
- `read_gdscript_function` is an indentation-aware lexical extractor, not a parser, semantic index, call hierarchy, or reference search. Only the exact open unsaved script can use editor source.
- Dependency discovery reports only saved serialized references known to `ResourceLoader`; dynamic `load()` calls, arbitrary code references, runtime objects, unsaved state, and complete project-wide graphs beyond hard bounds are unavailable.
- Progressive tool-schema disclosure is deferred. Orca still sends the full mode-eligible schema on each request, so Godot Intelligence adds schema cost despite bounded outputs.
- Structured ProjectSettings reads intentionally cover selected low-risk families rather than arbitrary custom settings or EditorSettings.

### Editing

- Patches are line-range operations, not a full unified-diff parser.
- Raw file patches receive semantic validation only for GDScript; structured scene and configuration tools provide their own typed semantic validation.
- Structured scene operations use deliberately narrow first contracts: structural changes are leaf-only, values exclude references/resources/collections, scripts and child scenes must be dependency-free, script operations permit exactly one reviewed attachment, and signals are bindless and built-in.
- Revert checkpoints are in memory and do not survive editor restart.
- Public Godot APIs expose no Project Settings dirty flag; Input Map proposals enforce affected-action live/disk equality but cannot identify unrelated pending Project Settings UI edits as dirty.
- Multi-file changes are approved one file at a time rather than as a transaction.

### Diagnostics And Execution

- Historical Output dock contents are unavailable through public GDScript APIs.
- Built-in game-process debugger output is not comprehensively captured.
- Orca performs one bounded automatic observation after each run, can objectively evaluate narrow predeclared startup/exit criteria, and can use the normal reviewed edit loop for fixes and explicit reruns. It does not autonomously apply fixes or rerun without another model tool decision.
- Captured runtime diagnostics are conservative stdout/stderr parsing, not full debugger state.

### UI And Sessions

- Prompt enhancement and image upload are visual placeholders.
- Conversations cannot yet be renamed or exported.
- History is keyed by the canonical project path, so moving the project does not automatically migrate its saved sessions.
- Session history is plaintext local data and has no configurable retention count beyond the built-in limit of 50.
- Search cards open the first match rather than presenting an interactive action for every match.

### Providers And Distribution

- First-class OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, Ollama, LM Studio, and Local OpenAI-compatible profiles use the shared Chat Completions transport. Local profiles support optional authentication, editable endpoints, explicit keyless model discovery, manual model fallback, and endpoint-aware discovery caches.
- Custom OpenAI-compatible endpoints remain available, but their model capabilities cannot always be discovered.
- Native Anthropic Messages, Gemini `generateContent`, Azure, and OpenAI Responses adapters are absent.
- Gemini's OpenAI-compatibility surface is beta, and Gemini/xAI have not been exercised against live credentials in the permanent automated suite.
- Editable profiles and fixed-provider origin overrides start Chat-only. Tools are exposed and runtime-permitted only when the request-scoped profile contains a persisted compatibility pass and separate explicit enablement matching the exact provider, origin, base/chat endpoint, case-sensitive model, reasoning effort, and probe version.
- Credentials are not stored in an OS credential manager.
- Cost is an estimate unless directly reported by the provider. Catalog prices may become stale, provider markups may differ, and unknown custom models may show unavailable cost or context limits.
- Plugin metadata declares version 1.2.0 and a concise description. Public release documentation, an MIT license, and add-on-only Git export rules are present; release automation, broader compatibility coverage, and third-party asset attribution records remain incomplete.

## Roadmap

### P0: Reliability And Persistence

- Expand provider-settings coverage for credential isolation, migration, custom endpoint preservation, discovery failures, and active-request lockout. Editor-only unsaved conflicts, diagnostics contracts/logger integration, editor scaling, and deeper plugin lifecycle coverage are permanent.
- Expand CI when additional Godot versions enter the supported compatibility matrix; Godot 4.7.2 is currently covered.
- Continue tuning token/context reserves from real-provider beta evidence; automatic complete-turn compaction is implemented for models with known context windows.
- Add durable pending-approval recovery after editor restart without weakening stale-state checks.
- Add session rename/export, configurable retention, and project-move migration.

### P1: Deeper Godot Integration

- Add bounded live current-scene inspection for unsaved editor state where public APIs permit it.
- Broaden current structural, value, script, instance, and signal contracts only through dedicated safety review.
- Expand structured Godot scene operations and add further settings only through dedicated risk review.
- Expand reflected Godot API metadata only where public stable APIs provide trustworthy additional detail; prose scraping remains excluded.
- Add project symbol indexing and reference search.
- Add progressive tool-schema disclosure only after provider compatibility, context budgeting, restoration, and deterministic tool-availability behavior are designed and tested.
- Expand semantic validation beyond the structured scene path to remaining raw `.tscn` and `.tres` patch proposals.
- Expand verification beyond text/process evidence only when a bounded visual or input-observation capability exists.

### P2: Review And Workflow

- Add multi-file change batches and transactional approval.
- Persist revert checkpoints.
- Add an interactive search-results card with Open actions for every match.
- Add richer changed-file summaries and context-budget warnings.
- Implement prompt enhancement and image/screenshot context.

### P2: Providers And Privacy

- Add native Anthropic Messages, Gemini `generateContent`, Azure, and OpenAI Responses adapters only where the shared Chat Completions transport is insufficient.
- Expand provider capability detection and add more community-maintained provider adapters.
- Support explicitly keyless local endpoints.
- Continue refining endpoint trust presentation from real user feedback without weakening exact-origin transport enforcement.
- Integrate an OS credential store where available.
- Add post-response retry controls, rate-limit backoff, proxy support, and configurable timeout behavior. Pre-submit connection retry is already bounded to one attempt.

### P3: Release Readiness

- Expand the supported compatibility matrix beyond Godot 4.7.2 when permanent coverage is available.
- Add packaging and release automation around the existing add-on-only Git export rules.

## Decision Log

### External Project Research

Decision: other projects may be studied to identify user problems, workflows, capabilities, and architectural tradeoffs, but they are research sources rather than code donors by default. Useful concepts must be independently designed for Orca's visual language and rebuilt through its bounded tool contracts, Plan/Work permissions, explicit approval, conflict detection, validation, cancellation, persistence, and testing architecture.

Read-only ideas should remain Plan-safe where appropriate. Any project mutation must still produce an immutable reviewed proposal, and any external-state operation must preserve Orca's ownership and boundedness rules. Research must not be used to justify copying another project's prompts, UI, naming, source structure, or weaker safety assumptions, and Orca's invariants must never be relaxed to match another product's feature count.

Direct source reuse is exceptional rather than the default. When compatible licensed material is intentionally reused, its provenance, license and attribution obligations, reason for reuse, and integration implications must be documented explicitly.

### Request-Scoped Project Guidance

Decision: automatically load only the bounded root `res://AGENTS.md` and bounded skill catalog metadata. Treat both as untrusted project guidance beneath higher-priority instructions and runtime controls, keep them through one turn's tool rounds, and remove them from resumable history. Do not automatically load skill bodies; require an explicit exact-name `read_project_skill` call and do not recursively follow references from its text.

### Reflected Godot API Information

Decision: expose stable `ClassDB` signatures and registered global-class metadata plus validated public editor Help topics. Do not construct reflected objects, load project scripts to discover members, or scrape prose from private Help controls. Open Docs delegates to Godot's own Help UI; the model receives reflected metadata, not the documentation page text.

### Unsaved Focused Source

Decision: a focused function read may use the exact unsaved source publicly exposed for the matching open script because it is read-only context. Such a result must identify editor provenance and omit a disk SHA-256, so it can never be confused with the saved base required for a patch.

### Serialized Dependency Discovery

Decision: use bounded `ResourceLoader.get_dependencies()` traversal for saved resource relationships. Reverse lookup may build a bounded project index, but results must explicitly exclude dynamic code loads, runtime-created resources, unsaved state, and completeness beyond scan limits.

### Tool-Loop Finalization

Decision: detect stable repeated or no-progress activity before the existing hard caps and permit one no-tools request so the model can report partial findings and a safe next step. Further tool calls from that request are denied with protocol-valid results. Keep the 12-round and 16-calls-per-response limits as independent hard failures.

### Progressive Schema Disclosure

Decision: progressive tool-schema disclosure is deferred. Version 1.2.0 continues sending the complete schema eligible for the active mode; future disclosure must preserve deterministic availability, Plan/Work boundaries, context budgeting, provider compatibility, and protocol-valid continuation.

### Plan And Work Names

Decision: Plan is strictly read-only; Work can inspect, debug, and propose approved changes. Work remains the default because approval still protects every mutation. The internal `BUILD` identifier is retained to preserve stored session compatibility.

### Explicit Approval

Decision: model tool calls create proposals, not immediate writes. This keeps the user in control and supports diff review, conflict detection, validation, and revert.

### Line Patches

Decision: replace whole-file model output with bounded line edits and a base hash. Orca still materializes complete old/new content internally for validation, review, application, and revert.

### Request-Scoped Editor Context

Decision: capture context automatically for each turn but remove the snapshot from persistent message history when the turn ends. The model can call `get_editor_context` to refresh it during a task.

### Supported Diagnostics Only

Decision: use public `Logger`, validation, and play-state APIs. Do not scrape private Output, Script Editor, or Debugger controls because those structures are unstable and incomplete.

### Diff Presentation

Decision: use a compact unified diff in the narrow dock and an expanded side-by-side Previous/Proposed viewer. This preserves readability without requiring a wide dock.

## Milestone Log

### 2026-10-01: Orca 1.1.0 Godot Intelligence

- Added automatic bounded root project instructions and bounded project-skill catalog metadata as private request-scoped guidance, with explicit exact-name skill-body loading and no recursive execution semantics.
- Added read-only Plan/Work tools for reflected Godot API signatures and Help topics, focused saved or unsaved GDScript functions, and bounded serialized forward/reverse dependencies.
- Added early repeated/no-progress tool-loop detection and one no-tools finalization request beneath existing hard caps.
- Preserved path, symlink, Orca-directory, output, privacy, and protocol boundaries; unsaved editor source never supplies a patch hash, API reflection never constructs objects, and dependency discovery never loads resources.
- Registered six permanent suites in CI and documented contracts, hard limits, security, testing, and known limitations.
- Included the post-1.0 responsive scaling, compact composer, transparent branding, expanded-diff sizing, active-turn auto-follow, and sequential approval visibility fixes in 1.1.0.
- Deferred progressive tool-schema disclosure rather than claiming it as implemented.

### 2026-09-29: In-Dock About Page

- Added a narrow-dock Provider/About switch to Settings without adding another crowded header action.
- Added an About page with the Orca mark, version sourced from `plugin.cfg`, a concise product and safety explanation, Godot compatibility, and MIT attribution.
- Preserved Provider as the default tab and the current-model shortcut into model configuration.
- Added permanent tab, release-metadata, branding, and 300 px layout coverage.

### 2026-09-27: Foundational Agent

- Established the Godot editor dock, settings, OpenAI-compatible API calls, conversation history, and initial list/read/edit tool loop.

### 2026-09-27: Composer And Header Cleanup

- Increased action targets, improved composer spacing and prompt readability, and repaired send-button presentation.

### 2026-09-27: Dock Visual Polish

- Added a branded empty state and clearer header hierarchy.
- Reworked the prompt composer with editor-themed focus treatment, compact actions, empty-prompt send state, and subdued unavailable actions.
- Replaced the basic mode menu with a responsive in-dock overlay and container-sized, icon-led Plan and Work choices that explain their permissions.

### 2026-09-27: Streaming And Cancellation

- Replaced buffered responses with nonblocking SSE streaming, reconstructed fragmented tool calls, added Stop behavior, and protected against stale requests.

### 2026-09-27: Structured Activity And Safe Review

- Replaced the text-only transcript with message and activity controls.
- Added collapsed tool cards, unified and side-by-side diffs, explicit Apply/Reject, conflict-aware writes, and Revert.

### 2026-09-27: Plan And Work Modes

- Added enforced read-only Plan mode and approved-change Work mode.
- Added mode-specific colors, prompts, tool schemas, and authoritative transition messages.

### 2026-09-27: Godot-Aware Coding Loop

- Added bounded recursive search and line-ranged reads with hashes.
- Added active scene, selected node, active script, caret, selection, and unsaved-state context.
- Replaced full-file model writes with precise line patches.
- Added GDScript validation before proposal and application.
- Added supported diagnostics and play-state reporting.
- Added Open File actions to tool and change cards.

### 2026-09-27: Sessions And Usage Visibility

- Enabled New Session with confirmation, full in-memory conversation reset, and empty-state restoration.
- Added provider-reported session token accounting across tool rounds and compact context usage in the dock header.
- Added session cost using provider values first, then automatic public model metadata with built-in offline fallbacks.
- Removed the small header logo to make room for session metrics at narrow dock widths.
- Removed manual pricing fields, added bounded weekly `models.dev` metadata refreshes, and moved metrics to a dedicated header row.

### 2026-09-27: Provider-Aware Settings

- Replaced the modal URL/key/model form with a responsive in-dock provider settings page.
- Added first-class OpenAI, DeepSeek, and OpenRouter profiles, provider-specific credentials, authenticated model discovery, searchable selection, and capability-driven reasoning effort.
- Preserved custom OpenAI-compatible endpoints and migrated existing global settings into provider profiles.
- Added request-scoped provider snapshots and provider-specific reasoning continuation for multi-round tool calls.

### 2026-09-28: Transport Failure Hardening

- Removed duplicate raw buffering for successful SSE streams and added separate bounded accumulators for visible output, reasoning, reasoning details, tool arguments, events, and error bodies.
- Added structured transport failure metadata, one safe pre-submit connection retry, strict content-type handling, clean-EOF SSE flushing, and tool-call ID validation.
- Marked failed partial responses as incomplete, preserved protocol-valid history, and stopped Orca transport errors from feeding back into project diagnostics.
- Added committed parser and local HTTP integration tests for clean streams, disconnects, oversized responses, cleanup, and malformed content types.

### 2026-09-28: Project Session History

- Enabled the History action with an in-dock browser for opening, continuing, deleting, and clearing project conversations.
- Added bounded project-keyed `user://` persistence with schema validation, 50-session retention, verified atomic replacement, backup recovery, and startup restoration.
- Persisted visible messages, sanitized tool activity, non-actionable change summaries, mode, model labels, and aggregate usage without credentials, hidden reasoning, editor snapshots, patch contents, or raw tool output.
- Added provider-independent continuation restoration and made interrupted tool sessions or truncated histories view-only to prevent duplicated side effects.
- Added permanent persistence, redaction, recovery, retention, controller restoration, and narrow-history-layout tests.

### 2026-09-28: Work Mode Naming

- Renamed the user-facing Build mode to Work to cover editing, debugging, and future run/fix/verify workflows without implying compilation or export.
- Preserved the internal `BUILD` enum and stored numeric mode value for session compatibility.
- Made the composer model pill open Settings at the provider-appropriate model control while preserving request-time settings lockout.

### 2026-09-28: Safety Regression Coverage

- Added permanent patch-materialization coverage for line operations, malformed and overlapping edits, and LF/CRLF preservation.
- Added tool safety coverage for mode schemas, direct mutation denial, path and symbolic-link boundaries, proposal immutability, stale conflicts, safe application, and guarded revert.
- Added controller coverage for Plan runtime enforcement, explicit approval and rejection, cancellation during approval, and protocol-valid results for every assistant tool call.
- Corrected project-root path normalization so `res://` cannot be treated as a writable file target.
- Added Godot 4.7.2 CI for all permanent suites, localhost transport integration, plugin initialization, and replacement-artifact hygiene.

### 2026-09-28: Rich Code Presentation

- Added line-aware fenced-code parsing that keeps malformed or incomplete fences as literal text and isolates code from Markdown and BBCode transformations.
- Added bounded selectable code blocks with language labels, Copy actions, horizontal scrolling, and public `GDScriptSyntaxHighlighter` integration.
- Reused the finalized renderer for streamed completions, tool-preface text, non-streaming responses, and restored complete sessions while leaving interrupted responses literal.
- Added permanent parser, rendering, streaming-finalization, restoration, safety, and 300 px layout coverage.

### 2026-09-28: Grouped Tool Activity

- Grouped consecutive allowlisted read-only tools into compact activity cards with aggregate status, total duration, and expandable per-call details.
- Kept mutation and unknown tools standalone and preserved dedicated change-card review for every patch proposal.
- Derived live and restored groups from the same flat tool-event sequence without changing session schema or persisting raw tool output.
- Persisted only bounded search labels and normalized navigation metadata needed to restore useful activity targets and Open actions.
- Added permanent aggregate, grouping-boundary, restoration, mutation-isolation, navigation, and 300 px layout coverage.

### 2026-09-28: Persistent Task Checklist

- Added `update_tasks` in Plan and Work as an atomic session-metadata operation with strict item, content, status, and single-active-task validation.
- Added a compact collapsible task panel above the composer with text and color status indicators and bounded narrow-dock layout.
- Persisted sanitized task state independently from tool protocol, restored it per project session, included it only in request-scoped model context, and cleared it for new sessions.
- Kept successful task updates out of the activity feed, surfaced failed updates as bounded activity, and excluded raw task arguments from persisted events.
- Added permanent tool validation, controller state, request-context, session sanitation/restoration, panel behavior, failure, and 300 px layout coverage.

### 2026-09-28: Saved Scene Inspection

- Added `inspect_scene` in Plan and Work using public `PackedScene`/`SceneState` metadata without node instantiation or raw `.tscn` parsing.
- Added bounded hierarchy, ownership, groups, child-scene references, serialized property, signal-connection, and JSON-safe Variant summaries with valid whole-record output truncation.
- Rejected outside-project, symbolic-link, Orca-owned, missing, non-scene, oversized, malformed, and unsaved scene targets before exposing navigation metadata.
- Integrated scene inspection into grouped activity, session-safe target metadata, scene navigation, and model guidance while persisting no raw scene output.
- Added permanent fixture coverage for structure, Godot values, child instances, connections, bounds, strict argument types, failures, Plan execution, and no-approval behavior.

### 2026-09-28: Structured Project Settings Inspection

- Added `inspect_project_settings` in Plan and Work for a bounded configuration overview or one allowlisted explicit setting without mutation or approval.
- Reported selected application, main-scene, window, Input Map, autoload, rendering, and physics values with active feature overrides and typed JSON-safe summaries.
- Added sensitive-path and low-risk-family restrictions, strict runtime arguments, fixed enumeration and Variant bounds, and a 64 KB whole-JSON output limit.
- Integrated grouped activity, `project.godot` navigation, safe session restoration metadata, model guidance, permanent tests, and CI coverage without persisting returned values.

### 2026-09-28: Reviewed Input Map Proposals

- Added Work-only `propose_input_map_changes` with typed add/update/remove operations for key, mouse, and joypad events.
- Generalized the controller's reviewed mutation path while preserving mandatory approval, protocol-valid cancellation, and runtime Plan denial; Plan now also blocks revert.
- Bound proposals to exact `project.godot` and retained-content hashes, preserved every unrelated byte, compared affected live/disk state, reparsed candidates, and verified synchronized InputMap values.
- Added a dedicated structured review card, safe non-actionable session summaries, guarded apply/revert with recovery-aware rollback behavior, permanent tests, and CI coverage.

### 2026-09-28: Reviewed Main Scene Proposals

- Added Work-only `propose_main_scene_change` for setting a validated saved `.tscn` as the project launch scene through explicit approval.
- Normalized valid UID/resource representations, detected semantic no-ops, disclosed unresolved previous values, and preserved every unrelated valid UTF-8 project byte.
- Revalidated target and project paths, live/disk state, retained hashes, PackedScene loading, and candidate configuration immediately before verified replacement.
- Added live ProjectSettings synchronization, guarded revert, conflict/recovery statuses, a dedicated narrow review card, private proposal boundaries, permanent tests, and CI coverage.

### 2026-09-28: Allowlisted Project Settings Proposals

- Added Work-only `propose_project_settings_changes` for atomic typed changes to six low-risk viewport, window-override, and stretch settings.
- Enforced exact path allowlisting, strict Variant types, conservative finite dimensions, enums, duplicate rejection, built-in defaults, and affected live/disk equality.
- Materialized only requested assignments, rebound retained metadata to the complete old/new allowlisted delta, and preserved unrelated valid UTF-8 project bytes.
- Added a dedicated typed review card, private/redacted persistence boundaries, synchronized apply/revert with conflict and recovery handling, permanent tests, and CI coverage.

### 2026-09-28: Structured Scene Proposal Foundation

- Added Work-only `propose_scene_changes` with an initial `create_scene` operation for `Node`, `Node2D`, `Node3D`, and `Control` roots.
- Constructed candidates through `ClassDB` and `PackedScene`, then saved and reloaded bounded `user://` scratch scenes before review and immediately before application.
- Bound proposals to absent targets and exact candidate hashes, rechecked path, existence, unsaved state, and semantic root identity, and added verified creation plus guarded deletion revert.
- Added a dedicated structured review card, Plan runtime denial, private proposal redaction, bounded session summaries, permanent tests, and CI coverage.

### 2026-09-28: Structured Scene Add Node

- Extended `propose_scene_changes` with hash-bound `add_node` operations targeting root or nested canonical parent paths.
- Reconstructed bounded compatible scenes with editor generation state, assigned scene-root ownership, and rejected scripts, instances, inheritance, Resource properties, open scenes, and unrelated serialization drift before review.
- Added existing-file verified replacement, final semantic verification, exact-byte guarded revert, structured hierarchy review, schema coverage, and permanent stale/conflict tests.
- Added dependency pre-screening, process/randomized scratch names, plugin-startup stale scratch cleanup, and prompt release of private proposal bytes after rejection, cancellation, failure, or successful revert.

### 2026-09-28: Expanded Structured Scene Operations

- Added typed property, leaf rename/remove/reparent, dependency-free child-scene instance, and persistent bindless signal connect/disconnect operations to the existing reviewed scene envelope.
- Added strict Variant decoding, canonical local paths, semantic before/after checks, dependency hashes, ownership and signature validation, operation-specific review summaries, exact-byte restoration, and permanent lifecycle coverage.
- Kept script attach/detach unavailable after confirming that Godot candidate construction would instantiate project scripts before user approval; documented the required future trust-boundary redesign instead of weakening review guarantees.

### 2026-09-28: Two-Stage Scene Script Operations

- Added dependency-free GDScript attach/detach to `propose_scene_changes` without loading or compiling project code during initial preparation.
- Added an explicit hash-bound Trust and Prepare review before candidate construction, followed by the normal immutable candidate Apply/Reject review inside one protocol-valid tool call.
- Rechecked scene/script paths, hashes, unsaved state, dependency freedom, GDScript validity, native-base compatibility, complete scene semantics, and exact-byte revert state before mutation.
- Reused one structured card and one sanitized session event across both stages; script bytes, hashes, trust bindings, operations, and pending approvals remain private and non-persistent.
- Added attach/detach lifecycle, stale script, invalid source, incompatible base, two-stage rejection/cancellation, privacy, and narrow-card regression coverage.

### 2026-09-28: Wave 4 Process Foundation

- Added Work-only `run_current_scene`, `run_main_scene`, and `stop_game` tools backed by one plugin-owned nonblocking Godot child process.
- Added fixed executable/project/scene arguments, active feature-aware main-scene resolution, unsaved-state checks, editor-run exclusion, private PID ownership, natural exit status, a 120-second timeout, and explicit kill-failure states.
- Added separately bounded stdout/stderr capture, continued pipe draining after retention limits, conservative project-local runtime diagnostics, and merged `get_diagnostics` reporting without private editor control scraping.
- Added standalone run/stop activity, Work-mode disclosure, sanitized persistence, deterministic lifecycle tests, and a real nested-Godot pipe/exit-code integration check.

### 2026-09-28: Bounded Run, Observe, Fix, Verify Loop

- Added immutable pre-launch `clean_startup` and `expected_exit` criteria, monotonic run IDs and snapshot sequences, read-only observation, and scoped machine-evaluated verification verdicts.
- Added a cancellable controller observation checkpoint after complete protocol-valid tool batches, with a 1.5-second settle period, five-second ceiling, three-run-per-turn limit, and request-scoped non-persistent evidence.
- Replaced single-line diagnostics with bounded stream-local parsing for Godot error/warning headers and following project-local `at:` or backtrace locations, including diagnostics beyond raw-output retention.
- Prevented criterion goalpost changes within a turn, nonzero-exit startup false passes, generic persisted success labels for failed verification, and oversized or malformed JSON/SSE tool-call batches.
- Kept fixes behind existing review approval and reruns explicit; no timer or diagnostic automatically changes files or starts another game.

### 2026-09-28: Protocol-Aware Context Budgeting

- Added conservative request estimation for known model context windows before initial requests and every tool follow-up, including tool-schema cost and bounded reserves for tool results and final answers.
- Added deterministic oldest-complete-turn compaction with one model-visible notice while preserving the active turn, request-scoped editor/runtime context, provider reasoning continuation, and complete assistant-call/tool-result protocol groups.
- Added fail-before-transport behavior when protected request state alone exceeds the safe budget; unknown custom-model limits continue without guessed enforcement.
- Rehydrated cached provider model metadata so discovered context limits remain available after cache reuse.
- Added permanent boundary, malformed-history, repeated-compaction, persistence, controller-index-remapping, and oversized-active-turn regression coverage.

### 2026-09-28: Animated Working States

- Added a mode-aware five-square bioluminescent tide indicator for initial thinking, post-tool response preparation, runtime observation, and assessment.
- Kept the transient indicator visible across successful SSE response headers and replaced it only when actual assistant text or tool activity begins, eliminating empty `Orca:` cards during first-token delays.
- Added explicit controller workflow state for every initial and follow-up provider request, deterministic animation cleanup, non-persistent status behavior, and narrow-dock regression coverage.

### 2026-09-28: Active Conversation Auto-Follow

- Replaced the one-frame bottom jump with bounded multi-frame following that survives deferred rich-text, container, code-block, and review-card layout.
- Kept active turns attached to the newest working, streamed response, tool, and approval activity, including automatic movement from one resolved proposal to the next pending proposal.
- Added regression coverage that expands a card after the initial scroll frame and verifies sequential review cards remain visible at the feed bottom.

### 2026-09-28: Gemini And xAI Providers

- Added first-class Google Gemini and xAI profiles using their OpenAI-compatible Chat Completions endpoints, separate credentials, authenticated model discovery, searchable model selection, and capability-driven reasoning effort.
- Normalized Gemini's native model list and xAI context, pricing, and reasoning capabilities while mapping their public metadata to the `google` and `xai` catalog namespaces.
- Preserved bounded opaque streamed tool-call metadata so Gemini thought signatures remain attached through tool-result continuation, and preserved xAI `reasoning_content` without displaying it.
- Added permanent adapter, metadata, parser, and localhost transport coverage without sending live provider requests.

### 2026-09-28: Release Documentation Baseline

- Declared Orca plugin version 1.0.0 and its user-facing description.
- Added MIT licensing, public installation and safety documentation, contributor and security guidance, a release changelog, and Godot-specific Git ignores.
- Recorded third-party SVG asset provenance as a release blocker until each source license and attribution requirement is verified.

### 2026-09-29: Responsive Editor Scaling

- Added one effective editor-scale policy for plugin-authored geometry while preserving Godot's already-scaled theme fonts and editor icons.
- Replaced the fixed-height composer with compact line-height-driven growth, removed unavailable image-action width, and corrected the 300 px-equivalent action-row budget.
- Scaled shell, settings, history, activity, task, and review-card geometry; bounded expanded diffs to the available editor window and stacked panes when narrow.
- Reworked the Orca mark as a transparent high-resolution SVG that remains visible on dark and light backgrounds.
- Added compact-composer, narrow-action, scale-conversion, editor-integration, and logo-transparency regression coverage.

### 2026-10-02: DeepSeek Stream Budget Alignment

- Bounded DeepSeek responses to 8,192 generated tokens, aligned with Orca's minimum known-context final-answer reserve, instead of inheriting the provider's substantially larger defaults.
- Raised the raw streamed transport allowance to 16 MiB while retaining tighter limits for accumulated assistant text, reasoning, tool arguments, metadata, SSE lines, and SSE events.
- Added provider-option coverage and a localhost regression proving that valid framing-heavy streams above the former 4 MiB threshold complete while oversized streams remain bounded.
- Restored the documented controller integration for repetitive/no-progress tool-loop detection and made the 12-round boundary request one tool-free summary instead of raising a system error after completed work.

### 2026-10-04: Orca 1.2 Editor Reliability Foundation

- Added permanent Godot 4.7.2 editor integration for real dirty script/scene state, exact unsaved current-editor source, patch/apply/revert conflict protection, saved-scene inspection/proposal rejection, and run blocking.
- Canonicalized reviewed file paths before editor-state, hash, and write checks; file reverts now reject dirty editor buffers rather than overwriting their saved backing file.
- Bounded diagnostic record fields, preserved warning severity, removed resource loading from logger callbacks, and reference-counted one shared logger so multiple services cannot duplicate records.
- Added diagnostics contract/editor integration and actual plugin enable/disable/re-enable suites, and registered all editor integration suites, including the previously omitted editor-scale suite, in CI.

### 2026-10-04: Orca 1.2 Local Provider Foundation

- Added first-class Ollama, LM Studio, and Local OpenAI-compatible profiles over the bounded shared Chat Completions transport, with editable conventional endpoints, truly optional bearer authentication, explicit keyless model discovery, and manual model fallback.
- Moved provider model discovery to an endpoint- and credential-aware cache and bounded model count, names, IDs, and reasoning metadata.
- Enforced local profiles as Chat-only at both schema and runtime boundaries; unsolicited tool calls fail before any project or process action unless an exact compatibility-bound opt-in is active.
- Added hermetic settings coverage, real EditorSettings profile-isolation coverage, keyless chat transport coverage, and keyless `/models` integration that verifies no Authorization header is sent.

### 2026-10-04: Orca 1.2 Endpoint Trust Hardening

- Added one strict endpoint policy for URL normalization, loopback/LAN/remote classification, exact-origin confirmation, and generated chat/discovery endpoint validation.
- Added Settings disclosure and confirmation bound to scheme, host, and effective port; stale confirmations, changed dialog text, malformed URLs, and partial profile saves fail closed.
- Chat and discovery reauthorize before constructing credential headers. Discovery disables redirects, while the low-level chat transport continues treating redirect responses as terminal HTTP failures.
- Bound Chat-only behavior to every editable OpenAI-compatible profile and fixed-provider origin override so DNS aliases, alternate IP forms, or provider labels cannot bypass the endpoint/model compatibility requirement.

### 2026-10-04: Orca 1.2 Compatibility-Checked Local Agents

- Added an isolated two-step synthetic function-call probe that sends no project, editor, session, task, instruction, skill, or real-tool context and requires exact call metadata, challenge arguments, matching tool-result continuation, and final acknowledgement.
- Persisted only bounded compatibility metadata in EditorSettings. A pass always starts disabled; a separate checkbox is required to enable Agent tools for the exact binding, and runtime recomputes the binding from the request snapshot.
- Kept canonical hosted providers unchanged while requiring probe plus opt-in for every editable profile and fixed-provider origin override. Provider, origin, base/chat endpoint, model, reasoning effort, or probe-version drift fails closed.
- Disabled the stream-options compatibility retry on probe requests and every normal continuation after a real tool round so post-tool failures cannot silently resend a changed request.

### 2026-10-05: Native Local Model Filtering

- Switched Ollama discovery to `/api/tags` and LM Studio discovery to `/api/v1/models`; known embeddings are excluded using native capabilities/types, with a conservative `embed` fallback only when metadata is absent.
- Preserved unrestricted manual Model ID override, reset normalized discovery cache to v3, sanitized cached records, and fixed stale request ownership and programmatic model-selection signal handling.
- Added bounded provider error extraction and local embedding-selection model-substitution detection. Live LM Studio testing showed that requesting its embedding ID returned HTTP 200 from the loaded Llama model; after the fix, Orca returns `model_mismatch` before emitting assistant text.

### 2026-10-05: Orca 1.2.0 Release Preparation

- Finalized 1.2.0 plugin metadata, public release notes, supported-version documentation, and About-page coverage.
- Kept editable-provider Settings within the 300 px dock constraint by preventing the Agent opt-in control from imposing a wide non-wrapping minimum.
- Retained add-on-only Git export rules and documented that release packaging automation remains future work.

## Handoff Checklist

Before another agent takes over, it should be able to answer:

- What user problem is currently being solved?
- Which architecture and safety invariants are involved?
- What code paths and tool schemas will change?
- How will Plan and Work differ after the change?
- What success, failure, cancellation, and stale-state paths need testing?
- What can be verified automatically and what still requires manual editor testing?
- Which known limitation or roadmap item changes when the task is complete?

At handoff, record the result, affected files, verification, residual risk, and next recommended action.
