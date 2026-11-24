# Windows on RTX Spark N1X: development pipeline and reproducible setup

This document records the complete pipeline that was built, measured, and
validated on an ASUS ProArt P16 with an NVIDIA RTX Spark N1X (GB10 die,
sm_121, ARM64 Windows 11, 128 GB unified memory) so the same environment can
be recreated on another N1X machine. It covers what to install, which package
pins had to move beyond `pyproject.toml`, every Windows-only code fix the port
needed, and the measured commands for export, serving, and validation.

Everything below was exercised end to end on this class of machine:
`ignition export qwen3.8-flash` completed natively (cache entry
`gb10-tp1-202610292028`, native export phase 1966 s, whole run ~33 min) and
`flare run` served the exported package with successful chat completions
(driver 617.69).

## Validated revision

Recreate against these pins, not against `main` (see "Reconciling with
upstream" for why):

| Item | Value |
|---|---|
| Fork | `https://github.com/R4yHarris/spark-local-inference` |
| Branch | `windows-n1x-validated` |
| Validated tip | `75bca4ba` plus the lockfile-sync and docs commits on this branch |
| Upstream base | `34443322` ("Keep self-reading complete copies in program order", #158) |
| Model prepared | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ `b9ce18a6` (~111 GB cache) |

The 14 Windows commits on the branch each carry one root-cause fix; see the
fix catalogue below for symptom → cause → commit.

## Host prerequisites

| Component | Requirement | Why |
|---|---|---|
| OS | Windows 11 on ARM64 (RTX Spark N1X) | sm_121 GB10 device id `0x2e03` |
| NVIDIA driver | 617.69 or newer (R620 branch for CUDA 13.5) | CUPTI, NVML |
| Visual Studio 2022 Build Tools | 14.44.x (`VC\Tools\MSVC\14.44.35207`), C++ x64 tools | `cl`/`link` for the FlashInfer nvcc JIT |
| Windows SDK | 10.0.26100.0 | INCLUDE/LIB for the JIT link |
| Strawberry Perl | `C:\Strawberry` | vendored OpenSSL build runs `perl Configure`; Git's perl lacks `Locale::Maketext::Simple` |
| uv + CPython 3.12 **x64** | `uv python` managed `cpython-3.12-windows-x86_64-none` | the whole Python stack is x64 under emulation; an ARM64 native stack is separate (below) |
| Rust | MSVC toolchain host | cargo cross-builds to the x64 interpreter |
| ninja | `uv tool install ninja` | **not** a venv package: `uv sync --locked` deletes venv-local copies and the next JIT dies with WinError 2 |
| LLVM/Clang | `C:\Program Files\LLVM\bin` on PATH | host-side build scripts on an ARM64 host compile `ring`'s asm with clang; the x64 cross toolchain from vcvars64 cannot |

Do not use an "ARM64 native tools" developer prompt: it puts `arm64`
`cl.exe` first on PATH while the venv interpreter is x64, and every JIT-built
DLL must be x64 (`Hostx64/x64`).

### Pagefile (serving)

The OS sees only ~31 GB of the 128 GB (the Windows dedicated-GPU-memory
slider reserves ~96 GB), so flare's ~102 GiB of GPU residency counts against
a ~126 GB commit limit and the box cascades out-of-memory (event 2004, then
`flare.exe` fastfails `c0000409`). Raise the pagefile before serving:

```bat
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" ^
  /v PagingFiles /t REG_MULTI_SZ /d "C:\pagefile.sys 192768 192768" /f
```

The lifted commit limit lands only after a reboot (then
`Get-Counter '\Memory\Commit Limit'` ≈ 219 GB).

### Power for multi-hour exports

Sleep during a run corrupts every phase timer and can strand a whole export:

```bat
powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /setactive <new GUID>
powercfg /setacvalueindex <new GUID> SUB_SLEEP STANDBYIDLE 0
powercfg /setactive <new GUID>
```

Set sleep-after 0 on every scheme you use and verify with
`powercfg /getactivescheme`; closing the lid still forces Modern Standby.

## CUDA toolkit layout

`C:\CUDA\v13.4` is a wheel-style (partial) toolkit, not a full installer
layout:

```
C:\CUDA\v13.4\nvcc\{bin,include,lib\x64,nvvm}   nvcc 13.4.92, ptxas, cicc,
                                                libdevice.10.bc, nvvm.lib,
                                                cudart.lib/cuda.lib
C:\CUDA\v13.4\CUPTI\lib\x64                     cupti64_*.dll
```

`CUDA_HOME` therefore points at `C:\CUDA\v13.4\nvcc` (the directory
containing `bin/`, `include/`, `lib\x64\`, `nvvm\`), and
`cupti64_<version>.dll` must be reachable from `CUDA_HOME` — the preparation
recorder resolves it with `cuda.pathfinder.load_nvidia_dynamic_lib("cupti")`,
which searches the `CUDA_PATH`/`CUDA_HOME` anchors but never `PATH`. Missing
components (cublas, nvrtc, cusparse, cusolver, npp) block only the sm103
recipes' gemm/fused_moe modules; the Qwen FP4 recipe does not need them.

Install route: the pip `nvidia-cuda-*` cu13 wheels (they lay out exactly this
tree under `site-packages/nvidia/cu13`) or the matching `cuda_13.4_*`
installer trimmed to the tree above.

## Python environment

Create the venv with the **x64** 3.12 interpreter, never the ARM64 one:

```bat
cd /d C:\flare-local-inference
uv venv --python cpython-3.12-windows-x86_64-none .venv
```

`uv sync --locked` and `uv pip install -e ".[prepare]"` both fail on Windows:
`nvidia-cutlass-dsl-libs-base` at the locked version publishes no
`win_amd64` wheel, and the b12x extra also pins CuTe DSL below the version
with Windows wheels. Install against the validated freeze instead, with the
editable package itself pulled in without deps:

```bat
uv pip install --python .venv\Scripts\python.exe -r scripts\windows-n1x\requirements.windows-n1x.txt
uv pip install --python .venv\Scripts\python.exe --no-deps -e .
uv tool install ninja
```

`requirements.windows-n1x.txt` is a freeze taken from the validated
environment. It excludes two locally built packages, installed from source:

```bat
REM heliopause is a maturin PEP 517 package; build it from the source tree
REM inside the dev shell (it honours PYO3_CROSS_* and PERL — see "Rebuilding
REM heliopause"). The validated environment installed it as
REM `flare-heliopause @ file:///C:/flare-local-inference/heliopause`:
uv pip install --python .venv\Scripts\python.exe --no-deps .\heliopause
```

### Pins that had to move beyond pyproject.toml

This table is the record of "which packages had to be updated to get it
working". The left column is what `pyproject.toml`/`uv.lock` declare for the
validated base commit; the middle is what actually runs on the N1X box.

| Package | pyproject/lock pin | Validated install | Why |
|---|---|---|---|
| `cuda-python`, `cuda-bindings` | 13.3.1 | **13.4.4** | parity with the CUDA 13.4 toolkit components; 13.3 bindings do not match the 13.4 CUPTI/nvcc pair on this box |
| `cuda-pathfinder` | (transitive) | **1.8.4** | resolves the CUPTI DLL through the CUDA anchors. For CUDA **13.5** it must go to **1.8.6**: 13.5 renames the DLL to `cupti64_13.dll` and 1.8.5's catalog does not know that name — the export then dies seconds after "Select GPUs" with `DynamicLibNotFoundError` |
| `nvidia-cutlass-dsl` + `-libs-base/-core/-cu12/-cu13` | b12x extra pins 4.7.1; `-libs-base` at lock version has no `win_amd64` wheel | **4.8.0** (win_amd64 wheels published since) | 4.7.1 cannot install on Windows; 4.8.0 ships `cp312-win_amd64` wheels. Keep all five at the same version |
| `flashinfer-python` | git `rev=main` of `local-inference-lab/flashinfer` | **f5f5341d…** (same version string 0.7.1 across revisions) | the version string never changes, so verify the revision from `direct_url.json`, not from `importlib.metadata`; a stale install looks current and later fails inside b12x tuning with a validator message that reads like a recipe bug |
| `triton-windows` | absent (repo declares triton `sys_platform == 'linux'`) | **3.8.0.post29** | autotuning's compile pool imports `triton`; without it every default-effort export dies right after tuning with a message that only says "run uv sync". post29 has working Windows wheels and compiles kernels |
| `transformers` | git pin `1d9654e7…` | same git pin | recipe requires this dev revision |
| `huggingface-hub` | ==1.33.0 | **2.3.0** | what the validated environment settled on; nothing in the Qwen FP4 path requires 1.33.x |
| `tokenizers` | ==0.23.2 | **0.23.3** | resolver outcome in the validated environment |
| `accelerate` | ==1.14.0 | **1.15.0** | resolver outcome in the validated environment |
| `cuda-tile[tileiras]` | ==1.6.0 | **not installed** | the Qwen FP4 export path never imports it; install only if a recipe asks |
| `flare-heliopause` | PyPI | local `maturin`/cargo build from `heliopause/` | the export capture fixes live in this tree's Rust code |
| `pytest`, `ninja` | not in the lock | 9.2.0 / 1.13.2 | test runner and JIT build tool kept out of the venv lock |

The remaining freeze lines are ordinary transitive dependencies.

### Rebuilding heliopause

From the dev shell (which sets `PYO3_CROSS_PYTHON_VERSION=3.12`,
`PYO3_CROSS_LIB_DIR`, and `PERL` — without them pyo3-ffi refuses the
cross-build and the vendored OpenSSL configure dies):

```bat
cargo build --locked --release --target x86_64-pc-windows-msvc --manifest-path heliopause\Cargo.toml
```

Pass `--target` explicitly: on the ARM64 host a bare `cargo build` builds the
host `aarch64-pc-windows-msvc` target, and the extension must be x64 to load
under the x64 interpreter.

Note on `--locked`: at the validated base commit `heliopause/Cargo.lock` was
stale and cargo refused `--locked` ("cannot update the lock file"); the
lockfile-sync commit on this branch repairs it (the other Rust trees —
`flare`, `helios`, `selene` — resolved under `--locked` all along). A clean
heliopause build takes ~14 min (OpenSSL from source); incremental crate-only
rebuilds are faster.

## Configuration files

The CLI loads `~\.config\flare\config.toml`; the repo's `ignition.toml`
applies only with `--config ignition.toml`. The one key that matters for the
toolchain is:

```toml
[paths]
cuda = "C:\\CUDA\\v13.4\\nvcc"
```

Verify the resolution rather than assuming it:

```bat
.venv\Scripts\python.exe -c "from ignition.cli.config import Configuration; c = Configuration.load(None); print(c.directory('cuda'))"
```

For unattended exports use `scripts/windows-n1x/config-nopublish.example.toml`
(a copy of which must live in the scratch directory you pass with
`--config`): a config **outside** `~\.config\flare` creates its own
development signing identity beside that config, and `flare run`/`inspect`
then need `--publisher-keys` pointing at it. `ignition.signing.passphrase`
checks `isatty`, which is why an inline-signing export cannot be driven
unattended — export unsigned with the scratch config, then `ignition sign`.

## Dev shell and preflight

Install `scripts/windows-n1x/dev-env.cmd` as
`%USERPROFILE%\.config\flare\dev-env.cmd` (or call it from the repo) in a
plain, non-elevated **cmd.exe**, then prove the toolchain in one line before
starting anything long:

```bat
call %USERPROFILE%\.config\flare\dev-env.cmd
where cl && where ninja && where nvcc
echo %FLASHINFER_EXTRA_CUDAFLAGS%     rem must print -D_USE_MATH_DEFINES
```

The helper refuses a second call in the same window (vcvars prepends until
cmd's line limit rejects the file — open a new window instead). From
git-bash, source `dev-env.sh` after generating `vcenv.txt` once with
`dump-vcenv.bat`. From git-bash, invoke any `.cmd` helper as
`MSYS2_ARG_CONV_EXCL='*' cmd.exe /c file.cmd` — `cmd //c` silently starts an
interactive cmd and runs nothing.

Missing any of `cl`, `ninja`, `CUDA_HOME`, or `-D_USE_MATH_DEFINES` surfaces
as the same opaque `FileNotFoundError [WinError 2]`; isolate JIT failures with
one module instead of a full export:

```bat
.venv\Scripts\python.exe -c "from flashinfer.jit.sampling import gen_sampling_module; print(gen_sampling_module().build_and_load())"
```

Measured first-build costs (x64 emulated): rope 196 s, sampling 463 s,
quantization ~2 min. Pre-warm the modules **into the workspace Ignition will
actually use** — Ignition keys it on the installed flashinfer file, so compute
the directory before warming:

```bat
.venv\Scripts\python.exe -c "from pathlib import Path; from ignition.cli.environment import flashinfer_workspace; print(flashinfer_workspace(Path.home()/'.cache/flare/kernels'))"
```

and set `FLASHINFER_WORKSPACE_BASE` to that path while warming. Warming the
default cache instead rebuilds silently inside the export (~7 min for
sampling). Never share a FlashInfer/Triton JIT cache between an ARM64 and an
x64 interpreter — the cache keys carry no host-architecture field and one
side loads a `.pyd` it cannot run.

## Export

Serving and exporting cannot share the box: an export holds 86–91 GB of the
96 GB. Fast iteration config that reaches the native export stage in minutes:

```bat
.venv\Scripts\python.exe -m ignition export qwen3.8-flash --no-mtp ^
  --max-concurrency 2 --image-concurrency 1 --autotune-effort off --no-compile --verbose
```

Measured: 24 graphs, catalog 24/24 in 41 s, whole run to the export step
~8 min. `--no-compile` still builds the full graph catalog and still runs
b12x kernel tuning; it only skips compiling forwards.

Full validated run (~33 min on a warm cache; ~½ day cold after a FlashInfer
revision change — the b12x program cache is keyed on the installed revision):

```bat
scripts\windows-n1x\export.cmd qwen3.8-flash --config <scratch>\config-nopublish.toml --verbose
```

What each phase means and what to watch: the export prints phase lines you can
judge from the worker's climbing `TotalProcessorTime` and artifact writes —
catalog construction and program planning are single-threaded CPU grinds that
print nothing for stretches; check CPU before calling it hung. `0 measured`
with an hours-long counter means the machine slept (Kernel-Power events
506/507), `0 cached` means real compute. A FlashInfer revision change turns a
6-minute tuning phase into hours (measured 15,384 s tuning + ~7 h forward
compile + 1,452 s native export) because every candidate is re-measured.

## Serving a validated package

```bat
flare\target\release\flare.exe models list
flare\target\release\flare.exe run nvidia/Qwen3.8-Flash-Next-FP4-Local --port 8000 ^
  --dangerously-approve-key <FINGERPRINT> --dangerously-accept-publisher local-development
curl http://127.0.0.1:8000/v1/models
curl http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" ^
  -d "{\"model\":\"nvidia/Qwen3.8-Flash-Next-FP4-Local\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17 multiplied by 23?\"}]}"
```

A healthy load prints weights, KV-cache size and token capacity (measured:
76.91 GiB loaded, 25.54 GiB cache budget, 1,650,688 KV tokens) and the
request answers with `finish_reason: stop`. The trust acknowledgment is
one-time (`~\.cache\flare\trust.toml`). Note the argument shapes: `flare run`
wants `org/Model` with a **forward** slash (a backslash is treated as a path),
`flare inspect` wants the cache key `org/Model@version`, and
`ignition convert` wants a native `C:/Users/...` directory path. Stop the
server with Ctrl-C or SIGTERM so native replay drains before CUDA resources
are released.

## Test commands that prove the port

The fast Windows reproduction for the commit-path defects is the cache suite:

```bat
cargo test --manifest-path helios/Cargo.toml --target x86_64-pc-windows-msvc --features runtime-package --lib package::cache
```

(38 failures before the fixes, 72 passed / 0 failed / 1 ignored after — see
`docs/windows.md` for the general Windows build/test lane.) The preparation
pytest suite is the Linux-side lane: two modules (`test_export_transfer.py`,
`test_host_ranks.py`) import POSIX-only `resource`/`fcntl` and cannot
collect, and several modules (measured at the validated base: 12 of the 26
`test_inductor_patches.py` tests) assert against synthesized Linux triton
fixtures — the patch table itself applies to the real triton-windows
environment, which is what the completed exports exercise. Treat the full
preparation suite as the Linux-side lane (the port's submission validation
measured 38 preparation tests passing, 1 skipped, on Linux) and do not
chase Windows fixture failures as port defects.

## Native ARM64 stack (separate, partial)

A parallel native-ARM64 environment (ARM64 Python, torch 2.14.0+cu134 from
`https://pypi.nvidia.com/nvtorch_oot/`, ARM64 Triton, native nvcc/MSVC,
`flare.exe`, `heliopause` wheel) exists at `C:\flare-arm64-feasibility`.
Blocked there: any recipe export, because `nvidia-cutlass-dsl-libs-base` /
`-libs-cu13` publish no `win_arm64` wheels (CuTe DSL is proprietary,
wheel-only — the gap cannot be closed locally; run
`scripts/check_cutlass_win_arm64.py` from the Hermes skill to produce the
evidence for the upstream request). Do not expect a CPU speedup either: native
torch (ArmPL, no oneDNN) is ~5x slower than the emulated x64 MKL build for
dense CPU matmul. This repo's x64-venv instructions above are the working
export path.

## Reconciling with upstream

Upstream `NVIDIA/spark-local-inference` absorbed part of this work in November
(PR #171 builds/tests Selene+Helios on Windows, PR #173 covers the
prepared-package file semantics, and current `main` carries the NVML name,
the N1X PCI id, BCryptGenRandom and the chat-template `.gitattributes`).
The branch here remains the validated stack for this box. Before rebasing
onto current `main`:

1. Rebuild first — new upstream crates are written against Linux and the
   Windows build fails on Unix-only APIs before the branch's own code
   (measured: `selene`'s `tokio::net::UnixStream` arm; the `libc` crate has no
   `strftime` on Windows though MSVC's CRT exports one).
2. Then run the patch stage alone —
   `python -c "from ignition.patches import apply; print(len(apply()))"` —
   because Linux-only preparation dependencies stop every export just after
   GPU selection with a message that only says to run `uv sync`.
3. Check `ABI_VERSION` in `helios/src/execution/manifest.rs` of the new tree
   before publishing anything built there: an ABI bump makes every older
   package unloadable at *load* time (`flare inspect` reads metadata only and
   still answers clean).
4. Compare the installed FlashInfer revision with `uv.lock`'s `#<sha>`
   (`direct_url.json`) — a rebase moves the pin invisibly.

## Fix catalogue (branch commits, oldest first)

| Commit | Symptom before the fix | Fix |
|---|---|---|
| `17812adf` | native export died with `CUDA 1: invalid argument` on a copy of a recorder allocation that preparation had already released (dead torch memory-pool block) | verify every recorder-discovered allocation end to end with `cuMemcpyDtoH`; omit + `Reachability::forget` when not graph-referenced, fail loudly when it is |
| `b624df37` | export commit died with bare `Access is denied` on Windows | fsync needs a writable handle; `LockFileEx` cannot downgrade in place; `ERROR_LOCK_VIOLATION` (33) is not `WouldBlock`; verbatim `\\?\` canonical paths broke root containment |
| `1a853e13` | `NVML reports unsupported GPU PCI id 0x2e03` | add the RTX Spark N1X GB10 device id next to the DGX Spark's `0x2e12` |
| `cdb20282` | tokenizer load: `cannot read \?\C:\...\gb10-tp1-<ts>\` — asset resolved to the entry directory | return the primary container path when the asset's relative name is empty |
| `1892da9c` | every `flare run` died pre-load: `direct I/O sector size 32768 does not divide 4096` | check logical and atomic sector sizes, not the performance hint |
| `cf97a93b` | every export died after GPU selection (Linux-only triton import, `DupFd` module-level import) | permit absent Triton on Windows; import peer storage without POSIX descriptor passing, raise on use |
| `320fdfd3` | selene manager socket failed opaquely on Windows | reject Unix-domain manager sockets where they cannot be opened |
| `f7e696ce` | link error on `strftime` (the `libc` crate declares none for Windows) | declare the symbol MSVC's CRT actually exports |
| `8f4af590` | pinned fixes never reached the platform-installed packages | apply the pinned patches to the packages the platform installs |
| `868b3769` | `core.autocrlf=true` checkouts broke serving with a Kimi-template panic | declare the template assets `text eol=lf` in `.gitattributes` |
| `130ab68d` | `cargo test` could not even build: Unix-only `flare-selene-manager` dev-dependency | scope the dependency and its single consumer to `cfg(unix)` |
| `e5f23a1c` | concurrent package mutation lost an update on Windows | take a real `LockFileEx` in `lock_package` (Windows refused to rename onto sealed read-only files: clear the attribute before the rename) |
| `da2f1743` | two-rank join died at startup (`/dev/urandom` on every platform, os error 3) | `BCryptGenRandom` with `BCRYPT_USE_SYSTEM_PREFERRED_RNG` |
| `75bca4ba` | `verify_ready` fixtures failed: Windows refuses to replace a read-only destination | clear the sealed attribute before corrupting a cached payload |

Plus the preparation-side fixes inside `cf97a93b`/`8f4af590`:
`PackageStorage.address_floor` returns 0 when the storage never sealed its
low window (Windows cannot seal — WDDM owns the low pool — so the export must
not assert `EXTERNAL_FLOOR`; asserting it rejected every export with
"retained device allocation … is below the restorable address floor"), and
export naming loads `nvml.dll` (not `libnvidia-ml.so.1`) on Windows.

## Known gaps / not yet done

- End-to-end serving of a package exported by **this branch's** tree has been
  exercised on this box; the HF-published copy under
  `huggingface.co/r4yharris/Qwen3.8-Flash-Next-FLARE` must be re-checked
  against the current `ABI_VERSION` before pointing new users at it.
- A full-capacity export (MTP on, full concurrency ladder) has not been
  re-run since the last FlashInfer revision change; budget ~½ day cold.
- The sm103 recipes (glm53, kimi3) need the complete CUDA component set
  (cublas/nvrtc/cccl); FlashInfer's fused_moe additionally passes `-lnvrtc`,
  a gcc-style flag `link.exe` rejects — needs `FLASHINFER_EXTRA_LDFLAGS`
  (`nvrtc.lib`) or an upstream fix.
- Native ARM64 export stays blocked on the proprietary CuTe DSL `win_arm64`
  wheels; the deliverable there is evidence for NVIDIA, not a local port.
- CUDA 13.5: feasible on ARM64 Windows (GA installer + win_arm64 wheels for
  the core components, uploaded 2026-11-04) but gated on this box still
  running driver 617.69 — 13.5's new features pair with R620+, and
  `cuda-pathfinder` must be ≥1.8.6 for the renamed CUPTI DLL before moving
  `CUDA_HOME`. Serve one request before trusting either upgrade.
