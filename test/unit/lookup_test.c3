// Tree queries: find / find_id (fault-based), the get_widget twins, and the
// @modify sugar.
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
