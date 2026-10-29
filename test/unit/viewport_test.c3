// The gesture helpers (DragTracker, Selection, View2D), the Viewport2D widget
// built on them, and the ContextMenu.
module cui_tests::viewports;
import cui;
import cui::widgets;
import cui_tests;
import std::math;
import std::core::test;

fn void a_press_becomes_a_drag_past_the_slop() @test
{
	DragTracker drag;
	drag.press({ 10, 10 }, MouseButton.LEFT);
	test::eq(drag.move({ 12, 10 }), false);
	test::eq(drag.state, DragState.PENDING);
	test::eq(drag.move({ 14, 10 }), true); // 4px > 3px slop
	test::eq(drag.move({ 20, 10 }), false); // only the crossing reports
	cui_tests::eq_vec2(drag.delta(), { 10, 0 });
	test::eq(drag.release(), DragState.DRAGGING);
	test::eq(drag.active(), false);

	drag.press({ 0, 0 }, MouseButton.LEFT);
	test::eq(drag.release(), DragState.PENDING); // a click

	drag.press({ 0, 0 }, MouseButton.LEFT);
	drag.move({ 50, 0 });
	test::eq(drag.cancel(), true);
	test::eq(drag.release(), DragState.IDLE); // Esc: nothing to commit
}

fn void selection_modes_follow_the_modifiers() @test
{
	Selection sel;
	defer sel.free();
	test::eq(cui::select_mode({ }), SelectMode.REPLACE);
	test::eq(cui::select_mode({ .shift = true }), SelectMode.ADD);
	test::eq(cui::select_mode({ .ctrl = true }), SelectMode.TOGGLE);

	sel.apply(REPLACE, { 1, 2 });
	sel.apply(ADD, { 3 });
	test::eq(sel.len(), (usz)3);
	sel.apply(TOGGLE, { 2, 4 });
	test::eq(sel.has(2), false);
	test::eq(sel.has(4), true);
	sel.apply(REPLACE, { });
	test::eq(sel.len(), (usz)0);

	test::eq(cui::boxes_overlap(cui::box_between({ 10, 10 }, { 0, 0 }), { 5, 5, 20, 20 }), true);
	test::eq(cui::boxes_overlap({ 0, 0, 10, 10 }, { 10, 0, 20, 10 }), false);
}

fn void zooming_keeps_the_anchor_still() @test
{
	View2D view = { .pan = { 100, 50 }, .zoom = 1 };
	Vec2 anchor = { 200, 80 };
	Vec2 before = view.to_plane(anchor);
	view.zoom_at(anchor, 2);
	test::eq(view.zoom, 2.0f);
	cui_tests::eq_vec2(view.to_plane(anchor), before);

	view.zoom_at(anchor, 1000); // clamped
	test::eq(view.zoom, 4.0f);

	view.pan_by({ 40, 0 }); // the plane follows the pointer right
	test::eq(view.pan.x < before.x, true);

	// One notch is one step on either platform's scale.
	test::eq(math::abs(cui::wheel_zoom_factor(1, false) - 1.15f) < 1e-5, true);
	test::eq(math::abs(cui::wheel_zoom_factor(15, false) - 1.15f) < 1e-5, true);

	view.frame({ 0, 0, 100, 50 }, { 400, 300 }, margin: 0, max_zoom: 10);
	test::eq(view.zoom, 4.0f); // 400 / 100, the tighter axis
	cui_tests::eq_vec2(view.to_screen({ 50, 25 }), { 200, 150 }); // centred
}

// A child on the plane is hit through the viewport's content transform, while
// the viewport's own clip stays fixed on screen.
fn void a_viewport_child_is_hit_where_it_is_drawn() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();

	EventRecord rec;
	rec.consume_mouse = true;
	Element* probe = ui.@node((EventProbe) { .pref = { 40, 20 }, .rec = &rec });
	Element* mark = ui.@node((Rectangle) { .size = { 5, 5 } });
	Element* viewport = ui.@node((Viewport2D) { .view = { .pan = { -10, 0 }, .zoom = 2 }, .size = { 300, 200 } }, mark, probe);
	probe.set_offset({ 20, 10 });
	ui.build(ui.@node((Stack) { }, viewport));
	ui.flush();

	// Plane {20, 10} → screen (20 + 10) * 2 = 60, 10 * 2 = 20.
	cui_tests::frame(ui, { 61, 21 }, left: true);
	test::eq(rec.presses, 1);
	cui_tests::eq_vec2(rec.last_pos, { 0.5f, 0.5f });

	// The viewport's own drawings and clip are not transformed.
	test::eq(ui.canvas.drawings[viewport.first_drawing].transform_id, (uint)0);
	ClipEntry clip = ui.canvas.clips[ui.canvas.drawings[mark.first_drawing].clip_id];
	test::eq(clip.slot, (uint)0);
	test::eq(clip.screen.z, 300.0f);
	test::eq(ui.canvas.drawings[mark.first_drawing].transform_id, viewport.transform_slot);
}

fn void a_middle_drag_pans_and_the_wheel_zooms() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();

	Element* viewport = ui.@node((Viewport2D) { .size = { 400, 300 } });
	ui.build(viewport);
	ui.flush();
	Viewport2D* vp = viewport.widget_as(Viewport2D);

	cui_tests::frame(ui, { 100, 100 }, middle: true);
	cui_tests::frame(ui, { 130, 110 }, middle: true);
	cui_tests::frame(ui, { 130, 110 });
	cui_tests::eq_vec2(vp.view.pan, { -30, -10 });

	Vec2 under = vp.view.to_plane({ 200, 150 });
	cui_tests::frame(ui, { 200, 150 }, scroll: 1);
	test::eq(vp.view.zoom > 1, true);
	cui_tests::eq_vec2(vp.view.to_plane({ 200, 150 }), under);
}

// -- ContextMenu ------------------------------------------------------------

ContextMenuItem[] menu_items = {
	{ .label = "Load image", .category = "Image" },
	{ .label = "Save image", .category = "Image" },
	{ .label = "Sampler", .category = "Sampling" },
	{ .label = "Broken", .category = "Sampling", .disabled = true },
	{ .label = "Seed", .category = "Sampling" },
};

sz chosen = -1;
int dismissed;
fn void on_menu_choose(Ui* ui, usz index) => chosen = (sz)index;
fn void on_menu_dismiss(Ui* ui) => dismissed++;

fn Element* open_menu(Ui* ui, bool searchable)
{
	chosen = -1;
	dismissed = 0;
	Element* menu = ui.@node((ContextMenu) {
		.items = menu_items,
		.on_choose = &on_menu_choose,
		.on_dismiss = &on_menu_dismiss,
		.searchable = searchable,
	});
	ui.build(ui.@node((Stack) { }, menu));
	ui.flush();
	menu.widget_as(ContextMenu).open_at(menu, { 50, 40 });
	ui.flush();
	return menu;
}

fn void the_keyboard_walks_and_chooses() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	Element* menu = open_menu(ui, false);
	ContextMenu* m = menu.widget_as(ContextMenu);
	test::eq(m.active, (sz)0);

	cui_tests::frame(ui, { 0, 0 }, keys: { Key.DOWN_ARROW });
	cui_tests::frame(ui, { 0, 0 });
	cui_tests::frame(ui, { 0, 0 }, keys: { Key.DOWN_ARROW });
	cui_tests::frame(ui, { 0, 0 });
	cui_tests::frame(ui, { 0, 0 }, keys: { Key.DOWN_ARROW });
	cui_tests::frame(ui, { 0, 0 });
	test::eq(m.active, (sz)4); // the disabled one is skipped

	cui_tests::frame(ui, { 0, 0 }, keys: { Key.RETURN });
	test::eq(chosen, (sz)4);
	test::eq(m.open, false);
	test::eq(dismissed, 0);
}

fn void the_search_narrows_and_return_takes_the_first_match() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	Element* menu = open_menu(ui, true);
	ContextMenu* m = menu.widget_as(ContextMenu);

	m.set_query("IMAGE"); // the category matches too, ignoring case
	test::eq(m.active, (sz)0);
	m.set_query("see");
	test::eq(m.active, (sz)4);
	m.set_query("nothing at all");
	test::eq(m.active, (sz)-1);

	m.set_query("sam");
	ui.flush();
	cui_tests::frame(ui, { 0, 0 }, keys: { Key.RETURN });
	test::eq(chosen, (sz)2);
}

fn void a_click_outside_dismisses_and_a_click_on_a_row_chooses() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	Element* menu = open_menu(ui, false);
	ContextMenu* m = menu.widget_as(ContextMenu);

	cui_tests::frame(ui, { 390, 290 }, left: true);
	cui_tests::frame(ui, { 390, 290 });
	test::eq(m.open, false);
	test::eq(dismissed, 1);

	m.open_at(menu, { 50, 40 });
	ui.flush();
	// The first row sits under the "Image" header, inside the panel's top pad.
	MenuStyle s = widgets::DEFAULT_MENU_STYLE;
	float header = s.item_height * widgets::CONTEXT_HEADER_RATIO;
	Vec2 row = { 50 + 40, 40 + widgets::PANEL_PAD_Y + header + s.item_height * 0.5f };
	cui_tests::frame(ui, row, left: true);
	cui_tests::frame(ui, row);
	test::eq(chosen, (sz)0);
}

// A dropdown on zoomed-out content: its click-anywhere catcher still covers
// the whole window, so a click far from it closes it.
String[] zoom_options = { "euler", "heun", "dpm++" };

fn void a_zoomed_out_select_closes_from_anywhere() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();

	Element* select = ui.@node((Select) { .options = zoom_options });
	Element* viewport = ui.@node((Viewport2D) { .view = { .zoom = 0.5 }, .size = { 400, 300 } }, select);
	select.set_offset({ 10, 10 });
	ui.build(ui.@node((Stack) { }, viewport));
	ui.flush();

	cui_tests::frame(ui, { 8, 8 }, left: true);
	cui_tests::frame(ui, { 8, 8 });
	ui.flush();
	test::eq(select.widget_as(Select).open, true);

	cui_tests::frame(ui, { 390, 290 }, left: true);
	cui_tests::frame(ui, { 390, 290 });
	ui.flush();
	test::eq(select.widget_as(Select).open, false);
}
