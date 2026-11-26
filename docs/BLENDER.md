# Blender Asset Studio

The **Orca 1.9.0 — Blender Asset Studio & Live Authoring** release includes
guided Blender setup, reviewed game-asset workspaces and optional authoring in an
already open Blender document. See the [published release](https://github.com/cold-atom/Orca/releases/tag/v1.9.0).

This checkout prepares **1.10.0 — Qwen, Claude & Blender Reliability**, including
workspace selection, field-specific error feedback, Auto apply continuity/explicit
pause/resume and validated punctual-light GLB handoff. **1.9.0 remains the latest
published release.** See the [candidate changelog](../CHANGELOG.md#1100---unreleased).

## Few-click setup

1. Restart Godot and open **Orca → Settings → Extensions**. **Blender Asset Studio**
   is the first section, using Orca's compact settings typography, inline connection
   status and native setup button. **Optional connections** below is collapsed by default and is not
   a prerequisite for asset creation.
   The single requirement note reads **Only Blender 5.2+ is required.** Hover it
   for the included-connector explanation; it disappears once connected.
2. Click **Set up Blender**. Orca checks Godot's Blender preference and bounded
   known installation locations. One detected installation goes straight to startup
   confirmation. Several installations require an explicit selection. If none are
   found, **Choose Blender…** supports portable/custom installs and macOS app bundles;
   **Download Blender** opens the official download page, then **Check for Blender**
   searches again. Choosing an installation never launches it.
3. Confirm **Start workspace** after reviewing the exact selected program. Orca starts
   Blender in the background. Startup exposes **Cancel**; **Workspace ready** appears
   only after the shipped connector's command contract and workspace identity validate.
4. Click **Back to chat** and describe your asset in **Work** mode. Your composer draft
   is preserved. **Workspace ready** confirms the dedicated background connection;
   the section separately explains missing provider/tool capability or Plan
   mode; workspace readiness itself does not grant model capability or edit permission.

No Python installation, package command, JSON configuration or `opencode.json`
is required. Orca ships an independently implemented constrained connector that
runs inside Blender's own Python. This also avoids downloading a second Python
runtime or installing dependencies into the user's system environment.
The official Blender Lab add-on and separate MCP server are optional for this flow.
Extra installation, new asset, template, texture and recovery controls are collapsed
under **Manage workspace…**. Connected installations cannot be changed; disconnect
first. A failed stop retains the owned process and exposes **Try disconnect again**.
Cancelled startup settles before reconnect and never replaces a new connection or
replays the previous start. Reopening Settings/loading preferences never launches it.

The selected program is saved in local EditorSettings, not in the project/plugin
release. Installations are user-local; the saved workspace is bound to the exact
Godot project root. Loading preferences never starts a process. Connections to
already open Blender documents appear as separate cards under **Extensions → Optional connections**, with
configuration/details under their **⋮** menu;
see [cross-project MCP setup](EXTENSIONS.md#reconnect-after-switching-projects).

## Complete plugin installation

These are mandatory Orca runtime source files, shipped in the plugin ZIP and Git
source distribution, even if Godot does not display Python files in its FileSystem:

```text
addons/orca/blender/workspace_connector.py
addons/orca/blender/workspace_contract.py
addons/orca/blender/live_session.py
addons/orca/blender/live_export.py
```

They implement the dedicated asset workspace, live-session adapter/export worker
and pinned declarative command contract using Blender's Python. Keep them in the
plugin. The installed Blender Lab `blender-mcp` server is the other connection path
for an already open Blender.
Workspace startup checks missing/unreadable runtime files before creating a
workspace or launching a process, and shows a complete-plugin reinstall message.
The release packager and updater reject workspace-enabled packages missing either
workspace file and live-enabled packages missing any of the four files; a plain
file-list ZIP command does not check those dependencies.

Use Blender **5.2+**. Native Linux/macOS/Windows installations and portable paths
have discovery/launch adapters. Linux also has fixed Snap/Flatpak launch adapters;
Flatpak receives only explicit toolkit-read/workspace-write mounts. Their actual
installation/confinement behavior still requires acceptance. AppImage/wrapper
stopping retains only the direct process identity; an OS-held workspace lease
prevents a surviving child from racing a replacement writer. Orca never kills
unrelated Blender instances or accepts a model-supplied PID.

## Workspace and recovery

Assets are edited in a per-project private user-data workspace, outside `res://`.
Every successful edit saves a new immutable `.blend` revision and its hash receipt.
A failed edit reloads the prior owned revision. A cancelled/failed request is
never automatically replayed; reconnect explicitly to inspect saved revisions.

**New asset workspace** starts another asset. **Open asset in Blender** opens the
saved revision for manual inspection/editing; future agent edits create other
revision files rather than overwriting that file. Changed saved revision bytes
invalidate the baseline. **Restore previous asset revision** is an explicit idle
Work action that saves a new revision, rather than overwriting the old one.

**In the 1.10.0 release candidate:** New Session starts a conversation, not a new
Blender file. Before the first Work submission with an existing asset and a capable
provider, choose **Continue this workspace**, **Start a separate asset…**, or
**Chat without Asset Studio**. Continue sends the draft with the existing workspace;
separate opens startup confirmation, preserves earlier revisions and keeps the draft
until you return to chat and send. Opting out omits only Asset Studio for this chat;
the optional live Blender connection is independent. **Back to chat** in Asset Studio
lets you reconsider. A new/restored chat or reconnection does not inherit this choice.
Whole-workspace preview/export cards show the revision even when collapsed. Live
preview/export cards say **Selected objects** instead.

**Start from saved Blender file…** copies an explicitly selected, hash-bound
`.blend` file. Automatic scripts are disabled. Linked libraries, embedded scripts
and drivers are refused; originals are preserved. **Attach asset texture…** prepares
a bounded still image and copies it into the workspace under its content hash.
Models refer only to that texture ID, never arbitrary external file paths.

Revisions and recovery files are retained as user artwork. There are at most 128
revisions per workspace, 64 current export records, 16 attached texture IDs, 128
objects, 256 bones, 64 actions and a conservative 100k evaluated-vertex budget.
Templates/revisions are capped at 32 MiB; GLB is capped at 16 MiB. Larger work
requires splitting assets or a separately designed higher-budget workflow.

## Supported declarative commands

The current toolkit exposes 28 fixed command families, rather than arbitrary
Python or unrestricted operator dispatch:

| Family | Commands |
| --- | --- |
| Asset/object management | reset, transform, delete, duplicate, join |
| Modeling | primitive, custom mesh, mesh_edit (extrude/inset/subdivide/merge/normals/smooth/reverse), fixed modifiers, curve |
| Game geometry | collider, decimated LOD copy |
| Materials/textures | PBR material, user-attached texture, smart UV unwrap, diffuse/normal/roughness bake |
| Characters | armature, automatic/explicit skin weights, fixed object/bone constraints |
| Animation | named object/bone keyframes, bounded visual animation bake, shape keys |
| Procedural assets | bounded native Geometry Nodes palette and graph realization |
| Scene/physics | camera, light, frame/FPS settings, native rigid body and cloth setup |

Coordinates are metres and rotations are degrees. Commands are bounded JSON data,
not code. Blender physics/simulations, arbitrary shaders, modifiers and control
rigs do not automatically become Godot gameplay components; bake/convert where
supported and verify the engine result. Unsupported nodes/add-ons, unrestricted
sculpting/operator APIs and freely generated Python remain outside this contract.
A private Blender process/file is not an OS security sandbox; unrestricted
generated-code execution requires an independently tested isolation layer.

## Chat, preview and Godot handoff

Example: “Create a low-poly character, add a simple rig and idle animation, preview
it, then import it into this Godot project.”

The Work-only `blender_workspace` wrapper has seven operations:

| Operation | Behavior |
| --- | --- |
| help | Compact command catalog; select up to four command names for exact schemas. |
| inspect | Fresh object/action/workspace summary. |
| edit | Validate 1–16 typed commands, then review or use the separately confirmed workspace Auto apply scope and checkpoint an immutable revision. |
| preview | Render a bounded 384px CPU image and a static interactive 3D snapshot in the workspace. |
| export | Stage a self-contained GLB, validate it and return an opaque artifact ID. |
| import | Review the artifact hash/summary, existing-file baseline and project destination; save with recovery checkpoint, then observe Godot reimport. |
| place | Review addition to a saved, clean, scriptless Node3D current scene; apply one native Undo action and report save pending. |

Review is the default. **Auto apply workspace…** on a pending workspace card opens
one explicit confirmation with **Remember for this project**. Script Auto apply's
confirmation also offers **Include Blender workspace operations**, and General
Settings has a separate Blender workspace choice. Existing script-only decisions
do not silently expand. Once enabled, help/inspect/edit/preview/export proceed
automatically and retain compact visible result cards and expandable evidence.
Import/place still require their exact approvals. Remembered permission is local,
exact-project and revision-bound; Plan/view-only history cannot activate it, and
loading preferences never starts Blender. Clicking the green header edit icon
revokes all automation scopes and clears their remembered defaults. Failed/interrupted
automatic operations pause this scope for the session; no request is replayed.

In the development build, commands rejected locally before dispatch retain valid
Auto apply permission. Numeric errors name the field, supplied value and allowed
bounds so the model can submit a corrected command. Script-only permission refresh
or checkpoint failure does not revoke a separate Blender grant.

Genuine execution/conflict pauses show their reason on the card and an amber header,
even if another scope remains active. The turn ends with one summary instead of
continuing into more approval cards. Send a follow-up to inspect current state, then
choose **Resume workspace Auto apply…** and confirm once. The remembered preference
remains saved, but cannot silently override a paused session. Failed operations are
never replayed.

Every `blender_workspace` call must be sent by the model in a separate response,
including help/inspect/preview under Auto apply. `inspect_mcp`, task updates and
project reads have their own responses. Orca now states this in the initial/Resume
prompt and tool descriptions, and supported OpenAI/standard Foundry requests
disable parallel tool generation for this workflow. A mixed batch is rejected
before any operation executes; one bounded correction explains the exact reason.
The final error identifies the offending standalone tool or JSON format instead
of a generic failure. If only the checklist ran, Recovery Ready says that no
project or Blender operation ran; Resume keeps the checklist and re-inspects.

3D preview controls are **left-drag to orbit**, **Shift-left-drag or middle-drag to
pan**, **wheel/pinch to zoom**, **Frame/F** to recenter, **Reset** for the initial
angle and **Expand** for a resizable viewer. Navigation uses Godot's local camera,
with no Blender request or asset change. The snapshot is a static evaluated model
with core geometry, base-color textures and basic PBR materials; animation,
normal/metallic-roughness texture maps and exact Blender shader/lighting parity
are not part of this viewer. Preview-only GLBs cannot be imported through an
artifact ID. Decoding bypasses project importers/scripts/GLTF extension callbacks,
bounds geometry/texture/time work and retains the rendered image when unsupported.
At most three render scenes remain; older geometry releases to its thumbnail.
New Session/history restoration never reloads persisted 3D authority or geometry.

Preview cards and setup offer **Attach preview
to chat**; confirmed image capability is required. This is an explicit user image
attachment, not automatic tool-image injection or a claim of visual verification.

GLB validation bounds JSON/nesting/records/accessors/images and rejects external
URIs, cyclic nodes and unverified required extensions. Import targets must be
canonical, non-hidden project `.glb` files in existing folders, with normal
protected-path/symlink/dirty checks and unchanged old/export bytes. Custom scene
import scripts require a separate execution-trust workflow and are refused here.
Source save, observed PackedScene import, visual correctness and editor-only
placement/save-pending are reported separately. Placement never saves/reloads a
scene and is natively undoable. **Revert last asset import** checks exact current
bytes against its memory-only current-session receipt; New Session clears that
receipt. Recovery bytes remain on disk but never restore approval authority.

In the development build, native point, spot and directional lights in
`KHR_lights_punctual` have a bounded validation path. The static preview uses its
own lighting, while the exported asset retains supported authored lights. Other
required extensions are identified on the failed operation card and do not become
import artifacts. A successful preview alone never confirms the exported contents.
Project replacement is also mutually excluded across editor instances. A crashed
critical replacement can leave a private lock requiring explicit recovery inspection;
it is never silently cleared and never authorizes replaying the original operation.

## Cloud and validation

### Work in an already open Blender session

Connect the official **Blender Lab** card under **Extensions → Optional connections**,
then choose **⋮ → Enable live authoring…** in Work and confirm. Its role becomes
**Live Blender · Create & edit**. Asset Studio's setup is independent. Interactive
Blender 5.2+ and native Undo are required; scripted/linked documents, unsupported
evaluation nodes/modifiers and exceeded budgets fail explicitly.

Example: “Create a low-poly robot in this Blender scene, give it a blue material,
preview Body and Rig, then import it into Godot.” `blender_session` supports reviewed
help/inspect/edit/preview/export/import/place. Its 26 typed families reuse the workspace
catalog except global reset and timeline/settings changes. Review is default;
script/workspace Auto apply does not cover live work. On a pending operation choose
**Auto apply live session…** and confirm to automate help/inspect/edit/preview/export
in that exact current session. This is memory-only, not a remembered project default.
Godot import and placement always require review. Execution failures/conflicts, intervening live
changes found by inspection, Stop or the green header revoke pause automation; session/
Plan/reconnect/reload boundaries clear it. Both confirmations have scrollable bodies
and visible native actions at narrow widths/large fonts.

Local numeric/JSON/help-selection rejection and missing/unknown server IDs do not
erase an existing valid live grant. After a genuine pause, start a fresh live
inspection and choose **Resume live Auto apply… → Inspect and resume**. This one
exact confirmation approves the fresh inspection and a new grant for the same live
session; its result establishes the current baseline. Other operations cannot
resume it. If native authoring itself is paused, inspect recovery and explicitly
enable authoring again in Extensions. The failed operation is not replayed.

Edits preserve earlier unsaved work and create private recovery copies before mutation.
Manual edits invalidate stale proposals. The original document stays open, without
automatic save/reload. **Undo last Orca live edit** requires unchanged live state and
revokes old identities. For partial/uncertain failures, inspect Blender and **Show live
recovery copies**; opening/recovering a copy is user-owned, never automatic restoration.
**Attach live asset texture…** supplies bounded texture IDs.

Preview/export selects 1–16 exact object names, including parents, rigs and referenced
constraint/Boolean targets. A private snapshot runs in a bounded background Blender
worker, preserving the open document. Godot preview, validated import, conflict-checked
source Revert and native Undo placement use Asset Studio's reviewed handoff.
New Session/restoration/Plan/disconnect clear authoring. Enabling replaces earlier
Orca authoring in that Blender instance. Interrupted effects are never replayed.

The MCP execution transport carries verified Orca helpers, **not unrestricted generated
Python**. Full Python-driven MCP control still needs independently tested isolation.
Cloud needs the additive `blender_sessions` rollout and catalog refresh; older flags
alone do not enable the tool.

Cloud requires strict authenticated `orca.blender_workspaces` plus normal managed
readiness, pinned through the turn. The companion backend supports only this
bounded wrapper; Blender, approvals and project writes execute locally. Deploy
the updated API and refresh the model catalog to enable Cloud. BYOK uses normal
provider tool-readiness checks. Setup works independently of model credentials.

Checks are documented in [tests/README.md](../tests/README.md). The normal editor
runner isolates project/XDG state; native acceptance requires explicit installed
Blender selection. Linux native 5.2.2 is locally exercised. A three-platform CI
workflow uses SHA-256-pinned official Linux x64, Windows x64 and macOS arm64
Blender 5.2.2 packages. Fresh CI, clean-machine novice acceptance, other versions,
Intel macOS/custom builds and Snap/Flatpak/AppImage acceptance remain required.
