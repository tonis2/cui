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

<*
 A pointer-transparent element does not win the hit test, even though it is
 painted last and its rect contains the point.

 This is the case that bites: hit testing picks the topmost rect whether or not
 that widget handles anything, and events bubble to PARENTS — so decoration
 overlaid on an interactive sibling used to make a dead zone. `Label` sets
 `ignores_pointer` for exactly this reason.
*>
fn void ignores_pointer_falls_through() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord under, over;
	Element* a = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &under });
	Element* b = ui.@node((EventProbe){ .pref = {60, 30}, .rec = &over, .transparent = true });
	ui.build(ui.@node((Stack){}, a, b));         // both at the origin; b paints last
	ui.flush();

	cui_tests::frame(ui, {10, 10});              // inside both rects
	test::@check(ui.hovered == a);               // the transparent one is skipped
	test::eq(under.enters, 1);
	test::eq(over.enters, 0);

	cui_tests::frame(ui, {10, 10}, left: true);
	test::eq(under.presses, 1);
	test::eq(over.presses, 0);
}

<*
 Transparency applies to the element itself, not its subtree: children are hit
 tested before the parent, so an interactive child of a transparent container
 still gets its events.
*>
fn void ignores_pointer_keeps_children_hittable() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord outer, inner;
	Element* child = ui.@node((EventProbe){ .pref = {40, 20}, .rec = &inner });
	Element* parent = ui.@node((EventProbe){ .pref = {100, 50}, .rec = &outer, .transparent = true }, child);
	ui.build(ui.@node((Stack){}, parent));
	ui.flush();

	cui_tests::frame(ui, {10, 10});              // over the child
	test::@check(ui.hovered == child);
	test::eq(inner.enters, 1);

	cui_tests::frame(ui, {80, 40});              // inside the parent, outside the child
	test::@check(ui.hovered != parent);          // the parent itself stays transparent
	test::eq(outer.enters, 0);
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

<*
 The held-key set a handler reads is the frame it was called for.

 A modifier and the key under it reach the embedder as two events, and one frame
 carries however many arrived since the last one — so Ctrl and A land together
 whenever they were pressed between the same two frames, which on a loop that
 sleeps for input is most of the time. An application resolving the chord asks
 `key_down(LEFT_CTRL)` while handling A: answered from the previous frame's set,
 the chord reads as the bare key and fires whatever that is bound to.
*>
fn void a_chord_inside_one_frame_reads_as_a_chord() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec = { .consume_key = true };
	Element* probe = ui.@node((EventProbe){
		.pref = {100, 50}, .rec = &rec, .watch = Key.LEFT_CTRL,
	});
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();

	cui_tests::frame(ui, {50, 25}, left: true);
	cui_tests::frame(ui, {50, 25});

	Key[2] both = { Key.LEFT_CTRL, Key.A };
	cui_tests::frame(ui, {50, 25}, keys: both[..]);
	test::eq(rec.last_key, Key.A);
	test::@check(rec.watched_at_key);

	// And the level state is gone on the frame the keys are: a handler asking
	// on the release edge is asking about a key that is up.
	cui_tests::frame(ui, {50, 25});
	test::eq(rec.key_ups, 2);
	test::@check(!rec.watched_at_key);
}

fn void cursor_resolves_from_hover_chain() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* btn = ui.@node((Button){ .size = {80, 30} });   // asks for POINTING_HAND
	ui.build(ui.@node((Stack){}, btn));
	ui.flush();

	cui_tests::frame(ui, {10, 10});
	test::eq(ui.cursor, Cursor.POINTING_HAND);

	cui_tests::frame(ui, {300, 80});
	test::eq(ui.cursor, Cursor.ARROW);           // no preference anywhere: default
}

fn void a_shape_asked_for_in_a_handler_lands_on_that_frame() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int layouts;
	Element* probe = ui.@node((CursorProbe){
		.pref = {80, 30}, .shape = Cursor.OPEN_HAND, .layouts = &layouts,
	});
	ui.build(ui.@node((Stack){}, probe));
	ui.flush();
	int sized = layouts;

	cui_tests::frame(ui, {10, 10});               // entering asks for the hand
	test::eq(ui.cursor, Cursor.OPEN_HAND);

	// The press closes it from on_mouse. Resolution runs after the dispatch, so
	// the shape is right on the frame that asked, not the one after.
	cui_tests::frame(ui, {10, 10}, left: true);
	test::eq(ui.cursor, Cursor.CLOSED_HAND);

	// And neither shape cost a layout: a cursor is not a layout question.
	test::eq(layouts, sized);
}

fn void a_button_asks_without_a_layout_of_its_own() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	// A Label-like child, transparent to the pointer, so the button itself is
	// what the pointer lands on — the arrangement its hand is written for.
	EventRecord rec;
	Element* inner = ui.@node((EventProbe){ .pref = {40, 20}, .rec = &rec, .transparent = true });
	Element* btn = ui.@node((Button){ .size = {80, 30} }, inner);
	ui.build(ui.@node((Stack){}, btn));
	ui.flush();

	// Sized by the field, with the child laid out inside it: Button has no layout.
	cui_tests::eq_vec2(btn.size, {80, 30});
	cui_tests::eq_vec2(inner.size, {40, 20});

	cui_tests::frame(ui, {10, 10});
	test::@check(ui.hovered == btn);
	test::eq(ui.cursor, Cursor.POINTING_HAND);
}

fn void no_preference_defers_to_the_ancestor() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	// The pointer lands on the probe, which asks for nothing; the shape comes
	// from the element above it, set from app code the way a viewport sets one
	// for everything drawn over it.
	EventRecord rec;
	Element* probe = ui.@node((EventProbe){ .pref = {40, 20}, .rec = &rec });
	Element* stack = ui.@node((Stack){}, probe);
	stack.set_cursor(Cursor.CROSSHAIR);
	ui.build(stack);
	ui.flush();

	cui_tests::frame(ui, {10, 10});
	test::@check(ui.hovered == probe);
	test::eq(ui.cursor, Cursor.CROSSHAIR);
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
