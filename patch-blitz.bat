@echo off
rem ==========================================================================
rem  Blitz Ad-Block patcher - one-click installer
rem  Auto-detects Blitz, applies the patch, installs the repair kit to
rem  %%APPDATA%%\Blitz\patch-kit and creates the "Blitz (patched)" shortcut.
rem ==========================================================================
setlocal
cd /d "%~dp0"

where pwsh >nul 2>&1 && (set "SH=pwsh") || (set "SH=powershell")

echo [blitz-patch] launching installer via %SH% ...
"%SH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0blitz-patch.ps1" -Install %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [blitz-patch] done. Use the "Blitz (patched)" desktop shortcut from now on.
) else (
  echo [blitz-patch] FAILED ^(code %RC%^) - see messages above.
)
pause
exit /b %RC%
