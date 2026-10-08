# Brave Portable Updater

Update and launch Brave Stable, Beta, or Nightly without affecting unrelated Brave processes.

## Modes

- **Root / standalone:** `download_brave.ps1` downloads the browser and `brave-portable.ps1` launches it using `Data/profile`, `Data/cache`, and redirected APPDATA/LOCALAPPDATA.
- **portapps/**: Updater scripts for an existing portapps.io `brave-portable.exe` wrapper. The wrapper handles its own portability.

**Important:** The standalone launcher now captures HKCU Brave registry and Brave group-policy keys. It backs up any existing keys, imports the saved portable state, and restores the original state after Brave exits. This involves replacing shared registry keys temporarily; it is **not crash-proof or a full Windows sandbox**. Avoid launching concurrently with a normal Brave installation.

Portable registry state is stored under `Data/registry` (`portable.reg` and `portable-policy.reg`). Pre-session snapshots (`before.reg`, `before-policy.reg`) are kept for recovery. If `active-session.json` remains after a crash, the launcher stops rather than risking automatic destructive recovery. `-NoRegistry` and `-NoPolicy` disable each capture layer; `-NoWait` requires both to be disabled.

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
.\brave-portable.ps1 -NoWait -NoRegistry -NoPolicy
```

The launcher waits for the browser and its visible portable `brave.exe` child processes unless `-NoWait` is used. It rejects custom `--user-data-dir` and `--disk-cache-dir` overrides. **Close normal Brave before launching** to avoid simultaneous access to shared registry keys.

## Scheduled update

```powershell
.\run_at_boot.ps1 -Edition stable
.\run_at_boot.ps1 -Remove
```

Despite the historical filename, this creates a **logon-triggered** Windows scheduled task under the current interactive user, not a boot-time SYSTEM task. Output is appended to `brave-update.log`.

## Requirements and limitations

Windows PowerShell 5.1+ on Windows x64, an internet connection to GitHub releases, and enough free disk space for both staged and old Brave binaries. Registry/group-policy capture is enabled by default in the standalone launcher. Windows integration tests and crash-recovery validation remain necessary, especially when policy keys are ACL-protected. Back up `Data/registry` before first use.


## Rust/MSIX alternative

A separate packaged-desktop implementation is available under [`msix-rust/`](msix-rust/README.md). It bundles Brave and a Rust launcher in an MSIX so Windows handles supported HKCU registry virtualization instead of the root launcher's export/import swap. It is installed/signed, not USB-folder portable. See its README for build prerequisites and limitations.


## Standalone Rust launcher (no installation)

See [`portable-rust/`](portable-rust/README.md) for a movable `BravePortable.exe` with profile, cache and AppData redirection and a Windows build workflow. **Registry/group-policy virtualization is not implemented in the standalone Rust launcher yet**; it does not replace the registry-capture PowerShell version. MSIX remains a separate packaging experiment.
