@echo off
REM ============================================================
REM  update.bat
REM  Runs the Brave Portable updater (download_brave.ps1).
REM
REM  Usage:
REM    update.bat              -> updates the nightly edition
REM    update.bat nightly      -> updates the nightly edition
REM    update.bat beta         -> updates the beta edition
REM    update.bat stable       -> updates the stable edition
REM
REM  Any extra arguments after the edition are forwarded to the
REM  PowerShell script (e.g. "update.bat stable -Force").
REM ============================================================

cd /d "%~dp0"

REM The first argument (if present) is treated as the edition and is
REM rewritten into a -Edition parameter for the PowerShell script.
set "EDITION_ARGS="
if not "%~1"=="" (
    set "EDITION_ARGS=-Edition %~1"
    shift
)

REM Forward any remaining arguments verbatim.
set "EXTRA_ARGS="
:collect
if not "%~1"=="" (
    set "EXTRA_ARGS=%EXTRA_ARGS% %~1"
    shift
    goto collect
)

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "download_brave.ps1" %EDITION_ARGS%%EXTRA_ARGS%

REM Propagate the PowerShell exit code so callers (and the user) can tell
REM whether the update actually succeeded.
exit /b %ERRORLEVEL%
