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

<*
 The panel. Everything but the message and the two callbacks is configured
 where the node is declared; those arrive with the question.
*>
struct ConfirmDialog (Widget)
{
	inline Question question; // the message, set by `ask`
	String title; // borrowed; must outlive the widget
	String confirm_label; // empty = "OK"
	String decline_label; // empty = "Cancel"
	DialogStyle style;
	ConfirmButtonStyle buttons;

	// --- set by `ask` ---
	OnClick on_confirm;
	OnClick on_decline;
}

fn String ConfirmDialog.confirm_text(&self) => self.confirm_label.len > 0 ? self.confirm_label : "OK";
fn String ConfirmDialog.decline_text(&self) => self.decline_label.len > 0 ? self.decline_label : "Cancel";

fn void ConfirmDialog.unmount(&self, Element* elem) @dynamic => self.question.free();

fn Element* ConfirmDialog.build(&self, Element* elem) @dynamic
{
	return self.question.panel(elem, self.title, self.style, &confirm_body, &confirm_dismissed);
}

<*
 Puts a question up; asking again while one is up replaces it.

 `ask.ask(elem, "Replace the rig?", &replace, &keep);`

 @param elem : `The ConfirmDialog's own element.`
 @param message : `What is being asked. Copied; may be this panel's own message.`
 @param confirm : `Run when the confirming button is pressed.`
 @param decline : `Run on every other way out — Cancel, the close button, ESC. May be null.`
*>
fn void ConfirmDialog.ask(&self, Element* elem, String message, OnClick confirm, OnClick decline = null)
{
	self.on_confirm = confirm;
	self.on_decline = decline;
	self.question.ask(elem, message);
}

// ---------------------------------------------------------------------------
// Internals.

// One answer as a Button, sized to its label plus the style's padding.
fn Button confirm_button(Ui* ui, String label, bool accent, ConfirmButtonStyle b, FontId font) @local
{
	Vec4 radii = { b.radius, b.radius, b.radius, b.radius };
	float w = ui.text.measure(font, label, b.text_size).x + 2 * b.pad_x;
	return {
		.size = { w, b.height },
		.label = label,
		.label_style = { .font = font, .size = b.text_size, .color = accent ? b.accent_text : b.text },
		.style = { .color = accent ? b.accent : b.fill, .border_radius = radii },
		.hover_style = { .color = accent ? b.accent : b.hover, .border_radius = radii },
		.press_style = { .color = b.press, .border_radius = radii },
		.on_press = accent ? &confirm_pressed : &decline_pressed,
	};
}

// The question, then Cancel and OK — the answer that acts last, where the
// pointer ends up.
fn Element* confirm_body(Ui* ui, any ctx) @local
{
	Element* host        = anycast(ctx, Element)!!;
	ConfirmDialog* self  = host.widget_as(ConfirmDialog);
	DialogStyle s        = self.style.resolved();
	ConfirmButtonStyle b = self.buttons.resolved();
	return self.question.content(ui, s, b.gap, ui.@node(
		(Row) { .size = { CONFIRM_TEXT_W, 0 }, .main_align = END, .gap = b.gap },
		ui.@node(confirm_button(ui, self.decline_text(), false, b, s.font)),
		ui.@node(confirm_button(ui, self.confirm_text(), true, b, s.font))
	));
}

<*
 Closes the panel and runs the answer given. Closed first, so a callback that
 asks a second question is not undone by this one's close.
*>
fn void confirm_answer(Element* button, bool confirmed) @local
{
	Element* host = button.ancestor(ConfirmDialog);
	if (!host) return;
	ConfirmDialog* self = host.widget_as(ConfirmDialog);
	OnClick chosen = confirmed ? self.on_confirm : self.on_decline;
	self.question.withdraw(host);
	if (chosen) chosen(button.ui);
}

fn void confirm_pressed(Element* button) @local => confirm_answer(button, true);
fn void decline_pressed(Element* button) @local => confirm_answer(button, false);

// Every other way out — the × and ESC — means "no".
fn void confirm_dismissed(Ui* ui, any ctx) @local
{
	ConfirmDialog* self = anycast(ctx, Element)!!.widget_as(ConfirmDialog);
	if (!self.withdrawing && self.on_decline) self.on_decline(ui);
}
