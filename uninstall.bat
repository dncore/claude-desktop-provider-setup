@echo off
rem Uninstall entry point for Windows. Removes only what this tool created.
setlocal

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\windows\Cli.ps1" uninstall --restart %*
set "RC=%ERRORLEVEL%"

if not defined CDS_NO_PAUSE (
    echo.
    pause
)
exit /b %RC%
