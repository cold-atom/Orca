# Orca credential bridge

This independently implemented helper stores editor-session credentials in the
native OS vault: Linux Secret Service/libsecret, macOS Keychain, or Windows
Credential Manager. It is not a Godot runtime dependency for game projects.
There is no plaintext fallback or bundled encryption key.

The GDScript wrapper runs only this fixed helper, with an opaque namespace in argv.
Credentials travel through bounded private pipes, never argv/environment/files.
An OS lock serializes read/refresh/replacement across editor processes. Lock files
contain no credentials. The helper's output must never be logged.

The wrapper reaps its direct helper on close/timeout. A native 180-second watchdog
also bounds helper lifetime if the editor crashes while the vault is blocked.

## Native builds

From the repository root, on a supported native machine:

```bash
python3 scripts/build_native_helper.py
```

Use `python` on Windows. Linux needs g++/pkg-config/libsecret development headers;
Windows needs Visual Studio C++ tools/SDK; macOS needs Xcode command-line tools.
Windows uses MSVC with a static CRT and Advapi32. Its stdin/stdout are binary so
the bounded LF protocol does not become CRLF. macOS uses Security/CoreFoundation
`SecItem` APIs with the same `Orca` service/account identity as the original
generic-password records, a macOS 11 deployment target, and ad-hoc signing.

The GitHub workflow `.github/workflows/native_helpers.yml` builds **Linux x86_64,
Windows x86_64, macOS arm64 and macOS x86_64** on native runners. It runs on manual
dispatch and is reused by Tests and Prepare Orca release. Each helper must pass
real Godot/native-vault acceptance before its artifact is uploaded. Linux uses a
private D-Bus session and temporary HOME/XDG keyring; macOS uses a temporary
unlocked default/search-list Keychain and restores the original settings; Windows
uses the disposable runner user's Credential Manager with a random erased scope.
All fixtures suppress owner account restoration/update checks. No real sign-in,
provider key or account token is required by CI.

Compiled helpers are not committed or bundled into plugin ZIPs. Plugin startup
quietly prepares the missing helper for this OS/architecture, without an install
prompt or updater notice. The plugin verifies size,
SHA-256/native architecture against its packaged `native_helpers.json`, then caches
the executable at `OS.get_data_dir()/Orca/native/<sha256>/<asset>`. No restart or
account token is needed to download. Early explicit sign-in waits for verification;
background completion alone never starts browser pairing. Missing/changed/symlinked
helpers cannot execute. Cancelling sign-in leaves preparation running; disabling
the plugin cancels it. BYOK/local use is available throughout.

The aggregate artifacts are `orca-native-helpers` (a local-preparation tar.gz),
`orca-native-release-assets` (four separate raw executables) and `orca-package`
(binary-free `orca-v<version>.zip` and checksum, named from `plugin.cfg`). Publish
the raw executables alongside their matching ZIP under the same official tag;
submit only the ZIP to Godot. Download/unzip `orca-package` for installation.
For local source preparation, download the helper bundle from the matching source
commit, unzip its Actions wrapper, then extract its tar.gz at the repository root.
See the [release/Asset Library procedure](https://github.com/cold-atom/Orca/blob/main/docs/UPDATES.md#builds-and-downloads-from-github-actions).

Local isolated acceptance:

```bash
GODOT_BIN=/path/to/Godot python3 scripts/test_native_credentials.py
```

Linux additionally needs `dbus-run-session`, `gnome-keyring-daemon` and `gdbus`.
For local Mac tests, use a disposable OS user because the fixture temporarily
changes that user's default/search-list Keychain. CI runs on a disposable runner.
The fixture checks LF/bounds, read/write/delete, two-helper locking and save/restore/
rotation in separate Godot processes. Test projects and keyrings are temporary;
only random synthetic test records are accessed.

Linux's isolated cached-helper flow is verified locally. Windows/macOS CI execution and real
downloaded-plugin acceptance are still required before declaring those builds
supported. Ad-hoc signing is not Developer ID signing/notarization; Gatekeeper and
Keychain prompts on a real downloaded package remain platform acceptance checks.
Linux requires a usable Secret Service collection and libsecret runtime; OS unlock
prompts may appear. Missing/unsupported vaults fail visibly, with no plaintext fallback.
