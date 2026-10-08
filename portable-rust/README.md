# Brave Portable — standalone Rust launcher

This is the installation-free Rust implementation, separate from the legacy PowerShell launcher. The MSIX experiment has been removed.

## Run

Build on Windows using the Rust MSVC toolchain:

```powershell
cargo build --release --manifest-path portable-rust/Cargo.toml --target x86_64-pc-windows-msvc
```

The GitHub Actions artifact contains the Rust launcher. **On first launch, if `App/` has no valid Brave installation, it automatically downloads the latest Stable Windows x64 ZIP from Brave's official GitHub releases, requires GitHub's SHA-256 digest, verifies the archive, safely extracts it to a staging folder and installs it to `App/`.** There is no need to run the PowerShell updater first. If Brave is already installed, the launcher starts without requiring an internet connection.

The executable can be placed in an empty writable folder; it creates the required subdirectories. No MSIX, installation, or administrator privileges are needed.

Supported launcher arguments:

```powershell
.\BravePortable.exe                       # install Stable if missing, then launch
.\BravePortable.exe --edition beta         # select Beta for first-time installation
.\BravePortable.exe --edition nightly      # select Nightly for first-time installation
.\BravePortable.exe --update               # download selected channel again and replace App/
.\BravePortable.exe --no-download          # offline-only; error if App/ is missing
.\BravePortable.exe -- --incognito          # forward browser arguments
```

`--edition` chooses which release to download but does not replace an existing installation unless `--update` is also supplied. Close all Brave instances before `--update`; the updater rejects a detected Brave process. Windows process detection still needs integration testing.

```text
BravePortable.exe
App/                 # exactly one brave.exe within this directory
Data/
  Profile/
  Cache/
  AppData/
```

The launcher forwards arguments and relocates the profile, disk cache and child environment paths inside `Data/`. Everything it directly creates is relative to its executable. Download and installation diagnostics, launch status, and errors are recorded in `Data/Logs/launcher.log`. If launch fails, a Windows message box displays the error and details are appended to `Data/Logs/launcher.log`. Successful browser launches are logged too. If Brave itself immediately exits or redirects to another existing browser instance, inspect that log and close any existing Brave processes. If an update was interrupted after moving App, the Rust updater can restore exactly one valid `.app-backup-*` folder when App is missing; multiple backups require manual selection.


## JSON settings and scheduling

On first run, the launcher creates `Data/settings.json` beside the EXE:

```json
{
  "edition": "stable",
  "update_frequency": "daily",
  "check_on_launch": true,
  "scheduled_updates": false,
  "registry_virtualization": "off"
}
```

- `edition`: `stable`, `beta`, or `nightly`. A different channel is downloaded on the next due check; existing profiles remain in `Data/Profile`.
- `update_frequency`: `never`, `launch`, `daily`, or `weekly`. The launcher remembers the last successful GitHub release check in `Data/last-update-check`; `daily` and `weekly` are minimum intervals, not background timers.
- `check_on_launch`: whether ordinary launches perform due update checks. It does not disable first-time installation if Brave is missing.
- `scheduled_updates`: opt-in to an external Windows Task Scheduler task.
- `registry_virtualization`: `off` (profile-only), `swap` (temporary PowerShell-style HKCU Brave and policy capture), or `required` (refuses launch until full virtualization is implemented). `swap` is **not virtualization**: it alters live Windows registry keys during a session.

To register/update the scheduler after placing `setup-scheduler.ps1` beside the EXE:

```powershell
.\setup-scheduler.ps1
.\setup-scheduler.ps1 -Remove
```

The scheduler runs `BravePortable.exe --update-only`, without opening a browser. The scheduler script requires no elevation in normal per-user configurations but Windows policy may limit registration. Change the frequency in JSON and **rerun setup-scheduler.ps1** to update the task. The current scheduler runs daily or weekly at 12:00 local time when the user is signed in. `launch` and `never` install no task. The JSON does not automatically register a task by itself.

Other supported flags: `--update`, `--force` / `-Force`, `--edition stable|beta|nightly` / `-Edition`, `--no-download`, `--update-only`, and `--` for browser arguments. Rust now also recognizes `-NoRegistry` / `--no-registry`, `-NoPolicy` / `--no-policy`, and `-NoWait` / `--no-wait`. `-NoRegistry` and `-NoPolicy` selectively disable the corresponding layer only in swap mode. `-NoWait` is refused when swap mode still manages either layer; both must be disabled. `-OutDir` remains unsupported because portable state is intentionally tied to the executable folder. The Rust launcher now supports **opt-in temporary registry/group-policy swapping**, but still does not provide virtualization. Its settings are separate from other launcher versions.

**Updates are blocked when any Brave process is running**, including unrelated installed Brave instances, to avoid replacing in-use executables. Close Brave and retry if an update fails. An interrupted update may leave `.app-backup-*` or `.app-staging-*` directories; do not delete them until you've confirmed your existing App works.

## Registry virtualization — implementation boundary

A portable Rust EXE alone does not redirect Windows registry operations of another executable. `RegOverridePredefKey` affects only its calling process, and Brave uses a multi-process architecture. A working backend must include interception/virtual namespace handling inside each Brave process, cover Win32 and native registry paths, preserve binary value types and deletion semantics, propagate to child processes, and verify isolation before launching. No such backend has been delivered in this repository; **do not infer isolation from the `Data` directory**.

## Registry limitations — important

**This release does not virtualize the registry or group policy.** With `registry_virtualization` set to `off`, the launcher does not deliberately change the registry. With `swap`, it exports the existing HKCU BraveSoftware and HKCU policy keys, replaces them with portable `.reg` snapshots, launches Brave, captures the changed portable state, and restores the original keys on exit. This modifies real Windows registry keys while Brave is running. `APPDATA` and `LOCALAPPDATA` environment redirection is not a security boundary.

A future registry virtualization mode must intercept relevant registry APIs across all browser processes, provide an isolated persistent namespace, and fail closed if the isolation is unavailable. Merely configuring `RegOverridePredefKey` in the parent launcher does not cover spawned Chromium subprocesses. The legacy PowerShell launcher also provides registry snapshot capture, with similar risks.

## Compatibility

Windows 10/11 x64, Rust MSVC release build. Do not use this launcher if complete registry isolation is a requirement until a genuine tested virtualization backend exists.


## Temporary registry + group-policy capture (opt-in)

Set `"registry_virtualization": "swap"` in `Data/settings.json` to enable the placeholder capture mode. Use `"off"` for the normal Rust profile-only mode, or `"required"` to refuse launching unless actual virtualization exists.

In swap mode, the Rust launcher:
1. Refuses startup while **any Brave process** is detected and obtains a named process mutex.
2. Exports existing `HKCU\Software\BraveSoftware` and `HKCU\Software\Policies\BraveSoftware\Brave` to timestamped `Data/Registry/*-host-*.reg` backups.
3. Writes `Data/Registry/active-session.json` **before** deleting/importing live keys. The session imports `portable-brave.reg` and `portable-policy.reg`, if available.
4. Launches Brave with portable profile/cache paths, waits for the original process and **all Brave processes** to exit, captures updated portable registry state, and restores the original host keys.
5. Removes the journal only after successfully restoring the host registry.

If Brave or the launcher crashes, `active-session.json` remains as a recovery warning and future swap launches refuse to proceed. **Recovery is manual**: close Brave, inspect that journal and the corresponding host snapshots, and restore only the original keys when safe. Do not delete the journal or old snapshots until recovery is complete.

This mode is **experimental and can cause data loss**. It temporarily replaces the *whole* user BraveSoftware branch and its HKCU Brave policy subtree. It does not isolate HKLM policy, native registry access, or third-party Windows integrations. The tasklist-based process check can miss races, access-denied processes or process names that differ. Unexpected termination, simultaneous regular Brave startup, or policy permissions can prevent restoration. Back up the Windows registry before trying it. It is not appropriate where other Brave instances may run concurrently. It is a placeholder until genuine registry virtualization is implemented.


## Safety fixes and remaining limitations

The updater records its last check after a successful installation or a confirmed current version, not before a failed download. It attempts recovery from one interrupted binary backup. Registry existence checks use native Win32 error codes (missing versus access denied), not locale-dependent `reg.exe` output. Waiting for all Brave processes is bounded to six hours; a timeout keeps the recovery journal and requires manual intervention.

**Registry swap is still experimental.** Windows registry errors can be localized, concurrent processes can race after the initial scan, and crashes can leave altered keys. There is no unattended automatic registry recovery and no native registry virtualization. The named session mutex does not coordinate with the separate PowerShell launcher. Avoid using both swap implementations concurrently. An accurate Windows integration test is still required.
\n\n## Additional update hardening\n\nUpdater operations now use an exclusive `Data/update.lock` file to avoid concurrent Rust binary replacement. Release-check timestamps are stored separately for Stable, Beta and Nightly. ZIP extraction has a 6 GB expanded-size cap. The scheduler setup script removes orphaned Rust update tasks whose executable paths no longer exist. Existing tasks for other working installations are preserved. The Rust registry mutex now uses the same current-user SID naming convention as the PowerShell launcher.\n\nThe six-hour process wait limit is a **recovery boundary, not automatic safe restoration**: if Brave is still open, host-registry restoration cannot safely proceed and manual recovery is required. The implementation has not been verified end-to-end on Windows.\n

## Recover an interrupted registry-swap session

The launcher now blocks **every normal launch**, including profile-only launches and update-only operations, while `Data/Registry/active-session.json` exists. This prevents silently running against an unresolved temporary registry state.

After closing **all** Brave processes, inspect `Data/Registry/active-session.json` and its named `*-host-*.reg` backups. If these are the correct original Windows registry backups, explicitly invoke:

```powershell
.\BravePortable.exe --recover-registry
```

The command takes a cross-launcher mutex, refuses to run if Brave is detected, validates that expected backup files exist, then restores the saved HKCU Brave and Brave user-policy keys. On failure, it preserves the recovery journal for another attempt. **It changes the real registry and is not safe if unrelated changes occurred since the backup**; inspect or export the current keys first if that is possible. This is deliberate manual recovery, not an automatic or crash-proof transaction.
