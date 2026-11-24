# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0
#
# Flare/Ignition development environment for git-bash on an ARM64 Windows
# Spark N1X box. Mirrors dev-env.cmd. Usage:  source dev-env.sh
#
# vcvars64 is a cmd batch; its environment cannot survive the child process,
# so dump-vcenv.bat captured the variable list into vcenv.txt and we import
# the compiler-relevant entries here.

_FLARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_VCENV="$_FLARE_DIR/vcenv.txt"
if [ ! -s "$_VCENV" ]; then
  echo "vcenv.txt missing; run: MSYS2_ARG_CONV_EXCL='*' cmd.exe /c $(cygpath -w "$_FLARE_DIR")\\dump-vcenv.bat" >&2
  return 1 2>/dev/null || exit 1
fi
while IFS='=' read -r k v; do
  case "$k" in
    INCLUDE|LIB|LIBPATH|VSINSTALLDIR|VCINSTALLDIR|WindowsSdkDir|VCToolsInstallDir|UCRTVersion|WindowsSDKVersion|VSCMD_VER|VCToolsVersion)
      export "$k=$v" ;;
  esac
done < <(tr -d '\r' < "$_VCENV")

: "${FLARE_REPO:=C:\flare-local-inference}"
: "${CUDA_ROOT:=C:\CUDA\v13.4}"

export CUDA_HOME="${CUDA_ROOT}\\nvcc"
export CUDA_PATH="$CUDA_HOME"
export CUTE_DSL_ARCH=sm_121a
export CUTE_DSL_PTXAS_PATH="${CUDA_ROOT}\\nvcc\\bin\\ptxas.exe"
# MSVC does not define M_PI; FlashInfer's pos_enc.cuh and generated cake kernels use it.
export FLASHINFER_EXTRA_CUDAFLAGS='-D_USE_MATH_DEFINES'

# Heliopause cross-builds from ARM64 to the x64 interpreter; these are
# cross-build settings only — a native ARM64 venv leaves PYO3_CROSS_* unset.
: "${STRAWBERRY_PERL:=C:\Strawberry\perl\bin\perl.exe}"
export PERL="$STRAWBERRY_PERL"
export OPENSSL_SRC_PERL="$PERL"
export PYO3_CROSS_PYTHON_VERSION=3.12
export PYO3_CROSS_LIB_DIR="$APPDATA/uv/python/cpython-3.12-windows-x86_64-none/libs"

_VS_BUILDTOOLS="${VS_BUILDTOOLS:-C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools}"
export PATH="$(cygpath -u "${FLARE_REPO//\\//}")/.venv/Scripts:$(cygpath -u "${CUDA_ROOT//\\//}")/nvcc/bin:$(cygpath -u "${CUDA_ROOT//\\//}")/CUPTI/lib/x64:$_VS_BUILDTOOLS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64:$PATH"

command -v cl.exe >/dev/null 2>&1 || echo "dev-env: cl.exe not found" >&2
command -v ninja >/dev/null 2>&1 || echo "dev-env: ninja not found (uv tool install ninja)" >&2
command -v nvcc >/dev/null 2>&1 || echo "dev-env: nvcc not found" >&2
