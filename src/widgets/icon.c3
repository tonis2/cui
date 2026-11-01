<*
 SVG icons as widgets: `Icon` draws one, `@icon_button` is the usual
 tooltip-button-icon stack.

 ```c3
 const String SAVE = $embed("icons/save.svg");
 widgets::@icon_button(SAVE, "Save the file", (Button) { .size = { 24, 24 }, .on_click = &save });
 ```
*>
module cui::widgets;
import cui;
import std::math;

<*
 One SVG icon, centred in the space it takes.
*>
struct Icon (Widget)
{
	String svg; // borrowed; a $embed or a literal
	float size; // the viewBox's long side, in pixels
	Color color;
	Vec2 box; // per axis: 0 = the space offered (or `size` when that is unbounded)
}

fn Vec2 Icon.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 want = self.box;
	if (want.x == 0) want.x = constraints.max.x < cui::UNBOUNDED ? constraints.max.x : self.size;
	if (want.y == 0) want.y = constraints.max.y < cui::UNBOUNDED ? constraints.max.y : self.size;
	return constraints.constrain(want);
}

fn void Icon.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.icon(elem.size * 0.5f, self.size, self.svg, self.color);
}

<*
 A button showing an icon, with a tooltip. Use inside a `@tree` body.

 @param svg : "The icon"
 @param text : "The tooltip"
 @param button : "The button: size, styles and on_click"
 @param ink : "The icon's colour"
 @return "The button element, for with_id"
*>
macro Element* @icon_button(String svg, String text, Button button, Color ink, float size = 16, String hint = "")
{
	Element* made;
	@tree(tip(text, hint))
	{
		made = @tree(button)
		{
			@node((Icon) { .svg = svg, .size = size, .color = ink });
		};
	};
	return made;
}
