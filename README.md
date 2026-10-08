# Brave Portable Updater

Update and launch Brave Stable, Beta, or Nightly without affecting unrelated Brave processes.

## Modes

- **Root / standalone:** `download_brave.ps1` downloads the browser and `brave-portable.ps1` launches it using `Data/profile`, `Data/cache`, and redirected APPDATA/LOCALAPPDATA.
- **portapps/**: Updater scripts for an existing portapps.io `brave-portable.exe` wrapper. The wrapper handles its own portability.

**Important:** The standalone launcher no longer swaps, deletes, exports, or imports the Windows Brave registry, and does not inject group policies. This removes a class of registry corruption and crash-recovery hazards. It is profile isolation, **not a full Windows sandbox**: Brave or Windows may still write other OS-level integration data. Avoid making portable Brave your default browser if you want to minimize this.

Older `Data/registry/*.reg` files from previous versions are left untouched for manual recovery. Back them up before removing them. `-NoRegistry` and `-NoPolicy` are still accepted for compatibility, but registry and policy mutation are now always disabled.

## Update

```powershell
.\download_brave.ps1                    # Nightly, the default
.\download_brave.ps1 -Edition stable
.\download_brave.ps1 -Edition beta -Force
```

```bat
update.bat stable
update_then_run_portable.bat stable
```

Downloaded archives are extracted into a staging folder and validated before switching `app/`. Existing installations are moved to a backup directory during replacement. The updater **never kills Brave**; close portable Brave before updating. Any older `.app-backup-*` directories should be reviewed before deletion. The updater uses channel-aware version markers and can page through GitHub releases.

## Launch (standalone)

```powershell
.\brave-portable.ps1
.\brave-portable.ps1 --incognito
.\brave-portable.ps1 https://example.com
.\brave-portable.ps1 -NoWait
```

The launcher waits for the browser and its visible portable `brave.exe` child processes unless `-NoWait` is used. It rejects custom `--user-data-dir` and `--disk-cache-dir` overrides.

## Scheduled update

```powershell
.\run_at_boot.ps1 -Edition stable
.\run_at_boot.ps1 -Remove
```

Despite the historical filename, this creates a **logon-triggered** Windows scheduled task under the current interactive user, not a boot-time SYSTEM task. Output is appended to `brave-update.log`.

## Requirements and limitations

Windows PowerShell 5.1+ on Windows x64, an internet connection to GitHub releases, and enough free disk space for both staged and old Brave binaries. Registry isolation is deliberately not provided by the standalone launcher. A Windows integration test is recommended before relying on unattended updates.
