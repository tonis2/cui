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

// Between the buttons, and above them, when the node leaves `gap` at zero.
const float CHOICE_GAP = 10.0;

<*
 The panel. Everything but the message is configured where the node is
 declared; the message arrives with the question.
*>
struct ChoiceDialog (Widget)
{
	inline Question question; // the message, set by `ask`
	String title; // borrowed; must outlive the widget
	DialogStyle style;
	float gap; // between the buttons, and above them; 0 = CHOICE_GAP
	OnClick on_dismiss; // the × or ESC; not run by `withdraw`. May be null.
}

fn void ChoiceDialog.unmount(&self, Element* elem) @dynamic => self.question.free();

fn Element* ChoiceDialog.build(&self, Element* elem) @dynamic
{
	return self.question.panel(elem, self.title, self.style, &choice_body, &choice_dismissed);
}

<*
 The content: the question, then the buttons the node was declared with. They
 are the composite's slots, borrowed in, so the next question shows the same
 ones.
*>
fn Element* choice_body(Ui* ui, any ctx) @local
{
	Element* host      = anycast(ctx, Element)!!;
	ChoiceDialog* self = host.widget_as(ChoiceDialog);
	float gap          = self.gap > 0 ? self.gap : CHOICE_GAP;
	Element* answers   = ui.@node((Row) { .size = { CONFIRM_TEXT_W, 0 }, .main_align = END, .gap = gap });
	foreach (slot : host.slots) answers.append(borrow_content(ui, slot));
	return self.question.content(ui, self.style.resolved(), gap, answers);
}

// The panel went away by the × or ESC — every route but `withdraw`.
fn void choice_dismissed(Ui* ui, any ctx) @local
{
	ChoiceDialog* self = anycast(ctx, Element)!!.widget_as(ChoiceDialog);
	if (!self.withdrawing && self.on_dismiss) self.on_dismiss(ui);
}
