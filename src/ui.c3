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
//   request_build   a composite drops its built subtree and re-runs build(),
//                   then layout + paint as above (request_paint on a build
//                   widget routes here — see Element.request_paint).
//   nothing         flush() returns immediately; the GPU redraws the retained
//                   display list without any upload.

// Sentinel: element has no palette slot and inherits its ancestor's.
const uint NO_TRANSFORM = 0xFFFF_FFFF;

// "Unbounded" constraint for scrollable axes. Deliberately finite: float.inf
// would turn a fill-to-max widget (a Stack with size 0) into an infinite
// element and NaNs downstream; 1e9 keeps the arithmetic sane. Fill-parent
// widgets must not be unbounded-axis children of a Scroll.
const float UNBOUNDED = 1e9;

struct Constraints
{
	Vec2 min;
	Vec2 max;
}

bitstruct DirtyFlags : char
{
	bool build;
	bool layout;
	bool paint;
}

typedef Color = Vec4;

const Color WHITE = { 1.0, 1.0, 1.0, 1.0 };
const Color BLACK = { 0.0, 0.0, 0.0, 1.0 };
const Color BLUE  = { 0.5, 0.5, 0.5, 1.0 };

// A widget is behavior attached to an Element. All methods are optional:
// 
//   build     compose this widget out of existing widgets: return a subtree
//             made with elem.ui.@node — the framework attaches it as the
//             element's single child on the flush after the element enters the
//             tree (a build widget takes no @node children of its own; the
//             built subtree IS its content). With layout omitted, the element
//             sizes itself to the built subtree. After mutating fields, call
//             elem.request_build() (or use ui.@modify) to regenerate the
//             subtree. Must be pure: read own fields, produce nodes — state
//             that must survive a rebuild lives on the composite, not inside
//             the built subtree. See test/composite.c3 and build.md.
//   layout    given constraints, return own size; lay out children through
//             elem.layout_child / elem.place_child. Omitted: a build widget
//             delegates to its built subtree; otherwise children get loose
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
	fn Element* build(Element* elem) @optional;
	fn Vec2 layout(Element* elem, Constraints constraints) @optional;
	fn void paint(Element* elem, Painter* painter) @optional;
	fn bool on_mouse(Element* elem, MouseEvent event) @optional;
	fn void on_hover(Element* elem, bool entered) @optional;
	fn bool on_key(Element* elem, KeyEvent event) @optional;
	fn void update(Element* elem, float dt) @optional;
	fn void unmount() @optional;
}

fn Vec2 Vec2.constrain(self, Constraints c)
{
	return { math::max(c.min.x, math::min(self.x, c.max.x)), math::max(c.min.y, math::min(self.y, c.max.y)), };
}

// Clamps a wanted size into the given constraints; the usual last step of a
// layout implementation.
fn Vec2 clamp_size(Vec2 size, Constraints c)
{
	return { math::max(c.min.x, math::min(size.x, c.max.x)), math::max(c.min.y, math::min(size.y, c.max.y)), };
}

struct Element
{
	Ui* ui;
	Widget widget;
	String id; // optional app-chosen name; find_id / get_widget_id
	// resolve it. Empty = unkeyed. Borrowed — the string
	// must outlive the element (a literal is ideal).
	Element* parent;
	List{Element*} children;

	// Layout cache: size is valid for last_constraints.
	Constraints last_constraints;
	Vec2 size;
	Vec2 offset; // relative to parent; set by the parent's layout
	// (or by the user under an absolute container)
	Vec2 absolute; // origin in UI coordinates, stored by the last
	// emit pass; hit testing reads it
	Cursor cursor; // preferred pointer shape while hovered
	// (DEFAULT = defer to ancestors)

	// Paint cache, in element-local coordinates. Emitting shifts copies by the
	// absolute origin, so a moved-but-clean element never re-paints.
	List{Drawing} local_drawings;
	sz first_drawing; // slice of Canvas.drawings written by last emit
	sz drawing_count;

	uint transform_slot;

	// Clipping: when set (widgets set it from layout(), like cursor), emit
	// clips this element's own drawings and its whole subtree to the element's
	// rect, rounded by clip_radii {TL, TR, BR, BL}. Nested clips intersect
	// (axis-aligned; the inner radii win — a documented approximation). Hit
	// testing is gated by the same rect.
	bool clips;
	Vec4 clip_radii;

	bool owns_widget; // widget is a heap copy made by @node; freed on release
	DirtyFlags dirty;
}

struct Ui
{
	Element* root;
	Canvas canvas;
	Vec2 size; // root constraints, usually the window size

	// Interactivity state, maintained by Ui.process_input (input.c3).
	Input input; // per-frame queryable state — the "context"
	Cursor cursor; // effective pointer shape, for the embedder
	Element* hovered;
	Element* captured; // consumer of an in-flight press, if any
	MouseButton capture_button;
	Element* focused; // receiver of key events
	List{Key} held_keys;

	// Elements are recycled through a free-list so Element* stays stable for
	// the lifetime of the Ui; all_elements exists only for final cleanup.
	List{Element*} free_elements;
	List{Element*} all_elements;
	List{uint} free_transform_slots;

	bool build_pending;
	bool layout_pending;
	bool paint_pending;
	bool frame_requested; // "schedule a frame": set by every invalidation
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

// The fault find / find_id (and the get_widget twins built on them) raise when
// the tree holds no matching node — so a lookup guards with `if (try elem =
// ui.find(Dial))` or asserts with `!!`.
faultdef WIDGET_NOT_FOUND;

// Query the retained tree by widget type: the first element whose widget is
// exactly $Type, or a WIDGET_NOT_FOUND fault. The top-down analog of Flutter's
// findAncestorStateOfType. The returned Element* is a stable handle (valid
// across frames), and it is *the* thing to hold when a callback will both read
// and invalidate a widget: resolve it once here, then widget_as (a cast) and
// request_paint (a flag flip) are both search-free. That is the hot path — the
// get_widget / request_paint twins below each re-walk the tree, so pairing them
// to mutate-then-repaint one node walks it twice. Use those only for one-shots.
macro Ui.find(&self, $Type)
{
	Element* elem = self.root ? find_by_type(self.root, $Type) : null;
	if (!elem) return WIDGET_NOT_FOUND~;
	return elem;
}

fn Element* find_by_type(Element* elem, typeid type) @private
{
	if (((any)elem.widget).type == type) return elem;
	foreach (child : elem.children)
	{
		Element* hit = find_by_type(child, type);
		if (hit) return hit;
	}
	return null;
}

// One-shot convenience over find: hand back the widget pointer directly
// (get_widget(Dial) → Dial*), or re-raise WIDGET_NOT_FOUND. One tree walk —
// right for reading a singleton's field. To mutate AND repaint, hold the
// Element* from find instead, so invalidation doesn't walk the tree a second
// time. A callback reaches these through a Ui it is handed — a Button passes its
// own element's ui to on_click, so no global and no app-threaded handle is
// needed. Both act on the first $Type in the tree, so they fit singletons (one
// Dial, one settings panel); name a node with .with_id when several coexist.
macro Ui.get_widget(&self, $Type)
{
	if (try elem = self.find($Type)) return elem.widget_as($Type);
	return WIDGET_NOT_FOUND~;
}

// One-shot invalidate by type: one tree walk, a no-op if absent. Same caveat —
// if you already hold the element, call elem.request_paint() and skip the walk.
macro Ui.request_paint(&self, $Type)
{
	if (try elem = self.find($Type)) elem.request_paint();
}

// ---------------------------------------------------------------------------
// Query the tree by app-chosen id — the escape hatch for when several widgets
// of a kind coexist, where a bare type lookup can't say which one you mean (its
// Flutter analog is a GlobalKey). Stamp a node with .with_id while building,
// then reach exactly that node by name from anywhere. This mirrors the type
// family above one-for-one — find_id / get_widget_id / request_paint_id — with
// the same "resolve the element once" rule: the id says *which*, the $Type still
// says *what*. v1 walks the tree like find_by_type — there is no registry to
// keep in sync, so an unmounted node simply stops being found; swap in a map
// behind these same signatures if lookups ever get hot.

// Stamps a stable name onto an element and returns it, so it chains straight
// into a @node expression: ui.@node((Dial){...}).with_id("dial"). The string is
// borrowed — it must outlive the element (a literal is ideal). Empty ids are
// never matched by find_id.
fn Element* Element.with_id(&self, String id)
{
	self.id = id;
	return self;
}

// The element carrying this id, or a WIDGET_NOT_FOUND fault — the id-keyed twin
// of find, and likewise the handle to hold when a callback reads and invalidates
// the same node.
fn Element*? Ui.find_id(&self, String id)
{
	Element* elem = self.root ? find_by_id(self.root, id) : null;
	if (!elem) return WIDGET_NOT_FOUND~;
	return elem;
}

fn Element* find_by_id(Element* elem, String id) @private
{
	if (elem.id.len > 0 && equals(elem.id, id)) return elem;
	foreach (child : elem.children)
	{
		Element* hit = find_by_id(child, id);
		if (hit) return hit;
	}
	return null;
}

// One-shot twins keyed by id — same single-walk cost and same caveat: hold the
// Element* from find_id to mutate-then-repaint without a second walk.
// get_widget_id still takes $Type — the id selects which node, the type says how
// to hand its widget back.
macro Ui.get_widget_id(&self, String id, $Type)
{
	if (try elem = self.find_id(id)) return elem.widget_as($Type);
	return WIDGET_NOT_FOUND~;
}

macro Ui.request_paint_id(&self, String id)
{
	if (try elem = self.find_id(id)) elem.request_paint();
}

// ---------------------------------------------------------------------------
// @modify — the resolve-once sugar for the common callback shape. It walks the
// tree a single time, hands the body the typed widget, then request_paint()s the
// element, so
//     ui.@modify(Dial; d) { d.value = 0; };
// is the one-walk equal of find + widget_as + request_paint. The id twin names
// the node instead (still passing $Type to type the widget):
//     ui.@modify_id("teal", Rectangle; card) { card.style.color = red; };
// The body runs only if the node exists (a silent no-op otherwise), and the
// invalidation is automatic and kind-aware: a painting widget repaints, a
// composite rebuilds its subtree (request_paint routes to request_build). For a
// change that resizes a non-composite widget (needing request_layout) hold the
// Element* from find and invalidate it yourself.
macro void Ui.@modify(&self, $Type; @body(widget))
{
	if (try elem = self.find($Type))
	{
		@body(elem.widget_as($Type));
		elem.request_paint();
	}
}

macro void Ui.@modify_id(&self, String id, $Type; @body(widget))
{
	if (try elem = self.find_id(id))
	{
		@body(elem.widget_as($Type));
		elem.request_paint();
	}
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

fn Element* Ui.attach_node(&self, Widget widget, bool owned, Element* ...children)
{
	Element* element = self.alloc_element();
	element.ui = self;
	element.widget = widget;
	element.owns_widget = owned;
	element.transform_slot = NO_TRANSFORM;
	element.dirty = { .layout = true, .paint = true };
	if (&widget.build)
	{
		element.dirty.build = true;
		self.build_pending = true;
	}
	foreach (child : children)
	{
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

	if (parent)
	{
		element.parent = parent;
		parent.children.push(element);
		parent.request_layout();
	}
	else
	{
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
	if (parent)
	{
		foreach (sz i, child : parent.children)
		{
			if (child == element)
			{
				parent.children.remove_at(i);
				break;
			}
		}
		parent.request_layout();
	}
	else if (self.root == element)
	{
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
	*element = { };
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

// Composite state changed: drop the built subtree and re-run build() on the
// next flush — CUI's setState. The release is DEFERRED to the build pass, so
// this is safe to call from event handlers running inside the subtree it
// condemns (releasing immediately would free the very widget whose callback is
// on the stack). Rebuilding cascades: nested composites in the fresh subtree
// are built in the same pass, Flutter-style.
fn void Element.request_build(&self)
{
	assert(&self.widget.build, "request_build on a widget with no build method");
	self.dirty.build = true;
	self.ui.build_pending = true;
	self.ui.frame_requested = true;
}

// Appearance changed but not size: only this element's paint() re-runs. On a
// build widget this routes to request_build — a composite has no paint of its
// own, so "appearance changed" can only mean "regenerate the subtree". That
// makes @modify work uniformly: mutate fields, and a leaf repaints while a
// composite rebuilds.
fn void Element.request_paint(&self)
{
	if (&self.widget.build && !&self.widget.paint)
	{
		self.request_build();
		return;
	}
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
	if (self.transform_slot == NO_TRANSFORM)
	{
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
// Frame flush: build pass, then layout pass, then paint + emit pass. Call once
// per frame before the renderer consumes the canvas.

fn void Ui.flush(&self)
{
	if (self.root == null) return;

	// Cleared BEFORE the walk: attach_node re-sets it for nodes created during
	// builds (handled in this same pass), and a request_build aimed at an
	// already-visited element correctly lands on the next flush instead of
	// being lost.
	if (self.build_pending)
	{
		self.build_pending = false;
		self.build_element(self.root);
	}

	if (self.layout_pending)
	{
		self.layout_element(self.root, { .min = self.size, .max = self.size });
		self.layout_pending = false;
	}

	if (self.paint_pending)
	{
		self.canvas.drawings.clear();
		// Clip rects depend on absolute origins, so the clip list is rebuilt
		// alongside the drawings; slot 0 is always "no clip".
		self.canvas.clips.clear();
		self.canvas.clips.push(NO_CLIP_ENTRY);
		self.emit(self.root, { 0, 0 }, 0, 0);
		self.canvas.drawings_dirty = true;
		self.canvas.clips_dirty = true;
		self.paint_pending = false;
	}
}

// Build pass: materialize composite widgets. Runs before layout, so build may
// freely append / request_layout — nothing is mid-pass yet (the reason build
// beats the build-lazily-inside-layout workaround this replaces). Recursing
// into children AFTER building the element means composites nested inside a
// freshly built subtree are built in the same pass, however deep they stack —
// so a rebuild regenerates its nested composites too, Flutter-style.
// 
// A rebuild is a naive replace: the old subtree is released wholesale (unmount
// hooks fire, elements recycle) and build() runs fresh. The contract that makes
// this correct rather than lossy: build is a pure function of the composite's
// OWN fields — state that must survive a rebuild belongs on the composite (or
// above), not on widgets inside the built subtree. See build.md.
fn void Ui.build_element(&self, Element* element)
{
	if (element.dirty.build)
	{
		element.dirty.build = false;
		foreach (child : element.children) self.release(child);
		element.children.clear();
		Element* subtree = element.widget.build(element);
		subtree.parent = element;
		element.children.push(subtree);
		element.request_layout();
	}
	foreach (child : element.children) self.build_element(child);
}

fn Vec2 Ui.layout_element(&self, Element* element, Constraints constraints)
{
	// Cache hit: not dirty and same constraints means same size, and none of
	// the subtree's layout code runs.
	if (!element.dirty.layout && vec2_eq(
		constraints.min,
		element.last_constraints.min
	) && vec2_eq(constraints.max, element.last_constraints.max))
	{
		return element.size;
	}

	element.last_constraints = constraints;
	element.dirty.layout = false;

	Vec2 size;
	if (&element.widget.layout)
	{
		size = element.widget.layout(element, constraints);
	}
	else if (&element.widget.build)
	{
		// Composite default: single-child passthrough — the built subtree
		// decides the size. Implement layout to override.
		size = element.layout_child(0, constraints);
		element.place_child(0, { 0, 0 });
	}
	else if (element.children.len() > 0)
	{
		// Default for layout-less containers: children get loose constraints
		// and keep their offsets; the container fills the available space.
		foreach (child : element.children)
		{
			self.layout_element(child, { .min = { 0, 0 }, .max = constraints.max });
		}
		size = constraints.max;
	}
	else
	{
		size = constraints.min;
	}

	if (!vec2_eq(size, element.size))
	{
		element.size = size;
		element.dirty.paint = true;
		self.paint_pending = true;
	}
	return size;
}

fn void Ui.emit(&self, Element* element, Vec2 origin, uint inherited_slot, uint inherited_clip)
{
	Vec2 absolute = origin + element.offset;
	element.absolute = absolute; // hit testing reads this
	uint slot = element.transform_slot != NO_TRANSFORM ? element.transform_slot : inherited_slot;

	// A clipping element pushes its rect (intersected with the inherited clip)
	// and the whole subtree stamps the new slot. An empty intersection
	// degenerates to a zero-area rect: fully clipped.
	uint clip = inherited_clip;
	if (element.clips)
	{
		Vec4 rect = { absolute.x, absolute.y, absolute.x + element.size.x, absolute.y + element.size.y };
		if (inherited_clip != 0)
		{
			Vec4 parent = self.canvas.clips[inherited_clip].rect;
			rect = {
				math::max(rect.x, parent.x), math::max(rect.y, parent.y),
				math::min(rect.z, parent.z), math::min(rect.w, parent.w),
			};
			if (rect.z < rect.x) rect.z = rect.x;
			if (rect.w < rect.y) rect.w = rect.y;
		}
		self.canvas.clips.push({ .rect = rect, .radii = element.clip_radii });
		clip = (uint)self.canvas.clips.len() - 1;
	}

	if (element.dirty.paint)
	{
		element.local_drawings.clear();
		if (&element.widget.paint)
		{
			Painter painter = { .element = element };
			element.widget.paint(element, &painter);
		}
		element.dirty.paint = false;
	}

	element.first_drawing = self.canvas.drawings.len();
	foreach (drawing : element.local_drawings)
	{
		drawing.corner += absolute;
		drawing.transform_id = slot;
		drawing.clip_id = clip;
		self.canvas.drawings.push(drawing);
	}
	element.drawing_count = self.canvas.drawings.len() - element.first_drawing;

	foreach (child : element.children) self.emit(child, absolute, slot, clip);
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

struct RectStyle
{
	Color color;
	Color border_color;
	float border_width; // px, inside the edge
	Vec4 border_radius; // per-corner px {TL, TR, BR, BL}
	Texture texture; // from Renderer.load_image; default = untextured
}

struct CircleStyle
{
	Color color;
	Color border_color;
	float border_width; // px, inside the edge
	Texture texture; // sampled across the shape's bounding box
}

struct Painter
{
	Element* element;
}

fn void Painter.rect(&self, Vec2 pos, Vec2 size, RectStyle style = { })
{
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.RECT,
			.texture = (int)style.texture,
			.border_width = style.border_width,
			.size = size,
			.corner = pos,
			.params = style.border_radius,
			.color = (Vec4)style.color,
			.border_color = (Vec4)style.border_color,
		}
	);
}

fn void Painter.circle(&self, Vec2 center, float radius, CircleStyle style = { })
{
	self.ellipse(center, { radius, radius }, style);
}

fn void Painter.ellipse(&self, Vec2 center, Vec2 radii, CircleStyle style = { })
{
	Vec2 half = radii + 1.0f; // 1px pad so the edge antialiasing isn't clipped
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.ELLIPSE,
			.texture = (int)style.texture,
			.border_width = style.border_width,
			.size = half * 2.0f,
			.corner = center - half,
			.params = { radii.x, radii.y, 0, 0 },
			.color = (Vec4)style.color,
			.border_color = (Vec4)style.border_color,
		}
	);
}

// Line segment with rounded caps.
fn void Painter.line(&self, Vec2 from, Vec2 to, float thickness, Color color)
{
	float pad   = thickness * 0.5f + 1.0f;
	Vec2 lo     = { math::min(from.x, to.x) - pad, math::min(from.y, to.y) - pad };
	Vec2 hi     = { math::max(from.x, to.x) + pad, math::max(from.y, to.y) + pad };
	Vec2 center = (lo + hi) * 0.5f;
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.LINE,
			.border_width = thickness,
			.size = hi - lo,
			.corner = lo,
			.params = { from.x - center.x, from.y - center.y, to.x - center.x, to.y - center.y },
			.color = (Vec4)color,
		}
	);
}

// Stroked circular arc: from `start`, spanning `sweep` radians, rounded caps.
// A sweep of 2π or more draws the full ring — progress rings and spinners.
fn void Painter.arc(&self, Vec2 center, float radius, float start, float sweep, float thickness, Color color)
{
	float pad = radius + thickness * 0.5f + 1.0f;
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.ARC,
			.border_width = thickness,
			.size = { pad * 2, pad * 2 },
			.corner = center - pad,
			.params = { radius, start, sweep, 0 },
			.color = (Vec4)color,
		}
	);
}

// Soft drop shadow of a (rounded) rect at pos/size: the edge fades over
// `blur` px each way. Paint it before the shape casting it; a border_radius
// of half the size makes it circular.
fn void Painter.rect_shadow(&self, Vec2 pos, Vec2 size, float blur, Color color, Vec4 border_radius = { })
{
	self.element.local_drawings.push(
		{
			.kind = DrawingKind.SHADOW,
			.border_width = blur,
			.size = size + 2.0f * blur,
			.corner = pos - blur,
			.params = border_radius,
			.color = (Vec4)color,
		}
	);
}
