<*
 The screen a widget is on — how big it is, where it sits, and at what pixel
 density it is rasterized.

 This is a different question from constraints, and both have answers at once.
 Constraints say "you may be this big"; media says "this is the surface you are
 on". A widget sizes itself with the first and decides its *shape* with the
 second: whether a dropdown has room to open downwards, whether a one-line hint
 fits at all, whether a panel takes a third of the width or all of it.

     Media m = elem.media();
     if (m.size.x < 900) ... // the compact arrangement

 The screen is not always the window. Any element can declare its own rect the
 screen for everything below it by publishing `Element.media_box` from its
 layout, and `media()` answers with the nearest such box at or above the caller
 — the window when there is none. `AreaPane` publishes one, so a view inside a
 split pane sizes against its pane rather than against a window it cannot draw
 into. That is the whole override mechanism: no wrapper widget, no extra
 element in the tree.
*>
module cui;
import std::math;

<*
 The metrics of one screen. Sizes and positions are in logical pixels, the same
 units as every other coordinate in cui.

 Freshness: `size` is what the box published on its way into the current layout
 pass and `origin` is where the emit pass last put it, so both are exact in
 `layout` and in `paint`, and in `build` — which runs before either — both are
 the previous frame's. Building against them is what `MenuBar` does to place a
 dropdown, and it is sound for the same reason offsetting a popup by a stale
 `absolute` is: a bar has not moved or changed size between the click that opens
 a menu and the frame that draws it. What is not sound is baking a media value
 into a subtree that then outlives the change — anything that has to keep up
 reads it where it is used.
*>
struct Media
{
	Vec2 size; // the screen's extent
	Vec2 origin; // its top-left in UI coordinates; zero for the window
	// Physical pixels per logical pixel: 2.0 on a retina display, where a 1.0
	// wide line covers two device pixels. Nothing in cui needs it — drawings
	// are logical throughout and the renderer rasterizes at the device's own
	// density — so it is here for the widget that does: snapping a hairline to
	// a whole device pixel, or picking a bitmap of a matching resolution.
	float pixel_ratio;
}

<*
 A size expressed as a share of the screen: `media.fraction({ 0.5, 1.0 })` is
 half the width, full height.

 @param share : `Per axis, the multiplier — 0.25 is a quarter of that axis.`
 @return `The size in pixels.`
*>
fn Vec2 Media.fraction(self, Vec2 share)
{
	return { self.size.x * share.x, self.size.y * share.y };
}

<*
 The position closest to `at` where a rect of `size` still fits on this screen.

 Coordinates are absolute — the same space as `Element.absolute` — so a popup
 positioned in element-local coordinates converts in and back out:
 `media.clamp_rect(elem.absolute + local, size) - elem.absolute`.

 A rect larger than the screen is pinned to the top-left corner rather than
 centred or shrunk: the overflow has to go somewhere, and the corner is the end
 the reader starts at. Clipping or scrolling what is left over is the caller's.

 @param at : `The preferred top-left, in UI coordinates.`
 @param size : `The rect's size.`
 @return `The top-left to place it at, in UI coordinates.`
*>
fn Vec2 Media.clamp_rect(self, Vec2 at, Vec2 size)
{
	Vec2 last = {
		math::max(self.origin.x + self.size.x - size.x, self.origin.x),
		math::max(self.origin.y + self.size.y - size.y, self.origin.y),
	};
	return { math::clamp(at.x, self.origin.x, last.x), math::clamp(at.y, self.origin.y, last.y) };
}

<*
 Where to put a dropdown hanging off an anchor: under it when the panel fits
 there, above it when it does not and there is more room that way, and clamped
 onto the screen either way. What a menu bar's dropdown, a Select's list and a
 combo box all want.

 The flip is decided by which side has more room, not by preference. A bar at
 the top of its screen has nothing above it, so its menu stays below and only
 slides up — overlapping the bar instead of leaving the screen, the trade a
 native menu makes on a short display. A Select in the middle of a form flips,
 because there the room above is real.

 @param anchor : `Top-left of the thing the panel hangs off, in UI coordinates. Its x is the panel's preferred x.`
 @param anchor_height : `How tall that thing is — where "under it" starts.`
 @param size : `The panel's size.`
 @return `The top-left to place the panel at, in UI coordinates.`
*>
fn Vec2 Media.drop(self, Vec2 anchor, float anchor_height, Vec2 size)
{
	float below = anchor.y + anchor_height;
	float room_below = self.origin.y + self.size.y - below;
	float room_above = anchor.y - self.origin.y;
	bool flip = size.y > room_below && room_above > room_below;
	return self.clamp_rect({ anchor.x, flip ? anchor.y - size.y : below }, size);
}

<*
 The window's own metrics — the screen every element sees until something
 between it and the root declares a smaller one.

 @return `The root media: the Ui's size at the origin.`
*>
fn Media Ui.media(&self)
{
	return { .size = self.size, .origin = { 0, 0 }, .pixel_ratio = self.pixel_ratio };
}

<*
 The screen this element is on: the nearest element publishing a `media_box` —
 itself included, so a widget that declares a box also sizes against it — or the
 window when nothing on the way up publishes one.

 Walks parent pointers, so it costs the depth of the tree. That is nothing at
 the rate layout calls it, but a paint loop wanting it per drawing should hoist
 the call out.

 @return `The metrics of the innermost screen containing this element.`
*>
fn Media Element.media(&self)
{
	for (Element* walk = self; walk != null; walk = walk.parent)
	{
		if (walk.media_box.x > 0 || walk.media_box.y > 0)
		{
			return { .size = walk.media_box, .origin = walk.absolute, .pixel_ratio = self.ui.pixel_ratio };
		}
	}
	return self.ui.media();
}
