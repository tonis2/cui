<*
 Paths for `Painter`: polylines and cubic Bézier curves, the wires of a node
 editor and the curves of a plot.

 Both are built out of LINE drawings, one per segment, with the round caps
 joining them, so a path costs one drawing per segment and needs nothing new
 from the GPU. The joints overlap by a cap, which is invisible on an opaque
 stroke; a translucent one darkens slightly at each joint.

 A dashed path (`dash > 0`) is measured along its length, so the dashes keep
 their rhythm through the joints and round a curve evenly.
*>
module cui;
import std::math;

<*
 The most segments one Bézier curve is cut into. Enough for a curve spanning a
 large window to look smooth; `Painter.bezier` uses fewer for shorter curves.
*>
const usz BEZIER_MAX_SEGMENTS = 64;

<*
 How long one segment of a flattened Bézier curve is, about, in the element's
 pixels.
*>
const float BEZIER_SEGMENT_LENGTH = 6.0;

<*
 A stroked polyline through the points, round-capped and round-joined.

 @param points : `The points, local to the element; fewer than two draws nothing.`
 @param thickness : `Stroke width in pixels.`
 @param color : `Stroke color.`
 @param dash : `0 for a solid line; otherwise the length of each dash, with gaps as long.`
 @require thickness >= 0 : `A line cannot have a negative thickness.`
 @require dash >= 0 : `A dash cannot have a negative length.`
*>
fn void Painter.polyline(&self, Vec2[] points, float thickness, Color color, float dash = 0)
{
	if (points.len < 2) return;
	if (dash <= 0)
	{
		for (usz i = 1; i < points.len; i++) self.line(points[i - 1], points[i], thickness, color);
		return;
	}
	// Walk the length, toggling between ink and gap every `dash` pixels; a
	// segment can hold several dashes, and a dash can span several segments.
	bool ink = true;
	float left = dash; // of the current dash or gap
	for (usz i = 1; i < points.len; i++)
	{
		Vec2 a = points[i - 1];
		Vec2 b = points[i];
		float length = (b - a).length();
		float done = 0;
		while (length - done > 1e-4f)
		{
			float step = math::min(left, length - done);
			if (ink)
			{
				Vec2 from = a + (b - a) * (done / length);
				Vec2 to = a + (b - a) * ((done + step) / length);
				self.line(from, to, thickness, color);
			}
			done += step;
			left -= step;
			if (left <= 1e-4f)
			{
				ink = !ink;
				left = dash;
			}
		}
	}
}

<*
 A stroked cubic Bézier curve from `a` to `b`, pulled toward `c1` and `c2` — the
 shape of a node editor's wire, with the controls straight out of each port.
 Flattened into segments about `BEZIER_SEGMENT_LENGTH` long.

 @param a : `Start point, local to the element.`
 @param c1 : `First control point.`
 @param c2 : `Second control point.`
 @param b : `End point.`
 @param thickness : `Stroke width in pixels.`
 @param color : `Stroke color.`
 @param dash : `0 for a solid curve; otherwise the length of each dash, with gaps as long.`
 @require thickness >= 0 : `A line cannot have a negative thickness.`
 @require dash >= 0 : `A dash cannot have a negative length.`
*>
fn void Painter.bezier(&self, Vec2 a, Vec2 c1, Vec2 c2, Vec2 b, float thickness, Color color, float dash = 0)
{
	Vec2[BEZIER_MAX_SEGMENTS + 1] points;
	usz count = flatten_bezier(a, c1, c2, b, &points);
	self.polyline(points[:count], thickness, color, dash);
}

<*
 Samples a cubic Bézier curve into a polyline: as many segments as its control
 polygon is long in `BEZIER_SEGMENT_LENGTH`s, at least 4 and at most
 `BEZIER_MAX_SEGMENTS`. The control polygon is never shorter than the curve,
 so this errs toward smooth.

 @param a : `Start point.`
 @param c1 : `First control point.`
 @param c2 : `Second control point.`
 @param b : `End point.`
 @param [out] points : `Receives the points, both ends included.`
 @return `How many points were written.`
*>
fn usz flatten_bezier(Vec2 a, Vec2 c1, Vec2 c2, Vec2 b, Vec2[BEZIER_MAX_SEGMENTS + 1]* points)
{
	float hull = (c1 - a).length() + (c2 - c1).length() + (b - c2).length();
	usz segments = (usz)math::clamp(hull / BEZIER_SEGMENT_LENGTH, 4.0f, (float)BEZIER_MAX_SEGMENTS);
	for (usz i = 0; i <= segments; i++)
	{
		(*points)[i] = bezier_point(a, c1, c2, b, (float)i / (float)segments);
	}
	return segments + 1;
}

<*
 The point at `t` along a cubic Bézier curve.

 @param a : `Start point.`
 @param c1 : `First control point.`
 @param c2 : `Second control point.`
 @param b : `End point.`
 @param t : `0 at a, 1 at b.`
 @return `The point.`
*>
fn Vec2 bezier_point(Vec2 a, Vec2 c1, Vec2 c2, Vec2 b, float t)
{
	float u = 1 - t;
	return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
}

<*
 How far a point is from a cubic Bézier curve, measured against the same
 polyline `Painter.bezier` draws — what hovering or clicking a wire tests.

 @param p : `The point.`
 @param a : `Start point.`
 @param c1 : `First control point.`
 @param c2 : `Second control point.`
 @param b : `End point.`
 @return `The distance, in the curve's pixels.`
*>
fn float bezier_distance(Vec2 p, Vec2 a, Vec2 c1, Vec2 c2, Vec2 b)
{
	Vec2[BEZIER_MAX_SEGMENTS + 1] points;
	usz count = flatten_bezier(a, c1, c2, b, &points);
	float best = (float)math::FLOAT_MAX;
	for (usz i = 1; i < count; i++) best = math::min(best, segment_distance(p, points[i - 1], points[i]));
	return best;
}

<*
 How far a point is from a line segment.

 @param p : `The point.`
 @param a : `One end.`
 @param b : `The other end.`
 @return `The distance to the nearest point of the segment.`
*>
fn float segment_distance(Vec2 p, Vec2 a, Vec2 b)
{
	Vec2 ab = b - a;
	float len2 = ab.dot(ab);
	float t = len2 > 0 ? math::clamp((p - a).dot(ab) / len2, 0.0f, 1.0f) : 0;
	return (p - (a + ab * t)).length();
}
