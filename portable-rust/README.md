# Brave Portable — standalone Rust launcher

This is the installation-free Rust implementation, separate from `msix-rust/` and from the legacy PowerShell launcher.

## Run

Build on Windows using the Rust MSVC toolchain:

```powershell
cargo build --release --manifest-path portable-rust/Cargo.toml --target x86_64-pc-windows-msvc
```

**The GitHub Actions artifact contains the launcher only, not Brave.** Extract/download the Brave x64 ZIP with the repository updater, then place `BravePortable.exe` next to `App/` containing the extracted Brave binaries. Do not run the EXE directly from a download folder or `target/release` unless `App/` is also there. Run without MSIX, registration, administrative rights, or code signing.

```text
BravePortable.exe
App/                 # exactly one brave.exe within this directory
Data/
  Profile/
  Cache/
  AppData/
```

The launcher forwards arguments and relocates the profile, disk cache and child environment paths inside `Data/`. Everything it directly creates is relative to its executable. If launch fails, a Windows message box now displays the error and details are appended to `Data/Logs/launcher.log`. Successful browser launches are logged too. If Brave itself immediately exits or redirects to another existing browser instance, inspect that log and close any existing Brave processes.

## Registry limitations — important

**This release does not virtualize the registry or group policy.** It deliberately does not export, delete, import, or mutate the system Brave registry or policy branches. Chrome/Brave can still perform Windows integration writes through operating-system APIs. `APPDATA` and `LOCALAPPDATA` environment redirection is not a security boundary.

A future registry virtualization mode must intercept relevant registry APIs across all browser processes, provide an isolated persistent namespace, and fail closed if the isolation is unavailable. Merely configuring `RegOverridePredefKey` in the parent launcher does not cover spawned Chromium subprocesses. The legacy PowerShell launcher still provides registry snapshot capture, with its documented risks.

## Compatibility

Windows 10/11 x64, Rust MSVC release build. Do not use this launcher if complete registry isolation is a requirement until a genuine tested virtualization backend exists.
