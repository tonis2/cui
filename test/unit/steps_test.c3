// Steps. Headless and fontless, so a label measures zero wide and a step is its
// paddings, its dot and its gaps: the geometry here is the style's numbers.
module cui_tests::steps;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

usz clicked @local;
int clicks @local;

fn void note_click(Ui* ui, usz index) @local
{
	clicked = index;
	clicks++;
}

fn void click(Ui* ui, Vec2 at) @local
{
	cui_tests::frame(ui, at);
	cui_tests::frame(ui, at, left: true);
	cui_tests::frame(ui, at);
	ui.flush();
}

// One step's width with no note: both paddings, the dot and its gap.
fn float bare_step() @local
{
	StepsStyle s = widgets::DEFAULT_STEPS_STYLE;
	return 2 * s.pad_x + s.icon + s.icon_gap;
}

<*
 Steps sit side by side with a chevron gap between them; a note widens its step
 by the note gap. A click reports the step under it, a click on a chevron gap
 reports nothing, and a press dragged to another step picks nothing.
*>
fn void steps_lay_out_and_report_the_clicked_step() @test
{
	Ui* ui = cui::new_ui({ 400, 100 });
	defer ui.free();
	clicks = 0;

	Step[3] row = {
		{ .label = "Model", .state = DONE },
		{ .label = "Skin", .note = "2", .state = ATTENTION, .detail = "2 joints hold no skin" },
		{ .label = "Export", .state = TODO },
	};
	Element* steps = ui.@node((Steps) { .steps = row[..], .current = 2, .on_click = &note_click });
	ui.build(ui.@node((Stack) { }, steps));
	ui.flush();

	StepsStyle s = widgets::DEFAULT_STEPS_STYLE;
	float bare   = bare_step();
	test::eq(steps.size.x, 3 * bare + s.note_gap + 2 * s.chevron);
	test::eq(steps.size.y, s.height);
	test::@check(!steps.widget_as(Steps).compact, "a row that fits dropped its notes");

	float second = bare + s.chevron;
	float third  = second + bare + s.note_gap + s.chevron;
	test::eq(steps.widget_as(Steps).index_at(steps, second + 1), (sz)1);
	test::eq(steps.widget_as(Steps).index_at(steps, bare + 1), (sz)-1);

	click(ui, { second + 2, 10 });
	test::eq(clicks, 1);
	test::eq(clicked, (usz)1);
	click(ui, { third + 2, 10 });
	test::eq(clicks, 2);
	test::eq(clicked, (usz)2);

	// On a chevron: nothing.
	click(ui, { bare + s.chevron * 0.5f, 10 });
	test::eq(clicks, 2);

	// Press on Model, release on Export: no choice.
	cui_tests::frame(ui, { 2, 10 });
	cui_tests::frame(ui, { 2, 10 }, left: true);
	cui_tests::frame(ui, { third + 2, 10 });
	ui.flush();
	test::eq(clicks, 2);
}

<*
 Hovering a step with a detail marks it hovered, which is what the tip is drawn
 from; leaving clears it.
*>
fn void steps_hover_tracks_the_step_under_the_pointer() @test
{
	Ui* ui = cui::new_ui({ 400, 100 });
	defer ui.free();

	Step[2] row = {
		{ .label = "Model", .state = DONE },
		{ .label = "Skin", .state = ATTENTION, .detail = "2 joints hold no skin" },
	};
	Element* steps = ui.@node((Steps) { .steps = row[..], .current = -1 });
	ui.build(ui.@node((Stack) { }, steps));
	ui.flush();

	float second = bare_step() + widgets::DEFAULT_STEPS_STYLE.chevron;
	cui_tests::frame(ui, { second + 2, 10 });
	ui.flush();
	Steps* widget = steps.widget_as(Steps);
	test::@check(widget.hovering && widget.hovered == 1, "hovering Skin did not mark it");

	cui_tests::frame(ui, { 390, 90 });
	ui.flush();
	test::@check(!widget.hovering, "leaving the row kept the hover");
}

<*
 A row too wide for the room it is offered drops its notes before anything else.
*>
fn void steps_drop_their_notes_when_narrow() @test
{
	Ui* ui = cui::new_ui({ 400, 100 });
	defer ui.free();

	Step[2] row = {
		{ .label = "Animations", .note = "(3)", .state = DONE },
		{ .label = "Export", .note = "saved", .state = TODO },
	};
	StepsStyle s  = widgets::DEFAULT_STEPS_STYLE;
	float bare    = bare_step();
	float compact = 2 * bare + s.chevron;

	Element* steps = ui.@node((Steps) { .steps = row[..], .current = -1 });
	ui.build(ui.@node((Column) { .size = { compact + 1, 0 } }, steps));
	ui.flush();

	test::@check(steps.widget_as(Steps).compact, "a row too wide for its room kept its notes");
	test::eq(steps.size.x, compact);
}