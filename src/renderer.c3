module cui;
import std::io;
import std::collections::list;
import std::math;

import vk;
import glfw;
import stb;
import camera;
import std::time;

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");

const ENABLE_VALIDATION_LAYERS = true;
const MAX_FRAMES_IN_FLIGHT = 2;
const APP_NAME = "UI EXAMPLE";

vk::Format depth_format;
// vk::Image depth_image;

struct PushConstantData {
    uint draw_index;
    vk::DeviceAddress canvas;
}

struct UniformBuffer {
    Matrix4f perspective;
    Matrix4f view;
    Vec2f resolution;
}

struct Renderer {
	Camera camera;
	Vec2f window_size;
	List(<String>) images;

	GLFWwindow window;
    EventHandler events;

	Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	QueueFamily queue_family;
	Device device;

	MemoryBlock canvas_buffer;
	MemoryBlock uniform_buffer;

	vk::Allocation local_allocation;
	vk::Allocation device_allocation;

	DescriptorImages textures;
    DescriptorImageInfo depth_texture;

    SemaphoreList wait_semaphores;
    SemaphoreList signal_semaphores;
    FenceList frame_fences;

    RenderState pipeline;
    DescriptorSetLayout descriptor_layout;
    WriteDescriptorSet[2] descriptor_writes;

    CommandPool command_pool;
    CommandBufferList command_buffers;

    SurfaceKHR surface;
    SwapchainKHR swapchain;
    ImageViewList swapchain_views;
    vk::ImageList swapchain_images;

    uint frame;
}

fault RendererErrors
{
    FAILED_CREATING_WINDOW,
    FAILED_FINDING_GPU
}

fn Renderer! new(Vec2f window_size = {800, 600}, List(<Drawing>) canvas, String[] images) {

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

    Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	QueueFamily queue_family;
	Device device;

    Renderer renderer = {
        .frame = 0,
        .camera = camera::new(.eye = {0.0, 0.0, 1.0}, .aspect = window_size.x / window_size.y, .min_zoom = 0.1, .max_zoom = 10)
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

	// Init GLFW window
	glfw::init();
    glfw::windowHint(glfw::GLFW_CLIENT_API, glfw::GLFW_NO_API);
    glfw::windowHint(glfw::GLFW_RESIZABLE, glfw::GLFW_FALSE);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 1);

    GLFWwindow window = glfw::createWindow((uint)window_size.x, (uint)window_size.y, "TEST", null, null);

    if (window == null)
    {
        return RendererErrors.FAILED_CREATING_WINDOW?;
    }

    renderer.window = window;
	renderer.events = { .window = window };
    renderer.events.init();

    validations.add_array({"VK_LAYER_KHRONOS_validation"});
    device_extensions.add_array({"VK_KHR_swapchain", "VK_KHR_push_descriptor", "VK_KHR_dynamic_rendering"});

    // SETUP extensions
    ZStringList glfw_extensions = glfw::getRequiredExtensions();
    extensions.add_all(&glfw_extensions);
    glfw_extensions.free();

    if (ENABLE_VALIDATION_LAYERS) {
     extensions.add_array({"VK_EXT_debug_utils"});
    }

    if (env::os_is_darwin()) {
      extensions.push("VK_KHR_portability_enumeration");
      device_extensions.push("VK_KHR_portability_subset");
    }

    vk::checkExtensionSupport(extensions)!;

    InstanceCreateInfo instanceInfo = vk::instanceCreateInfoBuilder()
    .setApplicationInfo(&&ApplicationInfo{
      .pApplicationName = "TEST",
      .pEngineName = "Super engine",
      .applicationVersion = vk::@makeApiVersion(0,1,0,0),
      .engineVersion = vk::@makeApiVersion(0,1,0,0),
      .apiVersion = vk::@makeApiVersion(0,1,3,0)
    })
    .setFlags(env::os_is_darwin() ? vk::INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0)
    .setEnabledExtensionNames(extensions.array_view());

    DebugUtilsMessengerCreateInfoEXT debug_info = vk::debugUtilsMessengerCreateInfoEXTBuilder()
        .setMessageSeverity(vk::DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        .setMessageType(vk::DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | vk::DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT)
        .setPfnUserCallback((PFN_vkDebugUtilsMessengerCallbackEXT)&vk::debugCallback);

    // Debug enabled
    if (ENABLE_VALIDATION_LAYERS) {
      vk::checkValidationLayersSupport(validations)!;
      instanceInfo.enabledLayerCount = (uint)validations.len();
      instanceInfo.ppEnabledLayerNames = (char*)validations.entries;
    }

    vk::createInstance(&instanceInfo, null, &instance)!;
    vk::loadExtensions(instance);

    if (ENABLE_VALIDATION_LAYERS) {
     renderer.debug_messenger = debug_info.build(instance)!;
    }

    renderer.surface = glfw::createWindowSurface(instance, window, null)!;

    bool found_device = false;
    // Macro to find a valid device
    instance.@requestDevice(;PhysicalDevice pdevice) {
      QueueFamily queue;
      // Check for device extension support
      bool supports_extensions = pdevice.checkExtensionSupport(device_extensions)!;
      QueuePropertiesList queue_properties = pdevice.getQueueProperties()!;

      queue.graphics = queue_properties.find(fn (usz index, QueueFamilyProperties props) => (usz)props.queueFlags & vk::QUEUE_GRAPHICS_BIT != 0);
      if (renderer.surface.checkSurfaceSupport(queue.graphics, pdevice)!) queue.present = queue.graphics;

      if (queue.is_ready() && supports_extensions) {
         physical_device = pdevice;
         queue_family = queue;
         found_device = true;
      }
    }!;

    if (!found_device) {
      io::printfn("Did not found suitable device!");
      return RendererErrors.FAILED_FINDING_GPU?;
    }

	// Setup Vulkan extensions configuration
    PhysicalDeviceProperties2 deviceProps2 = vk::physicalDeviceProperties2Builder()
                                                .setNext(&&vk::physicalDevicePushDescriptorPropertiesKHRBuilder().setMaxPushDescriptors(1));

	vk::getPhysicalDeviceProperties2(physical_device, &deviceProps2);

	PhysicalDeviceDescriptorIndexingFeatures device_indexing_feature = {
		.sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
	};

	PhysicalDeviceBufferDeviceAddressFeatures buffer_device_feature = {
		.sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_BUFFER_DEVICE_ADDRESS_FEATURES,
		.pNext = &device_indexing_feature,
		.bufferDeviceAddress = vk::TRUE,
		.bufferDeviceAddressCaptureReplay = vk::TRUE
	};

	PhysicalDeviceDynamicRenderingFeatures dynamic_rendering_feature = {
		.sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		.pNext = &buffer_device_feature
	};

	PhysicalDeviceSynchronization2Features syncronisation2_feature = {
		.sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		.pNext = &dynamic_rendering_feature,
		.synchronization2 = vk::TRUE
	};

	PhysicalDeviceFeatures2 device_features = {
		.sType = vk::STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
		.pNext = &syncronisation2_feature,
	};

	vk::getPhysicalDeviceFeatures2(physical_device, &device_features);

	DeviceQueueCreateInfo graphicsInfo = vk::deviceQueueCreateInfoBuilder()
	.setQueueFamilyIndex(queue_family.graphics)
	.setQueuePriorities({1.0});

	device = vk::deviceCreateInfoBuilder()
		.setQueueCreateInfos({ graphicsInfo })
		.setEnabledExtensionNames(device_extensions.array_view())
		.setNext(&device_features)
		.build(physical_device)!;

	queue_family.graphics_handle = device.getQueue(queue_family.graphics);

	SurfaceFormatList surface_formats = renderer.surface.getFormats(physical_device)!;
	PresentModeList present_modes = renderer.surface.getPresentModes(physical_device)!;
	SurfaceCapabilitiesKHR capabilities = renderer.surface.deviceSurfaceCapabilities(physical_device)!;

	defer {
		surface_formats.free();
		present_modes.free();
	}

	vk::Format depth_format = vk::findDepthFormat(.device = physical_device, .features = vk::FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
    SurfaceFormatKHR format = SurfaceFormatKHR {.format = vk::FORMAT_B8G8R8A8_UNORM, .colorSpace = vk::COLOR_SPACE_SRGB_NONLINEAR_KHR};

    // Create swapchain
    uint min_images = capabilities.maxImageCount != 0 ? capabilities.maxImageCount : capabilities.minImageCount + 2;
    SwapchainCreateInfoKHR swapchain_info = vk::swapchainCreateInfoKHRBuilder()
      .setMinImageCount(min_images)
      .setImageUsage(vk::IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      .setImageSharingMode(vk::SHARING_MODE_EXCLUSIVE)
      .setCompositeAlpha(vk::COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
      .setPresentMode(vk::PRESENT_MODE_MAILBOX_KHR)
      .setPreTransform(capabilities.currentTransform)
      .setImageColorSpace(format.colorSpace)
      .setImageFormat(format.format)
      .setSurface(renderer.surface)
      .setImageArrayLayers(1)
      .setImageExtent({ .width = (uint)window_size.x, .height = (uint)window_size.y });

    renderer.swapchain = swapchain_info.buildKHR(device)!;
    renderer.swapchain_images = renderer.swapchain.getImages(device, swapchain_info.minImageCount)!;

    for (int i = 0; i < swapchain_info.minImageCount; ++i) {
        ImageView view = vk::imageViewCreateInfoBuilder()
        .setViewType(vk::IMAGE_VIEW_TYPE_2D)
        .setFormat(format.format)
        .setComponents({
            .r = vk::COMPONENT_SWIZZLE_IDENTITY,
            .g = vk::COMPONENT_SWIZZLE_IDENTITY,
            .b = vk::COMPONENT_SWIZZLE_IDENTITY,
            .a = vk::COMPONENT_SWIZZLE_IDENTITY,
        })
        .setSubresourceRange({
            .aspectMask = vk::IMAGE_ASPECT_COLOR_BIT,
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
    CommandPool command_pool = device.createCommandPool(.queue = queue_family.graphics)!;
    CommandBufferList command_buffers = device.createCommandBuffers(command_pool, swapchain_info.minImageCount)!;

    // Create allocator of 50MB - DEVICE_ONLY memory
    renderer.device_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 50_000_000
    }.build()!;

    // Allocation where data can be changed from CPU
    renderer.local_allocation = vk::Allocation {
        .device = device,
        .pdevice = physical_device,
        .properties = vk::MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk::MEMORY_PROPERTY_HOST_CACHED_BIT,
        .flags = vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT | vk::MEMORY_ALLOCATE_DEVICE_ADDRESS_CAPTURE_REPLAY_BIT,
        .size = 20_000_000
    }.build()!;

    // Create texture images on GPU
    renderer.depth_texture.createDepthTexture(.allocator = &renderer.device_allocation, .queue = queue_family, .size = window_size, .format = depth_format)!;
    foreach (source : images) renderer.textures.loadPath(source, .allocator = &renderer.device_allocation, .queue = queue_family)!;

    // Create buffer placeholders
    renderer.uniform_buffer = vk::bufferCreateInfoBuilder()
        .setUsage(vk::BUFFER_USAGE_UNIFORM_BUFFER_BIT)
        .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
        .setSize(UniformBuffer.sizeof)
        .bind(&renderer.local_allocation)!;

    renderer.canvas_buffer = vk::bufferCreateInfoBuilder()
        .setUsage(vk::BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)
        .setSharingMode(vk::SHARING_MODE_EXCLUSIVE)
        .setSize(canvas.byte_size())
        .bind(&renderer.local_allocation)!;

    // Upload data to buffers
    renderer.uniform_buffer.upload(&uniform_data, UniformBuffer.sizeof, device);
    renderer.canvas_buffer.upload(canvas.entries, canvas.byte_size(), device);

    // Create vulkan pipeline stuff
    renderer.descriptor_writes = {
        vk::writeDescriptorSetBuilder()
        .setDescriptorType(vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo({
            {
                .buffer = renderer.uniform_buffer.buffer,
                .offset = 0,
                .range = UniformBuffer.sizeof,
            },
        }),
        vk::writeDescriptorSetBuilder()
        .setDstBinding(1)
        .setDescriptorType(vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(renderer.textures.array_view()),
    };

    renderer.descriptor_layout = vk::descriptorSetLayoutCreateInfoBuilder()
    .setFlags(vk::DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR)
    .setBindings({
        {
            .binding = 0,
            .descriptorType = vk::DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT
        },
        {
            .binding = 1,
            .descriptorType = vk::DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = (uint)renderer.textures.len(),
            .stageFlags = vk::SHADER_STAGE_FRAGMENT_BIT
        },
    }).build(device)!;

    renderer.pipeline = RenderState {
        .descriptor_layout = renderer.descriptor_layout,
        .shader = device.createShader(.vertex = &vertex_shader_data, .fragment = &fragment_shader_data)!,
        .cull_mode = vk::CULL_MODE_NONE,
        .front_face = vk::FRONT_FACE_COUNTER_CLOCKWISE,
        .topology = vk::PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .enable_depth = false,
        .push_constants = {
            {
                .offset = 0,
                .size = PushConstantData.sizeof,
                .stageFlags = vk::SHADER_STAGE_VERTEX_BIT | vk::SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        .dynamic_states = {
            vk::DYNAMIC_STATE_VIEWPORT,
            vk::DYNAMIC_STATE_SCISSOR,
        },
        .blend_attachments = {
            {
                .colorWriteMask =
                    vk::COLOR_COMPONENT_R_BIT |
                    vk::COLOR_COMPONENT_G_BIT |
                    vk::COLOR_COMPONENT_B_BIT |
                    vk::COLOR_COMPONENT_A_BIT,
                .blendEnable = vk::TRUE,
                .srcColorBlendFactor = vk::BLEND_FACTOR_SRC_ALPHA,
                .dstColorBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .colorBlendOp = vk::BLEND_OP_ADD,
                .srcAlphaBlendFactor = vk::BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = vk::BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .alphaBlendOp = vk::BLEND_OP_ADD,
            }
        },
        .color_attachments = {
            vk::FORMAT_B8G8R8A8_UNORM
        },
        .depth_format = depth_format
    }.build(device)!;


    for (uint i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        renderer.wait_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        renderer.signal_semaphores.push(vk::semaphoreCreateInfoBuilder().build(device))!;
        renderer.frame_fences.push(vk::fenceCreateInfoBuilder().setFlags(vk::FENCE_CREATE_SIGNALED_BIT).build(device))!;
    }

    Clock time = clock::now();

	return renderer;
}


fn void Renderer.free(&self) {
	self.images.free();


    self.device.waitIdle();
    if (ENABLE_VALIDATION_LAYERS) self.debug_messenger.free(self.instance);

    self.device_allocation.free();
    self.local_allocation.free();
    self.textures.free();

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
}