@echo off
REM Ensure the working directory is the same as the batch file location
cd /d "%~dp0"

REM Run the PowerShell updater script
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "download_brave.ps1"

REM Check if Brave was downloaded successfully
IF EXIST "brave-portable.exe" (
    START "" "brave-portable.exe"
)

EXIT
