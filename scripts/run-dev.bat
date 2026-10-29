@echo off
REM ============================================================
REM Windows launcher for scripts\run-dev.sh
REM Keep this file PURE ASCII (cmd.exe reads .bat in the OEM codepage).
REM
REM Usage:  scripts\run-dev.bat [-b] [-s]
REM ============================================================
setlocal

set "BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "D:\Program Files\Git\bin\bash.exe" set "BASH=D:\Program Files\Git\bin\bash.exe"
if not defined BASH for /f "delims=" %%i in ('where bash 2^>nul') do if not defined BASH set "BASH=%%i"

if not defined BASH (
    echo [x] bash not found. Install Git for Windows, or run scripts/run-dev.sh from WSL / a Linux shell.
    exit /b 1
)

"%BASH%" "%~dp0run-dev.sh" %*
exit /b %ERRORLEVEL%
