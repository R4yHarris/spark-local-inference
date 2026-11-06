# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-FileCopyrightText: Copyright (c) 2026 Flare community contributors
# SPDX-License-Identifier: Apache-2.0

"""Process environment that preparation libraries read, set from Flare's configuration.

PyTorch, b12x, Triton, and the CuTe DSL read these variables when they are
imported or first used, so `apply` runs before any of them is imported. Rank
and compiler processes inherit the result.
"""

import hashlib
import os
from importlib import util
from pathlib import Path

from ignition import patches

_DLL_DIRECTORIES = []

# b12x's RoCE v2 preparation defaults to GID index 3, which holds an IPv6 GID on hosts that
# register the IPv4-mapped one elsewhere. These are the indices the kernel assigns to the
# RoCE v2 GID table, so index 3 is tried first and the rest in ascending order.
_GID_INDEX_CANDIDATES = (3, *(index for index in range(16) if index != 3))
_IPV4_GID_PREFIX = "0000:0000:0000:0000:0000:ffff:"


def _read(path: Path) -> str | None:
    try:
        return path.read_text()
    except OSError:
        return None


def _ipv4_roce_v2_gids(port: Path) -> set[int]:
    """The GID indices of an active port whose entry is an IPv4-mapped RoCE v2 address."""
    return {index for index in range(16)
            if (_read(port / "gid_attrs/types" / str(index)) or "").strip() == "RoCE v2"
            and (_read(port / "gids" / str(index)) or "").strip().lower().startswith(_IPV4_GID_PREFIX)}


def roce_gid_index(root: Path = Path("/sys/class/infiniband")) -> int | None:
    """The GID index b12x should prepare RoCE v2 collectives with, or `None` when no active port
    exposes an IPv4-mapped RoCE v2 GID. Index 3 is preferred; ports that disagree fall back to the
    first port's index so a single value still describes the host."""
    if not root.is_dir():
        return None
    ports = [port for port in (device / "ports/1" for device in sorted(root.iterdir()))
             if (_read(port / "state") or "").startswith("4:")]
    discovered = {port: _ipv4_roce_v2_gids(port) for port in ports}
    discovered = {port: indices for port, indices in discovered.items() if indices}
    if not discovered:
        return None
    shared = set.intersection(*discovered.values())
    for index in _GID_INDEX_CANDIDATES:
        if index in shared:
            return index
    return min(next(iter(discovered.values())))


def flashinfer_workspace(kernel_cache: Path) -> Path:
    """Separate JIT build directories for independently editable installations."""
    package = util.find_spec("flashinfer")
    root = kernel_cache / "flashinfer"
    if package is None or package.origin is None:
        return root
    # FlashInfer keys build directories by version and GPU architecture. Distinct
    # checkouts can share both while requiring different sources and compiler flags.
    source = str(Path(package.origin).resolve()).encode()
    return root / hashlib.sha256(source).hexdigest()[:16]


def apply(configuration, gpus, b12x=()) -> None:
    """Select the plan's GPUs as process-local devices 0 through N-1, place every cache and set the recipe's
    b12x settings, which b12x reads only from its environment."""
    patches.apply()
    kernel_cache = configuration.directory("kernel_cache")
    os.environ.update({
        "CUDA_VISIBLE_DEVICES": ",".join(gpu.uuid for gpu in gpus),
        "HF_HUB_CACHE": str(configuration.directory("hub_cache")),
        "B12X_COMPILE_CACHE_DIR": str(kernel_cache / "b12x"),
        "FLASHINFER_WORKSPACE_BASE": str(flashinfer_workspace(kernel_cache)),
        "TRITON_CACHE_DIR": str(kernel_cache / "triton"),
        "TORCHINDUCTOR_CACHE_DIR": str(kernel_cache / "inductor"),
        **dict(b12x),
    })
    # b12x's RoCE v2 default index is wrong on hosts whose IPv4 GID lives elsewhere; an inherited
    # index from the operator or from NCCL is left alone.
    if not ({"B12X_ROCE_GID_INDEX", "NCCL_IB_GID_INDEX"} & os.environ.keys()):
        index = roce_gid_index()
        if index is not None:
            os.environ["B12X_ROCE_GID_INDEX"] = str(index)
    # cuTile discovers its compiler bundle independently of the native toolkit.
    cuda = configuration.directory("cuda")
    if cuda is not None:
        os.environ["CUDA_HOME"] = str(cuda)
        if os.name == "nt":
            os.environ["CUDA_PATH"] = str(cuda)
            os.environ["TRITON_PTXAS.EXE_PATH"] = str(cuda / "bin/ptxas.exe")
            for path in (cuda / "bin", cuda / "bin/x64", cuda / "lib/x64"):
                if path.is_dir():
                    _DLL_DIRECTORIES.append(os.add_dll_directory(str(path)))
