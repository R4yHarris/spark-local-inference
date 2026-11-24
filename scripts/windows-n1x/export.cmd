@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
REM SPDX-License-Identifier: Apache-2.0
REM
REM Unattended ignition export wrapper for the Windows N1X box.
REM   export.cmd <alias> [--no-compile] [other ignition export args...]
REM
REM Starts from a clean environment (so a previously stacked vcvars cannot hit
REM cmd's line limit), applies dev-env once, and writes an ANSI log — never
REM Tee-Object, which writes UTF-16LE and silently breaks grep/tail. The
REM config must carry no [publishing] section so the run never prompts for a
REM signing passphrase; sign afterwards with `ignition sign` (see
REM docs/windows-n1x-setup.md).

setlocal
if "%~1"=="" (
  echo usage: export.cmd ^<alias^> [ignition export args...] && exit /b 2
)

set "FLARE_REPO=C:\flare-local-inference"
set "LOG=%TEMP%\flare-export-%DATE:~-4%%DATE:~4,2%%DATE:~7,2%-%RANDOM%.log"

REM Clear the sentinel together with the toolchain variables so dev-env
REM actually applies; a stale sentinel makes the call a silent no-op and the
REM export then dies at Load weights with "requires an MSVC developer shell".
set "FLARE_DEV_ENV="
set "PATH=C:\Windows\system32;C:\Windows"
set "INCLUDE="
set "LIB="
call "%USERPROFILE%\.config\flare\dev-env.cmd" || (echo dev-env failed & exit /b 1)

cd /d %FLARE_REPO%
.venv\Scripts\python.exe -m ignition export %* > "%LOG%" 2>&1
echo EXIT=%ERRORLEVEL% >> "%LOG%"
echo log: %LOG%
endlocal & exit /b 0
