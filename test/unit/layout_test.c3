// Layout: built-in containers' sizing and placement, and the constraint cache.
module cui_tests::layouts;
import cui;
import cui_tests;
import std::core::test;

fn void clamp_size_clamps() @test
{
	Constraints c = { .min = {10, 10}, .max = {100, 50} };
	cui_tests::eq_vec2(cui::clamp_size({500, 5}, c), {100, 10});
	cui_tests::eq_vec2(cui::clamp_size({50, 30}, c), {50, 30});
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
