// Split areas: the node tree operations, the pane composites, tab switching,
// the strip's glyph controls, splitter drags and the @each visitors — all
// headless and fontless, so every tab falls back to its 2*pad_x floor width.
module cui_tests::areas;
import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math;

// Big enough that a side-by-side split clears 2 * min_pane on both axes.
const Vec2 AREA_WINDOW = { 800.0, 600.0 };

// With the default style and no font: tabs are 24px wide from x = 0, the
// glyph cells are tab_height (24px) squares against the right edge in the
// order [split-side][split-stack][close].
const float TAB_W = 2.0 * 12.0;
const float STRIP_H = 24.0;
const Vec2 TAB_A = { TAB_W * 0.5, STRIP_H * 0.5 };
const Vec2 TAB_B = { TAB_W * 1.5, STRIP_H * 0.5 };

// Two marker views: distinct types, so find/@each can tell panes apart.
struct AView (Widget)
{
	Vec2 size;
}

struct BView (Widget)
{
	Vec2 size;
}

int b_unmounts;

fn Element* build_a(Ui* ui)
{
	return ui.@node((AView) { });
}

fn Element* build_b(Ui* ui)
{
	return ui.@node((BView) { }, ui.@node((UnmountProbe) { .count = &b_unmounts }));
}

AreaLayout t_layout;
AreaView[2] t_views = {
	{ .name = "A", .build = &build_a },
	{ .name = "B", .build = &build_b },
};

fn Ui* area_ui()
{
	Ui* ui = cui::new_ui(AREA_WINDOW);
	t_layout.init(t_views[..]);
	@canvas(ui)
	{
		@node((AreaHost) { .areas = &t_layout });
	};
	ui.flush();
	return ui;
}

// A press is an edge, so it takes two frames: down then up.
fn void click(Ui* ui, Vec2 at)
{
	cui_tests::frame(ui, at, left: true);
	cui_tests::frame(ui, at, left: false);
	ui.flush();
}

macro usz count(Ui* ui, $Type)
{
	usz n = 0;
	ui.@each($Type; elem) { n++; };
	return n;
}

// The center of a glyph cell, counted from the right edge of a strip that
// ends at `right`: 3 = split-side, 2 = split-stack, 1 = close.
fn Vec2 glyph(float right, float from_right)
{
	return { right - (from_right - 0.5f) * STRIP_H, STRIP_H * 0.5f };
}

fn void initial_leaf_shows_first_view() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	test::@check(t_layout.root.is_leaf());
	test::@check(count(ui, AView) == 1);
	test::@check(count(ui, AreaTabStrip) == 1);
	test::@error(ui.find(BView), cui::WIDGET_NOT_FOUND);

	// The strip spans the width; the content fills everything under it.
	Element* content = ui.find(AView)!!;
	cui_tests::eq_vec2(content.size, { AREA_WINDOW.x, AREA_WINDOW.y - STRIP_H });
	cui_tests::eq_vec2(content.absolute, { 0, STRIP_H });
}

fn void tab_click_switches_pane() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, TAB_B);
	test::@check(t_layout.root.active == 1);
	test::@check(count(ui, BView) == 1);
	test::@error(ui.find(AView), cui::WIDGET_NOT_FOUND);

	click(ui, TAB_A);
	test::@check(count(ui, AView) == 1);
	test::@error(ui.find(BView), cui::WIDGET_NOT_FOUND);
}

fn void tab_switch_releases_old_content() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	b_unmounts = 0;
	click(ui, TAB_B);
	test::eq(b_unmounts, 0);
	click(ui, TAB_A);
	test::eq(b_unmounts, 1); // B's subtree was released, hooks and all
}

fn void split_side_makes_two_panes_keeping_view() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, TAB_B); // so the split must copy a non-default active
	click(ui, glyph(AREA_WINDOW.x, 3));

	test::@check(!t_layout.root.is_leaf());
	test::@check(t_layout.root.axis == SplitAxis.HORIZONTAL);
	test::@check(count(ui, BView) == 2); // both leaves kept the view
	test::@check(count(ui, AreaTabStrip) == 2);
	test::@check(count(ui, AreaSplitter) == 1);

	// Even split: each pane gets (800 - splitter) / 2.
	float first = (AREA_WINDOW.x - 5.0f) * 0.5f;
	Element* pane = ui.find(BView)!!;
	test::@check(pane.size.x == first || pane.size.x == AREA_WINDOW.x - 5.0f - first);
}

fn void splitter_drag_moves_ratio_and_clamps() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, glyph(AREA_WINDOW.x, 3));
	float total = AREA_WINDOW.x - 5.0f;

	// Grab the divider mid-window and pull it right.
	cui_tests::frame(ui, { 400, 300 }, left: true);
	cui_tests::frame(ui, { 500, 300 }, left: true);
	ui.flush();
	test::@check(math::abs(t_layout.root.ratio - (500.0f - 2.5f) / total) < 0.001f);

	// Capture holds the drag together however far it outruns the 5px handle;
	// the ratio clamps at min_pane from the edge.
	cui_tests::frame(ui, { 30, 300 }, left: true);
	cui_tests::frame(ui, { 30, 300 }, left: false);
	ui.flush();
	test::@check(math::abs(t_layout.root.ratio - 100.0f / total) < 0.001f);

	usz seen = 0;
	ui.@each(AView; elem)
	{
		seen++;
		test::@check(math::abs(elem.size.x - 100.0f) < 0.6f || math::abs(elem.size.x - (total - 100.0f)) < 0.6f);
	};
	test::eq(seen, 2ul);
}

fn void close_promotes_sibling() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, glyph(AREA_WINDOW.x, 3));
	test::@check(count(ui, AView) == 2);

	// The second pane's strip ends at the window edge; close is the last cell.
	click(ui, glyph(AREA_WINDOW.x, 1));
	test::@check(t_layout.root.is_leaf());
	test::@check(count(ui, AView) == 1);
	test::@check(count(ui, AreaSplitter) == 0);
}

fn void close_on_root_is_noop() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, glyph(AREA_WINDOW.x, 1));
	test::@check(t_layout.root.is_leaf());
	test::@check(count(ui, AView) == 1);
}

fn void nested_split_builds_three_leaves() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	click(ui, glyph(AREA_WINDOW.x, 3)); // left | right
	// The left pane's strip ends at its own right edge; stack it.
	float left_w = (AREA_WINDOW.x - 5.0f) * 0.5f;
	click(ui, glyph(left_w, 2));

	test::@check(count(ui, AView) == 3);
	test::@check(count(ui, AreaTabStrip) == 3);
	test::@check(count(ui, AreaSplitter) == 2);
	test::@check(t_layout.root.first.axis == SplitAxis.VERTICAL);

	// Close the top-left leaf; its sibling takes the whole left side back.
	click(ui, glyph(left_w, 1));
	test::@check(count(ui, AView) == 2);
	test::@check(t_layout.root.first.is_leaf());
}

fn void strip_swallows_misses() @test
{
	Ui* ui = area_ui();
	defer ui.free();
	defer t_layout.free();

	// A press on the strip's empty middle changes nothing and reaches nothing.
	click(ui, { 300, STRIP_H * 0.5f });
	test::@check(t_layout.root.is_leaf());
	test::@check(count(ui, AView) == 1);
}
