// Tree queries: find / find_id (fault-based), the get_widget twins, the
// @modify sugar, and the @walk / @each visitors.
module cui_tests::lookups;
import cui;
import cui_tests;
import std::core::test;

fn void find_returns_first_in_tree_order() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} });
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, a, b)));

	test::@check(ui.find(Rectangle)!! == a);
	Rectangle* r = ui.get_widget(Rectangle)!!;
	test::@check(r == a.widget_as(Rectangle));
}

fn void find_missing_type_faults() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	ui.build(ui.@node((Stack){}));
	test::@error(ui.find(Button), cui::WIDGET_NOT_FOUND);
	test::@error(ui.get_widget(Button), cui::WIDGET_NOT_FOUND);
}

fn void find_id_resolves_stamped_element() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} }).with_id("b");
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, a, b)));

	test::@check(ui.find_id("b")!! == b);
	Rectangle* rb = ui.get_widget_id("b", Rectangle)!!;
	test::@check(rb == b.widget_as(Rectangle));

	test::@error(ui.find_id("nope"), cui::WIDGET_NOT_FOUND);
	// An empty id is "unkeyed", never a match — even though unkeyed nodes exist.
	test::@error(ui.find_id(""), cui::WIDGET_NOT_FOUND);
}

fn void modify_mutates_and_invalidates() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	ui.build(ui.@node((Stack){}, a));
	ui.flush();
	test::@check(!ui.paint_pending);

	ui.@modify(Rectangle; r)
	{
		r.style.border_width = 3.0f;
	};

	test::@check(ui.paint_pending);             // repaint scheduled by @modify
	test::eq(a.widget_as(Rectangle).style.border_width, 3.0f);
}

fn void modify_id_targets_named_node() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* a = ui.@node((Rectangle){ .size = {30, 20} });
	Element* b = ui.@node((Rectangle){ .size = {50, 40} }).with_id("b");
	ui.build(ui.@node((Stack){}, ui.@node((Column){}, a, b)));
	ui.flush();

	ui.@modify_id("b", Rectangle; r)
	{
		r.style.border_width = 7.0f;
	};

	test::eq(b.widget_as(Rectangle).style.border_width, 7.0f);
	test::eq(a.widget_as(Rectangle).style.border_width, 0.0f);   // untouched
}

fn void modify_missing_is_silent_noop() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	ui.build(ui.@node((Stack){}));
	ui.flush();

	ui.@modify(Button; btn)
	{
		btn.held = true;                        // must never run
	};

	test::@check(!ui.paint_pending);
}

fn void walk_visits_every_element_in_order() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	// Lopsided on purpose: reaching `right` means climbing two levels out of
	// the deep branch, which is the step a stackless walk can get wrong. A
	// missed element here is a pane that never repaints.
	Element* deep = ui.@node((Rectangle){ .size = {10, 10} });
	Element* mid = ui.@node((Column){}, deep);
	Element* left = ui.@node((Column){}, mid);
	Element* right = ui.@node((Rectangle){ .size = {20, 20} });
	Element* root = ui.@node((Stack){}, left, right);
	ui.build(root);

	Element*[5] want = { root, left, mid, deep, right };
	int seen = 0;
	bool in_order = true;
	ui.@walk(; elem)
	{
		if (seen >= 5 || elem != want[seen]) in_order = false;
		seen++;
	};

	test::eq(seen, 5);
	test::@check(in_order);                     // parent first, siblings left to right
}

fn void walk_before_the_first_build_is_a_noop() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int seen = 0;
	ui.@walk(; elem) { seen++; };
	test::eq(seen, 0);
}

fn void each_sees_every_match() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	// One name on two nodes at different depths — the duplicated-subtree case
	// find/find_id cannot express, since they stop at the first hit.
	Element* a = ui.@node((Rectangle){ .size = {30, 20} }).with_id("card");
	Element* b = ui.@node((Rectangle){ .size = {50, 40} }).with_id("card");
	Element* column = ui.@node((Column){}, b);
	ui.build(ui.@node((Stack){}, a, column));

	int rects = 0;
	ui.@each(Rectangle; elem) { rects++; };
	test::eq(rects, 2);

	int cards = 0;
	ui.@each_id("card"; elem) { cards++; };
	test::eq(cards, 2);

	int absent = 0;
	ui.@each(Button; elem) { absent++; };
	test::eq(absent, 0);

	// The same two tests a @walk body would run by hand.
	test::@check(a.is_widget(Rectangle));
	test::@check(!a.is_widget(Column));
	test::@check(a.has_id("card"));
	test::@check(!a.has_id("nope"));
	test::@check(!column.has_id(""));           // unkeyed nodes match no name
}
