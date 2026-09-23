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