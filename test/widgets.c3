import std::io;
import cui;
import std::collections::list;
import glfw;
import std::math;
import camera;

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

    Column column = {
        .pos = {100.0, 100},
        .width = 200.0,
        .height = 200.0,
        .children = cui::widgets({
            &&Rectangle {
                .height = 50.0,
                .color = cui::BLUE
            }
        }),
    };

    CanvasContext canvas = {
        .size = window_size,
        .body = &column
    };

    defer canvas.free();

	Renderer renderer = cui::new(.window_size = window_size, .images = images)!;
	defer catch renderer.free();

	renderer.@on_frame(canvas.drawings; EventHandler events) {
        canvas.update();
	}!; 
}
