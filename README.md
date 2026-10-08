# Brave Portable Updater

Run **Brave Stable, Beta or Nightly** from a movable Windows folder. This repository includes two standalone launchers plus an updater for existing portapps wrappers. **Neither launcher implements true registry virtualization.**

## Choose a launcher

| Feature | Rust — `portable-rust/` | PowerShell — repository root | `portapps/` |
| --- | --- | --- | --- |
| Runs from a movable folder | Yes | Yes | Uses existing portapps wrapper |
| Downloads Brave | Automatically if missing | Run `download_brave.ps1` | Run its updater |
| Browser data stored locally | `Data/Profile`, `Data/Cache`, `Data/AppData` | `Data/profile`, `Data/cache`, `Data/AppData` | Managed by wrapper |
| Channel selection | JSON and `--edition` | Updater `-Edition` | Updater `-Edition` |
| Update checks | JSON frequency + optional scheduler | Manual updater + logon task | Manual updater + logon task |
| Registry and user policy capture | **Optional, experimental** `swap` mode | **Enabled by default** | Wrapper-dependent |
| True Windows registry virtualization | **No** | **No** | Not provided by this project |

The MSIX experiment was removed because MSIX registration and installation conflict with folder portability.

## Rust launcher — recommended for profile-only portability

See **[portable-rust/README.md](portable-rust/README.md)** for full instructions and limitations.

Download the built launcher from [Build Portable Rust Launcher](https://github.com/Chaython/Brave-Portable-Updater/actions/workflows/build-portable-rust.yml), extract `BravePortable.exe` together with the bundled `setup-scheduler.ps1`, and launch the executable from a **writable folder**. If `App/` is missing, it downloads the selected Brave Windows x64 ZIP from official GitHub releases, checks the SHA-256 digest, and installs to `App/`. An existing installation can run offline.

```text
BravePortable/
├── BravePortable.exe
├── setup-scheduler.ps1
├── App/                     # Brave binaries; downloaded if absent
└── Data/
    ├── Profile/
    ├── Cache/
    ├── AppData/
    ├── Logs/launcher.log
    ├── Registry/            # only populated by registry swap mode
    └── settings.json
```

### Rust commands

```powershell
.\BravePortable.exe
.\BravePortable.exe --edition stable
.\BravePortable.exe --edition beta
.\BravePortable.exe --edition nightly
.\BravePortable.exe --update
.\BravePortable.exe --update-only
.\BravePortable.exe --no-download
.\BravePortable.exe -- --incognito
```

`--force` / `-Force` and `-Edition` are also recognized. Unlike the original PowerShell launcher, Rust currently does **not** support `-OutDir`, `-NoRegistry`, `-NoPolicy`, or `-NoWait`. Rust launcher settings do not automatically configure the other launchers.

### Rust JSON settings and scheduled updates

First launch creates `Data/settings.json`:

```json
{
  "edition": "stable",
  "update_frequency": "daily",
  "check_on_launch": true,
  "scheduled_updates": false,
  "registry_virtualization": "off"
}
```

- `edition`: `stable`, `beta`, or `nightly`.
- `update_frequency`: `never`, `launch`, `daily`, or `weekly`. Daily/weekly are minimum intervals between launch-time release checks.
- `check_on_launch`: enable/disable due checks when launching normally. Initial download is still needed if Brave is absent.
- `scheduled_updates`: opt into Windows Task Scheduler; setting this alone does **not** register a task.
- `registry_virtualization`: `off` (profile isolation only), `swap` (risky temporary registry/policy capture), or `required` (refuse launch because true virtualization is not available).

To register a **per-user** scheduler after setting `scheduled_updates` to `true`, place `setup-scheduler.ps1` beside the EXE and run:

```powershell
.\setup-scheduler.ps1
.\setup-scheduler.ps1 -Remove
```

Re-run setup after changing frequency or moving the folder. The task executes `BravePortable.exe --update-only`; it checks for updates without opening a browser and runs when the user is signed in. Daily/weekly tasks currently trigger at 12:00 local time. For `launch` and `never`, no task is installed.

### Rust registry / group-policy **swap** (experimental)

To capture portable HKCU Brave settings between sessions, set:

```json
{ "registry_virtualization": "swap" }
```

This is a **setting excerpt**, not a replacement for the entire settings file. The Rust launcher then:

1. Refuses to start while another Brave process is detected and obtains a cross-session named lock.
2. Exports the current `HKCU\Software\BraveSoftware` and `HKCU\Software\Policies\BraveSoftware\Brave` keys to pre-session backups in `Data/Registry/`.
3. Records `Data/Registry/active-session.json` before changing live keys.
4. Temporarily replaces those keys with `portable-brave.reg` and `portable-policy.reg`, applies portable user policies, and launches Brave.
5. After Brave exits, captures the portable changes and attempts to restore the original host keys.

**Warning:** The keys are modified in the **real Windows registry** during the browser session. This is not a sandbox and not virtualization. If the program or OS crashes, the original keys might not be restored. An unfinished journal blocks subsequent swap sessions. Recovery is **manual**; preserve `active-session.json` and host backups and inspect the machine's registry before recovering. Registry changes by another Brave instance during the swap can be overwritten. Group-policy handling covers the HKCU Brave policy subtree only; HKLM or enforced machine policies are not virtualized. Back up your registry and close installed Brave before trying this experimental mode. It has **not been validated by a complete Windows integration test**.

Use `"registry_virtualization": "off"` for the safer default, or `"required"` to refuse launch until true virtualization is implemented.

## PowerShell updater and launcher

```powershell
.\download_brave.ps1                    # nightly (default)
.\download_brave.ps1 -Edition stable
.\download_brave.ps1 -Edition beta -Force

.\brave-portable.ps1
.\brave-portable.ps1 --incognito
.\brave-portable.ps1 https://example.com
.\brave-portable.ps1 -NoWait -NoRegistry -NoPolicy
```

Batch wrappers are available: `update.bat stable` and `update_then_run_portable.bat stable`.

The updater stages and verifies downloaded files, refuses to overwrite running portable Brave binaries, and maintains a backup during replacement. Inspect orphaned `.app-backup-*` folders before deleting them.

**PowerShell registry behavior:** The standalone launcher captures HKCU Brave and user policy state by default, temporarily removes/imports those live keys, saves portable snapshots under `Data/registry`, and tries to restore the host state on browser exit. Pre-session copies are retained. `-NoRegistry` and `-NoPolicy` disable the corresponding swapping; `-NoWait` requires both. As with Rust's optional `swap` mode, crashes and incomplete restoration are significant risks.

### PowerShell scheduled updates

```powershell
.\run_at_boot.ps1 -Edition stable
.\run_at_boot.ps1 -Remove
```

Despite the script's historical name, it registers a **logon** task, not a boot-time SYSTEM task. Output goes to `brave-update.log`. This is separate from Rust's JSON-configured scheduler.

## Requirements, compatibility, and safety

- **Rust:** Windows 10/11 x64. Rust MSVC and Windows build tools are needed to compile, not to run the compiled EXE. No MSIX install or administrator privileges needed for ordinary launching.
- **PowerShell:** Windows PowerShell 5.1+; downloaded Brave is x64.
- Both modes need sufficient disk space for the ZIP, staging and previous binary backups; downloads need access to GitHub.
- The folder should remain writable. Move the **whole folder**, including `Data/`, to preserve browser settings.
- Neither mode guarantees that Brave or Windows will avoid all host integration writes. Redirecting `APPDATA`/`LOCALAPPDATA` is not complete filesystem isolation.
- Do not launch or update multiple Brave instances during registry swap. Updates and recovery require real-Windows verification. The Rust swap feature is an **experimental placeholder**, not a secure virtualization backend.

## portapps integration

The `portapps/` scripts update the Brave installation used by an existing portapps.io wrapper; see [portapps/README.md](portapps/README.md). Their registry behavior belongs to that wrapper, not to the Rust or root PowerShell launchers.
