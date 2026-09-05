@echo off
setlocal
pushd "%~dp0"
wscript.exe "%~dp0Open-GUI.vbs"
set "BITWEB_EXIT=%ERRORLEVEL%"
popd
exit /b %BITWEB_EXIT%
