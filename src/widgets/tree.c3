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
import std::math;

<*
 What a row's click reports: which row, by position in the array given.
*>
alias OnRow = fn void(Ui* ui, usz row);

struct TreeStyle
{
	Color text;
	Color selected;      // the fill behind the selected row
	Color selected_text;
	Color hover;
	Color trailing;      // the right-hand column: a count, a size, a note
	Color mark;          // the disclosure triangle
	float row_height;
	float text_size;
	float padding;       // left and right inset inside a row
	float indent;        // per level of depth
	Vec4 radius;
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
	OnRow on_select;
	OnRow on_toggle;
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
fn int Tree.row_at(&self, Element* elem, Vec2 pos)
{
	TreeStyle style = self.style.resolved();
	if (pos.x < 0 || pos.x >= elem.size.x || pos.y < 0) return -1;

	int row = (int)(pos.y / style.row_height);
	return row >= 0 && row < (int)self.rows.len ? row : -1;
}

// Where a row's text starts, given how deep it sits. The disclosure mark lives in
// the indent step immediately left of it, which is why an expandable row does not
// need a wider inset than a plain one at the same depth.
fn float Tree.text_x(&self, TreeStyle style, usz depth)
{
	return style.padding + (float)depth * style.indent;
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

fn void Tree.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TreeStyle style = self.style.resolved();

	foreach (usz i, row : self.rows)
	{
		float y = (float)i * style.row_height;
		bool chosen = i == self.selected;
		bool hovered = self.lit == (int)i + 1 && !chosen;

		if (chosen || hovered)
		{
			painter.rect({ 0, y }, { elem.size.x, style.row_height }, {
				.color = chosen ? style.selected : style.hover,
				.border_radius = style.radius,
			});
		}

		float text_y = y + (style.row_height - style.text_size) * 0.5f - 1.0f;
		float x = self.text_x(style, row.depth);

		if (row.expandable)
		{
			// Left of the label in the indent its children will sit at, so the marks
			// of one level line up down the column whatever their labels are.
			painter.text({ x - style.indent, text_y }, row.expanded ? "v" : ">", {
				.size = style.text_size,
				.color = chosen ? style.selected_text : style.mark,
			});
		}

		painter.text({ x, text_y }, row.label, {
			.size = style.text_size,
			.color = chosen ? style.selected_text : style.text,
		});

		if (row.trailing.len == 0) continue;
		float trailing_w = elem.ui.text.measure(0, row.trailing, style.text_size).x;
		painter.text({ elem.size.x - style.padding - trailing_w, text_y }, row.trailing, {
			.size = style.text_size,
			.color = chosen ? style.selected_text : style.trailing,
		});
	}
}

fn bool Tree.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	TreeStyle style = self.style.resolved();

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
			// Hover is not a consumed event: a drag through a sidebar still scrolls
			// the Scroll around it.
			return false;

		case PRESS:
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

			// Set here as well as reported, so a caller that only wants the selection
			// drawn does not have to write it back. One that rebuilds its rows will
			// set it again anyway, and setting it twice costs nothing.
			self.selected = (usz)row;
			elem.request_paint();
			if (self.on_select) self.on_select(elem.ui, (usz)row);
			return true;

		default:
			return false;
	}
}

// Leaving the list produces no MOVE, so the highlight would stay lit on the row
// the pointer left through.
fn void Tree.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}
