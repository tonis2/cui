// Wrap, Segmented and ToggleButton. Headless and fontless, so a label measures
// zero wide and every segment is exactly its two paddings: the geometry here is
// the style's numbers and nothing softer.
module cui_tests::segmenteds;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

usz picked @local;
int picks @local;
bool toggled_to @local;
int toggles @local;

fn void note_pick(Ui* ui, usz index) @local
{
	picked = index;
	picks++;
}

fn void note_toggle(Ui* ui, bool on) @local
{
	toggled_to = on;
	toggles++;
}

fn void click(Ui* ui, Vec2 at) @local
{
	cui_tests::frame(ui, at);
	cui_tests::frame(ui, at, left: true);
	cui_tests::frame(ui, at);
	ui.flush();
}

<*
 Children keep their own widths and fold onto a new line only when the next one
 would run past the edge; a line's height is its tallest child.
*>
fn void wrap_folds_at_the_width() @test
{
	Ui* ui = cui::new_ui({ 400, 400 });
	defer ui.free();

	Element* wrap = ui.@node(
		(Wrap) { .gap_x = 10, .gap_y = 5 },
		ui.@node((Rectangle) { .size = { 100, 20 } }),
		ui.@node((Rectangle) { .size = { 80, 30 } }),
		ui.@node((Rectangle) { .size = { 60, 20 } }),
		ui.@node((Rectangle) { .size = { 300, 20 } })
	);
	ui.build(ui.@node((Column) { .size = { 260, 0 } }, wrap));
	ui.flush();

	// 100 + 10 + 80 = 190 fits in 260; adding 10 + 60 = 260 still fits exactly.
	cui_tests::eq_vec2(wrap.children[0].offset, { 0, 0 });
	cui_tests::eq_vec2(wrap.children[1].offset, { 110, 0 });
	cui_tests::eq_vec2(wrap.children[2].offset, { 200, 0 });
	// The wide one gets a line of its own, under the tallest child of the first.
	cui_tests::eq_vec2(wrap.children[3].offset, { 0, 35 });
	test::eq(wrap.size.y, 55.0f);
	test::eq(wrap.size.x, 260.0f);
}

<*
 A click picks the segment under it, lights it and reports its index; a press
 dragged off to another segment picks nothing.
*>
fn void segmented_picks_the_clicked_segment() @test
{
	Ui* ui = cui::new_ui({ 400, 100 });
	defer ui.free();
	picks = 0;

	String[] options = { "Smooth", "Linear", "Step" };
	Element* strip   = ui.@node((Segmented) { .options = options, .selected = -1, .on_change = &note_pick });
	ui.build(ui.@node((Stack) { }, strip));
	ui.flush();

	float pad = widgets::DEFAULT_SEGMENTED_STYLE.pad_x;
	test::eq(strip.size.x, 6 * pad);
	test::eq(strip.size.y, widgets::DEFAULT_SEGMENTED_STYLE.height);

	click(ui, { 2 * pad + pad, 10 });
	test::eq(picks, 1);
	test::eq(picked, (usz)1);
	test::eq(strip.widget_as(Segmented).selected, (sz)1);

	// Press on Step, release on Smooth: no choice.
	cui_tests::frame(ui, { 5 * pad, 10 });
	cui_tests::frame(ui, { 5 * pad, 10 }, left: true);
	cui_tests::frame(ui, { pad, 10 });
	ui.flush();
	test::eq(picks, 1);
	test::eq(strip.widget_as(Segmented).selected, (sz)1);
}

<*
 A toggle flips itself on each click and reports the new state.
*>
fn void toggle_button_flips_and_reports() @test
{
	Ui* ui = cui::new_ui({ 400, 100 });
	defer ui.free();
	toggles = 0;

	Element* toggle = ui.@node((ToggleButton) { .label = "Loop", .size = { 60, 28 }, .on_change = &note_toggle });
	ui.build(ui.@node((Stack) { }, toggle));
	ui.flush();

	click(ui, { 30, 14 });
	test::eq(toggles, 1);
	test::@check(toggled_to && toggle.widget_as(ToggleButton).on, "the first click did not turn it on");
	click(ui, { 30, 14 });
	test::eq(toggles, 2);
	test::@check(!toggled_to && !toggle.widget_as(ToggleButton).on, "the second click did not turn it off");
	click(ui, { 200, 60 });
	test::eq(toggles, 2);
}