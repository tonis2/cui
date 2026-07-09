// Built-in widgets: leaves and layout containers implementing the Widget
// interface from module cui. Apps compose these or write their own widgets
// against the same interface — nothing here is special-cased by the core.
module cui::widgets;
import std::collections::list;
import std::math;

import cui;

// ---------------------------------------------------------------------------
// Rectangle: leaf with a preferred size and an SDF rect style.

struct Rectangle (Widget) {
    Vec2 size;
    RectStyle style;
}

fn Vec2 Rectangle.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    return cui::clamp_size(self.size, constraints);
}

fn void Rectangle.paint(&self, Element* elem, Painter* painter) @dynamic
{
    painter.rect({0, 0}, elem.size, self.style);
}

// ---------------------------------------------------------------------------
// Column / Row: stack children along one axis with a gap. By default they
// wrap their content; a non-zero size fixes that axis, and the alignments
// distribute whatever slack the fixed size (or the incoming constraints)
// creates. A wrap-content container has no slack, so alignment only shows
// when something forces it bigger than its children.

enum MainAlign {
    START,
    CENTER,
    END,
    SPACE_BETWEEN,      // slack becomes equal extra spacing between children
}

enum CrossAlign {
    START,
    CENTER,
    END,
}

struct Column (Widget) {
    float gap;
    Vec2 size;              // per axis: 0 = wrap content
    MainAlign main_align;
    CrossAlign cross_align;
}

fn Vec2 Column.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    sz count = elem.children.len();
    float content = 0;
    float cross = 0;

    for (sz i = 0; i < count; i++) {
        float remaining = math::max(constraints.max.y - content, 0.0f);
        Vec2 child_size = elem.layout_child(i, { .min = {0, 0}, .max = {constraints.max.x, remaining} });
        content += child_size.y;
        if (i + 1 < count) content += self.gap;
        cross = math::max(cross, child_size.x);
    }

    Vec2 own = cui::clamp_size({
        self.size.x > 0 ? self.size.x : cross,
        self.size.y > 0 ? self.size.y : content,
    }, constraints);

    float leftover = math::max(own.y - content, 0.0f);
    float cursor = 0;
    float step = self.gap;
    switch (self.main_align) {
        case START: break;
        case CENTER: cursor = leftover / 2;
        case END: cursor = leftover;
        case SPACE_BETWEEN: if (count > 1) step += leftover / (float)(count - 1);
    }

    for (sz i = 0; i < count; i++) {
        Element* child = elem.children[i];
        float x = 0;
        switch (self.cross_align) {
            case START: x = 0;
            case CENTER: x = (own.x - child.size.x) / 2;
            case END: x = own.x - child.size.x;
        }
        elem.place_child(i, {x, cursor});
        cursor += child.size.y + step;
    }
    return own;
}

struct Row (Widget) {
    float gap;
    Vec2 size;              // per axis: 0 = wrap content
    MainAlign main_align;
    CrossAlign cross_align;
}

fn Vec2 Row.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    sz count = elem.children.len();
    float content = 0;
    float cross = 0;

    for (sz i = 0; i < count; i++) {
        float remaining = math::max(constraints.max.x - content, 0.0f);
        Vec2 child_size = elem.layout_child(i, { .min = {0, 0}, .max = {remaining, constraints.max.y} });
        content += child_size.x;
        if (i + 1 < count) content += self.gap;
        cross = math::max(cross, child_size.y);
    }

    Vec2 own = cui::clamp_size({
        self.size.x > 0 ? self.size.x : content,
        self.size.y > 0 ? self.size.y : cross,
    }, constraints);

    float leftover = math::max(own.x - content, 0.0f);
    float cursor = 0;
    float step = self.gap;
    switch (self.main_align) {
        case START: break;
        case CENTER: cursor = leftover / 2;
        case END: cursor = leftover;
        case SPACE_BETWEEN: if (count > 1) step += leftover / (float)(count - 1);
    }

    for (sz i = 0; i < count; i++) {
        Element* child = elem.children[i];
        float y = 0;
        switch (self.cross_align) {
            case START: y = 0;
            case CENTER: y = (own.y - child.size.y) / 2;
            case END: y = own.y - child.size.y;
        }
        elem.place_child(i, {cursor, y});
        cursor += child.size.x + step;
    }
    return own;
}

// ---------------------------------------------------------------------------
// Padding: insets around a single child; sizes itself to child + insets.

struct Insets {
    float left;
    float top;
    float right;
    float bottom;
}

fn Insets insets_all(float value)
{
    return { value, value, value, value };
}

struct Padding (Widget) {
    Insets insets;
}

fn Vec2 Padding.layout(&self, Element* elem, Constraints constraints) @dynamic
{
    float w = self.insets.left + self.insets.right;
    float h = self.insets.top + self.insets.bottom;
    Constraints inner = {
        .min = { math::max(constraints.min.x - w, 0.0f), math::max(constraints.min.y - h, 0.0f) },
        .max = { math::max(constraints.max.x - w, 0.0f), math::max(constraints.max.y - h, 0.0f) },
    };

    Vec2 child_size = {0, 0};
    if (elem.children.len() > 0) {
        child_size = elem.layout_child(0, inner);
        elem.place_child(0, {self.insets.left, self.insets.top});
    }
    return cui::clamp_size({child_size.x + w, child_size.y + h}, constraints);
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
    own = cui::clamp_size(own, constraints);

    for (sz i = 0; i < elem.children.len(); i++) {
        elem.layout_child(i, { .min = {0, 0}, .max = own });
    }
    return own;
}
