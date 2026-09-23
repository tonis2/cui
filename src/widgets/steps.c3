<*
 Steps: a row of labelled steps, each with a state — done, needs attention or
 not yet — and a click that reports which one.

 A workflow strip: "Model ✓ › Skeleton ✓ › Skin ⚠ › Animations (2) › Export".
 Each step may carry a short `note` after its label and a longer `detail`, shown
 as a tip under the step while the pointer is over it. `current` marks the step
 to do next with an outline.

 The steps are borrowed: a caller keeping them live edits the array in place and
 asks the element for layout and paint when something moved. When the row does
 not fit, the notes are dropped first.
*>
module cui::widgets;

import cui;
import std::math;

enum StepState : char
{
	TODO,
	DONE,
	ATTENTION,
}

struct Step
{
	String label; // borrowed
	String note; // borrowed; short, dim, after the label; "" for none
	String detail; // borrowed; the hover tip; "" for none
	StepState state;
}

struct StepsStyle
{
	Color text;
	Color dim; // a TODO step's label, the notes and the chevrons
	Color done;
	Color attention;
	Color mark; // the tick and the "!" drawn on the state dot
	Color hover;
	Color current; // outline of the step to do next
	Color tip_fill;
	Color tip_border;
	Color tip_text;
	Vec4 border_radius;
	FontId font; // 0 = the first loaded font
	float text_size;
	float pad_x; // either side of a step's contents
	float icon; // state dot diameter
	float icon_gap; // between the dot and the label
	float note_gap; // between the label and its note
	float chevron; // width of the gap between steps, the chevron centred in it
	float height; // 0 = the whole style defaults
}

const StepsStyle DEFAULT_STEPS_STYLE = {
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.dim = { 0.58, 0.60, 0.66, 1.0 },
	.done = { 0.36, 0.72, 0.45, 1.0 },
	.attention = { 0.95, 0.66, 0.22, 1.0 },
	.mark = { 0.05, 0.06, 0.09, 1.0 },
	.hover = { 0.28, 0.31, 0.40, 1.0 },
	.current = { 0.95, 0.60, 0.20, 1.0 },
	.tip_fill = { 0.13, 0.14, 0.18, 1.0 },
	.tip_border = { 0.28, 0.30, 0.38, 1.0 },
	.tip_text = { 0.92, 0.93, 0.95, 1.0 },
	.border_radius = { 5.0, 5.0, 5.0, 5.0 },
	.text_size = 12.0,
	.pad_x = 7.0,
	.icon = 11.0,
	.icon_gap = 5.0,
	.note_gap = 4.0,
	.chevron = 12.0,
	.height = 22.0,
};

fn StepsStyle StepsStyle.resolved(self)
{
	return self.height > 0 ? self : DEFAULT_STEPS_STYLE;
}

struct Steps (Widget)
{
	Step[] steps; // borrowed; must outlive the element
	sz current; // the step outlined as next; -1 = none
	OnSelect on_click; // optional
	StepsStyle style;
	bool compact; // set by layout: the notes did not fit and are not drawn
	bool hovering;
	sz hovered;
	sz held;
	bool tracking; // a press is in flight on `held`
}

fn float Steps.step_width(&self, Ui* ui, Step step, StepsStyle s)
{
	float width = 2 * s.pad_x + s.icon + s.icon_gap + ui.text.measure(s.font, step.label, s.text_size).x;
	if (!self.compact && step.note.len > 0)
	{
		width += s.note_gap + ui.text.measure(s.font, step.note, s.text_size).x;
	}
	return width;
}

fn float Steps.row_width(&self, Ui* ui, StepsStyle s)
{
	float width = 0;
	foreach (usz i, step : self.steps)
	{
		if (i > 0) width += s.chevron;
		width += self.step_width(ui, step, s);
	}
	return width;
}

<*
 Which step is under `x`, or -1 — a chevron gap belongs to neither side.
*>
fn sz Steps.index_at(&self, Element* elem, float x)
{
	StepsStyle s = self.style.resolved();
	float left   = 0;
	foreach (usz i, step : self.steps)
	{
		if (i > 0) left += s.chevron;
		float width = self.step_width(elem.ui, step, s);
		if (x >= left && x < left + width) return (sz)i;
		left += width;
	}
	return -1;
}

<*
 Where step `index` starts, in the element's own pixels.
*>
fn float Steps.step_left(&self, Element* elem, sz index)
{
	StepsStyle s = self.style.resolved();
	float left   = 0;
	foreach (usz i, step : self.steps)
	{
		if ((sz)i == index) return left;
		left += self.step_width(elem.ui, step, s) + s.chevron;
	}
	return left;
}

fn Vec2 Steps.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	StepsStyle s = self.style.resolved();
	self.compact = false;
	float width = self.row_width(elem.ui, s);
	if (width > constraints.max.x)
	{
		self.compact = true;
		width = self.row_width(elem.ui, s);
	}
	return constraints.constrain({ width, s.height });
}

fn void paint_step_icon(Painter* painter, Vec2 center, StepState state, StepsStyle s) @local
{
	float r = s.icon * 0.5f;
	switch (state)
	{
		case TODO:
			painter.circle(center, r, { .border_color = s.dim, .border_width = 1.5f });
		case DONE:
			painter.circle(center, r, { .color = s.done });
			painter.line(center + (Vec2) { -r * 0.5f, 0 }, center + (Vec2) { -r * 0.1f, r * 0.42f }, 1.6f, s.mark);
			painter.line(
				center + (Vec2) { -r * 0.1f, r * 0.42f },
				center + (Vec2) { r * 0.52f, -r * 0.45f },
				1.6f,
				s.mark
			);
		case ATTENTION:
			painter.circle(center, r, { .color = s.attention });
			painter.line(center + (Vec2) { 0, -r * 0.55f }, center + (Vec2) { 0, r * 0.12f }, 1.6f, s.mark);
			painter.circle(center + (Vec2) { 0, r * 0.5f }, 0.9f, { .color = s.mark });
	}
}

fn void Steps.paint(&self, Element* elem, Painter* painter) @dynamic
{
	StepsStyle s = self.style.resolved();
	float h      = elem.size.y;
	float left   = 0;
	foreach (usz i, step : self.steps)
	{
		if (i > 0)
		{
			float cx = left + s.chevron * 0.5f;
			float cy = h * 0.5f;
			painter.line({ cx - 1.5f, cy - 3.5f }, { cx + 1.5f, cy }, 1.2f, s.dim);
			painter.line({ cx + 1.5f, cy }, { cx - 1.5f, cy + 3.5f }, 1.2f, s.dim);
			left += s.chevron;
		}
		float width = self.step_width(elem.ui, step, s);
		bool lit    = self.tracking ? (sz)i == self.held : self.hovering && (sz)i == self.hovered;
		if (lit) painter.rect({ left, 0 }, { width, h }, { .color = s.hover, .border_radius = s.border_radius });
		if ((sz)i == self.current)
		{
			painter.rect(
				{ left, 0 },
				{ width, h },
				{
					.border_color = s.current,
					.border_width = 1.0f,
					.border_radius = s.border_radius,
				}
			);
		}

		float x = left + s.pad_x;
		paint_step_icon(painter, { x + s.icon * 0.5f, h * 0.5f }, step.state, s);
		x += s.icon + s.icon_gap;
		Vec2 label = elem.ui.text.measure(s.font, step.label, s.text_size);
		painter.text(
			{ x, (h - label.y) * 0.5f },
			step.label,
			{
				.font = s.font,
				.size = s.text_size,
				.color = step.state == TODO ? s.dim : s.text,
			}
		);
		x += label.x;
		if (!self.compact && step.note.len > 0)
		{
			x += s.note_gap;
			Vec2 note = elem.ui.text.measure(s.font, step.note, s.text_size);
			painter.text(
				{ x, (h - note.y) * 0.5f },
				step.note,
				{ .font = s.font, .size = s.text_size, .color = s.dim }
			);
		}
		left += width;
	}
	self.paint_tip(elem, painter, s);
}

<*
 The hovered step's detail, in a box hanging under the step. Drawn outside the
 element's own rect, so it covers whatever sits below the row; it takes no
 clicks.
*>
fn void Steps.paint_tip(&self, Element* elem, Painter* painter, StepsStyle s)
{
	if (!self.hovering || self.tracking || self.hovered < 0 || self.hovered >= (sz)self.steps.len) return;
	String detail = self.steps[self.hovered].detail;
	if (detail.len == 0) return;

	Vec2 text = elem.ui.text.measure(s.font, detail, s.text_size);
	Vec2 at   = { self.step_left(elem, self.hovered), elem.size.y + 4.0f };
	Vec2 size = { text.x + 2 * s.pad_x, text.y + 8.0f };
	painter.rect_shadow(at, size, 6.0f, { 0, 0, 0, 0.35 }, s.border_radius);
	painter.rect(
		at,
		size,
		{
			.color = s.tip_fill,
			.border_color = s.tip_border,
			.border_width = 1.0f,
			.border_radius = s.border_radius,
		}
	);
	painter.text(at + (Vec2) { s.pad_x, 4.0f }, detail, { .font = s.font, .size = s.text_size, .color = s.tip_text });
}

fn void Steps.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovering = entered;
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	elem.request_paint();
}

fn bool Steps.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
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
			if (self.held < 0) return false;
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
			if (self.on_click) self.on_click(elem.ui, (usz)chosen);
			return true;
		default:
			return false;
	}
}