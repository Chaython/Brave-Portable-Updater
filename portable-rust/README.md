# Brave Portable — standalone Rust launcher

This is the installation-free Rust implementation, separate from `msix-rust/` and from the legacy PowerShell launcher.

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

`--edition` chooses which release to download but does not replace an existing installation unless `--update` is also supplied. Avoid `--update` while portable Brave processes are running; this still needs explicit process-exclusion safeguards and Windows testing.

```text
BravePortable.exe
App/                 # exactly one brave.exe within this directory
Data/
  Profile/
  Cache/
  AppData/
```

The launcher forwards arguments and relocates the profile, disk cache and child environment paths inside `Data/`. Everything it directly creates is relative to its executable. Download and installation diagnostics, launch status, and errors are recorded in `Data/Logs/launcher.log`. If launch fails, a Windows message box displays the error and details are appended to `Data/Logs/launcher.log`. Successful browser launches are logged too. If Brave itself immediately exits or redirects to another existing browser instance, inspect that log and close any existing Brave processes.

## Registry limitations — important

**This release does not virtualize the registry or group policy.** It deliberately does not export, delete, import, or mutate the system Brave registry or policy branches. Chrome/Brave can still perform Windows integration writes through operating-system APIs. `APPDATA` and `LOCALAPPDATA` environment redirection is not a security boundary.

A future registry virtualization mode must intercept relevant registry APIs across all browser processes, provide an isolated persistent namespace, and fail closed if the isolation is unavailable. Merely configuring `RegOverridePredefKey` in the parent launcher does not cover spawned Chromium subprocesses. The legacy PowerShell launcher still provides registry snapshot capture, with its documented risks.

## Compatibility

Windows 10/11 x64, Rust MSVC release build. Do not use this launcher if complete registry isolation is a requirement until a genuine tested virtualization backend exists.
