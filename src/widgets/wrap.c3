<*
 Wrap: children laid out left to right at their own size, starting a new line
 when the next one does not fit.

 The flowing sibling of Row and Grid. A Row runs off the edge of a narrow pane;
 a Grid gives every child the same cell. A toolbar of buttons with different
 words on them wants neither: each keeps its own width, and the strip folds onto
 a second line instead of clipping.

 A child wider than the whole width gets a line of its own, offered the full
 width, rather than an empty line in front of it.
*>
module cui::widgets;

import cui;
import std::math;

struct Wrap (Widget)
{
	float gap_x;
	float gap_y;
	CrossAlign cross_align; // within each line
	Vec2 size; // per axis: 0 = wrap content
}

fn Vec2 Wrap.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	sz count = elem.children.len();
	Vec2 avail = {
		self.size.x > 0 ? math::min(self.size.x, constraints.max.x) : constraints.max.x,
		self.size.y > 0 ? math::min(self.size.y, constraints.max.y) : constraints.max.y,
	};

	for (sz i = 0; i < count; i++) elem.layout_child(i, cui::loose({ avail.x, cui::UNBOUNDED }));

	float y      = 0;
	float widest = 0;
	sz start     = 0;
	while (start < count)
	{
		// Take children onto this line while they fit; the first always goes.
		float x      = elem.children[start].size.x;
		float height = elem.children[start].size.y;
		sz end       = start + 1;
		while (end < count)
		{
			float next = x + self.gap_x + elem.children[end].size.x;
			if (next > avail.x) break;
			x = next;
			height = math::max(height, elem.children[end].size.y);
			end++;
		}

		float cursor = 0;
		for (sz i = start; i < end; i++)
		{
			Element* child = elem.children[i];
			float offset   = 0;
			switch (self.cross_align)
			{
				case CENTER: offset = (height - child.size.y) * 0.5f;
				case END: offset = height - child.size.y;
				case START: break;
			}
			elem.place_child(i, { cursor, y + offset });
			cursor += child.size.x + self.gap_x;
		}
		widest = math::max(widest, x);
		y += height;
		start = end;
		if (start < count) y += self.gap_y;
	}

	return constraints.constrain(
		{
			self.size.x > 0 ? self.size.x : widest,
			self.size.y > 0 ? self.size.y : y,
		}
	);
}