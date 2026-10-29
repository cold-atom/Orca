# Orca plugin updates (1.4.0)

Orca 1.4.0 is released. Windows/macOS native/update acceptance remains pending.

Orca checks the latest **stable GitHub Release** from `cold-atom/Orca`. GitHub
publication can precede Asset Library moderation. The updater is user-owned
plugin maintenance; it is never an agent tool and requires no Orca account.

## User workflow

- A small dock notice announces a newer version. **What's new** opens its official
  release page; **Later** dismisses that version. A later version can notify again.
- **Settings → General Settings** shows the update card below Language, with update status, **Check for updates**, the daily-check
  preference, download progress/cancellation, and the previous-addon rollback action.
- Checks run at most daily, with a bounded validated metadata cache so an existing
  notice survives restart. Disabling automatic checks retains manual checking.
- **Update & Restart** asks for confirmation. Save editor work and close other
  editors of the same project first. Finish/cancel Orca requests and approvals,
  stop game runs, and submit/clear composer drafts. Unsaved scripts/scenes, account
  pairing/refresh, active work, or failed conversation saving prevent handoff.
- Orca downloads, verifies and stages the release without running downloaded code.
  A trusted independent installer then waits for the initiating editor to exit,
  replaces `addons/orca/`, retains the original, and reopens the same project with
  the same Godot binary. Account credentials and conversation storage are separate
  from the replaced addon.

Each project has its own addon copy. The first updater-equipped release must be
installed manually once. Existing releases without a manifest, development
checkouts, locally modified addons, and packages incompatible with Godot require
manual installation; the updater preserves those files.

## Release contract

1. Bump `addons/orca/plugin.cfg` and the release documentation to the intended
   stable `major.minor.patch` version. Complete normal tests and platform checks.
2. Build the deliberately supported native credential-helper binaries and import
   the addon in the supported Godot editor so required script UIDs are available.
3. Build the ZIP using the repository's packaging script:

   ```bash
    python3 scripts/package_release.py --version 1.4.0 --require-platform-helpers --output dist/orca-v1.4.0.zip
   ```

   Replace `1.4.0` with the version in `plugin.cfg`. The command refuses mismatched
   versions or an existing output. It includes only `addons/orca/` regular files,
   omits generated `.import` metadata, and inserts `update_manifest.json` into the
   archive without modifying the source addon. The manifest records the format,
   version, minimum Godot version, paths, byte sizes, SHA-256 hashes and explicitly
   allowlisted credential-helper executable permissions. A ZIP checksum file is
    produced alongside it. `--require-platform-helpers` requires all four supported
    binaries and checks their ELF/PE/Mach-O format and architecture; a missing or
    misnamed artifact blocks packaging. These header checks complement the native
    execution tests, not replace them.
4. Publish a stable GitHub Release with tag `v1.4.0` and asset
   `orca-v1.4.0.zip`. The updater requires GitHub's exact asset URL, bounded size
   and SHA-256 `digest`. Drafts, prereleases, source snapshots and arbitrary assets
   are excluded. Asset Library submission remains a separate owner action.

`.github/workflows/release.yml` prepares packages from an **existing tag** only on
manual dispatch. Its `publish` checkbox defaults off; artifact preparation and
actual GitHub publication are separate jobs. Publication uses the selected tag
and generated notes only when explicitly selected. The workflow is prepared
locally; no release, tag, commit, push or Asset Library submission has been made
for this feature.

## Builds and downloads from GitHub Actions

No OS machine, Cloud credential or signing secret is needed for the standard CI
builds. Push the source/workflows to GitHub with Actions enabled. The Tests workflow
calls **Native credential helpers** automatically, or select **Actions → Native
credential helpers → Run workflow** on the desired branch. Four native jobs build
and test the helpers. The manual Run workflow button becomes available once the
workflow exists on the repository's default branch; push-triggered Tests can run
candidate branches first. The matrix covers
Linux x86_64, Windows x86_64, Apple Silicon macOS and Intel macOS with the
pinned Godot 4.7.2 editor. Ubuntu 22.04 provides the Linux build baseline; Windows
uses a static CRT; Mac binaries target macOS 11 and are ad-hoc signed. Real native
vault/protocol/locking and cross-Godot-process tests are required before upload.

After the whole run succeeds, its Artifacts section contains:

- **orca-native-helpers**: download/unzip the Actions wrapper to get
  `orca-native-helpers.tar.gz`. It contains the four binaries under
  `addons/orca/native/` and preserves executable permissions.
- **orca-package**: download/unzip to get `orca-v<version>.zip` and
  `orca-v<version>.zip.sha256`, with the version read from `addons/orca/plugin.cfg`
  (for example, `orca-v1.4.0.zip` when the plugin version is `1.4.0`). This is a
  complete installable addon from that exact source commit,
  including all helpers and the updater manifest. Use it directly in a disposable
  Godot test project; it uses the version currently declared in `plugin.cfg`.

Per-platform `orca-helper-*` artifacts are intermediate build outputs. Keep the
complete ZIP or aggregate tar.gz for distribution/preparation. Artifacts currently
expire after 14 days; published Release assets are the durable user download.
The package upload opts into hidden-file discovery only for `.ci/orca-v*.zip*`,
so Actions includes the generated ZIP/checksum inside the hidden build directory.

For local development packaging, extract the **matching source commit's** helper
bundle at the repository root:

```bash
tar -xzf /path/to/orca-native-helpers.tar.gz
python3 scripts/package_release.py --require-platform-helpers --output dist/orca-v1.4.0.zip
```

Use the version in `plugin.cfg` in the output filename (`1.4.0` above). The complete
`orca-package` download alone is sufficient for installation; the helper bundle is
only needed when preparing your own local addon folder/package.

The local packager reads current addon bytes, including uncommitted changes. It
does not read `HEAD`, and refuses existing output files. If only Linux is needed
for a local-only experiment, omit `--require-platform-helpers`; that does not
establish cross-platform distribution readiness. Rebuild/retest helpers when the
native source changes. Do not mix artifacts from different source revisions.

For GitHub Release preparation, bump/version/review the source, commit and push
the intended stable tag, then select **Actions → Prepare Orca release**, enter that
existing tag and leave **Publish** off for package-only preparation. The workflow
rebuilds/tests all four helpers from the tag, collects them and runs updater/package
checks before producing **orca-release**. Its ZIP is named `orca-v1.4.0.zip` for
tag `v1.4.0`. Download it and attach the ZIP/checksum manually to Releases, or select
the workflow's explicit Publish option when ready. Publication uses the built-in
GitHub token with `contents: write` only in the publish job.

### Commit-based Godot Asset Library releases

An Asset Library entry using **GitHub + Download Commit** downloads the chosen
repository snapshot. It does not automatically use an uploaded GitHub Release ZIP
or Actions artifact. The chosen commit therefore needs the tested binaries, and
also its matching installed manifest for updater support:

1. Bump the intended version and push the release-candidate source to a branch.
2. Run native builds/tests and accept the complete downloaded plugin on supported
   platforms. Download the helper bundle from that candidate's source revision.
3. Extract it into the matching local source, then run:

   ```bash
   python3 scripts/package_release.py --version 1.4.0 --require-platform-helpers --write-manifest --output dist/orca-v1.4.0.zip
   ```

   `--write-manifest` explicitly writes the same generated `update_manifest.json`
   into `addons/orca/` for review/commit. Ordinary packaging writes it only inside
   the ZIP. The manifest excludes itself and generated `.import` sidecars.
4. Review and commit the four helper files and manifest with the release source;
   preserve executable Git modes for Linux/macOS. Freeze addon bytes after
   generating the manifest, or regenerate it if anything changes. Push/tag that
   release commit and use it in the Asset Library submission.
5. Publish the assembled ZIP/checksum on GitHub Releases separately. Its own
   generated manifest matches its packaged bytes even if a later rebuild changes
   binary bytes. Test the actual Asset Library installation path too, including
   native executable permissions and macOS downloaded-package prompts.

`git archive ... HEAD addons/orca` now works for a complete committed snapshot only
after helpers/manifest are committed. It still excludes uncommitted files and
CI-only artifacts. Prefer the packaging script for official updater ZIPs; the
updater has a narrow archive-format contract that generic ZIP tools may not meet.
GitHub's automatically offered **Source code (zip/tar.gz)** assets are snapshots,
not the assembled updater release asset.

Standard CI needs no private signing setup. Developer ID signing/notarization for
Mac distribution would require a separate owner Apple Developer identity and
workflow secret setup; this workflow makes no notarization claim. All four native
runner build/acceptance jobs passed in Tests run #42. Complete CI success and
downloaded-package/Asset Library acceptance remain required.

## Bounds and recovery

- Release JSON: 128 KiB; at most 32 assets. Versions are numeric stable triples.
- Download: at most 32 MiB, a 120-second request deadline, and four bounded requests
  including redirects. Metadata never redirects. Downloads may use only the exact
  official asset URL and HTTPS `release-assets.githubusercontent.com` destinations.
  No provider/account/GitHub credentials are attached.
- ZIP: at most 2,049 entries, 8 MiB per file, 128 MiB aggregate content plus a
  512 KiB manifest. Central and local headers, file spans, declared sizes, unique
  case-folded paths and regular-file attributes are checked before decompression.
  ZIP64, encryption, comments, directory entries, symlinks, traversal, overlapping
  data and unsupported formats are rejected. Per-file hashes and plugin metadata
  are then verified. This is a deliberately narrow packaging format.
- Installed, staged and rollback copies must match their retained manifest hashes
  and complete file sets. Known generated `.import` sidecars are bounded separately.
  Added/changed files or directories block replacement or rollback.
- `res://.orca-update/` contains isolated staging, a download, the previous addon,
  trusted copied installer scripts and bounded ownership/transaction/result records.
  Its `.gdignore` prevents editor import, Git ignores it, and agent tools and script
  references cannot access it. An atomic project-scoped lock serializes preparation
  and installation across cooperating editor instances. Stale recognized locks can
  be reclaimed; unrecognized contents are preserved.
- Validation/extraction uses a bounded background thread. Download cancellation
  resolves waiting continuations and preserves the installed addon. After handoff,
  the independent installer owns completion and rollback.
- The installer waits at most 60 seconds for editor exit. On Unix, Godot's process
  API cannot inspect a parent, so a fixed `/bin/kill -0 <retained-pid>` probe is used.
  Reopening uses a fixed `/bin/sh` `exec` program with separate quoted positional
  arguments to detach closed installer pipes. No model-provided commands or shell
  payloads are accepted. Windows uses Godot's native process APIs.
- Handoff preserves the initiating editor's actual headless display backend using
  `DisplayServer.get_name()`. Godot removes `--headless` from its exposed arguments;
  relaunch does not infer display availability from those arguments.

For an interrupted replacement, **Settings → General Settings → Restore previous addon &
restart** restores only the exact unchanged retained original. The updater retains
a transaction record before moving directories, including when the addon is
temporarily absent. If the plugin cannot load after an interruption, close editors
of this project and invoke the retained trusted recovery launcher:

```bash
"$GODOT_BIN" --headless --path "/absolute/project/.orca-update/runner" --script "/absolute/project/.orca-update/runner/update_runner.gd" -- --recover "/absolute/project"
```

Use the same Godot binary and actual project path. The launcher validates workspace
ownership, the transaction, current files and backup hashes, restores the original,
and reopens the editor. Unknown or independently modified files are preserved for
manual recovery. A successfully prepared later update retires an unchanged older
rollback copy, keeping one previous version rather than an unbounded archive.

## Verification and remaining acceptance

Set `GODOT_BIN` to Godot 4.7.2 and suppress ordinary test startup checks:

```bash
export ORCA_DISABLE_ACCOUNT_RESTORE=1 ORCA_DISABLE_UPDATE_CHECKS=1
"$GODOT_BIN" --headless --editor --path . --quit
"$GODOT_BIN" --headless --path . --script res://tests/update_service_test.gd
"$GODOT_BIN" --headless --editor --path . --script res://tests/update_editor_test.gd
python3 -m unittest discover -s tests -p update_package_test.py -v
```

The Python suite builds synthetic and actual-source release packages and invokes
Godot against disposable projects. It covers ZIP/header/path/size/checksum rejection,
modified installations, stale hashes, interrupted replacement, rollback, project
locking, failed/cancelled real HTTP downloads and an actual independent
wait/replace/reopen round trip. It makes no live inference, payment or owner-vault
request. Fixture processes run without inherited X11/Wayland display variables,
and the reopened plugin reports its headless backend to catch graphical relaunch
regressions even on a developer desktop. Editor checks include shared updater
ownership, confirmation, active-work and dirty-source denial, dismissal, progress
and narrow layouts.

Linux/Godot 4.7.2 headless acceptance is verified. Real GitHub release publication,
graphical update/relaunch with a user's full project, other running editors,
macOS/Windows locks/permissions/processes, and deliberate OS termination at every
transaction boundary remain manual gates. Other resource-editor dirty state is not
enumerated by a general public Godot API; save all editor work before confirming.
The updater has no cross-project install, silent install, beta channel, delta patch,
server-side update execution or independent release-signing infrastructure.
