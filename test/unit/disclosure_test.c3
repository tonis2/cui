module cui_tests::disclosures;

import cui;
import cui::widgets;
import cui_tests;
import std::core::test;
import std::math::vector;

bool last_expanded @local;
int changes @local;

fn void disclosure_changed(Ui* ui, bool expanded) @local
{
	last_expanded = expanded;
	changes++;
}

fn Element* disclosure_of(Ui* ui, bool expanded) @local
{
	last_expanded = expanded;
	changes = 0;
	Element* section = ui.@node(
		(Disclosure) {
			.label = "Transform",
			.expanded = expanded,
			.width = 180,
			.on_change = &disclosure_changed,
		},
		ui.@node((Rectangle) { .size = { 100, 40 } })
	);
	ui.build(ui.@node((Stack) { }, section));
	ui.flush();
	return section;
}

fn void an_expanded_disclosure_places_its_body_below_the_header() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* section = disclosure_of(ui, true);

	float expected = widgets::DEFAULT_DISCLOSURE_STYLE.header_height + widgets::DEFAULT_DISCLOSURE_STYLE.gap + 40.0f
		+ widgets::DEFAULT_DISCLOSURE_STYLE.padding;
	test::eq(section.size.x, 180.0f);
	test::eq(section.size.y, expected);
	test::eq(section.children[0].offset.x, widgets::DEFAULT_DISCLOSURE_STYLE.padding);
	test::eq(
		section.children[0].offset.y,
		widgets::DEFAULT_DISCLOSURE_STYLE.header_height + widgets::DEFAULT_DISCLOSURE_STYLE.gap
	);
}

fn void the_header_collapses_and_reopens_its_body() @test
{
	Ui* ui = cui::new_ui(cui_tests::WINDOW);
	defer ui.free();
	Element* section = disclosure_of(ui, true);
	Vec2 header      = { 20, widgets::DEFAULT_DISCLOSURE_STYLE.header_height * 0.5f };

	cui_tests::frame(ui, header, left: true);
	cui_tests::frame(ui, header);
	ui.flush();
	test::eq(changes, 1);
	test::@check(!last_expanded, "the callback did not receive the collapsed state");
	test::eq(section.size.y, widgets::DEFAULT_DISCLOSURE_STYLE.header_height);
	test::eq(section.children[0].size.x, 0.0f);
	test::eq(section.children[0].size.y, 0.0f);

	cui_tests::frame(ui, header, left: true);
	cui_tests::frame(ui, header);
	ui.flush();
	test::eq(changes, 2);
	test::@check(last_expanded, "the callback did not receive the expanded state");
	test::@check(section.size.y > widgets::DEFAULT_DISCLOSURE_STYLE.header_height, "reopening left the body collapsed");
}