# Brave-Portable-Updater
Script to download and extract the newest brave package to be run in the dir of https://github.com/portapps/brave-portable


2025: You can now target an edition by editing the default in the file or by running with the command of the edition you want.

For Nightly (default):
.\download_brave.ps1

For Beta:
.\download_brave.ps1 -Edition beta

For Stable:
.\download_brave.ps1 -Edition stable

It should now also check if the version is in place and skip downloading if it is.

If you want to run at boot edit the script to point towards the download_brave.ps1. [if its in the same directory as download_brave.ps1 it should now find it automatically however.] 

This is currently configured for Windows, as brave-portable is for Windows. Therefore I am now deprecating .py and .js
