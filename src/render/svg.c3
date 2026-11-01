<*
 A small SVG reader for icons: the shapes, paths and transforms that icon sets
 use, flattened to line segments. Colour is ignored — an icon is one ink,
 chosen when it is drawn — and so are gradients, masks, text and filters.
 Strokes always have round caps and joins.
*>
module cui;
import std::collections::list;
import std::math;
import std::core::string;

excuse BAD_SVG;

<*
 One edge of a filled outline, in viewBox units.
*>
struct IconEdge
{
	Vec2 a;
	Vec2 b;
	ushort fill; // which fill it belongs to: insides are tested per fill
}

<*
 One stroked segment, in viewBox units.
*>
struct IconStroke
{
	Vec2 a;
	Vec2 b;
	float half; // half the stroke width
}

<*
 An icon as geometry: what `bake_icon` turns into a distance field.
*>
struct IconShape
{
	Vec4 view; // viewBox: min x, min y, width, height
	List{IconEdge} edges;
	List{IconStroke} strokes;
	List{bool} even_odd; // per fill: its fill rule
}

fn void IconShape.free(&self)
{
	self.edges.free();
	self.strokes.free();
	self.even_odd.free();
}

// 2D affine: x' = a x + c y + e, y' = b x + d y + f.
struct Affine @local
{
	float a;
	float b;
	float c;
	float d;
	float e;
	float f;
}

const Affine AFFINE_IDENTITY @local = { 1, 0, 0, 1, 0, 0 };

fn Vec2 Affine.apply(self, Vec2 p) => { self.a * p.x + self.c * p.y + self.e, self.b * p.x + self.d * p.y + self.f };

fn Affine Affine.then(self, Affine m)
{
	// self first, then m.
	return {
		m.a * self.a + m.c * self.b, m.b * self.a + m.d * self.b,
		m.a * self.c + m.c * self.d, m.b * self.c + m.d * self.d,
		m.a * self.e + m.c * self.f + m.e, m.b * self.e + m.d * self.f + m.f,
	};
}

fn float Affine.scale(self) => math::sqrt(math::abs(self.a * self.d - self.b * self.c));

// What an element paints with, inherited down the tree.
struct SvgPaint @local
{
	Affine transform;
	bool fill;
	bool stroke;
	float stroke_width;
	bool even_odd;
}

struct SvgReader @local
{
	IconShape* shape;
	float detail; // bake pixels per viewBox unit, for choosing segment counts
	// Points of the subpath being built, and whether it closed.
	List{Vec2} points;
	SvgPaint paint;
	int fill_group; // this element's fill, or -1 before its first
}

<*
 Reads an SVG document into flattened geometry.

 @param [&inout] shape : "Filled in; free with IconShape.free"
 @param bake_px : "The size the long side will be baked at, for curve detail"
 @return? BAD_SVG
*>
fn void? parse_svg(String svg, IconShape* shape, float bake_px = 48, Allocator allocator = mem)
{
	*shape = { };
	shape.edges.init(allocator);
	shape.strokes.init(allocator);
	shape.even_odd.init(allocator);
	SvgReader r = { .shape = shape };

	SvgPaint[16] stack;
	usz depth = 0;
	stack[0] = { .transform = AFFINE_IDENTITY, .fill = true, .stroke_width = 1 };
	usz skip = 0; // inside <defs> and the like
	bool seen_root = false;

	usz i = 0;
	@pool()
	{
		r.points.init(tmem);
		while (i < svg.len)
		{
			if (svg[i] != '<')
			{
				i++;
				continue;
			}
			if (i + 4 <= svg.len && svg[i + 1:3] == "!--")
			{
				i = find_from(svg, "-->", i) + 3;
				continue;
			}
			if (i + 1 < svg.len && (svg[i + 1] == '?' || svg[i + 1] == '!'))
			{
				i = find_from(svg, ">", i) + 1;
				continue;
			}
			usz end = find_from(svg, ">", i);
			if (end >= svg.len) return BAD_SVG~;
			String tag = svg[i + 1 .. end - 1];
			i = end + 1;

			if (tag.len && tag[0] == '/')
			{
				if (skip > 0)
				{
					skip--;
				}
				else if (depth > 0)
				{
					depth--;
				}
				continue;
			}
			bool self_closing = tag.len && tag[^1] == '/';
			if (self_closing) tag = tag[:tag.len - 1];
			String name = tag_name(tag);
			if (skip > 0)
			{
				if (!self_closing) skip++;
				continue;
			}

			SvgPaint paint = stack[depth];
			read_paint(tag, &paint);
			if (attribute(tag, "display") == "none")
			{
				if (!self_closing) skip++;
				continue;
			}

			switch (name)
			{
				case "svg":
					if (!seen_root) read_view(tag, shape);
					seen_root = true;
					r.detail = bake_px / math::max(shape.view.z, shape.view.w);
				case "g":
					break;
				case "defs":
				case "clipPath":
				case "mask":
				case "symbol":
				case "linearGradient":
				case "radialGradient":
				case "pattern":
				case "style":
				case "title":
				case "desc":
				case "text":
					if (!self_closing) skip++;
					continue;
				default:
					if (r.detail == 0) r.detail = bake_px / 24;
					r.paint = paint;
					r.shape_element(name, tag)!;
			}
			if (!self_closing)
			{
				if (depth + 1 < stack.len) depth++;
				stack[depth] = paint;
			}
		}
	};
	if (!seen_root) return BAD_SVG~;
}

fn usz find_from(String s, String what, usz from) @local
{
	for (usz i = from; i + what.len <= s.len; i++)
	{
		if (s[i:what.len] == what) return i;
	}
	return s.len;
}

fn String tag_name(String tag) @local
{
	usz n = 0;
	while (n < tag.len && !is_space(tag[n])) n++;
	return tag[:n];
}

fn bool is_space(char c) @local => c == ' ' || c == '\n' || c == '\t' || c == '\r';

<*
 An attribute's value, or empty. `style="a:b"` entries count as attributes.
*>
fn String attribute(String tag, String key) @local
{
	usz i = tag_name(tag).len;
	while (i < tag.len)
	{
		while (i < tag.len && is_space(tag[i])) i++;
		usz start = i;
		while (i < tag.len && tag[i] != '=' && !is_space(tag[i])) i++;
		String name = tag[start:i - start];
		while (i < tag.len && is_space(tag[i])) i++;
		if (i >= tag.len || tag[i] != '=') continue;
		i++;
		while (i < tag.len && is_space(tag[i])) i++;
		if (i >= tag.len) break;
		char quote = tag[i];
		if (quote != '"' && quote != '\'') continue;
		usz value_start = ++i;
		while (i < tag.len && tag[i] != quote) i++;
		String value = tag[value_start:i - value_start];
		i++;
		if (name == key) return value;
		if (name == "style")
		{
			String v = style_value(value, key);
			if (v.len) return v;
		}
	}
	return "";
}

fn String style_value(String style, String key) @local
{
	foreach (entry : style.tsplit(";"))
	{
		usz colon = find_from(entry, ":", 0);
		if (colon >= entry.len) continue;
		if (entry[:colon].trim() == key) return entry[colon + 1..].trim();
	}
	return "";
}

fn void read_paint(String tag, SvgPaint* paint) @local
{
	String fill = attribute(tag, "fill");
	if (fill.len) paint.fill = fill != "none" && fill != "transparent";
	String stroke = attribute(tag, "stroke");
	if (stroke.len) paint.stroke = stroke != "none" && stroke != "transparent";
	String width = attribute(tag, "stroke-width");
	if (width.len) paint.stroke_width = parse_float(width);
	String rule = attribute(tag, "fill-rule");
	if (rule.len) paint.even_odd = rule == "evenodd";
	String transform = attribute(tag, "transform");
	if (transform.len) paint.transform = parse_transform(transform).then(paint.transform);
}

fn void read_view(String tag, IconShape* shape) @local
{
	String view = attribute(tag, "viewBox");
	if (view.len)
	{
		NumberReader n = { view, 0 };
		shape.view = { n.next() ?? 0, n.next() ?? 0, n.next() ?? 24, n.next() ?? 24 };
	}
	else
	{
		float w = parse_float(attribute(tag, "width"));
		float h = parse_float(attribute(tag, "height"));
		shape.view = { 0, 0, w > 0 ? w : 24, h > 0 ? h : 24 };
	}
	if (shape.view.z <= 0) shape.view.z = 24;
	if (shape.view.w <= 0) shape.view.w = 24;
}

fn float parse_float(String s) @local
{
	NumberReader n = { s, 0 };
	return n.next() ?? 0;
}

// ---------------------------------------------------------------------------
// Numbers, the way path data writes them: "1.5-2e1,.5".

struct NumberReader @local
{
	String s;
	usz i;
}

fn void NumberReader.skip_separators(&self)
{
	while (self.i < self.s.len && (is_space(self.s[self.i]) || self.s[self.i] == ',')) self.i++;
}

fn bool NumberReader.at_number(&self)
{
	self.skip_separators();
	if (self.i >= self.s.len) return false;
	char c = self.s[self.i];
	return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.';
}

fn float? NumberReader.next(&self)
{
	if (!self.at_number()) return BAD_SVG~;
	usz start = self.i;
	String s = self.s;
	if (s[self.i] == '-' || s[self.i] == '+') self.i++;
	bool dot = false;
	while (self.i < s.len)
	{
		char c = s[self.i];
		if (c >= '0' && c <= '9')
		{
			self.i++;
		}
		else if (c == '.' && !dot)
		{
			dot = true;
			self.i++;
		}
		else if ((c == 'e' || c == 'E') && self.i + 1 < s.len && (s[self.i + 1] == '-' || s[self.i + 1] == '+' || (s[self.i + 1] >= '0' && s[self.i + 1] <= '9')))
		{
			self.i += 2;
			while (self.i < s.len && s[self.i] >= '0' && s[self.i] <= '9') self.i++;
			break;
		}
		else
		{
			break;
		}
	}
	return (float)s[start:self.i - start].to_double()!;
}

// An arc flag: a single 0 or 1, which may run straight into the next number.
fn bool? NumberReader.flag(&self)
{
	self.skip_separators();
	if (self.i >= self.s.len) return BAD_SVG~;
	char c = self.s[self.i++];
	if (c == '0') return false;
	if (c == '1') return true;
	return BAD_SVG~;
}

fn Affine parse_transform(String s) @local
{
	Affine total = AFFINE_IDENTITY;
	usz i = 0;
	while (i < s.len)
	{
		while (i < s.len && (is_space(s[i]) || s[i] == ',')) i++;
		usz name_start = i;
		while (i < s.len && s[i] != '(') i++;
		if (i >= s.len) break;
		String name = s[name_start:i - name_start].trim();
		usz close = find_from(s, ")", i);
		NumberReader n = { s[i + 1:close - i - 1], 0 };
		float[6] v;
		usz count = 0;
		while (count < 6 && n.at_number()) v[count++] = n.next() ?? 0;
		i = close + 1;
		Affine m = AFFINE_IDENTITY;
		switch (name)
		{
			case "translate": m = { 1, 0, 0, 1, v[0], count > 1 ? v[1] : 0 };
			case "scale": m = { v[0], 0, 0, count > 1 ? v[1] : v[0], 0, 0 };
			case "rotate":
				float r = v[0] * (float)math::PI / 180;
				float cs = math::cos(r);
				float sn = math::sin(r);
				m = { cs, sn, -sn, cs, 0, 0 };
				if (count == 3)
				{
					Affine to = { 1, 0, 0, 1, -v[1], -v[2] };
					Affine back = { 1, 0, 0, 1, v[1], v[2] };
					m = to.then(m).then(back);
				}
			case "matrix": m = { v[0], v[1], v[2], v[3], v[4], v[5] };
			default: break;
		}
		// The rightmost transform applies first.
		total = m.then(total);
	}
	return total;
}

// ---------------------------------------------------------------------------
// Shapes, as subpaths of points

fn void? SvgReader.shape_element(&self, String name, String tag)
{
	self.fill_group = -1;
	switch (name)
	{
		case "path":
			self.path(attribute(tag, "d"))!;
		case "line":
			self.points.clear();
			self.points.push({ parse_float(attribute(tag, "x1")), parse_float(attribute(tag, "y1")) });
			self.points.push({ parse_float(attribute(tag, "x2")), parse_float(attribute(tag, "y2")) });
			self.emit(false);
		case "polyline":
		case "polygon":
			self.points.clear();
			NumberReader n = { attribute(tag, "points"), 0 };
			while (n.at_number())
			{
				float x = n.next()!;
				float y = n.next()!;
				self.points.push({ x, y });
			}
			self.emit(name == "polygon");
		case "circle":
			float r = parse_float(attribute(tag, "r"));
			self.ellipse({ parse_float(attribute(tag, "cx")), parse_float(attribute(tag, "cy")) }, { r, r });
		case "ellipse":
			self.ellipse({ parse_float(attribute(tag, "cx")), parse_float(attribute(tag, "cy")) },
				{ parse_float(attribute(tag, "rx")), parse_float(attribute(tag, "ry")) });
		case "rect":
			self.rect(tag);
		default:
			break;
	}
}

fn usz SvgReader.segments_for(&self, float length)
{
	float px = length * self.detail * self.paint.transform.scale();
	return (usz)math::clamp(px / 2.0f, 2.0f, 64.0f);
}

fn void SvgReader.ellipse(&self, Vec2 c, Vec2 r)
{
	if (r.x <= 0 || r.y <= 0) return;
	self.points.clear();
	usz n = math::max(self.segments_for((float)math::PI * (r.x + r.y)), (usz)12);
	for (usz i = 0; i < n; i++)
	{
		float t = (float)i / n * 2 * (float)math::PI;
		self.points.push(c + (Vec2){ math::cos(t) * r.x, math::sin(t) * r.y });
	}
	self.emit(true);
}

fn void SvgReader.rect(&self, String tag)
{
	float x = parse_float(attribute(tag, "x"));
	float y = parse_float(attribute(tag, "y"));
	float w = parse_float(attribute(tag, "width"));
	float h = parse_float(attribute(tag, "height"));
	String rx_text = attribute(tag, "rx");
	String ry_text = attribute(tag, "ry");
	float rx = parse_float(rx_text);
	float ry = ry_text.len ? parse_float(ry_text) : rx;
	if (!rx_text.len) rx = ry;
	rx = math::min(rx, w / 2);
	ry = math::min(ry, h / 2);
	self.points.clear();
	if (rx <= 0 || ry <= 0)
	{
		self.points.push({ x, y });
		self.points.push({ x + w, y });
		self.points.push({ x + w, y + h });
		self.points.push({ x, y + h });
		self.emit(true);
		return;
	}
	Vec2[4] centers = { { x + w - rx, y + ry }, { x + w - rx, y + h - ry }, { x + rx, y + h - ry }, { x + rx, y + ry } };
	usz n = math::max(self.segments_for((float)math::PI * (rx + ry) / 4), (usz)3);
	foreach (corner, c : centers)
	{
		float start = ((float)corner - 1) * (float)math::PI / 2;
		for (usz i = 0; i <= n; i++)
		{
			float t = start + (float)i / n * (float)math::PI / 2;
			self.points.push(c + (Vec2){ math::cos(t) * rx, math::sin(t) * ry });
		}
	}
	self.emit(true);
}

<*
 Turns the gathered points into fill edges and stroke segments, in viewBox
 units after the transform. A fill always closes; a stroke only when asked.
*>
fn void SvgReader.emit(&self, bool closed)
{
	sz n = self.points.len();
	if (n < 2) return;
	Affine m = self.paint.transform;
	IconShape* shape = self.shape;
	if (self.paint.fill && n >= 3)
	{
		// Subpaths of one element share a fill, so a hole cut by winding stays a hole.
		if (self.fill_group < 0)
		{
			self.fill_group = (int)shape.even_odd.len();
			shape.even_odd.push(self.paint.even_odd);
		}
		ushort fill = (ushort)self.fill_group;
		for (sz i = 0; i < n; i++)
		{
			Vec2 a = m.apply(self.points[i]);
			Vec2 b = m.apply(self.points[(i + 1) % n]);
			if (a != b) shape.edges.push({ a, b, fill });
		}
	}
	if (self.paint.stroke && self.paint.stroke_width > 0)
	{
		float half = self.paint.stroke_width * m.scale() * 0.5f;
		sz last = closed ? n : n - 1;
		for (sz i = 0; i < last; i++)
		{
			shape.strokes.push({ m.apply(self.points[i]), m.apply(self.points[(i + 1) % n]), half });
		}
	}
}

// ---------------------------------------------------------------------------
// Path data

fn bool is_path_command(char c) @local
{
	switch (c)
	{
		case 'M': case 'm': case 'L': case 'l': case 'H': case 'h': case 'V': case 'v':
		case 'C': case 'c': case 'S': case 's': case 'Q': case 'q': case 'T': case 't':
		case 'A': case 'a': case 'Z': case 'z':
			return true;
		default:
			return false;
	}
}

fn Vec2? NumberReader.pair(&self)
{
	float x = self.next()!;
	float y = self.next()!;
	return { x, y };
}

fn void? SvgReader.path(&self, String d)
{
	NumberReader n = { d, 0 };
	Vec2 cur;
	Vec2 start;
	Vec2 ctrl; // the last control point, for S and T
	char cmd = 0;
	char prev = 0;
	self.points.clear();
	while (true)
	{
		n.skip_separators();
		if (n.i >= d.len) break;
		char c = d[n.i];
		if (is_path_command(c))
		{
			cmd = c;
			n.i++;
		}
		else if (cmd == 0 || cmd == 'z' || cmd == 'Z')
		{
			return BAD_SVG~;
		}
		bool rel = cmd >= 'a';
		Vec2 base = rel ? cur : (Vec2){ 0, 0 };
		char op = rel ? cmd : cmd + 32;
		switch (op)
		{
			case 'm':
				self.emit(false);
				self.points.clear();
				cur = base + n.pair()!;
				start = cur;
				self.points.push(cur);
				// Further pairs after a move are lines.
				cmd = rel ? 'l' : 'L';
			case 'l':
				cur = base + n.pair()!;
				self.points.push(cur);
			case 'h':
				float x = n.next()!;
				cur.x = rel ? cur.x + x : x;
				self.points.push(cur);
			case 'v':
				float y = n.next()!;
				cur.y = rel ? cur.y + y : y;
				self.points.push(cur);
			case 'c':
				Vec2 c1 = base + n.pair()!;
				Vec2 c2 = base + n.pair()!;
				Vec2 to = base + n.pair()!;
				self.cubic(cur, c1, c2, to);
				ctrl = c2;
				cur = to;
			case 's':
				Vec2 c1 = prev == 'c' || prev == 's' ? cur * 2 - ctrl : cur;
				Vec2 c2 = base + n.pair()!;
				Vec2 to = base + n.pair()!;
				self.cubic(cur, c1, c2, to);
				ctrl = c2;
				cur = to;
			case 'q':
				Vec2 q = base + n.pair()!;
				Vec2 to = base + n.pair()!;
				self.cubic(cur, cur + (q - cur) * (2.0f / 3), to + (q - to) * (2.0f / 3), to);
				ctrl = q;
				cur = to;
			case 't':
				Vec2 q = prev == 'q' || prev == 't' ? cur * 2 - ctrl : cur;
				Vec2 to = base + n.pair()!;
				self.cubic(cur, cur + (q - cur) * (2.0f / 3), to + (q - to) * (2.0f / 3), to);
				ctrl = q;
				cur = to;
			case 'a':
				float rx = n.next()!;
				float ry = n.next()!;
				float angle = n.next()!;
				bool large = n.flag()!;
				bool sweep = n.flag()!;
				Vec2 to = base + n.pair()!;
				self.arc(cur, to, rx, ry, angle, large, sweep);
				cur = to;
			case 'z':
				self.emit(true);
				self.points.clear();
				cur = start;
				self.points.push(cur);
			default:
				return BAD_SVG~;
		}
		prev = op;
	}
	self.emit(false);
	self.points.clear();
}

fn void SvgReader.cubic(&self, Vec2 a, Vec2 c1, Vec2 c2, Vec2 b)
{
	float hull = (c1 - a).length() + (c2 - c1).length() + (b - c2).length();
	usz n = self.segments_for(hull);
	for (usz i = 1; i <= n; i++) self.points.push(bezier_point(a, c1, c2, b, (float)i / n));
}

fn float vec_angle(Vec2 u, Vec2 v) @local => math::atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y);

// The endpoint arc of SVG's `A`, through its centre (SVG 1.1, F.6.5).
fn void SvgReader.arc(&self, Vec2 p0, Vec2 p1, float rx, float ry, float degrees, bool large, bool sweep)
{
	if (p0 == p1) return;
	rx = math::abs(rx);
	ry = math::abs(ry);
	if (rx == 0 || ry == 0)
	{
		self.points.push(p1);
		return;
	}
	float phi = degrees * (float)math::PI / 180;
	float cs = math::cos(phi);
	float sn = math::sin(phi);
	Vec2 h = (p0 - p1) * 0.5f;
	float x1 = cs * h.x + sn * h.y;
	float y1 = -sn * h.x + cs * h.y;
	float lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
	if (lambda > 1)
	{
		rx *= math::sqrt(lambda);
		ry *= math::sqrt(lambda);
	}
	float num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
	float den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
	float k = den > 0 ? math::sqrt(math::max(0.0f, num / den)) : 0;
	if (large == sweep) k = -k;
	float cxp = k * rx * y1 / ry;
	float cyp = -k * ry * x1 / rx;
	Vec2 mid = (p0 + p1) * 0.5f;
	Vec2 c = { cs * cxp - sn * cyp + mid.x, sn * cxp + cs * cyp + mid.y };
	Vec2 u = { (x1 - cxp) / rx, (y1 - cyp) / ry };
	Vec2 v = { (-x1 - cxp) / rx, (-y1 - cyp) / ry };
	float theta = vec_angle({ 1, 0 }, u);
	float delta = vec_angle(u, v);
	if (!sweep && delta > 0) delta -= 2 * (float)math::PI;
	if (sweep && delta < 0) delta += 2 * (float)math::PI;
	usz n = self.segments_for(math::abs(delta) * math::max(rx, ry));
	for (usz i = 1; i <= n; i++)
	{
		float t = theta + delta * (float)i / n;
		float ex = rx * math::cos(t);
		float ey = ry * math::sin(t);
		self.points.push(i == n ? p1 : c + (Vec2){ cs * ex - sn * ey, sn * ex + cs * ey });
	}
}
