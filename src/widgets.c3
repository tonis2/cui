module cui;
import std::io;
import std::collections::list;
import std::math;

typedef Color = Vec4;

const Color WHITE = {1.0, 1.0, 1.0, 1.0};
const Color BLACK = {0.0, 0.0, 0.0, 1.0};
const Color BLUE = {0.5, 0.5, 0.5, 1.0};

// A widget is behavior attached to an Element. All methods are optional:
//
//   layout   given constraints, return own size; lay out children through
//            elem.layout_child / elem.place_child. Omitted: children get loose
//            constraints and keep their offsets, size fills the constraints.
//   paint    emit primitives in element-local coordinates. Omitted: the
//            element draws nothing itself (pure container).
//   unmount  free whatever the widget allocated; called when its element
//            leaves the tree. The widget struct itself stays caller-owned.
interface Widget
{
    fn Vec2 layout(Element* elem, Constraints constraints) @optional;
    fn void paint(Element* elem, Painter* painter) @optional;
    fn void unmount() @optional;
}

fn Vec2 clamp_size(Vec2 size, Constraints c)
{
    return {
        math::max(c.min.x, math::min(size.x, c.max.x)),
        math::max(c.min.y, math::min(size.y, c.max.y)),
    };
}

// ---------------------------------------------------------------------------
// Rectangle: leaf with a preferred size and an SDF rect style.

struct Rectangle (Widget) {
    Vec2 size;
    RectStyle style;
}

fn Vec2 Rectangle.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    return clamp_size(self.size, constraints);
}

fn void Rectangle.paint(&self, Element* elem, Painter* painter) @dynamic
{
    painter.rect({0, 0}, elem.size, self.style);
}

// ---------------------------------------------------------------------------
// Column / Row: stack children along one axis with a gap, wrap their extent.

struct Column (Widget) {
    float gap;
}

fn Vec2 Column.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    float main = 0;
    float cross = 0;
    sz count = elem.children.len();

    for (sz i = 0; i < count; i++) {
        float remaining = math::max(constraints.max.y - main, 0.0f);
        Vec2 child_size = elem.layout_child(i, { .min = {0, 0}, .max = {constraints.max.x, remaining} });
        elem.place_child(i, {0, main});
        main += child_size.y + self.gap;
        cross = math::max(cross, child_size.x);
    }
    if (count > 0) main -= self.gap;

    return clamp_size({cross, main}, constraints);
}

struct Row (Widget) {
    float gap;
}

fn Vec2 Row.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    float main = 0;
    float cross = 0;
    sz count = elem.children.len();

    for (sz i = 0; i < count; i++) {
        float remaining = math::max(constraints.max.x - main, 0.0f);
        Vec2 child_size = elem.layout_child(i, { .min = {0, 0}, .max = {remaining, constraints.max.y} });
        elem.place_child(i, {main, 0});
        main += child_size.x + self.gap;
        cross = math::max(cross, child_size.y);
    }
    if (count > 0) main -= self.gap;

    return clamp_size({main, cross}, constraints);
}

// ---------------------------------------------------------------------------
// Stack: absolute container. Children are positioned by Element.set_offset and
// sized by their own layout under loose constraints.

struct Stack (Widget) {
    Vec2 size;      // zero on an axis = fill the available space
}

fn Vec2 Stack.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    Vec2 own = {
        self.size.x > 0 ? self.size.x : constraints.max.x,
        self.size.y > 0 ? self.size.y : constraints.max.y,
    };
    own = clamp_size(own, constraints);

    for (sz i = 0; i < elem.children.len(); i++) {
        elem.layout_child(i, { .min = {0, 0}, .max = own });
    }
    return own;
}
