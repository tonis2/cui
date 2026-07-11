import cui;
import std::io;
import std::math;

// Clipping example: three panels showing the clip system — and the scoped
// tree builder (@canvas / @tree / @node) that declares them.
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

	@canvas(ui)
	{
		@tree((Padding) { .insets = widgets::insets_all(24.0) })
		{
			@tree((Row) { .gap = 24.0 })
			{
				// Panel 1: the scroll viewport. Content is a Column far taller
				// than the 600px viewport; Scroll lays it out with unbounded
				// height and clips.
				@tree((Scroll) { .size = { 280, 600 }, .scroll_offset = 120, .radii = { 12, 12, 12, 12 } })
				{
					@tree((Column) { .gap = 12.0 })
					{
						for (int i = 0; i < 16; i++)
						{
							@node(
								(Rectangle) {
									.size = { 256, 90 },
									.style = {
										.color = i % 2 == 0 ? CARD_A : CARD_B,
										.border_radius = { 10, 10, 10, 10 }
									},
								}
							);
						}
					};
				};

				// Panel 2: a rounded Clip. The background rect is square-cornered
				// and the accent rects hang past every edge — the clip shaves all
				// of it to the 32px rounded outline.
				@tree((Clip) { .radii = { 32, 32, 32, 32 } })
				{
					@tree((Stack) { .size = { 260, 280 } })
					{
						@node((Rectangle) { .size = { 260, 280 }, .style = { .color = PANEL } });
						@node((Rectangle) { .size = { 120, 60 }, .style = { .color = ACCENT1 } })
							.set_offset({ -40, 30 });
						@node((Rectangle) { .size = { 100, 80 }, .style = { .color = ACCENT2 } })
							.set_offset({ 200, -30 });
						@node((Rectangle) { .size = { 120, 90 }, .style = { .color = ACCENT3 } })
							.set_offset({ 180, 240 });
						@node((Rectangle) { .size = { 90, 70 }, .style = { .color = ACCENT4 } })
							.set_offset({ -30, 200 });
					};
				};

				// Panel 3: nested clips. The inner Clip is offset so its rect
				// crosses the outer one; the bright rect only shows inside the
				// intersection.
				@tree((Clip) { .radii = { 24, 24, 24, 24 } })
				{
					@tree((Stack) { .size = { 260, 280 } })
					{
						@node((Rectangle) { .size = { 260, 280 }, .style = { .color = PANEL } });
						Element* inner = @tree((Clip) { .radii = { 24, 24, 24, 24 } })
						{
							@node((Rectangle) { .size = { 200, 200 }, .style = { .color = ACCENT1 } });
						};
						inner.set_offset({ 120, 140 });
					};
				};
			};
		};
	};

	// The app owns the loop; everything here is widget-driven, so the body is
	// empty — wheel over the left panel to scroll (ON_DEMAND sleeps between
	// inputs).
	while (renderer.frame(ui)!!)
	{
	}
}
