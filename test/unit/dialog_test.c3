// Dialogs: closed costs nothing, open centres and clamps, and every route out
// of it (the button, ESC, a modal backdrop, the app) ends in the same place.
// Headless and fontless, so the title measures zero and the panel comes out at
// exactly the style's minimum width.
module cui_tests::dialogs;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;

const Vec2 DIALOG_WINDOW = { 400.0, 300.0 };
const Vec2 BODY = { 180.0, 80.0 };

// The default style, with a body narrower than its 220px minimum: the width is
// that minimum, the height is the bar plus the body between its insets.
const float PANEL_W = 220.0;
const float PANEL_H = 30.0 + 2.0 * 12.0 + BODY.y;
const Vec2 CENTRED = { (DIALOG_WINDOW.x - PANEL_W) * 0.5, (DIALOG_WINDOW.y - PANEL_H) * 0.5 };

// Well outside the centred panel, in the window's top-left corner.
const Vec2 OUTSIDE = { 10.0, 10.0 };

struct DialogBody (Widget)
{
	Vec2 size;
}

fn Element* build_body(Ui* ui) => ui.@node((DialogBody) { .size = BODY });

int closes;
EventRecord behind;

fn void note_close(Ui* ui)
{
	closes++;
}

<*
 A window with something interactive filling it and a dialog over the top, so
 every check can ask what the pointer reached as well as what the dialog did.
*>
fn Ui* dialog_ui(bool modal = false, bool close_outside = false)
{
	closes = 0;
	behind = { };

	Ui* ui = cui::new_ui(DIALOG_WINDOW);
	@canvas(ui)
	{
		@tree((Stack) { })
		{
			@node((EventProbe) { .pref = DIALOG_WINDOW, .rec = &behind });
			@node((Dialog) {
				.title = "Controls",
				.body = &build_body,
				.modal = modal,
				.close_outside = close_outside,
				.on_close = &note_close,
			});
		};
	};
	ui.flush();
	return ui;
}

fn Element* open_dialog(Ui* ui)
{
	Element* elem = ui.find(Dialog)!!;
	elem.widget_as(Dialog).set_open(elem, true);
	ui.flush();
	return elem;
}

fn void click(Ui* ui, Vec2 at)
{
	cui_tests::frame(ui, at, left: true);
	cui_tests::frame(ui, at);
	ui.flush();
}

fn void closed_dialog_is_not_there() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();

	Element* elem = ui.find(Dialog)!!;
	cui_tests::eq_vec2(elem.size, { 0, 0 });
	test::@error(ui.find(DialogFrame), cui::WIDGET_NOT_FOUND);
	test::@error(ui.find_id(widgets::DIALOG_CLOSE_ID), cui::WIDGET_NOT_FOUND);

	// Nothing of it is in the way, wherever the pointer lands.
	test::@check(ui.hit_test({ 200, 150 }) != elem);
}

fn void opening_centres_the_panel() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	open_dialog(ui);

	Element* frame = ui.find(DialogFrame)!!;
	cui_tests::eq_vec2(frame.size, { PANEL_W, PANEL_H });
	cui_tests::eq_vec2(frame.absolute, CENTRED);

	// The body sits under the bar, between the insets.
	Element* body = ui.find(DialogBody)!!;
	cui_tests::eq_vec2(body.absolute, { CENTRED.x + 14.0, CENTRED.y + 30.0 + 12.0 });
}

fn void centring_follows_the_window() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	open_dialog(ui);

	ui.size = { 600, 500 };
	ui.root.request_layout();
	ui.flush();

	Element* frame = ui.find(DialogFrame)!!;
	cui_tests::eq_vec2(frame.absolute, { (600.0 - PANEL_W) * 0.5, (500.0 - PANEL_H) * 0.5 });
}

fn void close_button_dismisses_it() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	Element* elem = open_dialog(ui);

	Element* close = ui.find_id(widgets::DIALOG_CLOSE_ID)!!;
	click(ui, close.absolute + close.size * 0.5f);

	test::@check(!elem.widget_as(Dialog).open);
	test::eq(closes, 1);
	test::@error(ui.find(DialogFrame), cui::WIDGET_NOT_FOUND);
	cui_tests::eq_vec2(elem.size, { 0, 0 });
}

<*
 ESC works without the dialog ever being clicked: opening focuses it.
*>
fn void escape_dismisses_it() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	Element* elem = open_dialog(ui);
	test::@check(ui.focused == elem);

	Key[1] escape = { Key.ESCAPE };
	cui_tests::frame(ui, OUTSIDE, keys: escape[..]);
	ui.flush();

	test::@check(!elem.widget_as(Dialog).open);
	test::eq(closes, 1);
}

fn void title_drag_moves_the_panel() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	open_dialog(ui);

	Element* bar = ui.find(DialogTitleBar)!!;
	Vec2 grip = bar.absolute + (Vec2) { 20.0, 15.0 }; // left of the close button
	cui_tests::frame(ui, grip, left: true);
	cui_tests::frame(ui, grip + (Vec2) { 30.0, 20.0 }, left: true);
	ui.flush();

	Element* frame = ui.find(DialogFrame)!!;
	cui_tests::eq_vec2(frame.absolute, CENTRED + (Vec2) { 30.0, 20.0 });

	// Dragged at the edge it stops there rather than leaving the screen, and the
	// margin the panel is sized against is not part of that limit.
	cui_tests::frame(ui, { 900.0, 900.0 }, left: true);
	cui_tests::frame(ui, { 900.0, 900.0 });
	ui.flush();
	cui_tests::eq_vec2(frame.absolute, { DIALOG_WINDOW.x - PANEL_W, DIALOG_WINDOW.y - PANEL_H });

	// And it stays where it was left rather than snapping back to the middle.
	ui.root.request_layout();
	ui.flush();
	cui_tests::eq_vec2(frame.absolute, { DIALOG_WINDOW.x - PANEL_W, DIALOG_WINDOW.y - PANEL_H });
}

fn void a_plain_dialog_leaves_the_rest_live() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	Element* elem = open_dialog(ui);

	click(ui, OUTSIDE);
	test::eq(behind.presses, 1);
	test::@check(elem.widget_as(Dialog).open);
}

fn void a_modal_blocks_what_is_behind_it() @test
{
	Ui* ui = dialog_ui(modal: true);
	defer ui.free();
	Element* elem = open_dialog(ui);

	// The element itself is the backdrop: it covers the window and takes the
	// press that would otherwise have reached the probe.
	cui_tests::eq_vec2(elem.size, DIALOG_WINDOW);
	test::@check(ui.hit_test(OUTSIDE) == elem);

	click(ui, OUTSIDE);
	test::eq(behind.presses, 0);
	test::@check(elem.widget_as(Dialog).open); // no close_outside: the press is only swallowed
}

fn void close_outside_dismisses_from_the_backdrop() @test
{
	Ui* ui = dialog_ui(modal: true, close_outside: true);
	defer ui.free();
	Element* elem = open_dialog(ui);

	// Not from the panel, though: the frame eats its own clicks, which is what
	// keeps a click that lands on the dialog from dismissing it.
	Element* frame = ui.find(DialogFrame)!!;
	click(ui, frame.absolute + (Vec2) { 4.0, PANEL_H - 4.0 });
	test::@check(elem.widget_as(Dialog).open);

	click(ui, OUTSIDE);
	test::@check(!elem.widget_as(Dialog).open);
	test::eq(closes, 1);
	test::eq(behind.presses, 0);
}

fn void toggling_twice_leaves_it_open() @test
{
	Ui* ui = dialog_ui();
	defer ui.free();
	Element* elem = ui.find(Dialog)!!;
	Dialog* dialog = elem.widget_as(Dialog);

	dialog.toggle(elem);
	ui.flush();
	test::@check(dialog.open);

	dialog.toggle(elem);
	ui.flush();
	test::@check(!dialog.open);
	test::eq(closes, 1);

	dialog.toggle(elem);
	ui.flush();
	test::@check(dialog.open);
	test::@check(ui.find(DialogFrame)!!.size.x == PANEL_W);
}
