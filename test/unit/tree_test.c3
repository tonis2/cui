// Tree: which row a point lands in, the two targets a row has, and what the
// selection does. Headless and fontless, which is fine here — a row's height is
// a style constant and nothing about the hit test measures text.
module cui_tests::trees;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

const float ROW_H  = widgets::DEFAULT_TREE_STYLE.row_height;
const float INDENT = widgets::DEFAULT_TREE_STYLE.indent;
const float PAD    = widgets::DEFAULT_TREE_STYLE.padding;

// What the callbacks report, since a bare OnRow carries no context back.
int selected_row @local = -1;
int toggled_row @local  = -1;
int context_row @local  = -1;
Vec2 context_at @local;

fn void note_select(Ui* ui, usz row) @local
{
	selected_row = (int)row;
}
fn void note_toggle(Ui* ui, usz row) @local
{
	toggled_row = (int)row;
}
fn void note_context(Ui* ui, usz row, Vec2 at) @local
{
	context_row = (int)row;
	context_at = at;
}

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
	context_row = -1;

	Element* tree = ui.@node(
		(Tree) {
			.rows = rows[..],
			.selected = rows.len, // past the end: nothing selected
			.on_select = &note_select,
			.on_toggle = &note_toggle,
			.on_context = &note_context,
		}
	);
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
	test::@check(
		tree.size.y == (float)rows.len * ROW_H,
		"four rows came to %.0f rather than %.0f",
		tree.size.y,
		(float)rows.len * ROW_H
	);
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
	Tree* widget  = tree.widget_as(Tree);

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
	Tree* widget  = tree.widget_as(Tree);

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
	Tree* widget  = tree.widget_as(Tree);

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
	Tree* widget  = tree.widget_as(Tree);

	// Row 2 is a plain depth-2 row; this x is where its mark would be if it had one.
	float mark_x = PAD + 2 * INDENT - INDENT * 0.5f;
	test::@check(
		!widget.on_mark(widgets::DEFAULT_TREE_STYLE, 2, { mark_x, 0 }),
		"a row with nothing to expand offered a disclosure target"
	);

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
	Tree* widget  = tree.widget_as(Tree);
	usz before    = widget.selected;

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
	Tree* widget  = tree.widget_as(Tree);

	cui_tests::frame(ui, on_label(1));
	test::eq(widget.lit, 2); // index + 1, so 0 can mean none

	// Off the bottom of the tree, which is off the element entirely.
	cui_tests::frame(ui, { 200, cui_tests::WINDOW.y - 1 });
	test::eq(widget.lit, 0);
}
<*
 A right-press reports the row and where it landed, and leaves the selection to
 the caller — a context menu may act on a group the press did not pick.
*>
fn void a_right_press_asks_for_the_row_context() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = tree_of(ui);
	Tree* widget  = tree.widget_as(Tree);

	cui_tests::frame(ui, on_label(3), right: true);
	test::eq(context_row, 3);
	test::@check(context_at == on_label(3), "the context point is not where the press landed");
	test::eq(selected_row, -1);
	test::@check(widget.selected == rows.len, "a right-press moved the selection");

	// Past the last row is not a row: the press is left for the panel behind.
	cui_tests::frame(ui, on_label(3));
	context_row = -1;
	cui_tests::frame(ui, { 200, (float)rows.len * ROW_H + 4.0f }, right: true);
	test::eq(context_row, -1);
}

int toggle_row @local    = -1;
int toggle_column @local = -1;

fn void note_row_toggle(Ui* ui, usz row, usz column) @local
{
	toggle_row = (int)row;
	toggle_column = (int)column;
}

fn void paint_nothing(Painter* painter, Vec2 center, float size, ushort icon, bool dim) @local
{
}

const TreeStyle TOGGLE_STYLE @local = {
	.row_height = 24.0,
	.text_size = 13.0,
	.padding = 8.0,
	.indent = 16.0,
	.icon_size = 14.0,
	.toggle_width = 22.0,
};

// A mesh row with an eye, and a joint row under it with none.
TreeRow[2] switch_rows @local = {
	{ .label = "Mesh", .icon = 1, .toggles = { { .icon = 9, .on = true, .shown = true }, {} } },
	{ .label = "hips", .depth = 1, .icon = 2 },
};

fn Element* switch_tree_of(Ui* ui) @local
{
	selected_row = -1;
	toggle_row = -1;
	toggle_column = -1;

	Element* tree = ui.@node(
		(Tree) {
			.rows = switch_rows[..],
			.selected = switch_rows.len,
			.on_select = &note_select,
			.on_row_toggle = &note_row_toggle,
			.paint_icon = &paint_nothing,
			.style = TOGGLE_STYLE,
		}
	);
	ui.build(ui.@node((Stack) { }, tree));
	ui.flush();
	return tree;
}

<*
 A click on a row's switch reports the switch and leaves the selection alone:
 hiding the mesh is not choosing it.
*>
fn void a_toggle_click_reports_its_column_and_does_not_select() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = switch_tree_of(ui);
	Tree* widget  = tree.widget_as(Tree);

	float eye_x = tree.size.x - TOGGLE_STYLE.padding - TOGGLE_STYLE.toggle_width * 0.5f;
	cui_tests::frame(ui, { eye_x, 12 }, left: true);
	test::eq(toggle_row, 0);
	test::eq(toggle_column, 0);
	test::eq(selected_row, -1);
	test::@check(widget.selected == switch_rows.len, "a switch click moved the selection");

	// The same column on a row that shows no switch there is just the row.
	cui_tests::frame(ui, { eye_x, 12 });
	cui_tests::frame(ui, { eye_x, 36 }, left: true);
	test::eq(selected_row, 1);
	test::eq(toggle_row, 0); // unchanged
}

<*
 A row with an icon starts its label past the icon's slot — but only when there
 is something to paint the icon with, so a tree without icons keeps its layout.
*>
fn void an_icon_slot_moves_the_label_over() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* tree = switch_tree_of(ui);
	Tree* widget  = tree.widget_as(Tree);
	float bare    = widget.text_x(TOGGLE_STYLE, 1);

	test::@check(widget.label_x(TOGGLE_STYLE, switch_rows[1]) > bare + TOGGLE_STYLE.icon_size,
		"the label sits on top of its icon");
	widget.paint_icon = null;
	test::@check(widget.label_x(TOGGLE_STYLE, switch_rows[1]) == bare, "a tree with no icon painter moved its labels");
}

<*
 A row lit as part of a larger selection is only painted so: `selected` still
 names the one active row, and a click still moves that alone.
*>
fn void a_highlighted_row_is_not_the_selection() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	switch_rows[1].highlighted = true;
	defer switch_rows[1].highlighted = false;
	Element* tree = switch_tree_of(ui);
	Tree* widget  = tree.widget_as(Tree);
	test::@check(widget.selected == switch_rows.len, "a highlighted row became the selection");

	cui_tests::frame(ui, { 60, 12 }, left: true);
	test::eq(selected_row, 0);
	test::eq((int)widget.selected, 0);
}
