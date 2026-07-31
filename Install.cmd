@echo off
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
set "BITWEB_EXIT=%ERRORLEVEL%"
echo.
if "%BITWEB_EXIT%"=="0" (
  echo BIT-Web Auto Login installation completed.
) else (
  echo BIT-Web Auto Login installation failed with exit code %BITWEB_EXIT%.
)
echo Press any key to close this window.
pause >nul
popd
exit /b %BITWEB_EXIT%
