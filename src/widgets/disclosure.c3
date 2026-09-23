<*
 A titled panel whose body can be independently expanded and collapsed.

 Disclosure is intended for inspector sidebars and settings stacks. The whole
 header is the toggle target, while the single child is ordinary application
 content. A collapsed child is laid out at zero and clipped, keeping it mounted
 without leaving stale geometry on screen.
*>
module cui::widgets;

import cui;
import std::math;

alias OnDisclosureChange = fn void(Ui* ui, bool expanded);

struct DisclosureStyle
{
	Color background;
	Color header;
	Color header_hover;
	Color border;
	Color text;
	Color mark;
	Vec4 radius;
	float header_height;
	float text_size;
	float padding;
	float gap;
	float border_width;
}

const DisclosureStyle DEFAULT_DISCLOSURE_STYLE = {
	.background = { 0.12, 0.13, 0.16, 1.0 },
	.header = { 0.18, 0.19, 0.23, 1.0 },
	.header_hover = { 0.23, 0.24, 0.30, 1.0 },
	.border = { 0.30, 0.31, 0.36, 1.0 },
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.mark = { 0.72, 0.74, 0.79, 1.0 },
	.radius = { 6.0, 6.0, 6.0, 6.0 },
	.header_height = 32.0,
	.text_size = 14.0,
	.padding = 10.0,
	.gap = 8.0,
	.border_width = 1.0,
};

fn DisclosureStyle DisclosureStyle.resolved(self)
{
	return self.header_height > 0 ? self : DEFAULT_DISCLOSURE_STYLE;
}

struct Disclosure (Widget)
{
	String label;
	bool expanded;
	float width;
	DisclosureStyle style;
	OnDisclosureChange on_change;
	bool header_hovered;
	bool held;
}

fn Vec2 Disclosure.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	DisclosureStyle style = self.style.resolved();
	float width           = self.width > 0 ? self.width : constraints.max.x;
	width = math::clamp(width, constraints.min.x, constraints.max.x);
	float inner_width = math::max(width - style.padding * 2.0f, 0.0f);
	float height      = style.header_height;

	if (elem.children.len() > 0)
	{
		if (self.expanded)
		{
			Vec2 child = elem.layout_child(0, cui::loose({ inner_width, cui::UNBOUNDED }));
			elem.place_child(0, { style.padding, style.header_height + style.gap });
			height += style.gap + child.y + style.padding;
		}
		else
		{
			elem.layout_child(0, cui::tight({ 0, 0 }));
			elem.place_child(0, { style.padding, style.header_height });
		}
	}

	elem.clips = true;
	elem.clip_radii = style.radius;
	return constraints.constrain({ width, height });
}

fn void Disclosure.paint(&self, Element* elem, Painter* painter) @dynamic
{
	DisclosureStyle style = self.style.resolved();
	painter.rect(
		{ 0, 0 },
		elem.size,
		{
			.color = style.background,
			.border_color = style.border,
			.border_width = style.border_width,
			.border_radius = style.radius,
		}
	);

	Color header = self.header_hovered ? style.header_hover : style.header;
	painter.rect(
		{ style.border_width, style.border_width },
		{
			math::max(elem.size.x - style.border_width * 2.0f, 0.0f),
			math::max(style.header_height - style.border_width, 0.0f)
		},
		{
			.color = header,
			.border_radius = style.radius,
		}
	);

	float text_y = (style.header_height - style.text_size) * 0.5f - 1.0f;
	painter.text(
		{ style.padding, text_y },
		self.expanded ? "v" : ">",
		{
			.size = style.text_size,
			.color = style.mark,
		}
	);
	painter.text(
		{ style.padding + 18.0f, text_y },
		self.label,
		{
			.size = style.text_size,
			.color = style.text,
		}
	);
}

fn void Disclosure.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (!entered && self.header_hovered)
	{
		self.header_hovered = false;
		elem.request_paint();
	}
}

fn bool Disclosure.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	DisclosureStyle style = self.style.resolved();
	bool in_header        = event.pos.x >= 0 && event.pos.x < elem.size.x && event.pos.y >= 0
		&& event.pos.y < style.header_height;

	switch (event.kind)
	{
		case MOVE:
			if (self.header_hovered != in_header)
			{
				self.header_hovered = in_header;
				if (in_header) elem.set_cursor(Cursor.POINTING_HAND);
				elem.request_paint();
			}
			return false;
		case PRESS:
			if (event.button != MouseButton.LEFT || !in_header) return false;
			self.held = true;
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.held) return false;
			self.held = false;
			if (in_header)
			{
				self.expanded = !self.expanded;
				elem.request_layout();
				elem.request_paint();
				if (self.on_change) self.on_change(elem.ui, self.expanded);
			}
			return true;
		default:
			return false;
	}
}