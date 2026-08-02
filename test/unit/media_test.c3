// Media: what a widget is told about the screen it is on, and the placement
// arithmetic built on it. Headless and fontless, so the menu bar's titles are
// their 2*pad_x floor and its rows are PANEL_MIN_W wide.
module cui_tests::medias;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;

// Records what `media()` answered during layout — the moment a real widget
// would be deciding its shape, and the moment a box has to already be right.
struct MediaProbe (Widget)
{
	Media seen;
}

fn Vec2 MediaProbe.layout(&self, Element* elem, Constraints c) @dynamic
{
	self.seen = elem.media();
	return c.max; // fills, so a pane holding one is the size of its pane
}

// The shape of every media box: publish the rect, THEN lay out what is inside
// it. AreaPane and AreaHost are this, with panes in them.
struct Screen (Widget)
{
	Vec2 box; // 0 = whatever it is offered
}

fn Vec2 Screen.layout(&self, Element* elem, Constraints c) @dynamic
{
	Vec2 own = { self.box.x > 0 ? self.box.x : c.max.x, self.box.y > 0 ? self.box.y : c.max.y };
	elem.media_box = own;
	for (sz i = 0; i < elem.children.len(); i++)
	{
		elem.layout_child(i, { .min = { 0, 0 }, .max = own });
	}
	return own;
}

// A view builder for the AreaHost tests: one probe per pane.
fn Element* build_probe(Ui* ui)
{
	return ui.@node((MediaProbe) { });
}

AreaLayout m_layout;
AreaView[1] m_views = { { .name = "P", .build = &build_probe } };

// ---------------------------------------------------------------------------
// What a widget sees

fn void media_defaults_to_the_window() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* probe = ui.@node((MediaProbe) { });
	ui.build(ui.@node((Stack) { }, probe));
	ui.flush();

	Media seen = probe.widget_as(MediaProbe).seen;
	cui_tests::eq_vec2(seen.size, cui_tests::WINDOW);
	cui_tests::eq_vec2(seen.origin, { 0, 0 });
	// Nothing set one, and a fresh Ui must not report zero: widgets divide by it.
	test::eq(seen.pixel_ratio, 1.0f);
}

fn void pixel_ratio_reaches_the_widget() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	ui.pixel_ratio = 2.0f; // what the renderer pushes in on a retina display

	Element* probe = ui.@node((MediaProbe) { });
	ui.build(ui.@node((Stack) { }, probe));
	ui.flush();

	test::eq(probe.widget_as(MediaProbe).seen.pixel_ratio, 2.0f);
}

fn void a_published_box_replaces_the_window_under_it() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* inside = ui.@node((MediaProbe) { });
	Element* outside = ui.@node((MediaProbe) { });
	ui.build(ui.@node((Stack) { },
		ui.@node((Screen) { .box = { 120, 60 } }, inside),
		outside));
	ui.flush();

	cui_tests::eq_vec2(inside.widget_as(MediaProbe).seen.size, { 120, 60 });
	// A box covers its subtree and nothing else — the sibling is still on the
	// window, which is what makes this an override rather than a global.
	cui_tests::eq_vec2(outside.widget_as(MediaProbe).seen.size, cui_tests::WINDOW);
}

fn void the_innermost_box_wins() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* probe = ui.@node((MediaProbe) { });
	ui.build(ui.@node((Screen) { .box = { 300, 80 } },
		ui.@node((Screen) { .box = { 100, 40 } }, probe)));
	ui.flush();

	cui_tests::eq_vec2(probe.widget_as(MediaProbe).seen.size, { 100, 40 });
}

fn void the_origin_is_where_the_box_sits() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* probe = ui.@node((MediaProbe) { });
	Element* screen = ui.@node((Screen) { .box = { 120, 60 } }, probe);
	screen.set_offset({ 40, 25 });
	ui.build(ui.@node((Stack) { }, screen));
	ui.flush();

	// Two passes, and that is the contract rather than an accident of the test:
	// `origin` is where the emit pass last put the box, and the first layout of
	// a tree runs before anything has been emitted. Placement code reads it a
	// frame after the box moves — the same one-pass lag `Select` and `AreaHost`
	// already accept for offsetting a popup by `absolute`.
	probe.request_layout();
	ui.flush();

	// Absolute coordinates, so placement code can compare against them directly.
	cui_tests::eq_vec2(probe.widget_as(MediaProbe).seen.origin, { 40, 25 });
}

fn void a_box_is_published_before_its_children_lay_out() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* probe = ui.@node((MediaProbe) { });
	ui.build(ui.@node((Screen) { .box = { 120, 60 } }, probe));
	ui.flush();

	// The whole reason media_box is a size set from layout() and not the box
	// element's own `size`: an element's size is assigned only after its layout
	// returns, so on this first pass a child reading it would see zero — and
	// with constraints unchanged, layout would never run again to correct it.
	cui_tests::eq_vec2(probe.widget_as(MediaProbe).seen.size, { 120, 60 });
}

// ---------------------------------------------------------------------------
// The arithmetic

fn void fraction_is_a_share_of_the_screen() @test
{
	Media m = { .size = { 400, 300 }, .origin = { 0, 0 }, .pixel_ratio = 1.0 };
	cui_tests::eq_vec2(m.fraction({ 0.5, 1.0 }), { 200, 300 });
}

fn void clamp_rect_keeps_a_popup_on_screen() @test
{
	Media m = { .size = { 400, 300 }, .origin = { 0, 0 }, .pixel_ratio = 1.0 };

	// Already inside: untouched.
	cui_tests::eq_vec2(m.clamp_rect({ 10, 20 }, { 100, 50 }), { 10, 20 });
	// Off the right and the bottom: slid back by exactly the overhang.
	cui_tests::eq_vec2(m.clamp_rect({ 380, 290 }, { 100, 50 }), { 300, 250 });
	// Off the top-left: pushed in.
	cui_tests::eq_vec2(m.clamp_rect({ -30, -5 }, { 100, 50 }), { 0, 0 });
	// Bigger than the screen: pinned to the corner rather than centred, so what
	// is cut off is the tail.
	cui_tests::eq_vec2(m.clamp_rect({ 20, 20 }, { 500, 400 }), { 0, 0 });
}

fn void clamp_rect_respects_a_moved_origin() @test
{
	Media m = { .size = { 200, 200 }, .origin = { 50, 50 }, .pixel_ratio = 1.0 };
	cui_tests::eq_vec2(m.clamp_rect({ 0, 0 }, { 10, 10 }), { 50, 50 });
	cui_tests::eq_vec2(m.clamp_rect({ 1000, 1000 }, { 10, 10 }), { 240, 240 });
}

fn void drop_hangs_under_the_anchor_when_it_fits() @test
{
	Media m = { .size = { 400, 300 }, .origin = { 0, 0 }, .pixel_ratio = 1.0 };
	cui_tests::eq_vec2(m.drop({ 10, 20 }, 30.0, { 100, 100 }), { 10, 50 });
}

fn void drop_flips_above_when_that_is_the_roomy_side() @test
{
	Media m = { .size = { 400, 300 }, .origin = { 0, 0 }, .pixel_ratio = 1.0 };
	// A chooser near the bottom: 30px below it, 250 above.
	cui_tests::eq_vec2(m.drop({ 10, 250 }, 20.0, { 100, 100 }), { 10, 150 });
}

fn void drop_slides_rather_than_flipping_off_a_top_anchor() @test
{
	Media m = { .size = { 400, 300 }, .origin = { 0, 0 }, .pixel_ratio = 1.0 };
	// A bar at the top of a short screen: nothing above it, so flipping would
	// leave the screen entirely. It stays below and slides up over the bar.
	cui_tests::eq_vec2(m.drop({ 0, 0 }, 28.0, { 100, 290 }), { 0, 10 });
	// Taller than the screen: as far up as there is, and the tail is the
	// caller's problem.
	cui_tests::eq_vec2(m.drop({ 0, 0 }, 28.0, { 100, 400 }), { 0, 0 });
}

// ---------------------------------------------------------------------------
// The two widgets that use it

fn void a_pane_is_the_screen_its_view_is_on() @test
{
	Ui* ui = cui::new_ui(cui_tests::areas::AREA_WINDOW);
	defer ui.free();
	m_layout.init(m_views[..]);
	defer m_layout.free();

	@canvas(ui)
	{
		@node((AreaHost) { .areas = &m_layout });
	};
	ui.flush();

	// One pane: the whole host, tab strip included — the strip is part of the
	// pane, and a view that wants the room under it has its constraints for that.
	Element* only = ui.find(MediaProbe)!!;
	cui_tests::eq_vec2(only.widget_as(MediaProbe).seen.size, cui_tests::areas::AREA_WINDOW);

	cui_tests::areas::split(ui, { 400, 300 }, "Split Vertical");

	// Split: each view sees its own half, not the window. This is the whole
	// point — a view that sized itself against the window would lay out for
	// room it cannot draw into.
	float pane_w = (cui_tests::areas::AREA_WINDOW.x - 5.0f) * 0.5f;
	usz seen = 0;
	ui.@each(MediaProbe; elem)
	{
		seen++;
		Media m = elem.widget_as(MediaProbe).seen;
		test::@check(math::abs(m.size.x - pane_w) < 0.6f);
		test::eq(m.size.y, cui_tests::areas::AREA_WINDOW.y);
		// And the right-hand pane knows it is the right-hand one.
		test::@check(m.origin.x == 0.0f || math::abs(m.origin.x - (pane_w + 5.0f)) < 0.6f);
	};
	test::eq(seen, 2ul);
}

usz picked @local = 0;

fn void pick_one(Ui* ui) { picked = 1; }
fn void pick_two(Ui* ui) { picked = 2; }

MenuItem[3] short_items = {
	{ .label = "One", .on_select = &pick_one },
	{ .label = "Two", .on_select = &pick_two },
	{ .label = "Three" },
};

// Where to press on the only title: inside it (fontless, so 24 x 28), and low
// enough that the panel which appears — slid up to y = 12, its first row from
// y = 17 — has that row under the pointer rather than its own top padding.
// That overlap is the case worth testing; aiming at the title's middle would
// land on the chrome and prove nothing.
const Vec2 MENU_AIM = { 12, 20 };

// Press, flush, release, flush — one frame each, the way a render loop runs
// them. The shared `click` helper flushes only at the end, which would dispatch
// the release against the tree from before the menu opened: exactly the frame
// where the panel is not there yet, and the one this file must not test.
fn void click_framed(Ui* ui, Vec2 at)
{
	cui_tests::frame(ui, at, left: true);
	ui.flush();
	cui_tests::frame(ui, at, left: false);
	ui.flush();
}

// A bar over a screen too short to hang its own menu below it — 28 for the bar
// and 88 for the panel, in 100.
fn Ui* short_bar_ui(Menu[] menus)
{
	Ui* ui = cui::new_ui({ 400, 100 });
	ui.build(ui.@node((Screen) { }, ui.@node((MenuBar) { .menus = menus })));
	ui.flush();
	return ui;
}

fn void a_dropdown_stays_on_a_short_screen() @test
{
	Menu[1] menus = { { .title = "M", .items = short_items[..] } };
	Ui* ui = short_bar_ui(menus[..]);
	defer ui.free();

	// Open it: fontless, so the title is its 2 * pad_x floor.
	click_framed(ui, MENU_AIM);

	Element* panel = ui.find(PopupPanel)!!;
	float height = 3 * 26.0f + 2 * 5.0f;
	test::eq(panel.size.y, height);
	// Slid up until its bottom is the screen's, overlapping the bar it hangs
	// from. Without this it would sit at y = 28 and the last row would be drawn
	// past the bottom edge — invisible under a screen that clips.
	test::eq(panel.absolute.y, 100.0f - height);
	test::@check(panel.absolute.y >= 0.0f);
}

fn void the_click_that_opens_a_menu_does_not_choose_from_it() @test
{
	Menu[1] menus = { { .title = "M", .items = short_items[..] } };
	Ui* ui = short_bar_ui(menus[..]);
	defer ui.free();
	picked = 0;

	// The press is on the title; the panel that appears under it is placed over
	// the bar, so the release lands on a row. Nothing may be chosen by it, and
	// the menu has to still be open.
	click_framed(ui, MENU_AIM);
	test::eq(picked, 0ul);
	bool still_open = false;
	if (try Element* row = ui.find_id("One")) still_open = true;
	test::@check(still_open);
}

fn void a_drag_from_the_title_onto_an_item_still_chooses() @test
{
	Menu[1] menus = { { .title = "M", .items = short_items[..] } };
	Ui* ui = short_bar_ui(menus[..]);
	defer ui.free();
	picked = 0;

	// Press on the title, slide down onto the second row, release: the other way
	// to use a menu, and the one the swallowed release must not cost.
	cui_tests::frame(ui, MENU_AIM, left: true);
	ui.flush();
	Element* second = ui.find_id("Two")!!;
	Vec2 on_two = second.absolute + second.size * 0.5f;
	cui_tests::frame(ui, on_two, left: true);
	cui_tests::frame(ui, on_two, left: false);
	ui.flush();

	test::eq(picked, 2ul);
	test::@error(ui.find_id("One"), cui::WIDGET_NOT_FOUND); // and it closed
}
