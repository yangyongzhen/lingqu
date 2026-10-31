@echo off
REM ============================================================
REM Lingqu portable launcher (Windows x64)
REM
REM Puts the bundled runtime DLLs on PATH, then starts main.exe.
REM Keep this file PURE ASCII: cmd.exe reads .bat in the OEM
REM codepage and non-ASCII bytes can break the following lines.
REM ============================================================
setlocal
set "HERE=%~dp0"

REM Bundled DLLs live next to main.exe; PATH is only a safety net
REM for cangjie runtime deps that load by name.
set "PATH=%HERE%;%HERE%vendor\cjh\win-x64;%PATH%"

REM WebView2 user data: keep it inside the package so the app works
REM even when the default location is not writable.
if not defined WEBVIEW2_USER_DATA_FOLDER set "WEBVIEW2_USER_DATA_FOLDER=%HERE%.wv2"

start "" "%HERE%main.exe"
exit /b 0
