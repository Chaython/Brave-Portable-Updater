@echo off
REM ============================================================
REM  update_then_run_brave.bat
REM  Updates Brave Portable, then launches it via the portapps.io
REM  brave-portable.exe wrapper.
REM
REM  This is a DROP-IN script for an existing portapps.io Brave
REM  Portable installation: place these files next to
REM  brave-portable.exe (the portapps wrapper). The wrapper is what
REM  keeps Brave portable -- it redirects AppData and registry
REM  writes. Launching brave.exe directly would NOT be portable,
REM  so this script deliberately does NOT do that.
REM
REM  If you DON'T have the portapps wrapper, use
REM  update_then_run_portable.bat instead, which launches brave.exe
REM  through our own sandbox launcher (brave-portable.ps1).
REM
REM  Usage:
REM    update_then_run_brave.bat              :: nightly (default)
REM    update_then_run_brave.bat nightly
REM    update_then_run_brave.bat beta
REM    update_then_run_brave.bat stable
REM ============================================================

REM Ensure the working directory is the same as the batch file location
cd /d "%~dp0"

set "EDITION_ARGS="
if not "%~1"=="" (
    set "EDITION_ARGS=-Edition %~1"
    shift
)

REM Run the PowerShell updater script
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "download_brave.ps1" %EDITION_ARGS%
set "PS_EXITCODE=%ERRORLEVEL%"

REM If the updater failed, don't try to launch Brave; warn and pause so the
REM user can read the error before the window closes.
if not "%PS_EXITCODE%"=="0" (
    echo.
    echo [ERROR] download_brave.ps1 exited with code %PS_EXITCODE%. Brave will not be launched.
    pause
    exit /b %PS_EXITCODE%
)

REM --- LAUNCH VIA THE PORTAPPS WRAPPER ---
REM  brave-portable.exe is the portapps.io launcher. It sets up the
REM  portable environment (redirected AppData/registry) and then runs
REM  app\<version>\brave.exe. Without it, Brave is NOT portable.
if exist "brave-portable.exe" (
    start "" "brave-portable.exe"
    exit /b 0
)

echo.
echo [ERROR] brave-portable.exe was not found in "%~dp0".
echo.
echo This script is a drop-in for an existing portapps.io Brave Portable
echo install. Place it next to brave-portable.exe (the portapps wrapper).
echo.
echo If you do NOT have the portapps wrapper, run
echo update_then_run_portable.bat instead -- it launches brave.exe through
echo brave-portable.ps1, our own portable sandbox launcher (no portapps
echo needed).
pause
exit /b 1
