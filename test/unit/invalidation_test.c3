// Invalidation and lifecycle: pending flags, the paint cache, the dirty spine,
// append/unmount, element recycling, and the interactivity-pointer safety on
// release.
module cui_tests::invalidations;
import cui;
import cui_tests;
import std::core::test;

fn void flush_clears_pendings() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	ui.build(ui.@node((Stack){}, ui.@node((Rectangle){ .size = {30, 20} })));
	test::@check(ui.layout_pending);
	test::@check(ui.paint_pending);
	test::@check(ui.frame_requested);

	ui.flush();
	test::@check(!ui.layout_pending);
	test::@check(!ui.paint_pending);
}

fn void repaint_reruns_only_dirty_paint() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int paints_a, paints_b;
	Element* a = ui.@node((Probe){ .pref = {30, 20}, .paints = &paints_a });
	Element* b = ui.@node((Probe){ .pref = {50, 40}, .paints = &paints_b });
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, a, b)));

	ui.flush();
	test::eq(paints_a, 1);
	test::eq(paints_b, 1);

	a.request_paint();
	ui.flush();
	test::eq(paints_a, 2);
	test::eq(paints_b, 1);                       // B re-emitted from its cache
}

fn void request_layout_marks_ancestor_spine() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	Element* pad = ui.@node((Padding){ .insets = widgets::insets_all(5) }, rect);
	Element* col = ui.@node((Column){}, pad);
	Element* root = ui.@node((Stack){}, col);
	ui.build(root);
	ui.flush();

	rect.request_layout();
	test::@check(rect.dirty.layout);
	test::@check(pad.dirty.layout);              // the walk must descend here...
	test::@check(col.dirty.layout);
	test::@check(root.dirty.layout);             // ...from the root down
	test::@check(ui.layout_pending);
}

fn void frame_requested_by_every_invalidation() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	ui.build(ui.@node((Stack){}, rect));
	ui.flush();

	ui.frame_requested = false;                  // the render loop consumed it
	rect.request_paint();
	test::@check(ui.frame_requested);

	ui.frame_requested = false;
	rect.request_layout();
	test::@check(ui.frame_requested);
}

fn void append_grafts_and_lays_out() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* col = ui.@node((Column){});
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	col.append(rect);
	test::@check(ui.layout_pending);
	ui.flush();

	test::eq(col.children.len(), 1);
	cui_tests::eq_vec2(rect.size, {30, 20});
	cui_tests::eq_vec2(col.size, {30, 20});      // container re-wrapped its content
}

fn void unmount_recycles_and_fires_hook() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int unmounts;
	Element* probe = ui.@node((UnmountProbe){ .count = &unmounts });
	Element* col = ui.@node((Column){}, probe);
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	ui.unmount(probe);
	test::eq(unmounts, 1);
	test::eq(col.children.len(), 0);
	test::eq(ui.free_elements.len(), 1);         // back on the free-list
}

fn void release_clears_interactivity_pointers() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	ui.build(ui.@node((Stack){}, rect));
	ui.flush();

	// Elements recycle through a free-list: a stale pointer would silently
	// retarget whatever reuses the slot. Release must sever these.
	ui.hovered = rect;
	ui.captured = rect;
	ui.focused = rect;
	ui.unmount(rect);

	test::@check(ui.hovered == null);
	test::@check(ui.captured == null);
	test::@check(ui.focused == null);
}

fn void freed_elements_are_reused() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* col = ui.@node((Column){});
	ui.build(ui.@node((Stack){}, col));
	ui.flush();

	Element* rect = ui.@node((Rectangle){ .size = {30, 20} });
	col.append(rect);
	ui.flush();
	sz total = ui.all_elements.len();

	ui.unmount(rect);
	test::eq(ui.free_elements.len(), 1);

	col.append(ui.@node((Rectangle){ .size = {10, 10} }));
	test::eq(ui.free_elements.len(), 0);         // slot reused, not grown
	test::eq(ui.all_elements.len(), total);
}
