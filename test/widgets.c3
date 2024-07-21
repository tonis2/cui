import std::io;
import std::collections::list;
import std::math;
import xlib;
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

    xlib::initThreads();

    xlib::Display display = xlib::openDisplay(null);

    assert(display != null);
    
    xlib::Screen screen = xlib::defaultScreen(display);

    assert(screen != null);
}
