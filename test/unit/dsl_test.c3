// The scoped tree builder (@canvas / @tree / @node / @subtree): structure and
// layout of what the bodies build, handle chaining, detached subtrees for
// composites, and scope-state hygiene. All headless.
module cui_tests::dsl;
import cui;
import cui_tests;
import std::math;
import std::core::test;

// @canvas installs the body's top-level node as root, @tree nests, @node
// leafs, and a plain loop in a body emits real children — the tree lays out
// exactly like its ui.@node-composed equal.
fn void canvas_builds_and_installs() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* column;
	@canvas(ui)
	{
		@tree((Stack){})
		{
			column = @tree((Column){ .gap = 10.0 })
			{
				@node((Rectangle){ .size = {100, 40} });
				for (int i = 0; i < 3; i++) @node((Rectangle){ .size = {80, 10} });
			};
		};
	};

	test::eq(ui.root != null, true);
	test::eq(ui.root.children.len(), 1);
	test::eq(ui.root.children[0] == column, true);
	test::eq(column.children.len(), 4);

	ui.flush();
	cui_tests::eq_vec2(column.children[0].absolute, {0, 0});
	cui_tests::eq_vec2(column.children[1].absolute, {0, 50}); // 40 + gap 10
	cui_tests::eq_vec2(column.children[3].absolute, {0, 90});
	cui_tests::eq_vec2(column.size, {100, 100});
}

// Both macros hand back the Element*, so with_id and set_offset chain straight
// off a node expression and the handle stays valid after the block.
fn void handles_chain_and_survive() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* card;
	@canvas(ui)
	{
		@tree((Stack){ .size = {200, 100} })
		{
			card = @node((Rectangle){ .size = {40, 20} }).with_id("card");
			card.set_offset({30, 40});
		};
	};
	ui.flush();

	test::eq(ui.find_id("card")!! == card, true);
	cui_tests::eq_vec2(card.absolute, {30, 40});
}

// @subtree is @canvas without the install: the root comes back detached, in
// whatever scope it's called from — including nested inside a @canvas body,
// where the scope floor keeps its nodes from leaking into the outer tree.
fn void subtree_returns_detached_root() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* floating;
	@canvas(ui)
	{
		@tree((Stack){})
		{
			@node((Rectangle){ .size = {10, 10} });
			floating = @subtree(ui)
			{
				@tree((Column){})
				{
					@node((Rectangle){ .size = {5, 5} });
				};
			};
		};
	};

	test::eq(floating.parent == null, true);
	test::eq(ui.root.children.len(), 1); // the subtree didn't touch the outer scope
	test::eq(floating.children.len(), 1);

	ui.root.append(floating); // graft it like an app would (and so ui.free sees it)
	ui.flush();
	test::eq(ui.root.children.len(), 2);
}

// The composite shape: build() returns a @subtree. The DSL runs fine during
// the flush build pass, and a request_build regenerates through it.
struct Pair (Widget)
{
	float gap;
}

fn Element* Pair.build(&self, Element* elem) @dynamic
{
	return @subtree(elem.ui)
	{
		@tree((Column){ .gap = self.gap })
		{
			@node((Rectangle){ .size = {50, 20} });
			@node((Rectangle){ .size = {50, 20} });
		};
	};
}

fn void subtree_in_composite_build() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	@canvas(ui)
	{
		// Under a Stack so the composite wraps its content instead of being
		// stretched by the root's tight window constraints.
		@tree((Stack){})
		{
			@node((Pair){ .gap = 4.0 });
		};
	};
	ui.flush();

	Element* pair = ui.find(Pair)!!;
	test::eq(pair.children.len(), 1);
	Element* column = pair.children[0];
	test::eq(column.children.len(), 2);
	cui_tests::eq_vec2(column.children[1].absolute, {0, 24}); // 20 + gap 4
	cui_tests::eq_vec2(pair.size, {50, 44});

	pair.request_build();
	ui.flush();
	test::eq(pair.children.len(), 1);
	cui_tests::eq_vec2(pair.children[0].children[1].absolute, {0, 24});
}

// The free @node's extra arguments are widgets auto-wrapped as leaf children —
// a one-call row-of-leaves that lays out exactly like its @tree-body equal.
fn void node_varargs_attach_leaves() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* column;
	@canvas(ui)
	{
		@tree((Stack){})
		{
			column = @node(
				(Column){ .gap = 10.0 },
					(Rectangle){ .size = {100, 40} },
					(Rectangle){ .size = {80, 10} },
					(Rectangle){ .size = {80, 10} }
				);
		};
	};
	ui.flush();

	test::eq(column.children.len(), 3);
	cui_tests::eq_vec2(column.children[0].absolute, {0, 0});
	cui_tests::eq_vec2(column.children[1].absolute, {0, 50}); // 40 + gap 10
	cui_tests::eq_vec2(column.children[2].absolute, {0, 70});
	cui_tests::eq_vec2(column.size, {100, 80});
}

// Varargs also work on the body's top-level node, mix values with borrowed
// pointers, and the parent handle still chains.
fn void node_varargs_as_root() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Rectangle borrowed = { .size = {30, 30} };
	Element* stack;
	@canvas(ui)
	{
		stack = @node((Stack){}, (Rectangle){ .size = {10, 10} }, &borrowed).with_id("panel");
	};
	ui.flush();

	test::eq(ui.root == stack, true);
	test::eq(stack.children.len(), 2);
	test::eq(ui.find_id("panel")!! == stack, true);
	test::eq(stack.children[1].widget_as(Rectangle) == &borrowed, true); // borrowed, not copied
}

// Scope bookkeeping unwinds completely, and a detached ui.@node made inside a
// body stays detached — the DSL only attaches its own nodes.
fn void scope_state_unwinds() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();

	Element* detached;
	@canvas(ui)
	{
		@tree((Stack){})
		{
			@node((Rectangle){ .size = {10, 10} });
			detached = ui.@node((Rectangle){ .size = {20, 20} });
		};
	};

	test::eq(detached.parent == null, true);
	test::eq(ui.root.children.len(), 1);
	test::eq(ui.build_stack.len(), 0);
	test::eq(ui.scope_floor, 0);
	test::eq(ui.scoped_root == null, true);

	ui.root.append(detached); // attach so ui.free releases it
}
