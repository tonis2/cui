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

typedef Color = Vec4;

const Color WHITE = {1.0, 1.0, 1.0, 1.0};
const Color BLACK = {0.0, 0.0, 0.0, 1.0};
const Color BLUE = {0.5, 0.5, 0.5, 1.0};

// A widget is behavior attached to an Element. All methods are optional:
//
//   layout    given constraints, return own size; lay out children through
//             elem.layout_child / elem.place_child. Omitted: children get loose
//             constraints and keep their offsets, size fills the constraints.
//   paint     emit primitives in element-local coordinates. Omitted: the
//             element draws nothing itself (pure container).
//   on_mouse  press/release/move/scroll, hit-tested and bubbling: the deepest
//             element under the pointer gets it first; return true to consume.
//             Consuming a PRESS captures the mouse until that button releases.
//   on_hover  pointer entered (true) / left (false) this element.
//   on_key    key press/release edges, delivered to the focused element (left
//             click focuses; see Element.request_focus), bubbling like on_mouse.
//   update    called every frame with the frame's dt — for animations and
//             polling ui.input; mutate state then request_paint().
//   unmount   free whatever the widget allocated; called when its element
//             leaves the tree. The widget struct itself stays caller-owned.
//
// The built-in implementations (Rectangle, Column, Row, Stack, Padding,
// Button) live in module cui::widgets; apps write their own against this
// interface.
interface Widget
{
    fn Vec2 layout(Element* elem, Constraints constraints) @optional;
    fn void paint(Element* elem, Painter* painter) @optional;
    fn bool on_mouse(Element* elem, MouseEvent event) @optional;
    fn void on_hover(Element* elem, bool entered) @optional;
    fn bool on_key(Element* elem, KeyEvent event) @optional;
    fn void update(Element* elem, float dt) @optional;
    fn void unmount() @optional;
}

fn Vec2 Vec2.constrain(self, Constraints c) {
	return {
        math::max(c.min.x, math::min(self.x, c.max.x)),
        math::max(c.min.y, math::min(self.y, c.max.y)),
    };
}

// Clamps a wanted size into the given constraints; the usual last step of a
// layout implementation.
fn Vec2 clamp_size(Vec2 size, Constraints c)
{
    return {
        math::max(c.min.x, math::min(size.x, c.max.x)),
        math::max(c.min.y, math::min(size.y, c.max.y)),
    };
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
    Vec2 absolute;              // origin in UI coordinates, stored by the last
                                // emit pass; hit testing reads it
    Cursor cursor;              // preferred pointer shape while hovered
                                // (DEFAULT = defer to ancestors)

    // Paint cache, in element-local coordinates. Emitting shifts copies by the
    // absolute origin, so a moved-but-clean element never re-paints.
    List{Drawing} local_drawings;
    sz first_drawing;          // slice of Canvas.drawings written by last emit
    sz drawing_count;

    uint transform_slot;

    bool owns_widget;           // widget is a heap copy made by @node; freed on release
    DirtyFlags dirty;
}

struct Ui {
    Element* root;
    Canvas canvas;
    Vec2 size;                  // root constraints, usually the window size

    // Interactivity state, maintained by Ui.process_input (input.c3).
    Input input;                // per-frame queryable state — the "context"
    Cursor cursor;              // effective pointer shape, for the embedder
    Element* hovered;
    Element* captured;          // consumer of an in-flight press, if any
    MouseButton capture_button;
    Element* focused;           // receiver of key events
    List{Key} held_keys;

    // Elements are recycled through a free-list so Element* stays stable for
    // the lifetime of the Ui; all_elements exists only for final cleanup.
    List{Element*} free_elements;
    List{Element*} all_elements;
    List{uint} free_transform_slots;

    bool layout_pending;
    bool paint_pending;
    bool frame_requested;       // "schedule a frame": set by every invalidation
                                // below. A render loop that sleeps when idle
                                // (see cui::vulkan LoopMode) reads and clears
                                // this to decide whether to block for input.
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
    self.held_keys.free();
    self.canvas.free();
    mem::free(self);
}

// ---------------------------------------------------------------------------
// Tree building

// Declarative building: create an element for a widget together with its
// children, Flutter-style. Pass the widget as a VALUE (a struct literal — the
// element heap-copies and owns it) or as a POINTER (borrowed; the caller owns
// the struct and can mutate it, but must keep it alive). Children are
// elements built by nested @node calls. Attach the finished tree with
// Ui.build, or graft it onto a live element with Element.append.
//
//   ui.build(ui.@node((Column){ .gap = 8.0 },
//       ui.@node((Rectangle){ .size = {100, 40} }),
//       ui.@node((Rectangle){ .size = {100, 40} })));
macro Element* Ui.@node(&self, widget, ...)
{
    $if @kindof(widget) == POINTER:
        return self.attach_node(widget, false, ...$vaarg);
    $else
        var $Type = $Typeof(widget);
        $Type* copy = mem::new($Type);
        *copy = widget;
        return self.attach_node(copy, true, ...$vaarg);
    $endif
}

// The inverse of @node: recover the concrete widget behind an element as a
// typed pointer. An Element* is a stable handle to a tree node (it survives
// relayout and repaint), so holding one is CUI's equivalent of a Flutter
// GlobalKey — a callback that keeps it can read and mutate that widget's own
// state, then request_paint(), without a wrapper struct. Unchecked: the caller
// asserts $Type, the same assertion it made when it built the node.
macro Element.widget_as(&self, $Type)
{
    return ($Type*)((any)self.widget).ptr;
}

// Query the retained tree by widget type: the first element whose widget is
// exactly $Type, or null. The top-down analog of Flutter's
// findAncestorStateOfType. The returned Element* is a stable handle, so it
// stays valid across frames — hold it, or just re-query each time.
macro Element* Ui.find(&self, $Type)
{
    return self.root ? find_by_type(self.root, $Type) : null;
}

fn Element* find_by_type(Element* elem, typeid type) @private
{
    if (((any)elem.widget).type == type) return elem;
    foreach (child : elem.children) {
        Element* hit = find_by_type(child, type);
        if (hit) return hit;
    }
    return null;
}

// The fault get_widget raises when the tree holds no widget of the asked type.
faultdef WIDGET_NOT_FOUND;

// Convenience twins of Element.widget_as / Element.request_paint that resolve a
// widget by type. get_widget(Dial) hands back a Dial* to mutate, or a
// WIDGET_NOT_FOUND fault if the tree has none — so a caller can guard it with
// `if (try dial = ui.get_widget(Dial))` or assert with `!!`. request_paint(Dial)
// invalidates it (a no-op if absent). A callback reaches these through a Ui it
// is handed — a Button passes its own element's ui to on_click, so no global and
// no app-threaded handle are needed. Both act on the first $Type in the tree, so
// they fit singletons (one Dial, one settings panel); keep an explicit Element*
// handle (the one @node returns) when several of a kind coexist.
macro Ui.get_widget(&self, $Type)
{
    Element* elem = self.find($Type);
    if (!elem) return WIDGET_NOT_FOUND~;
    return elem.widget_as($Type);
}

macro Ui.request_paint(&self, $Type)
{
    Element* elem = self.find($Type);
    if (elem) elem.request_paint();
}

// Installs a built tree as the UI root, releasing any previous root.
fn void Ui.build(&self, Element* root)
{
    if (self.root && self.root != root) self.release(self.root);
    root.parent = null;
    self.root = root;
    self.layout_pending = true;
    self.paint_pending = true;
    self.frame_requested = true;
}

// Grafts a built subtree under a live element.
fn void Element.append(&self, Element* child)
{
    child.parent = self;
    self.children.push(child);
    self.request_layout();
}

fn Element* Ui.attach_node(&self, Widget widget, bool owned, Element*... children)
{
    Element* element = self.alloc_element();
    element.ui = self;
    element.widget = widget;
    element.owns_widget = owned;
    element.transform_slot = NO_TRANSFORM;
    element.dirty = { .layout = true, .paint = true };
    foreach (child : children) {
        child.parent = element;
        element.children.push(child);
    }
    return element;
}

// Attaches a widget to the tree (as root when parent is null). The widget
// struct is owned by the caller and must outlive the element.
fn Element* Ui.mount(&self, Widget widget, Element* parent = null)
{
    Element* element = self.attach_node(widget, false);

    if (parent) {
        element.parent = parent;
        parent.children.push(element);
        parent.request_layout();
    } else {
        self.root = element;
        self.layout_pending = true;
        self.paint_pending = true;
    }
    self.frame_requested = true;
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
    self.frame_requested = true;
}

fn void Ui.release(&self, Element* element)
{
    foreach (child : element.children) self.release(child);
    if (&element.widget.unmount) element.widget.unmount();
    if (element.owns_widget) mem::free(((any)element.widget).ptr);
    if (element.transform_slot != NO_TRANSFORM) self.free_transform_slots.push(element.transform_slot);
    // Elements get recycled — a stale interactivity pointer would silently
    // retarget whatever reuses this slot.
    if (self.hovered == element) self.hovered = null;
    if (self.captured == element) self.captured = null;
    if (self.focused == element) self.focused = null;
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

// Schedules a frame. An on-demand render loop (one that sleeps when nothing is
// happening) wakes and draws when this is set. Every invalidation below calls
// it, so ordinary state changes schedule a frame for free; a continuous
// animation keeps calling it each frame itself — the analog of a Flutter Ticker
// re-scheduling — and simply stops when it's done, letting the loop sleep.
fn void Ui.request_frame(&self)
{
    self.frame_requested = true;
}

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
    self.ui.frame_requested = true;
}

// Appearance changed but not size: only this element's paint() re-runs.
fn void Element.request_paint(&self)
{
    self.dirty.paint = true;
    self.ui.paint_pending = true;
    self.ui.frame_requested = true;
}

// Manual placement under an absolute container (Stack). Cheap: the subtree's
// cached drawings are re-emitted at the new origin, no paint() calls.
fn void Element.set_offset(&self, Vec2 offset)
{
    self.offset = offset;
    self.ui.paint_pending = true;
    self.ui.frame_requested = true;
}

// Directs key events to this element (a left click on an element whose widget
// implements on_key does the same automatically).
fn void Element.request_focus(&self)
{
    self.ui.focused = self;
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
    ui.frame_requested = true;
}

fn uint Ui.alloc_transform_slot(&self)
{
    if (try slot = self.free_transform_slots.pop()) return slot;
    self.canvas.transforms.push(matrix::IDENTITY4);
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
    element.absolute = absolute;       // hit testing reads this
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

fn bool vec2_eq(Vec2 a, Vec2 b) => a.x == b.x && a.y == b.y;

// ---------------------------------------------------------------------------
// Painter: what Widget.paint implementations draw with. Positions are local to
// the element; the emit pass translates them to absolute coordinates.
//
// All units are pixels; angles are radians with 0 = +x, increasing clockwise
// on screen (y points down). Corner radii run {top-left, top-right,
// bottom-right, bottom-left} and are clamped to what the shape can fit.
// Borders are drawn inside the shape's edge.

struct RectStyle {
    Color color;
    Color border_color;
    float border_width;     // px, inside the edge
    Vec4 border_radius;     // per-corner px {TL, TR, BR, BL}
    Texture texture;        // from Renderer.load_image; default = untextured
}

struct CircleStyle {
    Color color;
    Color border_color;
    float border_width;     // px, inside the edge
    Texture texture;        // sampled across the shape's bounding box
}

struct Painter {
    Element* element;
}

fn void Painter.rect(&self, Vec2 pos, Vec2 size, RectStyle style = {})
{
    self.element.local_drawings.push({
        .kind = DrawingKind.RECT,
        .texture = (int)style.texture,
        .border_width = style.border_width,
        .size = size,
        .corner = pos,
        .params = style.border_radius,
        .color = (Vec4)style.color,
        .border_color = (Vec4)style.border_color,
    });
}

fn void Painter.circle(&self, Vec2 center, float radius, CircleStyle style = {})
{
    self.ellipse(center, {radius, radius}, style);
}

fn void Painter.ellipse(&self, Vec2 center, Vec2 radii, CircleStyle style = {})
{
    Vec2 half = radii + 1.0f;   // 1px pad so the edge antialiasing isn't clipped
    self.element.local_drawings.push({
        .kind = DrawingKind.ELLIPSE,
        .texture = (int)style.texture,
        .border_width = style.border_width,
        .size = half * 2.0f,
        .corner = center - half,
        .params = {radii.x, radii.y, 0, 0},
        .color = (Vec4)style.color,
        .border_color = (Vec4)style.border_color,
    });
}

// Line segment with rounded caps.
fn void Painter.line(&self, Vec2 from, Vec2 to, float thickness, Color color)
{
    float pad = thickness * 0.5f + 1.0f;
    Vec2 lo = { math::min(from.x, to.x) - pad, math::min(from.y, to.y) - pad };
    Vec2 hi = { math::max(from.x, to.x) + pad, math::max(from.y, to.y) + pad };
    Vec2 center = (lo + hi) * 0.5f;
    self.element.local_drawings.push({
        .kind = DrawingKind.LINE,
        .border_width = thickness,
        .size = hi - lo,
        .corner = lo,
        .params = {from.x - center.x, from.y - center.y, to.x - center.x, to.y - center.y},
        .color = (Vec4)color,
    });
}

// Stroked circular arc: from `start`, spanning `sweep` radians, rounded caps.
// A sweep of 2π or more draws the full ring — progress rings and spinners.
fn void Painter.arc(&self, Vec2 center, float radius, float start, float sweep, float thickness, Color color)
{
    float pad = radius + thickness * 0.5f + 1.0f;
    self.element.local_drawings.push({
        .kind = DrawingKind.ARC,
        .border_width = thickness,
        .size = {pad * 2, pad * 2},
        .corner = center - pad,
        .params = {radius, start, sweep, 0},
        .color = (Vec4)color,
    });
}

// Soft drop shadow of a (rounded) rect at pos/size: the edge fades over
// `blur` px each way. Paint it before the shape casting it; a border_radius
// of half the size makes it circular.
fn void Painter.rect_shadow(&self, Vec2 pos, Vec2 size, float blur, Color color, Vec4 border_radius = {})
{
    self.element.local_drawings.push({
        .kind = DrawingKind.SHADOW,
        .border_width = blur,
        .size = size + 2.0f * blur,
        .corner = pos - blur,
        .params = border_radius,
        .color = (Vec4)color,
    });
}
