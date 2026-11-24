@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
REM SPDX-License-Identifier: Apache-2.0
REM
REM Dumps the vcvars64 environment to a file for dev-env.sh to import.
REM git-bash cannot call vcvars64 directly (its environment dies with the
REM child cmd), so dev-env.sh sources the captured variable list instead.
REM Usage (from git-bash, from this directory):
REM   MSYS2_ARG_CONV_EXCL='*' cmd.exe /c dump-vcenv.bat
if not defined VS_BUILDTOOLS set "VS_BUILDTOOLS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
call "%VS_BUILDTOOLS%\VC\Auxiliary\Build\vcvars64.bat" >nul
set > "%~dp0vcenv.txt"
