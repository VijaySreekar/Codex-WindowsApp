@echo off
setlocal

set "SCRIPT=%~dp0scripts\run.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%SCRIPT%" (
  echo Missing %SCRIPT%
  exit /b 1
)

if not exist "%PS_EXE%" (
  echo Missing %PS_EXE%
  exit /b 1
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
