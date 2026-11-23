@echo off
rem managed-by: claude-desktop-provider-setup
rem
rem Launcher for credential-helper.ps1. Claude Desktop runs this file; the
rem table at claude.com/docs/third-party/claude-desktop/credential-helper.md
rem lists .cmd as a supported helper form on Windows.
rem
rem -NoProfile        : do not load a profile that might print to stdout
rem -NonInteractive   : never wait on input
rem -ExecutionPolicy  : permit this local script even under a Restricted policy
rem                      (scoped to this process only; no machine setting changes)
setlocal
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0credential-helper.ps1"
exit /b %ERRORLEVEL%
