<*
 Grid: children flowed into rows of a fixed cell size, wrapping at the width.

 The wrapping sibling of Row and Column. Where a Row lays its children out at
 whatever size they ask for and runs off the edge, a Grid gives every child the
 same box and starts a new line when the next one will not fit — a gallery, a
 palette, a sheet of thumbnails.

 **Every cell is the same size, and the cell size is the Grid's, not the child's.**
 Children are laid out tight to `cell`, so a widget that would rather be bigger
 is not; that is what keeps the columns aligned, which is the whole reason to use
 this rather than a Row that wraps.

 Cells are real elements, so hover, cursor and hit-testing are per-cell and come
 free. A widget that paints all its cells itself has to hit-test them itself, and
 then paint and the hit test are two copies of the same arithmetic that can
 disagree about where a cell is. This has one copy, in `layout`.

 Content-sized in height, so it sits under a `Scroll` the way `FileBrowser` does.
 There is no virtualisation: every child is an element whether or not it is on
 screen. A caller with thousands of items should hand it the page it means to
 show rather than all of them.
*>
module cui::widgets;

import cui;
import std::math;

<*
 A wrapping grid of equally sized cells.

 `cell` is required — a zero on either axis leaves nothing to divide the width
 by, and the grid lays out as a single column of collapsed children rather than
 failing, since a widget mid-build has nowhere to report to.

 `size` follows the same convention as Row and Column: zero on an axis wraps the
 content, non-zero fixes it *and* is what the children are offered.
*>
struct Grid (Widget)
{
	Vec2 cell;
	float gap_x;
	float gap_y;
	Vec2 size; // per axis: 0 = wrap content
}

<*
 How many cells fit across `width`.

 Gaps sit between cells and not after the last, so the width needed for `n` of
 them is `n * cell.x + (n - 1) * gap_x` — which is why the width has one gap
 added before the division rather than the count having one subtracted after it.

 At least one, always. A viewport narrower than a single cell shows that cell cut
 off by the clip around it, which reads as "too narrow"; zero columns would show
 an empty panel, which reads as "nothing here".

 @param width : `The room available across.`
 @return `The column count, one or more.`
*>
fn usz Grid.columns(&self, float width)
{
	if (self.cell.x <= 0) return 1;
	float usable = width + self.gap_x;
	usz across = (usz)(usable / (self.cell.x + self.gap_x));
	return across > 0 ? across : 1;
}

<*
 Flows the children into rows and reports the height they came to.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The size taken: content-sized per axis unless size fixes it.`
*>
fn Vec2 Grid.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	sz count = elem.children.len();

	// A fixed size is what the children are measured against, not only what this
	// reports — the Column rule, and it matters more here: the width is what the
	// column count is divided out of, so a grid told to be 400 wide must wrap at
	// 400 and not at whatever the window offered.
	Vec2 avail = {
		self.size.x > 0 ? math::min(self.size.x, constraints.max.x) : constraints.max.x,
		self.size.y > 0 ? math::min(self.size.y, constraints.max.y) : constraints.max.y,
	};

	usz across = self.columns(avail.x);
	usz rows = count > 0 ? ((usz)count + across - 1) / across : 0;

	for (sz i = 0; i < count; i++)
	{
		// Tight, so every cell is the size the grid says. A loose constraint would
		// let each child pick its own size and the columns would stop lining up,
		// which is the one thing this is for.
		elem.layout_child(i, cui::tight(self.cell));
		elem.place_child(i, {
			(float)((usz)i % across) * (self.cell.x + self.gap_x),
			(float)((usz)i / across) * (self.cell.y + self.gap_y),
		});
	}

	float content_h = rows > 0
		? (float)rows * self.cell.y + (float)(rows - 1) * self.gap_y
		: 0;
	float content_w = count > 0
		? (float)math::min(across, (usz)count) * (self.cell.x + self.gap_x) - self.gap_x
		: 0;

	return constraints.constrain({
		self.size.x > 0 ? self.size.x : content_w,
		self.size.y > 0 ? self.size.y : content_h,
	});
}
