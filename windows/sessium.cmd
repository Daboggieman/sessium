@echo off
rem sessium - path shim so `sessium ...` works from any shell.
rem Keeps the .ps1 as the single source of logic.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sessium.ps1" %*
exit /b %ERRORLEVEL%
