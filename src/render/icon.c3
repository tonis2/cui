<*
 SVG icons, drawn like text: each icon is read once (svg.c3), baked into a
 distance field in the glyph atlas, and drawn as one tinted GLYPH quad, so it
 is sharp at any size and costs what a letter costs.
*>
module cui;
import std::collections::list;
import std::io;
import std::math;

<*
 The size the long side of an icon's viewBox is baked at.
*>
const float ICON_BAKE_PX = 48;

<*
 A baked icon: where it is in the atlas, and where its viewBox centre is in the
 tile, in bake pixels.
*>
struct IconSlot
{
	GlyphSlot glyph;
	Vec2 centre;
	Vec2 view_px; // the viewBox's size in bake pixels
}

<*
 An icon's distance field: 0.5 on the outline, as the font's glyphs are.
 Strokes and fills are joined as one shape.

 @param [&in] shape : "The parsed icon"
 @require px > 0 && spread > 0 : "Sizes must be positive"
*>
fn char[] bake_icon(IconShape* shape, float px, float spread, uint* width, uint* height, Vec2* centre, Allocator allocator = mem)
{
	Vec4 view = shape.view;
	float k = px / math::max(view.z, view.w);
	float pad = math::ceil(spread) + 1;
	uint w = (uint)math::ceil(view.z * k + 2 * pad);
	uint h = (uint)math::ceil(view.w * k + 2 * pad);
	*width = w;
	*height = h;
	*centre = { pad + view.z * k * 0.5f, pad + view.w * k * 0.5f };
	char[] pixels = alloc::new_array(allocator, char, (sz)w * h);

	@pool()
	{
		sz fills = math::max(shape.even_odd.len(), (sz)1);
		int[] winding = alloc::new_array(tmem, int, fills);
		float[] nearest = alloc::new_array(tmem, float, fills);
		for (uint iy = 0; iy < h; iy++)
		{
			for (uint ix = 0; ix < w; ix++)
			{
				Vec2 p = { view.x + ((float)ix + 0.5f - pad) / k, view.y + ((float)iy + 0.5f - pad) / k };
				// Signed distance in viewBox units, positive inside. Each fill is
				// measured on its own and the union taken, so where shapes overlap
				// their hidden edges leave no seam.
				float signed = -float::max;
				if (shape.edges.len())
				{
					winding[..] = 0;
					nearest[..] = float::max;
					foreach (e : shape.edges)
					{
						nearest[e.fill] = math::min(nearest[e.fill], segment_distance(p, e.a, e.b));
						if ((e.a.y <= p.y && p.y < e.b.y) || (e.b.y <= p.y && p.y < e.a.y))
						{
							float x = e.a.x + (p.y - e.a.y) / (e.b.y - e.a.y) * (e.b.x - e.a.x);
							if (x > p.x) winding[e.fill] += e.b.y > e.a.y ? 1 : -1;
						}
					}
					foreach (i, even_odd : shape.even_odd)
					{
						bool inside = even_odd ? (winding[i] & 1) != 0 : winding[i] != 0;
						signed = math::max(signed, inside ? nearest[i] : -nearest[i]);
					}
				}
				foreach (s : shape.strokes)
				{
					signed = math::max(signed, s.half - segment_distance(p, s.a, s.b));
				}
				float value = math::clamp(0.5f + signed * k / (2 * spread), 0.0f, 1.0f);
				pixels[(sz)iy * w + ix] = (char)(int)(value * 255.0f + 0.5f);
			}
		}
	};
	return pixels;
}

<*
 The baked icon for an SVG, baking and packing it on first use. An SVG that
 cannot be read is warned about once and draws nothing.
*>
fn IconSlot TextSystem.icon(&self, String svg)
{
	if (try slot = self.icons.get(svg)) return slot;
	IconSlot slot;
	IconShape shape;
	if (catch err = parse_svg(svg, &shape, ICON_BAKE_PX))
	{
		io::printfn("cui: could not read an icon (%s): %s", err, svg[:svg.len < 60 ? svg.len : 60]);
		self.icons.set(svg, slot);
		return slot;
	}
	defer shape.free();
	uint w;
	uint h;
	char[] pixels = bake_icon(&shape, ICON_BAKE_PX, TEXT_SPREAD, &w, &h, &slot.centre);
	defer alloc::free(mem, pixels);
	float k = ICON_BAKE_PX / math::max(shape.view.z, shape.view.w);
	slot.view_px = { shape.view.z * k, shape.view.w * k };
	self.pack(pixels, w, h, &slot.glyph);
	self.icons.set(svg, slot);
	return slot;
}

<*
 Draws an SVG icon centred on a point, tinted one colour.

 @param centre : "Where the viewBox's centre goes, local to the element"
 @param size : "How long the viewBox's long side is drawn, in pixels"
 @param svg : "The SVG text; borrowed for as long as the Ui lives (a $embed or literal)"
*>
fn void Painter.icon(&self, Vec2 centre, float size, String svg, Color color)
{
	if (size <= 0 || svg.len == 0) return;
	IconSlot slot = self.element.ui.text.icon(svg);
	if (!slot.glyph.has_bitmap) return;
	float g = size / ICON_BAKE_PX;
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.GLYPH,
			.texture = (int)self.element.ui.text.texture,
			.size = { slot.glyph.width * g, slot.glyph.height * g },
			.corner = centre - slot.centre * g,
			.params = slot.glyph.uv,
			.color = (Vec4)color,
		}
	);
}
