# Orca plugin updates and native-helper distribution

Orca checks stable GitHub Releases from `cold-atom/Orca`. GitHub publication can
precede Asset Store moderation. Updating and native-helper installation are
user-owned maintenance, never agent tools, and their public downloads require no
Orca account or GitHub token.

This checkout prepares **1.4.1**, the packaging follow-up to the GitHub-published
1.4.0 release rejected by the Godot Asset Store for bundled executables. Keep the
existing v1.4.0 tag/assets stable and publish the corrected package plus matching
helpers under a new **v1.4.1** tag. Godot users can upgrade directly from 1.3.0;
existing 1.4.0 installations can recognize the newer patch release. See
[1.4.1](../CHANGELOG.md#141---2026-10-30) for packaging fixes and
[1.4.0](../CHANGELOG.md#140---2026-10-29) for the full feature list. Publication and
Store approval remain pending; prior Store downloads and the thumbnail correction
must be coordinated with the reviewer separately.

## User workflow

- A dismissible dock notice announces a newer plugin version. **What's new** opens
  its official release page; **Later** dismisses that version.
- **Settings → General Settings** provides checking, daily-check preference,
  download progress/cancellation, **Update & Restart** and previous-addon rollback.
- Confirm an update after saving editor work and closing other editors of this
  project. Active requests/approvals, game runs, account/helper operations, unsaved
  scripts/scenes, composer drafts and failed conversation saving prevent handoff.
- Orca downloads and verifies the binary-free plugin ZIP without loading downloaded
  scripts. A trusted independent installer waits for this editor to exit, replaces
  `addons/orca/`, retains the original, and reopens the same project/Godot binary.

The first updater-equipped release is installed manually once. Developer checkouts,
packages without manifests and locally modified addons use manual installation.
Public dirty-state checks cover only the current editor; save other resource-editor
work too. Other editors of the same project must be closed.

## Native credential helper

Plugin ZIPs contain **no compiled executables**. Cloud account connections use a
separately published OS-vault helper. BYOK and local providers do not need it.

1. Install/enable Orca normally. When the plugin runs, it checks the exact cached
   helper and quietly prepares it in the background if missing. This cannot run
   during the Asset Store's ZIP download, before Orca is installed/enabled.
2. Orca downloads only this OS/architecture's helper, verifies its exact size,
   SHA-256/native format, sets Unix owner-only executable permissions and atomically
   installs it. There is no install prompt, progress card or updater-style notice.
   Existing account/BYOK onboarding remains; BYOK/local use does not wait.
3. Choosing **Sign in / Sign up with Orca** while preparation is pending shows
   **Preparing connection…** in the existing Account status. That explicit sign-in
   continues once when ready. Cancel or navigation invalidates the sign-in intent
   but leaves background preparation running. Disabling Orca/closing Godot cancels
   preparation and its waiters safely.
4. Preparation alone never opens a browser or sends chat requests. Startup saved
   account restoration waits for readiness and keeps the existing vault scope.
   Configured Cloud onboarding waits for that restoration decision; fresh onboarding
   remains available during preparation. Failures stay quiet until Cloud sign-in
   needs the component; the normal Sign in action retries, without an install step.

Startup, sign-in and cooperating editors share a single preparation operation.
Transient transport/429/5xx failures use at most three attempts with 1s/2s backoff;
live install locks are polled within a 150-second shared preparation deadline.
Invalid hashes/architecture/redirects, changed caches and unsafe paths are not
automatically retried. Verified cached components produce no download request.

The packaged `native_helpers.json` catalog (`orca-native-helpers-v1`) binds the
installed plugin version to exact public asset names, sizes and hashes. Assets come
from that version's release, not `releases/latest`. Supported builds are Linux and
Windows x86_64, macOS arm64 and macOS x86_64. Unsupported platforms remain usable
with BYOK/local providers, but cannot use Cloud account persistence.

The cache is `OS.get_data_dir()/Orca/native/<sha256>/<asset-name>`, shared by this OS
user across projects. It is outside the addon, project, updater workspace and
conversation data. Every launch revalidates bytes; there is no bundled-helper or
plaintext-credential fallback. Credentials retain the existing origin-bound OS
vault scope, private pipes, native refresh lock and process cleanup.

An atomic per-hash install lock coordinates editors. Recognized dead-owner locks
and their bounded partial download can be reclaimed; unrelated files/symlinks are
preserved. Cancel/failure removes only the operation's own partial download/lock.
Changed cached executables are refused, not overwritten. Remove a changed file
from this cache before retrying; missing execute permissions must also be corrected.
Retained hashes allow older editors and plugin rollback to use their own revision.
A newly updated plugin quietly prepares its exact helper if that hash is not cached.

Linux needs a usable Secret Service collection/libsecret runtime. macOS builds are
ad-hoc signed, not Developer ID signed/notarized; downloaded-package/Gatekeeper and
Keychain acceptance remains a real-platform check. Missing/locked vaults fail
visibly and are separate from a missing helper.

## Release contract

1. Bump `addons/orca/plugin.cfg` and release notes to the intended stable
   `major.minor.patch`. Use a new release tag; do not replace older published assets
   with different bytes under an existing catalog hash.
2. Build/test all four helpers from the selected source revision. Keep the native
   compilation, real isolated vault/protocol/locking and separate-Godot-process
   acceptance jobs. Initialize Godot so required script UIDs are present.
3. Package the binary-free addon and separate helpers together:

   ```bash
   python3 scripts/package_release.py --version 1.4.1 --require-platform-helpers --helper-assets dist --output dist/orca-v1.4.1.zip
   ```

   Substitute the actual new version. The script refuses version mismatches,
   symlinks, output inside the addon, overwrite, missing/misnamed/wrong-architecture
   helpers and disguised native files elsewhere in the plugin. Known compiled
   helpers are excluded from the ZIP, even if present locally. The public C++ source
   remains included. The ZIP contains only addon files, its generated helper catalog
   and `update_manifest.json`; all ZIP file modes are non-executable. `.import`
   sidecars are omitted.
4. Publish the exact output set under the matching stable GitHub Release:

   ```text
   orca-v<version>.zip
   orca-v<version>.zip.sha256
   credential_helper_linux.x86_64
   credential_helper_windows.x86_64.exe
   credential_helper_macos.arm64
   credential_helper_macos.x86_64
   ```

   Submit **only the plugin ZIP** to Godot. The updater selects its exact official
   ZIP URL and GitHub SHA-256 digest; helper installation uses its packaged hashes.
   A checksum establishes integrity against the selected official release, not an
   independent code-signing authority. The reviewer must confirm acceptance of
   post-install component downloading; prior Asset Store downloads and thumbnail
   corrections remain owner-maintained moderation work.

Ordinary packaging changes no source files. `--write-manifest` explicitly writes
both generated manifests into source for review. An existing pinned source helper
catalog must match these exact helper bytes unless that explicit regeneration flag
is selected. Never mix a ZIP/catalog and helper assets from separate builds.

## Builds and downloads from GitHub Actions

Tests calls **Native credential helpers** automatically; it can also be dispatched
manually. Native jobs use Linux x86_64, Windows x86_64 and Apple Silicon/Intel Mac
runners. Ubuntu 22.04 supplies the Linux baseline, Windows uses a static CRT and
LF-only binary pipes, and Mac targets macOS 11 with ad-hoc signing. Standard builds
require no signing/account secret. All native jobs must pass before packaging.

The aggregate artifacts are:

- **orca-package**: binary-free `orca-v<version>.zip` and its checksum.
- **orca-native-release-assets**: four raw helpers matching that ZIP's catalog.
- **orca-native-helpers**: a permissions-preserving tar.gz under `addons/orca/native/`
  for local build preparation. It is not an Asset Store submission.

Per-platform `orca-helper-*` artifacts are intermediate tested outputs. Actions
artifacts expire after 14 days; public GitHub Release assets are durable downloads.
The plugin does not download authenticated/expiring Actions artifacts. Downloading
an artifact does not publish it. A test ZIP's helper install requires its assets to
be published under the catalog's tag; use the isolated fixtures before publication.

**Prepare Orca release** is manually dispatched against an existing stable tag.
It rebuilds/tests the helpers, checks the plugin/updater/helper flow, then produces
**orca-release** with the ZIP, checksum and all raw helpers. Its Publish checkbox
defaults off. Only explicit publication has repository write permission; jobs do
not commit, tag, push or submit to Godot.

Published release notes link **Full Changelog** directly to `CHANGELOG.md` at the
selected release tag. Finalize that version's changelog before tagging so the link
retains the correct release history as the default branch advances.

For local development, build the current machine's helper and explicitly generate
a partial catalog/manifests:

```bash
python3 scripts/build_native_helper.py
python3 scripts/package_release.py --helper-assets .ci/local-helper-assets --write-manifest --output .ci/orca-local.zip
```

This permits local cache preparation using the generated catalog; it is not
four-platform release acceptance. The production downloader still uses official
release URLs. Native tests populate only isolated fixture caches. Generated source
catalogs/manifests should be reviewed or removed before changing addon bytes.

### Commit-based Godot Asset Library releases

A GitHub + Download Commit submission downloads the selected repository snapshot,
not an uploaded Release ZIP. Compiled helpers are Git-ignored/export-excluded and
must not be committed. Prepare a clean distribution snapshot from the **exact
accepted plugin ZIP**, including its `native_helpers.json` and update manifest,
and retain the matching separately published helpers under the catalog's version
tag. The snapshot's addon file set must equal the ZIP's file set; do not regenerate
its catalog from different binaries or change addon bytes after manifest creation.
Test the actual Godot snapshot installation as well as the canonical ZIP.

GitHub's automatic Source code ZIP/tar.gz files are snapshots, not canonical updater
assets. Prefer the packaging script for official ZIPs; generic ZIP writers may not
meet the updater's deliberately narrow archive contract.

## Bounds and recovery

- Plugin release JSON: 128 KiB, at most 32 assets; stable numeric version triples.
- Plugin download: at most 32 MiB; bounded request timeouts and four requests including
  redirects. Helper catalog: 8 KiB/four entries. Helper: at most 8 MiB, a 120-second
  whole-download deadline and at most four requests including redirects per attempt,
  inside the 150-second shared preparation deadline.
- Metadata never redirects. Download redirects allow only the initial official
  GitHub asset URL and HTTPS `release-assets.githubusercontent.com` destinations.
  No provider/account/GitHub credentials are attached.
- Plugin ZIP: at most 2,049 entries, 8 MiB per file, 128 MiB aggregate plus a 512 KiB
  manifest. Check central/local headers, spans, sizes, unique case-folded paths and
  regular-file attributes before decompression. Reject ZIP64, encryption, comments,
  directories, symlinks, traversal, overlap and unsupported formats. Validate file
  hashes and plugin metadata before installation.
- Installed/staged/rollback addons must match complete manifest file sets and
  hashes. Added/changed bytes block replacement; bounded generated `.import`
  sidecars are handled separately. Legacy manifests may describe bundled helpers
  for exact old-addon inspection/rollback; newly produced packages are binary-free.
- `res://.orca-update/` is import/Git-isolated and protected from agent tools. It
  contains project ownership, lock, staging, download, trusted copied installer,
  previous addon and bounded transaction/result records. Preparation hashing and
  extraction run on a bounded background thread.
- The installer waits at most 60 seconds for the initiating editor's exit. Unix
  uses a fixed signal-0 retained-PID probe and positional-argument `exec` wrapper;
  Windows uses public Godot process APIs. Relaunch retains the actual headless
  display backend. No executable/argument/PID authority is exposed to the model.

**Restore previous addon & restart** restores only an unchanged retained original.
For an interrupted replacement where Orca cannot load, close this project's editors
and invoke the retained trusted launcher:

```bash
"$GODOT_BIN" --headless --path "/absolute/project/.orca-update/runner" --script "/absolute/project/.orca-update/runner/update_runner.gd" -- --recover "/absolute/project"
```

Use the original Godot binary/project path. Unknown/modified files are preserved.
The next successful update retires only an unchanged older rollback copy, keeping
one previous addon. Native helper caches and OS-vault records are outside this
transaction and are never deleted by plugin rollback.

## Verification and remaining acceptance

Set `GODOT_BIN` to Godot 4.7.2 and use isolated tests:

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1 ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS=1
"$GODOT_BIN" --headless --editor --path . --quit
"$GODOT_BIN" --headless --path . --script res://tests/native_helper_service_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/native_helper_editor_test.gd
python3 -m unittest discover -s tests -p native_helper_packaging_test.py -v
python3 -m unittest discover -s tests -p native_helper_download_test.py -v
"$GODOT_BIN" --headless --path . --script res://tests/update_service_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/update_editor_test.gd
python3 -m unittest discover -s tests -p update_package_test.py -v
python3 scripts/build_native_helper.py
python3 scripts/test_native_credentials.py
```

Fixtures cover exact catalog/native headers, separate publication/binary-free ZIPs,
HTTP redirects, hashes/size/disconnect/cancel, cache reuse/tamper/symlinks, installer
coordination, background startup/retries, saved-account restoration, sign-in
cancellation without cancelling preparation, narrow inline Account status, private vault
round-trip/locking and separate-Godot-process persistence. Updater tests exercise
independent wait/replace/reopen, failure/rollback and local-change protections.

Linux/Godot 4.7.2 isolated acceptance is locally verified. Real GitHub publication,
Asset Store ZIP/snapshot acceptance, graphical full-project update/relaunch,
Windows/macOS downloaded-helper execution/prompts and exhaustive power-loss
boundaries remain manual. Editor fixtures retain Godot shutdown RID/ObjectDB
diagnostics. Background helper installation is automatic plugin initialization,
never model authority. There is no independent signing authority, beta/delta updater,
server-side execution or automatic metered-request replay.
