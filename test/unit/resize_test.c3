// What a window changing size does to the tree: `Ui.resize`, the embedder's
// entry point, and the two passes it has to schedule.
module cui_tests::resizes;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

// Twice as wide and half as tall as the fixture window — different on both axes
// and in both directions, so a resize that only ever grows would not pass.
const Vec2 BIGGER = { cui_tests::WINDOW.x * 2, cui_tests::WINDOW.y * 0.5 };

fn void a_resize_relays_the_tree_out() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int layouts;
	// Asks for more than any window has: `Probe.layout` constrains what it asks
	// for, so it comes back sized to whatever it was offered, and it counts the
	// calls — which a plain fill-parent widget does not.
	Element* filler = ui.@node((Probe){ .pref = {10_000, 10_000}, .layouts = &layouts });
	ui.build(ui.@node((Stack){}, filler));
	ui.flush();

	cui_tests::eq_vec2(filler.size, cui_tests::WINDOW);
	test::eq(layouts, 1);

	ui.resize(BIGGER);
	test::@check(ui.layout_pending);
	ui.flush();

	cui_tests::eq_vec2(filler.size, BIGGER);
	test::eq(layouts, 2);
}

fn void a_resize_moves_what_it_did_not_resize() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int paints;
	Element* badge = ui.@node((Probe){ .pref = {40, 20}, .paints = &paints });
	ui.build(ui.@node((Stack){}, ui.@node((Anchored){ .h = END, .v = END }, badge)));
	ui.flush();

	cui_tests::eq_vec2(badge.absolute, {
		cui_tests::WINDOW.x - 40,
		cui_tests::WINDOW.y - 20,
	});

	// The badge is the same 40x20 it was, so nothing about it is dirty and its
	// `paint` does not re-run — but the corner it is pinned to has moved, and the
	// canvas holds absolute coordinates. Only a re-emit puts it there.
	ui.resize(BIGGER);
	ui.flush();

	cui_tests::eq_vec2(badge.size, {40, 20});
	test::eq(paints, 1);
	cui_tests::eq_vec2(badge.absolute, { BIGGER.x - 40, BIGGER.y - 20 });
}

fn void a_resize_is_the_new_screen() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	ui.build(ui.@node((Stack){}, rect));
	ui.flush();

	// What a widget deciding its shape reads — a dropdown asking whether it has
	// room to open downwards gets the window it is actually in, not the one the
	// application opened at.
	ui.resize(BIGGER);
	cui_tests::eq_vec2(rect.media().size, BIGGER);
}

fn void the_size_it_already_is_costs_nothing() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	ui.build(ui.@node((Stack){}, ui.@node((Rectangle){ .size = {30, 20} })));
	ui.flush();
	ui.frame_requested = false; // the render loop consumed it

	// The reference renderer polls the surface every frame and calls this with
	// whatever it finds, so the unchanged case is the common one: it must not
	// schedule a frame, or an on-demand loop never sleeps again.
	ui.resize(cui_tests::WINDOW);
	test::@check(!ui.layout_pending);
	test::@check(!ui.paint_pending);
	test::@check(!ui.frame_requested);
}
