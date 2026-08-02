// Layout: built-in containers' sizing and placement, and the constraint cache.
module cui_tests::layouts;
import cui;
import cui_tests;
import std::core::test;
import std::math::vector;

fn void constrain_clamps() @test
{
	Constraints c = { .min = {10, 10}, .max = {100, 50} };
	cui_tests::eq_vec2(c.constrain({500, 5}), {100, 10});
	cui_tests::eq_vec2(c.constrain({50, 30}), {50, 30});
	// The free-function spelling kept for consumers, arguments the other way.
	cui_tests::eq_vec2(cui::clamp_size({500, 5}, c), {100, 10});
}

fn void tight_and_loose_build_the_two_common_offers() @test
{
	Constraints t = cui::tight({40, 20});
	cui_tests::eq_vec2(t.min, {40, 20});
	cui_tests::eq_vec2(t.max, {40, 20});

	Constraints l = cui::loose({40, 20});
	cui_tests::eq_vec2(l.min, {0, 0});
	cui_tests::eq_vec2(l.max, {40, 20});
}

<*
 Deflate reserves space on both bounds and floors at zero — a widget padded
 harder than the room it was given hands its child an empty box, never a
 negative one, which would make min > max and trip the constrain contract.
*>
fn void deflate_floors_at_zero() @test
{
	Constraints c = { .min = {10, 10}, .max = {100, 50} };
	Constraints inner = c.deflate({20, 8});
	cui_tests::eq_vec2(inner.min, {0, 2});
	cui_tests::eq_vec2(inner.max, {80, 42});

	Constraints crushed = c.deflate({500, 500});
	cui_tests::eq_vec2(crushed.min, {0, 0});
	cui_tests::eq_vec2(crushed.max, {0, 0});
}

<*
 `fill` is the size-field convention as a function: a set component is that many
 pixels, a zero one fills what was offered, and the result is inside the range
 either way. Hand-written layouts and the no-layout shortcut must agree, so this
 pins the rule both of them read.
*>
fn void fill_resolves_zero_as_fill_per_axis() @test
{
	Constraints c = { .min = {0, 0}, .max = {400, 100} };
	cui_tests::eq_vec2(c.fill({0, 0}), {400, 100});      // both axes fill
	cui_tests::eq_vec2(c.fill({0, 40}), {400, 40});      // mixed: the bar case
	cui_tests::eq_vec2(c.fill({80, 30}), {80, 30});      // both fixed
	cui_tests::eq_vec2(c.fill({9999, 30}), {400, 30});   // fixed but clamped

	Constraints floored = { .min = {50, 50}, .max = {400, 100} };
	cui_tests::eq_vec2(floored.fill({10, 10}), {50, 50}); // raised to the minimum
}

fn void align_in_places_a_box_against_edges() @test
{
	Vec2 outer = { 100, 40 };
	Vec2 inner = { 20, 10 };
	cui_tests::eq_vec2(widgets::align_in(outer, inner, CrossAlign.START, CrossAlign.START), {0, 0});
	cui_tests::eq_vec2(widgets::align_in(outer, inner, CrossAlign.END, CrossAlign.END), {80, 30});
	cui_tests::eq_vec2(widgets::align_in(outer, inner, CrossAlign.CENTER, CrossAlign.CENTER), {40, 15});

	// The margin holds the box off the edges it is pushed against, and a centered
	// axis ignores it — there is no edge there to sit against.
	cui_tests::eq_vec2(
		widgets::align_in(outer, inner, CrossAlign.END, CrossAlign.CENTER, {8, 8}),
		{72, 15}
	);
}

fn void rectangle_clamps_to_constraints() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {500, 10} });
	ui.build(ui.@node((Stack){}, rect));
	ui.flush();

	cui_tests::eq_vec2(rect.size, {400, 10});   // width clamped to the window
}

fn void column_wraps_content() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} });
	Element* col = ui.@node((Column){ .gap = 10 }, a, b);
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	cui_tests::eq_vec2(col.size, {50, 70});     // widest child x (20 + 10 + 40)
	cui_tests::eq_vec2(a.offset, {0, 0});
	cui_tests::eq_vec2(b.offset, {0, 30});      // 20 + gap
}

fn void column_center_aligns() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {40, 20} });
	Element* col = ui.@node((Column){ .size = {100, 100}, .main_align = CENTER, .cross_align = CENTER }, a);
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	cui_tests::eq_vec2(col.size, {100, 100});
	cui_tests::eq_vec2(a.offset, {30, 40});     // (100-40)/2, (100-20)/2
}

fn void column_space_between() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {10, 20} });
	Element* b = ui.@node((Rectangle){ .size = {10, 20} });
	Element* col = ui.@node((Column){ .size = {0, 100}, .main_align = SPACE_BETWEEN }, a, b);
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	test::eq(a.offset.y, 0.0f);
	test::eq(b.offset.y, 80.0f);                // pushed to the far end
}

fn void row_wraps_with_gap() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} });
	Element* row = ui.@node((Row){ .gap = 10 }, a, b);
	ui.build(ui.@node((Stack){}, row));
	ui.flush();

	cui_tests::eq_vec2(row.size, {90, 40});     // 30 + 10 + 50, tallest child
	cui_tests::eq_vec2(a.offset, {0, 0});
	cui_tests::eq_vec2(b.offset, {40, 0});      // 30 + gap
}

fn void row_end_aligns() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} });
	Element* row = ui.@node((Row){ .size = {200, 0}, .main_align = END, .cross_align = END }, a, b);
	ui.build(ui.@node((Stack){}, row));
	ui.flush();

	test::eq(a.offset.x, 120.0f);               // 200 - (30 + 50)
	test::eq(b.offset.x, 150.0f);
	test::eq(a.offset.y, 20.0f);                // bottom-aligned against 40
	test::eq(b.offset.y, 0.0f);
}

fn void padding_insets_child() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {40, 30} });
	Element* pad = ui.@node((Padding){ .insets = widgets::insets_all(5) }, rect);
	ui.build(ui.@node((Stack){}, pad));
	ui.flush();

	cui_tests::eq_vec2(pad.size, {50, 40});     // child + insets on both sides
	cui_tests::eq_vec2(rect.offset, {5, 5});
}

fn void stack_fills_and_keeps_offsets() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {20, 20} });
	Element* stack = ui.@node((Stack){}, rect);
	ui.build(stack);
	ui.flush();

	cui_tests::eq_vec2(stack.size, cui_tests::WINDOW);   // zero size = fill

	rect.set_offset({33, 44});                  // absolute container: offsets are the app's
	ui.flush();
	cui_tests::eq_vec2(rect.offset, {33, 44});  // relayout must not clobber them
}

fn void constraint_cache_prunes_clean_siblings() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int layouts_a, layouts_b;
	Element* a = ui.@node((Probe){ .pref = {30, 20}, .layouts = &layouts_a });
	Element* b = ui.@node((Probe){ .pref = {50, 40}, .layouts = &layouts_b });
	ui.build(ui.@node((Stack){}, ui.@node((Column){ .gap = 10 }, a, b)));

	ui.flush();
	test::eq(layouts_a, 1);
	test::eq(layouts_b, 1);

	ui.flush();                                 // nothing dirty: no layout at all
	test::eq(layouts_a, 1);
	test::eq(layouts_b, 1);

	a.request_layout();                         // dirty spine descends to A...
	ui.flush();
	test::eq(layouts_a, 2);
	test::eq(layouts_b, 1);                     // ...but B is a constraint-cache hit
}
