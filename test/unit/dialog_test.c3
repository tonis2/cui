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

	// Something only this element can remember. Content that was released and
	// rebuilt comes back with a fresh widget and a zero here; borrowed content
	// comes back with what was written into it.
	int remembered;
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
	cui_tests::frame(ui, grip);
	test::eq(ui.cursor, Cursor.OPEN_HAND);
	cui_tests::frame(ui, grip, left: true);
	test::eq(ui.cursor, Cursor.CLOSED_HAND);     // closed on the press that grabs
	cui_tests::frame(ui, grip + (Vec2) { 30.0, 20.0 }, left: true);
	ui.flush();

	Element* frame = ui.find(DialogFrame)!!;
	cui_tests::eq_vec2(frame.absolute, CENTRED + (Vec2) { 30.0, 20.0 });

	// Dragged at the edge it stops there rather than leaving the screen, and the
	// margin the panel is sized against is not part of that limit.
	cui_tests::frame(ui, { 900.0, 900.0 }, left: true);
	cui_tests::frame(ui, { 900.0, 900.0 });
	ui.flush();

	// The hand opens again on the release, which lands wherever the drag ended
	// — off the bar entirely here, since the pointer outran the panel.
	test::eq(bar.cursor, Cursor.OPEN_HAND);
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

// ---------------------------------------------------------------------------
// Borrowed content: an element the caller builds, owns and keeps, handed to the
// dialog instead of a builder. Closing must cut it loose rather than release it,
// and re-opening must attach the very same element back.

int body_unmounts;

<*
 The same window as `dialog_ui`, with the panel's content built here and kept
 here. The UnmountProbe under it is the witness: cui releasing the subtree behind
 the test's back would fire it.

 @param out : `Receives the borrowed element; the caller gives it back with Ui.unmount.`
*>
fn Ui* borrowed_ui(Element** out)
{
	closes = 0;
	behind = { };
	body_unmounts = 0;

	Ui* ui = cui::new_ui(DIALOG_WINDOW);
	Element* content = ui.@node((DialogBody) { .size = BODY },
		ui.@node((UnmountProbe) { .count = &body_unmounts }));
	*out = content;

	@canvas(ui)
	{
		@tree((Stack) { })
		{
			@node((EventProbe) { .pref = DIALOG_WINDOW, .rec = &behind });
			@node((Dialog) { .title = "Controls", .content = content, .on_close = &note_close });
		};
	};
	ui.flush();
	return ui;
}

fn void borrowed_content_stands_in_for_the_builder() @test
{
	Element* content;
	Ui* ui = borrowed_ui(&content);
	defer ui.free();
	defer ui.unmount(content); // the owner's job, and the only thing that frees it

	open_dialog(ui);

	// It lands where a built body lands: in the frame, under the bar, between
	// the insets — and it is the panel's whole content, so the panel is the
	// same size as one built around the same box.
	Element* frame = ui.find(DialogFrame)!!;
	test::@check(content.parent == frame);
	cui_tests::eq_vec2(frame.size, { PANEL_W, PANEL_H });
	cui_tests::eq_vec2(content.absolute, { CENTRED.x + 14.0, CENTRED.y + 30.0 + 12.0 });
}

fn void closing_detaches_borrowed_content() @test
{
	Element* content;
	Ui* ui = borrowed_ui(&content);
	defer ui.free();
	defer ui.unmount(content);

	Element* elem = open_dialog(ui);
	elem.widget_as(Dialog).set_open(elem, false);
	ui.flush();

	// The panel went with the close and the content did not: no unmount, its own
	// child still under it, its widget still readable — cut loose, not recycled.
	test::@error(ui.find(DialogFrame), cui::WIDGET_NOT_FOUND);
	test::@error(ui.find(DialogBody), cui::WIDGET_NOT_FOUND);
	test::eq(body_unmounts, 0);
	test::eq(content.parent == null, true);
	test::eq(content.children.len(), 1);
	cui_tests::eq_vec2(content.widget_as(DialogBody).size, BODY);
}

fn void reopening_attaches_the_same_element() @test
{
	Element* content;
	Ui* ui = borrowed_ui(&content);
	defer ui.free();
	defer ui.unmount(content);

	Element* elem = open_dialog(ui);
	Dialog* dialog = elem.widget_as(Dialog);
	content.widget_as(DialogBody).remembered = 7;

	dialog.set_open(elem, false);
	ui.flush();
	dialog.set_open(elem, true);
	ui.flush();

	// The same element, in the same place, remembering what was written into it
	// — which is the whole point of borrowing rather than building.
	test::eq(ui.find(DialogBody)!! == content, true);
	test::eq(content.parent == ui.find(DialogFrame)!!, true);
	test::eq(content.widget_as(DialogBody).remembered, 7);
	test::eq(body_unmounts, 0);
	cui_tests::eq_vec2(content.absolute, { CENTRED.x + 14.0, CENTRED.y + 30.0 + 12.0 });

	// And the dialog is a dialog either way: ESC still closes it, once.
	Key[1] escape = { Key.ESCAPE };
	cui_tests::frame(ui, OUTSIDE, keys: escape[..]);
	ui.flush();
	test::eq(dialog.open, false);
	test::eq(closes, 2);
}

// ---------------------------------------------------------------------------
// ConfirmDialog: the message is owned, which makes the buffer something `ask`
// can be handed a view of.

int confirms;
int declines;

fn void note_confirm(Ui* ui)
{
	confirms++;
}

fn void note_decline(Ui* ui)
{
	declines++;
}

const String CONFIRM_ID = "confirm";

fn Ui* confirm_ui()
{
	confirms = 0;
	declines = 0;

	Ui* ui = cui::new_ui(DIALOG_WINDOW);
	@canvas(ui)
	{
		@node((ConfirmDialog) { .title = "Careful" }).with_id(CONFIRM_ID);
	};
	ui.flush();
	return ui;
}

<*
 Re-asking with the panel's own message.

 A caller with nothing new to say hands `message.str_view()` straight back —
 changing only the callbacks, or re-posting a question after something else
 rebuilt the tree. `ask` clears that buffer before appending to it, so without a
 copy this is `mem::copy` over overlapping ranges: a contract failure, not a
 wrong answer.
*>
fn void asking_again_with_its_own_message_is_safe() @test
{
	Ui* ui = confirm_ui();
	defer ui.free();

	Element* elem = ui.find_id(CONFIRM_ID)!!;
	ConfirmDialog* panel = elem.widget_as(ConfirmDialog);

	panel.ask(elem, "Replace 17 dots?", &note_confirm, &note_decline);
	ui.flush();
	test::eq(panel.asking(elem), true);

	// The same bytes, out of the buffer they are already in.
	panel.ask(elem, panel.message.str_view(), &note_confirm, null);
	ui.flush();

	test::eq(panel.asking(elem), true);
	test::eq(panel.message.str_view(), "Replace 17 dots?");

	// Re-asking is not an answer: neither callback has run, and the first
	// question's decline was replaced rather than fired.
	test::eq(confirms, 0);
	test::eq(declines, 0);
}
