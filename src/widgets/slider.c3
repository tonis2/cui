<*
 A number that is tuned rather than typed: caption, track, readout, on one row.

     `@node((Slider) { .label = "Damping", .value = 0.9, .max = 1.0, .decimals = 2, .on_change = &damping_moved });`

 The control for a value whose right answer is found by watching something move
 — a spring rate, a gain, an opacity. A text field asks the user to know the
 number before they have seen it; a slider lets them arrive at it, which is the
 whole difference between tuning and configuring.

 **It reports twice, and the two are not the same event.** `on_change` fires on
 every value the drag passes through, which is what makes the thing on screen
 follow the pointer; `on_commit` fires once, when the button comes up, which is
 where a caller that records history puts the undo entry. A caller that wants
 only one of them leaves the other null.

 **The widget holds the value and then says so**, the way `Checkbox` holds the
 tick: it has already moved and repainted by the time the callback runs, so a
 drag responds without the caller rebuilding the subtree around it — and a
 rebuild mid-drag would in fact release the element under the pointer. A caller
 keeping the number somewhere of its own passes it back as `value` the next time
 the panel is built, and that copy wins.

 **The range may be skewed.** `curve` above 1 gives the low end of the range more
 of the track, which is what a value living in the thousands but interesting in
 the hundreds needs — the alternative being a slider whose useful half is its
 first millimetre.
*>
module cui::widgets;
import cui;
import std::io;
import std::math;

<*
 A slider callback, carrying the value the track is now at.

     `fn void gain_moved(Ui* ui, float value) { ui.inherit(Mixer)!!.gain = value; }`
*>
alias OnSlide = fn void(Ui* ui, float value);

<*
 How a Slider is drawn.

 The MenuStyle convention: a zero `height` means "use DEFAULT_SLIDER_STYLE
 wholesale", and a partly filled style is not merged field by field.

 `label_width` and `value_width` are columns rather than measurements, so a
 stack of sliders lines up its captions and its numbers however long either
 happens to be. Zero on either drops that column entirely.
*>
struct SliderStyle
{
	Color track; // the groove, right of the handle
	Color fill; // the groove, left of it
	Color hover_fill; // ... under the pointer
	Color handle;
	Color label_color;
	Color value_color;
	Color dim_color; // caption, readout and handle while disabled
	FontId font; // 0 = the first loaded font
	float text_size;
	float height; // the row; 0 = the whole style defaults
	float track_height;
	float handle_width;
	float label_width; // column for the caption; 0 = no caption column
	float value_width; // column for the readout; 0 = no readout column
	float gap; // between the three columns
	Vec4 border_radius; // of the groove and the handle
}

const SliderStyle DEFAULT_SLIDER_STYLE = {
	.track = { 0.20, 0.22, 0.28, 1.0 },
	.fill = { 0.95, 0.60, 0.20, 1.0 },
	.hover_fill = { 1.0, 0.70, 0.34, 1.0 },
	.handle = { 0.92, 0.93, 0.95, 1.0 },
	.label_color = { 0.92, 0.93, 0.95, 1.0 },
	.value_color = { 0.68, 0.71, 0.78, 1.0 },
	.dim_color = { 0.42, 0.44, 0.50, 1.0 },
	.text_size = 13.0,
	.height = 22.0,
	.track_height = 6.0,
	.handle_width = 10.0,
	.label_width = 78.0,
	.value_width = 54.0,
	.gap = 8.0,
	.border_radius = { 3.0, 3.0, 3.0, 3.0 },
};

fn SliderStyle SliderStyle.resolved(self)
{
	return self.height > 0 ? self : DEFAULT_SLIDER_STYLE;
}

// The longest readout this will format: a number, its decimals and a short
// suffix. A value that overruns it is truncated rather than smeared over the
// stack, and the columns are narrower than this long before it happens.
const usz SLIDER_READOUT_MAX = 32;

<*
 A value on a track, with its caption and its number.

 `min` and `max` are the ends of the range and may be given in either order for
 a track that runs the other way; a zero-width range pins the handle at the left
 and makes the control inert. `step` quantises what a drag can land on — 0 is
 continuous — and `decimals` is how many digits the readout shows, which is a
 separate question from what the value is allowed to be.

 Only the track is a target, not the whole row: a press on the caption would
 otherwise jump the value the user was reading.
*>
struct Slider (Widget)
{
	String label; // borrowed; must outlive the element, as every widget's string must
	String suffix; // borrowed; drawn after the number — "°", "×", " ms"
	float value;
	float min;
	float max;
	float step; // 0 = continuous
	float curve; // 0 or 1 = linear; above 1 stretches the low end of the range
	uint decimals; // digits in the readout, capped at 3
	bool disabled; // painted dim, and takes no drags
	OnSlide on_change; // optional; every value the drag passes through
	OnSlide on_commit; // optional; once, when the button comes up
	SliderStyle style;
	Vec2 size; // per axis: 0 = fill the width, and the style's height
	bool dragging;
	bool hovered;
}

<*
 Where the handle sits, as a fraction of the track.

 The inverse of `value_at`, so the two round-trip: a value put in comes back out
 of a press at the pixel this puts it.

 @return `0 to 1, left to right, whichever way the range runs.`
*>
fn float Slider.fraction(&self)
{
	float span = self.max - self.min;
	if (span == 0.0f) return 0.0f;

	float linear = math::clamp((self.value - self.min) / span, 0.0f, 1.0f);
	float curve = self.curve > 0.0f ? self.curve : 1.0f;
	return curve == 1.0f ? linear : (float)math::pow((double)linear, 1.0 / (double)curve);
}

<*
 What the value is at a fraction of the track, stepped and clamped.

 @param fraction : `0 to 1 along the track; anything outside is clamped to the ends.`
*>
fn float Slider.value_at(&self, float fraction)
{
	float curve = self.curve > 0.0f ? self.curve : 1.0f;
	float t = math::clamp(fraction, 0.0f, 1.0f);
	if (curve != 1.0f) t = (float)math::pow((double)t, (double)curve);

	float value = self.min + (self.max - self.min) * t;
	if (self.step > 0.0f) value = self.min + math::round((value - self.min) / self.step) * self.step;

	// Whichever way the range runs, the ends of it are the ends of it.
	float lo = math::min(self.min, self.max);
	float hi = math::max(self.min, self.max);
	return math::clamp(value, lo, hi);
}

<*
 The number as it is drawn, written into `buffer`.

 	`char[SLIDER_READOUT_MAX] scratch;`
 	`String shown = slider.readout(&scratch);`

 Exposed because a caller laying out its own columns has to know how wide the
 number comes to, and because it is the one part of the paint worth checking
 without a font loaded.

 @param buffer : `Where to write. SLIDER_READOUT_MAX bytes is enough for every value this formats.`
 @return `A slice of the buffer, or empty when the value would not fit in it.`
*>
fn String Slider.readout(&self, char[] buffer)
{
	char[]? written;
	switch (self.decimals)
	{
		case 0: written = io::bprintf(buffer, "%.0f%s", self.value, self.suffix);
		case 1: written = io::bprintf(buffer, "%.1f%s", self.value, self.suffix);
		case 2: written = io::bprintf(buffer, "%.2f%s", self.value, self.suffix);
		default: written = io::bprintf(buffer, "%.3f%s", self.value, self.suffix);
	}
	if (catch written) return "";
	return (String)written;
}

<*
 Fills the width it is offered and stands the style's height, unless `size` says
 otherwise.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
*>
fn Vec2 Slider.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	SliderStyle s = self.style.resolved();

	Vec2 own = self.size;
	if (own.x == 0.0f) own.x = constraints.max.x;
	if (own.y == 0.0f) own.y = s.height;
	return constraints.constrain(own);
}

<*
 Where the groove is, in element-local pixels: the row less the two columns.

 Shared by the paint and the drag so they cannot disagree about which pixel is
 which value — the bug every hand-placed slider has once.
*>
fn Vec2 Slider.track_span(&self, Element* elem)
{
	SliderStyle s = self.style.resolved();

	float left = s.label_width > 0.0f ? s.label_width + s.gap : 0.0f;
	float right = s.value_width > 0.0f ? s.value_width + s.gap : 0.0f;
	float width = math::max(elem.size.x - left - right, 0.0f);
	return { left, width };
}

<*
 Caption, groove, filled part, handle, number.

 @param elem : `The element this widget is attached to.`
 @param painter : `The painter to draw into, in element-local coordinates.`
*>
fn void Slider.paint(&self, Element* elem, Painter* painter) @dynamic
{
	SliderStyle s = self.style.resolved();

	Vec2 span = self.track_span(elem);
	float top = (elem.size.y - s.track_height) * 0.5f;

	painter.rect({ span.x, top }, { span.y, s.track_height }, {
		.color = s.track,
		.border_radius = s.border_radius,
	});

	// The handle rides inside the groove rather than off both ends of it, so the
	// value at the far right is reachable with the pointer still on the widget.
	float travel = math::max(span.y - s.handle_width, 0.0f);
	float at = self.fraction() * travel;

	if (!self.disabled && at > 0.0f)
	{
		painter.rect({ span.x, top }, { at + s.handle_width * 0.5f, s.track_height }, {
			.color = self.dragging || self.hovered ? s.hover_fill : s.fill,
			.border_radius = s.border_radius,
		});
	}

	painter.rect({ span.x + at, top - 3.0f }, { s.handle_width, s.track_height + 6.0f }, {
		.color = self.disabled ? s.dim_color : s.handle,
		.border_radius = s.border_radius,
	});

	if (self.label.len > 0 && s.label_width > 0.0f)
	{
		Vec2 text = elem.ui.text.measure(s.font, self.label, s.text_size);
		painter.text({ 0, (elem.size.y - text.y) * 0.5f }, self.label, {
			.font = s.font,
			.size = s.text_size,
			.color = self.disabled ? s.dim_color : s.label_color,
		});
	}

	if (s.value_width <= 0.0f) return;

	char[SLIDER_READOUT_MAX] scratch;
	String shown = self.readout(&scratch);
	if (shown.len == 0) return;

	// Right-aligned in its column: a stack of sliders whose numbers grow a digit
	// should not shuffle sideways as they are dragged.
	Vec2 number = elem.ui.text.measure(s.font, shown, s.text_size);
	painter.text({ elem.size.x - number.x, (elem.size.y - number.y) * 0.5f }, shown, {
		.font = s.font,
		.size = s.text_size,
		.color = self.disabled ? s.dim_color : s.value_color,
	});
}

<*
 Asks for the sideways cursor over the track it drags along.

 @param elem : `The element this widget is attached to.`
 @param entered : `True when the pointer entered, false when it left.`
*>
fn void Slider.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (self.disabled) return;
	self.hovered = entered;
	if (entered) elem.set_cursor(Cursor.RESIZE_H);
	elem.request_paint();
}

<*
 A press on the track takes the value there and captures the pointer; a move
 while held keeps taking it; the release reports once more.

 A press off the track — on the caption or the number — is declined rather than
 swallowed, so the row can sit inside something that scrolls or drags.

 @param elem : `The element this widget is attached to.`
 @param event : `The mouse event.`
 @return `True for a press on the track and everything that follows it.`
*>
fn bool Slider.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (self.disabled) return false;

	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;

			Vec2 span = self.track_span(elem);
			if (span.y <= 0.0f) return false;
			if (event.pos.x < span.x || event.pos.x > span.x + span.y) return false;

			self.dragging = true;
			self.take(elem, event.pos.x);
			return true; // consuming the press captures the pointer
		case MOVE:
			if (!self.dragging) return false;
			self.take(elem, event.pos.x);
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			elem.request_paint();
			if (self.on_commit) self.on_commit(elem.ui, self.value);
			return true;
		default:
			return false;
	}
}

// The value at a pixel, taken and reported. Silent when the pixel means the
// value the slider already has: a drag across a stepped track passes through
// the same number many times, and a caller writing history on every one of them
// would fill the undo stack with a single gesture.
fn void Slider.take(&self, Element* elem, float x)
{
	SliderStyle s = self.style.resolved();

	Vec2 span = self.track_span(elem);
	float travel = math::max(span.y - s.handle_width, 0.0f);
	if (travel <= 0.0f) return;

	// The pointer holds the middle of the handle, the way AreaSplitter's does.
	float taken = self.value_at((x - span.x - s.handle_width * 0.5f) / travel);
	if (taken == self.value) return;

	self.value = taken;
	elem.request_paint();
	if (self.on_change) self.on_change(elem.ui, taken);
}
