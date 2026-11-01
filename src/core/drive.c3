<*
 Driving a Ui without a person: synthetic input, finding widgets by id or by
 what they say, and a text dump of the tree. Shared by tests and by agents.
*>
module cui;
import std::io;
import std::math;
import std::collections::list;
import std::core::dstring;
import std::core::ascii;

// The frame step synthetic input advances time by.
const float DRIVE_DT = 1.0f / 60.0f;

excuse NO_SUCH_TARGET, UNKNOWN_KEY;

<*
 What a widget says about itself to `describe_tree` and `find_text`.
 Strings may be temp memory: a description lives for one `@pool`.
*>
struct Description
{
	String text; // what it reads as: a label, a tooltip
	String value; // its state: checked, typed text, a slider's number
	List{DescribedPart} parts;
}

<*
 A clickable cell with no element of its own: a strip button, a tree row.
*>
struct DescribedPart
{
	String label;
	Vec2 pos; // local to the element
	Vec2 size;
}

<*
 Adds a sub-cell, local to the described element.
*>
fn void Description.part(&self, String label, Vec2 pos, Vec2 size)
{
	if (!self.parts.allocator) self.parts.init(tmem);
	self.parts.push({ label, pos, size });
}

<*
 Where an element or one of its parts is on screen, in UI coordinates.
*>
struct DriveTarget
{
	Element* element;
	Vec2 min;
	Vec2 max;
	String label; // the text that matched, for find_text
}

fn Vec2 DriveTarget.center(self) => (self.min + self.max) * 0.5f;

// ---------------------------------------------------------------------------
// Synthetic input

<*
 One synthetic frame, fed and flushed the way an embedder would.

 @param frame : `The level state for this frame.`
 @param dt : `Seconds the frame advances.`
*>
fn void Ui.synth(&self, InputFrame frame, float dt = DRIVE_DT)
{
	self.process_input(frame, dt);
	self.flush();
}

<*
 A click: hover, press, release, `count` times. A double click is count = 2.

 @param at : `UI coordinates.`
 @param held : `Keys held through the click, e.g. LEFT_SHIFT.`
 @require count > 0 : "Count must be positive"
*>
fn void Ui.click(&self, Vec2 at, MouseButton button = LEFT, int count = 1, Key[] held = { })
{
	bool[3] down;
	self.synth({ .mouse = at, .keys_down = held });
	for (int i = 0; i < count; i++)
	{
		down[button.ordinal] = true;
		self.synth({ .mouse = at, .buttons = down, .keys_down = held });
		down[button.ordinal] = false;
		self.synth({ .mouse = at, .keys_down = held });
	}
	if (held.len) self.synth({ .mouse = at });
}

<*
 A left drag from one point to another, moved in even steps.

 @require steps > 0 : "Steps must be positive"
*>
fn void Ui.drag(&self, Vec2 from, Vec2 to, int steps = 8, Key[] held = { })
{
	self.synth({ .mouse = from, .keys_down = held });
	self.synth({ .mouse = from, .buttons = { true, false, false }, .keys_down = held });
	for (int i = 1; i <= steps; i++)
	{
		Vec2 p = from + (to - from) * ((float)i / steps);
		self.synth({ .mouse = p, .buttons = { true, false, false }, .keys_down = held });
	}
	self.synth({ .mouse = to, .keys_down = held });
	if (held.len) self.synth({ .mouse = to });
}

<*
 A wheel turn over a point; positive dy scrolls up, as a wheel does.
*>
fn void Ui.wheel(&self, Vec2 at, float dy, float dx = 0, Key[] held = { })
{
	self.synth({ .mouse = at, .keys_down = held });
	self.synth({ .mouse = at, .scroll = dy, .scroll_x = dx, .keys_down = held });
	self.synth({ .mouse = at });
}

<*
 Rests the pointer on a point, long enough for tooltips and hover delays.

 @require seconds >= 0 : "Time cannot run backwards"
*>
fn void Ui.hover(&self, Vec2 at, float seconds)
{
	self.synth({ .mouse = at });
	for (float t = 0; t < seconds; t += DRIVE_DT) self.synth({ .mouse = at });
}

<*
 Types text into whatever has focus, in one frame, as an IME would.
*>
fn void Ui.type_text(&self, String text)
{
	self.synth({ .mouse = self.input.mouse, .text = text });
	self.synth({ .mouse = self.input.mouse });
}

<*
 Presses a chord (all keys down together) and lets it go.
*>
fn void Ui.press_keys(&self, Key[] chord)
{
	self.synth({ .mouse = self.input.mouse, .keys_down = chord });
	self.synth({ .mouse = self.input.mouse });
}

struct KeyName @local
{
	String name;
	Key key;
}

const KeyName[*] KEY_NAMES @local = {
	{ "ctrl", LEFT_CTRL }, { "control", LEFT_CTRL }, { "shift", LEFT_SHIFT }, { "alt", LEFT_ALT },
	{ "super", LEFT_SUPER }, { "cmd", LEFT_SUPER }, { "escape", ESCAPE }, { "esc", ESCAPE },
	{ "return", RETURN }, { "enter", RETURN }, { "space", SPACE }, { "tab", TAB },
	{ "backspace", BACKSPACE }, { "delete", DELETE }, { "del", DELETE }, { "insert", INSERT },
	{ "left", LEFT_ARROW }, { "right", RIGHT_ARROW }, { "up", UP_ARROW }, { "down", DOWN_ARROW },
	{ "home", HOME }, { "end", END }, { "pageup", PAGE_UP }, { "pagedown", PAGE_DOWN },
	{ "f1", F1 }, { "f2", F2 }, { "f3", F3 }, { "f4", F4 }, { "f5", F5 }, { "f6", F6 },
	{ "f7", F7 }, { "f8", F8 }, { "f9", F9 }, { "f10", F10 }, { "f11", F11 }, { "f12", F12 },
	{ "-", MINUS }, { "=", EQUALS }, { "[", LEFT_BRACKET }, { "]", RIGHT_BRACKET },
	{ "\\", BACKSLASH }, { ";", SEMICOLON }, { "'", APOSTROPHE }, { "`", GRAVE },
	{ ",", COMMA }, { ".", PERIOD }, { "/", SLASH },
	{ "a", A }, { "b", B }, { "c", C }, { "d", D }, { "e", E }, { "f", F }, { "g", G },
	{ "h", H }, { "i", I }, { "j", J }, { "k", K }, { "l", L }, { "m", M }, { "n", N },
	{ "o", O }, { "p", P }, { "q", Q }, { "r", R }, { "s", S }, { "t", T }, { "u", U },
	{ "v", V }, { "w", W }, { "x", X }, { "y", Y }, { "z", Z },
	{ "0", KEY_0 }, { "1", KEY_1 }, { "2", KEY_2 }, { "3", KEY_3 }, { "4", KEY_4 },
	{ "5", KEY_5 }, { "6", KEY_6 }, { "7", KEY_7 }, { "8", KEY_8 }, { "9", KEY_9 },
};

<*
 A key from its name, case-insensitive: "a", "Escape", "ctrl", "F2", "[".

 @return? UNKNOWN_KEY
*>
fn Key? key_from_name(String name)
{
	foreach (k : KEY_NAMES)
	{
		if (k.name.len == name.len && ascii_equal_nocase(k.name, name)) return k.key;
	}
	return UNKNOWN_KEY~;
}

<*
 The keys of a chord written "ctrl+shift+z", into `out`.

 @return "The keys found, a slice of out"
 @return? UNKNOWN_KEY
*>
fn Key[]? keys_from_chord(String chord, Key[] out)
{
	usz n = 0;
	foreach (part : chord.tsplit("+", skip_empty: true))
	{
		String p = part.trim();
		if (n >= out.len) break;
		out[n++] = key_from_name(p)!;
	}
	return out[:n];
}

fn bool ascii_equal_nocase(String a, String b) @local
{
	foreach (i, c : a)
	{
		if (ascii::to_lower(c) != ascii::to_lower(b[i])) return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Finding targets

<*
 The element's box on screen, seen through transforms.
*>
fn DriveTarget Element.drive_target(&self, Vec2 pos = { }, Vec2 size = { -1, -1 })
{
	if (size.x < 0) size = self.size;
	Vec2 a = self.to_screen(pos);
	Vec2 b = self.to_screen(pos + size);
	return {
		.element = self,
		.min = { math::min(a.x, b.x), math::min(a.y, b.y) },
		.max = { math::max(a.x, b.x), math::max(a.y, b.y) },
	};
}

<*
 Whether `other` is this element or below it.
*>
fn bool Element.holds(&self, Element* other)
{
	for (Element* e = other; e != null; e = e.parent)
	{
		if (e == self) return true;
	}
	return false;
}

<*
 Whether a screen point on this element can be seen and clicked: inside the
 window and every clip above, and not covered by an unrelated element.
*>
fn bool Element.shows_point(&self, Vec2 point)
{
	Ui* ui = self.ui;
	if (point.x < 0 || point.y < 0 || point.x >= ui.size.x || point.y >= ui.size.y) return false;
	for (Element* e = self; e != null; e = e.parent)
	{
		if (!e.clips) continue;
		if (!e.contains_local(e.to_local(point))) return false;
	}
	Element* hit = ui.hit_test(point);
	return hit != null && (self.holds(hit) || hit.holds(self));
}

<*
 The element with this id, as a target.

 @return? NO_SUCH_TARGET
*>
fn DriveTarget? Ui.target_id(&self, String id)
{
	Element* elem = self.find_id(id) ?? null;
	if (!elem) return NO_SUCH_TARGET~;
	return elem.drive_target();
}

<*
 The visible element or part whose text best matches: exact first, then a
 prefix, then anywhere in it; case-insensitive. Earlier in the tree wins a tie.

 @return? NO_SUCH_TARGET
*>
fn DriveTarget? Ui.find_text(&self, String text, int* matches = null)
{
	if (!self.root || text.len == 0) return NO_SUCH_TARGET~;
	DriveTarget best;
	int best_rank = 0;
	int count = 0;
	@pool()
	{
		self.@walk(; elem)
		{
			Description d = elem.describe();
			if (d.text.len)
			{
				int rank = text_rank(d.text, text);
				DriveTarget t = elem.drive_target();
				if (rank > 0 && elem.shows_point(t.center()))
				{
					count++;
					if (rank > best_rank)
					{
						best_rank = rank;
						best = t;
						best.label = d.text;
					}
				}
			}
			foreach (part : d.parts)
			{
				int rank = text_rank(part.label, text);
				if (rank == 0) continue;
				DriveTarget t = elem.drive_target(part.pos, part.size);
				if (!elem.shows_point(t.center())) continue;
				count++;
				if (rank > best_rank)
				{
					best_rank = rank;
					best = t;
					best.label = part.label;
				}
			}
		};
	};
	if (matches) *matches = count;
	if (best_rank == 0) return NO_SUCH_TARGET~;
	// The matched label may have been temp memory; callers get the query back.
	best.label = text;
	return best;
}

fn int text_rank(String have, String want) @local
{
	if (want.len > have.len) return 0;
	if (have.len == want.len && ascii_equal_nocase(have, want)) return 3;
	if (ascii_equal_nocase(have[:want.len], want)) return 2;
	for (usz i = 1; i + want.len <= have.len; i++)
	{
		if (ascii_equal_nocase(have[i:want.len], want)) return 1;
	}
	return 0;
}

// ---------------------------------------------------------------------------
// Describing the tree

<*
 What this element's widget says about itself; empty when it says nothing.
 Call inside an `@pool`.
*>
fn Description Element.describe(&self)
{
	Description d;
	if (&self.widget.describe) self.widget.describe(self, &d);
	return d;
}

<*
 One element as a line, without the newline: `Button #save "Save" = on [x,y wxh]`.
 Coordinates are UI points times `scale`.

 @param [&inout] out : "Where the line goes; not temp memory, which the @pool inside would cut"
*>
fn void Element.describe_line(&self, DString* out, float scale = 1)
{
	@pool()
	{
		Description d = self.describe();
		DriveTarget t = self.drive_target();
		out.append(self.type_name.len ? self.type_name : "Widget");
		if (self.id.len) out.appendf(" #%s", self.id);
		if (d.text.len) out.appendf(" \"%s\"", d.text);
		if (d.value.len) out.appendf(" = %s", d.value);
		append_box(out, t, scale);
	};
}

fn void append_box(DString* out, DriveTarget t, float scale) @local
{
	out.appendf(" [%d,%d %dx%d]", (int)(t.min.x * scale), (int)(t.min.y * scale),
		(int)((t.max.x - t.min.x) * scale), (int)((t.max.y - t.min.y) * scale));
}

<*
 Writes the tree as indented lines, one per element worth naming, with parts
 indented under it. An element with no id, text, value, parts or mouse handler
 is left out and its children move up; `all` keeps every element.

 @param [&inout] out : "Where the lines go; not temp memory, which the @pool inside would cut"
 @param under : "An id to start from, or empty for the whole tree"
 @param scale : "Multiplies every coordinate, e.g. into screenshot pixels"
 @return? NO_SUCH_TARGET
*>
fn void? Ui.describe_tree(&self, DString* out, String under = "", bool all = false, float scale = 1)
{
	Element* start = self.root;
	if (under.len) start = self.find_id(under) ?? null;
	if (!start) return NO_SUCH_TARGET~;
	describe_element(start, out, 0, all, scale);
}

fn void describe_element(Element* elem, DString* out, int depth, bool all, float scale) @local
{
	bool keep;
	@pool()
	{
		Description d = elem.describe();
		DriveTarget t = elem.drive_target();
		bool visible = elem.size.x > 0 && elem.size.y > 0 && elem.shows_point(t.center());
		bool named = elem.id.len || d.text.len || d.value.len || d.parts.len() || &elem.widget.on_mouse;
		keep = all || (named && visible);
		if (keep)
		{
			for (int i = 0; i < depth; i++) out.append("  ");
			elem.describe_line(out, scale);
			if (!visible) out.append(" hidden");
			if (elem.ui.focused == elem) out.append(" focused");
			out.append("\n");
			foreach (part : d.parts)
			{
				DriveTarget p = elem.drive_target(part.pos, part.size);
				if (!all && !elem.shows_point(p.center())) continue;
				for (int i = 0; i <= depth; i++) out.append("  ");
				out.appendf("part \"%s\"", part.label);
				append_box(out, p, scale);
				out.append("\n");
			}
		}
	};
	foreach (child : elem.children) describe_element(child, out, keep ? depth + 1 : depth, all, scale);
}

<*
 The nearest element at or above a screen point that says something about
 itself or has an id: what a click there lands on, for a report.
*>
fn Element* Ui.named_at(&self, Vec2 point)
{
	for (Element* e = self.hit_test(point); e != null; e = e.parent)
	{
		if (e.id.len) return e;
		bool says;
		@pool()
		{
			Description d = e.describe();
			says = d.text.len > 0 || d.parts.len() > 0;
		};
		if (says) return e;
	}
	return null;
}
