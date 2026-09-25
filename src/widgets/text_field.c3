<*
 A single line of editable text.

 `@node((TextField) { .placeholder = "file name", .on_submit = &chosen });`

 The first widget in cui to read `Input.text`, which the platform layer has been
 filling all along — c3w's `get_text` on every backend. That is the field's whole
 character source: key codes say *which key*, and only the platform can say what
 a key means under the user's layout, their dead keys and their input method.

 **It takes the keyboard while it has the focus.** Every key it is offered is
 consumed except ESC and TAB, and that is not conservatism — an application that
 keeps single-letter shortcuts (crig hides the mesh on B) would fire them on every
 character typed, because cui bubbles a declined key to the ancestors. ESC is left
 to bubble so an enclosing `Dialog` still closes on it, and TAB so focus can move
 on once there is anywhere to move it to.

 **It repeats held keys itself.** Backspace, Delete and the arrows keep going
 while they are held, on the field's own clock — cui delivers one down edge per
 press, and the platforms disagree about whether a held key produces anything
 after it, so the field cannot wait to be told.

 **Ctrl+C, Ctrl+X and Ctrl+V** go through `Ui.clipboard_write` and
 `clipboard_read`, so they reach the system clipboard when the embedder provides
 a `Clipboard`. A paste is one line: its newlines and tabs become spaces.

 **`multiline`** makes it a box of paragraphs: the text wraps at word boundaries
 to the field's width, Return starts a new line (Ctrl+Return submits), Up and
 Down move between lines, a paste keeps its newlines, and a field shorter than
 its text scrolls - with the wheel, and to wherever the caret goes. `height`
 sets the box; zero is three lines.

 **What it is not**: a single-line field does not scroll past its own width. It
 is a path and a name field.
*>
module cui::widgets;

import cui;
import std::math;
import std::math::vector;
import std::collections::list;


<*
 Called when the field is submitted with Return.

 The string is the field's own buffer, valid only for the duration of the call —
 copy it if it has to outlive the callback.
*>
alias OnSubmit = fn void(Ui* ui, String text);

<*
 Called whenever the user changes the text, on every edit rather than on Return.

 What a search box is built on: filtering only on submit makes a field the user
 has to finish before anything happens, which is a different interaction from one
 that narrows as it is typed.

 Fired for typing, for a deletion that removed something, and for each tick of a
 held key that did. **Not** fired by `set_text` — that is the caller setting the
 field, and a callback there is a caller being told what it just did, which is
 how an update loop starts.

 The string is the field's own buffer, valid only for the duration of the call —
 copy it if it has to outlive the callback.
*>
alias OnChange = fn void(Ui* ui, String text);

// How long a key is held before it starts repeating, and how long between the
// repeats once it does. Close to what a desktop defaults to: the pause is what
// keeps a single tap from deleting two characters, and the interval is fast
// enough to clear a path without the user counting the deletions.
const float REPEAT_DELAY    = 0.4;
const float REPEAT_INTERVAL = 0.035;

<*
 How a TextField draws. A zero style takes `DEFAULT_TEXT_FIELD_STYLE` whole, the
 all-or-nothing rule `DialogStyle` uses: a partially filled style is not merged
 field by field, because "the caller left this at zero" and "the caller wants
 zero here" are the same value and cannot be told apart.
*>
struct TextFieldStyle
{
	Color background;
	Color border;
	Color border_focused;
	Color text;
	Color placeholder;
	Color caret;
	Color selection; // drawn under the selected text, so keep it translucent
	float border_width;
	Vec4 border_radius;
	Vec2 padding; // x each side, y top and bottom
	float text_size; // em px; 0 uses cui::DEFAULT_TEXT_SIZE
	float caret_width;
}

const TextFieldStyle DEFAULT_TEXT_FIELD_STYLE = {
	.background = { 0.12, 0.13, 0.17, 1.0 },
	.border = { 0.28, 0.30, 0.38, 1.0 },
	.border_focused = { 0.95, 0.60, 0.20, 1.0 },
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.placeholder = { 0.45, 0.48, 0.56, 1.0 },
	.caret = { 0.92, 0.93, 0.95, 1.0 },
	.selection = { 0.95, 0.60, 0.20, 0.35 },
	.border_width = 1.0,
	.border_radius = { 4, 4, 4, 4 },
	.padding = { 8.0, 6.0 },
	.text_size = 13.0,
	.caret_width = 1.0,
};

<*
 The style to draw with: this one, or the default when it was left zero.
*>
fn TextFieldStyle TextFieldStyle.resolved(self)
{
	return self.text_size == 0.0f ? DEFAULT_TEXT_FIELD_STYLE : self;
}

struct TextField (Widget)
{
	<*
	 The text, owned by the widget and freed in `unmount`.

	 Not initialised by the literal: a widget struct is copied into the element,
	 so a DString built before the copy would be owned by two of them. `mount`
	 is where it is created, and `set_text` is how a caller fills it in.
	*>
	DString text;

	String placeholder; // borrowed; must outlive the element
	OnSubmit on_submit; // optional; Return
	OnChange on_change; // optional; every edit
	TextFieldStyle style;

	<*
	 Where the next character goes, as a byte offset into `text`.

	 Bytes rather than characters, and always left on a UTF-8 boundary by the
	 movement helpers — the string is handed to the text engine whole, so an
	 index inside a multi-byte sequence would only ever be wrong.
	*>
	usz caret;

	<*
	 The other end of the selection, in the same byte offsets as `caret`.

	 The two together are the selection, in either order — the anchor is where it
	 started and the caret is the end the user is moving, so an anchor after the
	 caret is a selection dragged leftwards and not a mistake. Equal means no
	 selection, which is why every movement that is not extending one puts the
	 anchor back on the caret.
	*>
	usz anchor;

	float width; // px; 0 fills the space offered
	bool multiline; // paragraphs: wraps, Return is a newline - see the top of the file
	float height; // px, multiline only; 0 is three lines
	float scroll; // how far the text is scrolled: up when multiline, left when not, px
	usz revealed; // the caret `scroll` was last moved to show, + 1 (0 = never)
	bool focused; // mirrors ui.focused, so paint and update need not ask the tree
	bool dragging; // a left press landed here and has not been let go

	// The key being auto-repeated and the time left before the next repeat.
	// EMPTY is never a real key, so it means nothing is repeating.
	Key repeat_key;
	float repeat_delay;
}

fn void TextField.mount(&self, Element* elem) @dynamic
{
	self.ensure();
}

// The buffer, made if it is not there yet.
// 
// `mount` runs at the element's first layout, not when it is built — so a caller
// that fills a freshly built field in (`set_text` from a composite's builder)
// reaches it before mount does. Both go through here, and whichever is first
// makes the buffer.
fn void TextField.ensure(&self)
{
	if (!self.text.data()) self.text.init(mem);
}

fn void TextField.unmount(&self, Element* elem) @dynamic
{
	self.text.free();
}

<*
 Replace the contents and put the caret at the end.

 The way a caller fills a field in — a destination path, a name to edit — since
 a struct literal cannot carry a DString the element would then own two of.

 Safe on a field that has been built but not yet laid out, which is where a
 composite fills in what it just made.
*>
fn void TextField.set_text(&self, Element* elem, String text)
{
	self.ensure();
	// The same text again is no change, and leaves the caret where the person
	// typing put it: a caller that renders the field from its own copy of the
	// value hands every keystroke straight back.
	if (self.text.str_view() == text) return;
	self.text.clear();
	self.text.append_string(text);
	self.caret = self.length();
	self.anchor = self.caret;
	elem.request_paint();
}

<*
 Whether any text is selected — the question every edit asks first, since a
 selection is what a keystroke replaces and what a deletion removes.
*>
fn bool TextField.has_selection(&self) => self.anchor != self.caret;

// The selected range as a half-open byte span, ordered whichever way the
// selection was made.
fn usz TextField.selection_start(&self) => self.anchor < self.caret ? self.anchor : self.caret;
fn usz TextField.selection_end(&self) => self.anchor > self.caret ? self.anchor : self.caret;

<*
 What is selected, or the empty string when nothing is. Borrowed from the
 field's own buffer and dies with the next edit, like `value`.
*>
fn String TextField.selected(&self)
{
	usz start = self.selection_start();
	return self.text.str_view()[start:self.selection_end() - start];
}

<*
 Selects everything and leaves the caret at the end — what Ctrl+A does, and what
 a caller does to hand over a field whose contents are meant to be replaced
 rather than edited.
*>
fn void TextField.select_all(&self, Element* elem)
{
	self.anchor = 0;
	self.caret = self.length();
	elem.request_paint();
}

<*
 Removes the selected text and leaves the caret where it was.

 @return `True if there was a selection to remove; false leaves the field untouched.`
*>
fn bool TextField.delete_selection(&self)
{
	usz start = self.selection_start();
	usz end   = self.selection_end();
	if (start == end) return false;

	self.text.delete((sz)start, (sz)(end - start));
	self.caret = start;
	self.anchor = start;
	return true;
}

<*
 What the field currently holds. Borrowed from the widget's own buffer, so it
 dies with the next edit — copy anything that has to outlive the callback.
*>
fn String TextField.value(&self) => self.text.str_view();

// DString counts in `sz` and String slices in `usz`; the caret is an index into
// both, so one of the two conversions has to live somewhere. Here.
fn usz TextField.length(&self) => (usz)self.text.len();

fn Vec2 TextField.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	TextFieldStyle style = self.style.resolved();

	// Measured against a fixed sample rather than the current text: a field whose
	// height changed with what was typed in it would move everything under it on
	// every keystroke. "Mg" carries both an ascender and a descender.
	float line   = elem.ui.text.measure(0, "Mg", style.text_size).y;
	float height = line + style.padding.y * 2.0f;
	// Its own text is clipped to the box, which is what lets it scroll.
	elem.clips = true;
	elem.clip_radii = style.border_radius;
	if (self.multiline)
	{
		height = self.height > 0.0f ? self.height : line_step(line) * 3.0f + style.padding.y * 2.0f;
	}

	return constraints.constrain({ self.width > 0.0f ? self.width : constraints.max.x, height });
}

fn void TextField.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TextFieldStyle style = self.style.resolved();

	painter.rect(
		{ 0, 0 },
		elem.size,
		{
			.color = style.background,
			.border_color = self.focused ? style.border_focused : style.border,
			.border_width = style.border_width,
			.border_radius = style.border_radius,
		}
	);

	if (self.multiline)
	{
		self.paint_lines(elem, painter, style);
		return;
	}

	String shown       = self.text.str_view();
	float inner_height = elem.size.y - style.padding.y * 2.0f;
	float inner_width  = elem.size.x - style.padding.x * 2.0f;

	// Scrolled sideways to keep the caret in the box while it is being edited,
	// and back to the start once it is not.
	if (!self.focused)
	{
		self.scroll = 0;
	}
	else if (self.revealed != self.caret + 1)
	{
		self.revealed = self.caret + 1;
		float x = self.offset_of(elem, self.caret);
		if (x - self.scroll > inner_width) self.scroll = x - inner_width;
		if (x < self.scroll) self.scroll = x;
	}
	Vec2 at = { style.padding.x - self.scroll, style.padding.y };

	// Under the text, and only while focused — for the same reason as the caret:
	// a highlight left on a field that is no longer taking keys says the next
	// keystroke would replace it, and it would not.
	if (self.focused && self.has_selection())
	{
		float from = self.offset_of(elem, self.selection_start());
		float to   = self.offset_of(elem, self.selection_end());
		painter.rect({ at.x + from, at.y }, { to - from, inner_height }, { .color = style.selection });
	}

	if (shown.len == 0 && self.placeholder.len > 0)
	{
		painter.text(at, self.placeholder, { .size = style.text_size, .color = style.placeholder });
	}
	else if (shown.len > 0)
	{
		painter.text(at, shown, { .size = style.text_size, .color = style.text });
	}

	// The caret is drawn only while focused, which is what distinguishes a field
	// waiting for input from one that merely holds text.
	if (!self.focused) return;

	painter.rect(
		{ at.x + self.offset_of(elem, self.caret), at.y },
		{ style.caret_width, inner_height },
		{ .color = style.caret }
	);
}

<*
 Where a byte offset sits, in pixels from the start of the text — the x of the
 caret, and of either edge of the selection.

 @param index : `A byte offset into the text; clamped to its length.`
 @return `The width of the text before the offset, at the field's text size.`
*>
fn float TextField.offset_of(&self, Element* elem, usz index)
{
	if (index == 0) return 0.0f;

	String shown = self.text.str_view();
	if (index > shown.len) index = shown.len;
	return elem.ui.text.measure(0, shown[:index], self.style.resolved().text_size).x;
}

<*
 Takes in whatever the platform reported as typed this frame.

 Read here rather than in `on_key` because it arrives as text, not as keys:
 `Input.text` is the layout's answer to a whole frame of keystrokes, dead keys
 and IME composition folded together.

 **Guarded on the focus**, and that guard is the whole safety of it —
 `Input.text` is per-frame global state and is not routed to anybody, so a field
 that did not check would type along with whichever one the user is really in.
*>
fn void TextField.update(&self, Element* elem, float dt) @dynamic
{
	bool focused = elem.ui.focused == elem;
	if (focused != self.focused)
	{
		self.focused = focused;
		elem.request_paint();
	}
	if (!focused)
	{
		// A field that lost the focus mid-drag or mid-repeat keeps neither: the
		// keys and the pointer are somebody else's now.
		self.dragging = false;
		self.repeat_key = Key.EMPTY;
		return;
	}

	self.tick_repeat(elem, dt);

	String typed = elem.ui.input.text;
	if (typed.len == 0) return;

	// Control bytes are not text: Return and Backspace arrive as keys, and some
	// backends also report them here. Taking them literally would put a 0x08 in
	// the middle of a file name — and a frame carrying nothing else must leave
	// the field alone entirely, selection included.
	bool printable = false;
	foreach (char c : typed)
	{
		if (c >= 0x20 && c != 0x7f)
		{
			printable = true;
			break;
		}
	}
	if (!printable) return;

	// Typing replaces the selection, which is the only reason selecting a range
	// and then typing over it feels like one action rather than two.
	self.delete_selection();

	foreach (char c : typed)
	{
		if (c < 0x20 || c == 0x7f) continue;
		self.text.insert_chars_at((sz)self.caret, (String)&&(char[1]) { c });
		self.caret++;
	}
	self.anchor = self.caret;
	elem.request_paint();
	// Unconditional: the printable check above guarantees at least one character
	// went in, so reaching here is an edit whether or not the length moved — a
	// selection typed over by the same number of characters is still a change.
	if (self.on_change) self.on_change(elem.ui, self.text.str_view());
}

<*
 Advances the auto-repeat clock and fires the repeats that are due.

 The field runs this clock itself because cui reports key edges, not repeats:
 `on_key` sees one down per press however long it is held. What it repeats is
 whatever `apply` did for the press, re-read from the live modifier state, so
 adding Shift partway through a held arrow starts extending the selection from
 there.

 **Asks for a frame while a key is held.** An embedder in ON_DEMAND mode parks
 the thread when nothing is scheduled, and a held key generates no events to
 wake it — without this the repeat would stall between its own ticks.
*>
fn void TextField.tick_repeat(&self, Element* elem, float dt)
{
	if (self.repeat_key == Key.EMPTY) return;

	// The held-key set is the authority on whether the key is still down, and it
	// is this frame's: a release, or a window that lost the keyboard mid-hold,
	// both show up here as the key simply being gone.
	if (!elem.ui.input.key_down(self.repeat_key))
	{
		self.repeat_key = Key.EMPTY;
		return;
	}

	elem.ui.request_frame();

	self.repeat_delay -= dt;
	// A loop rather than one repeat per frame: at this interval a frame that
	// took longer than usual covers several, and dropping them would make the
	// deletion speed depend on the frame rate.
	while (self.repeat_delay <= 0.0f)
	{
		self.apply(elem, self.repeat_key);
		self.repeat_delay += REPEAT_INTERVAL;
	}
}

<*
 Editing keys, and the refusal that keeps the rest of the application out.

 Everything is consumed except ESC and TAB. The keys this switch does not name
 are not ignored — they are swallowed, because they are about to arrive as text
 in `update` and an application that also keeps them as shortcuts would act on
 them twice. See the note at the top of this file.

 @return `True for every key except ESC and TAB, whether or not it did anything.`
*>
fn bool TextField.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (event.key == Key.ESCAPE || event.key == Key.TAB) return false;
	// The release of a repeating key needs nothing here: `tick_repeat` runs later
	// in the same frame and reads the held-key set, which no longer has it.
	if (!event.down) return true;

	if (ctrl_held(elem.ui))
	{
		switch (event.key)
		{
			case Key.A:
				self.select_all(elem);
				return true;
			case Key.C:
				if (self.has_selection()) elem.ui.clipboard_write(self.selected());
				return true;
			case Key.X:
				if (!self.has_selection()) return true;
				elem.ui.clipboard_write(self.selected());
				self.delete_selection();
				elem.request_paint();
				if (self.on_change) self.on_change(elem.ui, self.text.str_view());
				return true;
			case Key.V:
				self.paste(elem);
				return true;
			default:
				break;
		}
	}

	if (event.key == Key.RETURN || event.key == Key.KP_RETURN)
	{
		if (self.multiline && !ctrl_held(elem.ui))
		{
			self.insert(elem, "\n");
			return true;
		}
		if (self.on_submit) self.on_submit(elem.ui, self.text.str_view());
		return true;
	}

	// Consumed either way: a key this field does not edit with is about to
	// arrive as text in `update`, and an application that also kept it as a
	// shortcut would act on it twice.
	if (!self.apply(elem, event.key)) return true;

	self.repeat_key = repeats(event.key) ? event.key : Key.EMPTY;
	self.repeat_delay = REPEAT_DELAY;
	return true;
}

<*
 The clipboard's text in place of the selection, on one line: a newline or a tab
 becomes a space and any other control byte is dropped.
*>
fn void TextField.paste(&self, Element* elem)
{
	@pool()
	{
		String pasted = elem.ui.clipboard_read(tmem);
		DString line = dstring::temp();
		foreach (char c : pasted)
		{
			if (c == '\n' && self.multiline)
			{
				line.append_char('\n');
			}
			else if (c == '\n' || c == '\t')
			{
				line.append_char(' ');
			}
			else if (c >= 0x20 && c != 0x7f)
			{
				line.append_char(c);
			}
		}
		if (line.len() == 0) return;
		self.insert(elem, line.str_view());
	};
}

<*
 `text` in place of the selection, the caret after it, and the change reported.
*>
fn void TextField.insert(&self, Element* elem, String text)
{
	self.delete_selection();
	self.text.insert_chars_at((sz)self.caret, text);
	self.caret += text.len;
	self.anchor = self.caret;
	elem.request_paint();
	if (self.on_change) self.on_change(elem.ui, self.text.str_view());
}

<*
 Runs one editing key, whether it was just pressed or is repeating.

 Shift is read from the frame rather than passed in, so a repeat follows the
 modifier as it is now: adding Shift to a held arrow starts extending the
 selection, letting go of it goes back to moving the caret.

 @return `True if this was a key the field edits with; false is a key that will arrive as text instead.`
*>
fn bool TextField.apply(&self, Element* elem, Key key)
{
	switch (key)
	{
		case Key.BACKSPACE:
		case Key.DELETE:
			// Measured across the deletion rather than assumed: Backspace at the
			// start of the field, and Delete at the end, are keys that consume the
			// event and remove nothing. Reporting those as edits would filter a
			// search on every tick of a key held against an end it cannot pass.
			usz before = self.length();
			self.delete_key(key);
			// A deletion always collapses the selection: it is what was removed,
			// so there is nothing left for the anchor to hold on to.
			self.anchor = self.caret;
			if (self.length() != before && self.on_change)
			{
				self.on_change(elem.ui, self.text.str_view());
			}
		case Key.UP_ARROW:
		case Key.DOWN_ARROW:
			if (!self.multiline) return false;
			self.move_line(elem, key == Key.UP_ARROW ? -1 : 1, shift_held(elem.ui));
		case Key.HOME:
		case Key.END:
			if (self.multiline)
			{
				self.move_line(elem, 0, shift_held(elem.ui), key == Key.HOME ? -1 : 1);
			}
			else
			{
				self.move_caret(key, shift_held(elem.ui));
			}
		case Key.LEFT_ARROW:
		case Key.RIGHT_ARROW:
			self.move_caret(key, shift_held(elem.ui));
		default:
			return false;
	}

	elem.request_paint();
	return true;
}

// One deletion: the selection if there is one, and otherwise the character on
// the side of the caret the key names.
fn void TextField.delete_key(&self, Key key)
{
	if (self.delete_selection()) return;

	if (key == Key.BACKSPACE)
	{
		if (self.caret == 0) return;
		usz start = self.previous_boundary();
		self.text.delete((sz)start, (sz)(self.caret - start));
		self.caret = start;
		return;
	}

	if (self.caret >= self.length()) return;
	usz end = self.next_boundary();
	self.text.delete((sz)self.caret, (sz)(end - self.caret));
}

<*
 One caret movement.

 @param extend : `Keep the anchor, growing or shrinking the selection; false collapses it onto the caret.`
*>
fn void TextField.move_caret(&self, Key key, bool extend)
{
	switch (key)
	{
		case Key.LEFT_ARROW:
			// A plain arrow steps off a selection rather than one character in
			// from the caret: the selection is what the user is looking at, and
			// its edge is where they expect to land.
			self.caret = !extend && self.has_selection() ? self.selection_start() : self.previous_boundary();
		case Key.RIGHT_ARROW:
			self.caret = !extend && self.has_selection() ? self.selection_end() : self.next_boundary();
		case Key.HOME:
			self.caret = 0;
		case Key.END:
			self.caret = self.length();
		default:
			break;
	}

	if (!extend) self.anchor = self.caret;
}

// Which keys keep going while they are held. Movement and deletion only: HOME
// and END have nowhere further to go, and a repeat that changes nothing would
// still hold the frame loop awake for as long as the key was down.
fn bool repeats(Key key) @local
{
	return key == Key.BACKSPACE || key == Key.DELETE || key == Key.LEFT_ARROW || key == Key.RIGHT_ARROW
		|| key == Key.UP_ARROW || key == Key.DOWN_ARROW;
}

// The modifiers, read from the frame's held-key set: cui delivers Shift and
// Ctrl as keys of their own rather than as flags on the event.
fn bool shift_held(Ui* ui) @local
{
	return ui.input.key_down(Key.LEFT_SHIFT) || ui.input.key_down(Key.RIGHT_SHIFT);
}

fn bool ctrl_held(Ui* ui) @local
{
	return ui.input.key_down(Key.LEFT_CTRL) || ui.input.key_down(Key.RIGHT_CTRL);
}

<*
 Focus on a left press, place the caret where the click landed, and select what
 the pointer is dragged across.

 Clicking already focuses in cui — `update_focus` picks the deepest hit element
 whose widget takes keys — so this is only about the caret. The press is
 consumed either way: a field is an editable surface, not a hole through to
 whatever is behind it, and consuming it is also what captures the pointer, so
 the drag keeps selecting after it has left the field's own rect.

 Shift on the press extends instead of starting over, which is the other way to
 select a range without holding the button down.
*>
fn bool TextField.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			elem.request_focus();
			self.caret = self.caret_at(elem, event.pos);
			if (!shift_held(elem.ui)) self.anchor = self.caret;
			self.dragging = true;
			elem.request_paint();
			return true;
		case MOVE:
			// Only while this field owns the press. Bare movement over a field is
			// nobody's event, and consuming it would stop anything above from
			// tracking the pointer.
			if (!self.dragging) return false;
			usz at = self.caret_at(elem, event.pos);
			if (at != self.caret)
			{
				self.caret = at;
				elem.request_paint();
			}
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			return true;
		case SCROLL:
			// Taken only while there is somewhere to go, so a box at either end
			// hands the wheel on to whatever scrolls around it.
			if (!self.multiline) return false;
			float before = self.scroll;
			self.scroll = self.clamp_scroll(elem, self.scroll - event.scroll * 3.0f * self.line_height(elem));
			if (self.scroll == before) return false;
			elem.request_paint();
			return true;
		default:
			return false;
	}
}

fn void TextField.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.IBEAM);
}

<*
 The caret position closest to `x`, in element-local pixels.

 Measured prefix by prefix rather than by dividing by an average width: the font
 is proportional, so an average puts the caret several characters out on a line
 of `l`s or `W`s. One measure per boundary is affordable on a line this short and
 is exact.
*>
fn usz TextField.caret_for(&self, Element* elem, float x)
{
	TextFieldStyle style = self.style.resolved();
	String shown         = self.text.str_view();
	float wanted         = x - style.padding.x + self.scroll;
	if (wanted <= 0.0f) return 0;

	float previous = 0.0f;
	for (usz i = 1; i <= shown.len; i++)
	{
		if (!boundary(shown, i)) continue;

		float width = elem.ui.text.measure(0, shown[:i], style.text_size).x;
		// The nearer edge of the character just crossed: clicking the left half
		// of a glyph puts the caret before it, the right half after it, which is
		// what every other text field does.
		if (width >= wanted) return (wanted - previous) < (width - wanted) ? previous_index(shown, i) : i;
		previous = width;
	}
	return shown.len;
}

// The byte offset before the caret, skipping back over a whole UTF-8 sequence.
fn usz TextField.previous_boundary(&self)
{
	String shown = self.text.str_view();
	usz i        = self.caret;
	while (i > 0)
	{
		i--;
		if (boundary(shown, i)) return i;
	}
	return 0;
}

// The byte offset after the caret, skipping forward over a whole UTF-8 sequence.
fn usz TextField.next_boundary(&self)
{
	String shown = self.text.str_view();
	usz i        = self.caret;
	while (i < shown.len)
	{
		i++;
		if (boundary(shown, i)) return i;
	}
	return shown.len;
}

// Whether `index` sits between two characters rather than inside one. A UTF-8
// continuation byte is 10xxxxxx and is the only thing that can be stood on by
// mistake.
fn bool boundary(String text, usz index) @local
{
	if (index == 0 || index >= text.len) return true;
	return (text[index] & 0xc0) != 0x80;
}

// The boundary strictly before `index`, for the "clicked the left half" answer.
fn usz previous_index(String text, usz index) @local
{
	usz i = index;
	while (i > 0)
	{
		i--;
		if (boundary(text, i)) return i;
	}
	return 0;
}
// ---------------------------------------------------------------------------
// Multiline

// One wrapped line: bytes `start` .. `end` of the text, without the newline
// that may end it.
struct TextLine @local
{
	usz start;
	usz end;
}

// The distance between baselines, for text of this height.
fn float line_step(float line) @local => math::ceil(line * 1.25f);

fn float TextField.line_height(&self, Element* elem)
{
	return line_step(elem.ui.text.measure(0, "Mg", self.style.resolved().text_size).y);
}

<*
 The text broken into lines that fit the box: at newlines, and between words
 where a line would overflow. A word wider than the box is broken wherever it
 has to be. Allocated with `alloc`.
*>
fn List{TextLine} TextField.lines(&self, Element* elem, Allocator alloc)
{
	TextFieldStyle style = self.style.resolved();
	float width = elem.size.x - style.padding.x * 2.0f;
	String text = self.text.str_view();
	List{TextLine} lines;
	lines.init(alloc);

	usz para = 0;
	while (true)
	{
		usz para_end = para;
		while (para_end < text.len && text[para_end] != '\n') para_end++;

		usz line = para;
		usz at = para;
		while (at < para_end)
		{
			usz word = at;
			while (word < para_end && text[word] != ' ') word++;
			while (word < para_end && text[word] == ' ') word++;
			usz visible = word;
			while (visible > line && text[visible - 1] == ' ') visible--;
			float wide = elem.ui.text.measure(0, text[line:visible - line], style.text_size).x;
			if (wide <= width)
			{
				at = word;
				continue;
			}
			if (at > line)
			{
				// The word goes to a line of its own.
				lines.push({ line, at });
				line = at;
				continue;
			}
			// A word longer than the box: as much of it as fits, at least one
			// character.
			usz fit = line;
			for (usz i = line + 1; i <= word; i++)
			{
				if (!boundary(text, i)) continue;
				if (fit > line && elem.ui.text.measure(0, text[line:i - line], style.text_size).x > width) break;
				fit = i;
			}
			lines.push({ line, fit });
			line = fit;
			at = fit;
		}
		lines.push({ line, para_end });
		if (para_end >= text.len) break;
		para = para_end + 1;
	}
	return lines;
}

// Which line holds byte `index`: the last one starting at or before it.
fn usz line_of(List{TextLine}* lines, usz index) @local
{
	usz found = 0;
	foreach (i, line : *lines)
	{
		if (line.start > index) break;
		found = (usz)i;
	}
	return found;
}

fn float TextField.clamp_scroll(&self, Element* elem, float scroll)
{
	float most = 0.0f;
	@pool()
	{
		List{TextLine} lines = self.lines(elem, tmem);
		TextFieldStyle style = self.style.resolved();
		float inner = elem.size.y - style.padding.y * 2.0f;
		most = math::max(0.0f, (float)lines.len() * self.line_height(elem) - inner);
	};
	return math::clamp(scroll, 0.0f, most);
}

fn void TextField.paint_lines(&self, Element* elem, Painter* painter, TextFieldStyle style)
{
	@pool()
	{
		String text = self.text.str_view();
		List{TextLine} lines = self.lines(elem, tmem);
		float step = self.line_height(elem);
		float inner = elem.size.y - style.padding.y * 2.0f;
		usz caret_line = line_of(&lines, self.caret);

		// Scrolled to the caret whenever it has moved, and left where the wheel
		// put it otherwise.
		if (self.revealed != self.caret + 1)
		{
			self.revealed = self.caret + 1;
			float top = (float)caret_line * step;
			if (top < self.scroll) self.scroll = top;
			if (top + step > self.scroll + inner) self.scroll = top + step - inner;
		}
		self.scroll = math::clamp(self.scroll, 0.0f, math::max(0.0f, (float)lines.len() * step - inner));

		float y0 = style.padding.y - self.scroll;
		if (text.len == 0 && self.placeholder.len > 0)
		{
			painter.text({ style.padding.x, y0 }, self.placeholder, { .size = style.text_size, .color = style.placeholder });
		}

		usz from = self.selection_start();
		usz to = self.selection_end();
		foreach (i, line : lines)
		{
			float y = y0 + (float)i * step;
			if (y + step < 0.0f || y > elem.size.y) continue;
			String shown = text[line.start:line.end - line.start];
			if (self.focused && from < to && from <= line.end && to > line.start)
			{
				usz a = math::max(from, line.start);
				usz b = math::min(to, line.end);
				float x0 = elem.ui.text.measure(0, text[line.start:a - line.start], style.text_size).x;
				float x1 = elem.ui.text.measure(0, text[line.start:b - line.start], style.text_size).x;
				// A selected newline shows as a little room past the line's end.
				if (to > line.end && i + 1 < lines.len()) x1 += style.text_size * 0.3f;
				painter.rect({ style.padding.x + x0, y }, { x1 - x0, step }, { .color = style.selection });
			}
			if (shown.len > 0) painter.text({ style.padding.x, y }, shown, { .size = style.text_size, .color = style.text });
		}

		if (!self.focused) return;
		TextLine line = lines[(sz)caret_line];
		float x = elem.ui.text.measure(0, text[line.start:self.caret - line.start], style.text_size).x;
		painter.rect(
			{ style.padding.x + x, y0 + (float)caret_line * step },
			{ style.caret_width, step },
			{ .color = style.caret }
		);
	};
}

<*
 The caret position closest to an element-local point: a line by its y, then a
 place in it by its x.
*>
fn usz TextField.caret_at(&self, Element* elem, Vec2 pos)
{
	if (!self.multiline) return self.caret_for(elem, pos.x);
	usz found;
	@pool()
	{
		TextFieldStyle style = self.style.resolved();
		List{TextLine} lines = self.lines(elem, tmem);
		float step = self.line_height(elem);
		int row = (int)math::floor((pos.y - style.padding.y + self.scroll) / step);
		if (row < 0) row = 0;
		if (row >= (int)lines.len()) row = (int)lines.len() - 1;
		found = self.index_in_line(elem, lines[(sz)row], pos.x - style.padding.x);
	};
	return found;
}

// The byte in `line` nearest `x` pixels from its start.
fn usz TextField.index_in_line(&self, Element* elem, TextLine line, float x) @local
{
	TextFieldStyle style = self.style.resolved();
	String text = self.text.str_view();
	if (x <= 0.0f) return line.start;
	float previous = 0.0f;
	usz before = line.start;
	for (usz i = line.start + 1; i <= line.end; i++)
	{
		if (!boundary(text, i)) continue;
		float width = elem.ui.text.measure(0, text[line.start:i - line.start], style.text_size).x;
		if (width >= x) return (x - previous) < (width - x) ? before : i;
		previous = width;
		before = i;
	}
	return line.end;
}

<*
 Move the caret `rows` lines up (negative) or down, keeping its x; or with
 `edge`, to the start (-1) or end (1) of its own line.
*>
fn void TextField.move_line(&self, Element* elem, int rows, bool extend, int edge = 0)
{
	@pool()
	{
		TextFieldStyle style = self.style.resolved();
		String text = self.text.str_view();
		List{TextLine} lines = self.lines(elem, tmem);
		usz row = line_of(&lines, self.caret);
		TextLine here = lines[(sz)row];
		if (edge != 0)
		{
			self.caret = edge < 0 ? here.start : here.end;
		}
		else
		{
			float x = elem.ui.text.measure(0, text[here.start:self.caret - here.start], style.text_size).x;
			if (rows < 0 && row == 0)
			{
				self.caret = 0;
			}
			else if (rows > 0 && row + 1 >= (usz)lines.len())
			{
				self.caret = text.len;
			}
			else
			{
				usz to = rows < 0 ? row - 1 : row + 1;
				self.caret = self.index_in_line(elem, lines[(sz)to], x);
			}
		}
	};
	if (!extend) self.anchor = self.caret;
}
