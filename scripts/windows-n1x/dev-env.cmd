@echo off
REM SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
REM SPDX-License-Identifier: Apache-2.0
REM
REM Flare/Ignition development shell for an ARM64 Windows Spark N1X box
REM (also works on x64 Windows hosts). Provides the MSVC x64 host toolchain
REM that FlashInfer's nvcc JIT needs, plus the Windows-specific JIT flags.
REM
REM Install as the user's dev shell, e.g.:
REM   copy scripts\windows-n1x\dev-env.cmd %USERPROFILE%\.config\flare\dev-env.cmd
REM Usage:
REM   cmd /c "call %USERPROFILE%\.config\flare\dev-env.cmd && ignition export <alias>"
REM
REM vcvars64 prepends to PATH/INCLUDE/LIB and does not replace them, so a second
REM call in the same window grows them until cmd's 8191-character line limit
REM rejects the batch file ("The input line is too long"). Refuse to re-apply.
if defined FLARE_DEV_ENV (
  echo dev-env already applied in this window
  goto :eof
)
set "FLARE_DEV_ENV=1"

REM ---- machine knobs (edit for the target box) --------------------------------
if not defined FLARE_REPO set "FLARE_REPO=C:\flare-local-inference"
if not defined CUDA_ROOT set "CUDA_ROOT=C:\CUDA\v13.4"
if not defined VS_BUILDTOOLS set "VS_BUILDTOOLS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
if not defined STRAWBERRY_PERL set "STRAWBERRY_PERL=C:\Strawberry\perl\bin\perl.exe"

call "%VS_BUILDTOOLS%\VC\Auxiliary\Build\vcvars64.bat" >nul

REM CUDA_HOME must name the directory that contains bin/, include/, lib\x64\ and
REM nvvm\ — for a wheel-style toolkit that is the nvcc\ subdirectory.
set "CUDA_HOME=%CUDA_ROOT%\nvcc"
set "CUDA_PATH=%CUDA_HOME%"
REM sm_121a is the RTX Spark N1X (GB10) architecture.
set "CUTE_DSL_ARCH=sm_121a"
set "CUTE_DSL_PTXAS_PATH=%CUDA_HOME%\bin\ptxas.exe"
REM MSVC does not define M_PI; FlashInfer's pos_enc.cuh and generated cake kernels use it.
set "FLASHINFER_EXTRA_CUDAFLAGS=-D_USE_MATH_DEFINES"

REM Heliopause cross-builds from ARM64 to the x64 interpreter, and its vendored
REM static OpenSSL build needs a perl with core modules (Git's perl lacks
REM Locale::Maketext::Simple). These are cross-build settings only; a native
REM ARM64 venv must leave PYO3_CROSS_* unset.
set "PERL=%STRAWBERRY_PERL%"
set "OPENSSL_SRC_PERL=%PERL%"
set "PYO3_CROSS_PYTHON_VERSION=3.12"
set "PYO3_CROSS_LIB_DIR=%APPDATA%\uv\python\cpython-3.12-windows-x86_64-none\libs"

set "PATH=%FLARE_REPO%\.venv\Scripts;%CUDA_HOME%\bin;%CUDA_ROOT%\CUPTI\lib\x64;%PATH%"
REM On an ARM64 host, build scripts (host-side) compile ring's asm with clang;
REM the x64 cross toolchain from vcvars64 cannot do it.
if exist "C:\Program Files\LLVM\bin\clang.exe" set "PATH=C:\Program Files\LLVM\bin;%PATH%"

where cl >nul 2>&1 || (echo dev-env: cl.exe not found & exit /b 1)
where ninja >nul 2>&1 || (echo dev-env: ninja not found ^(uv tool install ninja^) & exit /b 1)
where nvcc >nul 2>&1 || (echo dev-env: nvcc not found & exit /b 1)

echo dev-env ready: cl, ninja, nvcc, CUDA_HOME=%CUDA_HOME%
