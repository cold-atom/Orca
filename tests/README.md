# Orca Tests

GitHub Actions runs all commands below on Godot 4.7.2 through `.github/workflows/tests.yml`.

Run the parser and response-contract checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/api_client_test.gd
```

Run provider registration, model normalization, reasoning, and metadata-mapping checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/provider_test.gd
```

Run protocol-aware context estimation, reserve, compaction-boundary, and oversized-active-turn checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/context_budget_test.gd
```

Run line-patch materialization and newline-preservation checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/patch_utils_test.gd
```

Run filesystem path, proposal, conflict, application, and revert safety checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tools_test.gd
```

Run Plan/Work permission, approval, rejection, cancellation, guidance, tool-loop, and recoverable-interruption protocol checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/agent_controller_test.gd
```

Run project-scoped session persistence, recovery-checkpoint retention, redaction, and controller restoration checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/session_store_test.gd
```

Run the narrow History layout check:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/history_view_test.gd
```

Run provider/About tab switching, release metadata, and narrow settings-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/settings_view_test.gd
```

Run transparent, background-free logo asset checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/logo_asset_test.gd
```

Run the editor-scale integration check using the active editor display scale:

```bash
"$GODOT_BIN" --headless --editor --path . --script res://tests/editor_ui_scale_test.gd
```

Run working-state animation, first-token lifecycle, active-turn auto-follow, sequential review navigation, finalized assistant code-block, expanded diff, streaming-finalization, recoverable-interruption UI, restoration, structured review-card, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/chat_window_test.gd
```

Run grouped tool aggregate, expansion, navigation, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tool_activity_group_test.gd
```

Run persistent task-panel status, collapse, clearing, and narrow-layout checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/task_list_panel_test.gd
```

Run saved-scene structure, Variant normalization, connection, bounds, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/scene_inspector_test.gd
```

Run bounded ProjectSettings overview, explicit typed value, input action, privacy, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_settings_inspector_test.gd
```

Run root project-instruction loading, bounds, wrapping, and symlink-rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_instructions_test.gd
```

Run project-skill catalog, frontmatter, exact on-demand loading, bounds, and symlink-rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_skills_test.gd
```

Run reflected ClassDB class/member signature, inheritance, bound, and Help-topic checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/godot_api_inspector_test.gd
```

Run focused GDScript function extraction, unsaved editor-source provenance, ambiguity, and output-bound checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/gdscript_function_reader_test.gd
```

Run serialized forward/reverse resource dependency traversal, ordering, limit, and rejection checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/dependency_inspector_test.gd
```

Run repeated-call, alternating-cycle, repeated-round, and no-progress tool-loop guard checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/tool_loop_guard_test.gd
```

Run typed Input Map proposal, validation, application, live synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/input_map_proposal_test.gd
```

Run reviewed main-scene path/UID validation, exact materialization, live synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/main_scene_proposal_test.gd
```

Run allowlisted typed ProjectSettings validation, exact materialization, atomic application, synchronization, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/project_settings_proposal_test.gd
```

Run typed-root creation, node/property/structure operations, two-stage dependency-free script attach/detach, dependency-free child instances, bindless signals, pack/save/load validation, semantic preservation, and guarded revert checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/scene_proposal_test.gd
```

Run Orca-owned nonblocking process lifecycle, output bounds, multiline diagnostics, run identity, immutable verification criteria, timeout, ownership, and real pipe integration checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/game_process_service_test.gd
```

Run the deterministic local transport checks by starting the server in one terminal:

```bash
python3 tests/http_test_server.py
```

Then run the integration test in another terminal:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/api_client_integration_test.gd
```

The local server accepts seven requests and exits. It receives only the synthetic test key and prompt defined in the integration runner, and it accepts no network traffic from outside `127.0.0.1`.
