import cui;
import std::io;
import std::math;

// Clipping example: three panels showing the clip system.
// 
//   1. Scroll — a viewport over a Column of 16 cards. Wheel over it to
//      scroll; the indicator thumb tracks the position. The initial offset is
//      non-zero so a mid-scroll state (cut cards top and bottom, thumb partway
//      down) is visible without touching anything.
//   2. Clip — square rects hanging past every edge of a panel get shaved to
//      its rounded outline.
//   3. Nested clips — an offset inner Clip crossing the outer one: content is
//      confined to the intersection, the inner radii still round the corners.
// 
// Run with: c3c run scroll

const Color CARD_A  = { 0.22, 0.45, 0.60, 1.0 };
const Color CARD_B  = { 0.60, 0.35, 0.50, 1.0 };
const Color PANEL   = { 0.16, 0.17, 0.22, 1.0 };
const Color ACCENT1 = { 0.95, 0.60, 0.20, 1.0 };
const Color ACCENT2 = { 0.55, 0.85, 0.45, 1.0 };
const Color ACCENT3 = { 0.35, 0.70, 0.95, 1.0 };
const Color ACCENT4 = { 0.85, 0.40, 0.55, 1.0 };

fn void main(String[] args)
{
	Vec2 window_size = { 900.0, 700.0 };

	Renderer renderer = cui::vulkan::new(window_size: window_size, loop_mode: ON_DEMAND)!!;
	defer catch renderer.free();

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	// Panel 1: the scroll viewport. Content is a Column far taller than the
	// 600px viewport; Scroll lays it out with unbounded height and clips.
	Element* cards = ui.@node((Column) { .gap = 12.0 });
	for (int i = 0; i < 16; i++)
	{
		cards.append(
			ui.@node(
				(Rectangle) {
					.size = { 256, 90 },
					.style = { .color = i % 2 == 0 ? CARD_A : CARD_B, .border_radius = { 10, 10, 10, 10 } },
				}
			)
		);
	}
	Element* scroll = ui.@node(
		(Scroll) { .size = { 280, 600 }, .scroll_offset = 120, .radii = { 12, 12, 12, 12 } },
		cards
	);

	// Panel 2: a rounded Clip. The background rect is square-cornered and the
	// accent rects hang past every edge — the clip shaves all of it to the
	// 32px rounded outline.
	Element* overflow_stack = ui.@node(
		(Stack) { .size = { 260, 280 } },
		ui.@node((Rectangle) { .size = { 260, 280 }, .style = { .color = PANEL } })
	);
	Element*[4] hangers = {
		ui.@node((Rectangle) { .size = { 120, 60 }, .style = { .color = ACCENT1 } }),
		ui.@node((Rectangle) { .size = { 100, 80 }, .style = { .color = ACCENT2 } }),
		ui.@node((Rectangle) { .size = { 120, 90 }, .style = { .color = ACCENT3 } }),
		ui.@node((Rectangle) { .size = { 90, 70 }, .style = { .color = ACCENT4 } }),
	};
	Vec2[4] hang_offsets = { { -40, 30 }, { 200, -30 }, { 180, 240 }, { -30, 200 } };
	foreach (i, hanger : hangers)
	{
		overflow_stack.append(hanger);
		hanger.set_offset(hang_offsets[i]);
	}
	Element* clipped = ui.@node((Clip) { .radii = { 32, 32, 32, 32 } }, overflow_stack);

	// Panel 3: nested clips. The inner Clip is offset so its rect crosses the
	// outer one; the bright rect only shows inside the intersection.
	Element* inner = ui.@node(
		(Clip) { .radii = { 24, 24, 24, 24 } },
		ui.@node((Rectangle) { .size = { 200, 200 }, .style = { .color = ACCENT1 } })
	);
	Element* nested_stack = ui.@node(
		(Stack) { .size = { 260, 280 } },
		ui.@node((Rectangle) { .size = { 260, 280 }, .style = { .color = PANEL } })
	);
	nested_stack.append(inner);
	inner.set_offset({ 120, 140 });
	Element* nested = ui.@node((Clip) { .radii = { 24, 24, 24, 24 } }, nested_stack);

	ui.build(
		ui.@node(
			(Padding) { .insets = widgets::insets_all(24.0) },
			ui.@node((Row) { .gap = 24.0 }, scroll, clipped, nested)
		)
	);

	// The app owns the loop; everything here is widget-driven, so the body is
	// empty — wheel over the left panel to scroll (ON_DEMAND sleeps between
	// inputs).
	while (renderer.frame(ui)!!)
	{
	}
}
