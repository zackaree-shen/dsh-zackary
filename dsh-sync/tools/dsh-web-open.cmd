@echo off
rem Double-click entry point: ensure the DSH web server runs, then open the web
rem profile in an app-style browser window. Kept ASCII-only so the OEM codepage
rem cannot mangle this file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-web-open.ps1" %*
