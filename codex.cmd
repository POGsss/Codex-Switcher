@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexProxy.ps1" %*
exit /b %errorlevel%
