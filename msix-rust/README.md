# Brave Portable MSIX (Rust)

This folder implements a **separate** Rust launcher packaged together with Brave in an MSIX. The existing root PowerShell registry-capture launcher and portapps mode are unchanged.

## How it works

Windows provides the supported registry and AppData virtualization for a full-trust packaged classic desktop application. This project does NOT replace or delete the installed Brave registry, inject DLLs, or use registry API hooks. The packaged launcher starts the bundled Brave executable with a dedicated profile and cache in local app data.

The registry state belongs to the **installed package identity** (Windows-managed private HKCU hive), not a .reg file in a portable folder.

## Build on Windows 10/11 x64

Install Rust with the x64 MSVC toolchain, Visual Studio C++ build tools, and the Windows SDK containing MakeAppx and SignTool. Download a Brave x64 archive with the parent repository updater so that ../app contains exactly one brave.exe.

Run in PowerShell:

    cd msix-rust
    rustup target add x86_64-pc-windows-msvc
    .\build-msix.ps1 -BraveDir ..\app -Publisher 'CN=Your Signing Certificate Subject' -Version 1.0.0.0 -PfxPath C:\certs\mycert.pfx

The certificate subject must match the MSIX manifest publisher. If -PfxPath is omitted, an unsigned package is created for inspection and **cannot be installed** until signed. Output is under out/. Use Add-AppxPackage to install a trusted, signed MSIX and launch it from the Start menu. Increment the four-part package version on each update; keep the identity stable to preserve package state.

## Technical limits

- This is **not USB-folder portable**. MSIX requires Windows registration, installation, and code signing. Files in the MSIX package are read-only.
- MSIX virtualization covers supported HKCU registry operations and certain AppData operations. It does **not** provide general OS-level isolation. Full-trust code may still write to other system/user locations.
- Group-policy behavior depends on Windows policy enforcement and packaging; this project does not override machine policy or guarantee all policy interactions are virtualized.
- Windows 10 1903+ may allow modifications to pre-existing AppData files to reach the unvirtualized file; the dedicated profile reduces this risk.
- This version does **not** migrate older Data/registry backups from the classic PowerShell launcher and does not export MSIX private hives to a roaming folder.
- Full-trust child-process behavior and Brave's update/registration behavior need real Windows integration testing before production deployment.
- The generated letter-B tile logos are placeholders. The installer uses the supplied Brave build; no Brave binary is bundled in Git.

## Files

- Cargo.toml / src/main.rs: Rust launcher
- AppxManifest.xml.in: full-trust packaged desktop app manifest
- build-msix.ps1: compile, stage Brave, generate PNG tiles, pack MSIX, optionally sign

References:
https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes
https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization
https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations
