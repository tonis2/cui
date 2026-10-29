<*
 Gesture helpers: the small state machines and value types that canvas-like
 widgets keep re-deriving — telling a click from a drag, turning modifiers into
 a selection mode, a set of selected ids, a box dragged out on screen, and a
 pannable, zoomable view of a plane.

 Plain values with no element of their own, so a widget embeds them as fields
 and drives them from `on_mouse`/`on_key`. `Viewport2D` and `NodeGraph` are
 built on them; an app's own canvas can be too.
*>
module cui;
import std::math;
import std::math::matrix;
import std::collections::list;

// ---------------------------------------------------------------------------
// DragTracker

<*
 How far, in UI pixels, the pointer must travel with a button down before a
 press becomes a drag. Below it the press is a click.
*>
const float DRAG_SLOP = 3.0;

<*
 Where a `DragTracker` is in its gesture.
*>
enum DragState : char
{
	IDLE, // no button held
	PENDING, // pressed, not yet moved past the slop: still a click
	DRAGGING, // moved past the slop: a drag until release
}

<*
 Tells a click from a drag. Feed it the PRESS, the MOVEs and the RELEASE (and
 Esc, through `cancel`); it reports when a press turns into a drag and how far
 the pointer has gone since the press.

 Positions are whatever the widget measures in — usually `MouseEvent.pos` —
 and the slop is compared in the same units, so a widget inside a zoomed
 canvas that wants an on-screen slop feeds `MouseEvent.absolute` instead.

 ```
 case PRESS: self.drag.press(event.pos, event.button); return true;
 case MOVE: if (self.drag.move(event.pos)) start_dragging(); ...
 case RELEASE: if (self.drag.release() == PENDING) clicked(); ...
 ```
*>
struct DragTracker
{
	DragState state;
	MouseButton button; // the button that started it
	Vec2 start; // where it was pressed
	Vec2 last; // the latest position fed in
	float slop; // 0 = DRAG_SLOP
}

<*
 A button went down: a new gesture starts, as a click.

 @param at : `Where, in the widget's units.`
 @param button : `Which button.`
*>
fn void DragTracker.press(&self, Vec2 at, MouseButton button)
{
	self.state = PENDING;
	self.button = button;
	self.start = at;
	self.last = at;
}

<*
 The pointer moved. Returns true exactly once per gesture: on the move that
 carries it past the slop, which is when a widget picks the thing up.

 @param at : `Where, in the widget's units.`
 @return `True when this move started the drag.`
*>
fn bool DragTracker.move(&self, Vec2 at)
{
	self.last = at;
	if (self.state != PENDING) return false;
	float slop = self.slop > 0 ? self.slop : DRAG_SLOP;
	if ((at - self.start).length() < slop) return false;
	self.state = DRAGGING;
	return true;
}

<*
 The button went up. Returns what the gesture was — PENDING for a click,
 DRAGGING for a drag, IDLE when nothing was in progress (it was cancelled) —
 and resets to IDLE.

 @return `The state the gesture ended in.`
*>
fn DragState DragTracker.release(&self)
{
	DragState was = self.state;
	self.state = IDLE;
	return was;
}

<*
 Abandons the gesture, as Esc does: the release that follows reports IDLE, so
 the widget puts back whatever it was moving and commits nothing.

 @return `True when there was a gesture to cancel.`
*>
fn bool DragTracker.cancel(&self)
{
	bool active = self.state != IDLE;
	self.state = IDLE;
	return active;
}

<*
 Whether a gesture is in progress, click or drag.
*>
fn bool DragTracker.active(&self) => self.state != IDLE;

<*
 Whether the gesture has become a drag.
*>
fn bool DragTracker.dragging(&self) => self.state == DRAGGING;

<*
 How far the pointer has gone since the press.
*>
fn Vec2 DragTracker.delta(&self) => self.last - self.start;

// ---------------------------------------------------------------------------
// Selection

<*
 How a click or a box changes a selection.
*>
enum SelectMode : char
{
	REPLACE, // the clicked things become the whole selection
	ADD, // they join it
	TOGGLE, // each flips in or out
}

<*
 The mode the held modifiers ask for: Shift adds, Ctrl (or Super, on a Mac)
 toggles, nothing replaces — the convention of file managers and node
 editors alike.

 @param mods : `The modifiers held with the click.`
 @return `The mode.`
*>
fn SelectMode select_mode(Modifiers mods)
{
	if (mods.ctrl || mods.super) return TOGGLE;
	if (mods.shift) return ADD;
	return REPLACE;
}

<*
 A set of selected ids. The ids are the app's — node indices, entity handles —
 and the set is just a list, which is what a selection of the size a person
 makes by hand wants.

 Owns its list: call `free` when done.
*>
struct Selection
{
	List{ulong} ids;
}

<*
 Whether an id is selected.

 @param id : `The id.`
 @return `True when it is in the set.`
*>
fn bool Selection.has(&self, ulong id)
{
	foreach (i : self.ids) if (i == id) return true;
	return false;
}

<*
 Applies a click or a box: `ids` are what it hit (none, for a click on empty
 space, which with REPLACE clears the selection).

 @param mode : `How to combine.`
 @param ids : `What the gesture hit.`
*>
fn void Selection.apply(&self, SelectMode mode, ulong[] ids)
{
	if (mode == REPLACE) self.ids.clear();
	foreach (id : ids)
	{
		if (mode == TOGGLE && self.has(id))
		{
			self.remove(id);
			continue;
		}
		if (!self.has(id)) self.ids.push(id);
	}
}

<*
 Takes one id out of the set; a no-op when it is not in it.

 @param id : `The id.`
*>
fn void Selection.remove(&self, ulong id)
{
	foreach (i, have : self.ids)
	{
		if (have == id)
		{
			self.ids.remove_at((sz)i);
			return;
		}
	}
}

<*
 Empties the set.
*>
fn void Selection.clear(&self) => self.ids.clear();

<*
 How many ids are selected.
*>
fn usz Selection.len(&self) => (usz)self.ids.len();

<*
 Frees the list.
*>
fn void Selection.free(&self) => self.ids.free();

<*
 The box between two corners dragged out in any direction, as
 {min.x, min.y, max.x, max.y}.

 @param a : `One corner.`
 @param b : `The opposite one.`
 @return `The normalised box.`
*>
fn Vec4 box_between(Vec2 a, Vec2 b)
{
	return { math::min(a.x, b.x), math::min(a.y, b.y), math::max(a.x, b.x), math::max(a.y, b.y) };
}

<*
 Whether two boxes overlap — what a selection box asks of each thing under it.

 @param a : `{min.x, min.y, max.x, max.y}.`
 @param b : `{min.x, min.y, max.x, max.y}.`
 @return `True when they share any area.`
*>
fn bool boxes_overlap(Vec4 a, Vec4 b) => a.x < b.z && b.x < a.z && a.y < b.w && b.y < a.w;

// ---------------------------------------------------------------------------
// View2D

<*
 A pannable, zoomable view of a plane: which point of the plane sits at the
 view's top-left (`pan`, in plane units) and how many screen pixels one plane
 unit spans (`zoom`). The arithmetic behind `Viewport2D` and `NodeGraph`.

 "Screen" here is the viewport's own pixels, relative to its top-left.
*>
struct View2D
{
	Vec2 pan;
	float zoom; // 0 reads as 1
	float zoom_min; // 0 = 0.1
	float zoom_max; // 0 = 4
}

<*
 The zoom in force: `zoom`, or 1 when it was left zero.
*>
fn float View2D.scale(&self) => self.zoom > 0 ? self.zoom : 1.0f;

<*
 A point on the plane, in the viewport's pixels.

 @param p : `Plane units.`
 @return `Viewport pixels.`
*>
fn Vec2 View2D.to_screen(&self, Vec2 p) => (p - self.pan) * self.scale();

<*
 A point in the viewport's pixels, on the plane.

 @param p : `Viewport pixels.`
 @return `Plane units.`
*>
fn Vec2 View2D.to_plane(&self, Vec2 p) => p / self.scale() + self.pan;

<*
 The matrix that draws the plane into the viewport, for
 `Element.set_content_transform`: plane units relative to the viewport's
 top-left go in, viewport pixels come out.
*>
fn Matrix4f View2D.matrix(&self)
{
	float z = self.scale();
	return matrix::IDENTITY4.translate({ -self.pan.x * z, -self.pan.y * z, 0 }).scale({ z, z, 1 });
}

<*
 Slides the view by a distance on screen — what a pan drag does with the
 pointer's movement.

 @param screen_delta : `Viewport pixels; the plane follows the pointer.`
*>
fn void View2D.pan_by(&self, Vec2 screen_delta)
{
	self.pan -= screen_delta / self.scale();
}

<*
 Zooms by a factor, keeping the plane point under `anchor` where it is — the
 wheel zooming about the pointer. The result is held within the view's limits.

 @param anchor : `Viewport pixels that stay fixed.`
 @param factor : `> 1 zooms in.`
 @require factor > 0 : `A zoom factor must be positive.`
*>
fn void View2D.zoom_at(&self, Vec2 anchor, float factor)
{
	Vec2 fixed = self.to_plane(anchor);
	float lo = self.zoom_min > 0 ? self.zoom_min : 0.1f;
	float hi = self.zoom_max > 0 ? self.zoom_max : 4.0f;
	self.zoom = math::clamp(self.scale() * factor, lo, hi);
	self.pan = fixed - anchor / self.zoom;
}

<*
 The zoom factor one wheel event asks for. A detented wheel steps one notch
 per event whatever size the platform reports a notch as (1 on X11, about 15
 on Wayland); a trackpad's continuous deltas zoom in proportion.

 @param scroll : `The event's vertical delta, positive = up = in.`
 @param precise : `Whether it came from a trackpad.`
 @param step : `The factor of one notch; 0 = 1.15.`
 @return `The factor for zoom_at.`
*>
fn float wheel_zoom_factor(float scroll, bool precise, float step = 0)
{
	float notch = step > 0 ? step : 1.15f;
	float notches = precise ? scroll / 15.0f : math::clamp(scroll, -1.0f, 1.0f);
	return math::pow(notch, notches);
}

<*
 Fits a box of the plane into a viewport of the given size, centred, with a
 margin on screen — "frame everything". The zoom stays within the limits, and
 at most `max_zoom` so a single small thing is not blown up to fill the view.

 @param box : `Plane units, {min.x, min.y, max.x, max.y}.`
 @param size : `The viewport, in pixels.`
 @param margin : `Screen pixels left around the box.`
 @param max_zoom : `The largest zoom framing may pick; 0 = 1.`
*>
fn void View2D.frame(&self, Vec4 box, Vec2 size, float margin = 40, float max_zoom = 0)
{
	float w = math::max(box.z - box.x, 1.0f);
	float h = math::max(box.w - box.y, 1.0f);
	float room_x = math::max(size.x - 2 * margin, 1.0f);
	float room_y = math::max(size.y - 2 * margin, 1.0f);
	float lo = self.zoom_min > 0 ? self.zoom_min : 0.1f;
	float hi = self.zoom_max > 0 ? self.zoom_max : 4.0f;
	float cap = max_zoom > 0 ? max_zoom : 1.0f;
	self.zoom = math::clamp(math::min(math::min(room_x / w, room_y / h), cap), lo, hi);
	Vec2 centre = { (box.x + box.z) * 0.5f, (box.y + box.w) * 0.5f };
	self.pan = centre - size * (0.5f / self.zoom);
}
