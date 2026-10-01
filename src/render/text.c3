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

const uint ATLAS_SIZE = 1024; // atlas is square, R8, ATLAS_SIZE² bytes
const uint ATLAS_GAP  = 1;    // px between packed glyphs

// One baked glyph in the atlas. Geometry is in pixels at TEXT_BAKE_PX;
// Painter.text scales by (style size / TEXT_BAKE_PX) when emitting.
struct GlyphSlot
{
	Vec4 uv; // atlas UV rect {u0, v0, u1, v1}
	float bearing_x; // left bitmap edge relative to the pen
	float bearing_y; // top bitmap edge above the baseline
	float width; // bitmap size in px
	float height;
	float advance; // horizontal advance in px
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
	char[] atlas; // ATLAS_SIZE x ATLAS_SIZE, R8
	uint atlas_width;
	uint atlas_height;

	// Shelf packer state: glyphs fill left-to-right on the current shelf,
	// a new shelf opens below when a glyph does not fit.
	uint shelf_x;
	uint shelf_y;
	uint shelf_height;

	bool dirty; // atlas pixels changed since the backend's last upload
	bool atlas_full_warned;
	Texture texture; // backend-assigned atlas handle; NO_TEXTURE until then
}

fn void TextSystem.init(&self)
{
	self.atlas = alloc::new_array(mem, char, (sz)ATLAS_SIZE * ATLAS_SIZE);
	self.atlas_width = ATLAS_SIZE;
	self.atlas_height = ATLAS_SIZE;
	// Beside `glyphs`, and for the same reason: a zeroed List takes the temp
	// allocator on its first push, and a loaded font outlives every temp scope.
	self.fonts.init(mem, 0);
	self.glyphs.init(mem);
}

fn void TextSystem.free(&self)
{
	foreach (&f : self.fonts) f.free();
	self.fonts.free();
	self.glyphs.free();
	if (self.atlas.len > 0) alloc::free(mem, self.atlas);
	self.atlas = { };
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
	if ((sz)font_id >= self.fonts.len()) return { };
	font::Font f = self.fonts[font_id];
	if (size <= 0) size = DEFAULT_TEXT_SIZE;
	float scale       = f.scale_for_px(size);
	font::VMetrics vm = f.vmetrics();

	long advance_units = 0;
	uint prev_glyph    = 0;
	bool first         = true;
	usz i              = 0;
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
	font::Font f           = self.fonts[font_id];
	font::SdfBitmap? baked = f.bake_sdf(glyph_index, TEXT_BAKE_PX, TEXT_SPREAD);
	if (catch baked) return { };
	font::SdfBitmap bitmap = baked;
	defer bitmap.free();

	GlyphSlot slot = { .advance = bitmap.advance };
	if (bitmap.is_empty()) return slot;

	uint width  = bitmap.width;
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
			io::printfn(
				"cui: glyph atlas is full (%dx%d); further new glyphs will not render",
				self.atlas_width,
				self.atlas_height
			);
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
	FontId font; // from Ui.load_font; 0 = the first loaded font
	float size; // em size in px; 0 uses DEFAULT_TEXT_SIZE
	Color color; // text color — the zero default is fully transparent
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
	Ui* ui           = self.element.ui;
	TextSystem* text = &ui.text;
	if ((sz)style.font >= text.fonts.len()) return { };
	font::Font f = text.fonts[style.font];
	float size   = style.size > 0 ? style.size : DEFAULT_TEXT_SIZE;

	float scale       = f.scale_for_px(size); // font units -> px
	float glyph_scale = size / TEXT_BAKE_PX; // bake px -> px
	font::VMetrics vm = f.vmetrics();
	float baseline    = pos.y + (float)vm.ascent * scale;

	long pen_units  = 0;
	uint prev_glyph = 0;
	bool first      = true;
	usz i           = 0;
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

// ---------------------------------------------------------------------------
// Text in a box: what a run does when it is wider than the room it has.

<*
 What text does with a line wider than the width it is given.
*>
enum TextOverflow
{
	VISIBLE, // one line that runs past the edge — `Painter.text` as it always was
	ELLIPSIS, // one line, cut where it stops fitting and ended with "…"
	WRAP, // broken onto further lines at spaces, mid-word for a word too long
}

const String ELLIPSIS_MARK = "…";

<*
 Distance from one line's top to the next one's, at an em size: the line box
 plus the font's own gap between lines.
*>
fn float TextSystem.line_stride(&self, FontId font_id, float size = 0)
{
	if ((sz)font_id >= self.fonts.len()) return 0;
	font::Font f = self.fonts[font_id];
	if (size <= 0) size = DEFAULT_TEXT_SIZE;
	font::VMetrics vm = f.vmetrics();
	return (float)(vm.ascent - vm.descent + vm.line_gap) * f.scale_for_px(size);
}

<*
 How many bytes from the front of `str` fit in `max_w`, in whole runes. Stops
 at a newline, which is never part of the answer.

 @param font_id : `The font to measure with.`
 @param str : `UTF-8 text.`
 @param size : `Em size in px; 0 uses DEFAULT_TEXT_SIZE.`
 @param max_w : `The width to fit in, in pixels.`
 @return `The byte length of the longest prefix no wider than max_w.`
*>
fn usz TextSystem.fit(&self, FontId font_id, String str, float size, float max_w)
{
	if ((sz)font_id >= self.fonts.len()) return str.len;
	font::Font f = self.fonts[font_id];
	if (size <= 0) size = DEFAULT_TEXT_SIZE;
	float scale = f.scale_for_px(size);

	long advance_units = 0;
	uint prev_glyph    = 0;
	bool first         = true;
	usz i              = 0;
	while (i < str.len)
	{
		if (str[i] == '\n') return i;
		usz at = i;
		uint glyph = f.glyph_index(decode_rune(str, &i));
		if (!first) advance_units += f.kerning(prev_glyph, glyph);
		advance_units += f.hmetrics(glyph).advance;
		if ((float)advance_units * scale > max_w) return at;
		prev_glyph = glyph;
		first = false;
	}
	return str.len;
}

<*
 The next line of `str` when it is wrapped to `max_w`: the longest run that
 fits, broken after the last space in it, or mid-word when the run has no space,
 and never empty so a too-narrow box still makes progress. A newline always
 ends a line.

 @param next : `Set to where the line after this one starts; the space or newline the break fell on is skipped.`
 @return `The line's byte length, trailing spaces not counted.`
*>
fn usz TextSystem.line_break(&self, FontId font_id, String str, float size, float max_w, usz* next)
{
	usz fits = self.fit(font_id, str, size, max_w);
	usz end = fits;
	if (fits < str.len && str[fits] != '\n')
	{
		// Back to the last space, unless there is none to go back to.
		usz space = fits;
		while (space > 0 && str[space] != ' ') space--;
		if (str[space] == ' ' && space > 0)
		{
			end = space;
		}
		else if (fits == 0)
		{
			// Not even one rune fits: take it anyway.
			end = 1;
			while (end < str.len && (str[end] & 0xc0) == 0x80) end++;
		}
	}
	usz after = end;
	while (after < str.len && str[after] == ' ') after++;
	if (after < str.len && str[after] == '\n') after++;
	*next = after;
	while (end > 0 && str[end - 1] == ' ') end--;
	return end;
}

<*
 The size `Painter.text_box` takes for the same arguments.

 @param max_w : `The width the text is given; ignored for VISIBLE.`
 @return `Width no wider than max_w (except VISIBLE), height of every line.`
*>
fn Vec2 TextSystem.measure_box(&self, FontId font_id, String str, float size, float max_w, TextOverflow overflow)
{
	switch (overflow)
	{
		case VISIBLE:
			return self.measure(font_id, str, size);
		case ELLIPSIS:
			Vec2 whole = self.measure(font_id, str, size);
			return { math::min(whole.x, math::max(max_w, 0.0f)), whole.y };
		case WRAP:
			Vec2 line_box = self.measure(font_id, "", size);
			float stride = self.line_stride(font_id, size);
			float widest = 0;
			usz lines = 0;
			usz at = 0;
			do
			{
				usz next;
				usz len = self.line_break(font_id, str[at..], size, max_w, &next);
				widest = math::max(widest, self.measure(font_id, str[at:len], size).x);
				lines++;
				at += next;
			}
			while (at < str.len);
			return { widest, line_box.y + stride * (float)(lines - 1) };
	}
}

<*
 Text laid into a box `max_w` wide: one line as `text` draws it, one line cut
 with an ellipsis, or wrapped onto as many lines as it takes.

 @param pos : `Top-left of the first line, local to the element.`
 @param max_w : `The width the text is given; ignored for VISIBLE.`
 @return `The size drawn; what TextSystem.measure_box reports.`
*>
fn Vec2 Painter.text_box(&self, Vec2 pos, String str, TextStyle style, float max_w, TextOverflow overflow)
{
	TextSystem* text = &self.element.ui.text;
	switch (overflow)
	{
		case VISIBLE:
			return self.text(pos, str, style);
		case ELLIPSIS:
			Vec2 whole = text.measure(style.font, str, style.size);
			if (whole.x <= max_w) return self.text(pos, str, style);
			float mark = text.measure(style.font, ELLIPSIS_MARK, style.size).x;
			usz keep = text.fit(style.font, str, style.size, max_w - mark);
			while (keep > 0 && str[keep - 1] == ' ') keep--;
			Vec2 drawn = self.text(pos, str[:keep], style);
			self.text(pos + (Vec2){ drawn.x, 0 }, ELLIPSIS_MARK, style);
			return { math::min(drawn.x + mark, math::max(max_w, 0.0f)), whole.y };
		case WRAP:
			float stride = text.line_stride(style.font, style.size);
			Vec2 size;
			usz at = 0;
			float y = pos.y;
			do
			{
				usz next;
				usz len = text.line_break(style.font, str[at..], style.size, max_w, &next);
				Vec2 line = self.text({ pos.x, y }, str[at:len], style);
				size = { math::max(size.x, line.x), y - pos.y + line.y };
				y += stride;
				at += next;
			}
			while (at < str.len);
			return size;
	}
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