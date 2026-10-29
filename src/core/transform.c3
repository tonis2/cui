<*
 Element transforms: what `Element.set_transform` does and how the rest of the
 library sees through it.

 A transform is a matrix in the element's own pixels: it maps a point given
 relative to the element's top-left (where layout put it) to where that point
 is drawn, relative to the same top-left. `scale({2, 2, 1})` doubles the
 element and its subtree about its corner; `translate({-x, -y, 0})` slides the
 content up-left, as a pan does. Layout never sees it — sizes, offsets and the
 `absolute` origins stay where layout put them, "pre-transform" — and every
 consumer of a position sees through it:

 - painting: the palette slot holds the full screen matrix, composed with the
 transforms of the ancestors, so nested transforms nest;
 - hit testing: the point is mapped back through each transform on the way
 down, so a button inside a zoomed canvas is clicked where it is drawn;
 - events: `MouseEvent.pos` is the element-local, pre-transform position
 (`Element.to_local`), so a widget inside a zoomed canvas handles its events
 exactly as it would outside one;
 - clipping: see `ClipEntry`.

 Hit testing and event positions treat the matrix as a 2D affine one (the x/y
 rows); a 3D rotation still paints correctly but hit-tests as its projection
 onto the z = 0 plane without perspective.
*>
module cui;
import std::math;
import std::math::matrix;

<*
 Animation path: writes one matrix into the palette. The first call allocates a
 slot (forcing one re-emit so the subtree picks up the slot id); every call after
 that costs a 64-byte write plus a palette upload, regardless of how many
 drawings sit under this element — unless the subtree holds another transformed
 element, whose composed matrix depends on this one; then the canvas re-emits.

 @param transform : `The matrix applied to this element and its subtree, in its own pixels about its top-left (see the module docs).`
*>
fn void Element.set_transform(&self, Matrix4f transform)
{
	Ui* ui = self.ui;
	self.transform = transform;
	if (self.transform_slot == NO_TRANSFORM)
	{
		self.transform_slot = ui.alloc_transform_slot();
		ui.paint_pending = true;
	}
	else if (self.has_transformed_descendant())
	{
		ui.paint_pending = true;
	}
	// Written now as well as on the next emit, so the cheap path is the whole
	// path: a pan writes the matrix and the frame needs nothing else.
	ui.canvas.transforms[self.transform_slot] = self.inherited_transform() * self.placed_transform();
	ui.canvas.transforms_dirty = true;
	ui.frame_requested = true;
}

<*
 A transform for the children only: the element's own drawings, its rect for
 hit testing and its clip stay where layout put them, while everything inside
 moves. A viewport is the case — `translate(-pan * zoom)` times `scale(zoom)`
 pans and zooms what it holds, and its background, its border and the clip
 around its content stay put. Otherwise as `set_transform`.

 @param transform : `The matrix applied to the children, in this element's pixels about its top-left.`
*>
fn void Element.set_content_transform(&self, Matrix4f transform)
{
	if (!self.transform_content && self.transform_slot != NO_TRANSFORM) self.ui.paint_pending = true;
	self.transform_content = true;
	self.set_transform(transform);
}

<*
 The element's own transform as a matrix over absolute pre-transform UI pixels:
 moved to its top-left, applied, moved back. Identity for an element without one.

 @return `The matrix, ready to compose with the ancestors'.`
*>
fn Matrix4f Element.placed_transform(&self)
{
	if (self.transform_slot == NO_TRANSFORM) return matrix::IDENTITY4;
	Vec2 at = self.absolute;
	return matrix::IDENTITY4.translate({ at.x, at.y, 0 }).mul(self.transform).translate({ -at.x, -at.y, 0 });
}

<*
 The screen matrix of the nearest transformed ancestor — what this element's
 drawings would use if it had no transform of its own.

 @return `The composed matrix, identity when no ancestor is transformed.`
*>
fn Matrix4f Element.inherited_transform(&self)
{
	for (Element* e = self.parent; e != null; e = e.parent)
	{
		if (e.transform_slot != NO_TRANSFORM) return self.ui.canvas.transforms[e.transform_slot];
	}
	return matrix::IDENTITY4;
}

<*
 The full screen matrix in force for this element's drawings: its own composed
 slot, or the nearest ancestor's — skipping its own when that one moves only
 its children.

 @return `Absolute pre-transform UI pixels to screen pixels.`
*>
fn Matrix4f Element.screen_transform(&self)
{
	if (self.transform_slot != NO_TRANSFORM && !self.transform_content)
	{
		return self.ui.canvas.transforms[self.transform_slot];
	}
	return self.inherited_transform();
}

<*
 Whether anything below this element carries a transform of its own.

 @return `True when a descendant has a palette slot.`
*>
fn bool Element.has_transformed_descendant(&self)
{
	foreach (child : self.children)
	{
		if (child.transform_slot != NO_TRANSFORM || child.has_transformed_descendant()) return true;
	}
	return false;
}

<*
 A screen point (UI coordinates, as `Input.mouse` and `MouseEvent.absolute`
 give it) in this element's own pre-transform space — the space its `absolute`
 origin and its children's offsets live in.

 @param point : `The point on screen.`
 @return `The same point in this element's layout space.`
*>
fn Vec2 Element.layout_point(&self, Vec2 point)
{
	Vec2 p = self.parent ? self.parent.children_point(point) : point;
	if (self.transform_slot == NO_TRANSFORM || self.transform_content) return p;
	return untransform_point(self.placed_transform(), p);
}

<*
 A screen point in the space this element's children are laid out in: its own
 layout space, seen through its content transform when it has one.

 @param point : `The point on screen.`
 @return `The same point where the children's offsets live.`
*>
fn Vec2 Element.children_point(&self, Vec2 point)
{
	Vec2 p = self.layout_point(point);
	if (self.transform_slot == NO_TRANSFORM || !self.transform_content) return p;
	return untransform_point(self.placed_transform(), p);
}

<*
 A screen point relative to this element's top-left, seen through every
 transform above it — the `MouseEvent.pos` this element is handed.

 @param point : `The point on screen.`
 @return `The element-local, pre-transform position.`
*>
fn Vec2 Element.to_local(&self, Vec2 point) => self.layout_point(point) - self.absolute;

<*
 Where an element-local point is drawn on screen — the inverse of `to_local`,
 for a widget inside a zoomed canvas that opens a popup at the pointer.

 @param local : `A point relative to the element's top-left, pre-transform.`
 @return `The point on screen, in UI coordinates.`
*>
fn Vec2 Element.to_screen(&self, Vec2 local) => transform_point(self.screen_transform(), self.absolute + local);

<*
 The window, as a box in this element's layout space: where a popup's
 click-anywhere catcher has to reach to cover the whole screen, seen through
 any zoom above the element. {min.x, min.y, max.x, max.y}, relative to the
 element's top-left — the offset to give the catcher is the first pair, its
 size the difference.

 @return `The window's box, local to this element.`
*>
fn Vec4 Element.window_box(&self)
{
	Vec2 a = self.to_local({ 0, 0 });
	Vec2 b = self.to_local(self.ui.size);
	return { math::min(a.x, b.x), math::min(a.y, b.y), math::max(a.x, b.x), math::max(a.y, b.y) };
}

<*
 Applies the 2D affine part of a matrix to a point.

 @param m : `The matrix.`
 @param p : `The point.`
 @return `m * p, with z = 0 and w = 1.`
*>
fn Vec2 transform_point(Matrix4f m, Vec2 p)
{
	return { m.m00 * p.x + m.m01 * p.y + m.m03, m.m10 * p.x + m.m11 * p.y + m.m13 };
}

<*
 Undoes the 2D affine part of a matrix. A degenerate matrix (scaled to zero)
 has no inverse; the point comes back unchanged.

 @param m : `The matrix.`
 @param p : `A point already transformed by it.`
 @return `The point it came from.`
*>
fn Vec2 untransform_point(Matrix4f m, Vec2 p)
{
	float det = m.m00 * m.m11 - m.m01 * m.m10;
	if (math::abs(det) < 1e-12f) return p;
	float x = p.x - m.m03;
	float y = p.y - m.m13;
	return { (m.m11 * x - m.m01 * y) / det, (m.m00 * y - m.m10 * x) / det };
}

<*
 The axis-aligned box a rectangle covers after a matrix.

 @param m : `The matrix.`
 @param rect : `{min.x, min.y, max.x, max.y}.`
 @return `The bounding box of the four transformed corners.`
*>
fn Vec4 transform_box(Matrix4f m, Vec4 rect)
{
	Vec2 a = transform_point(m, { rect.x, rect.y });
	Vec2 b = transform_point(m, { rect.z, rect.y });
	Vec2 c = transform_point(m, { rect.z, rect.w });
	Vec2 d = transform_point(m, { rect.x, rect.w });
	return {
		math::min(math::min(a.x, b.x), math::min(c.x, d.x)),
		math::min(math::min(a.y, b.y), math::min(c.y, d.y)),
		math::max(math::max(a.x, b.x), math::max(c.x, d.x)),
		math::max(math::max(a.y, b.y), math::max(c.y, d.y)),
	};
}

<*
 The overlap of two boxes; an empty overlap degenerates to a zero-area box
 rather than an inverted one.

 @param a : `{min.x, min.y, max.x, max.y}.`
 @param b : `{min.x, min.y, max.x, max.y}.`
 @return `Their intersection.`
*>
fn Vec4 intersect_box(Vec4 a, Vec4 b)
{
	Vec4 r = { math::max(a.x, b.x), math::max(a.y, b.y), math::min(a.z, b.z), math::min(a.w, b.w) };
	if (r.z < r.x) r.z = r.x;
	if (r.w < r.y) r.w = r.y;
	return r;
}
