<*
 Where the Vulkan loader and the driver come from.

 Nothing links against Vulkan: the vk bindings resolve every command at runtime
 (see vk/loader.c3 in vulkan.c3l), so neither cui nor an app using it needs a
 Vulkan SDK to build — on any platform. What a program needs at runtime is a
 loader and a driver, and vulkan.c3l itself ships both for macOS — the one
 platform with no system Vulkan — in its `macos-aarch64/` directory: the LunarG
 loader, dlopened by `vk::init`, and the KosmicKrisp driver, handed to that
 loader through `VK_LUNARG_direct_driver_loading`. On Linux and Windows the
 machine's own loader and driver are used, since a driver is bound to the GPU
 and cannot be shipped.

 Finding those two files is vulkan.c3l's own job, and it needs no help: besides
 the executable directory and a system SDK, its last candidate is built from
 `$$FILEPATH` (`vk::c3l_root`), the compile-time path of its own source — so it
 locates its `macos-aarch64/` directory wherever the library ended up, whether
 that is a submodule under `lib/`, a downloaded `vulkan.c3l` c3c unpacked, or a
 plain clone. cui therefore ships no Vulkan binaries of its own; a consumer
 installs `vulkan.c3l` next to `cui.c3l` and both are found.

 All this file adds is the `$CUI_VULKAN_*` overrides, for pointing a build at a
 loader or driver of your own without rebuilding.

 See lib/vulkan.c3l/README.md.
*>
module cui::vulkan;
import std::os::env;
import vk;

<*
 The opt-out, for using a Vulkan of your own instead of the one vulkan.c3l
 ships. Build with `-D SYSTEM_VULKAN` (or add the feature to project.json) and
 cui stops looking for bundled candidates: `vk::init()` falls back to the
 platform default loader names, and the installed loader finds an installed
 driver exactly as it normally would.
*>
const bool SYSTEM_VULKAN @private = $feature(SYSTEM_VULKAN);

<*
 Bind the Vulkan loader. A `$CUI_VULKAN_LOADER` override comes first; without
 one, vk::init works through its own defaults — the executable directory, the
 `macos-aarch64/` directory vulkan.c3l ships, and a system SDK.

 @return? vk::LOADER_NOT_FOUND : `No loader anywhere — neither bundled nor installed.`
*>
fn void? init_loader() @if(env::DARWIN && !SYSTEM_VULKAN)
{
	String[1] candidates;
	usz count = 0;

	if (try override = env::tget_var("CUI_VULKAN_LOADER")) candidates[count++] = override;

	return vk::init(candidates[:count]);
}

<*
 No cui-specific candidates: either this is Linux or Windows, where the system
 loader is the only correct one, or SYSTEM_VULKAN asked cui to keep out of the
 way. `vk::init` opens the loader by its installed platform name.

 @return? vk::LOADER_NOT_FOUND : `No system loader installed.`
*>
fn void? init_loader() @if(!env::DARWIN || SYSTEM_VULKAN)
{
	return vk::init();
}

<*
 The driver for the instance's pNext chain: a `$CUI_VULKAN_DRIVER` override when
 one is set, otherwise the driver vulkan.c3l ships, found in its own directory.

 Finding nothing is not an error: the loader then discovers an installed driver
 itself, which is what happens when developing against a system Vulkan SDK.

 @return? vk::DRIVER_NOT_LOADED : `No bundled driver — fall back to the loader's own discovery.`
*>
fn vk::PFN_vkGetInstanceProcAddrLUNARG? find_bundled_driver() @if(env::DARWIN && !SYSTEM_VULKAN)
{
	if (try override = env::tget_var("CUI_VULKAN_DRIVER"))
	{
		if (try icd = vk::loadDriver(override)) return icd;
	}
	return vk::findBundledDriver();
}

<*
 No driver to load: either this is Linux or Windows, or SYSTEM_VULKAN asked cui
 to keep out of the way. The loader then discovers an installed driver in the
 usual manner, which is the only correct thing to do in both cases.

 @return? vk::DRIVER_NOT_LOADED : `Always — there is no bundled driver in this build.`
*>
fn vk::PFN_vkGetInstanceProcAddrLUNARG? find_bundled_driver() @if(!env::DARWIN || SYSTEM_VULKAN)
{
	return vk::DRIVER_NOT_LOADED~;
}
