@echo off
REM ============================================================
REM Lingqu portable launcher (Windows x64)
REM
REM Keeps this file PURE ASCII and free of tricky quoting:
REM cmd.exe mangles escaped quotes such as the classic
REM "strip trailing backslash" line, so we simply keep %~dp0
REM with its trailing backslash and concatenate.
REM ============================================================
setlocal

REM Package root (always ends with a backslash).
set "LINGQU_HOME=%~dp0"
REM Export without the trailing backslash for path building.
set "LINGQU_HOME_NB=%LINGQU_HOME:~0,-1%"

REM Bundled runtime + AI engine on PATH (some libs are loaded by name).
set "PATH=%LINGQU_HOME_NB%;%LINGQU_HOME_NB%\vendor\cjh\win-x64;%PATH%"

REM WebView2 user data inside the package (default location may be read-only).
if not defined WEBVIEW2_USER_DATA_FOLDER set "WEBVIEW2_USER_DATA_FOLDER=%LINGQU_HOME_NB%\.wv2"

REM Working directory must be the package root: assets are loaded relatively.
cd /d "%LINGQU_HOME_NB%"

start "" "%LINGQU_HOME%main.exe"
exit /b 0
