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

 It has no sizing method at all — the worked example of the size-field
 convention: the `size` field is picked up by the node macros, a set component
 is pixels and a zero component fills the parent, per axis.
*>
struct Rectangle (Widget)
{
	Vec2 size; // per axis: 0 = fill the available space
	RectStyle style;
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
 Where an already-measured box sits inside a bigger one — the offset to hand
 `place_child` once the child's size is known.

 The margin is a gap from the edges the box is pushed against, so it applies to
 START and END and is ignored on a CENTER axis, where there is no edge to sit
 against. A child bigger than the space it is aligned in overflows the far edge
 rather than being clamped: aligning is not sizing, and silently pulling it back
 would hide a constraint bug rather than show it.

 @param outer : `The space to align within.`
 @param inner : `The size of the box being placed.`
 @param h : `Horizontal edge: START = left, END = right.`
 @param v : `Vertical edge: START = top, END = bottom.`
 @param margin : `Gap from the anchored edges; ignored per centered axis.`
 @return `The inner box's origin, relative to the outer box.`
*>
fn Vec2 align_in(Vec2 outer, Vec2 inner, CrossAlign h, CrossAlign v, Vec2 margin = { 0, 0 })
{
	Vec2 pos;
	switch (h)
	{
		case START: pos.x = margin.x;
		case CENTER: pos.x = (outer.x - inner.x) / 2;
		case END: pos.x = outer.x - inner.x - margin.x;
	}
	switch (v)
	{
		case START: pos.y = margin.y;
		case CENTER: pos.y = (outer.y - inner.y) / 2;
		case END: pos.y = outer.y - inner.y - margin.y;
	}
	return pos;
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

	// A fixed size is what the children are offered, not just what this widget
	// returns: a 400px-wide Column hands its children 400 as their max width,
	// whatever it was offered itself. That top-down cap is what lets a
	// fill-width child — a zero size field, a bare container — inherit the
	// column's width instead of the window's.
	//
	// A cap rather than `constraints.fill`: fill would raise a size smaller than
	// the incoming minimum back up to it, and what the children are offered has
	// to be what this Column was told to be, not what its parent would prefer.
	Vec2 avail = {
		self.size.x > 0 ? math::min(self.size.x, constraints.max.x) : constraints.max.x,
		self.size.y > 0 ? math::min(self.size.y, constraints.max.y) : constraints.max.y,
	};

	for (sz i = 0; i < count; i++)
	{
		float remaining = math::max(avail.y - content, 0.0f);
		Vec2 child_size = elem.layout_child(i, cui::loose({ avail.x, remaining }));
		content += child_size.y;
		if (i + 1 < count) content += self.gap;
		cross = math::max(cross, child_size.x);
	}

	Vec2 own = constraints.constrain({
		self.size.x > 0 ? self.size.x : cross,
		self.size.y > 0 ? self.size.y : content,
	});

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
		float x        = align_in(own, child.size, self.cross_align, CrossAlign.START).x;
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

	// Same top-down cap as Column: a fixed size is offered to the children, so
	// fill-height children inherit a fixed-height Row rather than the window.
	Vec2 avail = {
		self.size.x > 0 ? math::min(self.size.x, constraints.max.x) : constraints.max.x,
		self.size.y > 0 ? math::min(self.size.y, constraints.max.y) : constraints.max.y,
	};

	for (sz i = 0; i < count; i++)
	{
		float remaining = math::max(avail.x - content, 0.0f);
		Vec2 child_size = elem.layout_child(i, cui::loose({ remaining, avail.y }));
		content += child_size.x;
		if (i + 1 < count) content += self.gap;
		cross = math::max(cross, child_size.y);
	}

	Vec2 own = constraints.constrain({
		self.size.x > 0 ? self.size.x : content,
		self.size.y > 0 ? self.size.y : cross,
	});

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
		float y        = align_in(own, child.size, CrossAlign.START, self.cross_align).y;
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
	Vec2 pad = {
		self.insets.left + self.insets.right,
		self.insets.top + self.insets.bottom,
	};

	Vec2 child_size = { 0, 0 };
	if (elem.children.len() > 0)
	{
		child_size = elem.layout_child(0, constraints.deflate(pad));
		elem.place_child(0, { self.insets.left, self.insets.top });
	}
	return constraints.constrain(child_size + pad);
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
	Vec2 own = constraints.fill(self.size);
	elem.layout_children(cui::loose(own));
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
	return constraints.constrain(size);
}

// ---------------------------------------------------------------------------

<*
 Pins a single child to a corner, edge or center of whatever space this widget
 is offered, with a margin from the anchored edges. It fills that space itself
 (transparently — the pointer passes through to what is underneath, though the
 child stays interactive), so the child's position follows every relayout: an
 overlay anchored END/START sits at the top-right of its pane however the pane
 resizes, where a hand-set offset would have to be recomputed by hand.
*>
struct Anchored (Widget)
{
	CrossAlign h; // START = left, END = right
	CrossAlign v; // START = top, END = bottom
	Vec2 margin; // gap from the anchored edges; ignored per centered axis
}

// The whole point of the widget is that it fills a space it does not itself
// occupy: it covers its pane so the child can be positioned against the pane's
// edges, and the pointer has to reach whatever is painted underneath.
fn void Anchored.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

<*
 Fills the offered space and places the child against the chosen edges.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken: everything offered.`
*>
fn Vec2 Anchored.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = constraints.max;
	if (elem.children.len() > 0)
	{
		Vec2 child = elem.layout_child(0, cui::loose(own));
		elem.place_child(0, align_in(own, child, self.h, self.v, self.margin));
	}
	return own;
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

	Vec2 viewport = constraints.fill(self.size);

	Vec2 content = elem.layout_child(0, cui::loose({ viewport.x, cui::UNBOUNDED }));
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
	elem.layout_child(1, cui::tight(thumb_size));
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
 inside, and `on_hover` also asks for the hand. And of a widget with no
 `layout` at all: the `size` field sizes it and children fill it.
*>
struct Button (Widget)
{
	Vec2 size; // per axis: 0 = fill the available space
	RectStyle style;
	RectStyle hover_style; // used while hovered, if its color alpha > 0
	RectStyle press_style; // used while held, if its color alpha > 0
	OnClick on_click; // optional; called on click-release inside
	bool hovered;
	bool held;

	<*
	 Text drawn centred in the button, or empty for a bare rect.

	 Here rather than as a nested `Label` because centring one would take a
	 container of its own, and because a label inside a button is not decoration
	 sitting on top of it — it is what the button says, and the two are never
	 styled or sized apart. Borrowed, like every other string in a widget: it
	 must outlive the element.
	*>
	String label;
	TextStyle label_style;
}

<*
 Draws the rect in the style matching the current state: press, then hover, then
 the base style (a state style counts as set when its color alpha is above zero),
 and the label centred on top of it.

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

	if (self.label.len == 0) return;

	Vec2 text = elem.ui.text.measure(self.label_style.font, self.label, self.label_style.size);
	painter.text((elem.size - text) * 0.5f, self.label, self.label_style);
}

<*
 Sizes to the label plus its padding when the button has one and no explicit
 size, so a row of buttons is as wide as its words rather than as wide as the
 widest guess. A `size` component that was set wins, per axis — the size-field
 convention, unchanged.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
*>
fn Vec2 Button.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = self.size;
	if (self.label.len > 0)
	{
		Vec2 text = elem.ui.text.measure(self.label_style.font, self.label, self.label_style.size);
		if (own.x == 0.0f) own.x = text.x + BUTTON_LABEL_PAD.x * 2.0f;
		if (own.y == 0.0f) own.y = text.y + BUTTON_LABEL_PAD.y * 2.0f;
	}
	own = constraints.fill(own);

	// The same loose pass a widget with no `layout` of its own would have got, so
	// adding this method did not change what children do inside a Button.
	elem.layout_children(cui::loose(own));
	return own;
}

<*
 Space around a label that is sizing its own button: enough that the text is not
 touching the border at either edge, and the same on every button so a row of
 them lines up.
*>
const Vec2 BUTTON_LABEL_PAD = { 14.0, 7.0 };

<*
 Tracks hover state and repaints.

 @param elem : `The element this widget is attached to.`
 @param entered : `True when the pointer entered, false when it left.`
*>
fn void Button.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
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

// ---------------------------------------------------------------------------

<*
 A toggle callback, carrying the state the box is in **after** the click.

     `fn void rig_toggled(Ui* ui, bool on) { ui.inherit(App)!!.with_rig = on; }`
*>
alias OnToggle = fn void(Ui* ui, bool checked);

<*
 How a Checkbox is drawn.

 The MenuStyle convention: a zero `box` means "use DEFAULT_CHECKBOX_STYLE
 wholesale", and a partly filled style is not merged field by field.
*>
struct CheckboxStyle
{
	Color color; // the square, unticked
	Color hover_color; // ... under the pointer
	Color checked_color; // ... ticked
	Color mark; // the tick drawn inside it
	Color text_color;
	Vec4 border_radius;
	FontId font; // 0 = the first loaded font
	float text_size;
	float box; // side of the square; 0 = the whole style defaults
	float gap; // between the square and the label
	float thickness; // of the tick's two strokes
}

const CheckboxStyle DEFAULT_CHECKBOX_STYLE = {
	.color = { 0.20, 0.22, 0.28, 1.0 },
	.hover_color = { 0.28, 0.31, 0.40, 1.0 },
	.checked_color = { 0.95, 0.60, 0.20, 1.0 },
	.mark = { 0.05, 0.06, 0.09, 1.0 },
	.text_color = { 0.92, 0.93, 0.95, 1.0 },
	.border_radius = { 4.0, 4.0, 4.0, 4.0 },
	.text_size = 14.0,
	.box = 16.0,
	.gap = 8.0,
	.thickness = 2.0,
};

fn CheckboxStyle CheckboxStyle.resolved(self)
{
	return self.box > 0 ? self : DEFAULT_CHECKBOX_STYLE;
}

<*
 A tick box with its label beside it: the boolean sibling of Button.

     `@node((Checkbox) { .label = "Export rig", .checked = true, .on_change = &rig_toggled });`

 **The box flips itself and then says so.** `on_change` is told the new state
 rather than asked for it, and the widget has already repainted by the time the
 callback runs. That is what makes a tick respond to the click that made it,
 without the caller having to rebuild the subtree around it — cui has no
 mechanism that would do that on its own. A caller keeping the answer somewhere
 of its own passes it back in as `checked` the next time the panel is built, and
 that copy wins.

 **Only the box and the label are clickable**, not the width they were offered:
 the widget sizes itself to its own ink unless `size` says otherwise, so a tick
 in a wide Column does not turn the empty half of the row into a target.
*>
struct Checkbox (Widget)
{
	String label; // borrowed; must outlive the element, as every widget's string must
	bool checked;
	OnToggle on_change; // optional; called after the flip, with the new state
	CheckboxStyle style;
	Vec2 size; // per axis: 0 = wrap the box and the label
	bool hovered;
	bool held;
}

fn Vec2 Checkbox.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	CheckboxStyle s = self.style.resolved();

	Vec2 own = self.size;
	if (own.x == 0.0f || own.y == 0.0f)
	{
		Vec2 text = self.label.len > 0
			? elem.ui.text.measure(s.font, self.label, s.text_size)
			: (Vec2){ 0, 0 };
		if (own.x == 0.0f) own.x = s.box + (self.label.len > 0 ? s.gap + text.x : 0.0f);
		if (own.y == 0.0f) own.y = math::max(s.box, text.y);
	}
	return constraints.constrain(own);
}

fn void Checkbox.paint(&self, Element* elem, Painter* painter) @dynamic
{
	CheckboxStyle s = self.style.resolved();

	// Centred in whatever height the row ended up at, so a tick beside a taller
	// label does not sit on its baseline.
	float top = (elem.size.y - s.box) * 0.5f;

	Color fill = s.color;
	if (self.checked) { fill = s.checked_color; }
	else if (self.hovered) { fill = s.hover_color; }
	painter.rect({ 0, top }, { s.box, s.box }, { .color = fill, .border_radius = s.border_radius });

	if (self.checked)
	{
		// Two strokes rather than a glyph: a tick is the one mark a widget cannot
		// assume the loaded font has.
		painter.line({ s.box * 0.24f, top + s.box * 0.52f }, { s.box * 0.44f, top + s.box * 0.72f },
			s.thickness, s.mark);
		painter.line({ s.box * 0.44f, top + s.box * 0.72f }, { s.box * 0.78f, top + s.box * 0.26f },
			s.thickness, s.mark);
	}

	if (self.label.len == 0) return;
	Vec2 text = elem.ui.text.measure(s.font, self.label, s.text_size);
	painter.text({ s.box + s.gap, (elem.size.y - text.y) * 0.5f }, self.label, {
		.font = s.font,
		.size = s.text_size,
		.color = s.text_color,
	});
}

fn void Checkbox.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

<*
 Flips on a left press released inside, the way Button fires.

 @return `True for any left press or release: consuming the press captures the pointer, so a drag out and back still resolves.`
*>
fn bool Checkbox.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.held = true;
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.held) return false;
			self.held = false;

			bool inside = event.pos.x >= 0 && event.pos.y >= 0
				&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			if (!inside) return true;

			self.checked = !self.checked;
			elem.request_paint();
			if (self.on_change) self.on_change(elem.ui, self.checked);
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

 A label is **transparent to the pointer**: it is decoration, and its rect is
 usually much larger than the ink in it. Overlay one on a viewport or put one
 inside a Button and the clicks, hover and cursor go to what is underneath, as
 they would in Flutter. Wrap it in a Button (or any widget with `on_mouse`) to
 make text clickable.
*>
struct Label (Widget)
{
	String text; // borrowed; must outlive the element (a literal is ideal)
	FontId font; // from Ui.load_font; 0 = the first loaded font
	float size; // em size in px; 0 uses cui::DEFAULT_TEXT_SIZE
	Color color; // text color — the zero default is fully transparent
}

// Text is decoration, and decoration must not eat the clicks meant for what it
// labels: without this a caption over a viewport wins the hit test (deepest
// rect containing the point) and becomes a dead zone, because events bubble to
// parents and never to the sibling underneath.
fn void Label.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

<*
 Sizes the label to its measured text.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The measured text size, clamped to the constraints.`
*>
fn Vec2 Label.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain(elem.ui.text.measure(self.font, self.text, self.size));
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
