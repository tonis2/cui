// Composite widgets: the build interface method, passthrough sizing,
// request_build (rebuild = naive replace), the request_paint routing, and the
// nested-composite rebuild cascade.
module cui_tests::builds;
import cui;
import cui_tests;
import std::core::test;

struct Inner (Widget)
{
	float v;
}

fn Element* Inner.build(&self, Element* elem) @dynamic
{
	// The leaf's width is baked from v at build time — a repaint alone could
	// never change it; only a rebuild can.
	return elem.ui.@node((Rectangle){ .size = { self.v * 100.0f, 10.0f } }).with_id("fill");
}

struct Outer (Widget)
{
	float v;
}

fn Element* Outer.build(&self, Element* elem) @dynamic
{
	// Nested composite: rebuilding Outer must cascade into a fresh Inner.
	return elem.ui.@node((Inner){ .v = self.v });
}

struct Shedding (Widget)
{
	int* unmounts;
}

fn Element* Shedding.build(&self, Element* elem) @dynamic
{
	return elem.ui.@node((UnmountProbe){ .count = self.unmounts });
}

fn Ui* fixture(float v) @private
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	ui.build(ui.@node((Stack){}, ui.@node((Outer){ .v = v })));
	ui.flush();
	return ui;
}

fn void initial_build_attaches_and_sizes() @test
{
	Ui* ui = fixture(0.5f);
	defer ui.free();

	Element* outer = ui.find(Outer)!!;
	test::eq(outer.children.len(), 1);
	Element* fill = ui.find_id("fill")!!;
	cui_tests::eq_vec2(fill.size, {50, 10});
	cui_tests::eq_vec2(outer.size, {50, 10});    // passthrough: composite = subtree
}

fn void modify_rebuilds_through_cascade() @test
{
	Ui* ui = fixture(0.5f);
	defer ui.free();

	// request_paint routes to request_build on a paint-less build widget, so
	// @modify regenerates the whole subtree — including the nested Inner.
	ui.@modify(Outer; o)
	{
		o.v = 0.75f;
	};
	test::@check(ui.build_pending);
	ui.flush();

	Element* fill = ui.find_id("fill")!!;
	test::eq(fill.size.x, 75.0f);
	test::eq(ui.find(Inner)!!.widget_as(Inner).v, 0.75f);   // fresh Inner, new config
}

fn void request_build_on_nested_composite_only() @test
{
	Ui* ui = fixture(0.5f);
	defer ui.free();

	Element* inner = ui.find(Inner)!!;
	inner.widget_as(Inner).v = 0.25f;
	inner.request_build();
	ui.flush();

	test::eq(ui.find_id("fill")!!.size.x, 25.0f);
}

fn void composite_handle_survives_rebuild() @test
{
	Ui* ui = fixture(0.5f);
	defer ui.free();

	Element* outer = ui.find(Outer)!!;
	ui.@modify(Outer; o)
	{
		o.v = 0.75f;
	};
	ui.flush();

	test::@check(ui.find(Outer)!! == outer);     // rebuild replaces children, not self
	test::eq(ui.free_elements.len(), 0);         // old elements recycled in place
}

fn void rebuild_fires_unmount_on_old_subtree() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	int unmounts;
	Element* shed = ui.@node((Shedding){ .unmounts = &unmounts });
	ui.build(ui.@node((Stack){}, shed));
	ui.flush();
	test::eq(unmounts, 0);

	shed.request_build();
	ui.flush();
	test::eq(unmounts, 1);                       // old UnmountProbe released

	shed.request_build();
	ui.flush();
	test::eq(unmounts, 2);
}

fn void request_paint_routes_only_for_paintless_build() @test
{
	Ui* ui = fixture(0.5f);
	defer ui.free();

	Element* outer = ui.find(Outer)!!;
	Element* fill = ui.find_id("fill")!!;

	outer.request_paint();                       // build widget: routes to rebuild
	test::@check(outer.dirty.build);
	test::@check(ui.build_pending);

	fill.request_paint();                        // plain widget: stays a repaint
	test::@check(!fill.dirty.build);
	test::@check(fill.dirty.paint);
}
