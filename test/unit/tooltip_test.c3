// Tooltip / TooltipHost: the text comes up after a rest, goes on leaving, on a
// press and on a scroll, a probe answers per part, the hint follows the pointer,
// and long text wraps inside the window.
module cui_tests::tooltip;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;

// Longer than the default delay at the helper's 16 ms frames.
const int REST @local = 45;
const Vec2 ON_A @local = { 20, 10 };
const Vec2 ON_B @local = { 70, 10 };
const Vec2 OFF @local = { 300, 80 };

fn String halves(Element* tip, Vec2 pos) @local
{
	Element* control = tip.children[0];
	return pos.x - control.absolute.x < control.size.x * 0.5f ? "left half" : "right half";
}

// Two buttons side by side, A with a plain tip and a hint, B with a probe;
// the host last, over everything.
fn Ui* tipped_ui(String a_text = "Alpha — the first") @local
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	ui.build(ui.@node((Stack) { },
		ui.@node((Row) { },
			ui.@node(widgets::tip(a_text, "alpha hint"), ui.@node((Button) { .size = { 40, 20 } })),
			ui.@node((Rectangle) { .size = { 10, 20 } }),
			ui.@node(widgets::tip_probe(&halves), ui.@node((Button) { .size = { 40, 20 } }))),
		ui.@node((TooltipHost) { })));
	ui.flush();
	return ui;
}

fn void rest(Ui* ui, Vec2 at, int frames = REST) @local
{
	for (int i = 0; i < frames; i++) cui_tests::frame(ui, at);
	ui.flush();
}

fn void a_tooltip_shows_after_a_rest_and_hides_on_leave() @test
{
	Ui* ui = tipped_ui();
	defer ui.free();

	rest(ui, ON_A, 2);
	test::@check(widgets::tooltip_shown(ui).len == 0, "showed before the delay");
	rest(ui, ON_A);
	test::@check(widgets::tooltip_shown(ui) == "Alpha — the first", "showed \"%s\"", widgets::tooltip_shown(ui));
	rest(ui, OFF, 1);
	test::@check(widgets::tooltip_shown(ui).len == 0, "stayed after the pointer left");
}

fn void a_press_hides_it_until_the_pointer_moves_on() @test
{
	Ui* ui = tipped_ui();
	defer ui.free();

	rest(ui, ON_A);
	cui_tests::frame(ui, ON_A, left: true);
	test::@check(widgets::tooltip_shown(ui).len == 0, "a press did not hide it");
	cui_tests::frame(ui, ON_A);
	rest(ui, ON_A);
	test::@check(widgets::tooltip_shown(ui).len == 0, "it came back with no movement");

	rest(ui, OFF, 1);
	rest(ui, ON_A);
	test::@check(widgets::tooltip_shown(ui).len > 0, "it did not come back after moving on");

	cui_tests::frame(ui, ON_A, scroll: 1);
	test::@check(widgets::tooltip_shown(ui).len == 0, "a scroll did not hide it");
}

fn void a_probe_answers_for_the_part_under_the_pointer() @test
{
	Ui* ui = tipped_ui();
	defer ui.free();

	rest(ui, { 55, 10 });
	test::@check(widgets::tooltip_shown(ui) == "left half", "showed \"%s\"", widgets::tooltip_shown(ui));
	rest(ui, { 85, 10 }, 1);
	test::@check(widgets::tooltip_shown(ui).len == 0, "the other half kept the first half's text");
	rest(ui, { 85, 10 });
	test::@check(widgets::tooltip_shown(ui) == "right half", "showed \"%s\"", widgets::tooltip_shown(ui));
}

fn void the_hint_follows_the_pointer_with_no_delay() @test
{
	Ui* ui = tipped_ui();
	defer ui.free();

	rest(ui, OFF, 1);
	test::@check(widgets::tooltip_hint(ui).len == 0, "a hint with the pointer off every control");
	rest(ui, ON_A, 1);
	test::@check(widgets::tooltip_hint(ui) == "alpha hint", "the hint was \"%s\"", widgets::tooltip_hint(ui));
	rest(ui, ON_B, 1);
	test::@check(widgets::tooltip_hint(ui).len == 0, "B has no hint, but A's stayed");
}

fn void every_element_under_a_wrapper_finds_it() @test
{
	Ui* ui = tipped_ui();
	defer ui.free();

	Element* host = ui.find(TooltipHost)!!;
	Element* row = ui.root.children[0];
	Element* button = row.children[0].children[0];
	test::@check(widgets::tooltip_above(button) == row.children[0], "the button did not find its wrapper");
	test::@check(widgets::tooltip_above(row) == null, "the row found a wrapper it is not under");
	test::@check(widgets::tooltip_above(host) == null, "the host found a wrapper");
}

fn void long_text_wraps_inside_the_window() @test
{
	String text = "Alpha — a tooltip with far more to say than fits on one line of a window only four hundred pixels wide";
	Ui* ui = tipped_ui(text);
	defer ui.free();
	ui.load_font("test/assets/DejaVuSans.ttf")!!;

	rest(ui, ON_A);
	Element* host = ui.find(TooltipHost)!!;
	float right = 0;
	float top = 1e9;
	float bottom = 0;
	foreach (d : host.local_drawings.array_view())
	{
		if (d.kind != DrawingKind.GLYPH) continue;
		right = math::max(right, d.corner.x + d.size.x);
		top = math::min(top, d.corner.y);
		bottom = math::max(bottom, d.corner.y + d.size.y);
	}
	test::@check(right > 0, "no text was drawn");
	test::@check(right <= cui_tests::WINDOW.x, "the text ran to %f in a %f window", right, cui_tests::WINDOW.x);
	test::@check(bottom - top > ui.text.measure(0, text, 12).y * 1.5f, "the text did not wrap");
}
