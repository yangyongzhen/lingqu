@echo off
REM ============================================================
REM Windows launcher for scripts\test.sh
REM
REM The gate lives in test.sh (one implementation, cross-platform).
REM This wrapper only finds a bash and delegates, so Windows and
REM Linux run exactly the same checks.
REM
REM Keep this file PURE ASCII: cmd.exe reads .bat in the OEM
REM codepage and non-ASCII bytes can break the following lines.
REM
REM Usage:  scripts\test.bat [-q|-s|-c]
REM ============================================================
setlocal

set "BASH="
REM Prefer Git for Windows bash (WSL's bash.exe in System32 would run
REM Linux bash against a Windows path and fail confusingly).
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "D:\Program Files\Git\bin\bash.exe" set "BASH=D:\Program Files\Git\bin\bash.exe"
if not defined BASH for /f "delims=" %%i in ('where bash 2^>nul') do if not defined BASH set "BASH=%%i"

if not defined BASH (
    echo [x] bash not found. Install Git for Windows, or run scripts/test.sh from WSL / a Linux shell.
    exit /b 1
)

"%BASH%" "%~dp0test.sh" %*
exit /b %ERRORLEVEL%
