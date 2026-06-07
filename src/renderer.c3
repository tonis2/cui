module cui;
import std::io;
import std::collections::list;
import std::math;

import vk;
import c3w;
import camera;

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");

const MAX_FRAMES_IN_FLIGHT = 2;
const APP_NAME = "UI EXAMPLE";

struct PushConstantData {
    uint draw_index;
    vk::DeviceAddress canvas;
}

struct UniformBuffer {
    Matrix4f perspective;
    Matrix4f view;
    Vec2 resolution;
}

// Yielded to the @on_frame body each frame.
struct FrameInput {
    float mouse_x_delta;
    float mouse_y_delta;
    c3w::EventMap events;
}

struct Renderer {
	Camera camera;
	Vec2 window_size;
    Extent2D extent;

	List{String} images;

	c3w::Window window;
    Vec2 prev_mouse;

	Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	vk::DeviceQueue graphics_queue;
	Device device;

	vk::Memory canvas_buffer;
	vk::Memory uniform_buffer;

	vk::MemoryAllocator allocator;

	DescriptorImages textures;
    DescriptorImageInfo depth_texture;

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    RenderState pipeline;
    DescriptorSetLayout descriptor_layout;

    CommandPool command_pool;
    CommandBufferList command_buffers;

    SurfaceKHR surface;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images;

    uint frame;

    bool enable_debug;
}


fn Renderer? new(Vec2 window_size = {800, 600}, String[] images, bool enable_debug = false) {

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

    Renderer renderer = {
        .frame = 0,
        .camera = camera::new(eye: {0.0, 0.0, 1.0}, aspect: window_size.x / window_size.y, min_zoom: 0.1, max_zoom: 10),
        .window_size = window_size,
        .enable_debug = enable_debug
    };

	defer {
		validations.free();
		extensions.free();
		device_extensions.free();
	}

    UniformBuffer uniform_data = {
        renderer.camera.perspective.transpose(),
        renderer.camera.view.transpose(),
        window_size
    };

    // Create the window first; the Vulkan surface is created from it.
    c3w::Window window = c3w::new(
        params: { .x = 0, .y = 0, .width = (int)window_size.x, .height = (int)window_size.y },
        name: APP_NAME
    )!;

    validations.push_all({"VK_LAYER_KHRONOS_validation"});
    device_extensions.push_all({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});
    extensions.push_all({"VK_KHR_surface"});

    // Surface extensions per-platform / backend (replaces glfw::getRequiredExtensions)
    $switch (env::OS_TYPE):
        $case MACOS:
            extensions.push_all({"VK_EXT_metal_surface", "VK_KHR_portability_enumeration"});
            device_extensions.push("VK_KHR_portability_subset");
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

    vk::checkInstanceExtensionSupport(extensions)!;

    ApplicationInfo app_info = {
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    };

    InstanceCreateInfo instance_info = vk::instanceCreateInfo()
    .setApplicationInfo(&app_info)
    .setFlags(env::os_is_darwin() ? vk::InstanceCreateFlagBits.INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : (vk::InstanceCreateFlags)0)
    .setEnabledExtensionNames(extensions.array_view());

    if (enable_debug) {
      instance_info.enabledLayerCount = (uint)validations.len();
      instance_info.ppEnabledLayerNames = (char*)validations.entries;
    }

    Instance instance = instance_info.build()!;
    vk::loadExtensions(instance);

    if (enable_debug) {
     renderer.debug_messenger = vk::setupDebugMessenger(instance)!;
    }

    // Create surface
    renderer.surface = (SurfaceKHR)window.create_vk_surface(instance)!;

    // Pick a physical device + graphics queue
    vk::DeviceSelection selection = vk::selectPhysicalDevice(instance, renderer.surface, device_extensions)!;
    PhysicalDevice physical_device = selection.device;
    vk::DeviceQueue graphics_queue = { .index = selection.graphics_queue_index };

	// Enable required device features (descriptor indexing, buffer device address,
	// dynamic rendering, synchronization2).
	PhysicalDeviceDescriptorIndexingFeatures device_indexing_feature = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
	};

	PhysicalDeviceBufferDeviceAddressFeatures buffer_device_feature = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
		.pNext = &device_indexing_feature,
		.bufferDeviceAddress = vk::TRUE,
		.bufferDeviceAddressCaptureReplay = vk::TRUE
	};

	PhysicalDeviceDynamicRenderingFeatures dynamic_rendering_feature = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		.pNext = &buffer_device_feature
	};

	PhysicalDeviceSynchronization2Features syncronisation2_feature = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		.pNext = &dynamic_rendering_feature,
		.synchronization2 = vk::TRUE
	};

	PhysicalDeviceFeatures2 device_features = {
		.sType = STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &syncronisation2_feature,
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
        .flags = MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
    }.init()!;

    // Create texture images on GPU
    renderer.depth_texture.createDepthTexture(&renderer.allocator, graphics_queue, window_size, depth_format)!;
    foreach (source : images) renderer.textures.loadPath(source, &renderer.allocator, graphics_queue)!;

    // Uniform buffer (host visible) - uploaded at creation
    renderer.uniform_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: &uniform_data,
        data_size: UniformBuffer::size,
    )!;

    // Canvas buffer carrying a shader device address; filled per-frame.
    renderer.canvas_buffer = vk::new_buffer(
        &renderer.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: Drawing::size * 1000,
    )!;

    // Descriptor writes are rebuilt per-frame in @on_frame so the pBufferInfo /
    // pImageInfo pointers reference data that is alive at record time.
    renderer.descriptor_layout = vk::descriptorSetLayoutCreateInfo()
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
            .descriptorCount = (uint)renderer.textures.len(),
            .stageFlags = SHADER_STAGE_FRAGMENT_BIT
        },
    }).build(device)!;

    renderer.pipeline = (RenderState) {
        .descriptor_layout = renderer.descriptor_layout,
        .vertex_spirv = vertex_shader_data[..],
        .fragment_spirv = fragment_shader_data[..],
        .cull_mode = CULL_MODE_NONE,
        .front_face = FRONT_FACE_COUNTER_CLOCKWISE,
        .topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .enable_depth = false,
        .push_constants = {
            {
                .offset = 0,
                .size = PushConstantData::size,
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
        .depth_format = depth_format
    }.build(device)!;


    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        renderer.wait_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        renderer.signal_semaphores.push(vk::semaphoreCreateInfo().build(device))!;
        renderer.frame_fences.push(vk::fenceCreateInfo().setFlags(FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

    renderer.instance = instance;
	renderer.physical_device = physical_device;
	renderer.graphics_queue = graphics_queue;
	renderer.device = device;

    renderer.window = window;

	return renderer;
}


fn void Renderer.free(&self) {
	self.images.free();

    self.device.waitIdle();
    if (self.enable_debug) self.debug_messenger.free(self.instance);

    self.uniform_buffer.free();
    self.canvas_buffer.free();
    self.textures.free();
    self.allocator.free();

    self.swapchain.free(self.device);
    self.depth_texture.free(self.device);

    foreach (view : self.swapchain_views) view.free(self.device);

    self.swapchain_images.free();
    self.swapchain_views.free();

    self.command_pool.free(self.device);

    self.descriptor_layout.free(self.device);
    self.pipeline.free(self.device);

    self.wait_semaphores.release(self.device);
    self.signal_semaphores.release(self.device);
    self.frame_fences.release(self.device);
    self.surface.free(self.instance);

    self.device.free();
    self.instance.free();
    self.window.free();
}


macro void? Renderer.@on_frame(self, List{Drawing} canvas; @body(FrameInput input))
{
    bool running = true;

    while (running) {
        c3w::EventMap event_map = self.window.getEvent();

        float dx = 0;
        float dy = 0;
        if (event_map.is_pressed(LEFT_MOUSE)) {
            Vec2 mouse_pos = self.window.getMousePos();
            dx = mouse_pos.x - self.prev_mouse.x;
            dy = mouse_pos.y - self.prev_mouse.y;
            self.prev_mouse = mouse_pos;
        }

        if (event_map.is_pressed(ESCAPE)) running = false;

        Fence frame_fence = self.frame_fences[self.frame];
        Semaphore wait_semaphore = self.wait_semaphores[self.frame];
        Semaphore signal_semaphore = self.signal_semaphores[self.frame];

        frame_fence.wait(self.device)!;
        frame_fence.reset(self.device)!;

        uint next_image = self.swapchain.getNextImage(self.device, wait_semaphore);

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
            { .buffer = self.uniform_buffer.buffer, .offset = 0, .range = UniformBuffer::size },
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

        @body((FrameInput){ .mouse_x_delta = dx, .mouse_y_delta = dy, .events = event_map });

        // Update canvas buffer
        self.canvas_buffer.upload(canvas.entries, canvas.byte_size());

        PushConstantData constant_data = {
            .draw_index = 0,
            .canvas = self.canvas_buffer.address,
        };

        // Draw scene
        foreach (uint index, item: canvas) {
            constant_data.draw_index = index;
            vk::cmdPushConstants(command_buffer, self.pipeline.pipeline_layout, SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT, 0, PushConstantData::size, &constant_data);
            vk::cmdDraw(command_buffer, 6, 1, 0, 0);
        }

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

        self.frame = (self.frame + 1) % 2;
	}
}
