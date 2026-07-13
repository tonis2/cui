<*
 Reference backend: a standalone window + swapchain renderer for cui.

 Create one with `new`, then drive it with `frame(ui)` — it polls input,
 dispatches to the widgets, flushes the Ui, records the canvas as one instanced
 draw and presents:

     `Renderer renderer = vulkan::new(window_size)!!;`
     `while (renderer.frame(ui)!!) { }`

 Engines with their own device and frame loop implement the same steps against
 the exports in src/shader.c3 instead (see "Embedding in a Vulkan engine" in
 README.md); this module doubles as the worked example.
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

const MAX_FRAMES_IN_FLIGHT = 2;
const APP_NAME = "UI EXAMPLE";

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

// Initial GPU buffer capacities. Buffers are sized by what the UI actually
// draws: whenever an upload outgrows its buffer, the buffer is reallocated at
// the next power of two (see ensure_buffer_capacity).
const INITIAL_DRAWINGS = 64;
const INITIAL_TRANSFORMS = 16;
const INITIAL_CLIPS = 16;

<*
 The window, the Vulkan device and everything the frame loop needs. Owns the
 three device-address buffers the shader reads (drawings, transforms, clips) and
 the texture array. Create with `new`, release with `free`.
*>
struct Renderer {
	Camera camera;
	Vec2 window_size;
    Extent2D extent;

	c3w::Window window;
    Clock frame_clock;
    cui::Cursor applied_cursor;
    List{cui::Key} key_scratch;
    LoopMode loop_mode;

	Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	vk::DeviceQueue graphics_queue;
	Device device;

	vk::Memory canvas_buffer;
	vk::Memory transform_buffer;
	vk::Memory clip_buffer;
	vk::Memory uniform_buffer;

	vk::MemoryAllocator allocator;

	DescriptorImages textures;
    DescriptorImageInfo depth_texture;
    vk::Image atlas_image;      // the Ui's glyph atlas, once created (see sync_text)

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    RenderState pipeline;
    DescriptorSetLayout descriptor_layout;
    vk::Format depth_format;
    sz pipeline_texture_count;  // texture count the pipeline was built for;
                                // 0 = not built yet (see rebuild_pipeline)

    CommandPool command_pool;
    CommandBufferList command_buffers;

    SurfaceKHR surface;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images;

    uint frame_index;   // frame-in-flight slot, cycles mod MAX_FRAMES_IN_FLIGHT

    bool enable_debug;
}


<*
 Opens a window and brings up the whole Vulkan stack for it: instance, device,
 swapchain, buffers and pipeline.

 @param window_size : `The window content size in pixels; also the root constraints for the Ui.`
 @param enable_debug : `Turn on the Vulkan validation layers and the debug messenger.`
 @param loop_mode : `Whether frame() redraws continuously or sleeps until input arrives.`
 @return `The renderer, ready for frame().`
*>
fn Renderer? new(Vec2 window_size = {800, 600}, bool enable_debug = false, LoopMode loop_mode = CONTINUOUS) {

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

    Renderer renderer = {
        .frame_index = 0,
        .camera = camera::new(eye: {0.0, 0.0, 1.0}, aspect: window_size.x / window_size.y, min_zoom: 0.1, max_zoom: 10),
        .window_size = window_size,
        .enable_debug = enable_debug,
        .loop_mode = loop_mode,
    };

	defer {
		validations.free();
		extensions.free();
		device_extensions.free();
	}

    // Slang's cbuffer matrix layout expects column-major bytes relative to
    // Matrix4f's row-major storage, so matrices are uploaded transposed
    // (verified against the SPIR-V: clip w collapses to 0 otherwise).
    // ui_view() bakes in the scale that makes canvas coordinates pixel-exact
    // under the perspective projection.
    ShaderUniforms uniform_data = {
        renderer.camera.perspective.transpose(),
        renderer.camera.ui_view().transpose(),
        window_size
    };

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
    renderer.extent = {.width = (uint)window_size.x, .height = (uint)window_size.y };

    // Create swapchain
    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHR()
      .setMinImageCount(min_images)
      .setImageUsage(IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      .setImageSharingMode(SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(PRESENT_MODE_FIFO_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(format.colorSpace)
      .setImageFormat(format.format)
      .setSurface(renderer.surface)
      .setImageArrayLayers(1)
      .setImageExtent({ .width = (uint)window_size.x, .height = (uint)window_size.y });

    renderer.swapchain = swapchain_info.build(device)!;
    renderer.swapchain_images = renderer.swapchain.getImages(device, swapchain_info.minImageCount)!;

    for (uint i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfo()
        .setViewType(IMAGE_VIEW_TYPE_2D)
        .setFormat(format.format)
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
        .setImage(renderer.swapchain_images[i])
        .build(device)!;
        renderer.swapchain_views.push(view);
    }

    // Create command pool
    renderer.command_pool = device.createCommandPool(queue: graphics_queue.index)!;
    renderer.command_buffers = device.createCommandBuffers(renderer.command_pool, swapchain_info.minImageCount)!;

    // Single allocator; per-buffer memory properties are chosen at new_buffer time.
    renderer.allocator = (vk::MemoryAllocator) {
        .device = device,
        .pdevice = physical_device,
        .queue = graphics_queue,
        .flags = MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT,
    }.init()!;

    renderer.depth_texture.createDepthTexture(&renderer.allocator, graphics_queue, window_size, depth_format)!;
    renderer.depth_format = depth_format;

    // 1x1 white placeholder in texture slot 1 so the sampler-array binding is
    // never empty; user images get their handles from load_image/load_pixels.
    char[4] white_pixel = { 255, 255, 255, 255 };
    renderer.textures.load_rgba(white_pixel[..], 1, 1, &renderer.allocator, graphics_queue)!;

    // Uniform buffer (host visible) - uploaded at creation
    renderer.uniform_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: &uniform_data,
        data_size: ShaderUniforms::size,
    )!;

    // Retained display list + transform palette + clip list; re-uploaded only
    // when the widget layer marks them dirty.
    renderer.canvas_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: Drawing::size * INITIAL_DRAWINGS,
    )!;

    renderer.transform_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: Matrix4f::size * INITIAL_TRANSFORMS,
    )!;

    renderer.clip_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: ClipEntry::size * INITIAL_CLIPS,
    )!;

    // The descriptor layout and pipeline are built lazily on the first frame
    // (and rebuilt when textures are added) since the sampler-array binding is
    // sized by the texture count — see rebuild_pipeline.

    // Acquire semaphores and fences are per frame slot; render-finished
    // semaphores are per swapchain image so one is never re-signaled while a
    // presentation of the same image may still wait on it.
    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        renderer.wait_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        renderer.frame_fences.push(vk::fenceCreateInfo().setFlags(FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }
    for (uint i = 0; i < swapchain_info.minImageCount; ++i) {
        renderer.signal_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
    }

    renderer.instance = instance;
	renderer.physical_device = physical_device;
	renderer.graphics_queue = graphics_queue;
	renderer.device = device;

    renderer.window = window;
    renderer.frame_clock = clock::now();

	return renderer;
}


<*
 Uploads an image file (png/jpg) to the GPU and returns the handle to reference
 it with (`RectStyle.texture` / `CircleStyle.texture`).

 Textures can be loaded at any time; ones loaded between frames become valid on
 the next `frame()` call (the pipeline is rebuilt for the new sampler count at the
 top of a frame).

 @param path : `Path to a png or jpg file.`
 @return `The texture handle.`
*>
fn cui::Texture? Renderer.load_image(&self, String path)
{
    self.textures.loadPath(path, &self.allocator, self.graphics_queue)!;
    return (cui::Texture)self.textures.len();
}

<*
 Uploads raw RGBA8 pixels (a generated atlas, say) and returns the handle to
 reference them with.

 @param rgba : `Tightly packed RGBA8 pixels, width * height * 4 bytes.`
 @param width : `Image width in pixels.`
 @param height : `Image height in pixels.`
 @require rgba.len >= (usz)width * height * 4 : `The pixel buffer is smaller than width * height * 4 bytes.`
 @return `The texture handle.`
*>
fn cui::Texture? Renderer.load_pixels(&self, char[] rgba, uint width, uint height)
{
    self.textures.load_rgba(rgba, width, height, &self.allocator, self.graphics_queue)!;
    return (cui::Texture)self.textures.len();
}

<*
 (Re)creates the descriptor layout and pipeline for the current texture count.

 Runs before the first frame and again whenever `load_image` grew the texture
 array; the GPU is idled first, since in-flight frames still use the old pipeline.
*>
fn void? Renderer.rebuild_pipeline(&self)
{
    if (self.pipeline_texture_count > 0) {
        self.device.waitIdle();
        self.pipeline.free(self.device);    // also frees the descriptor layout
    }

    // Descriptor writes are rebuilt per-frame in frame() so the pBufferInfo /
    // pImageInfo pointers reference data that is alive at record time.
    self.descriptor_layout = vk::descriptorSetLayoutCreateInfo()
    .setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT)
    .setBindings({
        {
            .binding = 0,
            .descriptorType = DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT
        },
        {
            .binding = 1,
            .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = (uint)self.textures.len(),
            .stageFlags = SHADER_STAGE_FRAGMENT_BIT
        },
    }).build(self.device)!;

    self.pipeline = (RenderState) {
        .descriptor_layout = self.descriptor_layout,
        .shaders = {
            { .spirv = cui::shader_spirv[..], .entry = cui::SHADER_VERTEX_ENTRY, .stage = SHADER_STAGE_VERTEX_BIT },
            { .spirv = cui::shader_spirv[..], .entry = cui::SHADER_FRAGMENT_ENTRY, .stage = SHADER_STAGE_FRAGMENT_BIT },
        },
        .cull_mode = CULL_MODE_NONE,
        .front_face = FRONT_FACE_COUNTER_CLOCKWISE,
        .topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .enable_depth = false,
        .push_constants = {
            {
                .offset = 0,
                .size = ShaderPushConstants::size,
                .stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        .dynamic_states = {
            DYNAMIC_STATE_VIEWPORT,
            DYNAMIC_STATE_SCISSOR,
        },
        .blend_attachments = {
            {
                .colorWriteMask =
                    COLOR_COMPONENT_R_BIT |
                    COLOR_COMPONENT_G_BIT |
                    COLOR_COMPONENT_B_BIT |
                    COLOR_COMPONENT_A_BIT,
                .blendEnable = vk::TRUE,
                .srcColorBlendFactor = BLEND_FACTOR_SRC_ALPHA,
                .dstColorBlendFactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .colorBlendOp = BLEND_OP_ADD,
                .srcAlphaBlendFactor = BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .alphaBlendOp = BLEND_OP_ADD,
            }
        },
        .color_attachments = {
            FORMAT_B8G8R8A8_UNORM
        },
        .depth_format = self.depth_format
    }.build(self.device)!;

    self.pipeline_texture_count = self.textures.len();
}

<*
 Keeps the GPU copy of the Ui's glyph atlas in step with the CPU one.

 Before `flush` (with `creating` true): once the Ui has fonts, the atlas
 texture is created up front — paint caches drawings with the texture handle
 baked in, so the handle must exist before the first `Painter.text` runs.
 After `flush` (`creating` false): re-upload the pixels whenever glyph baking
 marked them dirty, so glyphs painted this frame are sampled this frame.

 @param ui : `The Ui whose text system to sync.`
 @param creating : `True for the pre-flush texture-creation step.`
*>
fn void? Renderer.sync_text(&self, Ui* ui, bool creating)
{
    cui::TextSystem* text = &ui.text;
    if (creating) {
        if (text.texture == cui::NO_TEXTURE && text.fonts.len() > 0) {
            self.textures.load_atlas(text.atlas, text.atlas_width, text.atlas_height,
                &self.allocator, self.graphics_queue, &self.atlas_image)!;
            text.texture = (cui::Texture)self.textures.len();
            text.dirty = false;
        }
        return;
    }
    if (text.dirty && text.texture != cui::NO_TEXTURE) {
        vulkan::update_atlas_image(self.atlas_image, text.atlas, text.atlas_width, text.atlas_height,
            false, &self.allocator, self.graphics_queue)!;
        text.dirty = false;
    }
}

<*
 Idles the GPU, then tears down everything `new` created: buffers, textures,
 swapchain, pipeline, device, window. The Ui is separate — free it with
 `Ui.free`.
*>
fn void Renderer.free(&self) {
    self.device.waitIdle();
    if (self.enable_debug) self.debug_messenger.free(self.instance);

    self.adopt_buffers();
    self.uniform_buffer.free();
    self.canvas_buffer.free();
    self.transform_buffer.free();
    self.clip_buffer.free();
    self.textures.free();
    self.allocator.free();

    self.swapchain.free(self.device);
    self.depth_texture.free(self.device);

    foreach (view : self.swapchain_views) view.free(self.device);

    self.swapchain_images.free();
    self.swapchain_views.free();

    self.command_pool.free(self.device);

    // RenderState.free also frees the descriptor layout it holds.
    if (self.pipeline_texture_count > 0) self.pipeline.free(self.device);

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
 Grows a device-address buffer to fit `needed` bytes, doubling so growth is rare.

 The GPU is idled first: frames in flight may still read the old buffer. Callers
 re-push the new address every frame, so nothing else needs to know the buffer
 moved.

 @param buffer : `The buffer to grow in place. Freed and reallocated when it is too small.`
 @param needed : `The size the next upload needs, in bytes.`
*>
fn void? Renderer.ensure_buffer_capacity(&self, vk::Memory* buffer, sz needed)
{
    if (needed <= buffer.size) return;

    sz new_size = buffer.size > 0 ? buffer.size : 1024;
    while (new_size < needed) new_size *= 2;

    self.device.waitIdle();
    buffer.free();
    *buffer = vk::new_buffer(
        &self.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: new_size,
    )!;
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
 Re-points the four owned buffers' allocator references at this Renderer.

 `new()` builds the Renderer as a local and returns it by value, so the
 `&renderer.allocator` each vk::Memory captured at creation dangles once the
 struct is copied out. Freeing through that stale pointer (buffer growth,
 shutdown) reads a garbage device. Called wherever a free may follow.
*>
fn void Renderer.adopt_buffers(&self)
{
    self.canvas_buffer.allocator = &self.allocator;
    self.transform_buffer.allocator = &self.allocator;
    self.clip_buffer.allocator = &self.allocator;
    self.uniform_buffer.allocator = &self.allocator;
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
    Canvas* canvas = &ui.canvas;
    self.adopt_buffers();

    // Sleep decision, made at the top of the frame so it sees everything since
    // the last frame began — input handlers, update() hooks, AND app code run
    // between frame() calls. ON_DEMAND with nothing scheduled → getEvent parks
    // the thread at 0% CPU until an event arrives. Ui.build/mount set
    // frame_requested, so the first frame always renders.
    bool wait_for_events = self.loop_mode == LoopMode.ON_DEMAND && !ui.frame_requested;

    c3w::EventMap event_map = self.window.getEvent(wait_for_events);
    if (event_map.is_pressed(ESCAPE) || self.window.should_close()) return false;

    // Anything from here on that schedules work (input handlers, update hooks,
    // app code before the next call) re-sets frame_requested; clear it first so
    // the next sleep decision reflects only that activity.
    ui.frame_requested = false;

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
        .text = self.window.get_text(),
        .keys_down = self.key_scratch.array_view(),
    }, dt);

    if (ui.cursor != self.applied_cursor) {
        self.applied_cursor = ui.cursor;
        self.window.set_cursor(cursor_shape(ui.cursor));
    }

    // Flush (build/layout/paint/emit) runs before command recording so glyphs
    // baked during paint can be uploaded — and the pipeline rebuilt for a new
    // atlas texture — inside the same frame.
    self.sync_text(ui, true)!;
    ui.flush();
    self.sync_text(ui, false)!;

    // First frame, or textures were added since: (re)build the pipeline
    // so the sampler-array binding matches the texture count.
    if (self.pipeline_texture_count != self.textures.len()) self.rebuild_pipeline()!;

    Fence frame_fence = self.frame_fences[self.frame_index];
    Semaphore wait_semaphore = self.wait_semaphores[self.frame_index];

    frame_fence.wait(self.device)!;
    frame_fence.reset(self.device)!;

    uint next_image = self.swapchain.getNextImage(self.device, wait_semaphore);
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
            .color = { .float32 = { 0.0, 0.0, 0.0, 1.0 }}
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

    vk::Viewport viewport = { .width = self.window_size.x, .height = self.window_size.y, .minDepth = 0.0, .maxDepth = 1.0, .y = 0, .x = 0 };
    vk::Rect2D scissor = { .extent = self.extent, .offset = { .x = 0, .y = 0 }};
    vk::cmdSetViewport(command_buffer, 0, 1, &viewport);
    vk::cmdSetScissor(command_buffer, 0, 1, &scissor);

    vk::cmdBindPipeline(command_buffer, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.pipeline);

    DescriptorBufferInfo[1] uniform_info = {
        { .buffer = self.uniform_buffer.buffer, .offset = 0, .range = ShaderUniforms::size },
    };
    WriteDescriptorSet[2] descriptor_writes = {
        vk::writeDescriptorSet()
        .setDescriptorType(DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo(uniform_info[..]),
        vk::writeDescriptorSet()
        .setDstBinding(1)
        .setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(self.textures.array_view()),
    };
    vk::cmdPushDescriptorSetKHR(command_buffer, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.pipeline_layout, 0, descriptor_writes.len, &descriptor_writes[0]);

    // Re-upload only what changed since the last frame, growing the
    // buffers to whatever the UI actually produced.
    sz draw_count = canvas.drawings.len();

    if (canvas.drawings_dirty) {
        if (draw_count > 0) {
            self.ensure_buffer_capacity(&self.canvas_buffer, Drawing::size * draw_count)!;
            self.canvas_buffer.upload(canvas.drawings.entries, Drawing::size * draw_count);
        }
        canvas.drawings_dirty = false;
    }

    if (canvas.transforms_dirty) {
        sz transform_count = canvas.transforms.len();
        if (transform_count > 0) {
            self.ensure_buffer_capacity(&self.transform_buffer, Matrix4f::size * transform_count)!;
            self.transform_buffer.upload(canvas.transforms.entries, Matrix4f::size * transform_count);
        }
        canvas.transforms_dirty = false;
    }

    if (canvas.clips_dirty) {
        sz clip_count = canvas.clips.len();
        if (clip_count > 0) {
            self.ensure_buffer_capacity(&self.clip_buffer, ClipEntry::size * clip_count)!;
            self.clip_buffer.upload(canvas.clips.entries, ClipEntry::size * clip_count);
        }
        canvas.clips_dirty = false;
    }

    ShaderPushConstants constant_data = {
        .drawings = self.canvas_buffer.address,
        .transforms = self.transform_buffer.address,
        .clips = self.clip_buffer.address,
    };
    vk::cmdPushConstants(command_buffer, self.pipeline.pipeline_layout, SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT, 0, ShaderPushConstants::size, &constant_data);

    // The whole canvas in one instanced draw; the vertex shader indexes
    // drawings by SV_InstanceID.
    if (draw_count > 0) vk::cmdDraw(command_buffer, 6, (uint)draw_count, 0, 0);

    vk::cmdEndRenderingKHR(command_buffer);

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

    vk::queuePresentKHR(self.graphics_queue.handle, &present_info)!;

    self.frame_index = (self.frame_index + 1) % MAX_FRAMES_IN_FLIGHT;
    return true;
}
