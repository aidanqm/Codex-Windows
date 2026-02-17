@echo off
setlocal

set MANAGER=%~dp0scripts\manage.ps1
if not exist "%MANAGER%" (
  echo Missing %MANAGER%
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%MANAGER%"
