import cui;
import std::math;
import std::io;

// Composite-widget example: a widget whose look is not painted directly but
// COMPOSED from already-defined widgets. StatCard implements the Widget
// interface's build method — return a @subtree(...) of Stack / Padding
// / Column / Row / Rectangle, and the framework does the rest: it attaches the
// subtree as the element's child on the first flush and, with no layout method,
// sizes the card to what the subtree wants. The analog of a Flutter
// StatelessWidget.build(). The widget has no paint(): its children ARE its
// appearance, and self.value / self.accent parameterize the composition the way
// a Flutter build() reads its widget's fields. (Contrast test/layout.c3's Dial,
// which paints SDF primitives itself.) The subtree is cached like any other
// widget's children until request_build regenerates it: clicking a card bumps
// value and rebuilds — CUI's setState (see on_mouse below).
// 
// Run with: c3c run composite

const float CARD_W   = 260.0;
const float CARD_H   = 76.0;
const float CARD_PAD = 16.0;
const float BAR_W    = CARD_W - 2.0 * CARD_PAD; // inner content width

struct StatCard (Widget)
{
	float value; // 0..1, drives the progress fill
	Color accent; // chip + fill color
}

// The build method is the ENTIRE widget implementation — no layout, no paint.
// It returns a subtree assembled from existing widgets; the composed children
// do all the drawing, and the framework's single-child passthrough handles
// sizing.
fn Element* StatCard.build(&self, Element* elem) @dynamic
{
	float fill = math::clamp(self.value, 0.0f, 1.0f) * BAR_W;
	return @subtree(elem.ui)
	{
		@tree((Stack) { .size = { CARD_W, CARD_H } })
		{
			// Background panel — the first Stack child, at the origin.
			@node(
				(Rectangle) {
					.size = { CARD_W, CARD_H },
					.style = {
						.color = { 0.16, 0.17, 0.22, 1.0 },
						.border_radius = { 14.0, 14.0, 14.0, 14.0 },
						.border_width = 1.0,
						.border_color = { 0.28, 0.30, 0.38, 1.0 },
					},
				}
			);
			// Content, laid over the panel at the same origin.
			@tree((Padding) { .insets = widgets::insets_all(CARD_PAD) })
			{
				@tree((Column) { .gap = 14.0 })
				{
					// Header: an accent chip + a placeholder title bar (no text yet).
					@tree((Row) { .size = { BAR_W, 18.0 }, .gap = 10.0, .cross_align = CENTER })
					{
						@node(
							(Rectangle) {
								.size = { 18.0, 18.0 },
								.style = { .color = self.accent, .border_radius = { 6.0, 6.0, 6.0, 6.0 } },
							}
						);
						@node(
							(Rectangle) {
								.size = { BAR_W - 28.0, 9.0 },
								.style = { .color = { 0.42, 0.45, 0.52, 1.0 }, .border_radius = { 4.0, 4.0, 4.0, 4.0 } },
							}
						);
					};
					// Progress bar: a fill and a remainder rect side by side,
					// summing to BAR_W. self.value sets where they meet.
					@tree((Row) { .size = { BAR_W, 12.0 } })
					{
						@node(
							(Rectangle) {
								.size = { fill, 12.0 },
								.style = { .color = self.accent, .border_radius = { 6.0, 0.0, 0.0, 6.0 } },
							}
						);
						@node(
							(Rectangle) {
								.size = { BAR_W - fill, 12.0 },
								.style = { .color = { 0.24, 0.26, 0.32, 1.0 }, .border_radius = { 0.0, 6.0, 6.0, 0.0 } },
							}
						);
					};
				};
			};
		};
	};
}

// Interactivity composes with build: clicks on the card's rectangles bubble up
// to the composite element, whose widget handles them here. Mutate own state,
// then request_build — the framework drops the built subtree and re-runs build
// with the new value on the next flush. (ui.@modify(StatCard; c) {...} from an
// outside callback would do the same: request_paint routes to request_build on
// build widgets.)
fn bool StatCard.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != PRESS || event.button != MouseButton.LEFT) return false;
	self.value = self.value >= 1.0f ? 0.0f : math::clamp(self.value + 0.1f, 0.0f, 1.0f);
	elem.request_build();
	io::printfn("[composite] card clicked -> %.2f", self.value);
	return true;
}

struct CardSpec
{
	float value;
	Color accent;
}

fn void main(String[] args)
{
	Vec2 window_size = { 520.0, 560.0 };

	Renderer renderer = cui::vulkan::new(window_size: window_size, loop_mode: ON_DEMAND)!!;
	defer catch renderer.free();

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();

	CardSpec[4] specs = {
		{ 0.72, { 0.95, 0.60, 0.20, 1.0 } },
		{ 0.45, { 0.35, 0.70, 0.95, 1.0 } },
		{ 0.88, { 0.55, 0.85, 0.45, 1.0 } },
		{ 0.30, { 0.85, 0.40, 0.55, 1.0 } },
	};

	// The composite reused with different data, arranged by an ordinary Column
	// exactly as if StatCard were a built-in widget.
	@canvas(ui)
	{
		@tree((Padding) { .insets = widgets::insets_all(28.0) })
		{
			@tree((Column) { .gap = 18.0, .main_align = CENTER, .cross_align = CENTER })
			{
				foreach (spec : specs)
				{
					@node((StatCard) { .value = spec.value, .accent = spec.accent });
				}
			};
		};
	};

	// The app owns the loop; all the interactivity lives in the widgets, so
	// there is no per-frame code — frame() polls input, dispatches to the
	// widgets, flushes and presents (and, in ON_DEMAND mode, sleeps until
	// input when nothing scheduled a frame).
	while (renderer.frame(ui)!!) { }
}
