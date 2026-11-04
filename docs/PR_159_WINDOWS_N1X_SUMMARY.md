# Fork PR #159 Review Context: Windows RTX Spark N1X Export & Serving (`R4yHarris/spark-local-inference` -> `NVIDIA/spark-local-inference#159`)

- **Upstream Repository**: `NVIDIA/spark-local-inference` (Flare local inference server & SDK for NVIDIA SM120/SM121 GPUs)
- **Fork Repository**: `R4yHarris/spark-local-inference` (branch `windows-n1x-export`)
- **Pull Request**: `NVIDIA/spark-local-inference#159` — *Windows: prepare, export and serve prepared packages on RTX Spark N1X*
- **Original Author Branch Series (`75bca4ba9a9d4e0322cd69308c345a1d3c9c40df`)**: 14 commits across 25 files addressing ARM64 Windows / RTX Spark N1X (`0x2e03`) preparation, export, and Helios serving.
- **Merged Upstream Squash (`e88aba7f9c984ec554ffb8c61e1e0217481d9bdb`)**: 10 files merged into `main` on 2026-11-02 (`.gitattributes`, `eos/src/windows.rs`, `heliopause/src/export/capture.rs`, `helios/src/package/naming.rs`, `helios/src/runtime_package/protection.rs`, `ignition/patches/__init__.py`, `ignition/preparation/peer_storage.py`, `selene/Cargo.toml`, `selene/src/shard.rs`, `tests/preparation/test_inductor_patches.py`).
- **Open Architectural Tradeoff (`eos/src/windows.rs`)**: `authenticated_handles_survive_rename_and_replacement` fails on Windows because `eos::windows::direct_read_guard` opens sealed package files with `FILE_SHARE_READ` only (omitting `FILE_SHARE_DELETE`) to guarantee immutability, which blocks directory rename while a handle is open.

## 14-Commit Series at `75bca4ba9a9d4e0322cd69308c345a1d3c9c40df`

1. `17812adf` — `export: tolerate recorder allocations released during preparation` (`heliopause/src/export/capture.rs`)
2. `b624df37` — `package cache: commit and publish entries on Windows` (`helios/src/runtime_package/protection.rs`)
3. `1a853e13` — `naming: recognise the RTX Spark N1X PCI device id` (`helios/src/package/naming.rs`, PCI ID `0x2e03`)
4. `cdb20282` — `runtime_package: read the primary container for an empty relative name` (`helios/src/runtime_package/protection.rs`)
5. `1892da9c` — `eos: accept volumes whose performance sector hint exceeds the logical sector` (`eos/src/windows.rs`)
6. `cf97a93b` — `preparation: run preparation and export on Windows` (`ignition/preparation/peer_storage.py`)
7. `320fdfd3` — `selene: reject Unix-domain manager sockets where they cannot be opened` (`selene/src/shard.rs`)
8. `f7e696ce` — `frontend: declare strftime for the Windows C runtime`
9. `8f4af590` — `patches: apply the pinned fixes to the packages the platform installs` (`ignition/patches/__init__.py`, `tests/preparation/test_inductor_patches.py`)
10. `868b3769` — `assets: keep chat template line endings stable across checkouts` (`.gitattributes`)
11. `130ab68d` — `tests: make the helios test profile compile on Windows`
12. `e5f23a1c` — `package: serialise package mutation on Windows` (`helios/src/runtime_package/protection.rs`)
13. `da2f1743` — `selene: fill the record token from the Windows CSPRNG` (`selene/Cargo.toml`, `selene/src/shard.rs`, `BCryptGenRandom`)
14. `75bca4ba` — `tests: clear the sealed attribute before corrupting a cached payload` (`helios/src/runtime_package/protection.rs`)

## Merged Fork Commit & Full 10-File Unified Diff (`origin/windows-n1x-export` / `e88aba7`)

```diff
commit e88aba7f9c984ec554ffb8c61e1e0217481d9bdb
Author: R4yharris <harray86@me.com>
Date:   Mon Nov 2 15:48:49 2026 -0800

    Fix Windows N1X export and package portability
    
    Use the Windows NVML library name, recognize the N1X GB10 PCI ID, and
    resolve primary-container asset paths when the relative filename is empty.
    Check direct-I/O geometry against logical and atomic sector sizes, preserve
    LF chat-template bytes, and generate peer tokens with BCryptGenRandom.
    
    Permit importing peer storage without POSIX descriptor passing, with an
    explicit error when that operation is requested. Allow absent Triton only
    on Windows while retaining required PyTorch and exact installed versions.
    Cover directory and packed asset reads and dependency validation.
    
    Validation: 364 package tests and one shard handshake test passed on Linux
    (7 ignored); 38 preparation tests passed (1 skipped). The Windows x64
    Helios test binary cross-compiled, and Heliopause passed cargo check.
    Template bytes were preserved with core.autocrlf=true, and peer storage
    imported with DupFd unavailable. Native Windows execution and GPU export
    and serving were not exercised.
    
    Signed-off-by: R4yharris <harray86@me.com>
    Design-Signed-Off-By: Codex (GPT-6); design-review=1c01
    Signed-off-by: Luke Alonso <lalonso@gmail.com>
---
 .gitattributes                             |  3 ++
 eos/src/windows.rs                         |  3 +-
 heliopause/src/export/capture.rs           |  7 ++++-
 helios/src/package/naming.rs               | 14 +++++++--
 helios/src/runtime_package/protection.rs   | 47 ++++++++++++++++++++++++++----
 ignition/patches/__init__.py               | 15 ++++++++--
 ignition/preparation/peer_storage.py       |  9 +++++-
 selene/Cargo.toml                          |  2 +-
 selene/src/shard.rs                        | 25 ++++++++++++++++
 tests/preparation/test_inductor_patches.py | 28 +++++++++++++++++-
 10 files changed, 138 insertions(+), 15 deletions(-)

diff --git a/.gitattributes b/.gitattributes
index 25ed38d2..d7983a90 100644
--- a/.gitattributes
+++ b/.gitattributes
@@ -1,3 +1,6 @@
 # Preserve upstream license and notice bytes, including original line endings.
 third_party/rust/** -text
 packaging/license-supplements/** -text
+
+# Preserve the bytes used by chat-template digests and embedded template parsing.
+ignition/recipes/*/assets/*.jinja text eol=lf
diff --git a/eos/src/windows.rs b/eos/src/windows.rs
index cef16d9e..5fa6f0b5 100644
--- a/eos/src/windows.rs
+++ b/eos/src/windows.rs
@@ -96,9 +96,10 @@ fn check_alignment(file: File) -> io::Result<File> {
         {
             return Err(io::Error::last_os_error());
         }
+        // The performance sector size is a hint, not an unbuffered-I/O alignment requirement.
         for sector in [
             info.LogicalBytesPerSector,
-            info.PhysicalBytesPerSectorForPerformance,
+            info.PhysicalBytesPerSectorForAtomicity,
         ] {
             if sector == 0 || 4096 % sector != 0 {
                 return Err(io::Error::new(
diff --git a/heliopause/src/export/capture.rs b/heliopause/src/export/capture.rs
index c84d5252..d2458f6f 100644
--- a/heliopause/src/export/capture.rs
+++ b/heliopause/src/export/capture.rs
@@ -1811,7 +1811,12 @@ fn current_platform(cuda: &Cuda) -> ExportResult<Option<String>> {
     let slot = attribute("cuDeviceGetAttribute", 34, b"cuDeviceGetAttribute\0")?;
     let domain = attribute("cuDeviceGetAttribute", 50, b"cuDeviceGetAttribute\0")?;
     let bus_id = std::ffi::CString::new(format!("{domain:04x}:{bus:02x}:{slot:02x}.0"))?;
-    let library = unsafe { Library::new("libnvidia-ml.so.1") }
+    let soname = if cfg!(windows) {
+        "nvml.dll"
+    } else {
+        "libnvidia-ml.so.1"
+    };
+    let library = unsafe { Library::new(soname) }
         .map_err(|error| invalid(format!("NVML is required to name an export: {error}")))?;
     #[repr(C)]
     struct PciInfo {
diff --git a/helios/src/package/naming.rs b/helios/src/package/naming.rs
index d25d5334..2436cd76 100644
--- a/helios/src/package/naming.rs
+++ b/helios/src/package/naming.rs
@@ -22,12 +22,16 @@ pub const GB202_DEVICES: [u32; 9] = [
     0x2b85, 0x2b87, 0x2b8c, 0x2bb1, 0x2bb2, 0x2bb3, 0x2bb4, 0x2bb5, 0x2bb9,
 ];
 
+/// GB10 device identifiers. `0x2e12` is the DGX Spark part; `0x2e03` is the
+/// RTX Spark N1X part, which NVML reports for the same SM121 platform.
+pub const GB10_DEVICES: [u32; 2] = [0x2e12, 0x2e03];
+
 pub fn platform_from_pci(pci_id: u32) -> Option<&'static str> {
     if pci_id & 0xffff != 0x10de {
         return None;
     }
     let device = pci_id >> 16;
-    if device == 0x2e12 {
+    if GB10_DEVICES.contains(&device) {
         return Some("gb10");
     }
     GB202_DEVICES.contains(&device).then_some("gb202")
@@ -162,7 +166,13 @@ mod tests {
 
     #[test]
     fn pci_ids_select_the_platform_identifier() {
-        assert_eq!(platform_from_pci(0x2e12_10de), Some("gb10"));
+        for device in GB10_DEVICES {
+            assert_eq!(
+                platform_from_pci(device << 16 | 0x10de),
+                Some("gb10"),
+                "{device:#06x}"
+            );
+        }
         for device in GB202_DEVICES {
             assert_eq!(
                 platform_from_pci(device << 16 | 0x10de),
diff --git a/helios/src/runtime_package/protection.rs b/helios/src/runtime_package/protection.rs
index ccce1cab..670006b9 100644
--- a/helios/src/runtime_package/protection.rs
+++ b/helios/src/runtime_package/protection.rs
@@ -1664,11 +1664,15 @@ impl super::payload::Files for PayloadSource {
                 .relative
                 .get(&span.filename)
                 .ok_or_else(|| invalid("payload container has no relative name"))?;
-            Ok(self
-                .path
-                .parent()
-                .unwrap_or_else(|| std::path::Path::new("."))
-                .join(relative))
+            // An empty relative name means the payload is stored in the primary container.
+            Ok(if relative.is_empty() {
+                self.path.clone()
+            } else {
+                self.path
+                    .parent()
+                    .unwrap_or_else(|| std::path::Path::new("."))
+                    .join(relative)
+            })
         }
     }
     fn release_page_cache(&self) {}
@@ -3815,6 +3819,39 @@ mod payload_package_tests {
         let _ = std::fs::remove_dir_all(root);
     }
 
+    #[test]
+    fn asset_paths_read_initializer_bytes_in_directory_and_packed_packages() {
+        use crate::runtime_package::payload::Files;
+
+        let (root, publishers) = two_initializer_package();
+        let packed = root.with_extension("safetensors");
+        crate::package::conversion::pack(&root, &packed).unwrap();
+        for path in [&root, &packed] {
+            let verified = VerifiedPackage::open_tensor_parallel(path, &publishers, 1, None).unwrap();
+            let authorized = verified.authorize("two-init", false).unwrap();
+            let AuthorizedKind::Payload(payload) = &authorized.kind else {
+                panic!("expected a payload package");
+            };
+            let package = &payload.packages[0];
+            let allocation = &package.allocations[0];
+            assert_eq!(allocation.sources.len(), 2);
+            for (source, expected) in allocation
+                .sources
+                .iter()
+                .zip([vec![2, 3, 4, 5], vec![9, 10, 11]])
+            {
+                let span = payload.source.span(package, &source.resource).unwrap();
+                let (_, offset) = payload.source.source(span).unwrap();
+                let file = File::open(payload.source.asset_path(span).unwrap()).unwrap();
+                let mut bytes = vec![0; source.nbytes as usize];
+                FileReadAt::read_exact_at(&file, &mut bytes, offset + source.offset).unwrap();
+                assert_eq!(bytes, expected, "{}", path.display());
+            }
+        }
+        std::fs::remove_file(packed).unwrap();
+        std::fs::remove_dir_all(root).unwrap();
+    }
+
     #[test]
     fn memory_map_reports_initializer_source_and_destination_offsets_exactly() {
         let (root, publishers) = two_initializer_package();
diff --git a/ignition/patches/__init__.py b/ignition/patches/__init__.py
index 80c70503..976d80de 100644
--- a/ignition/patches/__init__.py
+++ b/ignition/patches/__init__.py
@@ -56,17 +56,26 @@ def apply() -> tuple[Path, ...]:
     Replacing files breaks wheel-cache hardlinks instead of modifying shared bytes.
     """
     try:
-        packages = {name: distribution(name) for name in _VERSIONS}
+        packages = {}
         for name, expected in _VERSIONS.items():
-            if packages[name].version != expected:
+            try:
+                package = distribution(name)
+            except PackageNotFoundError:
+                if name == "triton" and sys.platform == "win32":
+                    continue
+                raise
+            if package.version != expected:
                 raise PreparationError(
-                    f"Preparation patches require {name}=={expected}; found {packages[name].version}. "
+                    f"Preparation patches require {name}=={expected}; found {package.version}. "
                     "Install the locked preparation dependencies with uv sync --locked --extra prepare.")
+            packages[name] = package
 
         sources, patched, modules = {}, {}, {}
         for name in _PATCHES:
             for relative, before, after in _hunks(files(__package__).joinpath(name).read_text(encoding="utf-8")):
                 package = relative.split("/", 1)[0]
+                if package not in packages:
+                    continue
                 path = Path(packages[package].locate_file(relative))
                 modules[path] = relative.removesuffix(".py").replace("/", ".")
                 if path not in sources:
diff --git a/ignition/preparation/peer_storage.py b/ignition/preparation/peer_storage.py
index e30ae40c..ddb17834 100644
--- a/ignition/preparation/peer_storage.py
+++ b/ignition/preparation/peer_storage.py
@@ -4,10 +4,15 @@
 """Symmetric VMM mappings for b12x collectives during rank preparation."""
 
 import ctypes as C
-from multiprocessing.reduction import DupFd
 import os
 import pickle
 
+try:
+    from multiprocessing.reduction import DupFd
+except ImportError:
+    # The forward pickler imports this module on Windows; descriptor passing is POSIX-only.
+    DupFd = None
+
 from b12x.comm.pcie._cuda_ipc import CudaRTLibrary
 
 
@@ -47,6 +52,8 @@ class PeerStorage(CudaRTLibrary):
         del self.owned[pointer]
 
     def cudaIpcGetMemHandleBytes(self, pointer):
+        if DupFd is None:
+            raise RuntimeError("peer storage requires POSIX descriptor passing")
         cuda = self.storage.cuda
         region = self.dynamic.get(pointer)
         mappings = [(pointer, self.owned[pointer])] if region is None else region.mappings
diff --git a/selene/Cargo.toml b/selene/Cargo.toml
index f9ba7f7c..46020bfd 100644
--- a/selene/Cargo.toml
+++ b/selene/Cargo.toml
@@ -34,7 +34,7 @@ tower = { version = "0.5", features = ["util"] }
 twox-hash = { version = "2.1", default-features = false, features = ["xxhash3_64", "alloc"] }
 
 [target.'cfg(windows)'.dependencies]
-windows-sys = { version = "0.61", features = ["Win32_Foundation", "Win32_Storage_FileSystem", "Win32_System_IO", "Win32_System_Memory", "Win32_System_SystemInformation", "Win32_System_Threading", "Win32_Security"] }
+windows-sys = { version = "0.61", features = ["Win32_Foundation", "Win32_Storage_FileSystem", "Win32_System_IO", "Win32_System_Memory", "Win32_System_SystemInformation", "Win32_System_Threading", "Win32_Security", "Win32_Security_Cryptography"] }
 
 [target.'cfg(target_os = "linux")'.dependencies]
 io-uring = "0.7"
diff --git a/selene/src/shard.rs b/selene/src/shard.rs
index ed5db503..99e7b3e5 100644
--- a/selene/src/shard.rs
+++ b/selene/src/shard.rs
@@ -1285,6 +1285,7 @@ pub fn decode_agreed(payload: &[u8]) -> Result<HashMap<PrefixKey, bool>> {
 ///
 /// Failing here stops startup: a predictable token would let any host on the
 /// network claim a peer's record connection.
+#[cfg(unix)]
 pub fn nonce() -> Result<[u8; 16]> {
     let mut random = [0u8; 16];
     std::fs::File::open("/dev/urandom")
@@ -1293,5 +1294,29 @@ pub fn nonce() -> Result<[u8; 16]> {
     Ok(random)
 }
 
+/// Windows has no `/dev/urandom`; the system-preferred CSPRNG fills the same token.
+#[cfg(windows)]
+pub fn nonce() -> Result<[u8; 16]> {
+    use windows_sys::Win32::Security::Cryptography::{
+        BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCryptGenRandom,
+    };
+    let mut random = [0u8; 16];
+    let status = unsafe {
+        BCryptGenRandom(
+            std::ptr::null_mut(),
+            random.as_mut_ptr(),
+            random.len() as u32,
+            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
+        )
+    };
+    if status < 0 {
+        return Err(record::io_failure(
+            "read a prefix record token",
+            std::io::Error::other(format!("BCryptGenRandom failed with NTSTATUS {status:#x}")),
+        ));
+    }
+    Ok(random)
+}
+
 #[cfg(test)]
 mod tests;
diff --git a/tests/preparation/test_inductor_patches.py b/tests/preparation/test_inductor_patches.py
index 96d53ba1..6b277c3a 100644
--- a/tests/preparation/test_inductor_patches.py
+++ b/tests/preparation/test_inductor_patches.py
@@ -116,8 +116,11 @@ def test_file_replacement_preserves_permissions_and_wheel_cache_hardlinks(instal
         assert target.stat().st_ino != (links / target.name).stat().st_ino
 
 
+@pytest.mark.parametrize("target_platform", ["linux", "win32"])
 @pytest.mark.parametrize("name, version", [("torch", "2.14.0+cu132"), ("triton", "3.7.0")])
-def test_incompatible_dependency_versions_fail_before_writes(installation, name, version):
+def test_incompatible_dependency_versions_fail_before_writes(installation, monkeypatch, name, version,
+                                                           target_platform):
+    monkeypatch.setattr(patches, "sys", SimpleNamespace(platform=target_platform, modules=sys.modules))
     metadata = next(installation.root.glob(f"{name}-*.dist-info/METADATA"))
     metadata.write_text(f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
     with pytest.raises(PreparationError, match=f"require {name}=="):
@@ -126,6 +129,29 @@ def test_incompatible_dependency_versions_fail_before_writes(installation, name,
         assert (installation.root / relative).read_bytes() == source
 
 
+@pytest.mark.parametrize("target_platform", ["linux", "win32"])
+@pytest.mark.parametrize("name", ["torch", "triton"])
+def test_missing_dependency_is_allowed_only_for_triton_on_windows(installation, monkeypatch, name,
+                                                                target_platform):
+    shutil.rmtree(next(installation.root.glob(f"{name}-*.dist-info")))
+    monkeypatch.setattr(patches, "sys", SimpleNamespace(platform=target_platform, modules=sys.modules))
+    # Restrict distribution discovery to this installation, excluding the test runner's dependencies.
+    monkeypatch.setattr(sys, "path", [str(installation.root)])
+    if name == "triton" and target_platform == "win32":
+        assert len(patches.apply()) == 2
+        assert patches.apply() == ()
+        for relative, expected in installation.expected.items():
+            if relative.startswith("torch/"):
+                assert (installation.root / relative).read_text() == expected
+            else:
+                assert (installation.root / relative).read_bytes() == installation.sources[relative]
+    else:
+        with pytest.raises(PreparationError, match="require the preparation dependencies"):
+            patches.apply()
+        for relative, source in installation.sources.items():
+            assert (installation.root / relative).read_bytes() == source
+
+
 @pytest.mark.parametrize("ambiguous", [False, True])
 @pytest.mark.parametrize("relative, marker", [
     ("torch/_inductor/runtime/static_triton_launcher.py", "self.full_constexprs = constants"),
```
