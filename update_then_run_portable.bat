@echo off
REM ============================================================
REM  update_then_run_portable.bat
REM  Updates Brave, then launches it via brave-portable.ps1 -- our
REM  OWN portable sandbox launcher. No portapps.io wrapper needed.
REM
REM  brave-portable.ps1 keeps Brave portable by redirecting
REM  --user-data-dir, --disk-cache-dir, and the APPDATA /
REM  LOCALAPPDATA environment variables into a "Data" folder next
REM  to these scripts, so Brave never writes to your real AppData
REM  or user profile.
REM
REM  Use this instead of update_then_run_brave.bat when you do NOT
REM  have the portapps.io brave-portable.exe wrapper.
REM
REM  Usage:
REM    update_then_run_portable.bat              :: nightly (default)
REM    update_then_run_portable.bat nightly
REM    update_then_run_portable.bat beta
REM    update_then_run_portable.bat stable
REM ============================================================

cd /d "%~dp0"

set "EDITION_ARGS="
if not "%~1"=="" (
    set "EDITION_ARGS=-Edition %~1"
    shift
)

REM Run the PowerShell updater script
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "download_brave.ps1" %EDITION_ARGS%
set "PS_EXITCODE=%ERRORLEVEL%"

if not "%PS_EXITCODE%"=="0" (
    echo.
    echo [ERROR] download_brave.ps1 exited with code %PS_EXITCODE%. Brave will not be launched.
    pause
    exit /b %PS_EXITCODE%
)

REM Launch via our own portable sandbox launcher.
if not exist "brave-portable.ps1" (
    echo.
    echo [ERROR] brave-portable.ps1 was not found in "%~dp0".
    echo It is required for the self-contained portable mode.
    pause
    exit /b 1
)

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "brave-portable.ps1"
set "LAUNCH_EXITCODE=%ERRORLEVEL%"

if not "%LAUNCH_EXITCODE%"=="0" (
    echo.
    echo [ERROR] brave-portable.ps1 exited with code %LAUNCH_EXITCODE%.
    pause
    exit /b %LAUNCH_EXITCODE%
)

exit /b 0
