module cui;
import font;
import std::collections::list;
import std::collections::map;
import std::io;
import std::math;

// SDF text: fonts are loaded through Ui.load_font, glyphs are baked lazily
// into one shared R8 atlas on first use, and Painter.text emits one GLYPH
// drawing per glyph. The backend keeps the GPU copy of the atlas in step
// (cui::vulkan does this in frame(); embedders follow the same two steps —
// see Renderer.sync_text).

<*
 Identifies a loaded font: the return value of `Ui.load_font`, an index in
 loading order starting at 0.
*>
alias FontId = uint;

<*
 Em size used when a text style leaves `size` at 0.
*>
const float DEFAULT_TEXT_SIZE = 16;

<*
 Em size glyphs are baked at. One bake serves every displayed size: SDFs
 stay clean from roughly a fifth of this to several times it, which covers
 UI text comfortably.
*>
const float TEXT_BAKE_PX = 48;

<*
 SDF half-range in pixels at bake size, and the padding baked around each
 glyph bitmap. Bounds how far distance effects (and clean magnification)
 can reach.
*>
const float TEXT_SPREAD = 8;

const uint ATLAS_SIZE = 1024;   // atlas is square, R8, ATLAS_SIZE² bytes
const uint ATLAS_GAP = 1;       // px between packed glyphs

// One baked glyph in the atlas. Geometry is in pixels at TEXT_BAKE_PX;
// Painter.text scales by (style size / TEXT_BAKE_PX) when emitting.
struct GlyphSlot
{
	Vec4 uv;         // atlas UV rect {u0, v0, u1, v1}
	float bearing_x; // left bitmap edge relative to the pen
	float bearing_y; // top bitmap edge above the baseline
	float width;     // bitmap size in px
	float height;
	float advance;   // horizontal advance in px
	bool has_bitmap; // false: nothing to draw (space, or the atlas is full)
}

<*
 The Ui's text state: loaded fonts, the CPU-side glyph atlas and the cache of
 baked glyphs. Owned by Ui (`ui.text`); apps only touch it through
 `Ui.load_font`, `Painter.text` and `TextSystem.measure`.

 The backend reads `atlas`/`dirty` and owns `texture`: it creates the atlas
 texture once fonts exist and re-uploads the pixels whenever `dirty` is set
 (the reference renderer's `sync_text`).
*>
struct TextSystem
{
	List{font::Font} fonts;
	HashMap{ulong, GlyphSlot} glyphs; // key: FontId << 32 | glyph index
	char[] atlas;                     // ATLAS_SIZE x ATLAS_SIZE, R8
	uint atlas_width;
	uint atlas_height;

	// Shelf packer state: glyphs fill left-to-right on the current shelf,
	// a new shelf opens below when a glyph does not fit.
	uint shelf_x;
	uint shelf_y;
	uint shelf_height;

	bool dirty;          // atlas pixels changed since the backend's last upload
	bool atlas_full_warned;
	Texture texture;     // backend-assigned atlas handle; NO_TEXTURE until then
}

fn void TextSystem.init(&self)
{
	self.atlas = alloc::new_array(mem, char, (sz)ATLAS_SIZE * ATLAS_SIZE);
	self.atlas_width = ATLAS_SIZE;
	self.atlas_height = ATLAS_SIZE;
	self.glyphs.init(mem);
}

fn void TextSystem.free(&self)
{
	foreach (&f : self.fonts) f.free();
	self.fonts.free();
	self.glyphs.free();
	if (self.atlas.len > 0) alloc::free(mem, self.atlas);
	self.atlas = {};
}

<*
 Loads a TrueType font for `Painter.text` / the Label widget. Fonts stay
 loaded for the lifetime of the Ui.

 @param path : `Path to a .ttf file (or .ttc; the first font is used).`
 @return `The FontId to reference the font with in text styles.`
*>
fn FontId? Ui.load_font(&self, String path)
{
	font::Font f = font::load_file(path)!;
	self.text.fonts.push(f);
	return (FontId)(self.text.fonts.len() - 1);
}

<*
 Same as `load_font`, from font bytes already in memory (the bytes are copied).

 @param data : `Contents of a .ttf file.`
 @return `The FontId to reference the font with in text styles.`
*>
fn FontId? Ui.load_font_bytes(&self, char[] data)
{
	font::Font f = font::load_bytes(data)!;
	self.text.fonts.push(f);
	return (FontId)(self.text.fonts.len() - 1);
}

<*
 Size of `str` at an em size: x = advance width of the run (kerning included),
 y = ascent - descent. What the Label widget sizes itself with.

 @param font_id : `The font to measure with.`
 @param str : `UTF-8 text, single line.`
 @param size : `Em size in px; 0 uses DEFAULT_TEXT_SIZE.`
 @return `The measured size in pixels; zero when font_id is not loaded.`
*>
fn Vec2 TextSystem.measure(&self, FontId font_id, String str, float size = 0)
{
	if ((sz)font_id >= self.fonts.len()) return {};
	font::Font f = self.fonts[font_id];
	if (size <= 0) size = DEFAULT_TEXT_SIZE;
	float scale = f.scale_for_px(size);
	font::VMetrics vm = f.vmetrics();

	long advance_units = 0;
	uint prev_glyph = 0;
	bool first = true;
	usz i = 0;
	while (i < str.len)
	{
		uint glyph = f.glyph_index(decode_rune(str, &i));
		if (!first) advance_units += f.kerning(prev_glyph, glyph);
		advance_units += f.hmetrics(glyph).advance;
		prev_glyph = glyph;
		first = false;
	}
	return { (float)advance_units * scale, (float)(vm.ascent - vm.descent) * scale };
}

<*
 The baked glyph for (font, glyph index), baking and packing it into the atlas
 on first request. `has_bitmap` is false for glyphs with no outline and when
 the atlas ran out of space (warned once; those glyphs simply don't draw).
*>
fn GlyphSlot TextSystem.glyph(&self, FontId font_id, uint glyph_index)
{
	ulong key = ((ulong)font_id << 32) | glyph_index;
	if (try slot = self.glyphs.get(key)) return slot;
	GlyphSlot slot = self.bake(font_id, glyph_index);
	self.glyphs.set(key, slot);
	return slot;
}

fn GlyphSlot TextSystem.bake(&self, FontId font_id, uint glyph_index)
{
	font::Font f = self.fonts[font_id];
	font::SdfBitmap? baked = f.bake_sdf(glyph_index, TEXT_BAKE_PX, TEXT_SPREAD);
	if (catch baked) return {};
	font::SdfBitmap bitmap = baked;
	defer bitmap.free();

	GlyphSlot slot = { .advance = bitmap.advance };
	if (bitmap.is_empty()) return slot;

	uint width = bitmap.width;
	uint height = bitmap.height;
	if (self.shelf_x + width + ATLAS_GAP > self.atlas_width)
	{
		self.shelf_y += self.shelf_height + ATLAS_GAP;
		self.shelf_x = 0;
		self.shelf_height = 0;
	}
	if (width + ATLAS_GAP > self.atlas_width || self.shelf_y + height + ATLAS_GAP > self.atlas_height)
	{
		if (!self.atlas_full_warned)
		{
			io::printfn("cui: glyph atlas is full (%dx%d); further new glyphs will not render", self.atlas_width, self.atlas_height);
			self.atlas_full_warned = true;
		}
		return slot;
	}

	uint x = self.shelf_x;
	uint y = self.shelf_y;
	self.shelf_x += width + ATLAS_GAP;
	if (height > self.shelf_height) self.shelf_height = height;

	for (uint row = 0; row < height; row++)
	{
		mem::copy(&self.atlas[(sz)(y + row) * self.atlas_width + x], &bitmap.pixels[(sz)row * width], width);
	}
	self.dirty = true;

	float w = self.atlas_width;
	float h = self.atlas_height;
	slot.uv = { (float)x / w, (float)y / h, (float)(x + width) / w, (float)(y + height) / h };
	slot.bearing_x = bitmap.bearing_x;
	slot.bearing_y = bitmap.bearing_y;
	slot.width = width;
	slot.height = height;
	slot.has_bitmap = true;
	return slot;
}

<*
 Style for `Painter.text`.
*>
struct TextStyle
{
	FontId font;   // from Ui.load_font; 0 = the first loaded font
	float size;    // em size in px; 0 uses DEFAULT_TEXT_SIZE
	Color color;   // text color — the zero default is fully transparent
}

<*
 A single line of SDF text. `pos` is the TOP-LEFT of the line box; the
 baseline sits at pos.y + ascent. Glyphs are kerned (legacy kern table;
 GPOS-only fonts get none) and baked into the shared atlas on first use.

 @param pos : `Top-left of the line box, local to the element.`
 @param str : `UTF-8 text; control characters render as missing glyphs.`
 @param style : `Font, em size and color.`
 @return `The size of the emitted run, as TextSystem.measure reports it.`
*>
fn Vec2 Painter.text(&self, Vec2 pos, String str, TextStyle style = { })
{
	Ui* ui = self.element.ui;
	TextSystem* text = &ui.text;
	if ((sz)style.font >= text.fonts.len()) return {};
	font::Font f = text.fonts[style.font];
	float size = style.size > 0 ? style.size : DEFAULT_TEXT_SIZE;

	float scale = f.scale_for_px(size);           // font units -> px
	float glyph_scale = size / TEXT_BAKE_PX;      // bake px -> px
	font::VMetrics vm = f.vmetrics();
	float baseline = pos.y + (float)vm.ascent * scale;

	long pen_units = 0;
	uint prev_glyph = 0;
	bool first = true;
	usz i = 0;
	while (i < str.len)
	{
		uint glyph = f.glyph_index(decode_rune(str, &i));
		if (!first) pen_units += f.kerning(prev_glyph, glyph);

		GlyphSlot slot = text.glyph(style.font, glyph);
		if (slot.has_bitmap)
		{
			float pen_x = pos.x + (float)pen_units * scale;
			self.element.local_drawings.push(
				{
					.kind = DrawingKind.GLYPH,
					.texture = (int)text.texture,
					.size = { slot.width * glyph_scale, slot.height * glyph_scale },
					.corner = { pen_x + slot.bearing_x * glyph_scale, baseline - slot.bearing_y * glyph_scale },
					.params = slot.uv,
					.color = (Vec4)style.color,
				}
			);
		}

		pen_units += f.hmetrics(glyph).advance;
		prev_glyph = glyph;
		first = false;
	}
	return { (float)pen_units * scale, (float)(vm.ascent - vm.descent) * scale };
}

// Minimal UTF-8 decoder: advances *i past one encoded rune and returns its
// codepoint, U+FFFD on malformed input (foreach on String yields raw bytes).
fn uint decode_rune(String s, usz* i) @local
{
	char c = s[*i];
	if (c < 0x80)
	{
		(*i)++;
		return c;
	}
	uint cp;
	usz extra;
	switch
	{
		case (c & 0xe0) == 0xc0:
			cp = c & 0x1f;
			extra = 1;
		case (c & 0xf0) == 0xe0:
			cp = c & 0x0f;
			extra = 2;
		case (c & 0xf8) == 0xf0:
			cp = c & 0x07;
			extra = 3;
		default:
			(*i)++;
			return 0xfffd;
	}
	if (*i + extra >= s.len)
	{
		*i = s.len;
		return 0xfffd;
	}
	for (usz k = 1; k <= extra; k++)
	{
		char cc = s[*i + k];
		if ((cc & 0xc0) != 0x80)
		{
			(*i)++;
			return 0xfffd;
		}
		cp = (cp << 6) | (cc & 0x3f);
	}
	*i += extra + 1;
	return cp;
}
