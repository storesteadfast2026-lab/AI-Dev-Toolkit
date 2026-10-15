@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
set "AOM_VERSION=Application Operations Manager PS"
if exist "%~dp0VERSION.txt" set /p AOM_VERSION=<"%~dp0VERSION.txt"
echo %AOM_VERSION%
echo ============================================================
echo Running preflight...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp000_Preflight.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo ============================================================
  echo MANAGER PREFLIGHT RESULT: FAIL
  echo Exit code: %RC%
  echo ============================================================
  echo.
  echo The window will stay open so you can read the error.
  pause
  exit /b %RC%
)
echo.
echo Starting Windows PowerShell 5.1 GUI...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manager.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo ============================================================
  echo MANAGER RESULT: FAIL
  echo Exit code: %RC%
  echo ============================================================
  echo.
  echo The window will stay open so you can read the error.
  pause
)
exit /b %RC%
