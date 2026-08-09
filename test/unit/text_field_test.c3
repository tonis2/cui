// TextField: key auto-repeat, and the selection — made with the pointer, with
// Shift, or with Ctrl+A, and then typed over or deleted.
//
// No font is loaded in a headless Ui, so `TextSystem.measure` answers zero for
// every string. That is what makes the pointer cases deterministic here: a
// click left of the padding lands on offset 0, and any click right of it walks
// past every zero-width boundary and lands at the end.
module cui_tests::text_fields;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;

// Feed a frame of held keys with an explicit dt — how long the key has been
// down is the whole subject of the repeat tests.
fn void hold(Ui* ui, Key[] held, float dt = 0.016f) @local
{
	ui.process_input({ .mouse = { 300, 5 }, .keys_down = held }, dt);
}

// Feed a frame of typed text, the way a platform reports what a keystroke means
// under the user's layout.
fn void typed(Ui* ui, String text) @local
{
	ui.process_input({ .mouse = { 300, 5 }, .text = text }, 0.016f);
}

// What `on_change` reported, and how often — a bare OnChange carries no context
// back, so the callback writes here.
int changes @local;
char[64] last_text @local;
usz last_len @local;

fn void note_change(Ui* ui, String text) @local
{
	changes++;
	last_len = text.len < 64 ? text.len : 64;
	foreach (usz i, char c : text[:last_len]) last_text[i] = c;
}

fn String reported() @local => (String)last_text[:last_len];

// A focused field holding `text`, with the caret at the end: the click at x=300
// both focuses it and walks the caret past the last boundary.
fn TextField* focused_field(Ui* ui, Element** out_elem, String text) @local
{
	Element* elem = ui.@node((TextField){ });
	ui.build(elem);
	ui.flush();

	TextField* field = elem.widget_as(TextField);
	field.set_text(elem, text);
	cui_tests::frame(ui, { 300, 5 }, left: true);
	cui_tests::frame(ui, { 300, 5 });

	*out_elem = elem;
	return field;
}

<*
 A held Backspace pauses, then keeps deleting — the field's own clock, since cui
 delivers one down edge per press however long the key is held.
*>
fn void backspace_repeats_while_held() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");
	test::eq((int)field.caret, 10);

	hold(ui, { Key.BACKSPACE });
	test::@check(field.value() == "abcdefghi", "the press itself deletes exactly one");

	hold(ui, { Key.BACKSPACE }, 0.3f);
	test::@check(field.value() == "abcdefghi", "and nothing more inside the delay");

	hold(ui, { Key.BACKSPACE }, 0.2f); // past REPEAT_DELAY
	test::@check(field.length() < 9, "held past the delay, it repeats");

	usz settled = field.length();
	hold(ui, { }, 0.5f);
	hold(ui, { }, 0.5f);
	test::eq((int)field.length(), (int)settled);
}

<*
 Releasing stops the repeat within the same frame, however long that frame is:
 the clock is read only after the key is confirmed still down, so a release that
 arrives alongside a long dt cannot spend it on more deletions.
*>
fn void release_stops_the_repeat() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	hold(ui, { Key.BACKSPACE }, 0.5f); // armed, and past the delay
	usz mid = field.length();
	test::@check(mid < 9, "repeating by now");

	hold(ui, { }, 0.5f); // the release and a long frame together
	test::eq((int)field.length(), (int)mid);
}

<*
 The frame loop is asked to keep running while a key is held. An embedder in
 ON_DEMAND mode parks the thread when nothing is scheduled, and a held key
 produces no further events — the repeat has to ask for the frames its own clock
 runs on.
*>
fn void repeat_keeps_asking_for_frames() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	hold(ui, { Key.BACKSPACE });
	ui.frame_requested = false;

	hold(ui, { Key.BACKSPACE }, 0.1f); // still inside the delay: no edit, no paint
	test::@check(ui.frame_requested, "a held key keeps the loop awake between repeats");

	hold(ui, { });
	ui.frame_requested = false;
	hold(ui, { }, 0.5f);
	test::@check(!ui.frame_requested, "and stops asking once it is let go");
}

<*
 Dragging selects, and the selection is what the next deletion removes.
*>
fn void drag_selects_and_backspace_clears_it() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	cui_tests::frame(ui, { 2, 5 }, left: true); // press left of the padding: offset 0
	test::eq((int)field.caret, 0);
	test::@check(!field.has_selection(), "a press on its own starts an empty selection");

	cui_tests::frame(ui, { 300, 5 }, left: true); // dragged across, button still down
	test::@check(field.selected() == "abcdefghij", "the drag selects what it crossed");

	cui_tests::frame(ui, { 300, 5 }); // released; the selection stays
	test::@check(field.selected() == "abcdefghij");

	hold(ui, { Key.BACKSPACE });
	test::@check(field.value() == "", "one Backspace takes the whole range");
}

<*
 Pointer movement with no button held is nobody's business: a field must not
 keep selecting after the drag that started in it has ended.
*>
fn void movement_without_the_button_does_not_select() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	cui_tests::frame(ui, { 2, 5 }, left: true);
	cui_tests::frame(ui, { 2, 5 });     // release
	cui_tests::frame(ui, { 300, 5 });   // move across with nothing held

	test::@check(!field.has_selection(), "the caret stayed where the click put it");
	test::eq((int)field.caret, 0);
}

<*
 Ctrl+A takes the whole field, and typing replaces what is selected — the pair
 that makes a path field a thing you can retype rather than have to clear.
*>
fn void ctrl_a_then_typing_replaces_everything() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "/home/old/path.gltf");

	hold(ui, { Key.LEFT_CTRL, Key.A });
	test::@check(field.selected() == "/home/old/path.gltf");

	hold(ui, { });
	typed(ui, "x");
	test::@check(field.value() == "x", "the typed character replaced the selection");
	test::@check(!field.has_selection(), "and left nothing selected behind it");
}

<*
 A frame carrying nothing printable — a backend reporting Backspace or Return as
 text as well — leaves the selection alone. Taking it as a replacement would
 delete the range and put a control byte in its place.
*>
fn void control_bytes_do_not_replace_the_selection() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abc");

	hold(ui, { Key.LEFT_CTRL, Key.A });
	hold(ui, { });
	typed(ui, "\r");

	test::@check(field.value() == "abc");
	test::@check(field.selected() == "abc");
}

<*
 Shift extends the selection; a plain arrow steps off it instead of moving one
 character from the caret.
*>
fn void shift_arrow_extends_and_a_plain_arrow_collapses() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	hold(ui, { Key.LEFT_SHIFT, Key.LEFT_ARROW });
	test::@check(field.selected() == "j", "Shift kept the anchor at the end");
	test::eq((int)field.caret, 9);

	hold(ui, { });
	hold(ui, { Key.LEFT_ARROW });
	test::@check(!field.has_selection(), "the plain arrow collapsed it");
	test::eq((int)field.caret, 9); // the near edge of the selection, not 8
}

<*
 Deleting a selection collapses it: an anchor left pointing into text that is no
 longer there would select a range on the next keystroke that the user never
 marked.
*>
fn void deleting_a_selection_leaves_nothing_selected() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = focused_field(ui, &elem, "abcdefghij");

	hold(ui, { Key.LEFT_CTRL, Key.A });
	hold(ui, { });
	hold(ui, { Key.DELETE });

	test::@check(field.value() == "");
	test::@check(!field.has_selection());
	test::eq((int)field.caret, 0);
	test::eq((int)field.anchor, 0);
}

// A field that reports every edit, with the counters cleared and the text set
// before the callback is attached — `set_text` is not an edit and must not fire.
fn TextField* watched_field(Ui* ui, Element** out_elem, String text) @local
{
	changes = 0;
	last_len = 0;

	TextField* field = focused_field(ui, out_elem, text);
	field.on_change = &note_change;
	return field;
}

<*
 Typing reports every character, with the text as it stands after each.

 What a search box is built on: a field that only reported on Return would have
 to be finished before anything narrowed.
*>
fn void typing_reports_every_edit() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	watched_field(ui, &elem, "");

	typed(ui, "b");
	test::eq(changes, 1);
	test::@check(reported() == "b", "the callback was handed '%s'", reported());

	typed(ui, "i");
	typed(ui, "p");
	test::eq(changes, 3);
	test::@check(reported() == "bip", "the callback was handed '%s' rather than the whole field", reported());
}

<*
 A deletion reports, and one that removed nothing does not.

 Backspace at the start of a field consumes the key and changes no text. A held
 key against an end it cannot pass would otherwise re-filter a search thirty
 times a second over text that never moved.
*>
fn void deleting_reports_only_when_something_went() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = watched_field(ui, &elem, "ab");

	hold(ui, { Key.BACKSPACE });
	test::eq(changes, 1);
	test::@check(reported() == "a");

	hold(ui, { });
	hold(ui, { Key.BACKSPACE });
	test::eq(changes, 2);
	test::@check(reported() == "");

	// The field is empty and the caret is at 0: nothing left to take.
	hold(ui, { });
	hold(ui, { Key.BACKSPACE });
	hold(ui, { });
	hold(ui, { Key.DELETE });
	test::eq(changes, 2);
	test::eq((int)field.length(), 0);
}

<*
 A selection typed over reports once, whatever it did to the length.

 Replacing three characters with three is an edit the length cannot see, so a
 callback fired on a length change alone would miss it and leave a search showing
 results for text that is no longer in the box.
*>
fn void replacing_a_selection_reports_even_at_the_same_length() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	watched_field(ui, &elem, "abc");

	hold(ui, { Key.LEFT_CTRL, Key.A });
	hold(ui, { });
	test::eq(changes, 0); // selecting is not editing

	typed(ui, "xyz");
	test::eq(changes, 1);
	test::@check(reported() == "xyz", "the callback was handed '%s'", reported());
}

<*
 `set_text` does not report.

 That is the caller filling the field in, and telling it what it just did is how
 an update loop starts — a callback that rescanned and reset the field would call
 itself.
*>
fn void setting_the_text_is_not_an_edit() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = watched_field(ui, &elem, "abc");

	field.set_text(elem, "something else");
	test::eq(changes, 0);

	// And a frame carrying nothing printable leaves it alone too.
	typed(ui, "\r");
	test::eq(changes, 0);
}

<*
 A held key reports each repeat, because each repeat is an edit.

 The repeat runs off the field's own clock rather than off key events, so it
 reaches the buffer by a path a press does not — and a search that stopped
 narrowing while a key was held would look stuck.
*>
fn void a_held_key_reports_each_repeat() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem;
	TextField* field = watched_field(ui, &elem, "abcdefghij");

	hold(ui, { Key.BACKSPACE });
	test::eq(changes, 1);

	hold(ui, { Key.BACKSPACE }, 0.3f); // inside the delay: no repeat, no report
	test::eq(changes, 1);

	hold(ui, { Key.BACKSPACE }, 0.2f); // past REPEAT_DELAY
	test::@check(changes > 1, "the repeats deleted without reporting");
	test::@check(reported().len == field.length(),
		"the last report was %d characters and the field holds %d", reported().len, field.length());
}
