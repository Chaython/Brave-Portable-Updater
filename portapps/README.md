# portapps/ — drop-in for an existing portapps.io Brave Portable install

This folder is **self-contained**: it contains every script needed to update
and run a portapps.io Brave Portable installation. Copy this whole folder next
to your existing `brave-portable.exe` (the portapps.io wrapper) and use the
launchers below.

## Why a separate folder?

The parent folder runs Brave in **self-contained mode** via `brave-portable.ps1`
(our own sandbox launcher — no portapps needed). This `portapps/` folder is the
**Mode A** drop-in for people who already have the portapps.io wrapper and want
to keep using it. Keeping them separate avoids confusion about which launcher
belongs to which mode.

## Files

| File | Purpose |
| --- | --- |
| `download_brave.ps1` | Updater — accepts `-Edition`, `-OutDir`, `-Force`. |
| `update.bat` | Update only. First arg is the edition (`nightly`/`beta`/`stable`). |
| `update_then_run_brave.bat` | Update then launch via `brave-portable.exe` (the portapps wrapper). |
| `run_at_boot.ps1` | Register/remove a boot scheduled task. Accepts `-Edition` and `-Remove`. |

## Usage

```bat
update.bat                      :: update nightly
update.bat beta                 :: update beta
update_then_run_brave.bat       :: update + launch (nightly)
update_then_run_brave.bat stable:: update + launch (stable)
```

```powershell
.\run_at_boot.ps1 -Edition beta :: auto-update beta at boot
.\run_at_boot.ps1 -Remove       :: remove the boot task
```

## Note on portability

`brave-portable.exe` (the portapps.io wrapper) is what keeps Brave portable in
this mode — it redirects AppData and registry writes. These scripts do **not**
launch `brave.exe` directly, because that would break portability. If you don't
have the portapps wrapper, use the parent folder's self-contained mode instead
(`update_then_run_portable.bat` + `brave-portable.ps1`).
