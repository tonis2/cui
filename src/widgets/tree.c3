<*
 Tree: an indented list of rows, one of them selected, some of them collapsible.

 The sidebar shape — a catalogue, an outline, a set of categories. Rows are given
 flat, each carrying the depth it sits at, rather than as a structure of nodes
 with children. That is deliberate: the thing a caller has is almost always
 already a flat list it can derive a depth from, and a tree of nodes would make
 it build and free a parallel structure on every change just to hand it over.

 **Collapsing is the caller's to do.** A row marked `expandable` draws a
 disclosure mark and reports a click on it through `on_toggle`; what a caller
 does with that is rebuild the rows without the ones underneath. The widget does
 not hide rows itself, because it cannot know which of the rows after a heading
 belong to it — that is what the caller's own data says.

 Rows are borrowed for the life of the element, the way `MenuBar` borrows its
 menus: the array and every `label` in it must outlive the widget. A caller
 building rows per frame wants to hold them somewhere that lasts.

 Content-sized, so it sits under a `Scroll` — the shape every list in cui takes.
*>
module cui::widgets;

import cui;
import cui::icons;
import std::math;

<*
 What a row's right-click reports: which row, and where the press landed in
 window coordinates — the point a context menu opens at.
*>
alias OnRowAt = fn void(Ui* ui, usz row, Vec2 at);

<*
 What a click on one of a row's toggle columns reports: which row, and which
 column, counted from the right edge.
*>
alias OnRowToggle = fn void(Ui* ui, usz row, usz column);

<*
 Draws one of the caller's icons centred on `center`, `size` px across. Icons are
 the caller's own numbers: cui has no icon set, so what an icon looks like is
 whatever the caller paints for it. `dim` is set for a toggle that is off.
*>
alias TreePaintIcon = fn void(Painter* painter, Vec2 center, float size, ushort icon, bool dim);

<*
 What a left-click on a row reports when the caller wants the modifier keys too:
 shift to extend a selection, ctrl to toggle one row in or out. Set, it is called
 *instead of* `on_select`.
*>
alias OnRowMods = fn void(Ui* ui, usz row, Modifiers mods);

<*
 One entry of a Tree's icon table: an SVG on an 18-unit viewBox, tinted `color`.
 A toggle that is off draws `svg_off` instead when there is one (an open eye and
 a shut one), tinted `dim` (zero `dim` falls back to `color`). The strings are
 borrowed for as long as the Ui lives — the icon atlas is keyed by them.
*>
struct TreeIcon
{
	String svg;
	Color color;
	Color dim;
	String svg_off;
}

// Tree icons are drawn for a 14 px slot on an 18-unit viewBox, so the strokes fit.
const float TREE_ICON_VIEW_SCALE = 18.0f / 14.0f;

// How many toggle columns a row can carry at its right edge — an eye and one more.
const usz TREE_TOGGLES = 2;

struct TreeStyle
{
	Color text;
	Color selected; // the fill behind the selected row
	Color selected_text;
	Color hover;
	Color trailing; // the right-hand column: a count, a size, a note
	Color mark; // the disclosure triangle
	float row_height;
	float text_size;
	float padding; // left and right inset inside a row
	float indent; // per level of depth
	Vec4 radius;
	// The rest is optional: a zero leaves each one out, so a style written before
	// they existed draws the same tree it always did.
	Color highlighted; // the fill behind a row lit as part of a larger selection
	Color guide; // the thin lines down each level's children
	Color alternate; // the shade behind every other row
	float icon_size; // the square slot before a label that has an icon
	float toggle_width; // one right-edge toggle column
}

const TreeStyle DEFAULT_TREE_STYLE = {
	.text = { 0.92, 0.93, 0.95, 1.0 },
	.selected = { 0.95, 0.60, 0.20, 1.0 },
	.selected_text = { 0.05, 0.06, 0.09, 1.0 },
	.hover = { 0.28, 0.31, 0.40, 1.0 },
	.trailing = { 0.45, 0.48, 0.56, 1.0 },
	.mark = { 0.45, 0.48, 0.56, 1.0 },
	.row_height = 22.0,
	.text_size = 13.0,
	.padding = 8.0,
	.indent = 14.0,
	.radius = { 4, 4, 4, 4 },
};

// All or nothing, the convention every style struct here follows: a zero style
// takes the default whole rather than being merged into it field by field.
fn TreeStyle TreeStyle.resolved(self)
{
	return self.row_height == 0.0f ? DEFAULT_TREE_STYLE : self;
}

<*
 One row.

 `label` and `trailing` are borrowed and must outlive the widget. `trailing` is
 drawn right-aligned and skipped when empty — a count beside a category, or
 nothing.

 `expanded` is only read when `expandable` is set, and only decides which way the
 disclosure mark points. Nothing is hidden by it here; see this file's header.
*>
struct TreeRow
{
	String label;
	String trailing;
	usz depth;
	bool expandable;
	bool expanded;
	// Zero for none. Drawn by `Tree.paint_icon` in a slot before the label.
	ushort icon;
	// Lit as part of a selection of several; `Tree.selected` stays the active one.
	bool highlighted;
	// Right-edge switches, column 0 outermost — an eye, say. Unshown columns leave
	// their space empty, so the columns of different rows still line up.
	TreeToggle[TREE_TOGGLES] toggles;
}

struct TreeToggle
{
	ushort icon;
	bool on;
	bool shown;
}

<*
 This row with its own copies of `label` and `trailing`, for a row that outlives
 what it was made from. `free_tree_rows` frees them.
*>
fn TreeRow TreeRow.owned(self)
{
	TreeRow row = self;
	row.label = self.label.len > 0 ? self.label.copy(mem) : "";
	row.trailing = self.trailing.len > 0 ? self.trailing.copy(mem) : "";
	return row;
}

<*
 Frees rows made with `TreeRow.owned`, and their array.

 @param [&inout] rows : "Left empty"
*>
fn void free_tree_rows(TreeRow[]* rows)
{
	foreach (row : *rows)
	{
		if (row.label.len > 0) row.label.free(mem);
		if (row.trailing.len > 0) row.trailing.free(mem);
	}
	if (rows.len > 0) alloc::free(mem, *rows);
	*rows = { };
}

<*
 An indented list of rows with one selected.

 `selected` is a position in `rows`, or past its end for none — which is what a
 zero-initialised Tree with no rows is, so nothing is selected until something
 says so.
*>
struct Tree (Widget)
{
	TreeRow[] rows;
	usz selected;
	OnIndex on_select;
	OnIndex on_toggle;
	// A right-press on a row. Unset, the press is not the tree's and falls through
	// to whatever is behind it — a pane's own menu, say.
	OnRowAt on_context;
	// A click on a shown toggle column. Unset, the click selects the row instead.
	OnRowToggle on_row_toggle;
	// A left-click with the modifier keys, in place of `on_select` when set.
	OnRowMods on_pick;
	// Paints row and toggle icons. Unset, the `icons` table paints them, and with
	// neither there is no icon slot.
	TreePaintIcon paint_icon;
	// Icons by number, `icons[icon - 1]`: how a host that cannot hand over a
	// function pointer — a script — still draws its own. Borrowed.
	TreeIcon[] icons;
	TreeStyle style;

	// The row under the pointer as its index + 1, so the zero default means "none"
	// rather than "the first row" — the FileBrowser encoding.
	int lit;
}

<*
 Sizes to the rows: as wide as it was offered, as tall as they come to.

 Width is taken rather than measured because a sidebar's width is the caller's
 decision — a column that changed width when a longer category appeared would
 move the grid beside it.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The offered width, and the height every row needs.`
*>
fn Vec2 Tree.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	TreeStyle style = self.style.resolved();
	return constraints.constrain({ constraints.max.x, (float)self.rows.len * style.row_height });
}

<*
 Which row a point is in, or -1 for none.

 Shared by paint's hover highlight and `on_mouse`, so the two cannot disagree
 about where a row starts.
*>
fn int Tree.row_at(&self, Element* elem, Vec2 pos) => fixed_row_at(elem, pos, self.style.resolved().row_height, self.rows.len);

<*
 The row a point is in, for rows of one height, or -1. Tree and FileBrowser.
*>
fn int fixed_row_at(Element* elem, Vec2 pos, float row_height, usz rows)
{
	if (pos.x < 0 || pos.x >= elem.size.x || pos.y < 0) return -1;
	int row = (int)(pos.y / row_height);
	return row < (int)rows ? row : -1;
}

<*
 Lights `row` (-1: none) in a field that keeps it as index + 1, so zero is
 none; repaints on a change.
*>
fn void light_row(Element* elem, int* lit, int row)
{
	int want = row < 0 ? 0 : row + 1;
	if (want == *lit) return;
	*lit = want;
	elem.request_paint();
}

// Where a row's text starts, given how deep it sits. The disclosure mark lives in
// the indent step immediately left of it, which is why an expandable row does not
// need a wider inset than a plain one at the same depth.
//
// A top-level row that opens has nowhere left of its label for its mark, so a
// tree with one sets every row one step in: the mark stays inside the tree and
// clickable rather than hanging off its left edge.
fn float Tree.text_x(&self, TreeStyle style, usz depth)
{
	return style.padding + (float)(depth + self.lead()) * style.indent;
}

// One when a depth-0 row is expandable, else nothing.
fn usz Tree.lead(&self)
{
	foreach (row : self.rows) if (row.depth == 0 && row.expandable) return 1;
	return 0;
}

// Whether icons can be drawn at all: a painter, or a table to draw from.
fn bool Tree.has_icons(&self) => self.paint_icon != null || self.icons.len > 0;

// One icon, from the caller's painter if it gave one and from the table otherwise.
fn void Tree.draw_icon(&self, Painter* painter, Vec2 center, float size, ushort icon, bool dim)
{
	if (self.paint_icon)
	{
		self.paint_icon(painter, center, size, icon, dim);
		return;
	}
	if (icon == 0 || (usz)icon > self.icons.len) return;
	TreeIcon entry = self.icons[icon - 1];
	Color ink = dim && ((Vec4)entry.dim).w > 0.0f ? entry.dim : entry.color;
	String svg = dim && entry.svg_off.len > 0 ? entry.svg_off : entry.svg;
	painter.icon(center, size * TREE_ICON_VIEW_SCALE, svg, ink);
}

<*
 The part of this tree that can be seen, as a range of local y: the element's own
 extent narrowed by every clipping ancestor — the Scroll it sits in, a dialog's
 panel. A tree of thousands of rows paints only the rows inside it.

 Valid while painting: emit sets an element's `absolute` before it paints, and an
 ancestor's before any of its children. What it cannot see is the scroll moving,
 since a wheel tick re-emits cached drawings without painting; `Scroll` repaints
 the trees under it for that (`repaint_trees`).
*>
fn Vec2 Tree.visible_band(&self, Element* elem)
{
	float top    = 0.0f;
	float bottom = elem.size.y;
	for (Element* up = elem.parent; up != null; up = up.parent)
	{
		if (!up.clips) continue;
		top    = math::max(top, up.absolute.y - elem.absolute.y);
		bottom = math::min(bottom, up.absolute.y + up.size.y - elem.absolute.y);
	}
	return { top, math::max(bottom, top) };
}

// A range of rows: `first` up to, not including, `last`.
struct TreeSpan
{
	usz first;
	usz last;
}

// The first row a band can touch and one past the last, with a row of slack each
// side so a half-shown row never pops.
fn TreeSpan Tree.rows_in(&self, TreeStyle style, Vec2 band)
{
	int first = math::max((int)(band.x / style.row_height) - 1, 0);
	int last  = math::min((int)(band.y / style.row_height) + 2, (int)self.rows.len);
	return { (usz)first, (usz)math::max(last, first) };
}

<*
 Whether a point is on a row's disclosure mark rather than on the row itself.

 The mark is the width of one indent step, sitting left of the label. A click
 there toggles; a click anywhere else on the row selects. Two targets in one row,
 which is what lets a category be opened without also being selected.
*>
fn bool Tree.on_mark(&self, TreeStyle style, usz row, Vec2 pos)
{
	if (row >= self.rows.len || !self.rows[row].expandable) return false;
	float left = self.text_x(style, self.rows[row].depth) - style.indent;
	return pos.x >= left && pos.x < left + style.indent;
}

<*
 How many toggle columns the tree sets aside at its right edge: as many as the
 widest row shows, so every row's columns — and its trailing note — line up.
*>
fn usz Tree.toggle_columns(&self)
{
	usz columns = 0;
	foreach (row : self.rows)
	{
		for (usz c = columns; c < TREE_TOGGLES; c++) if (row.toggles[c].shown) columns = c + 1;
	}
	return columns;
}

<*
 The toggle column a point is on, or -1 for none. Only a shown toggle is a
 target; the space of an unshown one is part of the row.
*>
fn int Tree.toggle_at(&self, Element* elem, TreeStyle style, usz row, Vec2 pos)
{
	if (row >= self.rows.len || style.toggle_width <= 0.0f) return -1;
	float right = elem.size.x - style.padding;
	if (pos.x >= right) return -1;
	int column = (int)((right - pos.x) / style.toggle_width);
	if (column >= (int)TREE_TOGGLES || !self.rows[row].toggles[column].shown) return -1;
	return column;
}

// The label's x once the icon slot, if the row has one, is stepped over.
fn float Tree.label_x(&self, TreeStyle style, TreeRow row)
{
	float x = self.text_x(style, row.depth);
	if (row.icon != 0 && self.has_icons() && style.icon_size > 0.0f) x += style.icon_size + 5.0f;
	return x;
}

// A disclosure chevron, `size` wide when open: right when closed, down when open.
fn void paint_chevron(Painter* painter, Vec2 center, float size, bool open, Color color)
{
	painter.icon(center, size * 2, open ? icons::CHEVRON_DOWN : icons::CHEVRON_RIGHT, color);
}

fn void Tree.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TreeStyle style = self.style.resolved();
	usz columns     = self.toggle_columns();
	float right     = elem.size.x - style.padding - (float)columns * style.toggle_width;

	TreeSpan span = self.rows_in(style, self.visible_band(elem));
	for (usz i = span.first; i < span.last; i++)
	{
		TreeRow row  = self.rows[i];
		float y      = (float)i * style.row_height;
		bool chosen  = i == self.selected;
		bool lit     = row.highlighted && !chosen && style.highlighted.w > 0.0f;
		bool hovered = self.lit == (int)i + 1 && !chosen && !lit;

		if (i % 2 == 1 && style.alternate.w > 0.0f)
		{
			painter.rect({ 0, y }, { elem.size.x, style.row_height }, { .color = style.alternate });
		}
		if (chosen || lit || hovered)
		{
			painter.rect(
				{ 0, y },
				{ elem.size.x, style.row_height },
				{
					.color = chosen ? style.selected : lit ? style.highlighted : style.hover,
					.border_radius = style.radius,
				}
			);
		}

		float mid    = y + style.row_height * 0.5f;
		float text_y = y + (style.row_height - style.text_size) * 0.5f - 1.0f;
		float x      = self.text_x(style, row.depth);

		// One line down the column of every level this row sits under, where that
		// level's chevrons are, so a long run of children still reads as one group.
		if (style.guide.w > 0.0f)
		{
			for (usz level = 0; level < row.depth; level++)
			{
				float gx = self.text_x(style, level) - style.indent * 0.5f;
				if (gx <= 0.0f) continue;
				painter.line({ gx, y }, { gx, y + style.row_height }, 1.0f, style.guide);
			}
		}

		if (row.expandable)
		{
			// Left of the label in the indent its children will sit at, so the marks
			// of one level line up down the column whatever their labels are.
			paint_chevron(
				painter,
				{ x - style.indent * 0.5f, mid },
				math::min(style.indent, style.row_height) * 0.45f,
				row.expanded,
				chosen ? style.selected_text : style.mark
			);
		}

		if (row.icon != 0 && self.has_icons() && style.icon_size > 0.0f)
		{
			self.draw_icon(painter, { x + style.icon_size * 0.5f, mid }, style.icon_size, row.icon, false);
		}

		// A label longer than the room between its icon and what is on the right —
		// the trailing note, the switches — is cut with an ellipsis rather than
		// painted over them.
		float label_at = self.label_x(style, row);
		float note_w = row.trailing.len > 0 ? elem.ui.text.measure(0, row.trailing, style.text_size).x + 8.0f : 0.0f;
		painter.text_box(
			{ label_at, text_y },
			row.label,
			{
				.size = style.text_size,
				.color = chosen ? style.selected_text : style.text,
			},
			right - note_w - label_at,
			ELLIPSIS
		);

		for (usz c = 0; c < columns && self.has_icons(); c++)
		{
			TreeToggle toggle = row.toggles[c];
			if (!toggle.shown) continue;
			float cx = elem.size.x - style.padding - ((float)c + 0.5f) * style.toggle_width;
			self.draw_icon(painter, { cx, mid }, style.icon_size, toggle.icon, !toggle.on);
		}

		if (row.trailing.len == 0) continue;
		float trailing_w = elem.ui.text.measure(0, row.trailing, style.text_size).x;
		painter.text(
			{ right - trailing_w, text_y },
			row.trailing,
			{
				.size = style.text_size,
				.color = chosen ? style.selected_text : style.trailing,
			}
		);
	}
}

fn bool Tree.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	TreeStyle style = self.style.resolved();

	switch (event.kind)
	{
		case MOVE:
			light_row(elem, &self.lit, self.row_at(elem, event.pos));
			// Hover is not a consumed event: a drag through a sidebar still scrolls
			// the Scroll around it.
			return false;

		case PRESS:
			if (event.button == MouseButton.RIGHT)
			{
				if (!self.on_context) return false;
				int row = self.row_at(elem, event.pos);
				// Past the last row there is nothing to ask about: left for the panel
				// behind, so an empty tail still opens that panel's menu.
				if (row < 0) return false;
				self.on_context(elem.ui, (usz)row, elem.absolute + event.pos);
				return true;
			}
			if (event.button != MouseButton.LEFT) return false;

			int row = self.row_at(elem, event.pos);
			// A click in the empty tail below the last row is still the list's — it
			// is not a hole through to whatever is behind it.
			if (row < 0) return true;

			if (self.on_mark(style, (usz)row, event.pos))
			{
				if (self.on_toggle) self.on_toggle(elem.ui, (usz)row);
				return true;
			}

			// A switch on the row changes that one thing and leaves the selection
			// where it was — hiding the mesh is not choosing it.
			int column = self.on_row_toggle ? self.toggle_at(elem, style, (usz)row, event.pos) : -1;
			if (column >= 0)
			{
				self.on_row_toggle(elem.ui, (usz)row, (usz)column);
				return true;
			}

			// Set here as well as reported, so a caller that only wants the selection
			// drawn does not have to write it back. One that rebuilds its rows will
			// set it again anyway, and setting it twice costs nothing.
			self.selected = (usz)row;
			elem.request_paint();
			if (self.on_pick)
			{
				self.on_pick(elem.ui, (usz)row, event.mods);
			}
			else if (self.on_select)
			{
				self.on_select(elem.ui, (usz)row);
			}
			elem.request_focus();
			return true;

		default:
			return false;
	}
}

// Leaving the list produces no MOVE, so the highlight would stay lit on the row
// the pointer left through.
fn void Tree.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (!entered) light_row(elem, &self.lit, -1);
}

<*
 Up and down move the selection by a row, left and right close and open the row
 that has children (a second left on a closed row is left alone: there is no
 parent link to climb), and space flips the first toggle of the selected row.

 Everything else is declined, so a dialog's ESC and an application's shortcuts
 still reach them.
*>
fn bool Tree.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down || self.rows.len == 0) return false;
	usz at = self.selected < self.rows.len ? self.selected : 0;

	switch (event.key)
	{
		case Key.UP_ARROW:
			at = self.selected < self.rows.len && at > 0 ? at - 1 : at;
		case Key.DOWN_ARROW:
			at = self.selected < self.rows.len && at + 1 < self.rows.len ? at + 1 : at;
		case Key.LEFT_ARROW:
			if (self.selected < self.rows.len && self.rows[at].expandable && self.rows[at].expanded && self.on_toggle)
			{
				self.on_toggle(elem.ui, at);
				return true;
			}
			return false;
		case Key.RIGHT_ARROW:
			if (self.selected < self.rows.len && self.rows[at].expandable && !self.rows[at].expanded && self.on_toggle)
			{
				self.on_toggle(elem.ui, at);
				return true;
			}
			return false;
		case Key.SPACE:
			if (self.selected < self.rows.len && self.rows[at].toggles[0].shown && self.on_row_toggle)
			{
				self.on_row_toggle(elem.ui, at, 0);
				return true;
			}
			return false;
		default:
			return false;
	}

	self.selected = at;
	elem.request_paint();
	if (self.on_pick)
	{
		self.on_pick(elem.ui, at, {});
	}
	else if (self.on_select)
	{
		self.on_select(elem.ui, at);
	}
	return true;
}

// ---------------------------------------------------------------------------

<*
 Asked at every build for the rows an `EmptyStateTree` shows, and which one
 starts selected (past the end for none). The rows are copied, so the answer
 may borrow — and may be freed before the next build.
*>
alias TreeRowsFn = fn TreeRow[](Element* elem, usz* selected);

<*
 A Tree that says so when it has no rows.

 A bare `Tree` with no rows lays out flat and paints nothing, which inside a
 bordered box reads as a panel that failed to build. This one is as wide as it
 is offered and paints `empty` where the rows would be.

 `@node((EmptyStateTree) { .rows_of = &plan_rows, .empty = "No plans.", .style = STYLE })`

 The Tree is its only child and gets `tree_id`, so a caller finds and drives it
 as it would a bare Tree. `request_build` on this element asks for the rows again.
*>
struct EmptyStateTree (Widget)
{
	TreeRowsFn rows_of;
	OnIndex on_select;
	TreeStyle style;
	String empty; // borrowed; painted in place of the rows
	Color empty_color;
	String tree_id; // borrowed; given to the Tree child when set

	TreeRow[] rows; // owned copy of the last build's rows
}

fn Element* EmptyStateTree.build(&self, Element* elem) @dynamic
{
	usz selected    = ~(usz)0; // none, unless the answer says otherwise
	TreeRow[] given = self.rows_of(elem, &selected);
	free_tree_rows(&self.rows);
	if (given.len > 0)
	{
		self.rows = alloc::new_array(mem, TreeRow, (sz)given.len);
		foreach (usz i, row : given) self.rows[i] = row.owned();
	}

	return @subtree(elem.ui)
	{
		Element* tree = @node(
			(Tree) {
				.rows = self.rows,
				.selected = selected,
				.on_select = self.on_select,
				.style = self.style,
			}
		);
		if (self.tree_id.len > 0) tree.with_id(self.tree_id);
	};
}

fn Vec2 EmptyStateTree.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, 0 });

	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ constraints.max.x, inner.y });
}

fn void EmptyStateTree.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.rows.len > 0) return;
	painter.text(
		{ self.style.padding, self.style.padding },
		self.empty,
		{
			.size = self.style.text_size,
			.color = self.empty_color,
		}
	);
}

fn void EmptyStateTree.unmount(&self, Element* elem) @dynamic => free_tree_rows(&self.rows);