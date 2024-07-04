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

	List(<Drawing>) canvas;
	defer canvas.free();
	
	canvas.new_init(.initial_capacity = 1000);

	Matrix4f transform = camera::matrixRotation(Vec3f{0.0, 1.0, 0.0}, 0)
    .transpose();

    for (uint i = 0; i < 6; i += 2) {

        Vec2f box_size = {window_size.x / 3.3, window_size.y / 2};
        float padding = 20.0;
        float offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .type = 0,
            .size = {box_size.x, box_size.y},
            .corner = {offset, box_size.y / 3},
            .border_width = 1.0,
            .border_color = {1.0, 1.0, 1.0, 1.0},
            .border_radius = {1.0, 1.0, 1.0, 1.0},
            .color = {0.1, 0.5, 0.4, 1.0},
            .texture_id = i + 1,
            .transform = transform
        });

        float corner_offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .type = 0,
            .size = {box_size.x, box_size.y}, 
            .corner = {offset, box_size.y / 3},
            .texture_id = i,
            .transform = transform
        });
    }

	Renderer renderer = cui::new(.window_size = window_size, .canvas = canvas, .images = images)!;
	defer catch renderer.free();

	renderer.@draw(;EventHandler events) {
		
	}!;

	

	// renderer.draw(;window) {

	// }
	
}
