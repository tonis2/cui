// Transforms seen through: hit tests and event positions map back through
// set_transform, palette slots compose with the ancestors', and clips record
// the slot they live in so content zoomed inside a viewport clips on screen.
// Plus the input and paint-order pieces a zoomed canvas leans on: click counts,
// modifiers, move_child, and the path helpers.
module cui_tests::transforms;
import cui;
import cui_tests;
import std::math;
import std::math::matrix;
import std::core::test;

macro void eq_vec4(Vec4 got, Vec4 want)
{
	test::eq(got.x, want.x);
	test::eq(got.y, want.y);
	test::eq(got.z, want.z);
	test::eq(got.w, want.w);
}

// A pan-and-zoom the way a viewport sets it: scale about the content's corner,
// then slide it.
fn Matrix4f pan_zoom(Vec2 pan, float zoom)
{
	return matrix::IDENTITY4.translate({ pan.x, pan.y, 0 }).scale({ zoom, zoom, 1 });
}

// A probe at {10, 10} inside content zoomed 2x and slid by {20, 0}: on screen
// it covers {40, 20}..{80, 40}, and the event it gets is in its own, unzoomed
// pixels.
fn void a_zoomed_child_is_hit_where_it_is_drawn() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	rec.consume_mouse = true;
	Element* probe = ui.@node((EventProbe) { .pref = { 20, 10 }, .rec = &rec });
	Element* content = ui.@node((Stack) { .size = { 200, 100 } }, probe);
	probe.set_offset({ 10, 10 });
	ui.build(ui.@node((Stack) { }, content));
	content.set_transform(pan_zoom({ 20, 0 }, 2));
	ui.flush();

	cui_tests::frame(ui, { 25, 15 }); // where the probe sits unzoomed: not it
	test::eq(ui.hovered == probe, false);

	cui_tests::frame(ui, { 50, 30 }, left: true);
	test::eq(ui.hovered == probe, true);
	test::eq(rec.presses, 1);
	cui_tests::eq_vec2(rec.last_pos, { 5, 5 });

	cui_tests::eq_vec2(probe.to_local({ 50, 30 }), { 5, 5 });
	cui_tests::eq_vec2(probe.to_screen({ 5, 5 }), { 50, 30 });
}

// A capture keeps mapping: dragged off the probe, the move still arrives in
// its local, unzoomed pixels.
fn void a_captured_drag_reports_local_positions() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	rec.consume_mouse = true;
	Element* probe = ui.@node((EventProbe) { .pref = { 20, 10 }, .rec = &rec });
	Element* content = ui.@node((Stack) { .size = { 200, 100 } }, probe);
	ui.build(ui.@node((Stack) { }, content));
	content.set_transform(pan_zoom({ 0, 0 }, 0.5));
	ui.flush();

	cui_tests::frame(ui, { 4, 2 }, left: true);
	cui_tests::frame(ui, { 100, 50 }, left: true);
	cui_tests::eq_vec2(rec.last_pos, { 200, 100 });
}

// Nested transforms compose: the inner slot holds the outer matrix times the
// inner one, each anchored at its element's corner.
fn void nested_transforms_compose() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* leaf = ui.@node((Rectangle) { .size = { 10, 10 } });
	Element* inner = ui.@node((Stack) { .size = { 50, 50 } }, leaf);
	Element* outer = ui.@node((Stack) { .size = { 200, 100 } }, inner);
	inner.set_offset({ 30, 0 });
	ui.build(ui.@node((Stack) { }, outer));
	outer.set_transform(pan_zoom({ 0, 0 }, 2));
	inner.set_transform(pan_zoom({ 0, 0 }, 3));
	ui.flush();

	// The leaf's corner {30, 0} stays put under the inner zoom (it is the
	// inner element's own corner) and lands at {60, 0} under the outer one; a
	// point 1px right of it moves 3 * 2 = 6px on screen.
	Matrix4f m = ui.canvas.transforms[inner.transform_slot];
	cui_tests::eq_vec2(cui::transform_point(m, { 30, 0 }), { 60, 0 });
	cui_tests::eq_vec2(cui::transform_point(m, { 31, 0 }), { 66, 0 });
	test::eq(ui.canvas.drawings[leaf.first_drawing].transform_id, inner.transform_slot);

	// And a pan written after the flush re-emits, because the inner slot
	// depends on the outer one.
	outer.set_transform(pan_zoom({ 5, 0 }, 2));
	ui.flush();
	m = ui.canvas.transforms[inner.transform_slot];
	cui_tests::eq_vec2(cui::transform_point(m, { 30, 0 }), { 65, 0 });
}

// The pan path stays cheap: with nothing transformed below it, a second
// set_transform writes the palette and asks for no re-emit.
fn void a_pan_is_a_palette_write() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int paints;
	Element* probe = ui.@node((Probe) { .pref = { 20, 20 }, .paints = &paints });
	Element* content = ui.@node((Stack) { .size = { 200, 100 } }, probe);
	ui.build(ui.@node((Stack) { }, content));
	content.set_transform(pan_zoom({ 0, 0 }, 1));
	ui.flush();
	int before = paints;

	content.set_transform(pan_zoom({ 40, 10 }, 1.5));
	test::eq(ui.paint_pending, false);
	ui.flush();
	test::eq(paints, before);
	cui_tests::eq_vec2(cui::transform_point(ui.canvas.transforms[content.transform_slot], { 10, 10 }), { 55, 25 });
}

// A clipping viewport around zoomed content: the content's drawings carry the
// viewport's entry, recorded in the viewport's slot with its screen box, and a
// clip inside the content lives in the content's slot with the viewport in
// `outer`.
fn void clips_record_their_slot() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* loose = ui.@node((Rectangle) { .size = { 30, 30 } });
	Element* card_rect = ui.@node((Rectangle) { .size = { 40, 40 } });
	Element* card = ui.@node((Clip) { }, card_rect);
	Element* content = ui.@node((Stack) { .size = { 400, 400 } }, loose, card);
	card.set_offset({ 50, 0 });
	Element* viewport = ui.@node((Clip) { }, ui.@node((Stack) { .size = { 300, 80 } }, content));
	ui.build(ui.@node((Stack) { }, viewport));
	content.set_transform(pan_zoom({ 0, 0 }, 2));
	ui.flush();

	uint view_clip = ui.canvas.drawings[loose.first_drawing].clip_id;
	ClipEntry view = ui.canvas.clips[view_clip];
	test::eq(view.slot, (uint)0);
	eq_vec4(view.screen, { 0, 0, 300, 80 });
	test::eq(ui.canvas.drawings[loose.first_drawing].transform_id, content.transform_slot);

	ClipEntry inner = ui.canvas.clips[ui.canvas.drawings[card_rect.first_drawing].clip_id];
	test::eq(inner.slot, content.transform_slot);
	eq_vec4(inner.rect, { 50, 0, 90, 40 });
	eq_vec4(inner.screen, { 100, 0, 180, 80 });
	eq_vec4(inner.outer, { 0, 0, 300, 80 });
}

// The second press of the same button close by, and soon, is a double click;
// modifiers held with it come along.
fn void presses_count_clicks() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	ui.build(ui.@node((EventProbe) { .pref = { 100, 100 }, .rec = &rec }));
	ui.flush();

	cui_tests::frame(ui, { 10, 10 }, left: true);
	test::eq(rec.last_clicks, (char)1);
	cui_tests::frame(ui, { 10, 10 });
	test::eq(rec.last_clicks, (char)1); // the release carries its press's count
	cui_tests::frame(ui, { 11, 10 }, left: true, keys: { Key.LEFT_SHIFT });
	test::eq(rec.last_clicks, (char)2);
	test::eq(rec.last_mods.shift, true);
	test::eq(rec.last_mods.ctrl, false);
	cui_tests::frame(ui, { 11, 10 });

	// Too far away: a new click.
	cui_tests::frame(ui, { 40, 10 }, left: true);
	test::eq(rec.last_clicks, (char)1);
	cui_tests::frame(ui, { 40, 10 });

	// Too late: a new click.
	for (int i = 0; i < 30; i++) cui_tests::frame(ui, { 40, 10 });
	cui_tests::frame(ui, { 40, 10 }, left: true);
	test::eq(rec.last_clicks, (char)1);
}

// move_child changes who paints on top and who wins the hit test, and keeps
// both elements — nothing is rebuilt.
fn void move_child_reorders_without_rebuilding() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord a_rec;
	EventRecord b_rec;
	Element* a = ui.@node((EventProbe) { .pref = { 50, 50 }, .rec = &a_rec });
	Element* b = ui.@node((EventProbe) { .pref = { 50, 50 }, .rec = &b_rec });
	Element* stack = ui.@node((Stack) { }, a, b);
	ui.build(stack);
	ui.flush();

	cui_tests::frame(ui, { 10, 10 });
	test::eq(ui.hovered == b, true);

	a.bring_to_front();
	ui.flush();
	test::eq(stack.children[1] == a, true);
	test::eq(stack.children[0] == b, true);
	cui_tests::frame(ui, { 11, 10 });
	test::eq(ui.hovered == a, true);
}

// A Bézier curve flattens into LINE drawings that pass through both ends, and
// the distance to it is small on it and large off it.
fn void bezier_draws_and_measures() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem = ui.@node((Rectangle) { .size = { 10, 10 } });
	ui.build(elem);
	ui.flush();

	Painter painter = { .element = elem };
	elem.local_drawings.clear();
	painter.bezier({ 0, 0 }, { 100, 0 }, { 100, 100 }, { 200, 100 }, 2, { 1, 1, 1, 1 });
	sz solid = elem.local_drawings.len();
	test::eq(solid >= 4, true);
	test::eq(solid <= (sz)cui::BEZIER_MAX_SEGMENTS, true);
	foreach (d : elem.local_drawings) test::eq(d.kind, DrawingKind.LINE);

	elem.local_drawings.clear();
	painter.bezier({ 0, 0 }, { 100, 0 }, { 100, 100 }, { 200, 100 }, 2, { 1, 1, 1, 1 }, dash: 8);
	test::eq(elem.local_drawings.len() > 0, true);

	test::eq(cui::bezier_distance({ 0, 0 }, { 0, 0 }, { 100, 0 }, { 100, 100 }, { 200, 100 }) < 0.01f, true);
	test::eq(cui::bezier_distance({ 100, 50 }, { 0, 0 }, { 100, 0 }, { 100, 100 }, { 200, 100 }) < 1.0f, true);
	test::eq(cui::bezier_distance({ 0, 100 }, { 0, 0 }, { 100, 0 }, { 100, 100 }, { 200, 100 }) > 40.0f, true);
	elem.local_drawings.clear();
}
