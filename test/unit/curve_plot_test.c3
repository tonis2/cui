// CurvePlot. Headless, so the geometry is the style's numbers: a point's pixel
// is found through the widget's own mapping and pressed there.
module cui_tests::curve_plot;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;
import std::math::vector;

int pressed @local;
int drags @local;
int dones @local;
Vec2 landed @local;
int handle_dones @local;
Vec2 handle_to @local;
float scrubbed @local;
int views @local;
usz[8] boxed @local;
usz boxed_count @local;
CurveBox box_mode @local;
int scale_dones @local;
usz scaled_point @local;
CurveLock scaled_axis @local;
float scale_factor @local;
float scale_pivot @local;
int copies @local;
int pastes @local;

fn void note_box(Ui* ui, usz[] indices, CurveBox mode) @local
{
	boxed_count = indices.len;
	foreach (i, index : indices) boxed[i] = index;
	box_mode = mode;
}
fn void note_scale(Ui* ui, usz index, CurveLock axis, float factor, float pivot, bool done) @local
{
	if (!done) return;
	scale_dones++;
	scaled_point = index;
	scaled_axis = axis;
	scale_factor = factor;
	scale_pivot = pivot;
}
fn void note_copy(Ui* ui) @local
{
	copies++;
}
fn void note_paste(Ui* ui) @local
{
	pastes++;
}

fn void note_point(Ui* ui, usz index, bool toggle) @local
{
	pressed = (int)index;
}
fn void note_drag(Ui* ui, usz index, Vec2 to, bool done) @local
{
	drags++;
	if (done)
	{
		dones++;
		landed = to;
	}
}
fn void note_handle(Ui* ui, usz index, Vec2 to, bool done) @local
{
	if (done)
	{
		handle_dones++;
		handle_to = to;
	}
}
fn void note_scrub(Ui* ui, float x) @local
{
	scrubbed = x;
}
fn void note_view(Ui* ui, float zoom, float start) @local
{
	views++;
}

fn void reset() @local
{
	pressed = -1;
	drags = 0;
	dones = 0;
	handle_dones = 0;
	scrubbed = -1;
	views = 0;
	boxed_count = 0;
	scale_dones = 0;
	copies = 0;
	pastes = 0;
}

Vec2[3] line = { { 0, 0 }, { 1, 10 }, { 2, 0 } };

fn Element* plot(Ui* ui, CurveSeries[] series, CurvePoint[] points, CurveHandle[] handles) @local
{
	Element* elem = ui.@node(
		(CurvePlot) {
			.series = series,
			.points = points,
			.handles = handles,
			.x_min = 0,
			.x_max = 2,
			.snap_x = 0.5f,
			.on_point = &note_point,
			.on_point_drag = &note_drag,
			.on_handle_drag = &note_handle,
			.on_scrub = &note_scrub,
			.on_view = &note_view,
			.on_box = &note_box,
			.on_scale = &note_scale,
			.on_copy = &note_copy,
			.on_paste = &note_paste,
		}
	);
	ui.build(ui.@node((Column) { .size = { 400, 300 } }, elem));
	ui.flush();
	return elem;
}

<*
 Pixels and data round-trip, the fit covers the curve, and a press on a point
 reports it while a press elsewhere scrubs to the snapped x.
*>
fn void a_curve_plot_maps_and_picks() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurveSeries[1] series = { { .points = line[..] } };
	CurvePoint[2] points  = { { .at = { 1, 10 } }, { .at = { 2, 0 } } };
	Element* elem         = plot(ui, series[..], points[..], { });
	CurvePlot* widget     = elem.widget_as(CurvePlot);

	test::eq(elem.size.y, widgets::DEFAULT_CURVE_PLOT_STYLE.height);
	Vec2 range = widget.y_range();
	test::@check(range.x < 0 && range.y > 10, "the fit misses the curve");
	Vec2 pixel = widget.pixel_of(elem, { 1, 10 });
	Vec2 back  = widget.data_of(elem, pixel);
	test::@check(math::abs(back.x - 1) < 1e-4 && math::abs(back.y - 10) < 1e-3, "pixels do not round-trip");

	cui_tests::frame(ui, pixel);
	cui_tests::frame(ui, pixel, left: true);
	cui_tests::frame(ui, pixel);
	ui.flush();
	test::eq(pressed, 0);
	test::eq(drags, 0);

	Vec2 empty = widget.pixel_of(elem, { 0.4f, 3 });
	cui_tests::frame(ui, empty);
	cui_tests::frame(ui, empty, left: true);
	cui_tests::frame(ui, empty);
	ui.flush();
	test::@check(scrubbed == 0.5f, "a press off the points scrubbed to %f", scrubbed);
}

<*
 A drag that starts vertical stays vertical, reports live and once with `done`,
 and lands the point's new y with its x unchanged. A handle drag reports the
 pointer's data position.
*>
fn void a_curve_plot_drags_points_and_handles() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurveSeries[1] series  = { { .points = line[..] } };
	CurvePoint[1] points   = { { .at = { 1, 10 } } };
	CurveHandle[1] handles = { { .point = 0, .at = { 1.5f, 10 } } };
	Element* elem          = plot(ui, series[..], points[..], handles[..]);
	CurvePlot* widget      = elem.widget_as(CurvePlot);

	Vec2 from = widget.pixel_of(elem, { 1, 10 });
	Vec2 to   = widget.pixel_of(elem, { 1.1f, 5 });
	cui_tests::frame(ui, from);
	cui_tests::frame(ui, from, left: true);
	cui_tests::frame(ui, from + (Vec2) { 0, 10 }, left: true);
	cui_tests::frame(ui, to, left: true);
	cui_tests::frame(ui, to);
	ui.flush();
	test::@check(drags >= 2 && dones == 1, "drags %d dones %d", drags, dones);
	test::@check(landed.x == 1.0f && math::abs(landed.y - 5) < 0.05f, "the point landed at %s", landed);

	Vec2 grip = widget.pixel_of(elem, { 1.5f, 10 });
	Vec2 pull = widget.pixel_of(elem, { 1.5f, 7 });
	cui_tests::frame(ui, grip);
	cui_tests::frame(ui, grip, left: true);
	cui_tests::frame(ui, pull, left: true);
	cui_tests::frame(ui, pull);
	ui.flush();
	test::eq(handle_dones, 1);
	test::@check(
		math::abs(handle_to.y - 7) < 0.05f && math::abs(handle_to.x - 1.5f) < 0.01f,
		"the handle went to %s",
		handle_to
	);
	test::eq(dones, 1);
}

<*
 Ctrl+wheel zooms the x axis and reports it; Shift+wheel zooms y only.
*>
fn void a_curve_plot_zooms() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurveSeries[1] series = { { .points = line[..] } };
	Element* elem         = plot(ui, series[..], { }, { });
	CurvePlot* widget     = elem.widget_as(CurvePlot);
	Vec2 middle           = widget.pixel_of(elem, { 1, 5 });

	Key[1] ctrl = { Key.LEFT_CTRL };
	cui_tests::frame(ui, middle, keys: ctrl[..]);
	cui_tests::frame(ui, middle, scroll: 1, keys: ctrl[..]);
	ui.flush();
	test::@check(widget.zoom > 1 && views == 1, "ctrl+wheel did not zoom x");
	Vec2 fitted = widget.y_range();

	Key[1] shift = { Key.LEFT_SHIFT };
	cui_tests::frame(ui, middle, keys: shift[..]);
	cui_tests::frame(ui, middle, scroll: 1, keys: shift[..]);
	ui.flush();
	Vec2 zoomed = widget.y_range();
	test::@check(zoomed.y - zoomed.x < fitted.y - fitted.x && views == 1, "shift+wheel did not zoom y alone");
}
<*
 `frame` zooms onto a box with a margin and reports the time view; F and A ask
 `on_frame` once it is set.
*>
int framed @local;
bool framed_all @local;

fn void note_frame(Ui* ui, bool all) @local
{
	framed++;
	framed_all = all;
}

fn void a_curve_plot_frames_a_box_and_hands_f_and_a_on() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	framed = 0;
	CurveSeries[1] series = { { .points = line[..] } };
	Element* elem         = plot(ui, series[..], { }, { });
	CurvePlot* widget     = elem.widget_as(CurvePlot);

	widget.frame(elem, { 0.5f, 1.0f }, { 4, 10 });
	test::@check(widget.zoom > 2.0f && widget.zoom < 4.0f, "the box did not set the zoom (%f)", widget.zoom);
	test::@check(widget.view_start <= 0.5f && widget.view_start + widget.visible_width() >= 1.0f,
		"the box is outside the view");
	test::eq(views, 1);
	Vec2 range = widget.y_range();
	test::@check(range.x <= 4.0f && range.y >= 10.0f && range.y - range.x < 12.0f, "the y view %s misses 4..10", range);

	// A box with no extent keeps the zoom and centres on it.
	float zoom = widget.zoom;
	widget.frame(elem, { 1.5f, 1.5f }, { 5, 5 });
	test::@check(widget.zoom == zoom && math::abs(widget.view_start + widget.visible_width() * 0.5f - 1.5f) < 1.0e-3f,
		"a point box moved the zoom or missed the centre");

	// With on_frame set, F and A are the caller's.
	widget.on_frame = &note_frame;
	elem.request_focus();
	cui_tests::frame(ui, { 0, 0 }, keys: { Key.A });
	cui_tests::frame(ui, { 0, 0 });
	test::@check(framed == 1 && framed_all, "A did not ask to frame everything");
	cui_tests::frame(ui, { 0, 0 }, keys: { Key.F });
	cui_tests::frame(ui, { 0, 0 });
	test::@check(framed == 2 && !framed_all, "F did not ask to frame the selection");
}

Vec2[4] wave = { { 0, 0 }, { 0.5f, 6 }, { 1, 2 }, { 2, 10 } };

// Borrowed by the plot, so it outlives the helper's frame.
CurveSeries[1] wave_series @local;

fn Element* wave_plot(Ui* ui, CurvePoint[] points) @local
{
	wave_series[0] = { .points = wave[..] };
	return plot(ui, wave_series[..], points, { });
}

<*
 A drag over empty space reports the points inside the box once, on release,
 with Shift as add and Ctrl as toggle; a click without a drag still scrubs, and
 a press on the ruler scrubs instead of starting a box.
*>
fn void a_curve_plot_boxes_points() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurvePoint[4] points = { { .at = wave[0] }, { .at = wave[1] }, { .at = wave[2] }, { .at = wave[3] } };
	Element* elem        = wave_plot(ui, points[..]);
	CurvePlot* widget    = elem.widget_as(CurvePlot);

	// Around the middle two points, started clear of every one.
	Vec2 a    = widget.pixel_of(elem, wave[1]);
	Vec2 b    = widget.pixel_of(elem, wave[2]);
	Vec2 from = { a.x - 12, a.y - 30 };
	Vec2 to   = { b.x + 12, b.y + 30 };
	cui_tests::frame(ui, from);
	cui_tests::frame(ui, from, left: true);
	cui_tests::frame(ui, to, left: true);
	test::@check(boxed_count == 0 && widget.boxing && widget.dragged, "the box reported before the release");
	cui_tests::frame(ui, to);
	ui.flush();
	test::@check(boxed_count == 2 && boxed[0] == 1 && boxed[1] == 2 && box_mode == REPLACE,
		"the box picked %d points (%d, %d) as %s", boxed_count, boxed[0], boxed[1], box_mode);
	test::@check(scrubbed == -1.0f, "a box scrubbed the cursor");

	Key[1] shift = { Key.LEFT_SHIFT };
	cui_tests::frame(ui, from, keys: shift[..]);
	cui_tests::frame(ui, from, left: true, keys: shift[..]);
	cui_tests::frame(ui, to, left: true, keys: shift[..]);
	cui_tests::frame(ui, to, keys: shift[..]);
	test::@check(box_mode == ADD, "Shift did not add");
	Key[1] ctrl = { Key.LEFT_CTRL };
	cui_tests::frame(ui, from, keys: ctrl[..]);
	cui_tests::frame(ui, from, left: true, keys: ctrl[..]);
	cui_tests::frame(ui, to, left: true, keys: ctrl[..]);
	cui_tests::frame(ui, to, keys: ctrl[..]);
	test::@check(box_mode == TOGGLE, "Ctrl did not toggle");

	// A click with no drag is the scrub it always was; so is the ruler.
	reset();
	Vec2 empty = widget.pixel_of(elem, { 0.4f, 3 });
	cui_tests::frame(ui, empty);
	cui_tests::frame(ui, empty, left: true);
	test::@check(scrubbed == -1.0f, "the scrub fired before the click was over");
	cui_tests::frame(ui, empty);
	test::@check(scrubbed == 0.5f && boxed_count == 0, "a click scrubbed to %f", scrubbed);
	Vec2 ruler = { widget.pixel_of(elem, { 1.0f, 0 }).x, 5 };
	Vec2 along = { ruler.x + 100, 5 };
	cui_tests::frame(ui, ruler);
	cui_tests::frame(ui, ruler, left: true);
	cui_tests::frame(ui, along, left: true);
	test::@check(scrubbed > 1.0f && !widget.boxing, "a drag on the ruler did not scrub (%f)", scrubbed);
	cui_tests::frame(ui, along);
}

<*
 Dragging a selected point previews the selected ones with it: all of them for
 a sideways drag, those of its group for an up/down one. The caller still hears
 only the pressed point.
*>
fn void a_curve_plot_carries_the_selection() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurvePoint[4] points = {
		{ .at = wave[0], .selected = true, .group = 0 },
		{ .at = wave[1], .selected = true, .group = 1 },
		{ .at = wave[2], .selected = true, .group = 0 },
		{ .at = wave[3], .group = 0 },
	};
	Element* elem     = wave_plot(ui, points[..]);
	CurvePlot* widget = elem.widget_as(CurvePlot);

	Vec2 from = widget.pixel_of(elem, wave[2]);
	cui_tests::frame(ui, from);
	cui_tests::frame(ui, from, left: true);
	cui_tests::frame(ui, from + (Vec2){ 0, -20 }, left: true);
	test::@check(widget.lock == Y && widget.travels(0) && !widget.travels(1) && !widget.travels(3),
		"an up/down drag carries the wrong points");
	Vec2 moved = widget.previewed(0);
	test::@check(math::abs(moved.y - wave[0].y - (widget.drag_to.y - wave[2].y)) < 1.0e-4f && moved.x == wave[0].x,
		"the first point previews at %s", moved);
	cui_tests::frame(ui, from + (Vec2){ 0, -20 });
	test::@check(dones == 1 && drags >= 1, "the caller heard %d drags and %d dones", drags, dones);

	// Sideways: every selected point, whatever its group, and the unselected stays.
	from = widget.pixel_of(elem, wave[2]);
	cui_tests::frame(ui, from);
	cui_tests::frame(ui, from, left: true);
	cui_tests::frame(ui, from + (Vec2){ 30, 0 }, left: true);
	test::@check(widget.lock == X && widget.travels(0) && widget.travels(1) && !widget.travels(3),
		"a sideways drag carries the wrong points");
	cui_tests::frame(ui, from + (Vec2){ 30, 0 });

	// A point that is not selected drags alone.
	from = widget.pixel_of(elem, wave[3]);
	cui_tests::frame(ui, from);
	cui_tests::frame(ui, from, left: true);
	cui_tests::frame(ui, from + (Vec2){ 0, 20 }, left: true);
	test::@check(widget.travels(3) && !widget.travels(0) && !widget.travels(2), "an unselected point dragged others");
	cui_tests::frame(ui, from + (Vec2){ 0, 20 });
}

<*
 Alt + drag on a selected point scales: values about the middle of the
 selection, times about the cursor. The pressed point follows the pointer, the
 caller hears the factor and pivot on release, and the point drag is not used.
*>
fn void a_curve_plot_scales_the_selection() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurvePoint[4] points = {
		{ .at = wave[0], .selected = true },
		{ .at = wave[1], .selected = true },
		{ .at = wave[2], .selected = true },
		{ .at = wave[3] },
	};
	Element* elem     = wave_plot(ui, points[..]);
	CurvePlot* widget = elem.widget_as(CurvePlot);
	Key[1] alt        = { Key.LEFT_ALT };

	// Up/down: the pivot is the middle of 0..6, and dragging the 6 point to 9 doubles the spread (3 to 6 is 2x).
	Vec2 from = widget.pixel_of(elem, wave[1]);
	Vec2 to   = widget.pixel_of(elem, { wave[1].x, 9 });
	cui_tests::frame(ui, from, keys: alt[..]);
	cui_tests::frame(ui, from, left: true, keys: alt[..]);
	cui_tests::frame(ui, to, left: true, keys: alt[..]);
	test::@check(widget.scaling && widget.lock == Y, "Alt did not start a scale");
	test::@check(math::abs(widget.previewed(0).y - (3.0f + (0.0f - 3.0f) * 2.0f)) < 0.05f, "the preview reads %s", widget.previewed(0));
	cui_tests::frame(ui, to, keys: alt[..]);
	cui_tests::frame(ui, to);
	test::@check(scale_dones == 1 && scaled_point == 1 && scaled_axis == Y, "scale %d point %d", scale_dones, scaled_point);
	test::@check(math::abs(scale_pivot - 3.0f) < 1.0e-3f && math::abs(scale_factor - 2.0f) < 0.05f,
		"scaled by %f about %f", scale_factor, scale_pivot);
	test::eq(dones, 0);
	test::eq(pressed, -1);

	// Sideways: about the cursor, landing the pressed point on a frame step.
	reset();
	widget.cursor = 0.0f;
	widget.show_cursor = true;
	from = widget.pixel_of(elem, wave[2]);
	to   = widget.pixel_of(elem, { 1.5f, 2 });
	cui_tests::frame(ui, from, keys: alt[..]);
	cui_tests::frame(ui, from, left: true, keys: alt[..]);
	cui_tests::frame(ui, to, left: true, keys: alt[..]);
	cui_tests::frame(ui, to, keys: alt[..]);
	cui_tests::frame(ui, to);
	test::@check(scale_dones == 1 && scaled_axis == X && math::abs(scale_pivot) < 1.0e-6f
		&& math::abs(scale_factor - 1.5f) < 0.05f, "scaled by %f about %f", scale_factor, scale_pivot);

	// Alt on an unselected point is an ordinary drag.
	reset();
	from = widget.pixel_of(elem, wave[3]);
	cui_tests::frame(ui, from, keys: alt[..]);
	cui_tests::frame(ui, from, left: true, keys: alt[..]);
	cui_tests::frame(ui, from + (Vec2){ 0, 20 }, left: true, keys: alt[..]);
	test::@check(!widget.scaling, "Alt on an unselected point scaled");
	cui_tests::frame(ui, from + (Vec2){ 0, 20 });
	test::@check(dones == 1 && scale_dones == 0, "the drag did not report as a point drag");
}

<*
 Ctrl+C and Ctrl+V reach the plot's copy and paste callbacks once the plot has
 the focus, which a press inside it grants.
*>
fn void a_curve_plot_copies_and_pastes() @test
{
	Ui* ui = cui::new_ui({ 400, 300 });
	defer ui.free();
	reset();
	CurvePoint[4] points = { { .at = wave[0] }, { .at = wave[1] }, { .at = wave[2] }, { .at = wave[3] } };
	Element* elem        = wave_plot(ui, points[..]);
	CurvePlot* widget    = elem.widget_as(CurvePlot);
	Vec2 empty           = widget.pixel_of(elem, { 0.4f, 3 });
	cui_tests::frame(ui, empty);
	cui_tests::frame(ui, empty, left: true);
	cui_tests::frame(ui, empty);
	Key[2] copy  = { Key.LEFT_CTRL, Key.C };
	Key[2] paste = { Key.LEFT_CTRL, Key.V };
	Key[1] ctrl  = { Key.LEFT_CTRL };
	cui_tests::frame(ui, empty, keys: ctrl[..]);
	cui_tests::frame(ui, empty, keys: copy[..]);
	cui_tests::frame(ui, empty, keys: ctrl[..]);
	cui_tests::frame(ui, empty, keys: paste[..]);
	test::@check(copies == 1 && pastes == 1, "copy %d paste %d", copies, pastes);
}
