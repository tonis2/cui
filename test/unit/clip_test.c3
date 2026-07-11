// Clipping: the GPU struct contract, emit's clip stack, nested intersection,
// hit-test gating and release hygiene. All headless — clip entries and clip
// ids are asserted straight off ui.canvas.
module cui_tests::clips;
import cui;
import cui_tests;
import std::math;
import std::core::test;

// The canary for CPU/GPU struct desync: Drawing and ClipEntry are byte-copied
// into buffers the shader reads with scalar layout, so their C3 sizes are part
// of the GPU contract (see canvas.c3). A mismatch here renders scrambled.
fn void gpu_struct_contract() @test
{
	test::eq(Drawing::size, 96);
	test::eq(ClipEntry::size, 32);
}

macro void eq_vec4(Vec4 got, Vec4 want)
{
	test::eq(got.x, want.x);
	test::eq(got.y, want.y);
	test::eq(got.z, want.z);
	test::eq(got.w, want.w);
}

// A Clip pushes one entry with its absolute rect + radii; drawings inside
// carry its slot, drawings outside stay on slot 0.
fn void emit_writes_clip_slots() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* inside = ui.@node((Rectangle){ .size = {100, 50} });
	Element* clip = ui.@node((Clip){ .radii = {8, 8, 8, 8} }, inside);
	Element* outside = ui.@node((Rectangle){ .size = {10, 10} });
	ui.build(ui.@node((Stack){}, clip, outside));
	ui.flush();

	test::eq(ui.canvas.clips.len(), 2);
	eq_vec4(ui.canvas.clips[1].rect, {0, 0, 100, 50});
	eq_vec4(ui.canvas.clips[1].radii, {8, 8, 8, 8});
	test::eq(ui.canvas.drawings[inside.first_drawing].clip_id, (uint)1);
	test::eq(ui.canvas.drawings[outside.first_drawing].clip_id, (uint)0);
}

// Nested clips intersect at emit: the inner entry's rect is bounded by the
// outer's, and the inner radii win.
fn void nested_clips_intersect() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	// The inner clip is shifted to {40, 20} under an absolute Stack, so its own
	// rect {40, 20, 340, 100} crosses the outer clip {0, 0, 300, 90} on both
	// axes; the recorded entry must be the intersection.
	Element* rect = ui.@node((Rectangle){ .size = {300, 80} });
	Element* inner = ui.@node((Clip){ .radii = {6, 6, 6, 6} }, rect);
	Element* outer = ui.@node((Clip){}, ui.@node((Stack){ .size = {300, 90} }, inner));
	inner.set_offset({40, 20});
	ui.build(ui.@node((Stack){}, outer));
	ui.flush();

	test::eq(ui.canvas.clips.len(), 3);
	eq_vec4(ui.canvas.clips[1].rect, {0, 0, 300, 90});
	eq_vec4(ui.canvas.clips[2].rect, {40, 20, 300, 90});
	eq_vec4(ui.canvas.clips[2].radii, {6, 6, 6, 6});
	test::eq(ui.canvas.drawings[rect.first_drawing].clip_id, (uint)2);
}

// A clip gates hit testing: a child hanging outside the clip rect is visible
// nowhere, so it must be hittable nowhere — while its inside part still hits.
fn void clip_gates_hit_testing() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	EventRecord rec;
	Element* probe = ui.@node((EventProbe){ .pref = {60, 30}, .rec = &rec });
	Element* clip = ui.@node((Clip){}, ui.@node((Stack){ .size = {100, 50} }, probe));
	probe.set_offset({80, 10}); // probe rect {80,10}..{140,40}, clip ends at x=100
	ui.build(ui.@node((Stack){}, clip));
	ui.flush();

	cui_tests::frame(ui, {90, 20});
	test::eq(ui.hovered == probe, true);

	cui_tests::frame(ui, {120, 20}); // inside the probe rect, outside the clip
	test::eq(ui.hovered == probe, false);
	test::eq(rec.leaves, 1);
}

// Releasing a clipping subtree leaves no stale entries or ids behind, and the
// recycled element doesn't clip.
fn void clip_resets_on_release() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* clip = ui.@node((Clip){ .radii = {8, 8, 8, 8} }, ui.@node((Rectangle){ .size = {100, 50} }));
	Element* keeper = ui.@node((Rectangle){ .size = {10, 10} });
	Element* root = ui.@node((Stack){}, clip, keeper);
	ui.build(root);
	ui.flush();
	test::eq(ui.canvas.clips.len(), 2);

	ui.unmount(clip);
	ui.flush();

	test::eq(ui.canvas.clips.len(), 1);
	foreach (drawing : ui.canvas.drawings) test::eq(drawing.clip_id, (uint)0);

	// The recycled element must not inherit the old clip state.
	Element* reused = ui.@node((Rectangle){ .size = {5, 5} });
	test::eq(reused == clip, true); // free-list handed the same slot back
	test::eq(reused.clips, false);
	root.append(reused); // attach so ui.free releases it
}
