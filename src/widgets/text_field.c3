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

 **What it is not**: no selection, no clipboard, no wrapping, no scrolling past
 its own width. It is a path and a name field, and the caret alone is enough to
 edit one. Each of those is additive later without changing what is here.
*>
module cui::widgets;

import cui;
import std::math::vector;
import std::core::dstring;

<*
 Called when the field is submitted with Return.

 The string is the field's own buffer, valid only for the duration of the call —
 copy it if it has to outlive the callback.
*>
alias OnSubmit = fn void(Ui* ui, String text);

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
	TextFieldStyle style;

	<*
	 Where the next character goes, as a byte offset into `text`.

	 Bytes rather than characters, and always left on a UTF-8 boundary by the
	 movement helpers — the string is handed to the text engine whole, so an
	 index inside a multi-byte sequence would only ever be wrong.
	*>
	usz caret;

	float width; // px; 0 fills the space offered
	bool focused; // mirrors ui.focused, so paint and update need not ask the tree
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
	self.text.clear();
	self.text.append_string(text);
	self.caret = self.length();
	elem.request_paint();
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
	float line = elem.ui.text.measure(0, "Mg", style.text_size).y;
	float height = line + style.padding.y * 2.0f;

	return constraints.constrain({ self.width > 0.0f ? self.width : constraints.max.x, height });
}

fn void TextField.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TextFieldStyle style = self.style.resolved();

	painter.rect({ 0, 0 }, elem.size, {
		.color = style.background,
		.border_color = self.focused ? style.border_focused : style.border,
		.border_width = style.border_width,
		.border_radius = style.border_radius,
	});

	String shown = self.text.str_view();
	Vec2 at = { style.padding.x, style.padding.y };

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

	float offset = self.caret == 0
		? 0.0f
		: elem.ui.text.measure(0, shown[:self.caret], style.text_size).x;

	painter.rect(
		{ at.x + offset, at.y },
		{ style.caret_width, elem.size.y - style.padding.y * 2.0f },
		{ .color = style.caret });
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
	if (!focused) return;

	String typed = elem.ui.input.text;
	if (typed.len == 0) return;

	// Control bytes are not text: Return and Backspace arrive as keys, and some
	// backends also report them here. Taking them literally would put a 0x08 in
	// the middle of a file name.
	foreach (char c : typed)
	{
		if (c < 0x20 || c == 0x7f) continue;
		self.text.insert_chars_at((sz)self.caret, (String)&&(char[1]){ c });
		self.caret++;
	}
	elem.request_paint();
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
	if (!event.down) return true;

	switch (event.key)
	{
		case Key.BACKSPACE:
			if (self.caret > 0)
			{
				usz start = self.previous_boundary();
				self.text.delete((sz)start, (sz)(self.caret - start));
				self.caret = start;
			}
		case Key.DELETE:
			if (self.caret < self.length())
			{
				usz end = self.next_boundary();
				self.text.delete((sz)self.caret, (sz)(end - self.caret));
			}
		case Key.LEFT_ARROW:
			self.caret = self.previous_boundary();
		case Key.RIGHT_ARROW:
			self.caret = self.next_boundary();
		case Key.HOME:
			self.caret = 0;
		case Key.END:
			self.caret = self.length();
		case Key.RETURN:
		case Key.KP_RETURN:
			if (self.on_submit) self.on_submit(elem.ui, self.text.str_view());
		default:
			// Consumed and left to `update`, which is where the character it
			// produced will arrive.
			return true;
	}

	elem.request_paint();
	return true;
}

<*
 Focus on a left press, and place the caret where the click landed.

 Clicking already focuses in cui — `update_focus` picks the deepest hit element
 whose widget takes keys — so this is only about the caret. The press is
 consumed either way: a field is an editable surface, not a hole through to
 whatever is behind it.
*>
fn bool TextField.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != MouseEventKind.PRESS || event.button != MouseButton.LEFT) return false;

	elem.request_focus();
	self.caret = self.caret_for(elem, event.pos.x);
	elem.request_paint();
	return true;
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
	String shown = self.text.str_view();
	float wanted = x - style.padding.x;
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
	usz i = self.caret;
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
	usz i = self.caret;
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
