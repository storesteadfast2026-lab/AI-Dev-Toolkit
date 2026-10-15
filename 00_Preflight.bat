@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp000_Preflight.ps1"
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo SCRIPT RESULT: PASS
) else (
  echo SCRIPT RESULT: FAIL ^(exit code %RC%^)
)
echo.
pause
exit /b %RC%
