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

// A custom widget painting with the Painter primitives directly — circle,
// line, arc and rect_shadow — the way app-defined widgets are meant to.
// A gauge: shadowed face, tick marks, a track + value arc, and a needle.
struct Dial (Widget)
{
	Vec2 size;
	float value; // 0..1
}

fn Vec2 Dial.layout(&self, Element* elem, Constraints constraints) @dynamic => self.size.constrain(constraints);

fn void Dial.paint(&self, Element* elem, Painter* painter) @dynamic
{
	Vec2 center  = elem.size * 0.5f;
	float radius = math::min(elem.size.x, elem.size.y) * 0.5f - 16.0f;

	// The gauge spans 3/4 of a turn, opening at the bottom. Angles: 0 = +x,
	// clockwise on screen.
	float start = 0.75f * (float)math::PI;
	float span  = 1.5f * (float)math::PI;

	// Soft circular glow behind the face — a shadow is just a blurred rect,
	// and full-corner radii make it round. On a dark background a warm color
	// reads better than black.
	painter.rect_shadow(
		{ center.x - radius, center.y - radius },
		{ radius * 2.0f, radius * 2.0f },
		26.0f,
		{ 0.95, 0.60, 0.20, 0.35 },
		{ radius, radius, radius, radius }
	);

	painter.circle(
		center,
		radius,
		{ .color = { 0.13, 0.15, 0.19, 1.0 }, .border_width = 2.0f, .border_color = { 0.32, 0.35, 0.42, 1.0 }, }
	);

	// Tick lines around the rim.
	for (int i = 0; i <= 10; i++)
	{
		float angle = start + span * (float)i / 10.0f;
		Vec2 dir    = { math::cos(angle), math::sin(angle) };
		painter.line(center + dir * (radius - 16.0f), center + dir * (radius - 8.0f), 2.0f, { 0.45, 0.48, 0.56, 1.0 });
	}

	// Track arc, then the value arc over it.
	painter.arc(center, radius - 28.0f, start, span, 7.0f, { 0.22, 0.24, 0.30, 1.0 });
	painter.arc(center, radius - 28.0f, start, span * self.value, 7.0f, { 0.95, 0.60, 0.20, 1.0 });

	// Needle and hub.
	float needle_angle = start + span * self.value;
	Vec2 dir           = { math::cos(needle_angle), math::sin(needle_angle) };
	painter.line(center, center + dir * (radius - 34.0f), 3.0f, cui::WHITE);
	painter.circle(center, 7.0f, { .color = { 0.95, 0.60, 0.20, 1.0 } });
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
					.style = { .color = tile.color, .border_radius = { 8.0, 8.0, 8.0, 8.0 } },
				}
			)
		);
	}

	// Root: 24px of padding around a column that fills the window and centers
	// its content: a full-width textured header, two cards and the custom
	// Dial spread across the width by SPACE_BETWEEN, and the shelf.
	ui.build(
		ui.@node(
			(Padding) { .insets = widgets::insets_all(24.0) },
			ui.@node(
				(Column) { .gap = 24.0, .main_align = MainAlign.CENTER, .cross_align = CrossAlign.CENTER, },
				ui.@node(
					(Rectangle) {
						.size = { content_width, 96.0 },
						.style = { .texture = header_image, .border_radius = { 16.0, 16.0, 16.0, 16.0 } },
					}
				),
				ui.@node(
					(Row) { .size = { content_width, 0 }, .main_align = MainAlign.SPACE_BETWEEN },
					ui.@node(
						(Rectangle) {
							.size = { 260.0, 240.0 },
							.style = {
								.color = { 0.16, 0.45, 0.42, 1.0 },
								.border_radius = { 16.0, 16.0, 16.0, 16.0 }
							},
						}
					),
					ui.@node((Dial) { .size = { 260.0, 300.0 }, .value = 0.72 }),
					ui.@node(
						(Rectangle) {
							.size = { 260.0, 270.0 },
							.style = {
								.color = { 0.36, 0.28, 0.55, 1.0 },
								.border_radius = { 16.0, 16.0, 16.0, 16.0 },
								.border_width = 2.0,
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
