# Brave-Portable-Updater

A PowerShell-based utility to download and extract the latest Brave Portable edition for Windows — with two portable modes, registry management, and group-policy hijacking.

---

## Two modes, two folders

| Mode | Folder | When to use | How it stays portable |
| --- | --- | --- | --- |
| **A — portapps drop-in** | `portapps/` | You already have a portapps.io Brave Portable install with `brave-portable.exe`. | The portapps wrapper redirects AppData/registry. |
| **B — self-contained** | repository root | No portapps wrapper. Just these scripts. | `brave-portable.ps1` redirects env vars, registry, and injects group policies. |

Both folders are **self-contained** — each has its own copy of `download_brave.ps1`, `update.bat`, and `run_at_boot.ps1`, so you can use either one on its own.

### Mode A — portapps/ (drop-in)

Copy the `portapps/` folder next to your existing `brave-portable.exe`:

```bat
portapps\update.bat beta                 :: update beta
portapps\update_then_run_brave.bat       :: update + launch (nightly)
portapps\update_then_run_brave.bat stable:: update + launch (stable)
```

### Mode B — self-contained (root)

```bat
update.bat beta                          :: update beta
update_then_run_portable.bat             :: update + launch (nightly)
update_then_run_portable.bat stable      :: update + launch (stable)
```

Launch directly without updating:

```powershell
.\brave-portable.ps1                     :: portable launch
.\brave-portable.ps1 --incognito         :: portable + incognito
.\brave-portable.ps1 https://example.com :: portable + open URL
```

---

## How the self-contained launcher keeps Brave portable

`brave-portable.ps1` uses **four layers** of redirection so Brave never writes to your real user profile or leaves registry keys behind:

### Layer 1 — Environment variables
`APPDATA` and `LOCALAPPDATA` are redirected to `Data\AppData\Roaming` and `Data\AppData\Local`. Brave and every child process it spawns inherit these, so support files land in `Data\`.

### Layer 2 — Command-line flags
`--user-data-dir=Data\profile`, `--disk-cache-dir=Data\cache`, `--no-default-browser-check`, `--disable-background-mode`.

### Layer 3 — Group policy hijacking
Brave (like Chromium) reads policies from `HKCU\Software\Policies\BraveSoftware\Brave`. We inject these before launch and remove them after exit:

| Policy | Value | Effect |
| --- | --- | --- |
| `UserDataDir` | `Data\profile` | Forces the profile directory even for helper processes. |
| `DiskCacheDir` | `Data\cache` | Forces the cache directory. |
| `BackgroundModeEnabled` | `0` | No background process after the window closes. |
| `DefaultBrowserSettingEnabled` | `0` | Never tries to register as default browser. |
| `SyncDisabled` | `1` | No account sync — keeps data local. |

### Layer 4 — Registry backup / restore / cleanup
Brave writes to `HKCU\Software\BraveSoftware\*` (window placement, metrics, version beacon…). To keep that state portable **and** not clobber a real Brave install:

**On launch:**
1. *(once)* If a real Brave install's registry exists, back it up to `Data\registry\real-install-backup.reg` as a safety copy.
2. Snapshot the current live `HKCU\Software\BraveSoftware` → `pre-session.reg`.
3. Delete the live key (clean slate).
4. Import `Data\registry\brave-portable.reg` (portable state from last session, if any).

**After Brave exits:**
5. Export the live `HKCU\Software\BraveSoftware` → `brave-portable.reg` (persist this session).
6. Delete the live key.
7. Delete the injected policy keys.
8. Clean up stray default-browser / app-paths keys Brave may have created.
9. Re-import `pre-session.reg` (restoring the pre-launch state — real install, or nothing).

**Net result:** while Brave runs it sees its own portable registry; after it closes, the live registry is exactly as it was before.

> The script **waits for Brave to exit** so cleanup can run. Use `-NoWait` to fire-and-forget (cleanup is skipped, with a warning). Use `-NoRegistry` or `-NoPolicy` to disable individual layers.

---

## File reference

### Root (self-contained mode)

| File | Purpose |
| --- | --- |
| `download_brave.ps1` | Updater — edition targeting, version checking, downloading. Accepts `-Edition`, `-OutDir`, `-Force`. |
| `brave-portable.ps1` | Portable sandbox launcher — env + flags + group policy + registry management. Accepts `-NoRegistry`, `-NoPolicy`, `-NoWait`. |
| `update.bat` | Update only. First arg is the edition. |
| `update_then_run_portable.bat` | Update + launch via `brave-portable.ps1`. |
| `run_at_boot.ps1` | Register/remove a boot scheduled task. Accepts `-Edition` and `-Remove`. |

### portapps/ (Mode A drop-in)

| File | Purpose |
| --- | --- |
| `download_brave.ps1` | Updater (copy of root). |
| `update.bat` | Update only (copy of root). |
| `update_then_run_brave.bat` | Update + launch via `brave-portable.exe` (portapps wrapper). |
| `run_at_boot.ps1` | Boot task (copy of root). |

> All launchers forward the edition to `download_brave.ps1`. You no longer have to edit the default inside the script to use beta or stable.

---

## Folder layout (self-contained mode)

```
Brave-Portable-Updater/
├── download_brave.ps1
├── brave-portable.ps1
├── update.bat
├── update_then_run_portable.bat
├── run_at_boot.ps1
├── portapps/                         <- Mode A drop-in (self-contained)
│   ├── download_brave.ps1
│   ├── update.bat
│   ├── update_then_run_brave.bat
│   ├── run_at_boot.ps1
│   └── README.md
├── app/                              <- created by download_brave.ps1
│   └── brave-vX.Y.Z-win32-x64/
│       └── brave.exe
└── Data/                             <- created by brave-portable.ps1
    ├── profile/                      <- user data dir
    ├── cache/                        <- disk cache
    ├── AppData/
    │   ├── Roaming/                  <- redirected %APPDATA%
    │   └── Local/                    <- redirected %LOCALAPPDATA%
    └── registry/
        ├── brave-portable.reg        <- portable registry state (per-session)
        ├── real-install-backup.reg   <- one-time safety backup of a real install
        └── pre-session.reg           <- temp (deleted after restore)
```

---

## Usage

### Default (Nightly edition)

```powershell
.\download_brave.ps1
```

### Target a specific edition

```powershell
.\download_brave.ps1 -Edition beta
.\download_brave.ps1 -Edition stable
```

### Force a re-download

```powershell
.\download_brave.ps1 -Edition stable -Force
```

### Autorun at Boot

```powershell
.\run_at_boot.ps1                 :: nightly
.\run_at_boot.ps1 -Edition beta
.\run_at_boot.ps1 -Edition stable
.\run_at_boot.ps1 -Remove         :: uninstall the task
```

Task output is appended to `brave-update.log` next to the script.

---

## Compatibility

Designed for Windows OS. Requires PowerShell 5.1+ (PowerShell 7+ also works). `reg.exe` (standard Windows binary) is used for registry export/import.
