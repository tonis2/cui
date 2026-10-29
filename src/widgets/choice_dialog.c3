<*
 A question whose answers are its children: as many buttons as it is declared
 with, each doing its own thing.

 `Element* loop = @tree((ChoiceDialog) { .title = "Make loop" })`
 `{`
 `    @node((Button) { .label = "Cancel", .on_click = &cancel });`
 `    @node((Button) { .label = "Whole take", .on_click = &whole });`
 `};`
 `loop.with_id("loop");`

 `Element* at = ui.find_id("loop")!!;`
 `at.widget_as(ChoiceDialog).ask(at, string::tformat("Loop %s?", name));`

 Like `ConfirmDialog`, it is a `Dialog` underneath and **the message is decided
 when the question is asked**, copied out of whatever temporary the caller
 formatted. Unlike it, the buttons are not drawn here: they are ordinary
 elements, laid out in a row against the panel's right edge in the order they
 were declared, and kept across every opening.

 **A button closes the panel itself.** Its `on_click` does its work and calls
 `withdraw` — an `OnClick` cannot say which dialog its button is in, so the
 panel never finds out a button was pressed. The × and ESC close it on their
 own and run `on_dismiss`.
*>
module cui::widgets;

import cui;

// Between the buttons, and above them, when the node leaves `gap` at zero —
// the same spacing a ConfirmDialog's two answers get.
const float CHOICE_GAP = 10.0;

// The inner Dialog, found by the ChoiceDialog that built it. Scoped to that
// subtree by `Element.find_id`, so several in one tree do not collide.
const String CHOICE_PANEL_ID @local = "cui-choice-panel";

<*
 The panel. Everything but `message` is configured where the node is declared;
 the message arrives with the question.

 Strings are borrowed as everywhere else here, except `message`, which is copied
 because it comes from a temporary.
*>
struct ChoiceDialog (Widget)
{
	String title; // borrowed; must outlive the widget
	DialogStyle style;
	float gap; // between the buttons, and above them; 0 = CHOICE_GAP
	OnClick on_dismiss; // the × or ESC; not run by `withdraw`. May be null.

	// --- set by `ask` ---
	DString message; // owned

	// Raised when `ask` runs before the inner Dialog exists; `build` consumes it.
	bool open_when_built;

	// Guards `on_dismiss` against the close `withdraw` fires itself.
	bool withdrawing;
}

fn void ChoiceDialog.unmount(&self, Element* elem) @dynamic
{
	if (self.message.data()) self.message.free();
}

<*
 Builds the inner Dialog, which builds the rest. Its open state lives in that
 Dialog and nowhere here.
*>
fn Element* ChoiceDialog.build(&self, Element* elem) @dynamic
{
	bool open = self.open_when_built;
	self.open_when_built = false;

	return elem.ui.@node(
		(Dialog) {
			.title = self.title,
			.body_ctx = &choice_body,
			.ctx = elem,
			.style = self.style,
			.modal = true,
			.open = open,
			// The question is answered with a button, not a click beside it.
			.close_outside = false,
			.on_close_ctx = &choice_dismissed,
		}
	)
		.with_id(CHOICE_PANEL_ID);
}

<*
 Puts a question up, or replaces the one that is up.

 The message is copied, so a `tformat` result is a fine argument, and so is the
 panel's own `message.str_view()` coming back in.

 @param elem : `The ChoiceDialog's own element.`
 @param message : `What is being asked. Copied; the caller keeps ownership of the original.`
*>
fn void ChoiceDialog.ask(&self, Element* elem, String message)
{
	// Into the temp allocator first: appending a slice of this very buffer back
	// into it would be an overlapping copy.
	String wanted = message.tcopy();

	if (!self.message.data()) self.message.init(mem);
	self.message.clear();
	self.message.append(wanted);

	if (try Element* panel = elem.find_id(CHOICE_PANEL_ID))
	{
		Dialog* panelled = panel.widget_as(Dialog);
		if (panelled.open)
		{
			// Already up: the lines point into a buffer that has just changed.
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
 Whether a question is up.

 @param elem : `The ChoiceDialog's own element.`
*>
fn bool ChoiceDialog.asking(&self, Element* elem)
{
	if (try Element* panel = elem.find_id(CHOICE_PANEL_ID)) return panel.widget_as(Dialog).open;
	return self.open_when_built;
}

<*
 Takes the question down without running `on_dismiss` — what a button's own
 `on_click` calls once it has done its work.

 @param elem : `The ChoiceDialog's own element.`
*>
fn void ChoiceDialog.withdraw(&self, Element* elem)
{
	self.open_when_built = false;
	if (try Element* panel = elem.find_id(CHOICE_PANEL_ID))
	{
		self.withdrawing = true;
		panel.widget_as(Dialog).set_open(panel, false);
		self.withdrawing = false;
	}
}

// ---------------------------------------------------------------------------
// Internals.

<*
 The content: the question, then the buttons the node was declared with.

 They are the composite's slots, borrowed in here, so closing the panel cuts
 them loose rather than releasing them and the next question shows the same
 ones.

 @param ctx : `The ChoiceDialog's element.`
*>
fn Element* choice_body(Ui* ui, any ctx) @local
{
	Element* host      = anycast(ctx, Element)!!;
	ChoiceDialog* self = host.widget_as(ChoiceDialog);
	DialogStyle s      = self.style.resolved();
	float gap          = self.gap > 0 ? self.gap : CHOICE_GAP;

	// As wide as the question may run, which is what puts the buttons against
	// the right edge: a Row without a width is only as wide as they are.
	Element* answers = ui.@node((Row) { .size = { CONFIRM_TEXT_W, 0 }, .main_align = END, .gap = gap });
	foreach (slot : host.slots) answers.append(borrow_content(ui, slot));

	return ui.@node(
		(Column) { .size = { CONFIRM_TEXT_W, 0 }, .gap = gap },
		question_lines(ui, self.message.str_view(), s),
		answers
	);
}

// The panel went away by the × or ESC — every route but `withdraw`.
fn void choice_dismissed(Ui* ui, any ctx) @local
{
	Element* host      = anycast(ctx, Element)!!;
	ChoiceDialog* self = host.widget_as(ChoiceDialog);

	if (self.withdrawing) return;
	if (self.on_dismiss) self.on_dismiss(ui);
}
