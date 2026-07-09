import cui;
import std::math;

// Layout-widget example, built declaratively: the whole tree is described in
// one ui.build(...) expression, Flutter-style. Widgets passed to @node as
// struct literals are copied and owned by their element — no widget variables
// to keep alive. The shelf tiles show dynamic building with Element.append.
// 
// Compare with main.c3, which keeps app-owned widget structs (mount with a
// pointer) so it can mutate them and animate their elements every frame.
// 
// Run with: c3c run layout

struct TileSpec
{
	float height;
	Color color;
}

fn void main(String[] args)
{
	Vec2 window_size    = { 900.0, 700.0 };
	float content_width = window_size.x - 48.0f; // window minus 2 x 24 padding

	Renderer renderer = cui::vulkan::new(window_size: window_size)!!;
	defer catch renderer.free();

	// Images are uploaded to the renderer, which hands back the Texture
	// handle that widget styles reference.
	Texture header_image = renderer.load_image("test/assets/spirited_bg.jpg")!!;

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	// A shelf of small tiles: centered as a group, bottoms lined up by
	// CrossAlign.END inside the row's fixed height. Built in a loop and
	// appended, since the tiles only differ by data.
	Element* shelf = ui.@node(
		(Row) {
			.size = { content_width, 130.0 },
			.gap = 16.0,
			.main_align = MainAlign.CENTER,
			.cross_align = CrossAlign.END,
		}
	);

	TileSpec[4] tiles = {
		{ 60.0, { 0.50, 0.50, 0.55, 1.0 } },
		{ 130.0, { 0.65, 0.60, 0.30, 1.0 } },
		{ 90.0, { 0.35, 0.50, 0.65, 1.0 } },
		{ 110.0, { 0.60, 0.35, 0.40, 1.0 } },
	};

	foreach (tile : tiles)
	{
		shelf.append(
			ui.@node(
				(Rectangle) {
					.size = { 90.0, tile.height },
					.style = { .color = tile.color, .border_radius = { 0.6, 0.6, 0.6, 0.6 } },
				}
			)
		);
	}

	// Root: 24px of padding around a column that fills the window and centers
	// its content: a full-width textured header, three cards spread across
	// the width by SPACE_BETWEEN, and the shelf.
	ui.build(
		ui.@node(
			(Padding) { .insets = widgets::insets_all(24.0) },
			ui.@node(
				(Column) { .gap = 24.0, .main_align = MainAlign.CENTER, .cross_align = CrossAlign.CENTER, },
				ui.@node(
					(Rectangle) {
						.size = { content_width, 96.0 },
						.style = { .texture = header_image, .border_radius = { 1.0, 1.0, 1.0, 1.0 } },
					}
				),
				ui.@node(
					(Row) { .size = { content_width, 0 }, .main_align = MainAlign.SPACE_BETWEEN },
					ui.@node(
						(Rectangle) {
							.size = { 260.0, 240.0 },
							.style = { .color = { 0.16, 0.45, 0.42, 1.0 }, .border_radius = { 1.0, 1.0, 1.0, 1.0 } },
						}
					),
					ui.@node(
						(Rectangle) {
							.size = { 260.0, 300.0 },
							.style = { .color = { 0.75, 0.42, 0.16, 1.0 }, .border_radius = { 1.0, 1.0, 1.0, 1.0 } },
						}
					),
					ui.@node(
						(Rectangle) {
							.size = { 260.0, 270.0 },
							.style = {
								.color = { 0.36, 0.28, 0.55, 1.0 },
								.border_radius = { 1.0, 1.0, 1.0, 1.0 },
								.border_width = 1.0,
								.border_color = cui::WHITE
							},
						}
					)
				),
				shelf
			)
		)
	);

	renderer.@on_frame(&ui.canvas ; FrameInput input)
	{
		ui.flush();
	}!!;
}
