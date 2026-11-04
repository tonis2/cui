<*
 IconStrip: a row of icon cells drawn as one control, each with its own state,
 click and tooltip.

 A Segmented keeps one choice of its own. These cells keep nothing: each asks
 `state` every frame, the same query a menu item asks, so a key or a menu that
 changes the thing lights the cell without telling it. A press acts at once.

 The cells are borrowed, often a global. Wrap the strip in
 `tip_probe(&icon_strip_tip)` for a tooltip per cell.
*>
module cui::widgets;

import cui;
import std::math;

const usz ICON_STRIP_CELLS = 8;

struct IconStripStyle
{
	Color fill;
	Color hover;
	Color lit;
	Color ink;
	Color lit_ink;
	Color disabled_ink;
	Vec4 border_radius;
	Vec4 cell_radius;
	float inset; // between a cell's edge and its highlight
	Vec2 cell; // 0 = the whole style defaults
}

const IconStripStyle DEFAULT_ICON_STRIP_STYLE = {
	.fill = { 0.20, 0.22, 0.28, 1.0 },
	.hover = { 0.28, 0.31, 0.40, 1.0 },
	.lit = { 0.95, 0.60, 0.20, 1.0 },
	.ink = { 0.92, 0.93, 0.95, 1.0 },
	.lit_ink = { 0.05, 0.06, 0.09, 1.0 },
	.disabled_ink = { 0.30, 0.32, 0.36, 1.0 },
	.border_radius = { 6.0, 6.0, 6.0, 6.0 },
	.cell_radius = { 5.0, 5.0, 5.0, 5.0 },
	.inset = 2.0,
	.cell = { 28.0, 22.0 },
};

fn IconStripStyle IconStripStyle.resolved(self)
{
	return self.cell.x > 0 ? self : DEFAULT_ICON_STRIP_STYLE;
}

<*
 Draws one cell's icon.

 @param cell : "Which cell"
 @param centre : "The cell's middle, in element-local pixels"
 @param ink : "The icon's colour: lit and disabled are already applied"
 @param ground : "The strip's colour behind the icon, lit or plain"
*>
alias IconStripPaint = fn void(Painter* painter, usz cell, Vec2 centre, Color ink, Color ground);

struct IconStripCell
{
	MenuQuery state;
	OnClick on_select;
	String tip; // borrowed; a literal, or a string that outlives the element
}

struct IconStrip (Widget)
{
	IconStripCell[] cells; // borrowed; at most ICON_STRIP_CELLS
	IconStripPaint paint_icon;
	OnClick on_press; // optional; any left press on the strip, before the cell acts
	IconStripStyle style;

	int lit; // the hovered cell + 1; zero is none
	MenuItemFlags[ICON_STRIP_CELLS] shown; // what the last repaint drew
}

<*
 @require self.cells.len <= ICON_STRIP_CELLS : "Too many cells"
*>
fn Vec2 IconStrip.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 cell = self.style.resolved().cell;
	return constraints.constrain({ cell.x * (float)self.cells.len, cell.y });
}

fn void IconStrip.update(&self, Element* elem, float dt) @dynamic
{
	bool changed = false;
	foreach (usz i, cell : self.cells)
	{
		MenuItemFlags now = cell.state(elem.ui);
		if (now.checked != self.shown[i].checked || now.disabled != self.shown[i].disabled)
		{
			self.shown[i] = now;
			changed = true;
		}
	}
	if (changed) elem.request_paint();
}

fn void IconStrip.paint(&self, Element* elem, Painter* painter) @dynamic
{
	IconStripStyle s = self.style.resolved();
	painter.rect({ 0, 0 }, elem.size, { .color = s.fill, .border_radius = s.border_radius });

	foreach (usz i, cell : self.cells)
	{
		MenuItemFlags flags = self.shown[i];
		float x = s.cell.x * (float)i;
		bool hovered = self.lit == (int)i + 1 && !flags.disabled;
		if (flags.checked || hovered)
		{
			painter.rect(
				{ x + s.inset, s.inset },
				s.cell - s.inset * 2.0f,
				{
					.color = flags.checked ? s.lit : s.hover,
					.border_radius = s.cell_radius,
				}
			);
		}
		Color ink = flags.checked ? s.lit_ink : (flags.disabled ? s.disabled_ink : s.ink);
		self.paint_icon(painter, i, { x + s.cell.x * 0.5f, s.cell.y * 0.5f }, ink, flags.checked ? s.lit : s.fill);
	}
}

<*
 Which cell is under a point in element-local pixels, or -1.
*>
fn sz IconStrip.cell_at(&self, Vec2 pixel)
{
	Vec2 cell = self.style.resolved().cell;
	if (pixel.x < 0 || pixel.y < 0 || pixel.y >= cell.y) return -1;
	usz index = (usz)(pixel.x / cell.x);
	return index < self.cells.len ? (sz)index : -1;
}

fn bool IconStrip.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	sz over = self.cell_at(event.pos);
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			if (self.on_press) self.on_press(elem.ui);
			// A disabled cell still takes the press: it is a control on a bar, and
			// letting it through would be a click on the bar.
			if (over >= 0 && !self.shown[over].disabled)
			{
				self.cells[over].on_select(elem.ui);
				elem.request_paint();
			}
			return true;
		case MOVE:
			int was = self.lit;
			self.lit = (int)over + 1;
			if (self.lit != was) elem.request_paint();
			return true;
		default:
			return false;
	}
}

fn void IconStrip.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	// Leaving sends no MOVE, so the last cell would stay lit.
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

<*
 The tooltip of the cell under the pointer, for `tip_probe` around a strip.
*>
fn String icon_strip_tip(Element* holder, Vec2 pos)
{
	Element* strip = holder.children[0];
	IconStrip* self = strip.widget_as(IconStrip);
	sz over = self.cell_at(pos - strip.absolute);
	return over >= 0 ? self.cells[over].tip : "";
}
