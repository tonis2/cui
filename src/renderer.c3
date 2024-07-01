module cui;
import std::io;
import std::collections::list;
import std::math;

import vk;
import glfw;
import stb;
import camera;

// Load shaders
char[*] vertex_shader_data = $embed("./shaders/vertex.spv");
char[*] fragment_shader_data = $embed("./shaders/fragment.spv");


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
	Instance instance;
	DebugUtilsMessengerEXT debug_messenger;
	PhysicalDevice physical_device;
	QueueFamily queue_family;
	Device device;

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

	vk::Format depth_format;
	vk::Image depth_image;
	DescriptorImageInfo depth_texture;

	MemoryBlock canvas_buffer;
	MemoryBlock uniform_buffer;

	vk::Allocation local_allocation;
	vk::Allocation device_allocation;

	DescriptorImages textures;
}

fault RendererErrors
{
    FAILED_CREATING_WINDOW,
}

fn Renderer! new(Vec2f window_size = {800, 600}, uint max_canvas = 1000) {

	ZStringList validations;
	ZStringList extensions;
	ZStringList device_extensions;

	defer {
		validations.free();
		extensions.free();
		device_extensions.free();
	}

    Camera camera = camera::new(.eye = {0.0, 0.0, 1.0}, .aspect = window_size.x / window_size.y, .min_zoom = 0.1, .max_zoom = 10);

    UniformBuffer uniform_data = {
        camera.perspective.transpose(),
        camera.view.transpose(),
        window_size
    };

	// Init GLFW window

	glfw::init();
    glfw::windowHint(glfw::GLFW_CLIENT_API, glfw::GLFW_NO_API);
    glfw::windowHint(glfw::GLFW_RESIZABLE, glfw::GLFW_FALSE);
    glfw::windowHint(glfw::CONTEXT_VERSION_MAJOR, 4);
    glfw::windowHint(glfw::CONTEXT_VERSION_MINOR, 1);

    GLFWwindow window = glfw::createWindow((uint)window_size.x, (uint)window_size.y, "cui window", null, null);

    if (window == null)
    {
        return RendererErrors.FAILED_CREATING_WINDOW?;
    }

	return Renderer {
		.camera = camera,
		.window_size = window_size,
		.window = window,
	};
}


fn void Renderer.free(&self) {
	self.images.free();
}