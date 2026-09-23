// LiveLabel follows its text callback without a rebuild, and EmptyStateTree
// copies its rows, hands its id to the Tree, and knows when it has none.
module cui_tests::live_widgets;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;

// What the callbacks read — a bare function pointer carries no context.
int ticks @local;
TreeRow[] given_rows @local;

fn String tick_text(Element* elem) @local => string::format(mem, "tick %d", ticks);
fn String quiet_text(Element* elem) @local => "";

fn TreeRow[] rows_given(Element* elem, usz* selected) @local
{
	*selected = 1;
	return given_rows;
}

fn void a_live_label_follows_its_text_without_a_rebuild() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	ticks = 1;
	Element* elem = ui.@node((LiveLabel) { .text_of = &tick_text, .size = { 100, 20 } });
	ui.build(ui.@node((Stack) { }, elem));
	ui.flush();
	test::@check(elem.widget_as(LiveLabel).shown == "tick 1", "built on \"%s\"", elem.widget_as(LiveLabel).shown);
	test::@check(elem.children[0].widget_as(Label).text == "tick 1", "the Label shows the first text");
	test::@check(elem.size.x == 100 && elem.size.y == 20, "sized by its size field");

	ticks = 2;
	cui_tests::frame(ui, { 0, 0 });
	ui.flush();
	test::@check(elem.widget_as(LiveLabel).shown == "tick 2", "the tick moved the text");
	test::@check(elem.children[0].widget_as(Label).text == "tick 2", "the Label follows");
}

fn void a_live_label_may_answer_a_literal_empty_string() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* elem = ui.@node((LiveLabel) { .text_of = &quiet_text });
	ui.build(ui.@node((Stack) { }, elem));
	ui.flush();
	cui_tests::frame(ui, { 0, 0 });
	ui.flush();
	test::@check(elem.widget_as(LiveLabel).shown.len == 0, "nothing to show");
}

fn void an_empty_state_tree_copies_its_rows_and_names_the_tree() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	String first = "first".copy(mem);
	given_rows = { { .label = first }, { .label = "second" } };
	Element* elem = ui.@node((EmptyStateTree) { .rows_of = &rows_given, .empty = "None.", .tree_id = "the-tree" });
	ui.build(ui.@node((Stack) { }, elem));
	ui.flush();
	// The rows are copied, so the answer may go away before the next build.
	first.free(mem);
	given_rows = { };

	Tree* tree = ui.find_id("the-tree")!!.widget_as(Tree);
	test::@check(tree.rows.len == 2 && tree.rows[0].label == "first", "the tree holds a copy of the rows");
	test::@check(tree.selected == 1, "the answer chose the selection");
	test::@check(elem.size.x == cui_tests::WINDOW.x, "as wide as it was offered");

	elem.request_build();
	ui.flush();
	test::@check(elem.widget_as(EmptyStateTree).rows.len == 0, "a rebuild asks again and finds none");
}