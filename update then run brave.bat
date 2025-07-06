@echo off
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download_brave.ps1"

REM Check if Brave was downloaded successfully
IF EXIST "%~dp0brave-portable.exe" (
    START "" "%~dp0brave-portable.exe"
)

EXIT