🦁 Brave-Portable-Updater

A PowerShell-based utility to download and extract the latest Brave Portable edition for Windows.


⚙️ Overview

- download_brave.ps1: Primary logic script for edition targeting, version checking, and downloading.
- update.bat: Auxiliary launcher to bypass certificate checks for simpler execution.


🚀 Usage

Run the script in the same directory as brave-portable.
Default (Nightly edition):
.\download_brave.ps1


Target specific editions:
- Beta:
.\download_brave.ps1 -Edition beta
- Stable:
.\download_brave.ps1 -Edition stable


✅ The script automatically checks for existing versions and skips downloading if already present.

🔁 Autorun at Boot

To run on startup, modify your startup script to reference download_brave.ps1. If the updater is located in the same directory, it will auto-locate it.

🪟 Compatibility

This tool is designed for Windows OS and targets the brave-portable environment. Support for .py and .js is now deprecated as of 2025.
