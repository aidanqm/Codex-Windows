@echo off
setlocal

set SCRIPT=%~dp0scripts\run.ps1
set MANAGER=%~dp0scripts\manage.ps1
if not exist "%SCRIPT%" (
  echo Missing %SCRIPT%
  exit /b 1
)

if /I "%~1"=="-Manage" (
  if not exist "%MANAGER%" (
    echo Missing %MANAGER%
    exit /b 1
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%MANAGER%"
  exit /b %ERRORLEVEL%
)

if "%~1"=="" (
  if exist "%~dp0Codex.dmg" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -DmgPath "%~dp0Codex.dmg"
    exit /b %ERRORLEVEL%
  )
  echo Usage:
  echo   run.cmd
  echo   run.cmd -Manage
  echo   run.cmd -DmgPath .\Codex.dmg
  echo Optional:
  echo   -WorkDir .\work  -CodexCliPath C:\path\to\codex.exe  -Reuse  -EnableLogging
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
