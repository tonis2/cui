# Bundled Vulkan libraries

One `cui.c3l` builds an app on every platform: a `.c3l` holds a directory per
target, and c3c adds the matching one to the linker search path. This folder
mirrors that layout, so cutting a release is a plain copy — no toolchains, no
downloads, and the binaries shipped are exactly the ones that were tested.

| Path | Purpose | Version |
| --- | --- | --- |
| `macos-aarch64/libvulkan.a` | Vulkan loader, **linked statically** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |
| `macos-aarch64/libvulkan_kosmickrisp.dylib` | Vulkan driver, loaded at runtime | KosmicKrisp (Mesa), LunarG SDK 1.4.350.1 |
| `linux-x64/libvulkan.so` | Vulkan loader, **link time only** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |
| `windows-x64/vulkan.lib` | Vulkan import library, **link time only** | Vulkan-Loader `vulkan-sdk-1.4.350.1` |

Together these mean a consumer needs **no Vulkan SDK** on any platform.

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

An app shipping a macOS binary to other machines should copy the dylib next to
its executable (2), the way a game ships its runtime libraries.

## Refreshing these

Run the **Vendor Vulkan libraries** workflow (Actions → run manually, giving a
Vulkan-Loader tag), download the `vulkan-libs` artifact, unzip it over this
folder, and commit.

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
