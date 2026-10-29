<*
 A pannable, zoomable window onto a plane of widgets:
 `@tree((Viewport2D) { .on_view = &moved }) { @node((Label) { .text = "here" }).set_offset({ 1200, -300 }); };`

 The children are ordinary widgets placed on the plane by their offsets (plane
 units), sized by themselves — they are offered unbounded room, so give each a
 size of its own rather than one that fills. They are drawn through a content
 transform (`Element.set_content_transform`), which makes pan and zoom a single
 matrix write: nothing is laid out or painted again, and the children keep
 working at any zoom — a TextField on the plane is clicked and typed into where
 it is drawn.

 The viewport itself stays put: it clips the plane to its rect and paints the
 background and grid behind it, in screen space.

 The pointer:
 - the wheel zooms about the pointer, one step per notch; a trackpad scroll
 pans instead, and zooms with Ctrl held (pinch arrives that way);
 - a middle drag pans, from anywhere — over a child too, if the child does not
 take the middle button;
 - a right drag pans; a right click with no drag calls `on_context`;
 - a left press that no child took — empty space — pans when
 `pan_on_background`, and otherwise calls `on_background`.

 The view is the widget's own (`view`); `on_view` reports every change, and
 `set_view` / `frame_children` move it from code.
*>
module cui::widgets;
import std::math;

import cui;

<*
 The view changed: pan or zoom, by the user or by `set_view`.
*>
alias OnViewChange = fn void(Ui* ui, View2D view);

<*
 A press on the viewport that nothing on the plane took, at a plane point, with
 the screen point beside it for anything that opens a popup there.
*>
alias OnPlanePress = fn void(Ui* ui, MouseEvent event, Vec2 plane);

<*
 What a viewport paints behind its plane. Pass a complete style or none at all:
 a zero `grid_step` means "use DEFAULT_VIEWPORT_STYLE wholesale" — the
 MenuStyle convention. Hide the grid with a transparent `grid` color.
*>
struct ViewportStyle
{
	Color background;
	Color grid; // minor lines
	Color grid_major; // every `major_every`-th line
	float grid_step; // plane units between minor lines; 0 = the whole style defaults
	int major_every; // 0 = no major lines
	float min_spacing; // screen px: closer lines than this skip to every other one
}

const ViewportStyle DEFAULT_VIEWPORT_STYLE = {
	.background = { 0.09, 0.10, 0.12, 1.0 },
	.grid = { 0.14, 0.15, 0.18, 1.0 },
	.grid_major = { 0.18, 0.19, 0.23, 1.0 },
	.grid_step = 20.0,
	.major_every = 5,
	.min_spacing = 10.0,
};

fn ViewportStyle ViewportStyle.resolved(self)
{
	return self.grid_step > 0 ? self : DEFAULT_VIEWPORT_STYLE;
}

struct Viewport2D (Widget)
{
	View2D view;
	ViewportStyle style;
	Vec2 size; // per axis: 0 = fill
	bool pan_on_background; // a left drag on empty space pans
	float zoom_step; // the factor one wheel notch zooms by; 0 = 1.15

	OnViewChange on_view;
	OnPlanePress on_background; // left press on empty space, when it does not pan
	OnPlanePress on_context; // right click with no drag

	DragTracker drag; // the pan in progress, if any
}

fn void Viewport2D.mount(&self, Element* elem) @dynamic
{
	elem.set_cursor(Cursor.DEFAULT);
}

fn Vec2 Viewport2D.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.clips = true;
	Vec2 own = constraints.fill(self.size);
	// Plane items size themselves; their offsets are theirs to keep.
	elem.layout_children(cui::loose({ cui::UNBOUNDED, cui::UNBOUNDED }));
	elem.set_content_transform(self.view.matrix());
	return own;
}

fn void Viewport2D.paint(&self, Element* elem, Painter* painter) @dynamic
{
	paint_plane_grid(painter, elem.size, self.view, self.style.resolved());
}

fn bool Viewport2D.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case SCROLL:
			self.wheel(elem, event);
			return true;
		case PRESS:
			bool pans = event.button == MouseButton.MIDDLE || event.button == MouseButton.RIGHT
				|| (event.button == MouseButton.LEFT && self.pan_on_background);
			if (pans)
			{
				self.drag.press(event.pos, event.button);
				return true;
			}
			if (event.button == MouseButton.LEFT && self.on_background)
			{
				self.on_background(elem.ui, event, self.view.to_plane(event.pos));
				return true;
			}
			return false;
		case MOVE:
			if (!self.drag.active()) return false;
			Vec2 before = self.drag.last;
			bool started = self.drag.move(event.pos);
			if (!self.drag.dragging()) return true;
			// The whole way from the press on the move that starts it, so the
			// slop is not lost from the pan.
			Vec2 moved = started ? event.pos - self.drag.start : event.pos - before;
			View2D view = self.view;
			view.pan_by(moved);
			self.set_view(elem, view);
			elem.set_cursor(Cursor.CLOSED_HAND);
			return true;
		case RELEASE:
			if (!self.drag.active() || event.button != self.drag.button) return false;
			DragState was = self.drag.release();
			elem.set_cursor(Cursor.DEFAULT);
			if (was == DragState.PENDING && event.button == MouseButton.RIGHT && self.on_context)
			{
				self.on_context(elem.ui, event, self.view.to_plane(event.pos));
			}
			return true;
	}
}

fn bool Viewport2D.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (event.down && event.key == Key.ESCAPE && self.drag.cancel())
	{
		elem.set_cursor(Cursor.DEFAULT);
		return true;
	}
	return false;
}

<*
 The wheel: a trackpad pans, a wheel (or a trackpad with Ctrl) zooms about the
 pointer.
*>
fn void Viewport2D.wheel(&self, Element* elem, MouseEvent event)
{
	View2D view = self.view;
	if (event.scroll_precise && !event.mods.ctrl)
	{
		view.pan_by({ -event.scroll_x, event.scroll });
	}
	else
	{
		if (event.scroll == 0) return;
		view.zoom_at(event.pos, cui::wheel_zoom_factor(event.scroll, event.scroll_precise, self.zoom_step));
	}
	self.set_view(elem, view);
}

<*
 Moves the view from code: pans and zooms the plane, repaints the grid, and
 reports it through `on_view`.

 @param elem : `The viewport's element.`
 @param view : `The new view.`
*>
fn void Viewport2D.set_view(&self, Element* elem, View2D view)
{
	self.view = view;
	elem.set_content_transform(view.matrix());
	elem.request_paint();
	if (self.on_view) self.on_view(elem.ui, view);
}

<*
 Frames every child: the view zooms and pans so the box around them fits, with
 a margin. Uses the sizes from the last layout.

 @param elem : `The viewport's element.`
 @param margin : `Screen pixels left around them.`
 @param max_zoom : `The largest zoom framing may pick; 0 = 1.`
*>
fn void Viewport2D.frame_children(&self, Element* elem, float margin = 40, float max_zoom = 0)
{
	if (elem.children.len() == 0) return;
	float big = (float)math::FLOAT_MAX;
	Vec4 box = { big, big, -big, -big };
	foreach (child : elem.children)
	{
		box = {
			math::min(box.x, child.offset.x),
			math::min(box.y, child.offset.y),
			math::max(box.z, child.offset.x + child.size.x),
			math::max(box.w, child.offset.y + child.size.y),
		};
	}
	View2D view = self.view;
	view.frame(box, elem.size, margin, max_zoom);
	self.set_view(elem, view);
}

<*
 Paints a background and a grid of the plane under a view: minor lines every
 `grid_step` plane units, a major one every `major_every`, and lines that would
 crowd closer than `min_spacing` on screen thinned to every other one until
 they do not — so a far zoom draws a sparse grid rather than a grey sheet.

 @param painter : `The painter of the element the grid fills.`
 @param size : `The element's size.`
 @param view : `The view of the plane.`
 @param style : `Resolved.`
*>
fn void paint_plane_grid(Painter* painter, Vec2 size, View2D view, ViewportStyle style)
{
	painter.rect({ 0, 0 }, size, { .color = style.background });
	float step = style.grid_step;
	int every = style.major_every;
	float z = view.scale();
	while (step * z < style.min_spacing)
	{
		step *= 2;
		// A major line stays a major line only while the multiple divides.
		if (every > 0) every = every % 2 == 0 ? every / 2 : 0;
	}
	Vec2 top_left = view.to_plane({ 0, 0 });
	Vec2 bottom_right = view.to_plane(size);
	for (int pass = 0; pass < 2; pass++)
	{
		// Minor lines first, so the major ones are drawn over the crossings.
		bool major_pass = pass == 1;
		if (major_pass && every <= 1) break;
		for (long i = (long)math::floor(top_left.x / step); (float)i * step <= bottom_right.x; i++)
		{
			bool major = every > 1 && i % every == 0;
			if (major != major_pass && every > 1) continue;
			float x = math::round(view.to_screen({ (float)i * step, 0 }).x);
			painter.rect({ x, 0 }, { 1, size.y }, { .color = major ? style.grid_major : style.grid });
		}
		for (long i = (long)math::floor(top_left.y / step); (float)i * step <= bottom_right.y; i++)
		{
			bool major = every > 1 && i % every == 0;
			if (major != major_pass && every > 1) continue;
			float y = math::round(view.to_screen({ 0, (float)i * step }).y);
			painter.rect({ 0, y }, { size.x, 1 }, { .color = major ? style.grid_major : style.grid });
		}
	}
}
