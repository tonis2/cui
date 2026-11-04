// IconStrip: cells that poll their state and act on a press, and rows that own
// their strings. Headless, so a cell is the style's numbers and nothing softer.
module cui_tests::icon_strips;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

const float CELL_W = widgets::DEFAULT_ICON_STRIP_STYLE.cell.x;
const float CELL_H = widgets::DEFAULT_ICON_STRIP_STYLE.cell.y;

// What the queries answer and the clicks report: a bare fn pointer has no context.
bool first_on @local;
bool second_off @local;
int first_clicks @local;
int second_clicks @local;
int presses @local;
int painted @local;
Color last_ink @local;

fn MenuItemFlags first_state(Ui* ui) @local => { .checked = first_on };
fn MenuItemFlags second_state(Ui* ui) @local => { .disabled = second_off };
fn void first_click(Ui* ui) @local => first_clicks++;
fn void second_click(Ui* ui) @local => second_clicks++;
fn void note_press(Ui* ui) @local => presses++;

fn void note_paint(Painter* painter, usz cell, Vec2 centre, Color ink, Color ground) @local
{
	painted++;
	last_ink = ink;
}

IconStripCell[2] cells @local = {
	{ .state = &first_state, .on_select = &first_click, .tip = "First" },
	{ .state = &second_state, .on_select = &second_click, .tip = "Second" },
};

fn void reset_strip() @local
{
	first_on = false;
	second_off = false;
	first_clicks = 0;
	second_clicks = 0;
	presses = 0;
	painted = 0;
}

fn Element* strip_in(Ui* ui) @local
{
	reset_strip();
	Element* strip = ui.@node((IconStrip) { .cells = cells[..], .paint_icon = &note_paint, .on_press = &note_press });
	ui.build(ui.@node((Stack) { }, strip));
	ui.flush();
	return strip;
}

fn void a_strip_is_as_wide_as_its_cells() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	cui_tests::eq_vec2(strip.size, { CELL_W * 2, CELL_H });

	IconStrip* self = strip.widget_as(IconStrip);
	test::eq(self.cell_at({ 1, 1 }), (sz)0);
	test::eq(self.cell_at({ CELL_W + 1, 1 }), (sz)1);
	test::eq(self.cell_at({ CELL_W * 2 + 1, 1 }), (sz)-1);
	test::eq(self.cell_at({ 1, CELL_H + 1 }), (sz)-1);
	test::eq(self.cell_at({ -1, 1 }), (sz)-1);
}

// The query changed with no click, and the strip noticed by itself.
fn void a_cell_follows_its_query() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	IconStrip* self = strip.widget_as(IconStrip);

	cui_tests::frame(ui, { 300, 300 });
	test::@check(!self.shown[0].checked, "a cell lit before its query said so");
	first_on = true;
	second_off = true;
	cui_tests::frame(ui, { 300, 300 });
	test::@check(self.shown[0].checked, "the cell did not follow its query");
	test::@check(self.shown[1].disabled, "the cell did not grey with its query");
}

fn void a_press_acts_at_once() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	Vec2 second = strip.absolute + (Vec2) { CELL_W * 1.5f, CELL_H * 0.5f };

	cui_tests::frame(ui, second);
	cui_tests::frame(ui, second, left: true);
	test::eq(second_clicks, 1);
	test::eq(first_clicks, 0);
	test::eq(presses, 1);
	cui_tests::frame(ui, second);
	test::eq(second_clicks, 1);
}

// It reaches `on_press`, so a menu still closes, but the cell does nothing.
fn void a_disabled_cell_takes_the_press_and_does_nothing() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	second_off = true;
	Vec2 second = strip.absolute + (Vec2) { CELL_W * 1.5f, CELL_H * 0.5f };

	cui_tests::frame(ui, second);
	cui_tests::frame(ui, second, left: true);
	test::eq(second_clicks, 0);
	test::eq(presses, 1);
}

fn void hover_goes_when_the_pointer_leaves() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	IconStrip* self = strip.widget_as(IconStrip);

	cui_tests::frame(ui, strip.absolute + (Vec2) { CELL_W * 1.5f, CELL_H * 0.5f });
	test::eq(self.lit, 2);
	cui_tests::frame(ui, { 300, 300 });
	test::eq(self.lit, 0);
}

// One frame, then the strip's rects drawn in `color`: drawings come from the flush.
fn int rects_after(Ui* ui, Element* strip, Vec2 mouse, Color color) @local
{
	cui_tests::frame(ui, mouse);
	ui.flush();
	int found;
	for (sz i = strip.first_drawing; i < strip.first_drawing + strip.drawing_count; i++)
	{
		if ((Vec4)ui.canvas.drawings[i].color == (Vec4)color) found++;
	}
	return found;
}

fn void only_the_hovered_or_lit_cell_gets_a_highlight() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	IconStripStyle s = widgets::DEFAULT_ICON_STRIP_STYLE;
	Vec2 away = { 300, 300 };

	test::eq(rects_after(ui, strip, away, s.hover), 0);
	test::eq(rects_after(ui, strip, away, s.lit), 0);
	test::eq(rects_after(ui, strip, strip.absolute + (Vec2) { CELL_W * 1.5f, CELL_H * 0.5f }, s.hover), 1);

	first_on = true;
	test::eq(rects_after(ui, strip, away, s.hover), 0);
	test::eq(rects_after(ui, strip, away, s.lit), 1);
}

// A disabled cell is not offered, so the pointer doesn't light it.
fn void a_disabled_cell_does_not_light_under_the_pointer() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* strip = strip_in(ui);
	IconStripStyle s = widgets::DEFAULT_ICON_STRIP_STYLE;

	second_off = true;
	test::eq(rects_after(ui, strip, { 300, 300 }, s.hover), 0);
	test::eq(rects_after(ui, strip, strip.absolute + (Vec2) { CELL_W * 1.5f, CELL_H * 0.5f }, s.hover), 0);
}

fn void the_tip_is_the_cell_under_the_pointer() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	reset_strip();
	Element* strip = ui.@node((IconStrip) { .cells = cells[..], .paint_icon = &note_paint });
	Element* holder = ui.@node(widgets::tip_probe(&widgets::icon_strip_tip), strip);
	ui.build(ui.@node((Stack) { }, holder));
	ui.flush();

	test::eq(widgets::icon_strip_tip(holder, strip.absolute + (Vec2) { 1, 1 }), "First");
	test::eq(widgets::icon_strip_tip(holder, strip.absolute + (Vec2) { CELL_W + 1, 1 }), "Second");
	test::eq(widgets::icon_strip_tip(holder, strip.absolute + (Vec2) { CELL_W * 3, 1 }), "");
}

// Run with leak checks on: every row here is made and freed one way, including
// the empty strings, which `copy` would allocate and a length check would skip.
fn void rows_own_their_strings_and_free_them() @test
{
	char[3] source = { 'a', 'b', 'c' };
	TreeRow[] rows = alloc::new_array(mem, TreeRow, 3);
	rows[0] = ((TreeRow) { .label = (String)source[..], .trailing = "12" }).owned();
	rows[1] = ((TreeRow) { .label = "", .trailing = "" }).owned();
	rows[2] = ((TreeRow) { .depth = 2 }).owned();
	source[0] = 'z';
	test::eq(rows[0].label, "abc");
	test::eq(rows[2].depth, (usz)2);

	widgets::free_tree_rows(&rows);
	test::eq(rows.len, (sz)0);
	widgets::free_tree_rows(&rows);
}
