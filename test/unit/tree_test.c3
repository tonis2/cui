// Tree: which row a point lands in, the two targets a row has, and what the
// selection does. Headless and fontless, which is fine here — a row's height is
// a style constant and nothing about the hit test measures text.
module cui_tests::trees;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

const float ROW_H = widgets::DEFAULT_TREE_STYLE.row_height;
const float INDENT = widgets::DEFAULT_TREE_STYLE.indent;
const float PAD = widgets::DEFAULT_TREE_STYLE.padding;

// What the callbacks report, since a bare OnRow carries no context back.
int selected_row @local = -1;
int toggled_row @local = -1;

fn void note_select(Ui* ui, usz row) @local { selected_row = (int)row; }
fn void note_toggle(Ui* ui, usz row) @local { toggled_row = (int)row; }

// "All" over one collapsible kind and two plans under it — the sidebar shape.
TreeRow[4] rows @local = {
	{ .label = "All", .depth = 0 },
	{ .label = "Animations", .depth = 1, .expandable = true, .expanded = true, .trailing = "7" },
	{ .label = "biped", .depth = 2 },
	{ .label = "bird", .depth = 2 },
};

fn Element* tree_of(Ui* ui) @local
{
	selected_row = -1;
	toggled_row = -1;

	Element* tree = ui.@node((Tree) {
		.rows = rows[..],
		.selected = rows.len, // past the end: nothing selected
		.on_select = &note_select,
		.on_toggle = &note_toggle,
	});
	ui.build(ui.@node((Stack) { }, tree));
	ui.flush();
	return tree;
}

// The middle of row `row`, at an x that is on the label rather than on the mark.
fn Vec2 on_label(usz row) @local => { 200.0, (float)row * ROW_H + ROW_H * 0.5f };

<*
 The rows stack at one row height each, and the tree is as tall as they come to.

 Sized to content so it sits under a Scroll, and offered width taken rather than
 measured: a sidebar that changed width when a longer category appeared would
 move the grid beside it.
*>
fn void the_tree_is_as_tall_as_its_rows() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	test::@check(tree.size.y == (float)rows.len * ROW_H,
		"four rows came to %.0f rather than %.0f", tree.size.y, (float)rows.len * ROW_H);
	test::@check(tree.size.x == cui_tests::WINDOW.x, "the tree did not take the width it was offered");
}

<*
 A point lands in the row it is drawn in, and nowhere off the ends.

 Shared by paint's hover and the click, so an off-by-one here is a row that
 lights under the pointer while a different one is selected by the click.
*>
fn void a_point_lands_in_the_row_it_is_drawn_in() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);

	test::eq(widget.row_at(tree, { 200, 1 }), 0);
	test::eq(widget.row_at(tree, { 200, ROW_H - 1 }), 0);
	test::eq(widget.row_at(tree, { 200, ROW_H + 1 }), 1);
	test::eq(widget.row_at(tree, { 200, 3 * ROW_H + 1 }), 3);

	// Past the last row, and off the left and right edges.
	test::eq(widget.row_at(tree, { 200, 4 * ROW_H + 1 }), -1);
	test::eq(widget.row_at(tree, { 200, -1 }), -1);
	test::eq(widget.row_at(tree, { -1, 1 }), -1);
	test::eq(widget.row_at(tree, { cui_tests::WINDOW.x + 1, 1 }), -1);
}

<*
 Clicking a row selects it, and the selection is set here rather than only
 reported — a caller that just wants it drawn should not have to write it back.
*>
fn void clicking_a_row_selects_it() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);

	cui_tests::frame(ui, on_label(2), left: true);
	test::eq(selected_row, 2);
	test::eq((int)widget.selected, 2);

	cui_tests::frame(ui, on_label(2));
	cui_tests::frame(ui, on_label(0), left: true);
	test::eq(selected_row, 0);
	test::eq((int)widget.selected, 0);
}

<*
 A row has two targets: the disclosure mark opens it, and everything else
 selects it.

 Which is what lets a category be opened without also being browsed — the reason
 the mark is a target of its own rather than the row being a single toggle.
*>
fn void the_mark_toggles_where_the_row_selects() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);

	// The mark sits in the indent step left of a depth-1 label.
	float mark_x = PAD + INDENT - INDENT * 0.5f;
	cui_tests::frame(ui, { mark_x, ROW_H * 1.5f }, left: true);
	test::eq(toggled_row, 1);
	test::@check(selected_row == -1, "clicking the mark also selected the row");
	test::@check(widget.selected != 1, "clicking the mark moved the selection");

	// The label of the same row: selects, and does not toggle.
	cui_tests::frame(ui, on_label(1));
	cui_tests::frame(ui, on_label(1), left: true);
	test::eq(selected_row, 1);
	test::eq(toggled_row, 1); // unchanged from the click above
}

<*
 A row with nothing to expand has no mark, so a click at the mark's x selects
 like any other part of the row.

 Otherwise a strip down the left of every plain row would swallow clicks and do
 nothing with them.
*>
fn void a_plain_row_has_no_mark_to_hit() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);

	// Row 2 is a plain depth-2 row; this x is where its mark would be if it had one.
	float mark_x = PAD + 2 * INDENT - INDENT * 0.5f;
	test::@check(!widget.on_mark(widgets::DEFAULT_TREE_STYLE, 2, { mark_x, 0 }),
		"a row with nothing to expand offered a disclosure target");

	cui_tests::frame(ui, { mark_x, ROW_H * 2.5f }, left: true);
	test::eq(selected_row, 2);
	test::eq(toggled_row, -1);
}

<*
 A click in the empty space below the last row is still the list's.

 It is a list with a short tail, not a hole through to whatever is behind it —
 the FileBrowser rule, and the same reason: a click that fell through would act
 on the panel underneath.
*>
fn void the_empty_tail_still_belongs_to_the_tree() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);
	usz before = widget.selected;

	// Below every row, but inside the element the Stack stretched to the window.
	cui_tests::frame(ui, { 200, (float)rows.len * ROW_H + 4.0f }, left: true);
	test::eq(selected_row, -1);
	test::@check(widget.selected == before, "a click past the last row moved the selection");
}

<*
 The hover leaves with the pointer.

 Leaving produces no MOVE inside the element, so without `on_hover` the last row
 crossed would stay lit after the pointer had gone somewhere else entirely.
*>
fn void the_hover_clears_when_the_pointer_leaves() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget = tree.widget_as(Tree);

	cui_tests::frame(ui, on_label(1));
	test::eq(widget.lit, 2); // index + 1, so 0 can mean none

	// Off the bottom of the tree, which is off the element entirely.
	cui_tests::frame(ui, { 200, cui_tests::WINDOW.y - 1 });
	test::eq(widget.lit, 0);
}
