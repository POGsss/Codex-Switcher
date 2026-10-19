@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexAccountSwitcher.ps1"
endlocal