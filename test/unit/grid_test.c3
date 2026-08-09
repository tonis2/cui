// Grid: how many cells fit across, where they land, and what height the rows
// come to. Headless and fontless, which costs nothing here — a Grid measures no
// text, since every cell is the size the grid says rather than the size the
// child asks for.
module cui_tests::grids;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

const Vec2 CELL = { 90.0, 40.0 };
const float GAP = 10.0;

// Taller than `cui_tests::WINDOW`, which is 100 high — two rows of these cells
// already reach that, and a grid clamped by the window is measuring the clamp
// rather than the wrap. A real one sits under a Scroll, which offers it an
// unbounded height; this is the nearest thing to that with no Scroll in the way.
const Vec2 SHEET = { 400.0, 600.0 };

// A grid of `count` cells under a Column that fixes the width, since a bare
// canvas offers the whole window and the point of most of these is what happens
// at a particular width.
fn Element* grid_of(Ui* ui, usz count, float width) @local
{
	Element* grid = ui.@node((Grid) { .cell = CELL, .gap_x = GAP, .gap_y = GAP });
	for (usz i = 0; i < count; i++) grid.children.push(ui.@node((Rectangle) { }));

	// Under a Column with a fixed width, because that width is what the wrap is
	// computed from — a bare canvas offers the whole window, and most of these
	// checks are about what happens at one particular width.
	ui.build(ui.@node((Column) { .size = { width, 0 } }, grid));
	ui.flush();
	return grid;
}

<*
 The column count is what fits, gaps counted between cells and not after the last.

 The off-by-one this guards: three 90-wide cells with 10-wide gaps need 290, not
 300, so a 290-wide grid holds three. Counting a gap after the last cell would
 fit only two and leave 90 pixels of visible empty space beside them.
*>
fn void columns_count_the_gaps_between_cells() @test
{
	Grid grid = { .cell = CELL, .gap_x = GAP };

	test::eq((int)grid.columns(290.0f), 3);
	test::eq((int)grid.columns(299.0f), 3);
	test::eq((int)grid.columns(300.0f), 3);
	test::eq((int)grid.columns(390.0f), 4);
	test::eq((int)grid.columns(190.0f), 2);

	// Never zero. A viewport too narrow for one cell shows that cell clipped, which
	// reads as too narrow; no columns at all reads as an empty panel.
	test::eq((int)grid.columns(10.0f), 1);
	test::eq((int)grid.columns(0.0f), 1);

	// A grid never given a cell size has nothing to divide by, and must not divide
	// by it — mid-build there is nowhere to report the mistake to.
	Grid unsized = { };
	test::eq((int)unsized.columns(300.0f), 1);
}

<*
 Cells are placed in rows, every one the grid's own size.

 The size is the check that matters: a Rectangle with no size field of its own
 would take whatever it was offered, so a cell coming back at the full grid width
 means the children were laid out loosely and the columns do not line up.
*>
fn void cells_wrap_into_rows_at_the_grid_size() @test
{
	Ui* ui = cui::new_ui(SHEET);
	defer ui.free();

	// 290 wide: three across, so five cells are a full row and a row of two.
	Element* grid = grid_of(ui, 5, 290.0f);

	test::eq((int)grid.children.len(), 5);
	foreach (child : grid.children)
	{
		test::@check(child.size.x == CELL.x && child.size.y == CELL.y,
			"a cell came back %.0fx%.0f rather than the grid's %.0fx%.0f",
			child.size.x, child.size.y, CELL.x, CELL.y);
	}

	test::@check(grid.children[0].offset.x == 0.0f && grid.children[0].offset.y == 0.0f);
	test::@check(grid.children[1].offset.x == CELL.x + GAP, "the second cell is not one cell and a gap across");
	test::@check(grid.children[2].offset.y == 0.0f, "the third cell wrapped early");

	// The fourth starts the second row: back to the left edge, one row down.
	test::@check(grid.children[3].offset.x == 0.0f, "the fourth cell did not wrap");
	test::@check(grid.children[3].offset.y == CELL.y + GAP,
		"the second row sits at %.0f rather than one cell and a gap down", grid.children[3].offset.y);
	test::@check(grid.children[4].offset.y == grid.children[3].offset.y, "the fifth cell is not beside the fourth");

	// Two rows: two cells tall with one gap between them, and no gap under the last.
	test::@check(grid.size.y == 2 * CELL.y + GAP,
		"two rows came to %.0f rather than %.0f", grid.size.y, 2 * CELL.y + GAP);
}

<*
 A narrower grid wraps sooner, which is the whole point of it wrapping.

 Same five cells, a width that holds two: three rows rather than two. The height
 has to follow, or the Scroll around it scrolls to the wrong place.
*>
fn void a_narrower_grid_takes_more_rows() @test
{
	Ui* ui = cui::new_ui(SHEET);
	defer ui.free();

	Element* grid = grid_of(ui, 5, 190.0f);

	test::@check(grid.children[2].offset.y == CELL.y + GAP, "the third cell did not wrap at two across");
	test::@check(grid.size.y == 3 * CELL.y + 2 * GAP,
		"three rows came to %.0f rather than %.0f", grid.size.y, 3 * CELL.y + 2 * GAP);
}

<*
 An empty grid takes no room at all.

 A list that has been filtered down to nothing is the ordinary case for this, and
 a grid that still reported a row's height would leave a gap above whatever the
 caller draws to say there is nothing to show.
*>
fn void an_empty_grid_is_flat() @test
{
	Ui* ui = cui::new_ui(SHEET);
	defer ui.free();

	Element* grid = grid_of(ui, 0, 290.0f);
	test::eq((int)grid.children.len(), 0);
	test::eq((int)grid.size.y, 0);
}

<*
 One row of cells is as wide as those cells, not as wide as it was offered.

 What a `Scroll` reads to decide whether there is anything to scroll, and what an
 alignment around the grid measures. A single cell reporting the full offered
 width would centre as though it were a full row.
*>
fn void a_short_row_is_only_as_wide_as_its_cells() @test
{
	Ui* ui = cui::new_ui(SHEET);
	defer ui.free();

	Element* one = grid_of(ui, 1, 290.0f);
	test::@check(one.size.x == CELL.x, "one cell reported %.0f wide rather than %.0f", one.size.x, CELL.x);

	Element* two = grid_of(ui, 2, 290.0f);
	test::@check(two.size.x == 2 * CELL.x + GAP,
		"two cells reported %.0f wide rather than %.0f", two.size.x, 2 * CELL.x + GAP);
}
