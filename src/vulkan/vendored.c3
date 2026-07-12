<*
 Where the Vulkan library and the driver come from.

 cui ships a Vulkan library for every platform it covers, so that neither the
 examples nor an app using cui needs a Vulkan SDK installed. Nothing here has to
 ask for them: they are linked by default, on both sides of a release.

 - Building cui, they come from `lib/vulkanlibs.c3l` — a library that is nothing
   but a manifest and a directory of binaries per target. c3c puts the directory
   matching what you are building on the linker search path, and the manifest names
   `vulkan` for that target.
 - Building an app against the released cui.c3l, the very same binaries come out of
   the artifact the same way, since a .c3l holds a directory per target too.

 That is also why the choice cannot be made in project.json: it has no per-OS
 sections, and simply listing every directory as `linker-search-paths` does not
 work, because each linker scans its own name patterns across all of them, picks up
 another platform library named libvulkan, and fails to parse it. A library with a
 directory per target is the mechanism c3c has for exactly this.

 See lib/vulkanlibs.c3l/README.md.
*>
module cui::vulkan;
import std::os::env;
import vk;

<*
 The opt-out, for using a Vulkan of your own instead of the one cui ships.

 Point `linker-search-paths` in project.json at your own Vulkan and it wins: a
 search path from the project is searched before the directory inside a .c3l. Build
 with `-D SYSTEM_VULKAN` on top of that (or add the feature to project.json) and
 cui also stops loading the driver it ships, leaving the installed loader to find an
 installed driver exactly as it normally would.
*>
const bool SYSTEM_VULKAN @private = $feature(SYSTEM_VULKAN);

<*
 The Vulkan driver cui ships for macOS, the one platform with no system Vulkan at
 all — where the loader is linked in statically, and this is what it drives.
*>
const String BUNDLED_DRIVER @private @if(env::DARWIN && !SYSTEM_VULKAN) = "libvulkan_kosmickrisp.dylib";

<*
 Where cui looks for the driver it ships, most preferred first: an explicit
 `$CUI_VULKAN_DRIVER` override, next to the running executable (where a
 distributed app keeps it), the folder c3c unpacks a .c3l into (so a fresh
 `c3c run` works straight after downloading cui.c3l), and last the cui repository
 itself, so its own examples run from a clone with nothing installed.

 Finding nothing is not an error: the loader then discovers an installed driver
 itself, which is what happens when developing against a system Vulkan SDK.

 @return? vk::DRIVER_NOT_LOADED : `No bundled driver — fall back to the loader's own discovery.`
*>
fn vk::PFN_vkGetInstanceProcAddrLUNARG? find_bundled_driver() @if(env::DARWIN && !SYSTEM_VULKAN)
{
	String[4] candidates;
	usz count = 0;

	if (try override = env::tget_var("CUI_VULKAN_DRIVER")) candidates[count++] = override;
	if (try exe = env::executable_path())
	{
		if (try dir = exe.path_tdirname()) candidates[count++] = string::tformat("%s/%s", dir, BUNDLED_DRIVER);
	}
	// Relative to the working directory, which for `c3c run` is the project root.
	candidates[count++] = string::tformat("build/unpacked_c3l/cui.c3l/macos-aarch64/%s", BUNDLED_DRIVER);
	candidates[count++] = string::tformat("lib/vulkanlibs.c3l/macos-aarch64/%s", BUNDLED_DRIVER);

	return vk::findDriver(candidates[:count]);
}

<*
 No driver to load: either this is Linux or Windows, or SYSTEM_VULKAN asked cui to
 keep out of the way. The loader then discovers an installed driver in the usual
 manner, which is the only correct thing to do in both cases.

 Linux and Windows ship no driver on purpose: a driver is bound to the GPU and the
 kernel module, so the machine has the only correct one — and it is always installed
 already, along with the loader that finds it. The library linked there is therefore
 only ever used to resolve symbols. The SONAME recorded inside libvulkan.so, and the
 import records inside vulkan.lib, both name the system loader, so that is what
 runs. Nothing extra ships with the app.

 @return? vk::DRIVER_NOT_LOADED : `Always — there is no bundled driver in this build.`
*>
fn vk::PFN_vkGetInstanceProcAddrLUNARG? find_bundled_driver() @if(!env::DARWIN || SYSTEM_VULKAN)
{
	return vk::DRIVER_NOT_LOADED~;
}
