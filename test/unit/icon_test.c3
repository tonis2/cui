// SVG icons: reading the subset, and the distance field each bake makes.
module cui_tests::icons;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// The field's value at a viewBox point: above 0.5 is inside the icon.
fn float sample(String svg, Vec2 at) @local
{
	IconShape shape;
	cui::parse_svg(svg, &shape)!!;
	defer shape.free();
	uint w;
	uint h;
	Vec2 centre;
	char[] px = cui::bake_icon(&shape, 48, 8, &w, &h, &centre);
	defer free(px);
	float k = 48 / math::max(shape.view.z, shape.view.w);
	Vec2 p = centre + (at - (Vec2){ shape.view.x + shape.view.z / 2, shape.view.y + shape.view.w / 2 }) * k;
	return px[(sz)p.y * w + (sz)p.x] / 255.0f;
}

fn void a_filled_square_is_inside_and_its_corner_out() @test
{
	String svg = `<svg viewBox="0 0 12 12"><path d="M2 2 H10 V10 H2 Z"/></svg>`;
	test::@check(sample(svg, { 6, 6 }) > 0.6f, "the middle is inside");
	test::@check(sample(svg, { 1, 1 }) < 0.4f, "outside the corner");
}

fn void relative_commands_draw_the_same_square() @test
{
	IconShape a;
	IconShape b;
	cui::parse_svg(`<svg viewBox="0 0 12 12"><path d="M2 2 H10 V10 H2 Z"/></svg>`, &a)!!;
	cui::parse_svg(`<svg viewBox="0 0 12 12"><path d="m2 2 l8 0 0 8-8 0z"/></svg>`, &b)!!;
	defer a.free();
	defer b.free();
	test::eq(a.edges.len(), b.edges.len());
	foreach (i, e : a.edges)
	{
		test::@check(e.a == b.edges[i].a && e.b == b.edges[i].b, "edge %d matches", i);
	}
}

fn void an_even_odd_ring_has_a_hole() @test
{
	String svg = `<svg viewBox="0 0 12 12"><path fill-rule="evenodd" d="M6 1a5 5 0 1 1 0 10a5 5 0 1 1 0-10zM6 4a2 2 0 1 1 0 4a2 2 0 1 1 0-4z"/></svg>`;
	test::@check(sample(svg, { 6, 6 }) < 0.4f, "the hole is empty");
	test::@check(sample(svg, { 6, 2.5f }) > 0.6f, "the band is filled");
}

fn void a_stroked_line_has_its_width() @test
{
	String svg = `<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2"><line x1="2" y1="6" x2="10" y2="6"/></svg>`;
	test::@check(sample(svg, { 6, 6 }) > 0.6f, "on the line");
	test::@check(sample(svg, { 6, 6.6f }) > 0.5f, "inside its width");
	test::@check(sample(svg, { 6, 8 }) < 0.4f, "off the line");
	test::@check(sample(svg, { 10.5f, 6 }) > 0.5f, "the cap is round, past the end");
}

fn void shapes_and_transforms_land_where_they_say() @test
{
	String svg = `<svg viewBox="-8 -8 16 16"><g transform="translate(3 0)"><circle r="2"/></g><rect x="-7" y="-7" width="3" height="3" rx="1"/></svg>`;
	test::@check(sample(svg, { 3, 0 }) > 0.6f, "the circle moved right");
	test::@check(sample(svg, { 0, 0 }) < 0.4f, "and left the middle");
	test::@check(sample(svg, { -5.5f, -5.5f }) > 0.6f, "the rect is there");
}

fn void bad_svg_is_an_error() @test
{
	IconShape shape;
	test::@check(@catch(cui::parse_svg("not svg", &shape)) == cui::BAD_SVG, "no root");
	shape.free();
}

fn void an_icon_is_one_drawing() @test
{
	Ui* ui = cui::new_ui({ 100, 100 });
	defer ui.free();
	Element* icon = ui.@node((Icon) { .svg = `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/></svg>`, .size = 16, .color = cui::WHITE });
	ui.build(ui.@node((Stack) { }, icon));
	ui.flush();
	test::eq(icon.local_drawings.len(), 1);
	test::@check(icon.local_drawings[0].kind == GLYPH, "drawn as a glyph");
	test::eq(icon.local_drawings[0].size.x, icon.local_drawings[0].size.y);
}

fn void overlapping_fills_leave_no_seam() @test
{
	String svg = `<svg viewBox="0 0 12 12"><rect x="1" y="1" width="6" height="10"/><rect x="5" y="1" width="6" height="10"/></svg>`;
	// x = 6 is the first rect's right edge, hidden inside the second.
	test::@check(sample(svg, { 6, 6 }) > 0.6f, "the hidden edge is still inside");
}
