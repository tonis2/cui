<*
 CurvePlot: value-over-x curves with points and handles that can be dragged.

 `@node((CurvePlot) { .series = lines, .points = keys, .x_max = 2.0f,`
 `                    .on_point_drag = &moved, .on_scrub = &seek });`

 A curve editor's canvas: polylines in data space, points on them (keys) that
 are pressed and dragged, handles hanging off points, and a cursor line. The x
 axis runs from `x_min` to `x_max` and zooms and pans horizontally
 (`zoom`/`view_start`, reported through `on_view` so another view can share
 them); the y axis fits whatever is visible, and Shift+wheel zooms it, a middle
 drag pans both, F fits it again.

 The data is borrowed and never edited. A point drag locks to the axis it
 starts along and reports where the point would land, live and once more with
 `done` on release; a handle drag reports the pointer's data position. The
 caller rewrites its data and hands new arrays back.
*>
module cui::widgets;

import cui;
import std::math;
import std::core::string;

struct CurveSeries
{
	Vec2[] points; // borrowed; data space, in x order
	Color color;
	float width; // 0 = 1.5
}

struct CurvePoint
{
	Vec2 at;
	Color color;
	bool selected;
}

struct CurveHandle
{
	usz point; // the point it hangs off
	Vec2 at;
}

struct CurvePlotStyle
{
	Color background;
	Color gutter; // behind the y labels
	Color ruler; // the strip along the top
	Color grid;
	Color zero; // the y = 0 line
	Color text;
	Color point_border;
	Color selected;
	Color hover;
	Color handle;
	Color cursor;
	FontId font; // 0 = the first loaded font
	float text_size;
	float ruler_height;
	float gutter_width;
	float point_radius;
	float handle_radius;
	float pad; // inside the plot, so a point on the edge is not cut in half
	float height; // when `size.y` is 0; 0 = the whole style defaults
}

const CurvePlotStyle DEFAULT_CURVE_PLOT_STYLE = {
	.background = { 0.11, 0.12, 0.15, 1.0 },
	.gutter = { 0.14, 0.15, 0.19, 1.0 },
	.ruler = { 0.16, 0.17, 0.22, 1.0 },
	.grid = { 0.20, 0.22, 0.27, 1.0 },
	.zero = { 0.32, 0.34, 0.40, 1.0 },
	.text = { 0.62, 0.64, 0.70, 1.0 },
	.point_border = { 0.05, 0.06, 0.09, 1.0 },
	.selected = { 1.0, 0.85, 0.35, 1.0 },
	.hover = { 1.0, 1.0, 1.0, 1.0 },
	.handle = { 0.85, 0.86, 0.90, 1.0 },
	.cursor = { 0.95, 0.60, 0.20, 1.0 },
	.text_size = 11.0,
	.ruler_height = 18.0,
	.gutter_width = 44.0,
	.point_radius = 4.0,
	.handle_radius = 3.0,
	.pad = 8.0,
	.height = 220.0,
};

fn CurvePlotStyle CurvePlotStyle.resolved(self)
{
	return self.height > 0 ? self : DEFAULT_CURVE_PLOT_STYLE;
}

alias OnCurvePoint = fn void(Ui* ui, usz index, bool toggle);
alias OnCurveDrag = fn void(Ui* ui, usz index, Vec2 to, bool done);
alias OnCurveScrub = fn void(Ui* ui, float x);
alias OnCurveView = fn void(Ui* ui, float zoom, float start);
// A right press: the point under it or -1, the x it names, and where on screen.
alias OnCurveContext = fn void(Ui* ui, sz point, float x, Vec2 pixel);

enum CurveLock : char
{
	NONE,
	X,
	Y,
}

struct CurvePlot (Widget)
{
	CurveSeries[] series; // borrowed for the life of the element
	CurvePoint[] points; // borrowed
	CurveHandle[] handles; // borrowed
	float x_min;
	float x_max;
	float zoom; // <= 1 fits the whole axis
	float view_start;
	float cursor;
	bool show_cursor;
	float snap_x; // what a dragged point's x lands on; 0 is continuous
	float x_label_scale; // > 0: x labels read round(x * scale); 0: x itself
	String y_suffix; // borrowed; after each y label, e.g. "°"
	String empty_text; // borrowed; said when there are no series

	OnCurvePoint on_point; // a point was pressed; `toggle` with Shift
	OnCurveDrag on_point_drag;
	OnCurveDrag on_handle_drag;
	OnCurveScrub on_scrub; // a press or drag off every point
	OnCurveView on_view;
	OnCurveContext on_context;
	OnClick on_delete;

	CurvePlotStyle style;
	Vec2 size; // per axis: 0 = fill the width, and the style's height

	// The pointer's state and the vertical view; the widget owns these.
	float y_zoom; // 0 or 1 = fitted
	float y_shift;
	int lit; // hovered point, one-based
	int held; // point being dragged, one-based
	int held_handle; // handle being dragged, one-based
	Vec2 press;
	Vec2 drag_to;
	CurveLock lock;
	bool dragged;
	bool scrubbing;
	bool panning;
	Vec2 pan_from;
	float pan_start;
	float pan_shift;
}

fn Vec2 CurvePlot.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	CurvePlotStyle s = self.style.resolved();
	elem.clips = true;
	float w = self.size.x > 0 ? self.size.x : constraints.max.x;
	float h = self.size.y > 0 ? self.size.y : s.height;
	return constraints.constrain({ w, h });
}

<*
 The plot area in element pixels: x = left, y = top, z = width, w = height.
*>
fn Vec4 CurvePlot.plot_rect(&self, Element* elem)
{
	CurvePlotStyle s = self.style.resolved();
	float left       = s.gutter_width + s.pad;
	float top        = s.ruler_height + s.pad;
	return { left, top, math::max(elem.size.x - left - s.pad, 1.0f), math::max(elem.size.y - top - s.pad, 1.0f) };
}

fn float CurvePlot.visible_width(&self) => (self.x_max - self.x_min) / math::max(self.zoom, 1.0f);

fn bool CurvePlot.x_visible(&self, float x)
{
	return x >= self.view_start - 1.0e-6f && x <= self.view_start + self.visible_width() + 1.0e-6f;
}

<*
 The y range shown: the visible data fitted with a margin, then the vertical
 zoom and pan. x = bottom, y = top.
*>
fn Vec2 CurvePlot.y_range(&self)
{
	bool found = false;
	float low  = 0;
	float high = 0;
	foreach (line : self.series)
	{
		foreach (p : line.points)
		{
			if (!self.x_visible(p.x)) continue;
			if (!found)
			{
				low = p.y;
				high = p.y;
				found = true;
				continue;
			}
			low = math::min(low, p.y);
			high = math::max(high, p.y);
		}
	}
	foreach (p : self.points)
	{
		if (!self.x_visible(p.at.x)) continue;
		if (!found)
		{
			low = p.at.y;
			high = p.at.y;
			found = true;
			continue;
		}
		low = math::min(low, p.at.y);
		high = math::max(high, p.at.y);
	}
	if (!found) return { -1.0f, 1.0f };
	float margin = high - low > 1.0e-6f ? (high - low) * 0.1f : math::max(math::abs(high) * 0.1f, 1.0f);
	float center = (low + high) * 0.5f + self.y_shift;
	float half   = ((high - low) * 0.5f + margin) / (self.y_zoom > 0 ? self.y_zoom : 1.0f);
	return { center - half, center + half };
}

fn Vec2 CurvePlot.pixel_of(&self, Element* elem, Vec2 at)
{
	Vec4 r      = self.plot_rect(elem);
	Vec2 range  = self.y_range();
	float width = self.visible_width();
	float x     = width > 0 ? r.x + r.z * (at.x - self.view_start) / width : r.x;
	float y     = range.y > range.x ? r.y + r.w * (range.y - at.y) / (range.y - range.x) : r.y + r.w * 0.5f;
	return { x, y };
}

fn Vec2 CurvePlot.data_of(&self, Element* elem, Vec2 pixel)
{
	Vec4 r     = self.plot_rect(elem);
	Vec2 range = self.y_range();
	return {
		self.view_start + (pixel.x - r.x) / r.z * self.visible_width(),
		range.y - (pixel.y - r.y) / r.w * (range.y - range.x),
	};
}

// An x snapped and kept on the axis.
fn float CurvePlot.settle_x(&self, float x)
{
	if (self.snap_x > 0) x = math::round(x / self.snap_x) * self.snap_x;
	return math::clamp(x, self.x_min, self.x_max);
}

<*
 The point under a pixel, one-based, or 0. Nearest wins.
*>
fn int CurvePlot.point_at(&self, Element* elem, Vec2 pos)
{
	CurvePlotStyle s = self.style.resolved();
	float closest    = s.point_radius + 3.0f;
	int found        = 0;
	foreach (usz i, p : self.points)
	{
		if (!self.x_visible(p.at.x)) continue;
		float d = (self.pixel_of(elem, p.at) - pos).length();
		if (d <= closest)
		{
			closest = d;
			found = (int)i + 1;
		}
	}
	return found;
}

fn int CurvePlot.handle_at(&self, Element* elem, Vec2 pos)
{
	CurvePlotStyle s = self.style.resolved();
	float closest    = s.handle_radius + 3.0f;
	int found        = 0;
	foreach (usz i, h : self.handles)
	{
		float d = (self.pixel_of(elem, h.at) - pos).length();
		if (d <= closest)
		{
			closest = d;
			found = (int)i + 1;
		}
	}
	return found;
}

// A 1-2-5 step giving about `lines` divisions of `range`.
fn float nice_step(float range, float lines) @local
{
	if (!(range > 0)) return 1.0f;
	float raw       = range / lines;
	float magnitude = math::pow(10.0f, math::floor(math::log10(raw)));
	float norm      = raw / magnitude;
	float step      = norm < 1.5f ? 1.0f : (norm < 3.5f ? 2.0f : (norm < 7.5f ? 5.0f : 10.0f));
	return step * magnitude;
}

// Liang–Barsky: the part of a segment inside the rect, or false for none.
fn bool clip_segment(Vec2* a, Vec2* b, Vec4 r) @local
{
	float t0   = 0;
	float t1   = 1;
	Vec2 d     = *b - *a;
	float[4] p = { -d.x, d.x, -d.y, d.y };
	float[4] q = { a.x - r.x, r.x + r.z - a.x, a.y - r.y, r.y + r.w - a.y };
	for (int i = 0; i < 4; i++)
	{
		if (p[i] == 0)
		{
			if (q[i] < 0) return false;
			continue;
		}
		float t = q[i] / p[i];
		if (p[i] < 0)
		{
			if (t > t1) return false;
			if (t > t0) t0 = t;
		}
		else
		{
			if (t < t0) return false;
			if (t < t1) t1 = t;
		}
	}
	Vec2 start = *a;
	*a = start + d * t0;
	*b = start + d * t1;
	return true;
}

fn void CurvePlot.paint(&self, Element* elem, Painter* painter) @dynamic
{
	CurvePlotStyle s = self.style.resolved();
	Vec4 r           = self.plot_rect(elem);
	painter.rect({ 0, 0 }, elem.size, { .color = s.background });
	painter.rect({ 0, 0 }, { s.gutter_width, elem.size.y }, { .color = s.gutter });
	painter.rect({ s.gutter_width, 0 }, { elem.size.x - s.gutter_width, s.ruler_height }, { .color = s.ruler });

	if (self.series.len == 0)
	{
		if (self.empty_text.len > 0)
		{
			painter.text(
				{ s.gutter_width + s.pad, s.ruler_height + s.pad },
				self.empty_text,
				{ .font = s.font, .size = s.text_size + 1.0f, .color = s.text }
			);
		}
		return;
	}

	// Horizontal grid with the y labels in the gutter.
	Vec2 range    = self.y_range();
	float y_step  = nice_step(range.y - range.x, math::max(2.0f, r.w / 40.0f));
	String format = y_step >= 1.0f ? "%.0f%s" : (y_step >= 0.1f ? "%.1f%s" : (y_step >= 0.01f ? "%.2f%s" : "%.3f%s"));
	float first_y = math::ceil(range.x / y_step) * y_step;
	for (int i = 0; i < 64; i++)
	{
		float v = first_y + (float)i * y_step;
		if (v > range.y) break;
		float y   = self.pixel_of(elem, { self.view_start, v }).y;
		bool zero = math::abs(v) < y_step * 1.0e-3f;
		painter.line({ s.gutter_width, y }, { elem.size.x, y }, 1.0f, zero ? s.zero : s.grid);
		char[32] buffer;
		String label  = string::bformat(buffer[..], format, zero ? 0.0f : v, self.y_suffix);
		Vec2 measured = elem.ui.text.measure(s.font, label, s.text_size);
		painter.text(
			{ s.gutter_width - 4.0f - measured.x, y - measured.y * 0.5f },
			label,
			{ .font = s.font, .size = s.text_size, .color = s.text }
		);
	}

	// Vertical ticks with the x labels on the ruler.
	float width = self.visible_width();
	if (width > 0)
	{
		float step = nice_step(width, math::max(1.0f, r.z / 80.0f));
		if (self.x_label_scale > 0)
		{
			float ticks = math::max(1.0f, math::floor(r.z / 80.0f));
			step = math::max(1.0f, math::ceil(width * self.x_label_scale / ticks)) / self.x_label_scale;
		}
		float first = math::ceil(self.view_start / step) * step;
		for (int i = 0; i < 256; i++)
		{
			float at = first + (float)i * step;
			if (at > self.view_start + width + 1.0e-5f) break;
			float x = self.pixel_of(elem, { at, 0 }).x;
			painter.line({ x, s.ruler_height }, { x, elem.size.y }, 1.0f, s.grid);
			char[16] buffer;
			String label  = self.x_label_scale > 0 ? string::bformat(
				buffer[..],
				"%.0f",
				math::round(at * self.x_label_scale)
			)
				: string::bformat(buffer[..], "%.2f", at);
			Vec2 measured = elem.ui.text.measure(s.font, label, s.text_size);
			painter.text(
				{ math::min(x + 2.0f, elem.size.x - measured.x), (s.ruler_height - measured.y) * 0.5f },
				label,
				{ .font = s.font, .size = s.text_size, .color = s.text }
			);
		}
	}

	// The curves, cut to the plot.
	Vec4 clip = { s.gutter_width, s.ruler_height, elem.size.x - s.gutter_width, elem.size.y - s.ruler_height };
	foreach (line : self.series)
	{
		float thickness = line.width > 0 ? line.width : 1.5f;
		for (usz i = 0; i + 1 < line.points.len; i++)
		{
			Vec2 p = line.points[i];
			Vec2 q = line.points[i + 1];
			if (q.x < self.view_start || p.x > self.view_start + width) continue;
			Vec2 a = self.pixel_of(elem, p);
			Vec2 b = self.pixel_of(elem, q);
			if (!clip_segment(&a, &b, clip)) continue;
			painter.line(a, b, thickness, line.color);
		}
	}

	// Handles: a line from the point, a small dot at the end.
	foreach (usz i, h : self.handles)
	{
		if (h.point >= self.points.len) continue;
		Vec2 from = self.pixel_of(elem, self.points[h.point].at);
		Vec2 to   = self.pixel_of(elem, h.at);
		if (self.held_handle == (int)i + 1 && self.dragged) to = self.pixel_of(elem, self.drag_to);
		Vec2 a = from;
		Vec2 b = to;
		if (clip_segment(&a, &b, clip)) painter.line(a, b, 1.0f, s.handle);
		painter.circle(
			to,
			s.handle_radius,
			{ .color = s.handle, .border_color = s.point_border, .border_width = 1.0f }
		);
	}

	// The points, a selected one in the selection colour.
	foreach (usz i, p : self.points)
	{
		if (!self.x_visible(p.at.x)) continue;
		Vec2 at      = self.pixel_of(elem, p.at);
		Color fill   = p.selected ? s.selected : p.color;
		float radius = s.point_radius;
		if (self.lit == (int)i + 1 || self.held == (int)i + 1) radius += 1.0f;
		painter.circle(at, radius, { .color = fill, .border_color = s.point_border, .border_width = 1.0f });
	}
	if (self.held != 0 && self.dragged && (usz)(self.held - 1) < self.points.len)
	{
		Vec2 from = self.pixel_of(elem, self.points[(usz)(self.held - 1)].at);
		Vec2 to   = self.pixel_of(elem, self.drag_to);
		painter.line(from, to, 1.0f, s.hover);
		painter.circle(
			to,
			s.point_radius + 1.0f,
			{ .color = s.selected, .border_color = s.hover, .border_width = 1.5f }
		);
	}

	if (self.show_cursor && self.x_visible(self.cursor))
	{
		float x = self.pixel_of(elem, { self.cursor, 0 }).x;
		painter.line({ x, 0 }, { x, elem.size.y }, 1.5f, s.cursor);
	}
}

fn void CurvePlot.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

fn bool modifier_down(Ui* ui, Key left, Key right) @local => ui.input.key_down(left) || ui.input.key_down(right);

// Where a held point would land for the pointer at `pos`, locked to one axis.
fn Vec2 CurvePlot.point_target(&self, Element* elem, Vec2 pos)
{
	Vec2 origin = self.points[(usz)(self.held - 1)].at;
	Vec2 moved  = self.data_of(elem, pos) - self.data_of(elem, self.press);
	if (self.lock == X) return { self.settle_x(origin.x + moved.x), origin.y };
	return { origin.x, origin.y + moved.y };
}

fn bool CurvePlot.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	CurvePlotStyle s = self.style.resolved();
	switch (event.kind)
	{
		case SCROLL:
			if (self.held != 0 || self.held_handle != 0 || self.scrubbing || self.panning) return false;
			float delta = event.scroll_x != 0 ? event.scroll_x : event.scroll;
			if (modifier_down(elem.ui, Key.LEFT_SHIFT, Key.RIGHT_SHIFT))
			{
				float zoom = self.y_zoom > 0 ? self.y_zoom : 1.0f;
				self.y_zoom = math::clamp(zoom * (delta > 0 ? 1.25f : 0.8f), 0.05f, 1000.0f);
				elem.request_paint();
				return true;
			}
			if (modifier_down(elem.ui, Key.LEFT_CTRL, Key.RIGHT_CTRL))
			{
				Vec4 r         = self.plot_rect(elem);
				float fraction = math::clamp((event.pos.x - r.x) / r.z, 0.0f, 1.0f);
				float anchor   = self.view_start + fraction * self.visible_width();
				self.zoom = math::clamp(math::max(self.zoom, 1.0f) * (delta > 0 ? 1.25f : 0.8f), 1.0f, 32.0f);
				self.view_start = anchor - fraction * self.visible_width();
			}
			else
			{
				if (self.zoom <= 1) return false;
				self.view_start += delta * self.visible_width() * 0.1f;
			}
			self.view_start = math::clamp(self.view_start, self.x_min, self.x_max - self.visible_width());
			if (self.on_view) self.on_view(elem.ui, self.zoom, self.view_start);
			elem.request_paint();
			return true;
		case PRESS:
			if (event.pos.x < s.gutter_width) return false;
			if (event.button == MouseButton.MIDDLE)
			{
				self.panning = true;
				self.pan_from = event.pos;
				self.pan_start = self.view_start;
				self.pan_shift = self.y_shift;
				return true;
			}
			if (event.button == MouseButton.RIGHT)
			{
				if (!self.on_context) return false;
				int hit = self.point_at(elem, event.pos);
				self.on_context(elem.ui, (sz)hit - 1, self.settle_x(self.data_of(elem, event.pos)
					.x), elem.absolute + event.pos);
				return true;
			}
			if (event.button != MouseButton.LEFT) return false;
			elem.request_focus();
			self.press = event.pos;
			self.dragged = false;
			self.lock = NONE;
			int handle = self.handle_at(elem, event.pos);
			if (handle != 0)
			{
				self.held_handle = handle;
				self.drag_to = self.handles[(usz)(handle - 1)].at;
				return true;
			}
			int hit = self.point_at(elem, event.pos);
			if (hit != 0)
			{
				self.held = hit;
				self.drag_to = self.points[(usz)(hit - 1)].at;
				elem.request_paint();
				if (self.on_point)
				{
					self.on_point(elem.ui, (usz)(hit - 1), modifier_down(elem.ui, Key.LEFT_SHIFT, Key.RIGHT_SHIFT));
				}
				return true;
			}
			self.scrubbing = true;
			self.take(elem, event.pos.x);
			return true;
		case MOVE:
			if (self.panning)
			{
				Vec4 r       = self.plot_rect(elem);
				Vec2 range   = self.y_range();
				float span_y = range.y - range.x;
				Vec2 moved   = event.pos - self.pan_from;
				if (self.zoom > 1)
				{
					self.view_start = math::clamp(
						self.pan_start - moved.x / r.z * self.visible_width(),
						self.x_min,
						self.x_max - self.visible_width()
					);
					if (self.on_view) self.on_view(elem.ui, self.zoom, self.view_start);
				}
				// Step by step: the shift does not change the span, so each pixel of
				// drag is the same data step.
				self.y_shift = self.pan_shift + moved.y / r.w * span_y;
				self.pan_from = event.pos;
				self.pan_shift = self.y_shift;
				self.pan_start = self.view_start;
				elem.request_paint();
				return true;
			}
			if (self.held_handle != 0)
			{
				if (!self.dragged && (event.pos - self.press).length() < 3.0f) return true;
				self.dragged = true;
				self.drag_to = self.data_of(elem, event.pos);
				elem.request_paint();
				if (self.on_handle_drag) self.on_handle_drag(elem.ui, (usz)(self.held_handle - 1), self.drag_to, false);
				return true;
			}
			if (self.held != 0)
			{
				Vec2 moved = event.pos - self.press;
				if (!self.dragged)
				{
					if (moved.length() < 3.0f) return true;
					self.dragged = true;
					self.lock = math::abs(moved.x) >= math::abs(moved.y) ? X : Y;
				}
				self.drag_to = self.point_target(elem, event.pos);
				elem.request_paint();
				if (self.on_point_drag) self.on_point_drag(elem.ui, (usz)(self.held - 1), self.drag_to, false);
				return true;
			}
			if (self.scrubbing)
			{
				self.take(elem, event.pos.x);
				return true;
			}
			int over = event.pos.x < s.gutter_width ? 0 : self.point_at(elem, event.pos);
			if (over != self.lit)
			{
				self.lit = over;
				elem.request_paint();
			}
			return false;
		case RELEASE:
			if (self.panning && event.button == MouseButton.MIDDLE)
			{
				self.panning = false;
				return true;
			}
			if (event.button != MouseButton.LEFT) return false;
			if (self.held_handle != 0)
			{
				usz which = (usz)(self.held_handle - 1);
				self.held_handle = 0;
				elem.request_paint();
				if (self.dragged && self.on_handle_drag) self.on_handle_drag(elem.ui, which, self.drag_to, true);
				self.dragged = false;
				return true;
			}
			if (self.held != 0)
			{
				usz which = (usz)(self.held - 1);
				self.held = 0;
				elem.request_paint();
				if (self.dragged && self.on_point_drag) self.on_point_drag(elem.ui, which, self.drag_to, true);
				self.dragged = false;
				return true;
			}
			if (!self.scrubbing) return false;
			self.scrubbing = false;
			return true;
		default:
			return false;
	}
}

fn bool CurvePlot.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	if (event.key == Key.ESCAPE && (self.held != 0 || self.held_handle != 0 || self.scrubbing))
	{
		self.held = 0;
		self.held_handle = 0;
		self.dragged = false;
		self.scrubbing = false;
		elem.request_paint();
		return true;
	}
	if (self.held != 0 || self.held_handle != 0 || self.scrubbing) return false;
	if (event.key == Key.F)
	{
		self.y_zoom = 1.0f;
		self.y_shift = 0;
		elem.request_paint();
		return true;
	}
	if (event.key == Key.DELETE && self.on_delete)
	{
		self.on_delete(elem.ui);
		return true;
	}
	return false;
}

// The cursor to the x under a pixel, reported unless it is already there.
fn void CurvePlot.take(&self, Element* elem, float x)
{
	float at = self.settle_x(self.data_of(elem, { x, 0 }).x);
	if (self.show_cursor && at == self.cursor) return;
	self.cursor = at;
	elem.request_paint();
	if (self.on_scrub) self.on_scrub(elem.ui, at);
}