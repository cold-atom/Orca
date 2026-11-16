# Extensions and MCP inspection

**Orca → Settings → Extensions** starts with the guided **Blender Asset Studio**
section for asset creation. It needs only Blender 5.2+; Orca ships the workspace connector.
Optional MCP integrations appear below it under the collapsed **Optional connections**
section, with a compact card for each configured app. Expanding this section never
starts a connection; collapsing it preserves live connections and shows their count.
The explanation appears inside the expanded section so the normal page stays compact.
Configure once on this computer, then click **Connect** in any Godot project.
**Disconnect** stops that editor's bridge; **Cancel** interrupts connection startup.
The **⋮** menu contains **Configure…**, **Connection details** and **Remove connector**.

See [Blender setup and workflows](BLENDER.md) for the dedicated asset workspace.
It can be set up directly without enabling a Blender Lab inspection connector.
Blender cards initially identify **Live Blender · Inspection only**. Connected MCP cards say
**Connected for inspection**: this reports the stdio bridge
connection, not verification of an open Blender listener. Official Blender Lab can
separately enable reviewed live authoring, changing its role to **Create & edit**.

The development checkout adds **Settings → Extensions**, using the supplied
puzzle-piece icon. Plugin metadata remains 1.8.0; this feature is unreleased.

## Connect a local server

1. Install a trusted MCP stdio server using its own installation instructions.
2. Open **Settings → Extensions → Optional connections → Add connection…**.
3. Choose **Blender Lab — Official**, **Blender — Community**, or **Custom MCP**
   (listed text resources). Confirm the name and installed server program. Orca
   suggests an existing `blender-mcp` path from bounded known locations/PATH entries;
   a filename is not evidence of an official installation. The official profile
   shows an installation checklist and the **Blender Lab installation guide** link,
   including the Blender add-on, separate server and listener. The focused form
   scrolls vertically at narrow widths/large fonts. **Browse…** handles
   custom locations. Arguments are optional, under **Advanced**, and passed
   individually without Orca constructing a shell command.
   Prefer an already installed direct server executable. A package runner can
   itself install packages or spawn children; that is behavior of the chosen
   program, not an Orca-managed installation.
4. **Save** the configuration, then click **Connect** on its card. Setup discloses
   the selected local program's OS access; Connect is the explicit user-owned start
   decision bound to the displayed configuration and current project/editor.
   Existing `blender` descriptions keep their community profile; selecting the
   official type is an explicit change. Save itself never starts a program.
5. Check the connection state and supported inspection description. Ask Orca in Work
   mode to inspect the connection's catalog or a supported resource/Blender state.

Descriptions live once in computer-local EditorSettings. Up to 16 connectors /
128 KiB of descriptions, 24 arguments per connector and four live bridges per
editor are supported. Reload restores descriptions only; Connect must be clicked
again. Do not put credentials in arguments: setup is not encrypted secret storage.

## Reconnect after switching projects

Open the other project, open **Extensions → Optional connections**, and click **Connect** on the same connector card.
There is no project copy, export, reuse picker or second setup step. Each editor
still owns a fresh process and project-bound inspection context. Send a fresh Work
message after connecting; external reads still require **Allow read**.

Older valid project descriptions and the old reusable library are migrated
automatically into a versioned canonical registry at `orca/extensions/mcp_library`.
Exact descriptions differing only in ID are deduplicated; different arguments,
names or explicit profiles remain separate. ID collisions do not overwrite existing
entries. Old records are preserved; bounded origin/removal fingerprints prevent
deleted or superseded legacy descriptions from returning. Malformed/future records
are preserved and rejected. Discovery reads only Orca's own local EditorSettings,
not another project's files (4096 properties, 32 records, 128 KiB scan budget).
The registry retains at most 512 64-character bookkeeping hashes; migration can
be incomplete at those limits and never silently drops source records.

Configuration is shared for future starts, never live process/approval authority.
Configure changes stop the affected local bridge and require a new Connect; unchanged
Save preserves it. Launch actions are single-use, sealed in memory and bound to
root, service identity, generation and exact registry snapshot. An old cancelled
start cannot stop a newer connection. Closed coroutines settle before their client
Nodes are retired, with failed-stop ownership retained. No automatic reconnect/replay.

Arguments remain literal: project-specific paths require review and are not rewritten.
Setup belongs to this computer's Godot configuration, not the ZIP or Git repository.
Newly saved preferences are visible in another editor after restart; live cross-editor
preference synchronization is not provided. Reopening Extensions refreshes the current
editor's local settings snapshot. Inspection snapshots also bind service identity,
so equal root/generation values cannot transfer authority across editor instances.

The selected local executable runs with the user's OS access and inherited
environment. It is trusted software, not a sandbox. Connecting is user-owned
maintenance and is never a model tool. Orca does not install the server/add-on,
open Blender, select a Blender document, or send Godot project roots to the server.

## What this milestone supports

`inspect_mcp` has four operations:

| Operation | Result |
| --- | --- |
| `catalog` | The connected, turn-bound capability snapshot; no new server call. |
| `read_resource` | One exact listed URI with a text MIME type. |
| `blender_scene` | Official profile: `get_objects_summary`; community profile: `get_scene_info`. Empty arguments only. |
| `blender_status` | Official profile: `get_blendfile_summary_datablocks` (counts, active workspace and render engine); community profile: `get_addon_status`. Empty arguments only. |

Blender operations appear only when the selected profile's exact tool and a
supported schema accepting empty arguments are advertised. The catalog's
`inspection_tools` mapping, turn context and approval card identify the exact
tool. Profile selection never falls back to another bridge's vocabulary, including
when a server advertises both sets. No new Cloud operation enum is needed: the
existing `blender_status` operation is explicitly a profile-specific summary,
not a claim that the official server reports add-on version/status.
Other discovered tool names are
visible metadata, not callable functions. A `readOnlyHint` annotation cannot
enable Python execution, file writes, generators or arbitrary server tools.
The Blender profile relies on the user trusting the connected server to implement
its advertised inspection contract; a program can misrepresent its behavior.

The model can request these operations only in **Work**. Every external read
waits for an **Allow read / Reject** card identifying the server, operation and
resource URI. Script Auto apply does not approve it. Text returned by the server
is sent to the selected model as untrusted reference data. Catalog metadata can
also enter the model context. No credentials or executable/argument settings are
inserted into requests. Source text may be quoted by the model in its answer;
normal conversation persistence therefore still applies to visible answers.

The first transport supports newline-delimited MCP JSON-RPC with initialization
revisions **2025-11-25**, **2025-06-18**, and **2024-11-05**. Unsupported versions
fail explicitly. It does not yet implement the 2026 stateless protocol, HTTP,
OAuth, custom environment variables, server prompts, Skills-over-MCP, sampling,
elicitation, resource subscriptions, image results or arbitrary tool dispatch.
Server-initiated requests receive an unsupported-capability error; project roots
are not disclosed. Instructions supplied in initialization are not consumed.

## Blender setup and next milestone

### Official Blender Lab server

Blender's own integration is [Blender Lab MCP](https://www.blender.org/lab/mcp-server/),
with [official source and tool documentation](https://projects.blender.org/lab/blender_mcp).
It is distinct from community packages with similar executable names. Local
acceptance targets official server/add-on **v1.0.3** with **Blender 5.2.2 LTS**.

1. Install and enable the official MCP extension in Blender from Blender Lab's
   page. The extension is only the Blender-side component.
2. Install the separate official server from its source. For example, with an
   already installed `uv`:
   ```bash
   uv tool install 'git+https://projects.blender.org/lab/blender_mcp.git@v1.0.3#subdirectory=mcp'
   command -v blender-mcp
   ```
   Use the resulting absolute executable path. A bare package name on PyPI or
   `uvx blender-mcp` is not evidence that the official server was installed.
3. Open Blender and enable the add-on listener in **Preferences → Add-ons → MCP**.
   Its default is `127.0.0.1:9876`; Auto Start can start it when Blender opens.
4. In Orca, select **Blender Lab — Official**, enter the official server executable,
   and use `[]` arguments for its default stdio/local connection. The executable
   field is the MCP server, not Blender, its add-on's `__init__.py`, or a `.blend` file.
5. Save and click **Connect**. Connection details may show 26 discovered tools and zero
   resources; the card describes only the inspections Orca actually exposes.
   An older community profile against the official server exposes only `catalog`.
6. Start a fresh Work turn: “Inspect the current Blender scene through Blender Lab
   and list its objects.” Review `get_objects_summary` and click **Allow read**.
   The untouched default scene should contain Camera, Cube and Light. Ask for the
   data-block/workspace/render-engine summary to exercise `blender_status`.

The official server implements these fixed observations by sending its own bundled
Python to the Blender add-on. Orca supplies no Python or arbitrary arguments and
does not call its generic execution, background-Blender, navigation, rendering or
file-writing tools. Trust remains in the selected installed server implementation.
JSON returned as MCP text is bounded and forwarded as untrusted reference text;
`structuredContent` does not create extra dispatch authority or bypass content checks.

### Community bridge

A typical Blender integration has an installed stdio bridge and an add-on inside
Blender. Open Blender and enable the add-on's connection yourself, then configure
the bridge in Orca using **Blender — Community**. The selected bridge and add-on
versions must be compatible. Synthetic MCP tests do not imply live community
bridge or other Blender-version acceptance.

The MCP connector supports inspection and connection management. Modeling, rigging,
animation and export/import use [Blender Asset Studio](BLENDER.md) or its optional live
integration. Official Blender Lab's **⋮ → Enable live authoring…** in Work permits
reviewed creation/editing in the current interactive scene. `blender_session` uses
pinned Orca helpers through the exact official execution transport; it exposes typed
commands, not generic MCP calls or model Python. See the
[live workflow](BLENDER.md#work-in-an-already-open-blender-session).

The existing `res://skills/<slug>/SKILL.md` loader remains available. A full Skills
library follows the MCP/Blender milestones described in `DEVELOPMENT.md`.

## Lifecycle, bounds and recovery

- All stdio I/O is nonblocking. One request per connection, 8 KiB request frames,
  128 KiB aggregate response/stdout and stderr work per request, 24 JSON nesting
  levels, 16 frames per process frame and 64 notifications bound transport work.
- Catalogs allow four pages and 64 entries per kind, with a separate 32 KiB
  model-facing metadata budget; truncation is disclosed.
  Tool bodies/resources are not fetched while discovering the catalog. A read
  returns at most 16 text blocks / 32 KiB; binary and unexpected-URI results fail.
- The connection generation/catalog is fixed through a turn. Disconnect, edited
  configuration, process failure or list-changed notifications invalidate it.
  Reconnect and start a fresh turn to use changed capabilities.
- Stop cancels pending approval and closes a bridge with an active request.
  Disconnect terminates only Orca's retained direct bridge process. It does not
  stop Blender or promise termination of subprocesses created by the server.
  If direct-process stop fails, Orca retains its identity, reports the failure,
  and refuses replacement/removal until an explicit disconnect succeeds.
  In-flight external effects cannot be rolled back or presumed not to have
  happened. Accepted requests are never automatically replayed.
- History retains only coarse inspection receipts, with no external URIs,
  returned tool text, live capabilities or actionable approval. Restoration
  cannot reconnect, replay or approve an external read.

## Orca Cloud

Cloud additionally requires authenticated boolean `orca.mcp_inspection` in the
model catalog, pinned as `hosted_mcp_inspection` for the turn, plus existing
account/origin/model readiness. The companion backend adds only the bounded
`inspect_mcp(server_id, operation, uri?)` function contract. It does not connect
to MCP servers or receive launch settings. Older catalogs omit the tool, and
direct calls remain denied. Deploy/reload the updated API and refresh the model
catalog before trying this with Cloud. No database migration is needed.

## Verification

Use the startup suppressions and isolated configuration described in
`tests/README.md`. Relevant checks:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/mcp_test.gd
python3 tests/run_editor_test.py mcp_editor_test.gd
python3 tests/run_editor_test.py mcp_editor_test.gd --graphical
python3 tests/run_editor_test.py mcp_editor_test.gd --graphical --blender-lab-executable /absolute/path/to/blender-mcp
python3 -m unittest discover -s tests -p translation_catalog_test.py -v
```

The optional `--blender-lab-executable` path is an explicit live acceptance action:
keep an already open default Blender scene listening at `127.0.0.1:9876`. The
runner uses the installed bridge, actual Orca launch/read cards and fixed official
scene/data-block reads, with a synthetic model and isolated Godot project/XDG state.
It does not install or open Blender, use live inference, save the `.blend`, or
automatically pick up an inherited live-executable environment variable. The
ordinary runner/CI continue to use only the synthetic peer.

The synthetic Python stdio peer uses no owner files, credentials, Blender or model
inference. Tests cover real process framing, UTF-8, initialization, malformed and
oversized output, unknown IDs, server requests, list changes, incompatible schemas,
timeouts, cancellation, permissions and provider continuations. Both bridge
vocabularies, wrong/mixed profiles, incompatible official schemas, JSON/text
results, exact approval tool identity, profile replacement and in-flight Stop
are covered. Normal-editor tests
exercise project-local preference persistence across two editor processes, explicit launch/read UI,
five-language 1×/1.5×/2× layouts and teardown. The live Linux graphical acceptance
passes with official Blender Lab server/add-on v1.0.3 and Blender 5.2.2 LTS,
including the default scene and data-block summary through actual approval cards
and synthetic-model continuations. Other server/Blender versions, live inference
and Windows/macOS graphical interoperability require separate acceptance.
