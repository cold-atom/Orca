# Orca: The Godot AI Assistant

## Overview
Orca (formerly GodoPilot) is an autonomous AI coding assistant integrated directly into the Godot Engine. It acts as an Editor Plugin, providing a docked chat interface where developers can interact with an AI agent powered by Large Language Models (LLMs). 

Instead of just answering questions, Orca uses **Function Calling** to actively participate in the development process. It can browse the project, read scripts, and propose reviewed code changes within the Godot workspace.

## Development Documentation

- [`AGENTS.md`](AGENTS.md) contains mandatory repository instructions and a quick architecture map for coding agents.
- [`DEVELOPMENT.md`](DEVELOPMENT.md) contains the current implementation state, architecture, tool contracts, safety model, testing process, limitations, decisions, roadmap, and milestone log.

## What We Have (Current State)
The project is currently a functional, foundational Godot Editor Plugin located in the `addons/orca/` directory.

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
4. **Autonomous Tools (`tools.gd`)**
   - Provides specific capabilities to the AI:
      - `list_directory`: Lists all folders and files inside a specified `res://` directory.
      - `read_file`: Reads bounded, numbered line ranges and returns a content hash.
       - `search_files`: Recursively searches project text files with bounded output.
       - `inspect_scene`: Reads bounded saved scene hierarchy, serialized properties, instances, groups, and signal connections through `PackedScene`/`SceneState` without instantiating nodes.
       - `inspect_project_settings`: Reads a bounded configuration overview or one allowlisted typed ProjectSettings value without modifying the project.
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
    - **Built-in Safety:** Canonical path and symlink checks keep access inside the project and protect Orca's own plugin directory. Writes use conflict checks, validation, diff review, temporary-file replacement, and reversible checkpoints. Game runs accept no arbitrary commands or PIDs and are bounded to one Orca-owned direct process.
5. **Agent Modes and Review**
   - Plan mode exposes only read-only tools.
   - Work mode can propose patches, but every change requires explicit user approval.
    - Consecutive read-only activity is grouped with aggregate status and duration while retaining each call's details and navigation.
    - Unified diffs, expanded side-by-side review, and file navigation make agent work visible.
    - Completed responses render fenced code in bounded selectable blocks with language labels, Copy actions, and native GDScript highlighting.
    - A mode-colored five-square working indicator shows initial thinking, post-tool response preparation, and runtime observation without creating empty assistant messages during first-token delays.
    - Active turns automatically follow late-sizing response, tool, and review cards so the newest activity and sequential approvals remain visible.
6. **Sessions and Usage**
   - Conversations are automatically saved in bounded, project-scoped local history and the most recent session is restored when the editor reopens.
   - The History page can open, continue, or delete prior sessions. Interrupted or truncated sessions remain safely view-only.
   - The header New Session action archives the current conversation and restores the empty state without undoing already-applied project changes.
    - Provider-reported token usage is accumulated across all model requests in a session, including tool follow-up rounds.
    - The header shows current context use and session cost when model metadata is available.
    - Known model context windows are budgeted conservatively before every request, with capacity reserved for tool results and a final answer. Old complete turns are omitted atomically when needed without splitting tool-call/result groups.
     - Orca prefers provider-reported cost, then automatically resolves public model context and pricing metadata from a cached `models.dev` catalog with built-in offline fallbacks.
    - Multi-step work can maintain a bounded persistent checklist with pending, active, completed, blocked, and cancelled states.
7. **Configuration (`config.gd`, `settings_view.gd`)**
   - Provides an in-dock settings page for OpenAI, Google Gemini, xAI, DeepSeek, OpenRouter, and custom OpenAI-compatible endpoints.
   - Stores separate API key, model, and reasoning-effort selections per provider and discovers models from provider APIs.
   - Integrates with Godot's Editor Settings for persistence. Editor Settings is not an encrypted OS credential store.

## What We Are Building (The Vision)
We are building a truly autonomous copilot for game development in Godot, similar to GitHub Copilot or Roo Code (formerly Cline), but deeply integrated into the Godot ecosystem. The goal is to move beyond simple chat interfaces to an AI agent that understands the full context of a Godot project.

### Future Goals
- **Expanded Toolset:** Adding capabilities to query the local Godot class reference, manipulate the Scene Tree, instantiate nodes, and configure properties automatically.
- **Deeper Context Awareness:** Scene-tree inspection, node properties, and project symbol indexing.
- **Structured Godot Operations:** Reviewed Input Map, project configuration, and scene-tree proposals built on bounded typed inspection.
- **Debugging Assistant:** Bounded automatic post-launch observation, conservative runtime diagnostics, reviewed fixes, explicit reruns, and scoped startup/exit verification without claiming visual gameplay correctness.
- **Local-First Focus:** Ensuring the plugin works flawlessly with locally-hosted, fast open-source models (like Llama 3 or Qwen) for privacy-conscious developers.
- **Robustness:** Refining error handling for complex edge cases (e.g., massive files, connection timeouts) and creating better syntax parsing.

Orca aims to be an essential sidekick for Godot developers, handling boilerplate code, exploring unfamiliar APIs, and accelerating the game development workflow securely and efficiently.
