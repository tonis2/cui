// Slider: which value a pixel on the track means, what a drag reports, and what
// is not a target. Headless and fontless — the caption and the readout are
// measured text, but nothing about the geometry below is.
module cui_tests::sliders;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;
import std::math::vector;

const SliderStyle STYLE = widgets::DEFAULT_SLIDER_STYLE;

// A row narrower than the window, so a press past its right edge is a press
// that missed rather than one the window clamped.
const Vec2 ROW = { 300.0, 22.0 };

// The groove inside it: the row less the caption column and the readout column.
const float TRACK_X = STYLE.label_width + STYLE.gap;
const float TRACK_W = ROW.x - TRACK_X - STYLE.value_width - STYLE.gap;

// What a fraction of the track is worth in pixels. The handle rides inside the
// groove, so the travel is short by its width and the pointer holds its middle.
const float TRAVEL = TRACK_W - STYLE.handle_width;

// What the callbacks report, since an OnSlide carries no context back.
float changed_to @local = 0.0;
int changes @local = 0;
float committed_to @local = 0.0;
int commits @local = 0;

fn void note_change(Ui* ui, float value) @local { changed_to = value; changes++; }
fn void note_commit(Ui* ui, float value) @local { committed_to = value; commits++; }

// The pixel where `fraction` of the track is, in window coordinates: the middle
// of the handle when it sits there.
fn Vec2 at_fraction(float fraction) @local
{
	return { TRACK_X + STYLE.handle_width * 0.5f + TRAVEL * fraction, ROW.y * 0.5f };
}

fn Element* slider_of(Ui* ui, Slider widget) @local
{
	changed_to = 0.0f;
	changes = 0;
	committed_to = 0.0f;
	commits = 0;

	widget.size = ROW;
	widget.on_change = &note_change;
	widget.on_commit = &note_commit;

	Element* slider = ui.@node(widget);
	ui.build(ui.@node((Stack) { }, slider));
	ui.flush();
	return slider;
}

<*
 A press at the middle of the track is the middle of the range, and the widget
 has moved by the time the callback sees it.
*>
fn void a_press_takes_the_value_under_it() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0 });

	cui_tests::frame(ui, at_fraction(0.5), left: true);

	test::eq(changes, 1);
	test::@check(math::abs(changed_to - 50.0f) < 0.01f, "the middle of the track was not the middle of the range");
	test::@check(slider.widget_as(Slider).value == changed_to, "the widget reported a value it had not taken");
}

<*
 The two ends are reachable. A slider whose maximum needs the pointer to leave
 the widget is one that cannot be set to its maximum.
*>
fn void both_ends_of_the_track_are_reachable() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0, .value = 50.0 });

	cui_tests::frame(ui, at_fraction(1.0), left: true);
	test::@check(slider.widget_as(Slider).value == 100.0f, "the right end of the track was not the maximum");

	cui_tests::frame(ui, at_fraction(0.0));
	cui_tests::frame(ui, at_fraction(0.0), left: true);
	test::@check(slider.widget_as(Slider).value == 0.0f, "the left end of the track was not the minimum");
}

<*
 A drag reports every value it passes through, and the release reports once
 more — the seam a caller records history on.
*>
fn void a_drag_reports_live_and_the_release_once() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0 });

	cui_tests::frame(ui, at_fraction(0.25), left: true);
	cui_tests::frame(ui, at_fraction(0.5), left: true);
	cui_tests::frame(ui, at_fraction(0.75), left: true);

	test::eq(changes, 3);
	test::eq(commits, 0);

	cui_tests::frame(ui, at_fraction(0.75));

	test::eq(commits, 1);
	test::@check(math::abs(committed_to - 75.0f) < 0.01f, "the release reported a different value than the drag left");
	test::@check(slider.widget_as(Slider).value == committed_to, "the release reported a value the widget did not hold");
}

<*
 A drag holds the pointer: the value keeps following it out past the ends of the
 track, rather than stopping where the widget does.
*>
fn void a_drag_keeps_the_pointer_past_the_edge() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0 });

	cui_tests::frame(ui, at_fraction(0.5), left: true);
	cui_tests::frame(ui, { cui_tests::WINDOW.x - 1.0f, ROW.y * 0.5f }, left: true);

	test::@check(slider.widget_as(Slider).value == 100.0f, "a drag past the right edge did not reach the maximum");
}

<*
 `step` quantises what a drag can land on, and a pixel that means the value the
 slider already has is not reported: one gesture over a stepped track would
 otherwise write the same number many times.
*>
fn void a_step_quantises_and_does_not_repeat_itself() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 10.0, .step = 1.0 });

	cui_tests::frame(ui, at_fraction(0.52), left: true);
	test::@check(slider.widget_as(Slider).value == 5.0f, "a stepped track landed between its steps");
	test::eq(changes, 1);

	// A pixel further along the same step: the value is unchanged, so nothing is
	// reported.
	cui_tests::frame(ui, at_fraction(0.53), left: true);
	test::eq(changes, 1);

	cui_tests::frame(ui, at_fraction(0.62), left: true);
	test::eq(changes, 2);
	test::@check(slider.widget_as(Slider).value == 6.0f, "the next step was not the next whole number");
}

<*
 A curve above 1 gives the low end of the range more of the track: the point of
 it, for a value that lives in the thousands and is interesting in the hundreds.
*>
fn void a_curve_stretches_the_low_end() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 10000.0, .curve = 2.0 });

	cui_tests::frame(ui, at_fraction(0.5), left: true);

	// Half the track is a quarter of the range, not half of it.
	test::@check(math::abs(slider.widget_as(Slider).value - 2500.0f) < 1.0f,
		"a squared curve did not put a quarter of the range at half the track");

	// And it round-trips: the fraction the value comes back as is the one the
	// press was at, which is what keeps the handle under the pointer.
	test::@check(math::abs(slider.widget_as(Slider).fraction() - 0.5f) < 0.01f,
		"the value did not map back to the fraction it was taken from");
}

<*
 Only the track is a target. A press on the caption is declined outright, so the
 row can sit inside something that scrolls or drags.
*>
fn void the_caption_is_not_a_target() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0, .value = 40.0 });

	cui_tests::frame(ui, { STYLE.label_width * 0.5f, ROW.y * 0.5f }, left: true);

	test::eq(changes, 0);
	test::@check(slider.widget_as(Slider).value == 40.0f, "a press on the caption moved the value");
}

<*
 A disabled slider takes no drags at all — it is a readout of a value that is
 not this panel's to set.
*>
fn void a_disabled_slider_takes_no_drags() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* slider = slider_of(ui, { .min = 0.0, .max = 100.0, .value = 40.0, .disabled = true });

	cui_tests::frame(ui, at_fraction(0.5), left: true);
	cui_tests::frame(ui, at_fraction(0.5));

	test::eq(changes, 0);
	test::eq(commits, 0);
	test::@check(slider.widget_as(Slider).value == 40.0f, "a disabled slider moved");
}

<*
 The readout is the value, its decimals and its suffix — the one part of the
 paint worth checking without a font, since a caller sizing its own columns has
 to know how wide the number comes to.
*>
fn void the_readout_carries_the_decimals_and_the_suffix() @test
{
	Slider slider = { .value = 0.9, .decimals = 2 };
	char[widgets::SLIDER_READOUT_MAX] scratch;
	test::eq(slider.readout(&scratch), "0.90");

	Slider degrees = { .value = 29.0, .decimals = 0, .suffix = "°" };
	test::eq(degrees.readout(&scratch), "29°");
}
