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

    for (uint i = 0; i < 6; i += 2) {
        Vec2f box_size = {window_size.x / 3.3, window_size.y / 2};
        float padding = 20.0;
        float offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .size = {box_size.x, box_size.y},
            .corner = {offset, box_size.y / 3},
            .border_width = 1.0,
            .border_color = {1.0, 1.0, 1.0, 1.0},
            .border_radius = {1.0, 1.0, 1.0, 1.0},
            .color = {0.1, 0.5, 0.4, 1.0},
            .texture_id = i + 1,
            .transform = MATRIX4F_IDENTITY
        });

        float corner_offset = padding + i * (box_size.x / 2 + padding);

        canvas.push({
            .size = {box_size.x, box_size.y}, 
            .corner = {offset, box_size.y / 3},
            .texture_id = i,
            .transform = MATRIX4F_IDENTITY
        });
    }

	Renderer renderer = cui::new(.window_size = window_size, .images = images)!;
	defer catch renderer.free();

    double x_rotation = -0.8;
    double y_rotation = -0.8;
	renderer.@on_frame(canvas; EventHandler events) {
        x_rotation += events.mouse_x_delta * 0.005;
        y_rotation += events.mouse_y_delta * 0.005;

        foreach (index, &item: canvas) {
            float offset = 10.0;
            if (index % 2 == 0) {
                item.transform = MATRIX4F_IDENTITY
                .rotate_y((float)x_rotation * 1.5)
                .rotate_x((float)y_rotation * 1.5);
            } else {
                item.transform = MATRIX4F_IDENTITY
                .rotate_y((float)x_rotation)
                .rotate_x((float)y_rotation);
            }
        }
	}!; 
	
}
