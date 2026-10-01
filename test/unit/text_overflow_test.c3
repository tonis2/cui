// Text wider than its room: TextSystem.fit / line_break / measure_box, and a
// Label cut with an ellipsis or wrapped onto more lines.
module cui_tests::text_overflow;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;

const String FONT @local = "test/assets/DejaVuSans.ttf";
const String LONG @local = "The quick brown fox jumps over the lazy dog and keeps on running";

fn Ui* new_ui_with_font() @local
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	ui.load_font(FONT)!!;
	return ui;
}

// The furthest right any glyph of `elem` reaches, and how many lines its glyphs
// sit on: glyph centres within half a 14 px line of each other share one.
fn float glyph_right(Element* elem, usz* rows) @local
{
	float right = 0;
	float[16] tops;
	usz count = 0;
	foreach (d : elem.local_drawings.array_view())
	{
		if (d.kind != DrawingKind.GLYPH) continue;
		right = math::max(right, d.corner.x + d.size.x);
		float top = d.corner.y + d.size.y * 0.5f;
		bool seen;
		for (usz i = 0; i < count; i++) seen = seen || math::abs(tops[i] - top) < 8.0f;
		if (!seen && count < tops.len) tops[count++] = top;
	}
	*rows = count;
	return right;
}

fn void fit_takes_the_longest_prefix_that_fits() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	float whole = ui.text.measure(0, LONG, 14).x;
	test::eq(ui.text.fit(0, LONG, 14, whole), (usz)LONG.len);
	usz half = ui.text.fit(0, LONG, 14, whole * 0.5f);
	test::@check(half > 0 && half < LONG.len, "half the width took %d of %d bytes", half, LONG.len);
	test::@check(ui.text.measure(0, LONG[:half], 14).x <= whole * 0.5f, "the prefix is wider than its room");
	test::@check(ui.text.measure(0, LONG[:half + 1], 14).x > whole * 0.5f, "one more rune would still have fit");
	test::eq(ui.text.fit(0, "ab\ncd", 14, 1000), (usz)2);
}

fn void line_break_breaks_at_a_space_mid_word_and_at_a_newline() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	usz next;
	float word = ui.text.measure(0, "quick", 14).x;
	// Room for "quick" and part of "brown": the line ends after "quick".
	usz len = ui.text.line_break(0, "quick brown", 14, word * 1.6f, &next);
	test::@check("quick brown"[:len] == "quick", "broke as \"%s\"", "quick brown"[:len]);
	test::eq(next, (usz)6);

	// One word wider than the room breaks inside it, and never on nothing.
	len = ui.text.line_break(0, "unbreakable", 14, word * 0.5f, &next);
	test::@check(len > 0 && len < 11 && next == len, "a long word broke at %d", len);
	len = ui.text.line_break(0, "unbreakable", 14, 0.0f, &next);
	test::eq(len, (usz)1);

	len = ui.text.line_break(0, "one\ntwo", 14, 1000, &next);
	test::eq(len, (usz)3);
	test::eq(next, (usz)4);
}

fn void measure_box_wraps_to_the_width_and_grows_down() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	Vec2 line = ui.text.measure(0, LONG, 14);
	Vec2 visible = ui.text.measure_box(0, LONG, 14, 100, TextOverflow.VISIBLE);
	test::@check(visible.x == line.x && visible.y == line.y, "VISIBLE is not measure");

	Vec2 cut = ui.text.measure_box(0, LONG, 14, 100, TextOverflow.ELLIPSIS);
	test::@check(cut.x <= 100 && cut.y == line.y, "an ellipsis is one line no wider than its room");

	Vec2 wrapped = ui.text.measure_box(0, LONG, 14, 100, TextOverflow.WRAP);
	test::@check(wrapped.x <= 100, "a wrapped line is %f wide in 100", wrapped.x);
	test::@check(wrapped.y >= line.y * 4.0f, "the wrapped text is only %f tall", wrapped.y);

	Vec2 roomy = ui.text.measure_box(0, LONG, 14, 10000, TextOverflow.WRAP);
	test::@check(roomy.x == line.x && roomy.y == line.y, "text that fits is one line");
	Vec2 empty = ui.text.measure_box(0, "", 14, 100, TextOverflow.WRAP);
	test::@check(empty.x == 0 && empty.y == line.y, "empty text is one empty line");
}

fn void a_label_runs_past_its_room_by_default() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	Element* label = ui.@node((Label) { .text = LONG, .size = 14, .color = { 1, 1, 1, 1 } });
	ui.build(ui.@node((Column) { .size = { 80, 0 } }, label));
	ui.flush();
	usz rows;
	test::@check(glyph_right(label, &rows) > 80, "the default label was cut");
	test::eq(rows, (usz)1);
}

fn void an_ellipsis_label_ends_in_the_mark_inside_its_room() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	Element* label = ui.@node((Label) { .text = LONG, .size = 14, .color = { 1, 1, 1, 1 }, .overflow = ELLIPSIS });
	ui.build(ui.@node((Column) { .size = { 80, 0 } }, label));
	ui.flush();
	test::@check(label.size.x <= 80, "the label is %f wide in 80", label.size.x);
	usz rows;
	test::@check(glyph_right(label, &rows) <= 80, "a glyph ran past the edge");
	test::eq(rows, (usz)1);
	// The mark is the last glyph drawn, so it has the rightmost corner.
	Drawing* last;
	foreach (&d : label.local_drawings.array_view()) if (d.kind == DrawingKind.GLYPH) last = d;
	usz unused;
	test::@check(last != null && last.corner.x + last.size.x >= glyph_right(label, &unused), "the ellipsis is not last");
}

fn void a_wrapping_label_grows_down_inside_its_width() @test
{
	Ui* ui = new_ui_with_font();
	defer ui.free();

	Element* label = ui.@node((Label) { .text = LONG, .size = 14, .color = { 1, 1, 1, 1 }, .overflow = WRAP });
	ui.build(ui.@node((Column) { .size = { 120, 0 } }, label));
	ui.flush();
	float one_line = ui.text.measure(0, LONG, 14).y;
	test::@check(label.size.x <= 120, "the label is %f wide in 120", label.size.x);
	test::@check(label.size.y > one_line * 2.0f, "the label did not grow down");
	usz rows;
	test::@check(glyph_right(label, &rows) <= 120, "a glyph ran past the edge");
	test::@check(rows >= 3, "drew %d lines", rows);
}
