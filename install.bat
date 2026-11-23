@echo off
rem Entry point for Windows. Double-clickable and usable from a terminal.
rem Set CDS_NO_PAUSE=1 to suppress the "press any key" prompt in automation.
setlocal

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\windows\Cli.ps1" %*
set "RC=%ERRORLEVEL%"

if not defined CDS_NO_PAUSE (
    echo.
    pause
)
exit /b %RC%
