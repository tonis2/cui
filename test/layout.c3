import cui;
import std::math;
import std::io;

// Layout-widget example, built declaratively: the whole tree is one
// @canvas(ui) block — @tree nests a container, @node adds a leaf, and the
// nesting of the code is the nesting of the tree. Widgets passed as struct
// literals are copied and owned by their element — no widget variables to
// keep alive. The shelf tiles show a plain loop inside a @tree body.
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
// 
// Also the worked example of the event callbacks: drag or scroll on it to
// set the value, click to focus it, then nudge with the arrow keys.
struct Dial (Widget)
{
	Vec2 size;
	float value; // 0..1
	bool dragging; // between PRESS and RELEASE on this widget
}

// The gauge spans 3/4 of a turn, opening at the bottom. Angles: 0 = +x,
// clockwise on screen.
const float DIAL_START = 0.75 * math::PI;
const float DIAL_SPAN  = 1.5 * math::PI;

fn Vec2 Dial.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = Cursor.OPEN_HAND;
	return self.size.constrain(constraints);
}

// Point the needle at the pointer: angle of the element-local position
// around the center, mapped into the gauge's arc.
fn void Dial.drag(&self, Element* elem, Vec2 local)
{
	Vec2 d    = local - elem.size * 0.5f;
	float rel = math::atan2(d.y, d.x) - DIAL_START;
	while (rel < 0) rel += 2.0f * (float)math::PI;
	if (rel > DIAL_SPAN)
	{
		// The dead zone at the bottom: snap to the closer end.
		self.value = rel - DIAL_SPAN > 0.25f * (float)math::PI ? 0.0f : 1.0f;
	}
	else
	{
		self.value = rel / DIAL_SPAN;
	}
	elem.request_paint();
}

fn bool Dial.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.dragging = true;
			self.drag(elem, event.pos);
			return true; // consuming the press captures the drag
		case MOVE:
			// Only drag between our own PRESS and RELEASE — a button held
			// down elsewhere must not steer the dial as the pointer passes.
			if (!self.dragging) return false;
			self.drag(elem, event.pos);
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			return true;
		case SCROLL:
			self.value = math::clamp(self.value + event.scroll * 0.005f, 0.0f, 1.0f);
			elem.request_paint();
			return true;
		default:
			return false;
	}
}

// Clicking the dial focuses it (it implements on_key); arrows nudge it.
fn bool Dial.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	switch (event.key)
	{
		case Key.LEFT_ARROW: self.value = math::clamp(self.value - 0.05f, 0.0f, 1.0f);
		case Key.RIGHT_ARROW: self.value = math::clamp(self.value + 0.05f, 0.0f, 1.0f);
		default: return false;
	}
	elem.request_paint();
	return true;
}

fn void Dial.paint(&self, Element* elem, Painter* painter) @dynamic
{
	Vec2 center  = elem.size * 0.5f;
	float radius = math::min(elem.size.x, elem.size.y) * 0.5f - 16.0f;

	float start = DIAL_START;
	float span  = DIAL_SPAN;

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

// Button callbacks are handed the Ui they're rendered in — passed automatically
// from the button's own element, so there's no global and no app-threaded
// handle. ui.@modify(Dial; d) resolves the Dial's element once, hands the body a
// Dial* to mutate, then repaints that element — a single tree walk, no context
// threaded in, the way a Flutter callback reaches other widgets through its own.
fn void reset_dial(Ui* ui)
{
	ui.@modify(Dial; d)
	{
		d.value = 0.0;
		io::printfn("[layout] reset clicked -> %.2f", d.value);
	};
}

fn void bump_dial(Ui* ui)
{
	ui.@modify(Dial; d)
	{
		d.value = math::clamp(d.value + 0.1f, 0.0f, 1.0f);
		io::printfn("[layout] bump clicked -> %.2f", d.value);
	};
}

// The id twin, for when a bare type lookup is ambiguous: the tree holds many
// Rectangles, so @modify(Rectangle) would hit the header. @modify_id names the
// one stamped "teal" — resolved once, mutated, repainted.
fn void recolor_card(Ui* ui)
{
	ui.@modify_id("teal", Rectangle; card)
	{
		Vec4 c = (Vec4)card.style.color;
		card.style.color = c.y > c.x ? (Color) { 0.55, 0.30, 0.50, 1.0 } : (Color) { 0.16, 0.45, 0.42, 1.0 };
		io::printfn("[layout] recolor teal card");
	};
}

fn void main(String[] args)
{
	Vec2 window_size    = { 900.0, 700.0 };
	float content_width = window_size.x - 48.0f; // window minus 2 x 24 padding

	// ON_DEMAND: this UI only changes when the user interacts, so the loop
	// sleeps at 0% CPU when idle and wakes on input — the way a desktop app
	// should behave. (main.c3 leaves the default CONTINUOUS: its cards animate
	// every frame.) Dragging the dial still streams mouse events, so it stays
	// smooth; the loop only parks once everything settles.
	Renderer renderer = cui::vulkan::new(window_size: window_size, loop_mode: ON_DEMAND)!!;
	defer catch renderer.free();

	// Images are uploaded to the renderer, which hands back the Texture
	// handle that widget styles reference.
	Texture header_image = renderer.load_image("test/assets/spirited_bg.jpg")!!;

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	TileSpec[4] tiles = {
		{ 60.0, { 0.50, 0.50, 0.55, 1.0 } },
		{ 130.0, { 0.65, 0.60, 0.30, 1.0 } },
		{ 90.0, { 0.35, 0.50, 0.65, 1.0 } },
		{ 110.0, { 0.60, 0.35, 0.40, 1.0 } },
	};

	// Root: 24px of padding around a column that fills the window and centers
	// its content: a full-width textured header, two cards and the custom
	// Dial spread across the width by SPACE_BETWEEN, the shelf, and the
	// button row.
	@canvas(ui)
	{
		@tree((Padding) { .insets = widgets::insets_all(24.0) })
		{
			@tree((Column) { .gap = 24.0, .main_align = CENTER, .cross_align = CENTER, })
			{
				// The full-width textured header.
				@node(
					(Rectangle) {
						.size = { content_width, 96.0 },
						.style = { .texture = header_image, .border_radius = { 16.0, 16.0, 16.0, 16.0 } },
					}
				);

				@tree((Row) { .size = { content_width, 0 }, .main_align = SPACE_BETWEEN })
				{
					// Element.cursor gives any element a pointer shape
					// declaratively — no widget code involved.
					// .with_id names this node so a button callback can reach
					// this exact rectangle among the many in the tree —
					// get_widget(Rectangle) would return the header, the first
					// one. The id chains onto the @node expression.
					Element* teal_card = @node(
						(Rectangle) {
							.size = { 260.0, 240.0 },
							.style = { .color = { 0.16, 0.45, 0.42, 1.0 }, .border_radius = { 16.0, 16.0, 16.0, 16.0 } },
						}
					).with_id("teal");
					teal_card.cursor = Cursor.POINTING_HAND;

					@node((Dial) { .size = { 260.0, 300.0 }, .value = 0.72 });

					@node(
						(Rectangle) {
							.size = { 260.0, 270.0 },
							.style = {
								.color = { 0.36, 0.28, 0.55, 1.0 },
								.border_radius = { 16.0, 16.0, 16.0, 16.0 },
								.border_width = 2.0,
								.border_color = cui::WHITE
							},
						}
					);
				};

				// A shelf of small tiles: centered as a group, bottoms lined up
				// by CrossAlign.END inside the row's fixed height. A plain loop,
				// since the tiles only differ by data.
				@tree((Row) { .size = { content_width, 130.0 }, .gap = 16.0, .main_align = CENTER, .cross_align = END, })
				{
					foreach (tile : tiles)
					{
						@node(
							(Rectangle) {
								.size = { 90.0, tile.height },
								.style = { .color = tile.color, .border_radius = { 8.0, 8.0, 8.0, 8.0 } },
							}
						);
					}
				};

				// Three unlabeled buttons (no text rendering yet): reset, +10%
				// and recolor.
				@tree((Row) { .size = { content_width, 0 }, .gap = 16.0, .main_align = CENTER })
				{
					@node(
						(Button) {
							.size = { 130.0, 40.0 },
							.style = { .color = { 0.20, 0.22, 0.28, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.hover_style = { .color = { 0.28, 0.31, 0.40, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.press_style = { .color = { 0.16, 0.17, 0.22, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.on_click = &reset_dial,
						}
					);
					@node(
						(Button) {
							.size = { 130.0, 40.0 },
							.style = { .color = { 0.75, 0.45, 0.15, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.hover_style = { .color = { 0.88, 0.55, 0.20, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.press_style = { .color = { 0.60, 0.35, 0.12, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.on_click = &bump_dial,
						}
					);
					@node(
						(Button) {
							.size = { 130.0, 40.0 },
							.style = { .color = { 0.42, 0.30, 0.52, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.hover_style = { .color = { 0.52, 0.38, 0.64, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.press_style = { .color = { 0.34, 0.24, 0.42, 1.0 }, .border_radius = { 10.0, 10.0, 10.0, 10.0 } },
							.on_click = &recolor_card,
						}
					);
				};
			};
		};
	};

	// frame() polls input, dispatches to widgets, flushes and presents; the
	// loop body runs between frames. ui.input is the queryable context —
	// e.g. text typed during the frame just processed:
	while (renderer.frame(ui)!!)
	{
		if (ui.input.text.len > 0) io::printfn("[layout] typed: %s", ui.input.text);
	}
}
