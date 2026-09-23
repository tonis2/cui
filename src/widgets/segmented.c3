<*
 Segmented: a strip of labelled choices drawn as one control, one lit.
 ToggleButton: the same look for a single on/off choice.

 A Select hides its options behind a click; a segmented control shows them all,
 which is what a handful of modes the user flips between wants. `selected` may
 be -1, for "none of these": a selection that mixes modes, or nothing to show.

 Both flip themselves and then report, the Checkbox way: the new state is drawn
 by the click that made it, and a caller keeping its own copy passes it back in
 on the next build.
*>
module cui::widgets;

import cui;
import std::math;

struct SegmentedStyle
{
	Color fill;
	Color hover;
	Color selected;
	Color border;
	Color text;
	Color selected_text;
	Vec4 border_radius;
	FontId font; // 0 = the first loaded font
	float text_size;
	float pad_x; // either side of each label
	float height; // 0 = the whole style defaults
}

const SegmentedStyle DEFAULT_SEGMENTED_STYLE = {
	.fill = { 0.20, 0.22, 0.28, 1.0 },
	.hover = { 0.28, 0.31, 0.40, 1.0 },
	.selected = { 0.95, 0.60, 0.20, 1.0 },
	.border = { 0.28, 0.30, 0.38, 1.0 },
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.selected_text = { 0.05, 0.06, 0.09, 1.0 },
	.border_radius = { 6.0, 6.0, 6.0, 6.0 },
	.text_size = 13.0,
	.pad_x = 10.0,
	.height = 28.0,
};

fn SegmentedStyle SegmentedStyle.resolved(self)
{
	return self.height > 0 ? self : DEFAULT_SEGMENTED_STYLE;
}

fn float SegmentedStyle.segment_width(self, Ui* ui, String label)
{
	return ui.text.measure(self.font, label, self.text_size).x + 2 * self.pad_x;
}

// One segment's box: its own fill, rounded only on the strip's outer corners.
fn void paint_segment(Painter* painter, Vec2 at, Vec2 size, Color color, SegmentedStyle s, bool first, bool last) @local
{
	Vec4 r = s.border_radius;
	painter.rect(
		at,
		size,
		{
			.color = color,
			.border_radius = { first ? r.x : 0, last ? r.y : 0, last ? r.z : 0, first ? r.w : 0 },
		}
	);
}

fn void paint_segment_label(
	Ui* ui,
	Painter* painter,
	Vec2 at,
	Vec2 size,
	String label,
	Color ink,
	SegmentedStyle s
) @local
{
	Vec2 text = ui.text.measure(s.font, label, s.text_size);
	painter.text(at + (size - text) * 0.5f, label, { .font = s.font, .size = s.text_size, .color = ink });
}

struct Segmented (Widget)
{
	String[] options; // borrowed; must outlive the element
	sz selected; // -1 = none lit
	OnSelect on_change; // optional; called after the flip, with the new index
	SegmentedStyle style;
	bool hovering;
	sz hovered;
	sz held;
	bool tracking; // a press is in flight on `held`
}

<*
 Which segment is under `x`, or -1.
*>
fn sz Segmented.index_at(&self, Element* elem, float x)
{
	SegmentedStyle s = self.style.resolved();
	float left       = 0;
	foreach (usz i, option : self.options)
	{
		float width = s.segment_width(elem.ui, option);
		if (x >= left && x < left + width) return (sz)i;
		left += width;
	}
	return -1;
}

fn Vec2 Segmented.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	SegmentedStyle s = self.style.resolved();
	float width      = 0;
	foreach (option : self.options) width += s.segment_width(elem.ui, option);
	return constraints.constrain({ width, s.height });
}

fn void Segmented.paint(&self, Element* elem, Painter* painter) @dynamic
{
	SegmentedStyle s = self.style.resolved();
	painter.rect({ 0, 0 }, elem.size, { .color = s.fill, .border_radius = s.border_radius });
	float left = 0;
	usz last   = self.options.len - 1;
	foreach (usz i, option : self.options)
	{
		float width = s.segment_width(elem.ui, option);
		Vec2 at     = { left, 0 };
		Vec2 size   = { width, elem.size.y };
		bool lit    = (sz)i == self.selected;
		if (lit)
		{
			paint_segment(painter, at, size, s.selected, s, i == 0, i == last);
		}
		else if (self.tracking ? (sz)i == self.held : self.hovering && (sz)i == self.hovered)
		{
			paint_segment(painter, at, size, s.hover, s, i == 0, i == last);
		}
		if (i > 0 && !lit && (sz)i - 1 != self.selected)
		{
			painter.line({ left, 5 }, { left, elem.size.y - 5 }, 1.0f, s.border);
		}
		paint_segment_label(elem.ui, painter, at, size, option, lit ? s.selected_text : s.text, s);
		left += width;
	}
	painter.rect(
		{ 0, 0 },
		elem.size,
		{
			.border_color = s.border,
			.border_width = 1.0f,
			.border_radius = s.border_radius,
		}
	);
}

fn void Segmented.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovering = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

fn bool Segmented.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case MOVE:
			sz over = self.index_at(elem, event.pos.x);
			if (!self.hovering || over != self.hovered)
			{
				self.hovering = true;
				self.hovered = over;
				elem.request_paint();
			}
			return false;
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.held = self.index_at(elem, event.pos.x);
			self.tracking = true;
			elem.request_paint();
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.tracking) return false;
			self.tracking = false;
			elem.request_paint();
			bool inside = event.pos.y >= 0 && event.pos.y < elem.size.y;
			sz chosen = inside ? self.index_at(elem, event.pos.x) : -1;
			if (chosen < 0 || chosen != self.held) return true;
			self.selected = chosen;
			if (self.on_change) self.on_change(elem.ui, (usz)chosen);
			return true;
		default:
			return false;
	}
}

struct ToggleButton (Widget)
{
	String label; // borrowed; must outlive the element
	bool on;
	OnToggle on_change; // optional; called after the flip, with the new state
	SegmentedStyle style;
	Vec2 size; // per axis: 0 = wrap the label
	bool hovered;
	bool held;
}

fn Vec2 ToggleButton.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	SegmentedStyle s = self.style.resolved();
	return constraints.constrain(
		{
			self.size.x > 0 ? self.size.x : s.segment_width(elem.ui, self.label),
			self.size.y > 0 ? self.size.y : s.height,
		}
	);
}

fn void ToggleButton.paint(&self, Element* elem, Painter* painter) @dynamic
{
	SegmentedStyle s = self.style.resolved();
	Color fill       = self.on ? s.selected : (self.hovered || self.held ? s.hover : s.fill);
	painter.rect(
		{ 0, 0 },
		elem.size,
		{
			.color = fill,
			.border_color = s.border,
			.border_width = self.on ? 0.0f : 1.0f,
			.border_radius = s.border_radius,
		}
	);
	paint_segment_label(elem.ui, painter, { 0, 0 }, elem.size, self.label, self.on ? s.selected_text : s.text, s);
}

fn void ToggleButton.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

fn bool ToggleButton.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.held = true;
			elem.request_paint();
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.held) return false;
			self.held = false;
			elem.request_paint();
			bool inside = event.pos.x >= 0 && event.pos.y >= 0 && event.pos.x < elem.size.x
				&& event.pos.y < elem.size.y;
			if (!inside) return true;
			self.on = !self.on;
			if (self.on_change) self.on_change(elem.ui, self.on);
			return true;
		default:
			return false;
	}
}