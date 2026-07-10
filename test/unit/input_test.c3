// Input: hit testing, hover, press/release edges, capture, bubbling, focus +
// key delivery, cursor resolution, scroll, and the per-frame update tick.
// process_input needs absolute origins, so every scenario flushes first.
module cui_tests::inputs;
import cui;
import cui_tests;
import std::core::test;

int g_clicks;

fn void count_click(Ui* ui)
{
	g_clicks++;
}

fn void hit_test_picks_topmost() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord under, over;
	Element* a = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &under });
	Element* b = ui.@node((EventProbe){ .pref = {60, 30}, .rec = &over });
	ui.build(ui.@node((Stack){}, a, b));         // both at the origin; b paints last
	ui.flush();

	cui_tests::frame(ui, {10, 10});
	test::@check(ui.hovered == b);               // reverse paint order: topmost wins
	test::eq(over.enters, 1);
	test::eq(under.enters, 0);
}

fn void hover_enter_leave() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	Element* probe = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &rec });
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();

	cui_tests::frame(ui, {50, 25});              // onto the probe
	test::eq(rec.enters, 1);
	test::@check(ui.hovered == probe);

	cui_tests::frame(ui, {300, 80});             // off it (still inside the window)
	test::eq(rec.leaves, 1);
	test::@check(ui.hovered != probe);
}

fn void press_release_edges_and_capture() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec = { .consume_mouse = true };
	Element* probe = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &rec });
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();

	cui_tests::frame(ui, {50, 25}, left: true);  // press edge
	test::eq(rec.presses, 1);
	test::@check(ui.input.pressed[0]);
	test::@check(ui.captured == probe);          // consuming a press captures

	cui_tests::frame(ui, {50, 25}, left: true);  // held: level, not edge
	test::eq(rec.presses, 1);
	test::@check(!ui.input.pressed[0]);
	test::@check(ui.input.down[0]);

	// Drag outside while held: capture keeps routing to the consumer, with the
	// position translated into its local space (negative/outside is expected).
	cui_tests::frame(ui, {300, 80}, left: true);
	test::@check(rec.moves > 0);
	cui_tests::eq_vec2(rec.last_pos, {300, 80});

	cui_tests::frame(ui, {300, 80});             // release outside
	test::eq(rec.releases, 1);
	test::@check(ui.input.released[0]);
	test::@check(ui.captured == null);
}

fn void bubbling_reaches_ancestor() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord outer_rec = { .consume_mouse = true };
	EventRecord inner_rec;                       // does not consume
	Element* inner = ui.@node((EventProbe){ .pref = {60, 30}, .rec = &inner_rec });
	Element* outer = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &outer_rec }, inner);
	ui.build(ui.@node((Stack){}, outer));
	ui.flush();

	cui_tests::frame(ui, {10, 10}, left: true);  // inside both
	test::eq(inner_rec.presses, 1);              // deepest first...
	test::eq(outer_rec.presses, 1);              // ...then bubbles up
	test::@check(ui.captured == outer);          // the consumer captures
}

fn void focus_and_key_delivery() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec = { .consume_key = true };
	Element* probe = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &rec });
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();

	cui_tests::frame(ui, {50, 25}, left: true);  // left press focuses on_key widgets
	cui_tests::frame(ui, {50, 25});
	test::@check(ui.focused == probe);

	Key[1] held = { Key.A };
	cui_tests::frame(ui, {50, 25}, keys: held[..]);
	test::eq(rec.key_downs, 1);                  // edge on the diff, not the level
	test::eq(rec.last_key, Key.A);
	test::@check(ui.input.key_down(Key.A));

	cui_tests::frame(ui, {50, 25});              // key released
	test::eq(rec.key_ups, 1);

	cui_tests::frame(ui, {300, 80}, left: true); // press where nothing takes keys
	test::@check(ui.focused == null);
}

fn void cursor_resolves_from_hover_chain() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* btn = ui.@node((Button){ .size = {80, 30} });   // sets POINTING_HAND
	ui.build(ui.@node((Stack){}, btn));
	ui.flush();

	cui_tests::frame(ui, {10, 10});
	test::eq(ui.cursor, Cursor.POINTING_HAND);

	cui_tests::frame(ui, {300, 80});
	test::eq(ui.cursor, Cursor.ARROW);           // no preference anywhere: default
}

fn void scroll_reaches_hovered() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	Element* probe = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &rec });
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();

	cui_tests::frame(ui, {50, 25}, scroll: 2.5f);
	test::eq(rec.scrolls, 1);
	test::eq(rec.last_scroll, 2.5f);
	test::eq(ui.input.scroll, 2.5f);
}

fn void button_clicks_on_release_inside() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	g_clicks = 0;

	Element* btn = ui.@node((Button){ .size = {80, 30}, .on_click = &count_click });
	ui.build(ui.@node((Stack){}, btn));
	ui.flush();

	cui_tests::frame(ui, {10, 10});
	cui_tests::frame(ui, {10, 10}, left: true);
	cui_tests::frame(ui, {10, 10});              // release inside -> click
	test::eq(g_clicks, 1);

	cui_tests::frame(ui, {10, 10}, left: true);
	cui_tests::frame(ui, {300, 90}, left: true); // drag out while held
	cui_tests::frame(ui, {300, 90});             // release outside -> no click
	test::eq(g_clicks, 1);
	test::@check(!btn.widget_as(Button).held);   // but the press state was cleared
}

fn void update_ticks_every_frame() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	ui.build(ui.@node((Stack){}, ui.@node((EventProbe){ .pref = {100, 50}, .rec = &rec })));
	ui.flush();

	cui_tests::frame(ui, {200, 80});
	cui_tests::frame(ui, {200, 80});
	cui_tests::frame(ui, {200, 80});
	test::eq(rec.updates, 3);                    // ticks regardless of hover/hit
}
