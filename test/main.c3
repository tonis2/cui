import std::io;
import cui;
import std::collections::list;
import std::math;

String[] images = {
	"test/assets/spirited.png",
	"test/assets/spirited_bg.jpg",
	"test/assets/howl.png",
	"test/assets/howl_bg.jpg",
	"test/assets/mono.png",
	"test/assets/mono_bg.jpg",
};

fn void main(String[] args)
{
	Vec2 window_size = { 900.0, 700.0 };

	Renderer renderer = cui::vulkan::new(window_size: window_size)!!;
	defer catch renderer.free();

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	// Widgets are owned by the app and must outlive their elements.
	Stack stack;
	Rectangle[6] cards;
	Element*[6] card_elements;

	Element* root = ui.mount(&stack);

	for (uint i = 0; i < 6; i += 2)
	{
		Vec2 box_size = { window_size.x / 3.5, window_size.y / 2 };
		float padding = 20.0;
		float offset  = padding + i * (box_size.x / 2 + padding);

		Texture character = renderer.load_image(images[i])!!;
		Texture backdrop  = renderer.load_image(images[i + 1])!!;

		// Backdrop card: bordered, rounded, textured with the *_bg image.
		cards[i] = {
			.size = box_size,
			.style = {
				.border_width = 2.0,
				.border_color = { 1.0, 1.0, 1.0, 1.0 },
				.border_radius = { 16.0, 16.0, 16.0, 16.0 },
				.color = { 0.1, 0.5, 0.4, 1.0 },
				.texture = backdrop,
			},
		};
		// Foreground card: the character png on top.
		cards[i + 1] = { .size = box_size, .style = { .texture = character }, };

		card_elements[i] = ui.mount(&cards[i], root);
		card_elements[i].set_offset({ offset, box_size.y / 3 });

		card_elements[i + 1] = ui.mount(&cards[i + 1], root);
		card_elements[i + 1].set_offset({ offset, box_size.y / 3 });
	}

	double x_rotation = -0.15;
	double y_rotation = -0.15;

	renderer.@on_frame(&ui.canvas ; FrameInput input)
	{
		x_rotation += input.mouse_x_delta * 0.005;
		y_rotation += input.mouse_y_delta * 0.005;

		// Transform-only animation: no layout or paint runs for this, each
		// card is a single matrix write into the palette.
		foreach (index, element : card_elements)
		{
			float rate = index % 2 == 0 ? 1.5f : 1.0f;
			element.set_transform(matrix::IDENTITY4.rotate_y((float)(x_rotation * rate))
				.rotate_x((float)(y_rotation * rate)));
		}

		ui.flush();
	}!!;
}
