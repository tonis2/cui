<*
 Reference backend: a standalone window + swapchain renderer for cui.

 Create one with `new`, then drive it with `frame(ui)` — it polls input,
 dispatches to the widgets, flushes the Ui, records the canvas as one instanced
 draw and presents:

     `Renderer renderer = vulkan::new(window_size)!!;`
     `while (renderer.frame(ui)!!) { }`

 This is a *host*: a window, a swapchain, an input pump and a frame loop wrapped
 around one `CanvasPass`, which is where all the actual interface drawing lives.
 An engine that already has a device and a frame loop skips Renderer entirely and
 drives a CanvasPass from its own — see canvas_pass.c3 and docs/embedding.md.

 The split is the point: the fiddly half of embedding cui is shared code both
 sides run, not a page of documentation to reimplement and get subtly wrong.
*>
module cui::vulkan;
import std::io;
import std::collections::list;
import std::math;
import std::time;

import cui;
import vk;
import c3w;
import cui::camera;
import image;
import image::png;

const MAX_FRAMES_IN_FLIGHT = 2;
const APP_NAME = "UI EXAMPLE";

// The canvas pass rotates its host-visible buffers over CANVAS_SLOTS copies and
// trusts the host to have waited for the frame that many submissions back before
// asking for an upload. `frame()` waits on frame_fences[frame_index], which is
// the frame MAX_FRAMES_IN_FLIGHT back — so raising the depth here without
// raising it there would put the memcpy back on top of a frame still drawing.
$assert MAX_FRAMES_IN_FLIGHT <= CANVAS_SLOTS :
    "CANVAS_SLOTS must cover MAX_FRAMES_IN_FLIGHT, or uploads tear frames in flight";

<*
 Upper bound on a frame delta, in seconds. A stall — or waking from an on-demand
 sleep after minutes idle — must not hand animations one enormous step. Also the
 usual spiral-of-death guard.
*>
const float MAX_FRAME_DT = 0.1;

<*
 How the reference frame loop paces itself.

 - CONTINUOUS — redraw every frame, poll input, run at the refresh rate of the
   display (FIFO present) forever. Lowest latency; a core stays busy. Right when
   something is always animating.
 - ON_DEMAND — after a frame, if nothing scheduled another (`ui.frame_requested`
   is clear), block for input: the thread sleeps at 0% CPU until the user does
   something. Right for mostly-static desktop UIs. A running animation keeps
   scheduling frames, so it still plays smoothly; the loop only sleeps once
   everything settles.
*>
enum LoopMode
{
    CONTINUOUS,
    ON_DEMAND,
}

<*
 Records app-owned draws into the frame, inside cui's render pass and before the
 UI is drawn over them. Set it on `Renderer.scene` (with `Renderer.scene_ctx` as
 the context pointer) and it runs once per `frame()`.

 This is the seam for 3D content under a cui interface. The depth attachment
 cui binds and clears every frame is never touched by cui's own pipeline
 (`enable_depth = false`), so a pipeline built with `enable_depth = true` and
 `RenderState.depth_format = Renderer.depth_format` gets correct occlusion for
 free, and the UI then composites on top untested. Build that pipeline against
 the Renderer's own `device`, `allocator`, `graphics_queue` and `extent` — one
 device, one swapchain, one render pass.

 The hook runs after `process_input`, so it sees this frame's input: update the
 camera at the top of it rather than in the frame loop body, which runs after
 the recording and would lag by a frame.

 Viewport and scissor are set before it and restored after, so scissoring to a
 sub-rect is safe. Any other dynamic state it changes is its own to restore;
 cui re-binds its pipeline, descriptors and push constants unconditionally.

 @param ctx : `Renderer.scene_ctx, verbatim.`
 @param cmd : `The frame's command buffer, inside a begun render pass.`
 @param extent : `The framebuffer size in physical pixels.`
*>
alias SceneRecorder = fn void?(void* ctx, CommandBuffer cmd, Extent2D extent);

<*
 The window, the Vulkan device and everything the frame loop needs — plus one
 `CanvasPass`, which owns everything about drawing the interface itself.

 Create with `new`, release with `free`.
*>
struct Renderer {
    // The interface itself. Everything about drawing a cui Canvas lives here —
    // pipeline, buffers, textures — and nothing about windows or presentation
    // does. An engine with its own device and frame loop skips Renderer and
    // drives one of these directly; see canvas_pass.c3.
    CanvasPass canvas;

	Vec2 window_size;   // logical pixels: UI coordinates, root constraints, mouse
    Extent2D extent;    // physical pixels: window_size * the window's scale
    // The ratio between those two, pushed into `Ui.pixel_ratio` every frame so
    // widgets can read it through `Element.media`. Sampled once, at creation:
    // it is the density the swapchain was built for, and reporting a live one
    // the framebuffer had not been rebuilt to match would be a lie a widget
    // could act on. A resize keeps it and derives the new `window_size` from it,
    // so the two stay consistent with the surface the layer actually has.
    float pixel_ratio;

	c3w::Window window;
    Clock frame_clock;
    cui::Cursor applied_cursor;
    List{cui::Key} key_scratch;
    LoopMode loop_mode;

    SceneRecorder scene;    // null = UI only, the default
    void* scene_ctx;        // passed to scene, untouched by cui
    float[4] clear_color;
    bool quit_on_escape;    // clear it to bind ESCAPE yourself

	Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	vk::DeviceQueue graphics_queue;
	Device device;

	vk::MemoryAllocator allocator;

    // A DescriptorImageInfo is sampler + view only, so the image behind it has
    // to be owned separately or nothing can destroy it. The swapchain's images
    // are deliberately absent: those belong to the swapchain.
    DescriptorImageInfo depth_texture;
    vk::Image depth_image;

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    vk::Format depth_format;

    CommandPool command_pool;
    CommandBufferList command_buffers;

    SurfaceKHR surface;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images;

    // What the swapchain is rebuilt from when the window changes size. The image
    // count is settled once, at creation, and reused: the per-image semaphores
    // and command buffers are sized by it and are deliberately NOT rebuilt on a
    // resize, because a semaphore a presentation engine may still be waiting on
    // is not safe to destroy — `vkDeviceWaitIdle` covers the queues, not the
    // presentation.
    SurfaceFormatKHR surface_format;
    ImageUsageFlags swapchain_usage;
    uint swapchain_image_count;

    uint frame_index;   // frame-in-flight slot, cycles mod MAX_FRAMES_IN_FLIGHT

    bool enable_debug;

    // Pending screenshot, serviced by frame() while the image is still ours.
    // The path is owned: request_screenshot is usually called from a key
    // handler with a formatted path, which would be gone by the time the grab
    // runs a frame later.
    String screenshot_path;
    bool screenshot_pending;
    bool screenshot_supported;  // false when the surface refused TRANSFER_SRC
}


<*
 Opens a window and brings up the whole Vulkan stack for it: instance, device,
 swapchain, buffers and pipeline.

 @param window_size : `The window content size in points; also the root constraints for the Ui. On a retina display the framebuffer is larger by the backing scale — everything renders at the display's native pixel density.`
 @param enable_debug : `Turn on the Vulkan validation layers and the debug messenger.`
 @param loop_mode : `Whether frame() redraws continuously or sleeps until input arrives.`
 @param clear_color : `RGBA the color attachment is cleared to each frame.`
 @param quit_on_escape : `Whether ESCAPE ends the frame loop. Clear it when the app binds ESCAPE itself — a 3D viewport usually wants it for cancel/deselect.`
 @return `The renderer, ready for frame(). Set its scene/scene_ctx fields to draw under the UI.`
*>
fn Renderer? new(Vec2 window_size = {800, 600}, bool enable_debug = false, LoopMode loop_mode = CONTINUOUS,
                 float[4] clear_color = {0.0, 0.0, 0.0, 1.0}, bool quit_on_escape = true) {

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

    Renderer renderer = {
        .frame_index = 0,
        .window_size = window_size,
        .enable_debug = enable_debug,
        .loop_mode = loop_mode,
        .clear_color = clear_color,
        .quit_on_escape = quit_on_escape,
    };

	defer {
		validations.free();
		extensions.free();
		device_extensions.free();
	}

    // Create the window first; the Vulkan surface is created from it.
    c3w::Window window = c3w::new(
        params: { .x = 0, .y = 0, .width = (int)window_size.x, .height = (int)window_size.y },
        name: APP_NAME
    )!;

    // Bind the Vulkan loader before anything asks Vulkan a question: every
    // command is a runtime-loaded pointer, and this is what loads the first of
    // them (see vendored.c3).
    init_loader()!;

    validations.push_all({"VK_LAYER_KHRONOS_validation"});
    device_extensions.push_all({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});
    extensions.push_all({"VK_KHR_surface"});

    // VK_KHR_portability_enumeration is implemented by the Vulkan loader, not by the
    // driver. A build that links a driver directly (no loader) does not advertise it,
    // so request it -- and the matching instance flag -- only when it is present.
    bool portability = false;

    // Surface extensions per-platform / backend (replaces glfw::getRequiredExtensions)
    $switch (env::OS_TYPE):
        $case MACOS:
            extensions.push("VK_EXT_metal_surface");
            ZStringList portability_probe;
            portability_probe.push("VK_KHR_portability_enumeration");
            if (catch vk::checkInstanceExtensionSupport(portability_probe))
            {
                portability = false;
            }
            else
            {
                portability = true;
                extensions.push("VK_KHR_portability_enumeration");
            }
            portability_probe.free();
        $case WIN32:
            extensions.push_all({"VK_KHR_win32_surface"});
        $case LINUX:
            switch (window.getBackend()) {
                case WAYLAND: extensions.push("VK_KHR_wayland_surface");
                case X11:     extensions.push("VK_KHR_xcb_surface");
                default:
            }
        $default:
    $endswitch

    if (enable_debug) {
     extensions.push("VK_EXT_debug_utils");
    }

    // If cui ships a driver (macOS), hand it straight to the loader rather than
    // relying on a system installation that may not exist. Both halves must hold:
    // a driver we can open, and a loader new enough to accept one.
    vk::DirectDriverLoadingInfoLUNARG bundled_driver;
    vk::DirectDriverLoadingListLUNARG bundled_drivers;
    bool direct_driver = false;

    if (try icd = find_bundled_driver())
    {
        if (vk::supportsDirectDriverLoading())
        {
            bundled_driver = vk::directDriverInfo(icd);
            bundled_drivers = vk::directDriverList(&bundled_driver, 1);
            extensions.push(vk::DIRECT_DRIVER_LOADING_EXTENSION_NAME);
            direct_driver = true;
        }
    }

    // Only meaningful against drivers the loader has already discovered: instance
    // extensions are enumerated before the instance exists, so a driver supplied at
    // create time is invisible here -- with nothing installed, even VK_KHR_surface
    // reads as unsupported. vkCreateInstance validates the list against the bundled
    // driver instead.
    if (!direct_driver) vk::checkInstanceExtensionSupport(extensions)!;

    ApplicationInfo app_info = {
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    };

    InstanceCreateInfo instance_info = vk::instanceCreateInfo()
    .setApplicationInfo(&app_info)
    .setFlags(portability ? vk::InstanceCreateFlagBits.INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : (vk::InstanceCreateFlags)0)
    .setEnabledExtensionNames(extensions.array_view());

    if (enable_debug) {
      instance_info.enabledLayerCount = (uint)validations.len();
      instance_info.ppEnabledLayerNames = (char*)validations.entries;
    }

    // Chained last: bundled_drivers must outlive the create call, and it does --
    // it lives in this frame, as does the instance_info it hangs off.
    if (direct_driver) instance_info.pNext = &bundled_drivers;

    Instance instance = instance_info.build()!;

    if (enable_debug) {
     renderer.debug_messenger = vk::setupDebugMessenger(instance)!;
    }

    // Create surface
    // Hand the window our vkGetInstanceProcAddr rather than letting it hunt for a
    // Vulkan dylib: the loader cui found (possibly its own bundled one) is not
    // necessarily the one a bare dlopen would land on.
    renderer.surface = (SurfaceKHR)window.create_vk_surface(
        instance,
        (c3w::VkGetInstanceProcAddrFn)vk::getInstanceProcAddr
    )!;

    // Pick a physical device + graphics queue
    vk::DeviceSelection selection = vk::selectPhysicalDevice(instance, renderer.surface, device_extensions)!;
    PhysicalDevice physical_device = selection.device;
    vk::DeviceQueue graphics_queue = { .index = selection.graphics_queue_index };

	// Feature pNext chain: query first (driver fills in support bits, including
	// shaderDrawParameters, buffer device address, dynamic rendering and
	// synchronization2), then hand the same chain to device creation so exactly
	// what the device supports gets enabled.
	PhysicalDeviceVulkan13Features v13_features = { .sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
	PhysicalDeviceVulkan12Features v12_features = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		.pNext = &v13_features,
	};
	PhysicalDeviceVulkan11Features v11_features = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		.pNext = &v12_features,
	};
	PhysicalDeviceFeatures2 device_features = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &v11_features,
	};

	vk::getPhysicalDeviceFeatures2(physical_device, &device_features);

	DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfo()
	.setQueueFamilyIndex(graphics_queue.index)
	.setQueuePriorities({1.0});

	Device device = vk::deviceCreateInfo()
		.setQueueCreateInfos({ graphicsInfo })
		.setEnabledExtensionNames(device_extensions.array_view())
		.setNext(&device_features)
		.build(physical_device)!;

	// Rebind device-level commands through vkGetDeviceProcAddr: calls then
	// dispatch straight into the driver instead of through the loader.
	vk::loadDeviceCommands(device);

	graphics_queue.handle = device.getQueue(graphics_queue.index);

	SurfaceFormatList surface_formats = renderer.surface.getFormats(physical_device)!;
	PresentModeList present_modes = renderer.surface.getPresentModes(physical_device)!;
	SurfaceCapabilitiesKHR capabilities = renderer.surface.deviceSurfaceCapabilities(physical_device)!;

	defer {
		surface_formats.free();
		present_modes.free();
	}

	vk::Format depth_format = vk::findDepthFormat(features: FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT, device: physical_device);
    SurfaceFormatKHR format = {.format = FORMAT_B8G8R8A8_UNORM, .colorSpace = COLOR_SPACE_SRGB_NONLINEAR_KHR};

    // Framebuffer at physical pixels: on a HiDPI output (Wayland scale > 1) the
    // window spans window_size logical units but scale times as many pixels, so
    // the swapchain, depth buffer and viewport are sized up by the window's
    // scale. Everything UI-facing stays logical — the shader's resolution
    // uniform, root constraints and mouse coordinates are untouched — the
    // drawings simply rasterize at the higher density, which is what makes SDF
    // text pixel-sharp instead of compositor-upscaled.
    float scale = window.get_scale();
    renderer.extent = {.width = (uint)(window_size.x * scale), .height = (uint)(window_size.y * scale) };
    renderer.pixel_ratio = scale;

    // Settled once and reused by every later rebuild — see the fields' own note
    // for why the image count in particular must not move.
    renderer.swapchain_image_count = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    renderer.surface_format = format;

    // TRANSFER_SRC lets request_screenshot copy a rendered image back to host
    // memory. Masked against what the surface actually supports, so a surface
    // that refuses it still gets a swapchain and only screenshots are lost.
    renderer.swapchain_usage = IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if ((ImageUsageFlagBits)capabilities.supportedUsageFlags & IMAGE_USAGE_TRANSFER_SRC_BIT) {
        renderer.swapchain_usage |= IMAGE_USAGE_TRANSFER_SRC_BIT;
        renderer.screenshot_supported = true;
    }

    // Assigned before the swapchain is built rather than at the end of `new`,
    // because `create_swapchain` reaches for them through `self`.
    renderer.instance = instance;
	renderer.physical_device = physical_device;
	renderer.graphics_queue = graphics_queue;
	renderer.device = device;
    renderer.depth_format = depth_format;

    // Create command pool
    renderer.command_pool = device.createCommandPool(queue: graphics_queue.index)!;
    renderer.command_buffers = device.createCommandBuffers(renderer.command_pool, renderer.swapchain_image_count)!;

    // Single allocator; per-buffer memory properties are chosen at new_buffer time.
    renderer.allocator = (vk::MemoryAllocator) {
        .device = device,
        .pdevice = physical_device,
        .queue = graphics_queue,
        .flags = MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT,
    }.init()!;

    // After the allocator, which the depth image's memory comes from.
    renderer.create_swapchain()!;

    // Everything about drawing the interface, in one object the host merely
    // owns. Built after the allocator and the depth texture because it borrows
    // the first and has to match the format of the second.
    renderer.canvas = new_canvas_pass(device, &renderer.allocator, graphics_queue,
        format.format, depth_format, window_size)!;

    // Acquire semaphores and fences are per frame slot; render-finished
    // semaphores are per swapchain image so one is never re-signaled while a
    // presentation of the same image may still wait on it.
    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        renderer.wait_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        renderer.frame_fences.push(vk::fenceCreateInfo().setFlags(FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }
    for (uint i = 0; i < renderer.swapchain_image_count; ++i) {
        renderer.signal_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
    }

    renderer.window = window;
    renderer.frame_clock = clock::now();

	return renderer;
}

<*
 Build the swapchain, its image views and the depth attachment at `self.extent`.

 Everything here is sized by that extent and by nothing else, which is what makes
 a resize `destroy_swapchain` + this. The per-image semaphores and command
 buffers are NOT built here: they are sized by `swapchain_image_count`, which is
 settled once in `new`.

 **The caller owns the ordering.** On a rebuild the device must be idle and the
 previous swapchain already destroyed; at creation the allocator must exist, since
 the depth image's memory comes from it.
*>
fn void? Renderer.create_swapchain(&self)
{
    // Re-queried rather than remembered: `currentTransform` is what the surface
    // wants *now*, and on a display that can rotate it is not what it was when
    // the first swapchain was built.
    SurfaceCapabilitiesKHR capabilities = self.surface.deviceSurfaceCapabilities(self.physical_device)!;

    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHR()
      .setMinImageCount(self.swapchain_image_count)
      .setImageUsage(self.swapchain_usage)
      .setImageSharingMode(SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(PRESENT_MODE_FIFO_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(self.surface_format.colorSpace)
      .setImageFormat(self.surface_format.format)
      .setSurface(self.surface)
      .setImageArrayLayers(1)
      .setImageExtent(self.extent);

    self.swapchain = swapchain_info.build(self.device)!;

    // Fetched into a scratch array rather than through `SwapchainKHR.getImages`,
    // which allocates one and never frees it — a leak per rebuild, and a rebuild
    // happens on every resize.
    uint count = self.swapchain_image_count;
    vk::Image[] images = mem::new_array(vk::Image, count);
    defer mem::free(images);
    vk::getSwapchainImagesKHR(self.device, self.swapchain, &count, images.ptr)!;

    for (uint i = 0; i < count; ++i) {
        self.swapchain_images.push(images[i]);
        self.swapchain_views.push(vk::imageViewCreateInfo()
        .setViewType(IMAGE_VIEW_TYPE_2D)
        .setFormat(self.surface_format.format)
        .setComponents({
            .r = COMPONENT_SWIZZLE_IDENTITY,
            .g = COMPONENT_SWIZZLE_IDENTITY,
            .b = COMPONENT_SWIZZLE_IDENTITY,
            .a = COMPONENT_SWIZZLE_IDENTITY,
        })
        .setSubresourceRange({
            .aspectMask = IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .levelCount = 1,
        })
        .setImage(images[i])
        .build(self.device)!);
    }

    self.depth_texture.createDepthTexture(&self.allocator, self.graphics_queue,
        { self.extent.width, self.extent.height }, self.depth_format, &self.depth_image)!;
}

<*
 Destroy everything `create_swapchain` made, leaving the lists empty and ready to
 be filled again.

 **The device must be idle.** Every object here can be in flight in a frame that
 has been submitted, and none of them is reference-counted by the driver.
*>
fn void Renderer.destroy_swapchain(&self)
{
    self.depth_texture.free(self.device);
    self.depth_image.free(self.device);

    // Views read images the swapchain owns, so they go first.
    foreach (view : self.swapchain_views) view.free(self.device);
    self.swapchain_views.clear();
    self.swapchain_images.clear();
    self.swapchain.free(self.device);
}


<*
 Uploads an image file (png/jpg) to the GPU and returns the handle to reference
 it with (`RectStyle.texture` / `CircleStyle.texture`).

 Forwards to the CanvasPass, which is where the texture array lives.

 @param path : `Path to a png or jpg file.`
 @return `The texture handle.`
*>
fn cui::Texture? Renderer.load_image(&self, String path)
{
    // adopt first: textures are usually loaded during setup, before the first
    // frame() has re-pointed the pass at this Renderer's allocator, and new()
    // returned the Renderer by value so the pass is still holding the address
    // of the local it was built in.
    self.canvas.adopt(&self.allocator);
    return self.canvas.load_image(path);
}

<*
 Uploads raw RGBA8 pixels (a generated atlas, say) and returns the handle to
 reference them with.

 @param rgba : `Tightly packed RGBA8 pixels, width * height * 4 bytes.`
 @param width : `Image width in pixels.`
 @param height : `Image height in pixels.`
 @return `The texture handle.`
*>
fn cui::Texture? Renderer.load_pixels(&self, char[] rgba, uint width, uint height)
{
    self.canvas.adopt(&self.allocator);
    return self.canvas.load_pixels(rgba, width, height);
}

<*
 Idles the GPU, then tears down everything `new` created: buffers, textures,
 swapchain, pipeline, device, window. The Ui is separate — free it with
 `Ui.free`.
*>
fn void Renderer.free(&self) {
    self.device.waitIdle();
    if (self.enable_debug) self.debug_messenger.free(self.instance);

    // Teardown is strictly inside-out, and each step here outlives the one
    // before it: a view reads an image, an image is bound to allocator memory.
    // The pass holds buffers and images of its own, so it goes before the
    // allocator its memory came from.
    self.canvas.adopt(&self.allocator);
    self.canvas.free();

    // Before the allocator: the depth image inside is bound to memory that came
    // out of it.
    self.destroy_swapchain();
    self.allocator.free();

    // `destroy_swapchain` empties the lists; this releases their storage.
    self.swapchain_images.free();
    self.swapchain_views.free();

    self.command_pool.free(self.device);

    self.wait_semaphores.release(self.device);
    self.signal_semaphores.release(self.device);
    self.frame_fences.release(self.device);
    self.surface.free(self.instance);

    self.device.free();
    self.instance.free();
    self.key_scratch.free();
    self.window.free();
}


<*
 Whether a c3w event key is really a mouse button. The EventMap of c3w mixes
 keyboard keys and mouse buttons; buttons feed `InputFrame.buttons`, everything
 else becomes a `cui::Key`.

 @param key : `The c3w event key.`
 @return `True for mouse buttons and wheel events.`
*>
fn bool is_mouse_key(c3w::EventKey key)
{
    switch (key) {
        case LEFT_MOUSE:
        case RIGHT_MOUSE:
        case MIDDLE_MOUSE:
        case MOUSE_SCROLL_UP:
        case MOUSE_SCROLL_DOWN:
        case MOUSE_4:
        case MOUSE_5:
            return true;
        default:
            return false;
    }
}

<*
 Maps a `cui::Cursor` to the c3w shape the window manager understands.

 @param cursor : `The cursor cui resolved for this frame.`
 @return `The matching c3w cursor shape.`
*>
fn c3w::CursorShape cursor_shape(cui::Cursor cursor)
{
    switch (cursor) {
        case DEFAULT:
        case ARROW:         return ARROW;
        case POINTING_HAND: return POINTING_HAND;
        case IBEAM:         return IBEAM;
        case CROSSHAIR:     return CROSSHAIR;
        case OPEN_HAND:     return OPEN_HAND;
        case CLOSED_HAND:   return CLOSED_HAND;
        case RESIZE_H:      return RESIZE_H;
        case RESIZE_V:      return RESIZE_V;
    }
}

<*
 Runs one frame: poll input, dispatch to the widgets, flush the Ui, record the
 canvas and present.

 The app owns the loop; per-frame logic goes in the body, reading `ui.input`
 directly:

     `while (renderer.frame(ui)!!)`
     `{`
     `    // app/game logic — mutations made here render on the next call`
     `}`

 In ON_DEMAND mode the call blocks for input when nothing scheduled a frame, so
 the loop body only runs when frames do — a game simulation that must tick every
 iteration wants CONTINUOUS.

 @param ui : `The Ui to drive. Its size tracks the window across resizes.`
 @require ui != null : `frame() needs a Ui.`
 @return `False when the user asked to quit (ESCAPE or window close).`
*>
fn bool? Renderer.frame(&self, Ui* ui)
{
    // new() returns the Renderer by value, so every &self.allocator the pass's
    // buffers captured at creation dangles once the struct is copied out.
    self.canvas.adopt(&self.allocator);

    // Sleep decision, made at the top of the frame so it sees everything since
    // the last frame began — input handlers, update() hooks, AND app code run
    // between frame() calls. ON_DEMAND with nothing scheduled → getEvent parks
    // the thread at 0% CPU until an event arrives. Ui.build/mount set
    // frame_requested, so the first frame always renders.
    bool wait_for_events = self.loop_mode == LoopMode.ON_DEMAND && !ui.frame_requested;

    c3w::EventMap event_map = self.window.getEvent(wait_for_events);
    if ((self.quit_on_escape && event_map.is_pressed(ESCAPE)) || self.window.should_close()) return false;

    // Anything from here on that schedules work (input handlers, update hooks,
    // app code before the next call) re-sets frame_requested; clear it first so
    // the next sleep decision reflects only that activity.
    ui.frame_requested = false;

    // Polled rather than driven by an event, because a resize is not one: on
    // macOS the whole drag runs inside AppKit's own tracking loop and nothing
    // here is reached until the mouse comes up, and c3w reports no resize event
    // on any platform. Asking the surface is the one question that has the same
    // answer everywhere.
    //
    // Ahead of the input dispatch and the flush, so the widgets are hit-tested
    // and laid out against the size this frame will actually be drawn at.
    Extent2D surface = self.surface_extent()!;
    if (surface.width != self.extent.width || surface.height != self.extent.height)
    {
        self.rebuild_surface(ui)!;
    }

    // Before anything can lay out or paint, so `Element.media` answers with this
    // window's density from the very first frame.
    ui.pixel_ratio = self.pixel_ratio;

    // Clamped so a long idle sleep (or a stall) doesn't advance animations
    // by the whole elapsed wall-clock in one step.
    float dt = math::min((float)self.frame_clock.mark().to_sec(), MAX_FRAME_DT);

    // c3w reports the pointer in Cocoa window coordinates (bottom-left
    // origin, points); cui works top-left.
    Vec2 raw_mouse = self.window.getMousePos();
    Vec2 mouse = { raw_mouse.x, self.window_size.y - raw_mouse.y };

    self.key_scratch.clear();
    event_map.@each(; c3w::EventKey key, bool held) {
        if (held && !is_mouse_key(key)) self.key_scratch.push((cui::Key)key.code);
    };

    // Feed the frame's input; the Ui updates ui.input, dispatches the
    // widget events, and runs update() hooks.
    ui.process_input({
        .mouse = mouse,
        .buttons = {
            event_map.is_pressed(LEFT_MOUSE),
            event_map.is_pressed(RIGHT_MOUSE),
            event_map.is_pressed(MIDDLE_MOUSE),
        },
        .scroll = self.window.get_scroll(),
        .scroll_x = self.window.get_scroll_x(),
        .scroll_precise = self.window.get_scroll_precise(),
        .text = self.window.get_text(),
        .keys_down = self.key_scratch.array_view(),
    }, dt);

    if (ui.cursor != self.applied_cursor) {
        self.applied_cursor = ui.cursor;
        self.window.set_cursor(cursor_shape(ui.cursor));
    }

    Fence frame_fence = self.frame_fences[self.frame_index];
    Semaphore wait_semaphore = self.wait_semaphores[self.frame_index];

    // Ahead of the upload, not after it. There are MAX_FRAMES_IN_FLIGHT fences
    // and slots alike, so this fence is the frame that last wrote the buffers
    // the upload is about to write, and waiting on it is the whole of what makes
    // them free. Uploading first hands the memcpy to a frame still on the GPU
    // and tears its display list — see CANVAS_SLOTS for what that looks like.
    frame_fence.wait(self.device)!;
    frame_fence.reset(self.device)!;

    // Flush and upload before any recording starts: this bakes glyphs, may grow
    // a buffer (which idles the GPU) and may rebuild the pipeline for a new
    // texture count — none of which belong in the middle of a command buffer.
    self.canvas.upload(ui, self.window_size)!;

    // Acquired by hand rather than through `SwapchainKHR.getNextImage`, which
    // asserts on every result it does not recognise: a swapchain the window has
    // outgrown reports itself here first, and that is a frame to skip and rebuild
    // from, not a crash. The timeout is infinite for the same reason — the
    // helper's is four seconds, and a timeout is not mapped to a fault, so it
    // would come back as success holding an index nothing wrote.
    uint next_image;
    if (catch fault error = vk::acquireNextImageKHR(self.device, self.swapchain,
        ulong::max, wait_semaphore, (Fence)null, &next_image))
    {
        if (error != vk::E_ERROR_OUT_OF_DATE_KHR) return error~;

        // The upload above advanced the canvas slot for a frame that is not going
        // to be submitted, so the rotation is now half a step out of phase with
        // the fences: the next upload would write the copy the frame BEFORE this
        // one is still reading, which is exactly the tear CANVAS_SLOTS exists to
        // prevent. Draining here puts it right, and costs nothing on a path that
        // only runs when the window has just changed size.
        self.device.waitIdle();

        // Nothing will be submitted this frame, and the fence was just reset —
        // so the next pass through this slot would wait for a frame that never
        // happened. An empty submit signals it and nothing else.
        vk::queueSubmit(self.graphics_queue.handle, 0, null, frame_fence)!;

        self.rebuild_surface(ui)!;
        return true;
    }
    Semaphore signal_semaphore = self.signal_semaphores[next_image];

    RenderingInfo rendering_info = vk::renderingInfo()
    .setLayerCount(1)
    .setRenderArea({
        .offset = { .x = 0, .y = 0 },
        .extent = self.extent,
    })
    .setColorAttachments({
        vk::renderingAttachmentInfo()
        .setImageView(self.swapchain_views[next_image])
        .setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        .setStoreOp(ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({
            .color = { .float32 = self.clear_color }
        })
    })
    .setDepthAttachment(&&vk::renderingAttachmentInfo()
        .setImageView(self.depth_texture.imageView)
        .setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
        .setStoreOp(ATTACHMENT_STORE_OP_STORE)
        .setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
        .setClearValue({
        .depthStencil = { 1.0f, 0 }
    }));

    CommandBuffer command_buffer = self.command_buffers[next_image];
    vk::resetCommandBuffer(command_buffer, (vk::CommandBufferResetFlags)0)!;
    vk::beginCommandBuffer(command_buffer, &&vk::commandBufferBeginInfo())!;

    ImageMemoryBarrier image_memory_start = vk::imageMemoryBarrier()
    .setDstAccessMask(ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
    .setOldLayout(IMAGE_LAYOUT_UNDEFINED)
    .setNewLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    .setImage(self.swapchain_images[next_image])
    .setSubresourceRange({
        .aspectMask = IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    });

    vk::cmdPipelineBarrier(
        command_buffer,
        PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        (DependencyFlags)0,
        0,
        null,
        0,
        null,
        1,
        &image_memory_start
    );

    vk::cmdBeginRenderingKHR(command_buffer, &rendering_info);

    vk::Viewport viewport = { .width = (float)self.extent.width, .height = (float)self.extent.height, .minDepth = 0.0, .maxDepth = 1.0, .y = 0, .x = 0 };
    vk::Rect2D scissor = { .extent = self.extent, .offset = { .x = 0, .y = 0 }};
    vk::cmdSetViewport(command_buffer, 0, 1, &viewport);
    vk::cmdSetScissor(command_buffer, 0, 1, &scissor);

    // App-owned 3D content goes into the depth buffer cui's own pipeline never
    // touches; the UI below composites over whatever it left behind. Viewport
    // and scissor are restored after, so the hook may scissor to a sub-rect.
    if (self.scene)
    {
        self.scene(self.scene_ctx, command_buffer, self.extent)!;
        vk::cmdSetViewport(command_buffer, 0, 1, &viewport);
        vk::cmdSetScissor(command_buffer, 0, 1, &scissor);
    }

    self.canvas.record(command_buffer, self.extent)!;

    vk::cmdEndRenderingKHR(command_buffer);

    // Record any pending screenshot copy here, while the image is still ours to
    // touch. Once queuePresentKHR below hands it over, it belongs to the
    // presentation engine and reading it is a spec violation even where it
    // happens to work.
    vk::Memory readback;
    bool grabbing = self.screenshot_pending;
    if (grabbing) readback = self.record_screenshot_copy(command_buffer, next_image)!;

    ImageMemoryBarrier image_memory_end = vk::imageMemoryBarrier()
    .setSrcAccessMask(ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
    .setOldLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    .setNewLayout(IMAGE_LAYOUT_PRESENT_SRC_KHR)
    .setImage(self.swapchain_images[next_image])
    .setSubresourceRange({
        .aspectMask = IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    });

    vk::cmdPipelineBarrier(
        command_buffer,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        (DependencyFlags)0,
        0,
        null,
        0,
        null,
        1,
        &image_memory_end
    );

    SubmitInfo submit_info = vk::submitInfo()
    .setWaitSemaphores({ wait_semaphore })
    .setCommandBuffers({ command_buffer })
    .setSignalSemaphores({ signal_semaphore })
    .setWaitDstStageMask({ PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT });

    vk::endCommandBuffer(command_buffer)!;
    vk::queueSubmit(self.graphics_queue.handle, 1, &submit_info, frame_fence)!;

    PresentInfoKHR present_info = vk::presentInfoKHR()
    .setWaitSemaphores({ signal_semaphore })
    .setSwapchains({ self.swapchain })
    .setImageIndices({ next_image });

    // The other end the window's new size can arrive from: the image was drawn
    // at the old one and is presented anyway — stretched by the compositor for
    // this one frame — and the rebuild happens below, once the frame is finished
    // with. Skipping the present instead would leave the acquired image
    // unreturned.
    bool stale = false;
    if (catch fault error = vk::queuePresentKHR(self.graphics_queue.handle, &present_info))
    {
        if (error != vk::E_ERROR_OUT_OF_DATE_KHR) return error~;
        stale = true;
    }

    if (grabbing)
    {
        defer readback.free();
        self.screenshot_pending = false;
        // Wait for the copy to land. The readback buffer is not a presentable
        // image, so reading it after the present is fine.
        self.device.waitIdle();
        self.write_screenshot(readback, self.screenshot_path)!;
        self.screenshot_path.free(mem);
        self.screenshot_path = "";
    }

    self.frame_index = (self.frame_index + 1) % MAX_FRAMES_IN_FLIGHT;

    // Last, so the frame's own bookkeeping is complete before the device is
    // idled and the swapchain replaced under it.
    if (stale) self.rebuild_surface(ui)!;
    return true;
}

<*
 The window's framebuffer size right now, in physical pixels.

 Read off the surface rather than off the window, because it is the surface the
 swapchain has to agree with and the two can disagree for a frame while a resize
 settles.

 A surface that declines to say — Wayland answers `0xFFFFFFFF`, meaning "whatever
 the swapchain asks for" — gets the extent already in use, so the caller sees no
 change and nothing is rebuilt. Resizing there needs the window's own size, which
 c3w does not report.

 @return `The surface's current extent, or the one in use where it has no answer.`
*>
fn Extent2D? Renderer.surface_extent(&self)
{
    SurfaceCapabilitiesKHR capabilities = self.surface.deviceSurfaceCapabilities(self.physical_device)!;
    if (capabilities.currentExtent.width == uint::max) return self.extent;
    return capabilities.currentExtent;
}

<*
 Rebuild the swapchain for the window's current size and re-lay the interface out
 in it.

 The one path a resize takes, whether it was noticed by the poll at the top of
 `frame()` or reported as `ERROR_OUT_OF_DATE_KHR` by the acquire or the present.
 The device is idled first: every image and view about to be destroyed can be in
 flight.

 `pixel_ratio` is kept rather than re-sampled, and the logical size derived from
 it, so `Ui.size` and the framebuffer stay two views of one number. A window
 dragged onto a display of a different density therefore keeps the density it was
 opened at — the layer's `contentsScale` is set once too, so that is the honest
 answer rather than a stale one.

 **Only callable between frames.** Nothing may be recorded or in flight against
 the swapchain this replaces; `frame()`'s three call sites are all outside a
 command buffer.

 @param ui : `Re-laid out at the new logical size, and asked for the frame that redraws into the new images.`
*>
fn void? Renderer.rebuild_surface(&self, Ui* ui)
{
    Extent2D extent = self.surface_extent()!;

    // Minimized, or on a space that is not showing: there is nothing to build a
    // swapchain for, and asking for a frame would spin the loop on an acquire
    // that keeps failing. The window system's next event is what brings it back.
    if (extent.width == 0 || extent.height == 0) return;

    self.device.waitIdle();
    self.destroy_swapchain();

    self.extent = extent;
    self.window_size = {
        (float)extent.width / self.pixel_ratio,
        (float)extent.height / self.pixel_ratio,
    };
    self.create_swapchain()!;

    // The Ui only re-lays out when the logical size actually moved, but the frame
    // is asked for either way: the images are new and hold nothing, so something
    // has to draw into them before anything is on screen.
    ui.resize(self.window_size);
    ui.request_frame();
}

<*
 Raised when a screenshot is requested on a surface that refused TRANSFER_SRC.
*>
faultdef SCREENSHOT_UNSUPPORTED;

<*
 Write the next completed frame to `path` as a PNG.

 The grab is serviced inside the next `frame()`, between the render pass ending
 and the present, because a presentable image may only be touched between
 vkAcquireNextImageKHR and vkQueuePresentKHR.

 This reads the rendered image rather than grabbing the OS window, so the result
 is exact: native framebuffer resolution, no title bar, no compositor colour
 management, and identical frame for frame. That is what makes it usable for
 before/after comparison and for checking a render from a script.

 One request is outstanding at a time; a second call before the first is
 serviced replaces it. `path` is copied.

 @param path : `Where to write the PNG. Copied, so a temporary is fine.`
*>
fn void Renderer.request_screenshot(&self, String path)
{
    if (self.screenshot_path.len > 0) self.screenshot_path.free(mem);
    self.screenshot_path = path.copy(mem);
    self.screenshot_pending = true;
}

<*
 Record the image-to-buffer copy into the frame's own command buffer.

 The image arrives in COLOR_ATTACHMENT_OPTIMAL and is handed back in it, so
 frame()'s usual present barrier still applies unchanged.
*>
fn vk::Memory? Renderer.record_screenshot_copy(&self, CommandBuffer command_buffer, uint image_index)
{
    if (!self.screenshot_supported) return SCREENSHOT_UNSUPPORTED~;

    vk::Image source = self.swapchain_images[image_index];
    ImageSubresourceRange range = {
        .aspectMask = IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };

    vk::Memory readback = vk::new_buffer(
        &self.allocator,
        usage: BUFFER_USAGE_TRANSFER_DST_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
        data_size: (sz)self.extent.width * (sz)self.extent.height * 4,
    )!;

    ImageMemoryBarrier to_transfer = vk::imageMemoryBarrier()
    .setSrcAccessMask(ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
    .setDstAccessMask(ACCESS_TRANSFER_READ_BIT)
    .setOldLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    .setNewLayout(IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    .setImage(source)
    .setSubresourceRange(range);

    vk::cmdPipelineBarrier(command_buffer,
        PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, PIPELINE_STAGE_TRANSFER_BIT,
        (DependencyFlags)0, 0, null, 0, null, 1, &to_transfer);

    // rowLength/imageHeight 0 means tightly packed to imageExtent.
    BufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { self.extent.width, self.extent.height, 1 },
    };
    vk::cmdCopyImageToBuffer(command_buffer, source, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback.buffer, 1, &region);

    ImageMemoryBarrier to_color = vk::imageMemoryBarrier()
    .setSrcAccessMask(ACCESS_TRANSFER_READ_BIT)
    .setDstAccessMask(ACCESS_COLOR_ATTACHMENT_WRITE_BIT)
    .setOldLayout(IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
    .setNewLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
    .setImage(source)
    .setSubresourceRange(range);

    vk::cmdPipelineBarrier(command_buffer,
        PIPELINE_STAGE_TRANSFER_BIT, PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        (DependencyFlags)0, 0, null, 0, null, 1, &to_color);

    return readback;
}

<*
 Swizzle the mapped copy into RGBA and write the PNG.
*>
fn void? Renderer.write_screenshot(&self, vk::Memory readback, String path)
{
    sz byte_size = (sz)self.extent.width * (sz)self.extent.height * 4;

    // The swapchain is created B8G8R8A8_UNORM, so the channels need swapping.
    // Alpha is forced opaque: the UI shader writes real alpha there, and a
    // half-transparent PNG of a finished frame is never what was wanted.
    char* mapped = readback.data();
    char[] pixels = mem::new_array(char, byte_size);
    defer free(pixels);

    for (sz i = 0; i < byte_size; i += 4) {
        pixels[i]     = mapped[i + 2];
        pixels[i + 1] = mapped[i + 1];
        pixels[i + 2] = mapped[i];
        pixels[i + 3] = 255;
    }

    image::Image picture = {
        .width = self.extent.width,
        .height = self.extent.height,
        .bit_depth = 8,
        .format = image::PixelFormat.RGBA,
        .pixels = pixels,
    };
    return png::save_file(&picture, path);
}
