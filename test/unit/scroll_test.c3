// Scroll: viewport layout under unbounded height, wheel clamping and
// consumption, clip-gated hits for off-viewport content, and the indicator
// thumb's geometry. Fixture: a {100,100} viewport over a Column of four
// {80,100} cards — content 400, max scroll 300.
module cui_tests::scrolls;
import cui;
import cui_tests;
import std::math;
import std::core::test;

fn Element* fixture(Ui* ui, Element** out_scroll = null)
{
	Element* column = ui.@node((Column){},
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }));
	Element* scroll = ui.@node((Scroll){ .size = {100, 100} }, column);
	if (out_scroll) *out_scroll = scroll;
	ui.build(ui.@node((Stack){}, scroll));
	ui.flush();
	return column;
}

// The content child gets the unbounded axis (sizes to its natural 400), the
// viewport keeps its own size, and the internal thumb child appears.
fn void scroll_layout_and_viewport() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* scroll;
	Element* column = fixture(ui, &scroll);

	cui_tests::eq_vec2(scroll.size, {100, 100});
	test::eq(scroll.children.len(), 2);
	cui_tests::eq_vec2(column.size, {80, 400});
	cui_tests::eq_vec2(column.offset, {0, 0});
	test::eq(scroll.clips, true);
}

// Wheel scrolling moves by step (40px default) and clamps at both ends.
fn void scroll_clamps_at_both_ends() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* scroll;
	Element* column = fixture(ui, &scroll);
	Scroll* widget = scroll.widget_as(Scroll);

	cui_tests::frame(ui, {50, 50}, scroll: -1); // wheel down one unit
	test::eq(widget.scroll_offset, 40.0f);
	cui_tests::eq_vec2(column.offset, {0, -40});

	cui_tests::frame(ui, {50, 50}, scroll: -100); // far past the end
	test::eq(widget.scroll_offset, 300.0f);

	cui_tests::frame(ui, {50, 50}, scroll: 100); // far past the top
	test::eq(widget.scroll_offset, 0.0f);
	cui_tests::eq_vec2(column.offset, {0, 0});
}

// A mid-range wheel is consumed by the Scroll; at the limit it bubbles so an
// enclosing scroll area (here an EventProbe stand-in) can take over.
fn void scroll_consumes_then_bubbles_at_limit() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	Element* column = ui.@node((Column){},
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }));
	Element* scroll = ui.@node((Scroll){ .size = {100, 100} }, column);
	Element* outer = ui.@node((EventProbe){ .pref = {200, 100}, .rec = &rec }, scroll);
	ui.build(ui.@node((Stack){}, outer));
	ui.flush();

	cui_tests::frame(ui, {50, 50}, scroll: -1); // 0 -> 40: consumed
	test::eq(rec.scrolls, 0);

	cui_tests::frame(ui, {50, 50}, scroll: 1); // 40 -> 0: consumed
	test::eq(rec.scrolls, 0);

	cui_tests::frame(ui, {50, 50}, scroll: 1); // already at 0: bubbles out
	test::eq(rec.scrolls, 1);
}

// The wheel's cheap path (set_offset, no relayout) still moves what the next
// emit produces: absolute origins and canvas corners shift by the offset.
fn void scroll_offset_moves_child_absolute() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* scroll;
	Element* column = fixture(ui, &scroll);
	Element* second_card = column.children[1];

	cui_tests::frame(ui, {50, 50}, scroll: -1); // offset 40
	ui.flush();

	test::eq(second_card.absolute.y, 60.0f); // 100 - 40
	test::eq(ui.canvas.drawings[second_card.first_drawing].corner.y, 60.0f);
}

// Content scrolled out of the viewport is not hittable; visible content is.
fn void scroll_gates_hits_below_viewport() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* scroll;
	Element* column = fixture(ui, &scroll);
	Element* top_card = column.children[0];
	Element* fourth_card = column.children[3]; // content y 300..400, off-screen

	cui_tests::frame(ui, {50, 50});
	test::eq(ui.hovered == top_card, true);

	// No point inside the window can reach the fourth card: its rect is below
	// the viewport and the clip gate stops the descent.
	cui_tests::frame(ui, {50, 99});
	test::eq(ui.hovered == fourth_card, false);
	test::eq(fourth_card.absolute.y, 300.0f);
}

// Thumb: proportional length (clamped to the minimum), placed at the right
// edge, tracking scroll_offset across the track.
fn void thumb_geometry() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* scroll;
	fixture(ui, &scroll);
	Element* thumb = scroll.children[1];

	// track = 100 - 2*2 = 96; proportional length 96 * 100/400 = 24 = THUMB_MIN.
	cui_tests::eq_vec2(thumb.size, {6, 24});
	cui_tests::eq_vec2(thumb.offset, {92, 2});
	test::eq(thumb.widget_as(ScrollThumb).visible, true);

	// At max scroll the thumb sits at the end of its travel: 2 + (96-24) = 74.
	cui_tests::frame(ui, {50, 50}, scroll: -100);
	test::eq(thumb.offset.y, 74.0f);
}

// Content that fits gets no indicator and leaves the wheel to ancestors.
fn void thumb_hidden_when_content_fits() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	Element* scroll = ui.@node((Scroll){ .size = {100, 100} },
		ui.@node((Rectangle){ .size = {80, 50} }));
	Element* outer = ui.@node((EventProbe){ .pref = {200, 100}, .rec = &rec }, scroll);
	ui.build(ui.@node((Stack){}, outer));
	ui.flush();

	Element* thumb = scroll.children[1];
	test::eq(thumb.widget_as(ScrollThumb).visible, false);
	test::eq(thumb.drawing_count, 0);

	cui_tests::frame(ui, {50, 50}, scroll: -1);
	test::eq(rec.scrolls, 1); // nothing to scroll: bubbles out
}

// An out-of-range initial offset in the literal clamps on the first layout.
fn void initial_offset_clamped() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* column = ui.@node((Column){},
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }),
		ui.@node((Rectangle){ .size = {80, 100} }));
	Element* scroll = ui.@node((Scroll){ .size = {100, 100}, .scroll_offset = 1000 }, column);
	ui.build(ui.@node((Stack){}, scroll));
	ui.flush();

	test::eq(scroll.widget_as(Scroll).scroll_offset, 300.0f);
	cui_tests::eq_vec2(column.offset, {0, -300});
}
