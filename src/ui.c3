module cui;
import std::io;
import std::collections::list;
import std::math;

// Retained widget core.
//
// The user owns widget structs; the library owns the element tree that gives
// them identity, cached layout, and a paint cache. Nothing is diffed or
// re-computed on its own: state changes go through explicit invalidation
// (request_layout / request_paint / set_transform), and clean elements are
// re-emitted from their cached drawings without their widget code running.
//
// Per-frame cost by kind of change:
//   set_transform   one matrix write, palette re-upload. No layout, no paint.
//   request_paint   that element's paint() re-runs; everything else is cache.
//   request_layout  the dirty spine re-layouts (constraint cache prunes the
//                   rest), then the display list is re-emitted.
//   nothing         flush() returns immediately; the GPU redraws the retained
//                   display list without any upload.

// Sentinel: element has no palette slot and inherits its ancestor's.
const uint NO_TRANSFORM = 0xFFFF_FFFF;

struct Constraints {
    Vec2 min;
    Vec2 max;
}

bitstruct DirtyFlags : char {
    bool layout;
    bool paint;
}

struct Element {
    Ui* ui;
    Widget widget;
    Element* parent;
    List{Element*} children;

    // Layout cache: size is valid for last_constraints.
    Constraints last_constraints;
    Vec2 size;
    Vec2 offset;                // relative to parent; set by the parent's layout
                                // (or by the user under an absolute container)

    // Paint cache, in element-local coordinates. Emitting shifts copies by the
    // absolute origin, so a moved-but-clean element never re-paints.
    List{Drawing} local_drawings;
    sz first_drawing;          // slice of Canvas.drawings written by last emit
    sz drawing_count;

    uint transform_slot;

    DirtyFlags dirty;
}

struct Ui {
    Element* root;
    Canvas canvas;
    Vec2 size;                  // root constraints, usually the window size

    // Elements are recycled through a free-list so Element* stays stable for
    // the lifetime of the Ui; all_elements exists only for final cleanup.
    List{Element*} free_elements;
    List{Element*} all_elements;
    List{uint} free_transform_slots;

    bool layout_pending;
    bool paint_pending;
}

// Heap-allocated so Element.ui stays valid; released with Ui.free().
fn Ui* new_ui(Vec2 size)
{
    Ui* ui = mem::new(Ui);
    ui.size = size;
    ui.canvas.init();
    return ui;
}

fn void Ui.free(&self)
{
    if (self.root) self.release(self.root);
    foreach (element : self.all_elements) mem::free(element);
    self.all_elements.free();
    self.free_elements.free();
    self.free_transform_slots.free();
    self.canvas.free();
    mem::free(self);
}

// ---------------------------------------------------------------------------
// Tree building

// Attaches a widget to the tree (as root when parent is null). The widget
// struct is owned by the caller and must outlive the element.
fn Element* Ui.mount(&self, Widget widget, Element* parent = null)
{
    Element* element = self.alloc_element();
    element.ui = self;
    element.widget = widget;
    element.parent = parent;
    element.transform_slot = NO_TRANSFORM;
    element.dirty = { .layout = true, .paint = true };

    if (parent) {
        parent.children.push(element);
        parent.request_layout();
    } else {
        self.root = element;
        self.layout_pending = true;
        self.paint_pending = true;
    }
    return element;
}

// Removes an element (and its subtree) while the app runs. Widgets get their
// unmount() hook to free whatever they own; elements go back to the free-list.
fn void Ui.unmount(&self, Element* element)
{
    Element* parent = element.parent;
    if (parent) {
        foreach (sz i, child : parent.children) {
            if (child == element) {
                parent.children.remove_at(i);
                break;
            }
        }
        parent.request_layout();
    } else if (self.root == element) {
        self.root = null;
    }
    self.release(element);
    self.paint_pending = true;
}

fn void Ui.release(&self, Element* element)
{
    foreach (child : element.children) self.release(child);
    if (&element.widget.unmount) element.widget.unmount();
    if (element.transform_slot != NO_TRANSFORM) self.free_transform_slots.push(element.transform_slot);
    element.children.free();
    element.local_drawings.free();
    *element = {};
    self.free_elements.push(element);
}

fn Element* Ui.alloc_element(&self)
{
    if (try element = self.free_elements.pop()) return element;
    Element* element = mem::new(Element);
    self.all_elements.push(element);
    return element;
}

// ---------------------------------------------------------------------------
// Invalidation — the only way anything gets recomputed.

// Size or child structure changed: re-layout from here, repaint here. Ancestors
// are marked so the layout walk descends to this element; their own cached
// sizes still short-circuit if nothing about them changes.
fn void Element.request_layout(&self)
{
    self.dirty.layout = true;
    self.dirty.paint = true;
    for (Element* p = self.parent; p != null && !p.dirty.layout; p = p.parent) p.dirty.layout = true;
    self.ui.layout_pending = true;
    self.ui.paint_pending = true;
}

// Appearance changed but not size: only this element's paint() re-runs.
fn void Element.request_paint(&self)
{
    self.dirty.paint = true;
    self.ui.paint_pending = true;
}

// Manual placement under an absolute container (Stack). Cheap: the subtree's
// cached drawings are re-emitted at the new origin, no paint() calls.
fn void Element.set_offset(&self, Vec2 offset)
{
    self.offset = offset;
    self.ui.paint_pending = true;
}

// Animation path: writes one matrix into the palette. The first call allocates
// a slot (forcing one re-emit so the subtree picks up the slot id); every call
// after that costs a 64-byte write plus a palette upload, regardless of how
// many drawings sit under this element.
fn void Element.set_transform(&self, Matrix4f transform)
{
    Ui* ui = self.ui;
    if (self.transform_slot == NO_TRANSFORM) {
        self.transform_slot = ui.alloc_transform_slot();
        ui.paint_pending = true;
    }
    // Stored as-is: the shader reads the palette as raw float4 rows matching
    // Matrix4f's row-major storage (see shader.slang PushData).
    ui.canvas.transforms[self.transform_slot] = transform;
    ui.canvas.transforms_dirty = true;
}

fn uint Ui.alloc_transform_slot(&self)
{
    if (try slot = self.free_transform_slots.pop()) return slot;
    self.canvas.transforms.push(MATRIX4F_IDENTITY);
    return (uint)self.canvas.transforms.len() - 1;
}

// ---------------------------------------------------------------------------
// Layout helpers available to Widget.layout implementations.

fn Vec2 Element.layout_child(&self, sz index, Constraints constraints)
{
    return self.ui.layout_element(self.children[index], constraints);
}

fn void Element.place_child(&self, sz index, Vec2 offset)
{
    self.children[index].offset = offset;
}

// ---------------------------------------------------------------------------
// Frame flush: layout pass, then paint + emit pass. Call once per frame before
// the renderer consumes the canvas.

fn void Ui.flush(&self)
{
    if (self.root == null) return;

    if (self.layout_pending) {
        self.layout_element(self.root, { .min = self.size, .max = self.size });
        self.layout_pending = false;
    }

    if (self.paint_pending) {
        self.canvas.drawings.clear();
        self.emit(self.root, {0, 0}, 0);
        self.canvas.drawings_dirty = true;
        self.paint_pending = false;
    }
}

fn Vec2 Ui.layout_element(&self, Element* element, Constraints constraints)
{
    // Cache hit: not dirty and same constraints means same size, and none of
    // the subtree's layout code runs.
    if (!element.dirty.layout
        && vec2_eq(constraints.min, element.last_constraints.min)
        && vec2_eq(constraints.max, element.last_constraints.max)) {
        return element.size;
    }

    element.last_constraints = constraints;
    element.dirty.layout = false;

    Vec2 size;
    if (&element.widget.layout) {
        size = element.widget.layout(element, constraints);
    } else if (element.children.len() > 0) {
        // Default for layout-less containers: children get loose constraints
        // and keep their offsets; the container fills the available space.
        foreach (child : element.children) {
            self.layout_element(child, { .min = {0, 0}, .max = constraints.max });
        }
        size = constraints.max;
    } else {
        size = constraints.min;
    }

    if (!vec2_eq(size, element.size)) {
        element.size = size;
        element.dirty.paint = true;
        self.paint_pending = true;
    }
    return size;
}

fn void Ui.emit(&self, Element* element, Vec2 origin, uint inherited_slot)
{
    Vec2 absolute = origin + element.offset;
    uint slot = element.transform_slot != NO_TRANSFORM ? element.transform_slot : inherited_slot;

    if (element.dirty.paint) {
        element.local_drawings.clear();
        if (&element.widget.paint) {
            Painter painter = { .element = element };
            element.widget.paint(element, &painter);
        }
        element.dirty.paint = false;
    }

    element.first_drawing = self.canvas.drawings.len();
    foreach (drawing : element.local_drawings) {
        drawing.corner += absolute;
        drawing.transform_id = slot;
        self.canvas.drawings.push(drawing);
    }
    element.drawing_count = self.canvas.drawings.len() - element.first_drawing;

    foreach (child : element.children) self.emit(child, absolute, slot);
}

fn bool vec2_eq(Vec2 a, Vec2 b)
{
    return a.x == b.x && a.y == b.y;
}

// ---------------------------------------------------------------------------
// Painter: what Widget.paint implementations draw with. Positions are local to
// the element; the emit pass translates them to absolute coordinates.

struct RectStyle {
    Color color;
    Color border_color;
    float border_width;
    Vec4 border_radius;
    int texture;            // 0 = none, else renderer image index + 1
}

struct Painter {
    Element* element;
}

fn void Painter.rect(&self, Vec2 pos, Vec2 size, RectStyle style = {})
{
    self.element.local_drawings.push({
        .kind = DRAWING_RECT,
        .texture = style.texture,
        .border_width = style.border_width,
        .size = size,
        .corner = pos,
        .border_radius = style.border_radius,
        .color = (Vec4)style.color,
        .border_color = (Vec4)style.border_color,
    });
}
