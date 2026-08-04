<*
 A question with two answers: the panel that asks before something is thrown
 away.

 	`@node((ConfirmDialog) { .title = "Apply body plan" }).with_id("confirm");`

 	`ConfirmDialog* ask = ui.get_widget_id("confirm", ConfirmDialog)!!;`
 	`Element* at = ui.find_id("confirm")!!;`
 	`ask.ask(at, string::tformat("Replace %d dots?", n), &on_replace, &on_keep);`

 It is a `Dialog` underneath and looks like one, so a confirmation and a key
 reference are the same object on screen. What it adds is the part a `Dialog`
 alone cannot do: **the message is decided when the question is asked**, not
 when the tree is built. `Dialog.body` is a plain function pointer with nowhere
 to carry a payload, so a panel wanting to say "this will remove 17 dots" had to
 park that sentence somewhere outside itself and read it back. This owns the
 sentence instead, copying it out of whatever temporary the caller formatted.

 **Every way out is an answer.** Cancel, the close button, ESC and a click on
 the backdrop all run `on_decline`; only the confirming button runs
 `on_confirm`. A dialog whose × meant neither would leave the caller holding a
 question it could never find out had been abandoned.

 The two callbacks are read at the moment the answer is given, so `ask` may
 hand it a different pair each time — the same panel can front several
 questions.
*>
module cui::widgets;

import std::math;
import std::math::vector;
import cui;

<*
 How the two buttons look. Zero `height` means the defaults wholesale, the
 MenuStyle convention — a partially filled style is not merged field by field.
*>
struct ConfirmButtonStyle
{
	Color fill; // the declining button, and what the confirming one hovers to
	Color hover;
	Color press;
	Color accent; // the confirming button
	Color text; // on `fill`
	Color accent_text; // on `accent`
	FontId font;
	float text_size;
	float height;
	float pad_x; // label inset from each end of a button
	float gap; // between the buttons, and above them
	float radius;
}

const ConfirmButtonStyle DEFAULT_CONFIRM_BUTTONS = {
	.fill = { 0.24, 0.26, 0.33, 1.0 },
	.hover = { 0.30, 0.33, 0.42, 1.0 },
	.press = { 0.20, 0.22, 0.28, 1.0 },
	.accent = { 0.40, 0.62, 0.95, 1.0 },
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.accent_text = { 0.10, 0.11, 0.14, 1.0 },
	.text_size = 13.0,
	.height = 28.0,
	.pad_x = 14.0,
	.gap = 10.0,
	.radius = 8.0,
};

fn ConfirmButtonStyle ConfirmButtonStyle.resolved(self)
{
	return self.height > 0 ? self : DEFAULT_CONFIRM_BUTTONS;
}

// How wide the message is allowed to run before it wraps. Not in the style: it
// is a readability limit rather than a taste, and a question long enough to
// cross it is one nobody reads in a single line anyway.
const float CONFIRM_TEXT_W = 380.0;

// Between wrapped lines of the question. Tighter than the gap above the
// buttons, so the message reads as one paragraph rather than as a list.
const float CONFIRM_LINE_GAP = 4.0;

// The inner Dialog, found by the ConfirmDialog that built it. Scoped to that
// subtree by `Element.find_id`, so several confirm dialogs in one tree do not
// collide.
const String CONFIRM_PANEL_ID @local = "cui-confirm-panel";

<*
 The panel. Everything but `message`, `on_confirm` and `on_decline` is
 configured where the node is declared; those three arrive with the question.

 Strings are borrowed as everywhere else here — except `message`, which is
 copied, because the whole point is that it comes from a temporary.
*>
struct ConfirmDialog (Widget)
{
	String title; // borrowed; must outlive the widget
	String confirm_label; // empty = "OK"
	String decline_label; // empty = "Cancel"
	DialogStyle style;
	ConfirmButtonStyle buttons;

	// --- set by `ask` ---
	DString message; // owned
	OnClick on_confirm;
	OnClick on_decline;

	// Raised when `ask` runs before the inner Dialog exists — a composite's
	// children appear at its first layout, and a question asked before then has
	// nowhere yet to be shown. `build` consumes it.
	bool open_when_built;

	// Guards `on_decline` against the close this fires itself on the way out of
	// a confirm: the confirming button closes the panel, and closing is
	// otherwise how declining is reported.
	bool answering;
}

fn String ConfirmDialog.confirm_text(&self) => self.confirm_label.len > 0 ? self.confirm_label : "OK";
fn String ConfirmDialog.decline_text(&self) => self.decline_label.len > 0 ? self.decline_label : "Cancel";

fn void ConfirmDialog.unmount(&self, Element* elem) @dynamic
{
	if (self.message.data()) self.message.free();
}

<*
 Builds the inner Dialog, which builds the rest.

 One node, as a composite must. The panel's own open state lives in that Dialog
 and nowhere here — a second copy is a second thing ESC could leave disagreeing
 with.
*>
fn Element* ConfirmDialog.build(&self, Element* elem) @dynamic
{
	bool open = self.open_when_built;
	self.open_when_built = false;

	return elem.ui.@node((Dialog) {
		.title = self.title,
		.body_ctx = &confirm_body,
		.ctx = elem,
		.style = self.style,
		.modal = true,
		.open = open,

		// A question about to delete work is not answered by a click beside it,
		// so the backdrop does not dismiss. The × and ESC still do, and both
		// count as declining.
		.close_outside = false,
		.on_close_ctx = &confirm_dismissed,
	}).with_id(CONFIRM_PANEL_ID);
}

<*
 Puts a question up.

 	`ask.ask(elem, "Replace the rig?", &replace, &keep);`

 The message is copied, so a `tformat` result or any other temporary is a
 perfectly good argument. Asking again while a question is already up replaces
 it — the newer question is the one the user is looking at.

 @param elem : `The ConfirmDialog's own element.`
 @param message : `What is being asked. Copied; the caller keeps ownership of the original.`
 @param confirm : `Run when the confirming button is pressed.`
 @param decline : `Run on every other way out — Cancel, the close button, ESC. May be null.`
*>
fn void ConfirmDialog.ask(&self, Element* elem, String message, OnClick confirm, OnClick decline = null)
{
	if (!self.message.data()) self.message.init(mem);
	self.message.clear();
	self.message.append(message);

	self.on_confirm = confirm;
	self.on_decline = decline;

	if (try Element* panel = elem.find_id(CONFIRM_PANEL_ID))
	{
		Dialog* panelled = panel.widget_as(Dialog);
		if (panelled.open)
		{
			// Already up, asking something else. `set_open` is a no-op on a state
			// it is already in, and the content is built from a buffer that has
			// just changed underneath it — so the rebuild has to be asked for.
			panel.request_build();
		}
		else
		{
			panelled.set_open(panel, true);
		}
		return;
	}

	self.open_when_built = true;
	elem.request_build();
}

<*
 Whether a question is up. False before the first layout, when there is no panel
 to be up yet.

 @param elem : `The ConfirmDialog's own element.`
*>
fn bool ConfirmDialog.asking(&self, Element* elem)
{
	if (try Element* panel = elem.find_id(CONFIRM_PANEL_ID)) return panel.widget_as(Dialog).open;
	return self.open_when_built;
}

<*
 Takes the question down without running either callback.

 For the caller that has decided the question no longer applies — the document
 was closed underneath it, the pack it was about is gone. An answer is what the
 user gives; this is the question being withdrawn.

 @param elem : `The ConfirmDialog's own element.`
*>
fn void ConfirmDialog.withdraw(&self, Element* elem)
{
	self.open_when_built = false;
	if (try Element* panel = elem.find_id(CONFIRM_PANEL_ID))
	{
		self.answering = true;
		panel.widget_as(Dialog).set_open(panel, false);
		self.answering = false;
	}
}

// ---------------------------------------------------------------------------
// Internals.

<*
 The content: the question, then the two answers.

 Asserted rather than checked: `ConfirmDialog.build` is the only thing that
 sets this, and it passes its own element. A cast that fails here means the
 widget was rewired, not that a caller got something wrong.

 @param ctx : `The ConfirmDialog's element, which is how the row reaches the callbacks.`
*>
fn Element* confirm_body(Ui* ui, any ctx) @local
{
	Element* host = anycast(ctx, Element)!!;
	ConfirmDialog* self = host.widget_as(ConfirmDialog);
	DialogStyle s = self.style.resolved();
	ConfirmButtonStyle b = self.buttons.resolved();

	// One Label per line, because `Label` is a single run of text and a question
	// long enough to need two is exactly the kind worth reading. The slices point
	// into the widget's own buffer, which is why `ask` rebuilds the panel when it
	// changes the message under an open one.
	Element* lines = ui.@node((Column) { .gap = CONFIRM_LINE_GAP });
	String rest = self.message.str_view();
	while (rest.len > 0)
	{
		String line = wrap_line(ui, rest, s.font, s.text_size, CONFIRM_TEXT_W);
		lines.append(ui.@node((Label) {
			.text = line,
			.font = s.font,
			.size = s.text_size,
			.color = s.text_color,
		}));

		rest = rest[line.len..];
		while (rest.len > 0 && rest[0] == ' ') rest = rest[1..];
	}

	// The outer column carries the width, which is what lets the row below it
	// push the buttons to the right edge rather than to the end of its own
	// content — the same shape every button row in a panel here has.
	return ui.@node(
		(Column) { .size = { CONFIRM_TEXT_W, 0 }, .gap = b.gap },
		lines,
		ui.@node((Row) { .main_align = END },
		ui.@node((ConfirmActions) { .host = host, .style = b, .font = s.font }))
	);
}

<*
 The longest prefix of `text` that fits in `width`, broken at a space.

 Falls back to the whole of the first word when even that word is too wide: a
 line that cannot be made to fit is better overflowing than looped over
 forever, and there is nothing else to break at.

 @return `A prefix of the text, never empty unless the text itself is.`
*>
fn String wrap_line(Ui* ui, String text, FontId font, float size, float width) @local
{
	if (ui.text.measure(font, text, size).x <= width) return text;

	usz cut = 0;
	for (usz i = 0; i < text.len; i++)
	{
		if (text[i] != ' ') continue;
		if (ui.text.measure(font, text[:i], size).x > width) break;
		cut = i;
	}

	if (cut > 0) return text[:cut];

	// No break point that fits: take the first word whole.
	foreach (usz i, c : text)
	{
		if (c == ' ') return text[:i];
	}
	return text;
}

// The dialog went away by some route other than the confirming button, which is
// every route that means "no".
fn void confirm_dismissed(Ui* ui, any ctx) @local
{
	Element* host = anycast(ctx, Element)!!;
	ConfirmDialog* self = host.widget_as(ConfirmDialog);

	if (self.answering) return;
	if (self.on_decline) self.on_decline(ui);
}

<*
 The two buttons, painted and hit-tested by one widget.

 Not a Row of `Button`s, for the reason this whole file exists: `OnClick` is a
 bare function pointer, so a Button cannot tell its handler which dialog it
 belongs to. One widget holding `host` can, which is the idiom
 `DialogCloseButton` already uses.
*>
struct ConfirmActions (Widget) @local
{
	Element* host; // the ConfirmDialog element
	ConfirmButtonStyle style;
	FontId font;

	// Hovered and pressed button as index + 1, so zero means none rather than
	// the first — the encoding every hit-tested list here uses.
	int lit;
	int held;

	// Where each button ended up, written by layout and read by paint and the
	// hit test so the three cannot disagree.
	float decline_x;
	float decline_w;
	float confirm_x;
	float confirm_w;
}

fn Vec2 ConfirmActions.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	ConfirmDialog* owner = self.host.widget_as(ConfirmDialog);
	ConfirmButtonStyle s = self.style.resolved();

	float pad = 2 * s.pad_x;
	self.decline_w = elem.ui.text.measure(self.font, owner.decline_text(), s.text_size).x + pad;
	self.confirm_w = elem.ui.text.measure(self.font, owner.confirm_text(), s.text_size).x + pad;

	// Confirm last: the answer that does something sits where the pointer ends
	// up, and the one that does not is passed on the way. Sized to exactly the
	// two buttons — the enclosing Row is what puts them against the right edge.
	self.decline_x = 0;
	self.confirm_x = self.decline_w + s.gap;

	return constraints.constrain({ self.confirm_x + self.confirm_w, s.height });
}

// Which button a point is over: 1 decline, 2 confirm, 0 neither. One arithmetic
// for paint and for the click.
fn int ConfirmActions.hit_at(&self, Vec2 at)
{
	if (at.y < 0 || at.y > self.style.resolved().height) return 0;
	if (at.x >= self.decline_x && at.x < self.decline_x + self.decline_w) return 1;
	if (at.x >= self.confirm_x && at.x < self.confirm_x + self.confirm_w) return 2;
	return 0;
}

fn void ConfirmActions.paint(&self, Element* elem, Painter* painter) @dynamic
{
	ConfirmDialog* owner = self.host.widget_as(ConfirmDialog);
	ConfirmButtonStyle s = self.style.resolved();
	Vec4 radii = { s.radius, s.radius, s.radius, s.radius };

	Color decline_fill = s.fill;
	if (self.held == 1) { decline_fill = s.press; }
	else if (self.lit == 1) { decline_fill = s.hover; }

	Color confirm_fill = self.held == 2 ? s.press : s.accent;

	painter.rect({ self.decline_x, 0 }, { self.decline_w, s.height },
		{ .color = decline_fill, .border_radius = radii });
	painter.rect({ self.confirm_x, 0 }, { self.confirm_w, s.height },
		{ .color = confirm_fill, .border_radius = radii });

	self.label(elem, painter, owner.decline_text(), self.decline_x, self.decline_w, s.text, s);
	self.label(elem, painter, owner.confirm_text(), self.confirm_x, self.confirm_w, s.accent_text, s);
}

// Centred in its button, both ways. Measured rather than assumed, since the
// button was sized around this same measurement.
fn void ConfirmActions.label(
	&self, Element* elem, Painter* painter, String text, float x, float w, Color ink, ConfirmButtonStyle s)
{
	Vec2 run = elem.ui.text.measure(self.font, text, s.text_size);
	painter.text({ x + (w - run.x) * 0.5f, (s.height - run.y) * 0.5f }, text,
		{ .font = self.font, .size = s.text_size, .color = ink });
}

fn void ConfirmActions.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	self.lit = 0;
	self.held = 0;
	elem.set_cursor(Cursor.ARROW);
	elem.request_paint();
}

fn bool ConfirmActions.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	int over = self.hit_at(event.pos);

	switch (event.kind)
	{
		case MOVE:
			if (over != self.lit)
			{
				self.lit = over;
				elem.set_cursor(over > 0 ? Cursor.POINTING_HAND : Cursor.ARROW);
				elem.request_paint();
			}
			return over > 0;

		case PRESS:
			if (event.button != MouseButton.LEFT || over == 0) return false;
			self.held = over;
			elem.request_paint();
			return true;

		case RELEASE:
			int pressed = self.held;
			self.held = 0;
			elem.request_paint();
			if (event.button != MouseButton.LEFT || pressed == 0 || pressed != over) return false;
			self.answer(elem, pressed == 2);
			return true;

		default:
			return false;
	}
}

<*
 Closes the panel and runs the answer the user gave.

 Closed first, so a callback that puts a second question up is not undone by
 this one's dismissal landing after it. `answering` is what keeps that close
 from being reported as a decline.
*>
fn void ConfirmActions.answer(&self, Element* elem, bool confirmed)
{
	ConfirmDialog* owner = self.host.widget_as(ConfirmDialog);
	OnClick chosen = confirmed ? owner.on_confirm : owner.on_decline;

	owner.answering = true;
	owner.withdraw(self.host);
	owner.answering = false;

	if (chosen) chosen(elem.ui);
}
