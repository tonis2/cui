import std::io;
import cui;
import std::collections::list;


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
	List(<Drawing>) canvas;
	defer canvas.free();
	
	canvas.new_init(.initial_capacity = 1000);

	Renderer renderer = cui::new(.window_size = {900.0, 700.0}, .canvas = canvas, .images = images)!;
	defer catch renderer.free();

	// renderer.draw(;window) {

	// }
	
}
