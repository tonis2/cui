<*
 A directory listing you can walk and pick a file out of.

 `@tree((Scroll) { }) { @node((FileBrowser) { .mask = "*.glb", .on_choose = &opened }); };`

 One row per entry, directories first and an "Up one folder" row above them.
 Each row has a drawn icon (folder, page, or the up arrow) when the style's
 `icon_size` is set, a file's extension dimmed after its name, and its size
 right-aligned; a name too long for the row ends in "…" short of the size.
 Rows are striped, and an empty folder says so in the space below. A click selects a row
 and a second click on the selected row activates it — enter the directory, or
 choose the file — which is the same two-step the animation library's clip cells
 use, and it means a browser can be driven with single clicks by anything that
 cannot express a double one, tests included.

 **It sizes itself to its content** and expects a `Scroll` above it, the shape
 every list in cui takes: there is no windowing here, no virtualisation and no
 scrollbar of its own. A directory of ten thousand files measures ten thousand
 rows, which is affordable because a row is a few rects and lines and two strings. Given a box
 smaller than the listing — a panel that capped it, or a caller who forgot the
 Scroll — it paints the rows that fit and stops, rather than down over whatever
 the panel is floating on.

 The listing is a snapshot, taken when the directory changes and not refreshed
 behind the user's back — `rescan` is how a caller asks for the current truth.
*>
module cui::widgets;

import cui;
import std::io;
import std::io::path;
import std::math::vector;
import std::core::string;

import std::collections::list;


<*
 Called with an absolute path when a row is activated (a second click on the
 selected row, or Return) and, if `on_select` is set, when the selection moves.

 The path is borrowed for the duration of the call; copy it to keep it.
*>
alias OnChoose = fn void(Ui* ui, String path);

<*
 How a FileBrowser draws. Zero takes `DEFAULT_FILE_BROWSER_STYLE` whole — the
 all-or-nothing rule `TextFieldStyle` and `DialogStyle` both follow.
*>
struct FileBrowserStyle
{
	Color text;
	Color directory; // folders read differently from files, which is the one
	// distinction a listing must make at a glance; also the folder icon's fill
	Color size; // the right-hand column, a file's extension and the empty-folder note
	Color icon; // a file's page outline
	Color hover;
	Color selected;
	Color selected_text;
	Color stripe; // every other row's fill, so a long row is easy to follow; zero alpha for none
	float row_height;
	float text_size;
	float padding; // left and right inset inside a row
	float icon_size; // the square slot before the name; zero for no icons
	Vec4 radius;
}

const FileBrowserStyle DEFAULT_FILE_BROWSER_STYLE = {
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.directory = { 0.55, 0.75, 0.95, 1.0 },
	.size = { 0.45, 0.48, 0.56, 1.0 },
	.icon = { 0.62, 0.65, 0.72, 1.0 },
	.hover = { 0.28, 0.31, 0.40, 1.0 },
	.selected = { 0.95, 0.60, 0.20, 1.0 },
	.selected_text = { 0.05, 0.06, 0.09, 1.0 },
	.stripe = { 1.0, 1.0, 1.0, 0.025 },
	.row_height = 26.0,
	.text_size = 13.0,
	.padding = 8.0,
	.icon_size = 14.0,
	.radius = { 5, 5, 5, 5 },
};

fn FileBrowserStyle FileBrowserStyle.resolved(self)
{
	return self.row_height == 0.0f ? DEFAULT_FILE_BROWSER_STYLE : self;
}

<*
 One row of the listing. `name` is owned by the browser and freed on the next
 rescan; `size` is meaningless for a directory and is not drawn for one.
*>
struct FileEntry
{
	String name;
	bool is_dir;
	long size;
}

alias FileEntryList = List{FileEntry};

struct FileBrowser (Widget)
{
	<*
	 The directory being listed, absolute and without a trailing separator.

	 Owned. Set it with `go_to`, which is what re-reads the listing — assigning
	 to this leaves `entries` describing somewhere else.
	*>
	DString directory;

	<*
	 Where to open, or empty for the working directory.

	 A literal field rather than a `go_to` from whoever built the tree, because
	 `mount` runs at the element's first layout and the buffer `go_to` writes into
	 does not exist before that. Borrowed for as long as the element lives, like
	 every other string in a widget — a caller that remembers the last directory
	 keeps it, not this.
	*>
	String start;

	<*
	 Which files to show: a borrowed list of patterns, any one of which may match.
	 Each is literal text with at most one `*`, as in `{ "*.glb", "*.gltf" }`. An
	 empty list shows every file.

	 A list rather than one pattern because a format is rarely one extension, and
	 the grammar has room for exactly one wildcard — `*.gl*` is not expressible
	 and `*.gl` matches neither.

	 Applied to files only. A pattern handed to `path::ls` itself would filter the
	 directories out too, and a browser that cannot show you a folder cannot get
	 you to the file inside it.
	*>
	String[] mask;

	OnChoose on_choose; // optional; a second click on the selected row, or Return
	OnChoose on_select; // optional; whenever the selection moves

	<*
	 Called with the new directory whenever the listing moves, `go_to` included.

	 What a breadcrumb or a path field subscribes to. Separate from `on_select`
	 because walking into a folder drops the selection: something has to say
	 where the browser now is, and "nothing is selected" is not that.
	*>
	OnChoose on_directory;

	FileBrowserStyle style;

	<*
	 Hovered and selected rows, each as its index + 1 so the zero default means
	 "none" rather than "the first one" — the encoding the animation list uses,
	 and for the same reason: a browser that opens with its first file already
	 selected is a browser that can pick one by accident.
	*>
	int lit;
	int chosen;

	FileEntryList entries;

	// `..` occupies row 0 everywhere except the filesystem root, where there is
	// nowhere above to go. Cached rather than recomputed per row so paint, layout
	// and the hit test cannot disagree about what row 0 is.
	bool has_parent;
}

fn void FileBrowser.mount(&self, Element* elem) @dynamic
{
	self.directory.init(mem);
	self.entries.init(mem);

	if (self.start.len > 0)
	{
		self.directory.append_string(trim_separator(self.start));
	}
	else if (try Path here = path::cwd(mem))
	{
		// The working directory: where a program started from a shell was
		// pointed at, and the only guess available with nothing else said.
		defer here.free(mem);
		self.directory.append_string((String)here);
	}
	self.rescan();

	// So a breadcrumb or a path field is right on the first frame rather than
	// only after the first move — this is the browser's first move.
	if (self.on_directory) self.on_directory(elem.ui, self.directory.str_view());
}

fn void FileBrowser.unmount(&self, Element* elem) @dynamic
{
	self.drop_entries();
	self.entries.free();
	self.directory.free();
}

fn void FileBrowser.drop_entries(&self)
{
	foreach (entry : self.entries) alloc::free(mem, entry.name.ptr);
	self.entries.clear();
}

<*
 List `directory` and show it, dropping the selection.

 A missing or unreadable directory lists as empty rather than raising: a browser
 is how a user recovers from a bad path, so it has to survive being pointed at
 one. The parent row is still offered, which is what gets them back out.

 **`directory` may be a view into this browser's own buffer** — walking up hands
 in a slice of the very string being replaced, which is `activate`'s only way of
 saying "the folder above this one". It is copied before anything is cleared, so
 callers need not know.

 @param directory : `A trailing separator is trimmed. Relative paths are listed as given.`
*>
fn void FileBrowser.go_to(&self, Element* elem, String directory)
{
	// Into the temp allocator first: `clear` frees nothing, but `append_string`
	// into a buffer that overlaps its own source is an aliasing violation, and
	// the growth it may trigger would move the bytes out from under the slice.
	String wanted = trim_separator(directory).tcopy();

	self.directory.clear();
	self.directory.append_string(wanted);
	self.chosen = 0;
	self.lit = 0;
	self.rescan();

	// Both: the row count changed, so the height this widget reports has to be
	// measured again before anything is painted at it.
	elem.request_layout();
	elem.request_paint();

	// Last, so a callback that reads the browser sees where it actually is.
	if (self.on_directory) self.on_directory(elem.ui, self.directory.str_view());
}

<*
 Re-read the current directory. Directories first, each group in name order.

 The caller owns nothing: names are copied into the browser's own allocator and
 released by the next rescan or by `unmount`.
*>
fn void FileBrowser.rescan(&self)
{
	self.drop_entries();

	String here = self.directory.str_view();
	self.has_parent = here.len > 1;

	PathList? found = path::ls(mem, (Path)here);
	if (catch found) return;

	// Each entry carries its own copy of the name; the list's own free releases
	// the array that held them and not the names themselves.
	defer
	{
		foreach (entry : found) entry.free(mem);
		found.free();
	}

	foreach (entry : found)
	{
		String name = (String)entry;
		if (name.len == 0 || name == "." || name == "..") continue;

		// Dotfiles are noise in a model browser and there is no toggle for them
		// yet; the field to type a path is the way to reach one.
		if (name[0] == '.') continue;

		String full = string::format(mem, "%s/%s", here, name);
		defer alloc::free(mem, full.ptr);

		bool is_dir = path::is_dir((Path)full);
		if (!is_dir && !matches_any(name, self.mask)) continue;

		long size = 0;
		if (!is_dir)
		{
			if (try long measured = path::file_size((Path)full)) size = measured;
		}

		self.entries.push({ .name = name.copy(mem), .is_dir = is_dir, .size = size });
	}

	sort_entries(self.entries.array_view());
}

<*
 The absolute path of row `row`, or an empty string for the parent row and for a
 row that does not exist.

 The parent has no path of its own here because it is not an entry — it is a
 move, and `activate` is where it is made.

 The string is temporary: it lives in the temp allocator and is gone at the end
 of the current scope.
*>
fn String FileBrowser.path_of(&self, int row)
{
	usz index = self.entry_index(row);
	if (index >= self.count()) return "";
	return string::tformat("%s/%s", self.directory.str_view(), self.entries.get((sz)index).name);
}

<*
 Which row lists an entry of this name, or -1 for none.

 Names, not paths — how a caller says "select the file I just wrote" without
 knowing where the listing put it, and how a test says "click the models
 folder" without depending on what else is beside it.
*>
fn int FileBrowser.entry_at_name(&self, String name)
{
	foreach (usz i, entry : self.entries.array_view())
	{
		if (entry.name == name) return (int)i + (self.has_parent ? 1 : 0);
	}
	return -1;
}

<*
 How many rows the listing has, the parent row included.
*>
fn usz FileBrowser.rows(&self) => self.count() + (self.has_parent ? (usz)1 : (usz)0);

// `List.len` counts in `sz`; every index here is a `usz`, so the conversion
// lives in one place rather than at each use.
fn usz FileBrowser.count(&self) => (usz)self.entries.len();

<*
 A row's index into `entries`, or `count()` — one past the end — for the parent
 row and for a row that is not there. Callers test against `count()` rather than
 against a magic number, so there is nothing to keep in step.
*>
fn usz FileBrowser.entry_index(&self, int row)
{
	if (row < 0) return self.count();
	usz index = (usz)row;
	if (!self.has_parent) return index;
	return index == 0 ? self.count() : index - 1;
}

<*
 Do what row `row` is for: walk into a directory, go up from the parent row, or
 hand a file to `on_choose`.

 Selecting and activating are separate on purpose — a single click must not
 leave the directory the user is reading.
*>
fn void FileBrowser.activate(&self, Element* elem, int row)
{
	if (self.has_parent && row == 0)
	{
		self.go_to(elem, parent_of(self.directory.str_view()));
		return;
	}

	usz index = self.entry_index(row);
	if (index >= self.count()) return;

	String full = self.path_of(row);
	if (self.entries.get((sz)index).is_dir)
	{
		self.go_to(elem, full);
		return;
	}
	if (self.on_choose) self.on_choose(elem.ui, full);
}

fn Vec2 FileBrowser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	FileBrowserStyle style = self.style.resolved();
	// An empty folder keeps room under its rows for the note that says so.
	float note = self.count() == 0 ? EMPTY_NOTE_ROWS * style.row_height : 0.0f;
	return constraints.constrain({ constraints.max.x, (float)self.rows() * style.row_height + note });
}

// How many rows' height the empty-folder note takes.
const float EMPTY_NOTE_ROWS @private = 3.0;

fn void FileBrowser.paint(&self, Element* elem, Painter* painter) @dynamic
{
	FileBrowserStyle style = self.style.resolved();
	float width = elem.size.x;

	char[32] buffer;
	for (int row = 0; row < (int)self.rows(); row++)
	{
		float y = (float)row * style.row_height;
		// A listing is taller than its box whenever it was given one — no
		// Scroll above it, or a panel that capped it — and a widget painting
		// rows past its own rect is drawing over whatever is beside the panel.
		// Under a Scroll the box IS the content, so nothing is lost here.
		if (elem.size.y > 0 && y >= elem.size.y) break;
		bool selected = self.chosen == row + 1;
		bool lit      = self.lit == row + 1;

		RectStyle fill = { .border_radius = style.radius };
		if (selected)
		{
			fill.color = style.selected;
		}
		else if (lit)
		{
			fill.color = style.hover;
		}
		else if (row % 2 == 1)
		{
			fill.color = style.stripe;
		}
		if (fill.color.a > 0) painter.rect({ 0, y }, { width, style.row_height }, fill);

		usz index      = self.entry_index(row);
		bool is_parent = index >= self.count();
		bool is_dir    = is_parent || self.entries.get((sz)index).is_dir;
		String name    = is_parent ? ".." : self.entries.get((sz)index).name;

		Color ink = selected ? style.selected_text : style.text;
		Color dim = selected ? style.selected_text : style.size;

		// Vertically centred by eye against the row rather than measured: every
		// row is one line of one size, so the inset is a constant.
		float mid    = y + style.row_height * 0.5f;
		float text_y = mid - style.text_size * 0.5f - 1.0f;
		float x      = style.padding;

		if (style.icon_size > 0.0f)
		{
			Vec2 center = { x + style.icon_size * 0.5f, mid };
			if (is_parent)
			{
				paint_up_icon(painter, center, style.icon_size, selected ? style.selected_text : style.directory);
			}
			else if (is_dir)
			{
				paint_folder_icon(painter, center, style.icon_size, selected ? style.selected_text : style.directory);
			}
			else
			{
				paint_file_icon(painter, center, style.icon_size, selected ? style.selected_text : style.icon);
			}
			x += style.icon_size + 7.0f;
		}
		else if (is_dir && !is_parent)
		{
			// Without icons the trailing separator is the folder mark: it reads
			// the same in every font there is.
			name = string::tformat("%s/", name);
		}

		// The size column, measured first so a long name can stop short of it.
		String size_text = "";
		float size_w     = 0.0f;
		if (!is_dir)
		{
			if (try char[] written = human_size(buffer[..], self.entries.get((sz)index).size))
			{
				size_text = (String)written;
				size_w    = elem.ui.text.measure(0, size_text, style.text_size).x;
			}
		}
		float room = width - style.padding - x - (size_w > 0.0f ? size_w + 12.0f : 0.0f);

		if (is_parent)
		{
			painter.text_box({ x, text_y }, "Up one folder", { .size = style.text_size, .color = dim }, room, TextOverflow.ELLIPSIS);
		}
		else if (is_dir)
		{
			painter.text_box({ x, text_y }, name, { .size = style.text_size, .color = selected ? ink : style.directory }, room, TextOverflow.ELLIPSIS);
		}
		else
		{
			// The stem in full ink and the extension dimmed: in a folder of one
			// format the names are what differ, and the extension is a repeat.
			usz dot = extension_at(name);
			String stem = name[:dot];
			String ext  = name[dot..];
			float stem_w = elem.ui.text.measure(0, stem, style.text_size).x;
			float ext_w  = elem.ui.text.measure(0, ext, style.text_size).x;
			if (stem_w + ext_w <= room)
			{
				painter.text({ x, text_y }, stem, { .size = style.text_size, .color = ink });
				painter.text({ x + stem_w, text_y }, ext, { .size = style.text_size, .color = dim });
			}
			else
			{
				painter.text_box({ x, text_y }, name, { .size = style.text_size, .color = ink }, room, TextOverflow.ELLIPSIS);
			}
		}

		// Right-aligned, which is what makes a column of sizes comparable at a
		// glance rather than a ragged list of numbers.
		if (size_w > 0.0f)
		{
			painter.text({ width - style.padding - size_w, text_y }, size_text, { .size = style.text_size, .color = dim });
		}
	}

	if (self.count() == 0)
	{
		// Said in the space the files would have taken, so an empty folder reads
		// as empty rather than as a list that failed to load.
		String note = self.mask.len > 0 ? "No matching files in this folder" : "This folder is empty";
		float note_w = elem.ui.text.measure(0, note, style.text_size).x;
		float top    = (float)self.rows() * style.row_height + style.row_height;
		painter.text({ (width - note_w) * 0.5f, top }, note, { .size = style.text_size, .color = style.size });
	}
}

// Where a name's extension starts — its last '.', or the end for none. A leading
// dot is part of the name, not an extension.
fn usz extension_at(String name) @private
{
	for (usz i = name.len; i > 1; i--)
	{
		if (name[i - 1] == '.') return i - 1;
	}
	return name.len;
}

// A folder: a tab on the back's top-left and the front panel below it, `size`
// across and centred on `center`.
fn void paint_folder_icon(Painter* painter, Vec2 center, float size, Color color) @private
{
	float w = size;
	float h = size * 0.78f;
	Vec2 corner = center - (Vec2) { w * 0.5f, h * 0.5f };
	Color back = color;
	back.a *= 0.65f;
	painter.rect(corner, { w * 0.45f, h * 0.3f }, { .color = back, .border_radius = { 1.5f, 1.5f, 0, 0 } });
	painter.rect(corner + (Vec2) { 0, h * 0.18f }, { w, h * 0.82f }, { .color = color, .border_radius = { 1.5f, 2.0f, 2.0f, 2.0f } });
}

// A page with its top-right corner folded over, outlined in `color`.
fn void paint_file_icon(Painter* painter, Vec2 center, float size, Color color) @private
{
	float w    = size * 0.72f;
	float h    = size;
	float fold = w * 0.38f;
	float t    = 1.3f;
	Vec2 lo = center - (Vec2) { w * 0.5f, h * 0.5f };
	Vec2 hi = center + (Vec2) { w * 0.5f, h * 0.5f };
	painter.line({ lo.x, lo.y }, { hi.x - fold, lo.y }, t, color);
	painter.line({ hi.x - fold, lo.y }, { hi.x, lo.y + fold }, t, color);
	painter.line({ hi.x, lo.y + fold }, { hi.x, hi.y }, t, color);
	painter.line({ hi.x, hi.y }, { lo.x, hi.y }, t, color);
	painter.line({ lo.x, hi.y }, { lo.x, lo.y }, t, color);
	painter.line({ hi.x - fold, lo.y }, { hi.x - fold, lo.y + fold }, t, color);
	painter.line({ hi.x - fold, lo.y + fold }, { hi.x, lo.y + fold }, t, color);
	// Two text lines, so the page reads as a document rather than a box.
	float inset = w * 0.22f;
	painter.line({ lo.x + inset, center.y + h * 0.08f }, { hi.x - inset, center.y + h * 0.08f }, t * 0.8f, color);
	painter.line({ lo.x + inset, center.y + h * 0.28f }, { hi.x - inset, center.y + h * 0.28f }, t * 0.8f, color);
}

// An arrow bending up and back: the parent row's "out of here".
fn void paint_up_icon(Painter* painter, Vec2 center, float size, Color color) @private
{
	float s = size * 0.5f;
	float t = 1.6f;
	Vec2 tip = { center.x - s * 0.35f, center.y - s * 0.85f };
	painter.line(tip, { tip.x - s * 0.5f, tip.y + s * 0.5f }, t, color);
	painter.line(tip, { tip.x + s * 0.5f, tip.y + s * 0.5f }, t, color);
	painter.line(tip, { tip.x, center.y + s * 0.6f }, t, color);
	painter.line({ tip.x, center.y + s * 0.6f }, { center.x + s * 0.9f, center.y + s * 0.6f }, t, color);
}

<*
 Which row a point is in, or -1 for none. Shared by paint's hover highlight and
 `on_mouse`, so the two cannot disagree about where a row starts.
*>
fn int FileBrowser.row_at(&self, Element* elem, Vec2 pos)
{
	FileBrowserStyle style = self.style.resolved();
	if (pos.x < 0 || pos.x >= elem.size.x || pos.y < 0) return -1;

	int row = (int)(pos.y / style.row_height);
	return row >= 0 && row < (int)self.rows() ? row : -1;
}

fn bool FileBrowser.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case MOVE:
			int row = self.row_at(elem, event.pos);
			int lit = row < 0 ? 0 : row + 1;
			if (lit != self.lit)
			{
				self.lit = lit;
				elem.request_paint();
			}
			return false; // hover is not a consumed event; a drag through still scrolls
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;

			int row = self.row_at(elem, event.pos);
			if (row < 0) return true; // a click in the empty tail is still the list's

			elem.request_focus();
			if (self.chosen == row + 1)
			{
				self.activate(elem, row);
				return true;
			}

			self.chosen = row + 1;
			elem.request_paint();
			if (self.on_select) self.on_select(elem.ui, self.path_of(row));
			return true;
		default:
			return false;
	}
}

// Leaving the list produces no MOVE, so the highlight would stay lit on the row
// the pointer left through.
fn void FileBrowser.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

<*
 Arrow keys move the selection, Return activates it.

 Everything else is declined, so a dialog's ESC and an application's shortcuts
 still reach them — unlike `TextField`, a browser is not typing anything and has
 no claim on the keyboard beyond these three.
*>
fn bool FileBrowser.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down || self.rows() == 0) return false;

	switch (event.key)
	{
		case Key.UP_ARROW:
			self.chosen = self.chosen > 1 ? self.chosen - 1 : 1;
		case Key.DOWN_ARROW:
			self.chosen = self.chosen < (int)self.rows() ? self.chosen + 1 : (int)self.rows();
		case Key.RETURN:
		case Key.KP_RETURN:
			if (self.chosen > 0) self.activate(elem, self.chosen - 1);
			return true;
		default:
			return false;
	}

	elem.request_paint();
	if (self.on_select && self.chosen > 0) self.on_select(elem.ui, self.path_of(self.chosen - 1));
	return true;
}

// ---------------------------------------------------------------------------
// Paths and names

<*
 The directory above `directory`, or `directory` itself when it is the root.

 Borrowed from the argument, so it stays valid exactly as long as that does —
 which is why `go_to` copies before it clears the buffer it was handed a slice
 of. Getting that order wrong walks the browser to an empty string.
*>
fn String parent_of(String directory)
{
	usz cut = 0;
	foreach (i, c : directory)
	{
		if (c == '/' || c == '\\') cut = (usz)i;
	}
	// The root's own separator is part of it: "/usr" goes to "/", not to "".
	return cut == 0 ? "/" : directory[:cut];
}

// Without a trailing separator, so joining is always "%s/%s" and never yields
// "//name" — which is a legitimate path on POSIX but reads as a mistake.
fn String trim_separator(String directory) @private
{
	if (directory.len > 1 && (directory[^1] == '/' || directory[^1] == '\\'))
	{
		return directory[:directory.len - 1];
	}
	return directory;
}

<*
 Whether `name` matches any pattern in `mask`. An empty list matches everything,
 which is what a browser with no filter set shows.
*>
fn bool matches_any(String name, String[] mask)
{
	if (mask.len == 0) return true;
	foreach (pattern : mask)
	{
		if (matches_mask(name, pattern)) return true;
	}
	return false;
}

<*
 Whether `name` matches one `path::ls`-style pattern: literal text with at most
 one `*`. An empty pattern matches everything.

 Written here rather than borrowed from `ls` because the filter has to be applied
 to files alone — see `FileBrowser.mask`.
*>
fn bool matches_mask(String name, String mask)
{
	if (mask.len == 0) return true;

	usz star = mask.len;
	foreach (i, c : mask)
	{
		if (c == '*')
		{
			star = (usz)i;
			break;
		}
	}
	if (star == mask.len) return name == mask;

	String head = mask[:star];
	String tail = mask[star + 1..];
	if (name.len < head.len + tail.len) return false;
	return name[:head.len] == head && name[name.len - tail.len..] == tail;
}

// Directories above files, each group in byte order. Insertion sort: a listing
// is short, and this keeps the comparison in one place rather than behind a
// callback that would have to be a file-scope function.
fn void sort_entries(FileEntry[] entries) @private
{
	for (usz i = 1; i < entries.len; i++)
	{
		FileEntry moving = entries[i];
		usz j            = i;
		while (j > 0 && after(entries[j - 1], moving))
		{
			entries[j] = entries[j - 1];
			j--;
		}
		entries[j] = moving;
	}
}

fn bool after(FileEntry a, FileEntry b) @private
{
	if (a.is_dir != b.is_dir) return !a.is_dir;

	usz shared = a.name.len < b.name.len ? a.name.len : b.name.len;
	for (usz i = 0; i < shared; i++)
	{
		if (a.name[i] != b.name[i]) return a.name[i] > b.name[i];
	}
	return a.name.len > b.name.len;
}

// Three significant figures at most, which is as much as a size column is ever
// read for. Binary units, since that is what a file manager on every platform
// this runs on reports.
fn char[]? human_size(char[] buffer, long bytes) @private
{
	if (bytes < 1024) return io::bprintf(buffer, "%d B", bytes);

	double scaled   = (double)bytes;
	String[3] units = { "KB", "MB", "GB" };
	usz unit        = 0;
	while (unit < 2 && scaled >= 1024.0 * 1024.0)
	{
		scaled /= 1024.0;
		unit++;
	}
	scaled /= 1024.0;

	return scaled < 10.0 ? io::bprintf(buffer, "%.1f %s", scaled, units[unit])
		: io::bprintf(buffer, "%.0f %s", scaled, units[unit]);
}