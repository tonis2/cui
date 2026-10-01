<*
 Hover tooltips: a line of what a control does, beside the pointer after it has
 rested on the control for a moment.

 Two parts:

 - `Tooltip` wraps the control that wants one. It lays out as its child and draws
   nothing; the text is its only state. Attaching one is a tree around the
   control, `widgets::tip("Rotate (R) - turn the selected joint")` as its widget.

 - `TooltipHost` is mounted once, last in the root. Each frame it asks the Ui
   which element the pointer is over, climbs to the nearest `Tooltip`, and counts
   how long the pointer has stayed there. After the style's `delay` it shows the
   text; a press, a scroll or moving to another control hides it again.

 Read from the wrapper rather than the control so the control's own widget stays
 untouched — a Button, a Segmented and a hand-painted toggle are all the same to
 it. The text is borrowed: a literal, or a string that outlives the build that
 named it. Text longer than the style's `max_width` wraps onto more lines.

 **A control with parts** (one widget, several painted cells) passes a `probe`
 instead, which is asked for the text at the pointer each frame.

 **A hint**: a wrapper may also carry a second, longer line meant for a status
 bar. The host keeps the hovered control's hint; `tooltip_hint` reads it, and
 it is empty with the pointer anywhere else.
*>
module cui::widgets;

import cui;
import std::math;

<*
 The text for the part of the control under the pointer.

 @param tip : `The wrapper's element; its first child is the control.`
 @param pos : `The pointer, in window coordinates.`
 @return `The text, or an empty string for no tooltip here.`
*>
alias TooltipProbe = fn String(Element* tip, Vec2 pos);

struct Tooltip (Widget)
{
	String text;
	// For a status bar while the pointer is on this control; see `tooltip_hint`.
	String hint;
	TooltipProbe probe;
}

<*
 A tooltip for the control built inside it.

 @param text : `What the tooltip says.`
 @param hint : `Optional longer line for a status bar while the pointer is over the control.`
*>
fn Tooltip tip(String text, String hint = "") => { .text = text, .hint = hint };

<*
 A tooltip whose text depends on where on the control the pointer is.
*>
fn Tooltip tip_probe(TooltipProbe probe) => { .probe = probe };

// The wrapper is its child's size and nothing else, so putting one around a
// control cannot move it.
fn Vec2 Tooltip.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	Vec2 child = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return child;
}

<*
 The text a wrapper has for a pointer at `pos`.

 @param elem : `The wrapper's element.`
 @param pos : `The pointer, in window coordinates.`
*>
fn String Tooltip.text_at(&self, Element* elem, Vec2 pos)
{
	if (self.probe) return self.probe(elem, pos);
	return self.text;
}

<*
 The nearest wrapper above `from` (itself included), or null.
*>
fn Element* tooltip_above(Element* from)
{
	for (Element* e = from; e; e = e.parent)
	{
		if (e.is_widget(Tooltip)) return e;
	}
	return null;
}

<*
 How a tooltip looks and when it comes up.

 The CheckboxStyle convention: a zero `delay` means "use DEFAULT_TOOLTIP_STYLE
 wholesale", and a partly filled style is not merged field by field.
*>
struct TooltipStyle
{
	TextStyle text;
	RectStyle box;
	Color shadow;
	float shadow_blur;
	Vec2 pad; // between the box's edge and the text
	Vec2 offset; // from the pointer to the box's corner, clear of the cursor
	float max_width; // of the text; longer text wraps
	float delay; // seconds the pointer rests before the text shows
	float still; // px the pointer must travel before a dismissed tooltip may return
}

const TooltipStyle DEFAULT_TOOLTIP_STYLE = {
	.text = { .size = 12.0, .color = { 0.92, 0.93, 0.95, 1.0 } },
	.box = {
		.color = { 0.13, 0.14, 0.17, 1.0 },
		.border_color = { 0.28, 0.30, 0.36, 1.0 },
		.border_width = 1.0,
		.border_radius = { 6.0, 6.0, 6.0, 6.0 },
	},
	.shadow = { 0, 0, 0, 0.35 },
	.shadow_blur = 8.0,
	.pad = { 8.0, 5.0 },
	.offset = { 14.0, 20.0 },
	.max_width = 380.0,
	.delay = 0.5,
	.still = 3.0,
};

fn TooltipStyle TooltipStyle.resolved(self)
{
	return self.delay > 0 ? self : DEFAULT_TOOLTIP_STYLE;
}

<*
 Shows the hovered `Tooltip`'s text. Mount one, last in the root, so it paints
 above every pane.
*>
struct TooltipHost (Widget)
{
	TooltipStyle style;
	// The wrapper the pointer is on, and how long it has been there.
	Element* target;
	String pending;
	String hint;
	float held;
	// Showing, and where the pointer was when it came up.
	bool visible;
	String shown;
	Vec2 at;
	// A press or scroll hid it; it stays hidden until the pointer moves on.
	bool dismissed;
	Vec2 dismissed_at;
}

fn void TooltipHost.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

// Covers the window so the label can be placed anywhere in it, and above every
// pane so it is never under one.
fn Vec2 TooltipHost.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.raised = true;
	return constraints.max;
}

fn void TooltipHost.update(&self, Element* elem, float dt) @dynamic
{
	Ui* ui = elem.ui;
	TooltipStyle style = self.style.resolved();
	Vec2 mouse = ui.input.mouse;

	Element* found = ui.hovered ? tooltip_above(ui.hovered) : null;
	String text = "";
	self.hint = "";
	if (found)
	{
		Tooltip* tip = found.widget_as(Tooltip);
		text = tip.text_at(found, mouse);
		self.hint = tip.hint;
	}

	// Moving to another control, or to another part of this one, starts over.
	if (found != self.target || text != self.pending)
	{
		self.target = found;
		self.pending = text;
		self.held = 0;
		// A click often rebuilds the very control it landed on, so the element
		// changes under a pointer that has not; only moving on brings it back.
		if (self.dismissed && (mouse - self.dismissed_at).length() > style.still) self.dismissed = false;
		self.hide(elem);
	}

	bool clicked = ui.input.pressed[0] || ui.input.pressed[1] || ui.input.pressed[2];
	if (clicked || ui.input.scroll != 0 || ui.input.scroll_x != 0)
	{
		self.dismissed = true;
		self.dismissed_at = mouse;
		self.hide(elem);
	}

	if (self.visible || self.dismissed || text.len == 0) return;

	self.held += dt;
	if (self.held < style.delay)
	{
		// The loop sleeps when nothing is animating; the countdown is an
		// animation, so it has to ask for the frame that ends it.
		ui.request_frame();
		return;
	}
	self.visible = true;
	self.shown = text;
	self.at = mouse;
	elem.request_paint();
}

fn void TooltipHost.hide(&self, Element* elem)
{
	if (!self.visible) return;
	self.visible = false;
	self.shown = "";
	elem.request_paint();
}

fn void TooltipHost.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (!self.visible || self.shown.len == 0) return;
	TooltipStyle style = self.style.resolved();

	// Wrapped to the style's width, or to the window's when that is narrower.
	float room = math::min(style.max_width, elem.size.x - style.pad.x * 2.0f - 4.0f);
	Vec2 text = elem.ui.text.measure_box(style.text.font, self.shown, style.text.size, room, TextOverflow.WRAP);
	Vec2 size = text + style.pad * 2.0f;

	// Below and right of the pointer; flipped to the other side of it when that
	// would run off the window.
	Vec2 pointer = self.at - elem.absolute;
	Vec2 pos = pointer + style.offset;
	if (pos.x + size.x > elem.size.x) pos.x = pointer.x - size.x - 4.0f;
	if (pos.y + size.y > elem.size.y) pos.y = pointer.y - size.y - 8.0f;
	pos.x = math::max(pos.x, 2.0f);
	pos.y = math::max(pos.y, 2.0f);

	painter.rect_shadow(pos, size, style.shadow_blur, style.shadow, style.box.border_radius);
	painter.rect(pos, size, style.box);
	painter.text_box(pos + style.pad, self.shown, style.text, room, TextOverflow.WRAP);
}

<*
 What the tooltip host is showing right now, or the empty string.
*>
fn String tooltip_shown(Ui* ui)
{
	if (try Element* host = ui.find(TooltipHost)) return host.widget_as(TooltipHost).shown;
	return "";
}

<*
 The hint of the control under the pointer, or the empty string. Written by the
 host every frame, so it is never stale past one frame.
*>
fn String tooltip_hint(Ui* ui)
{
	if (try Element* host = ui.find(TooltipHost)) return host.widget_as(TooltipHost).hint;
	return "";
}
