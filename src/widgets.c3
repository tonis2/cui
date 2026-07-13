<*
 Built-in widgets: leaves and layout containers implementing the Widget
 interface from module `cui`. Apps compose these or write their own widgets
 against the same interface — nothing here is special-cased by the core.

 Every widget is a plain struct: build one with a literal in a node macro, pass
 it by value (the element copies and owns it) or by pointer (borrowed, and
 mutable from a callback).
*>
module cui::widgets;
import std::collections::list;
import std::math;

import cui;

// ---------------------------------------------------------------------------

<*
 Leaf with a preferred size and an SDF rect style: fill, border and per-corner
 radii. The workhorse for cards, chips, bars and dividers.
*>
struct Rectangle (Widget)
{
	Vec2 size;
	RectStyle style;
}

<*
 Takes its preferred size, clamped to the constraints.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken.`
*>
fn Vec2 Rectangle.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return cui::clamp_size(self.size, constraints);
}

<*
 Draws the styled rect filling the element.

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter to draw into, in element-local coordinates.`
*>
fn void Rectangle.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.rect({ 0, 0 }, elem.size, self.style);
}

// ---------------------------------------------------------------------------
// Column / Row: stack children along one axis with a gap.

<*
 How a Column or Row distributes slack along its MAIN axis (vertical for a
 Column, horizontal for a Row).
*>
enum MainAlign
{
	START,
	CENTER,
	END,
	SPACE_BETWEEN, // slack becomes equal extra spacing between children
}

<*
 How a Column or Row aligns children across its CROSS axis (horizontal for a
 Column, vertical for a Row).
*>
enum CrossAlign
{
	START,
	CENTER,
	END,
}

<*
 Stacks children vertically with a gap between them.

 By default it wraps its content; a non-zero `size` fixes that axis, and the
 alignments distribute whatever slack the fixed size (or the incoming
 constraints) creates. A wrap-content Column has no slack, so alignment only
 shows when something forces it bigger than its children.
*>
struct Column (Widget)
{
	float gap;
	Vec2 size; // per axis: 0 = wrap content
	MainAlign main_align;
	CrossAlign cross_align;
}

<*
 Lays children out top to bottom, then aligns them in whatever slack is left.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken: content-sized per axis unless size fixes it.`
*>
fn Vec2 Column.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	sz count      = elem.children.len();
	float content = 0;
	float cross   = 0;

	for (sz i = 0; i < count; i++)
	{
		float remaining = math::max(constraints.max.y - content, 0.0f);
		Vec2 child_size = elem.layout_child(i, { .min = { 0, 0 }, .max = { constraints.max.x, remaining } });
		content += child_size.y;
		if (i + 1 < count) content += self.gap;
		cross = math::max(cross, child_size.x);
	}

	Vec2 own = cui::clamp_size(
		{ self.size.x > 0 ? self.size.x : cross, self.size.y > 0 ? self.size.y : content, },
		constraints
	);

	float leftover = math::max(own.y - content, 0.0f);
	float cursor   = 0;
	float step     = self.gap;
	switch (self.main_align)
	{
		case START: break;
		case CENTER: cursor = leftover / 2;
		case END: cursor = leftover;
		case SPACE_BETWEEN: if (count > 1) step += leftover / (float)(count - 1);
	}

	for (sz i = 0; i < count; i++)
	{
		Element* child = elem.children[i];
		float x        = 0;
		switch (self.cross_align)
		{
			case START: x = 0;
			case CENTER: x = (own.x - child.size.x) / 2;
			case END: x = own.x - child.size.x;
		}
		elem.place_child(i, { x, cursor });
		cursor += child.size.y + step;
	}
	return own;
}

<*
 Stacks children left to right with a gap between them — the horizontal twin of
 Column, with the same wrap-content and alignment rules.
*>
struct Row (Widget)
{
	float gap;
	Vec2 size; // per axis: 0 = wrap content
	MainAlign main_align;
	CrossAlign cross_align;
}

<*
 Lays children out left to right, then aligns them in whatever slack is left.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken: content-sized per axis unless size fixes it.`
*>
fn Vec2 Row.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	sz count      = elem.children.len();
	float content = 0;
	float cross   = 0;

	for (sz i = 0; i < count; i++)
	{
		float remaining = math::max(constraints.max.x - content, 0.0f);
		Vec2 child_size = elem.layout_child(i, { .min = { 0, 0 }, .max = { remaining, constraints.max.y } });
		content += child_size.x;
		if (i + 1 < count) content += self.gap;
		cross = math::max(cross, child_size.y);
	}

	Vec2 own = cui::clamp_size(
		{ self.size.x > 0 ? self.size.x : content, self.size.y > 0 ? self.size.y : cross, },
		constraints
	);

	float leftover = math::max(own.x - content, 0.0f);
	float cursor   = 0;
	float step     = self.gap;
	switch (self.main_align)
	{
		case START: break;
		case CENTER: cursor = leftover / 2;
		case END: cursor = leftover;
		case SPACE_BETWEEN: if (count > 1) step += leftover / (float)(count - 1);
	}

	for (sz i = 0; i < count; i++)
	{
		Element* child = elem.children[i];
		float y        = 0;
		switch (self.cross_align)
		{
			case START: y = 0;
			case CENTER: y = (own.y - child.size.y) / 2;
			case END: y = own.y - child.size.y;
		}
		elem.place_child(i, { cursor, y });
		cursor += child.size.x + step;
	}
	return own;
}

// ---------------------------------------------------------------------------

<*
 Per-edge insets in pixels.
*>
struct Insets
{
	float left;
	float top;
	float right;
	float bottom;
}

<*
 Insets with the same value on every edge.

 @param value : `The inset in pixels.`
 @return `The insets.`
*>
fn Insets insets_all(float value)
{
	return { value, value, value, value };
}

<*
 Insets around a single child; sizes itself to child + insets. Takes one child
 and ignores any others.
*>
struct Padding (Widget)
{
	Insets insets;
}

<*
 Shrinks the constraints by the insets, lays the child out inside them, and
 takes the size of the child plus the insets.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken: child + insets, clamped.`
*>
fn Vec2 Padding.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float w = self.insets.left + self.insets.right;
	float h = self.insets.top + self.insets.bottom;
	Constraints inner = {
		.min = { math::max(constraints.min.x - w, 0.0f), math::max(constraints.min.y - h, 0.0f) },
		.max = { math::max(constraints.max.x - w, 0.0f), math::max(constraints.max.y - h, 0.0f) },
	};

	Vec2 child_size = { 0, 0 };
	if (elem.children.len() > 0)
	{
		child_size = elem.layout_child(0, inner);
		elem.place_child(0, { self.insets.left, self.insets.top });
	}
	return cui::clamp_size({ child_size.x + w, child_size.y + h }, constraints);
}

// ---------------------------------------------------------------------------

<*
 Absolute container: children are positioned by `Element.set_offset` and sized by
 their own layout under loose constraints. The escape hatch from the
 constraint-driven containers — and the base for overlays, badges and anything
 animated by moving a handle.
*>
struct Stack (Widget)
{
	Vec2 size; // zero on an axis = fill the available space
}

<*
 Fills the available space (unless `size` fixes an axis) and lays every child out
 loosely; placement is left to whoever holds the child handles.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken.`
*>
fn Vec2 Stack.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = {
		self.size.x > 0 ? self.size.x : constraints.max.x,
		self.size.y > 0 ? self.size.y : constraints.max.y,
	};
	own = cui::clamp_size(own, constraints);

	for (sz i = 0; i < elem.children.len(); i++)
	{
		elem.layout_child(i, { .min = { 0, 0 }, .max = own });
	}
	return own;
}

// ---------------------------------------------------------------------------

<*
 Clips the subtree of its single child — including anything that subtree
 overflows — to its own bounds, optionally rounded. Sizes itself to the child.

 The clip is resolved per fragment in the shader, so rounded corners get the same
 antialiasing as shape edges. Hit testing is gated by the rect: a point in a
 clipped-away rounded corner still hits (corners are visual only, like
 transforms).
*>
struct Clip (Widget)
{
	Vec4 radii; // per-corner px {TL, TR, BR, BL}; zero = square
}

<*
 Marks the element as clipping, then sizes itself to its child.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size of the child, clamped; zero when there is no child.`
*>
fn Vec2 Clip.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.clips = true;
	elem.clip_radii = self.radii;

	Vec2 size = { 0, 0 };
	if (elem.children.len() > 0)
	{
		size = elem.layout_child(0, constraints);
		elem.place_child(0, { 0, 0 });
	}
	return cui::clamp_size(size, constraints);
}

// ---------------------------------------------------------------------------

<*
 Default scroll distance per wheel unit, in pixels — used when `Scroll.step` is
 zero.
*>
const float SCROLL_STEP_DEFAULT = 40.0;

<*
 Width of the scrollbar indicator pill, in pixels.
*>
const float THUMB_WIDTH = 6.0;

<*
 Gap between the indicator pill and the edges of the viewport, in pixels.
*>
const float THUMB_MARGIN = 2.0;

<*
 Shortest the indicator pill gets, however long the content — in pixels.
*>
const float THUMB_MIN = 24.0;

<*
 Indicator color used when `Scroll.thumb_color` is left at zero alpha.
*>
const Color THUMB_COLOR_DEFAULT = { 1.0, 1.0, 1.0, 0.35 };

<*
 A clipped viewport over one child laid out with unbounded height.

 Vertical only — the platform wheel reports a single vertical delta. Takes
 exactly ONE node child (the content); `children[1]` is an internal
 scrollbar-indicator overlay mounted on first layout, so do not append to a
 Scroll.

 Wheel events over the viewport move the content; at either end the event is left
 unconsumed, so an enclosing Scroll can take over.
*>
struct Scroll (Widget)
{
	Vec2 size; // per axis: 0 = fill the available space
	float scroll_offset; // px scrolled down, clamped to [0, content - viewport];
	// settable in the literal for an initial position
	float step; // px per wheel unit; 0 = SCROLL_STEP_DEFAULT
	Vec4 radii; // viewport corner radii (rounded clipping)
	Color thumb_color; // zero alpha = THUMB_COLOR_DEFAULT
	float content_extent; // content height, remembered by layout for on_mouse
}

<*
 The indicator: a pill at the right edge of the viewport, sized and placed by the
 owning Scroll. Non-interactive — it shows the scroll position, it does not take
 drags. Mounted internally by Scroll; apps never build one.
*>
struct ScrollThumb (Widget)
{
	Color color;
	bool visible;
}

<*
 Draws the pill, or nothing while the content fits.

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter to draw into, in element-local coordinates.`
*>
fn void ScrollThumb.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (!self.visible) return;
	float r = elem.size.x * 0.5f;
	painter.rect({ 0, 0 }, elem.size, { .color = self.color, .border_radius = { r, r, r, r } });
}

<*
 Sizes the viewport, lays the content out with unbounded height, clamps the
 scroll offset to the overflow, and sizes and places the thumb. Mounts the thumb
 on the first run.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() >= 1 : `A Scroll takes exactly one node child: the content to scroll.`
 @return `The size of the viewport.`
*>
fn Vec2 Scroll.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	// Mount the thumb overlay once, AFTER the content child so it emits (and
	// paints) on top. Deliberately not Ui.mount / Element.append: those call
	// request_layout, which from inside the layout pass would re-dirty this
	// element after layout_element cleared it. Pushed directly and laid out
	// below in this same call instead.
	if (elem.children.len() == 1)
	{
		Color color    = ((Vec4)self.thumb_color).w > 0 ? self.thumb_color : THUMB_COLOR_DEFAULT;
		Element* thumb = elem.ui.@node((ScrollThumb) { .color = color });
		thumb.parent = elem;
		elem.children.push(thumb);
	}

	Vec2 viewport = {
		self.size.x > 0 ? self.size.x : constraints.max.x,
		self.size.y > 0 ? self.size.y : constraints.max.y,
	};
	viewport = cui::clamp_size(viewport, constraints);

	Vec2 content = elem.layout_child(0, { .min = { 0, 0 }, .max = { viewport.x, cui::UNBOUNDED } });
	self.content_extent = content.y;

	float max_scroll = math::max(content.y - viewport.y, 0.0f);
	self.scroll_offset = math::clamp(self.scroll_offset, 0.0f, max_scroll);
	elem.place_child(0, { 0, -self.scroll_offset });

	elem.clips = true;
	elem.clip_radii = self.radii;

	// Thumb: proportional length, shown only on overflow.
	ScrollThumb* thumb = elem.children[1].widget_as(ScrollThumb);
	bool show          = max_scroll > 0;
	if (thumb.visible != show)
	{
		thumb.visible = show;
		elem.children[1].request_paint(); // safe: the paint pass runs after layout
	}
	float track     = math::max(viewport.y - 2 * THUMB_MARGIN, 0.0f);
	float len       = show ? math::clamp(track * (viewport.y / content.y), THUMB_MIN, track) : 0;
	Vec2 thumb_size = { show ? THUMB_WIDTH : 0, len };
	elem.layout_child(1, { .min = thumb_size, .max = thumb_size });
	self.place_thumb(elem, viewport, max_scroll);
	return viewport;
}

<*
 Positions the thumb from `scroll_offset`; shared by layout and the wheel handler
 (which rides the same cheap re-emit as the content set_offset).

 @param elem : `The Scroll element.`
 @param viewport : `The size of the viewport, in pixels.`
 @param max_scroll : `The overflow: content height minus viewport height.`
 @require elem.children.len() == 2 : `The thumb is mounted by Scroll.layout, which must run first.`
*>
fn void Scroll.place_thumb(&self, Element* elem, Vec2 viewport, float max_scroll)
{
	Element* thumb = elem.children[1];
	float track    = math::max(viewport.y - 2 * THUMB_MARGIN, 0.0f);
	float travel   = math::max(track - thumb.size.y, 0.0f);
	float y        = THUMB_MARGIN + (max_scroll > 0 ? travel * (self.scroll_offset / max_scroll) : 0);
	thumb.offset = { viewport.x - THUMB_WIDTH - THUMB_MARGIN, y };
}

<*
 Moves the content on wheel events. At either end the event is left unconsumed,
 so an enclosing Scroll can pick it up.

 @param elem : `The element this widget is attached to.`
 @param event : `The mouse event; only SCROLL is handled.`
 @return `True when the wheel actually moved this Scroll.`
*>
fn bool Scroll.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != MouseEventKind.SCROLL) return false;
	float max_scroll = math::max(self.content_extent - elem.size.y, 0.0f);
	if (max_scroll <= 0) return false;

	// Wheel up (positive) moves the content down: offset shrinks.
	float step   = self.step > 0 ? self.step : SCROLL_STEP_DEFAULT;
	float target = math::clamp(self.scroll_offset - event.scroll * step, 0.0f, max_scroll);
	if (target == self.scroll_offset) return false; // at a limit: let ancestors scroll

	self.scroll_offset = target;
	elem.children[0].set_offset({ 0, -target }); // offset write + re-emit, no relayout
	self.place_thumb(elem, elem.size, max_scroll);
	return true;
}

// ---------------------------------------------------------------------------

<*
 A click callback. It receives the Ui the button is rendered in — the framework
 passes the ui of the button element automatically, so the callback carries no
 app-threaded context yet can still reach the rest of the tree, the way a Flutter
 callback reaches other widgets through its BuildContext:

     `fn void reset_clicked(Ui* ui) {`
     `    ui.@modify(Dial; d) { d.value = 0; };   // resolve once, mutate, repaint`
     `}`
*>
alias OnClick = fn void(Ui* ui);

<*
 A clickable rect with hover and press styles.

 Also the worked example of the Widget event callbacks: `on_hover` / `on_mouse`
 mutate state and `request_paint`; `on_click` fires when a left press is released
 inside.
*>
struct Button (Widget)
{
	Vec2 size;
	RectStyle style;
	RectStyle hover_style; // used while hovered, if its color alpha > 0
	RectStyle press_style; // used while held, if its color alpha > 0
	OnClick on_click; // optional; called on click-release inside
	bool hovered;
	bool held;
}

<*
 Takes its preferred size and asks for the hand cursor while hovered.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken.`
*>
fn Vec2 Button.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = Cursor.POINTING_HAND;
	return self.size.constrain(constraints);
}

<*
 Draws the rect in the style matching the current state: press, then hover, then
 the base style (a state style counts as set when its color alpha is above zero).

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter to draw into, in element-local coordinates.`
*>
fn void Button.paint(&self, Element* elem, Painter* painter) @dynamic
{
	RectStyle style = self.style;
	if (self.held && ((Vec4)self.press_style.color).w > 0)
	{
		style = self.press_style;
	}
	else if (self.hovered && ((Vec4)self.hover_style.color).w > 0)
	{
		style = self.hover_style;
	}
	painter.rect({ 0, 0 }, elem.size, style);
}

<*
 Tracks hover state and repaints.

 @param elem : `The element this widget is attached to.`
 @param entered : `True when the pointer entered, false when it left.`
*>
fn void Button.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	elem.request_paint();
}

<*
 Tracks the held state and fires `on_click` when a left press is released inside
 the button. Consuming the press captures the pointer, so a drag out and back
 still resolves correctly.

 @param elem : `The element this widget is attached to.`
 @param event : `The mouse event.`
 @return `True when the event was consumed (any left press or release).`
*>
fn bool Button.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.held = true;
			elem.request_paint();
			return true; // consuming the press captures the pointer
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.held) return false;
			self.held = false;
			elem.request_paint();
			bool inside = event.pos.x >= 0 && event.pos.y >= 0 && event.pos.x < elem.size.x
				&& event.pos.y < elem.size.y;
			if (inside && self.on_click) self.on_click(elem.ui);
			return true;
		default:
			return false;
	}
}

<*
 A single line of SDF text, sized by its font metrics: width = the kerned
 advance of the string, height = ascent - descent. Load a font first with
 `Ui.load_font`; see `cui::TextStyle` for the field semantics.

     ui.@node((Label){ .text = "Hello", .size = 20, .color = { 1, 1, 1, 1 } })
*>
struct Label (Widget)
{
	String text; // borrowed; must outlive the element (a literal is ideal)
	FontId font; // from Ui.load_font; 0 = the first loaded font
	float size; // em size in px; 0 uses cui::DEFAULT_TEXT_SIZE
	Color color; // text color — the zero default is fully transparent
}

<*
 Sizes the label to its measured text, clamped into the constraints.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The constraints to fit into.`
 @return `The measured text size, clamped.`
*>
fn Vec2 Label.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return cui::clamp_size(elem.ui.text.measure(self.font, self.text, self.size), constraints);
}

<*
 Paints the line at the element origin.

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter collecting this element's drawings.`
*>
fn void Label.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.text({ 0, 0 }, self.text, { .font = self.font, .size = self.size, .color = self.color });
}
