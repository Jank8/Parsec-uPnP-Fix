@echo off
setlocal EnableExtensions
title Parsec uPnP Fix

REM ---------------------------------------------------------------------------
REM  One-click launcher for parsec-upnp-powershell.ps1
REM  Passes any arguments through, e.g.:
REM      parsec-upnp-launcher.cmd -Mode List
REM      parsec-upnp-launcher.cmd -Mode Remove
REM ---------------------------------------------------------------------------

echo ================================================================
echo   Parsec uPnP Fix - creating the port forwardings Parsec needs
echo ================================================================
echo.

set "PS=pwsh"
where pwsh >nul 2>&1
if errorlevel 1 set "PS=powershell"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0parsec-upnp-powershell.ps1" %*
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo Finished successfully.
) else (
    echo Script exited with code %RC% - see the message above.
)
echo.
echo Press any key to close...
pause >nul
