# Bundled Vulkan libraries

A library with no code in it: a manifest, and a directory of Vulkan binaries per
target. c3c links whichever directory matches what is being built, which is what
lets cui build on any platform from one committed set of libraries.

The released `cui.c3l` carries the same directories, because a `.c3l` is exactly
this shape — so cutting a release is a plain copy. No toolchains, no downloads, and
the binaries shipped are the ones that were tested.

| Path | Purpose | Version |
| --- | --- | --- |
| `macos-aarch64/libvulkan.a` | Vulkan loader, **linked statically** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |
| `macos-aarch64/libvulkan_kosmickrisp.dylib` | Vulkan driver, loaded at runtime | KosmicKrisp (Mesa), LunarG SDK 1.4.350.1 |
| `linux-x64/libvulkan.so` | Vulkan loader, **link time only** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |
| `windows-x64/vulkan.lib` | Vulkan import library, **link time only** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |

Together these mean a consumer needs **no Vulkan SDK** on any platform.

## How they get linked

By default, and with no configuration on either side — building cui, or building an
app against `cui.c3l`. c3c puts the target directory of a library on the linker
search path, and the manifest names `vulkan` for that target; the directory it picks
is the one matching what is being built.

This is why the choice is not made in project.json: it has no per-OS sections, and
listing every directory under `linker-search-paths` does not work either, because
each linker scans its own name patterns across all of them, finds another platform
library called `libvulkan` and fails to parse it. A library with a directory per
target is the mechanism c3c has for precisely this.

## Using your own Vulkan instead

Point `linker-search-paths` in project.json at your own Vulkan: it wins, because a
search path from the project is searched before the directory inside a library. Add
`-D SYSTEM_VULKAN` and cui also stops loading the driver it ships, leaving the
installed loader to find an installed driver as it normally would.

## Why macOS is different

A Vulkan driver is bound to the GPU and the kernel module, so on Linux and
Windows the machine's own driver is the only correct one — and it is always
installed already, along with the loader that finds it. Bundling one there would
be wrong, not merely wasteful.

The libraries shipped for those platforms are therefore **link-time only**:
`libvulkan.so` records `SONAME libvulkan.so.1` and `vulkan.lib` records
`vulkan-1.dll`, so at runtime the dynamic linker resolves to the machine's own
loader and driver. Nothing extra ships with the app.

macOS has no system Vulkan at all. There the loader is linked in statically — so
the binary carries no Vulkan dylib dependency whatsoever — and cui loads the
bundled driver itself, through `VK_LUNARG_direct_driver_loading` (see
`vk::loadDriver`): the driver's `vk_icdGetInstanceProcAddr` is handed straight to
the loader, needing no ICD manifest, no `VK_DRIVER_FILES`, and no installation.

`cui::vulkan` looks for the driver in this order, falling back to the loader's
own discovery — a system Vulkan install — when it finds nothing:

1. `$CUI_VULKAN_DRIVER`, an explicit path override
2. next to the running executable, where a distributed app keeps it
3. the folder c3c unpacks a `.c3l` into, so `c3c run` works straight after
   downloading `cui.c3l`
4. this folder, so the examples in the cui repository run from a clone

An app shipping a macOS binary to other machines should copy the dylib next to
its executable (2), the way a game ships its runtime libraries.

## Refreshing these

Run the **Vendor Vulkan libraries** workflow (Actions → run manually, giving a
Vulkan-Loader tag), download the `vulkan-libs` artifact, unzip it over this folder,
and commit. Note `gh run download` refuses to overwrite files that already
exist, so download to an empty directory and copy from there.

They cannot simply be downloaded from anywhere:

- the macOS **static** loader is published by nobody — the LunarG SDK ships only
  a dylib — so it must be built
- the Windows import library needs a Windows toolchain (or `llvm-dlltool`)
- only the Linux `.so` exists prebuilt (Debian's `libvulkan1`), and building it
  alongside the others keeps all three pinned to one loader version

The driver is separate: replace `libvulkan_kosmickrisp.dylib` by hand with a
newer build when you want one.

Note `.gitignore` ignores `*.a`, `*.lib`, `*.so` and `*.dylib` repo-wide; this
folder is exempted explicitly, or these files would be silently dropped from a
commit.

## Not covered

**Intel Macs** (`macos-x64`) and **ARM Linux** (`linux-aarch64`) get no bundled
library, so those targets link against a system Vulkan as before. Apple Silicon
is the only macOS target with a driver.

## Licensing

The Vulkan loader is Apache-2.0. KosmicKrisp is part of
[Mesa](https://gitlab.freedesktop.org/mesa/mesa) and is MIT-licensed —
redistribution is permitted with attribution.
