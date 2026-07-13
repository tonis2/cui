// SDF text demo: one font baked once at 48px serves every size below; all
// labels sample the same R8 atlas and render in the single instanced draw.
import std::io;
import cui;
import std::math;

fn void main(String[] args)
{
	Vec2 window_size = { 900.0, 700.0 };

	Renderer renderer = cui::vulkan::new(window_size: window_size)!!;
	defer catch renderer.free();

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	ui.load_font("lib/font.c3l/test/DejaVuSans.ttf")!!;

	Stack stack;
	Element* root = ui.mount(&stack);

	Label[8] labels;
	labels[0] = { .text = "CUI — SDF text rendering", .size = 34, .color = { 1.0, 1.0, 1.0, 1.0 } };
	labels[1] = { .text = "The quick brown fox jumps over the lazy dog 0123456789", .size = 16, .color = { 0.85, 0.85, 0.85, 1.0 } };
	labels[2] = { .text = "Kerning pairs: AV To Wa LT AA", .size = 22, .color = { 0.55, 0.78, 1.0, 1.0 } };
	labels[3] = { .text = "Unicode: déjà vu, naïve, café — arrows → ↑ ↓", .size = 22, .color = { 1.0, 0.82, 0.4, 1.0 } };
	labels[4] = { .text = "tiny 11px text from the same 48px bake stays readable", .size = 11, .color = { 0.75, 0.75, 0.75, 1.0 } };
	labels[5] = { .text = "BIG 72px", .size = 72, .color = { 0.4, 1.0, 0.62, 1.0 } };
	labels[6] = { .text = "@#$%&*(){}[]<>/\\|~^ +=–", .size = 18, .color = { 1.0, 0.5, 0.55, 1.0 } };
	labels[7] = { .text = "one atlas, one draw call", .size = 14, .color = { 0.65, 0.6, 1.0, 1.0 } };

	float y = 30;
	foreach (i, &label : labels)
	{
		Element* element = ui.mount(label, root);
		element.set_offset({ 30, y });
		y += label.size * 1.5f + 14;
	}

	while (renderer.frame(ui)!!) { }
}
