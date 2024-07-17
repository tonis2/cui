import std::io;
import cui;
import std::collections::list;
import glfw;
import std::math;
import camera;
import rgfw;
import vk;

String[] images = {
    "test/assets/spirited.png",
    "test/assets/spirited_bg.jpg",
    "test/assets/howl.png",
    "test/assets/howl_bg.jpg",
    "test/assets/mono.png",
    "test/assets/mono_bg.jpg",
};

fn void! main(String[] args)
{
	Vec2f window_size = {900.0, 700.0};

    rgfw::Window win = rgfw::createWindow("Vulkan Example", Rect {0, 0, 500, 500 }, rgfw::ALLOW_DND | rgfw::CENTER);

    $switch(env::OS_TYPE) 
        $case LINUX: {
            XcbSurfaceCreateInfoKHR createInfo = { 
                vk::STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR, 
                null, 
                0, 
                win.src.display, 
                0
            };
        }
        $case MACOS: {
            MacOSSurfaceCreateInfoMVK createInfo = { 
                vk::STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK, 
                null, 
                0, 
                win.src.window
            };
        }
        $case WIN32: {
            Win32SurfaceCreateInfoKHR createInfo = {
                vk::STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                null,
                0,
                win.src.window,
                win.src.hdc
            };
        }
        $default: {}
    $endswitch
}
