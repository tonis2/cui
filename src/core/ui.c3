<*
 Retained widget core.

 The user owns widget structs; the library owns the element tree that gives
 them identity, cached layout, and a paint cache. Nothing is diffed or
 re-computed on its own: state changes go through explicit invalidation
 (`request_layout` / `request_paint` / `set_transform`), and clean elements are
 re-emitted from their cached drawings without their widget code running.

 Per-frame cost by kind of change:
 - `set_transform` — one matrix write, palette re-upload. No layout, no paint.
 - `request_paint` — that element's `paint()` re-runs; everything else is cache.
 - `request_layout` — the dirty spine re-layouts (the constraint cache prunes
   the rest), then the display list is re-emitted.
 - `request_build` — a composite drops its built subtree and re-runs `build()`,
   then layout + paint as above (`request_paint` on a build widget routes here
   — see `Element.request_paint`).
 - `invalidate` — every element whose hook read the named provided value
   (`Element.watch`) is invalidated in the phase it read it from. One tree walk
   plus whichever of the above the watchers asked for.
 - nothing — `flush()` returns immediately; the GPU redraws the retained
   display list without any upload.

 Invalidation is per element and does not propagate: a parent's `request_paint`
 does not reach its children and a child's does not reach its parent. Where two
 elements go stale together because they read the same state, that is what
 `watch` / `invalidate` are for — a writer naming the elements it believes are
 affected goes wrong as soon as one moves in the tree or a second copy of the
 view appears.

 The built-in widgets live in `cui::widgets`, the reference renderer in
 `cui::vulkan`.
*>
module cui;
import std::io;
import std::collections::list;
import std::math;

<*
 Sentinel: element has no palette slot and inherits its ancestor's.
*>
const uint NO_TRANSFORM = 0xFFFF_FFFF;

<*
 "Unbounded" constraint for scrollable axes. Deliberately finite: `float.inf`
 would turn a fill-to-max widget (a Stack with size 0) into an infinite element
 and NaNs downstream; 1e9 keeps the arithmetic sane. Fill-parent widgets must
 not be unbounded-axis children of a Scroll.
*>
const float UNBOUNDED = 1e9;

<*
 The size range a parent offers a child: `layout()` must return a size within
 it. Tight constraints (`min == max`) force a size; loose ones (`min` zero) let
 the child pick.
*>
struct Constraints
{
	Vec2 min;
	Vec2 max;
}

<*
 Constraints that force one exact size: `min == max`, so the child has no say.
 What a parent hands a child whose rect it has already decided — a split's
 panes, a title bar's close button.

 @param size : `The size the child must take.`
 @return `Tight constraints at that size.`
*>
fn Constraints tight(Vec2 size)
{
	return { .min = size, .max = size };
}

<*
 Constraints that force nothing: zero minimum, the given maximum. What a parent
 hands a child it wants to size itself — the default offer, and the one to reach
 for when in doubt.

 @param max : `The most the child may take on each axis.`
 @return `Loose constraints up to that size.`
*>
fn Constraints loose(Vec2 max)
{
	return { .min = { 0, 0 }, .max = max };
}

<*
 Clamps a wanted size into this range — the usual last step of a `layout()`,
 since the size a layout returns must lie inside the constraints it was given.

 @param wanted : `The size the widget would take if it could.`
 @require self.min.x <= self.max.x && self.min.y <= self.max.y : `Constraints must have min <= max on both axes.`
 @return `The wanted size, clamped to this constraint box.`
*>
fn Vec2 Constraints.constrain(self, Vec2 wanted)
{
	return {
		math::max(self.min.x, math::min(wanted.x, self.max.x)),
		math::max(self.min.y, math::min(wanted.y, self.max.y)),
	};
}

<*
 Shrinks both bounds by `by`, floored at zero — the constraints to hand a child
 when this widget keeps some of the space for itself: padding, a title bar, a
 border. Flooring matters: a widget padded harder than the room it was offered
 must hand its child an empty box, not a negative one.

 @param by : `Total space to reserve on each axis (both edges together).`
 @return `The remaining range, never negative.`
*>
fn Constraints Constraints.deflate(self, Vec2 by)
{
	return {
		.min = { math::max(self.min.x - by.x, 0.0f), math::max(self.min.y - by.y, 0.0f) },
		.max = { math::max(self.max.x - by.x, 0.0f), math::max(self.max.y - by.y, 0.0f) },
	};
}

<*
 Resolves a size the way the `size` field convention does: per axis, a set
 component is that many pixels and a zero component fills whatever was offered,
 clamped into range either way. `{ 0, 40 }` inside a 400px Column is 400×40.

 This is the convention the built-in containers and the size-field shortcut both
 follow (see the Widget interface docs), so a hand-written `layout` that starts
 here behaves like the rest of the library instead of approximately like it.

 It clamps, which is what a widget's OWN size wants and not always what it wants
 to offer its children: under tight constraints the clamp wins, so a widget that
 must cap its children below a minimum it was handed — or publish a `media_box`
 smaller than the space it fills — has to write that cap out rather than call
 this. Column does, and says why.

 @param size : `The widget's wanted size, zero meaning "fill" on that axis.`
 @return `The resolved size, inside these constraints.`
*>
fn Vec2 Constraints.fill(self, Vec2 size)
{
	return self.constrain({
		size.x > 0 ? size.x : self.max.x,
		size.y > 0 ? size.y : self.max.y,
	});
}

<*
 What an element must recompute on the next flush. Set through the
 `request_*` methods, cleared by the passes that service them.
*>
bitstruct DirtyFlags : char
{
	bool build;
	bool layout;
	bool paint;
}

<*
 Which hook a watch was taken from, and therefore what `Ui.invalidate` asks for
 when the watched value changes. See `Element.watch`.
*>
enum WatchKind : char
{
	BUILD,
	LAYOUT,
	PAINT,
}

<*
 One recorded dependency: this element's `kind` hook read the provided value of
 `type` the last time it ran.
*>
struct Watch
{
	typeid type;
	WatchKind kind;
}

<*
 How many distinct (type, hook) pairs one element may watch.

 Inline on the Element rather than a list, so watching allocates nothing and a
 recycled element carries none of its predecessor's. Four is generous for what
 a single hook realistically reads — a camera, a theme — and overflowing it
 asserts rather than silently dropping a dependency, which would show up as a
 stale pane long after the call that caused it.
*>
const usz MAX_WATCHES = 4;

<*
 Linear RGBA, 0..1 per channel. Alpha 0 also means "unset" wherever a style
 field is optional (Button.hover_style, Scroll.thumb_color).
*>
typedef Color = Vec4;

<*
 Opaque white.
*>
const Color WHITE = { 1.0, 1.0, 1.0, 1.0 };

<*
 Opaque black.
*>
const Color BLACK = { 0.0, 0.0, 0.0, 1.0 };

<*
 Opaque mid grey. Historical name — kept because demos reference it.
*>
const Color BLUE  = { 0.5, 0.5, 0.5, 1.0 };


// Multiplies rgb rather than dropping alpha: over a dark viewport those look
// alike, but over the lit flank of the model only the first still reads as
// "further away" instead of "translucent".
fn Color Color.dim(self, float amount)
{
	Vec4 rgba = (Vec4)self;
	return (Color){ rgba.x * amount, rgba.y * amount, rgba.z * amount, rgba.w };
}

<*
 A widget is behavior attached to an Element. All methods are optional.

 Sizing in particular is two tiers, and most widgets never write sizing code
 at all. A struct carrying a `Vec2 size` field and no `layout` is sized by the
 field: per axis, a set component is that many pixels and a zero component
 fills what the parent offers — the same convention the built-in containers
 use, so `{ 0, 40 }` inside a 400px Column is a 400×40 bar. Rectangle is the
 worked example. The field is read live on every layout, so mutating it and
 calling `request_layout` resizes the element. The detection happens in the
 node macros, where the concrete type is still visible; a widget handed to
 `Ui.mount` arrives type-erased, so give those a real `layout`. Everything the
 field cannot say — a size measured from content, or children to place —
 is `layout`. A widget with neither fills whatever it is offered.

 The pointer shape is not a method either: `Element.set_cursor` can be called
 from any hook, and the natural one is `on_hover`, which most interactive
 widgets already implement to light themselves up. Button is the worked example.

 - `build` — compose this widget out of existing widgets: return a subtree made
   with `elem.ui.@node` — the framework attaches it as the element's single
   child on the flush after the element enters the tree (a build widget takes
   no @node children of its own; the built subtree IS its content). With
   `layout` omitted, the element sizes itself to the built subtree. After
   mutating fields, call `elem.request_build()` (or use `ui.@modify`) to
   regenerate the subtree. Must be pure: read own fields, produce nodes — state
   that must survive a rebuild lives on the composite, not inside the built
   subtree. See test/composite.c3 and build.md.
 - `mount` — the element entered the tree; runs once, just before its first
   layout, with the parent chain already wired. The home for element properties
   that never change: `elem.ignores_pointer`, `elem.clips` / `clip_radii`, and
   `set_cursor` for a widget that speaks for its whole subtree. A property
   computed from constraints or from mutable fields belongs in `layout`
   instead, which re-runs; this does not. Not a safe place to acquire anything
   that `unmount` must release: an element released before it was ever laid out
   — a subtree built and replaced in the same frame — gets the `unmount` without
   ever having got the `mount`. Allocate in `build` or on first use.
 - `layout` — given constraints, return own size; lay out children through
   `elem.layout_child` / `elem.place_child`. A content-sized leaf is one line:
   `return constraints.constrain(wanted);` — see Label. Omitted: a build widget
   delegates to its built subtree; otherwise the size field or the fill default
   decides, and children get loose constraints and keep their offsets. Reach
   for `Constraints.loose` / `tight` / `deflate` / `fill` rather than writing
   the ranges out by hand. Re-runs on every resize, which is what makes it the
   place for the element properties `mount` cannot answer for: a `media_box`
   sized from the constraints, a clip radius read from a mutable style.
 - `paint` — emit primitives in element-local coordinates. Omitted: the element
   draws nothing itself (pure container).
 - `on_mouse` — press/release/move/scroll, hit-tested and bubbling: the deepest
   element under the pointer gets it first; return true to consume. Consuming a
   PRESS captures the mouse until that button releases.
 - `on_hover` — pointer entered (true) / left (false) this element.
 - `on_key` — key press/release edges, delivered to the focused element (left
   click focuses; see `Element.request_focus`), bubbling like `on_mouse`.
 - `update` — called every frame with the frame's dt — for animations and
   polling `ui.input`; mutate state then `request_paint()`.
 - `unmount` — free whatever the widget allocated; called whenever its element
   leaves the tree, including when it leaves only to be rebuilt (which mounts
   the new one again). Fires unconditionally, so it is the wider of the pair:
   see the caveat on `mount`. The widget struct itself stays caller-owned.
   Takes the element like every other hook, so a widget can still reach
   `inherit` on the way out and release symmetrically with what it acquired.

 The built-in implementations (Rectangle, Column, Row, Stack, Padding, Clip,
 Scroll, Button) live in module `cui::widgets`; apps write their own against
 this interface.
*>
interface Widget
{
	fn void mount(Element* elem) @optional;
	fn Element* build(Element* elem) @optional;
	fn Vec2 layout(Element* elem, Constraints constraints) @optional;
	fn void paint(Element* elem, Painter* painter) @optional;
	fn bool on_mouse(Element* elem, MouseEvent event) @optional;
	fn void on_hover(Element* elem, bool entered) @optional;
	fn bool on_key(Element* elem, KeyEvent event) @optional;
	fn void update(Element* elem, float dt) @optional;
	fn void unmount(Element* elem) @optional;
}

<*
 True when `#expr` can be attached as a widget: a struct implementing Widget,
 passed either by value or as a pointer. Used by the contracts on the node
 macros, so a bad argument is a compile-time error naming the actual problem.

 @param #expr : `The candidate widget expression.`
 @return `True if the expression is a Widget value or a pointer to one.`
*>
macro bool @is_widget(#expr) @const @builtin
{
	$if @kindof(#expr) == POINTER:
		return $defined(Widget w = #expr);
	$else
		return $defined(Widget w = ($Typeof(#expr)*)null);
	$endif
}

<*
 True when `$Type` implements Widget — the type-keyed twin of `@is_widget`, for
 the lookup macros that take a type rather than a widget.

 @param $Type : `The candidate widget type.`
 @return `True if $Type implements the Widget interface.`
*>
macro bool @is_widget_type($Type) @const @builtin
{
	return $defined(Widget w = ($Type*)null);
}

<*
 Free-function spelling of `Constraints.constrain`, with the arguments the other
 way round. The method is the one to reach for in new code; this exists because
 it was the original name and consumers call it.

 @param size : `The size the widget wants.`
 @param c : `The constraints handed to layout().`
 @return `The wanted size, clamped to the constraint box.`
*>
fn Vec2 clamp_size(Vec2 size, Constraints c)
{
	return c.constrain(size);
}

<*
 Reads a widget's `Vec2 size` field through the type-erased pointer the element
 stores — the runtime half of the size-field convention. The node macros
 instantiate one per widget type that qualifies.
*>
alias SizeGetter = fn Vec2(void* widget);

<*
 One node of the retained tree: a widget's identity, its cached layout and its
 cached drawings. Elements are created by the node macros and recycled through
 a free-list, so an `Element*` stays valid for the lifetime of its Ui — holding
 one is CUI's equivalent of a Flutter GlobalKey. Widget code reaches everything
 else through it (`elem.ui`, `elem.parent`, `elem.children`).
*>
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
	// Preferred pointer shape while hovered; DEFAULT defers to the ancestors.
	// Written through `set_cursor` — see it for when it is read and what a
	// widget is expected to do about it.
	Cursor cursor;

	// The size-field convention (see the Widget interface docs): reads the
	// widget's `Vec2 size` field back out of the type-erased pointer. Set by
	// the node macros at build time — the one place the concrete type is still
	// known — and null for every widget that sizes itself another way.
	SizeGetter auto_size;

	// Whether the widget's `mount` hook has run. Zeroed with the rest of the
	// element on release, so an element recycled into a new widget mounts that
	// widget rather than inheriting the last one's answer.
	bool mounted;

	// Transparent to hit testing: the pointer passes straight through this
	// element to whatever is painted behind it. Children are unaffected — they
	// are tested first and hit normally — so a transparent container still
	// delivers events to interactive descendants.
	//
	// Set from layout(), like clips. Widgets that paint decoration over an
	// interactive surface want it: without it, a Label overlaid on a viewport
	// wins the hit test (deepest rect containing the point, whether or not it
	// handles anything) and events bubble to its PARENTS, never to the sibling
	// underneath — so the label becomes a dead zone, and it also takes the
	// cursor down to ARROW, since hover stops at the label and nothing there
	// ever asked for the viewport's crosshair.
	//
	// Deliberately opt-in rather than "skip elements with no handlers": a
	// modal scrim, a disabled overlay and a drag blocker are all exactly an
	// element that handles nothing and must block everything.
	bool ignores_pointer;

	// Paint cache, in element-local coordinates. Emitting shifts copies by the
	// absolute origin, so a moved-but-clean element never re-paints.
	List{Drawing} local_drawings;
	sz first_drawing; // slice of Canvas.drawings written by last emit
	sz drawing_count;

	uint transform_slot;

	// Clipping: when set (widgets set it from layout(), like ignores_pointer), emit
	// clips this element's own drawings and its whole subtree to the element's
	// rect, rounded by clip_radii {TL, TR, BR, BL}. Nested clips intersect
	// (axis-aligned; the inner radii win — a documented approximation). Hit
	// testing is gated by the same rect.
	bool clips;
	Vec4 clip_radii;

	// The screen this element publishes to its subtree: `Element.media` answers
	// with the nearest non-zero box at or above the caller, and with the window
	// when there is none. Zero — the default — is "not a screen".
	//
	// A size rather than a flag, and set from `layout()` BEFORE the children are
	// laid out, because that is the only moment the answer both exists and is
	// early enough to be useful: `size` below is not assigned until the widget's
	// own layout has returned, by which time everything inside has already had
	// to size itself. See media.c3.
	Vec2 media_box;

	bool owns_widget; // widget is a heap copy made by @node; freed on release
	DirtyFlags dirty;

	// Provided values this element's hooks read, recorded by `Element.watch` and
	// re-declared every time the hook runs. `Ui.invalidate` walks the tree
	// looking at these.
	Watch[MAX_WATCHES] watches;
	uint watch_count;
}

<*
 One UI instance: the element tree, the canvas the renderer consumes, and the
 interactivity state. Created with `new_ui`, driven by `process_input` +
 `flush` once per frame (the reference renderer's `frame()` does both).
*>
struct Ui
{
	Element* root;
	Canvas canvas;
	TextSystem text; // fonts + glyph atlas backing Painter.text (render/text.c3)
	Vec2 size; // root constraints, usually the window size
	float pixel_ratio; // physical pixels per logical one, reported to widgets
	// through `Element.media`. The embedder sets it — the
	// reference renderer from the window's backing scale —
	// and 1.0 is the answer until something does.

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

	// Scoped tree building (@canvas / @tree / @node): the open @tree scopes;
	// nodes made by the free macros attach to the top one. scope_floor hides
	// outer scopes from a nested @subtree; scoped_root catches the single node
	// built at the top level of a @canvas/@subtree body.
	List{Element*} build_stack;
	sz scope_floor;
	Element* scoped_root;

	// Embedder state, reachable by type from anywhere in the tree — see
	// `Ui.provide` / `Element.inherit`. Every slot is borrowed.
	List{any} context;

	// Whose hook is running, for `Element.watch` to attribute a read to. Null
	// outside the three dispatches; saved and restored around each of them,
	// because layout nests (a container lays its children out from inside its
	// own `layout`).
	Element* watcher;
	WatchKind watch_kind;

	bool build_pending;
	bool layout_pending;
	bool paint_pending;
	bool frame_requested; // "schedule a frame": set by every invalidation
	// below. A render loop that sleeps when idle
	// (see cui::vulkan LoopMode) reads and clears
	// this to decide whether to block for input.
}

<*
 Creates a Ui. Heap-allocated so `Element.ui` stays valid; released with
 `Ui.free`.

 @param size : `Root constraints — normally the window size in pixels.`
 @return `The new Ui.`
*>
fn Ui* new_ui(Vec2 size)
{
	Ui* ui = mem::new(Ui);
	ui.size = size;
	// Not the zero a fresh Ui would otherwise report: a widget dividing by the
	// pixel ratio to snap a coordinate would get an infinity, and "one device
	// pixel per logical pixel" is the right answer for an embedder that never
	// says otherwise.
	ui.pixel_ratio = 1.0;
	ui.canvas.init();
	ui.text.init();
	return ui;
}

<*
 Makes a value reachable by type from anywhere in the tree.

 Every widget hook receives an `Element*`, and every element holds `Ui* ui`, so
 a value provided here is one hop away from any point in the tree without the
 embedder threading a pointer through the struct literal that built the widget.
 That is what lets this library ship *interactive* widgets at all: a Button has
 to call back into the app, and cui has no app type to name.

 This is not the way a widget should reach state it owns and mutates. A field
 of the right type is checked by the compiler; a lookup here is checked at
 runtime and raises NOT_PROVIDED when the embedder forgot. For a callback
 context or a theme — uniform across the tree, provided once at startup, read
 far more than written — that trade is fine, and the failure is loud on the
 first interaction. For the widget holding the document, take the pointer as a
 field and let a missing one fail to compile.

 Providing the same type twice is an override rather than a duplicate:
 `inherit` searches newest-first, so swapping a theme at runtime is a push.

 @param value : `Borrowed — must outlive the Ui. Pass a pointer; it converts to any.`
*>
fn void Ui.provide(&self, any value)
{
	self.context.push(value);
}

<*
 The fault `inherit` raises when nothing in the tree provided the type — so a
 lookup asserts with `!!` or degrades with `if (try v = elem.inherit(T))`.
*>
faultdef NOT_PROVIDED;

<*
 The provided value of a type. See `Ui.provide`.

 Prefer `Element.inherit` at call sites; see the note there.

 A fault rather than a null, matching `find` / `find_id` above — this is the
 same kind of question (ask the tree for something that may not be there) and
 it should fail the same way. It also decides how the mistake reads: `!!` on a
 missing provider panics naming NOT_PROVIDED at the call site, where a returned
 null would segfault one line later inside the caller's own code, pointing at
 the wrong thing entirely.

 @param $Type : `The provided type itself, not its pointer — inherit(AppState).`
 @return `Pointer to the provided value.`
 @return? NOT_PROVIDED
*>
macro Ui.inherit(&self, $Type)
{
	foreach_r (slot : self.context)
	{
		if (try $Type* hit = anycast(slot, $Type)) return hit;
	}
	return NOT_PROVIDED~;
}

<*
 Releases the tree (running every widget's `unmount`), the canvas and the Ui
 itself. Widget structs passed by pointer stay caller-owned.
*>
fn void Ui.free(&self)
{
	if (self.root) self.release(self.root);
	foreach (element : self.all_elements) mem::free(element);
	self.all_elements.free();
	self.free_elements.free();
	self.free_transform_slots.free();
	self.build_stack.free();
	self.held_keys.free();
	self.context.free(); // the list; the values in it are the embedder's
	self.canvas.free();
	self.text.free();
	mem::free(self);
}

// ---------------------------------------------------------------------------
// Tree building

<*
 Declarative building: create an element for a widget together with its
 children, Flutter-style. Pass the widget as a VALUE (a struct literal — the
 element heap-copies and owns it) or as a POINTER (borrowed; the caller owns the
 struct and can mutate it, but must keep it alive). Children are elements built
 by nested `@node` calls. Attach the finished tree with `Ui.build`, or graft it
 onto a live element with `Element.append`.

     ui.build(ui.@node((Column){ .gap = 8.0 },
         ui.@node((Rectangle){ .size = {100, 40} }),
         ui.@node((Rectangle){ .size = {100, 40} })));

 The scoped builder (`@canvas` / `@tree` / `@node`) is sugar over this and reads
 better for whole trees; this stays the detached primitive.

 @param widget : `The widget: a struct value (copied and owned) or a pointer to one (borrowed).`
 @require @is_widget(widget) : `A node takes a widget — a struct implementing Widget, by value or as a pointer.`
 @return `The new, detached element.`
*>
macro Element* Ui.@node(&self, widget, ...)
{
	$if @kindof(widget) == POINTER:
		Element* element = self.attach_node(widget, false, ...$vaarg);
		@detect_size_field($Typeof(*widget), element);
		return element;
	$else
		var $Type = $Typeof(widget);
		$Type* copy = mem::new($Type);
		*copy = widget;
		Element* element = self.attach_node(copy, true, ...$vaarg);
		@detect_size_field($Type, element);
		return element;
	$endif
}

<*
 The compile-time half of the size-field convention: a widget whose struct
 carries a `Vec2 size` field and implements no `layout` is sized by that
 field, with no layout code written. This macro runs where the node macros
 still know the concrete type — the only place the field is visible at all,
 since the element stores the widget behind the type-erased interface — and
 plants a typed getter for the layout pass to call. The getter reads the live
 field every layout, so mutating `size` and requesting layout resizes the
 element.

 An explicit `layout` opts out entirely: those widgets are sized by their
 method and the field means whatever they say it means (the built-in
 containers all keep `layout`, which is why their "0 = fill" fields never
 collide with this).

 @param $Type : `The concrete widget type.`
 @param element : `The element just built for it.`
*>
macro void @detect_size_field($Type, Element* element) @private
{
	// $defined on a member access answers "does the type have this" without
	// evaluating anything — the reflection-flavored twin of the @is_widget
	// probe. Nested rather than one condition, so the $Typeof of the field
	// only happens once the field is known to exist.
	$if $defined((($Type*)null).size):
		var $FieldType = $Typeof((($Type*)null).size);
		$if $FieldType == Vec2 &&& !$defined((($Type*)null).layout):
			element.auto_size = fn Vec2 (void* widget) => (($Type*)widget).size;
		$endif
	$endif
}

<*
 The inverse of `@node`: recover the concrete widget behind an element as a
 typed pointer. An `Element*` is a stable handle to a tree node (it survives
 relayout and repaint), so holding one is CUI's equivalent of a Flutter
 GlobalKey — a callback that keeps it can read and mutate that widget's own
 state, then `request_paint()`, without a wrapper struct. Unchecked: the caller
 asserts $Type, the same assertion it made when it built the node.

 @param $Type : `The widget type this element was built with.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
 @return `A pointer to the element's widget.`
*>
macro Element.widget_as(&self, $Type)
{
	return ($Type*)((any)self.widget).ptr;
}

<*
 Whether this element's widget is exactly $Type — the test `@each` runs on
 every element, exposed for `@walk` bodies that sort several types out of one
 pass. Exact, not "assignable to": a widget is one concrete type here.

 @param $Type : `The widget type to test for.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
*>
macro bool Element.is_widget(&self, $Type)
{
	return ((any)self.widget).type == $Type;
}

<*
 The embedder value of a type, as seen from this element. See `Ui.provide`.

 Prefer this over `elem.ui.inherit` even though they are the same call today.
 Every provider currently lives on the Ui, so the lookup cannot depend on where
 in the tree it was made — but a themed subtree or a scoped locale would put
 providers on elements, and this is the call that would then start walking
 parents. Written this way, that change is confined to this macro; written the
 other way it is every call site in every app.

 @param $Type : `The provided type itself, not its pointer.`
 @return `Pointer to the provided value.`
 @return? NOT_PROVIDED
*>
macro Element.inherit(&self, $Type) => self.ui.inherit($Type);

<*
 `inherit`, and a standing request to be invalidated when that value changes.

 The mover then names only what it wrote — `ui.invalidate(OrbitCamera)` — and
 every hook that read it re-runs, in the phase it read it from: a `paint` that
 watches repaints, a `layout` that watches re-layouts, a `build` that watches
 rebuilds. Nobody has to know who the readers are, which is the whole point:
 painting is cached per element, so the alternative is each writer naming the
 elements it believes are affected, and that list goes stale the moment a widget
 moves in the tree or a second pane appears.

 Watches are re-declared on every run of the hook and the previous run's are
 dropped, so a branch that stops reading a value stops being invalidated by it.

 ONLY counts inside `build`, `layout` and `paint` — the calls whose result is
 cached and therefore can go stale. From an event handler, `mount` or a free
 function this is exactly `inherit`: handlers run on every event already, so
 there is nothing to invalidate.

 @param $Type : `The provided type itself, not its pointer.`
 @return `Pointer to the provided value.`
 @return? NOT_PROVIDED
*>
macro Element.watch(&self, $Type)
{
	if (self.ui.watcher == self)
	{
		// The bare type, not `$Type.typeid`: the latter is rejected inside a
		// macro body ("A type can't appear here").
		typeid want = $Type;
		self.record_watch(want, self.ui.watch_kind);
	}
	return self.ui.inherit($Type);
}

<*
 Records one dependency, ignoring a repeat. Internal to `Element.watch`; the
 dedupe is what lets a paint loop call `watch` per item without overflowing.

 @param type : `The provided type read.`
 @param kind : `The hook that read it.`
*>
fn void Element.record_watch(&self, typeid type, WatchKind kind)
{
	for (uint i = 0; i < self.watch_count; i++)
	{
		if (self.watches[i].type == type && self.watches[i].kind == kind) return;
	}
	assert(self.watch_count < MAX_WATCHES, "an element watches at most MAX_WATCHES provided types");
	self.watches[self.watch_count++] = { .type = type, .kind = kind };
}

<*
 Drops the watches taken from one hook, leaving the other hooks' alone.

 Per kind rather than all at once because the hooks run on different schedules:
 a layout watch is declared once and then survives many paints, and clearing
 everything at the top of `paint` would delete it with no layout run coming to
 put it back.

 @param kind : `The hook about to run.`
*>
fn void Element.clear_watches(&self, WatchKind kind)
{
	uint kept = 0;
	for (uint i = 0; i < self.watch_count; i++)
	{
		if (self.watches[i].kind == kind) continue;
		self.watches[kept++] = self.watches[i];
	}
	self.watch_count = kept;
}

<*
 Runs one widget hook with `Element.watch` attributing to it: the previous run's
 watches of this kind are dropped first, and the cursor is restored afterwards
 so a nested dispatch (layout, which lays its children out from inside itself)
 hands attribution back to the outer one.

 @param element : `The element whose hook is about to run.`
 @param kind : `Which hook it is.`
*>
macro void Ui.@watching(&self, Element* element, WatchKind kind; @body())
{
	element.clear_watches(kind);
	Element* outer = self.watcher;
	WatchKind outer_kind = self.watch_kind;
	self.watcher = element;
	self.watch_kind = kind;
	defer
	{
		self.watcher = outer;
		self.watch_kind = outer_kind;
	}
	@body();
}

<*
 The fault `find` / `find_id` (and the `get_widget` twins built on them) raise
 when the tree holds no matching node — so a lookup guards with
 `if (try elem = ui.find(Dial))` or asserts with `!!`.
*>
faultdef WIDGET_NOT_FOUND;

<*
 Query the retained tree by widget type: the first element whose widget is
 exactly $Type, or a WIDGET_NOT_FOUND fault. The top-down analog of Flutter's
 findAncestorStateOfType. The returned `Element*` is a stable handle (valid
 across frames), and it is *the* thing to hold when a callback will both read
 and invalidate a widget: resolve it once here, then `widget_as` (a cast) and
 `request_paint` (a flag flip) are both search-free. That is the hot path — the
 `get_widget` / `request_paint` twins below each re-walk the tree, so pairing
 them to mutate-then-repaint one node walks it twice. Use those only for
 one-shots.

 @param $Type : `The widget type to look for.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
 @return `The first element whose widget is $Type.`
 @return? WIDGET_NOT_FOUND : `No element in the tree carries a $Type widget.`
*>
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

<*
 One-shot convenience over `find`: hand back the widget pointer directly
 (`get_widget(Dial)` → `Dial*`), or re-raise WIDGET_NOT_FOUND. One tree walk —
 right for reading a singleton's field. To mutate AND repaint, hold the
 `Element*` from `find` instead, so invalidation doesn't walk the tree a second
 time. A callback reaches this through a Ui it is handed — a Button passes its
 own element's ui to `on_click`, so no global and no app-threaded handle is
 needed. Acts on the first $Type in the tree, so it fits singletons (one Dial,
 one settings panel); name a node with `with_id` when several coexist.

 @param $Type : `The widget type to look for.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
 @return `A pointer to the first $Type widget in the tree.`
 @return? WIDGET_NOT_FOUND : `No element in the tree carries a $Type widget.`
*>
macro Ui.get_widget(&self, $Type)
{
	if (try elem = self.find($Type)) return elem.widget_as($Type);
	return WIDGET_NOT_FOUND~;
}

<*
 One-shot invalidate by type: one tree walk, a no-op if absent. Same caveat — if
 you already hold the element, call `elem.request_paint()` and skip the walk.

 @param $Type : `The widget type to repaint.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
*>
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

<*
 Stamps a stable name onto an element and returns it, so it chains straight into
 a `@node` expression: `ui.@node((Dial){...}).with_id("dial")`.

 @param id : `The name. Borrowed — it must outlive the element (a literal is ideal). Empty ids are never matched by find_id.`
 @return `The same element, for chaining.`
*>
fn Element* Element.with_id(&self, String id)
{
	self.id = id;
	return self;
}

<*
 The element carrying this id — the id-keyed twin of `find`, and likewise the
 handle to hold when a callback reads and invalidates the same node.

 @param id : `The name given with with_id.`
 @return `The element carrying the id.`
 @return? WIDGET_NOT_FOUND : `No element in the tree carries that id.`
*>
fn Element*? Ui.find_id(&self, String id)
{
	Element* elem = self.root ? find_by_id(self.root, id) : null;
	if (!elem) return WIDGET_NOT_FOUND~;
	return elem;
}

<*
 The element carrying this id within this subtree, this element included.

 The scoped twin of `Ui.find_id`, and what a composite uses to reach into the
 subtree it has just built: a detached subtree is not in `Ui.root` yet, so the
 tree-wide lookup cannot see it. It is also the narrower answer when ids repeat
 by design — one HUD per pane — since it searches only below here.

 @param id : `The name given with with_id.`
 @return `The element carrying the id.`
 @return? WIDGET_NOT_FOUND : `No element in this subtree carries that id.`
*>
fn Element*? Element.find_id(&self, String id)
{
	Element* elem = find_by_id(self, id);
	if (!elem) return WIDGET_NOT_FOUND~;
	return elem;
}

<*
 Whether this element carries this name. An empty id never matches, so unkeyed
 elements stay invisible to a name-based pass.

 @param id : `The name given with with_id.`
*>
fn bool Element.has_id(&self, String id)
{
	return self.id.len > 0 && equals(self.id, id);
}

fn Element* find_by_id(Element* elem, String id) @private
{
	if (elem.has_id(id)) return elem;
	foreach (child : elem.children)
	{
		Element* hit = find_by_id(child, id);
		if (hit) return hit;
	}
	return null;
}

<*
 One-shot twin keyed by id — same single-walk cost and same caveat: hold the
 `Element*` from `find_id` to mutate-then-repaint without a second walk. Still
 takes $Type: the id selects which node, the type says how to hand its widget
 back.

 @param id : `The name given with with_id.`
 @param $Type : `The widget type of that node.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
 @return `A pointer to the widget of the element carrying the id.`
 @return? WIDGET_NOT_FOUND : `No element in the tree carries that id.`
*>
macro Ui.get_widget_id(&self, String id, $Type)
{
	if (try elem = self.find_id(id)) return elem.widget_as($Type);
	return WIDGET_NOT_FOUND~;
}

<*
 One-shot invalidate by id: one tree walk, a no-op if absent.

 @param id : `The name given with with_id.`
*>
macro Ui.request_paint_id(&self, String id)
{
	if (try elem = self.find_id(id)) elem.request_paint();
}

// ---------------------------------------------------------------------------
// @modify — the resolve-once sugar for the common callback shape.

<*
 Walks the tree a single time, hands the body the typed widget, then
 `request_paint()`s the element, so

     ui.@modify(Dial; d) { d.value = 0; };

 is the one-walk equal of `find` + `widget_as` + `request_paint`. The body runs
 only if the node exists (a silent no-op otherwise), and the invalidation is
 kind-aware: a painting widget repaints, a composite rebuilds its subtree
 (`request_paint` routes to `request_build`). For a change that resizes a
 non-composite widget (needing `request_layout`) hold the `Element*` from `find`
 and invalidate it yourself.

 @param $Type : `The widget type to modify.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
*>
macro void Ui.@modify(&self, $Type; @body(widget))
{
	if (try elem = self.find($Type))
	{
		@body(elem.widget_as($Type));
		elem.request_paint();
	}
}

<*
 The id-keyed twin of `@modify` — names the node instead of finding it by type
 (still passing $Type to type the widget):

     ui.@modify_id("teal", Rectangle; card) { card.style.color = red; };

 @param id : `The name given with with_id.`
 @param $Type : `The widget type of that node.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
*>
macro void Ui.@modify_id(&self, String id, $Type; @body(widget))
{
	if (try elem = self.find_id(id))
	{
		@body(elem.widget_as($Type));
		elem.request_paint();
	}
}

// ---------------------------------------------------------------------------
// Tree visitors — the every-match twins of find / find_id, which stop at the
// first match in tree order. Use these when a widget type or an id is
// deliberately duplicated across the tree (one HUD per split pane): reaching
// only the first HUD leaves every other pane stale.
//
// All three take the body inline instead of returning a list, so no match
// outlives the call and nothing has to be freed. The traversal follows the
// parent pointers rather than pushing a stack, so it allocates nothing at all
// and is cheap enough to call from a render loop. Visit order is pre-order: an
// element before its children, children left to right.
//
// Implementation note for anyone tempted to simplify: the walk cannot be
// recursive. A tree's depth is a runtime value and macro recursion in C3 only
// terminates on compile-time bounds, and a plain `fn` walker cannot stand in
// either, because a C3 lambda captures nothing and so cannot carry the body.

<*
 Runs the body once for every element in the tree.

     ui.@walk(; elem)
     {
         if (elem.is_widget(Viewport) || elem.has_id("hud")) elem.request_paint();
     };

 The unfiltered primitive under `@each` and `@each_id`. Reach for it when one
 pass has to answer several questions: three `@each` calls are three walks of
 the same tree, and testing an element costs far less than reaching it.

 Invalidation from the body is safe (it only sets flags); structural mutation
 of the tree is not — defer it with request_build like everything else.
*>
macro void Ui.@walk(&self; @body(elem))
{
	Element* root = self.root;
	Element* walk = root;
	while (walk)
	{
		@body(walk);

		// Down first; at a leaf, across to the next sibling, climbing while
		// there is none. Arriving back at the root means the tree is done.
		if (walk.children.len() > 0)
		{
			walk = walk.children[0];
			continue;
		}
		Element* next = null;
		while (walk != root && walk.parent)
		{
			Element* parent = walk.parent;
			sz after = child_slot(parent, walk) + 1;
			if (after < parent.children.len())
			{
				next = parent.children[after];
				break;
			}
			walk = parent;
		}
		walk = next;
	}
}

<*
 Where a child sits in its parent's list — the step `@walk` takes in place of a
 stack. Linear in the sibling count, which stays small in a UI tree; a parent
 with hundreds of children pays for it once per child.

 @return `The index, or the child count if the two are not related.`
*>
fn sz child_slot(Element* parent, Element* child) @private
{
	foreach (index, entry : parent.children) if (entry == child) return index;
	return parent.children.len();
}

<*
 Runs the body for every element whose widget is exactly $Type.

     ui.@each(Viewport; elem) { elem.request_paint(); };

 @param $Type : `The widget type to visit.`
 @require @is_widget_type($Type) : `$Type must implement the Widget interface.`
*>
macro void Ui.@each(&self, $Type; @body(elem))
{
	typeid want = $Type;
	self.@walk(; visited)
	{
		if (((any)visited.widget).type == want) @body(visited);
	};
}

<*
 Runs the body for every element stamped with this id — the id-keyed twin of
 `@each`, for when one name is deliberately shared across duplicated subtrees.

 @param id : `The name given with with_id.`
*>
macro void Ui.@each_id(&self, String id; @body(elem))
{
	self.@walk(; visited)
	{
		if (visited.has_id(id)) @body(visited);
	};
}

// ---------------------------------------------------------------------------
// Scoped tree building — @pool-style sugar over @node. All four macros are
// @builtin, so app code calls them without the cui:: prefix. Rules:
//   - @tree/@node only work inside a @canvas/@subtree body (a contract).
//   - The free @node's extra arguments are leaf WIDGETS attached as its
//     children — never Element*. And never pass a @tree/@node result to
//     ui.@node's varargs: it is already attached. ui.@node remains the
//     detached form.
//   - A `return` inside a body exits the surrounding function (like @pool);
//     the scope state unwinds correctly, but no root gets installed.

tlocal Ui* ambient_ui @private;

<*
 Opens a build scope and installs what the body builds as the UI root. Inside
 the body `@tree` and `@node` need no ui and attach themselves to the enclosing
 node:

     `@canvas(ui)`
     `{`
     `    @tree((Column){ .gap = 8.0 })`
     `    {`
     `        @node((Rectangle){ .size = {100, 40} });`
     `        for (int i = 0; i < 4; i++) @node((Rectangle){ .size = {80, 20} });`
     `    };`
     `};`

 The single node built at the top level of the body becomes the UI root. Both
 inner macros return the `Element*`, so handles still chain —
 `@node(...).with_id("card")`, `Element* col = @tree(...) { ... };` — and plain
 statements (loops, locals, `set_offset` on a returned handle) mix freely into
 the bodies.

 @param ui : `The Ui to build into.`
 @require ui != null : `@canvas needs a Ui.`
*>
macro void @canvas(Ui* ui; @body()) @builtin
{
	Ui* prev_ui = ambient_ui;
	Element* prev_root = ui.scoped_root;
	sz prev_floor = ui.scope_floor;
	ambient_ui = ui;
	ui.scoped_root = null;
	ui.scope_floor = ui.build_stack.len();
	defer
	{
		ambient_ui = prev_ui;
		ui.scoped_root = prev_root;
		ui.scope_floor = prev_floor;
	}
	@body();
	assert(ui.scoped_root, "@canvas body built no root node");
	ui.build(ui.scoped_root);
}

<*
 The detached twin of `@canvas`: returns the body's single top-level node
 instead of installing it — the shape of a composite's `build()`:

 @param ui : `The Ui to build into — inside build(), elem.ui.`
 @require ui != null : `@subtree needs a Ui.`
 @return `The single node built at the top level of the body, detached.`
*>
macro Element* @subtree(Ui* ui; @body()) @builtin
{
	Ui* prev_ui = ambient_ui;
	Element* prev_root = ui.scoped_root;
	sz prev_floor = ui.scope_floor;
	ambient_ui = ui;
	ui.scoped_root = null;
	ui.scope_floor = ui.build_stack.len();
	defer
	{
		ambient_ui = prev_ui;
		ui.scoped_root = prev_root;
		ui.scope_floor = prev_floor;
	}
	@body();
	Element* root = ui.scoped_root;
	assert(root, "@subtree body built no root node");
	return root;
}

<*
 Container node: attaches to the enclosing scope (or becomes the body's root),
 then IS the enclosing scope for its own body. Children needing statements —
 loops, locals, chained `set_offset`, nesting — belong in a `@tree` body; a row
 of plain leaves can ride as `@node` varargs instead.

 @param widget : `The widget: a struct value (copied and owned) or a pointer to one (borrowed).`
 @require @is_widget(widget) : `A node takes a widget — a struct implementing Widget, by value or as a pointer.`
 @require ambient_ui != null : `@tree only works inside a @canvas or @subtree body.`
 @return `The element, attached.`
*>
macro Element* @tree(widget; @body()) @builtin
{
	Ui* scope_ui = ambient_ui;
	Element* elem = scope_ui.@node(widget);
	scope_ui.attach_scoped(elem);
	scope_ui.build_stack.push(elem);
	defer (void)scope_ui.build_stack.pop();
	@body();
	return elem;
}

<*
 Leaf node: attaches to the enclosing scope (or becomes the body's root).

 Extra arguments are leaf WIDGETS (values or borrowed pointers, like the first)
 attached as children in order — a one-call subtree for the common row-of-leaves
 shape, without a `@tree` body:

     `@node((Row){ .gap = 16.0 },`
     `    (Button){ .on_click = &reset },`
     `    (Button){ .on_click = &bump });`

 Unlike `ui.@node`'s varargs these never take `Element*` — an already-attached
 node passed here would attach twice, and the compiler rejects it (`Element*` is
 not a Widget).

 @param widget : `The widget: a struct value (copied and owned) or a pointer to one (borrowed).`
 @require @is_widget(widget) : `A node takes a widget — a struct implementing Widget, by value or as a pointer.`
 @require ambient_ui != null : `@node only works inside a @canvas or @subtree body.`
 @return `The element, attached, with any extra widgets attached under it as children.`
*>
macro Element* @node(widget, ...) @builtin
{
	Ui* scope_ui = ambient_ui;
	Element* elem = scope_ui.@node(widget);
	scope_ui.attach_scoped(elem);
	$for var $i = 0; $i < $vaarg.len; $i++:
	{
		Element* child = scope_ui.@node($vaarg[$i]);
		child.parent = elem;
		elem.children.push(child);
	}
	$endfor
	return elem;
}

<*
 Plain parent/child wiring, matching `attach_node` — no request_layout walks:
 nothing built here is mounted yet (`@canvas` installs the root afterwards,
 which invalidates everything once). Internal to the DSL macros; not part of the
 widget-facing API.

 @param elem : `The freshly built element to attach.`
*>
fn void Ui.attach_scoped(&self, Element* elem)
{
	if (self.build_stack.len() > self.scope_floor)
	{
		Element* top = self.build_stack[self.build_stack.len() - 1];
		elem.parent = top;
		top.children.push(elem);
		return;
	}
	assert(!self.scoped_root, "a @canvas/@subtree body can only build one root node");
	self.scoped_root = elem;
}

<*
 Installs a built tree as the UI root, releasing any previous root.

 @param root : `The root of a tree built with ui.@node.`
 @require root != null : `Ui.build needs a root element.`
*>
fn void Ui.build(&self, Element* root)
{
	if (self.root && self.root != root) self.release(self.root);
	root.parent = null;
	self.root = root;
	self.layout_pending = true;
	self.paint_pending = true;
	self.frame_requested = true;
}

<*
 Grafts a built subtree under a live element.

 @param child : `The root of a detached subtree built with ui.@node.`
 @require child != null : `Element.append needs a child.`
*>
fn void Element.append(&self, Element* child)
{
	child.parent = self;
	self.children.push(child);
	self.request_layout();
}

<*
 Allocates the element for a widget and wires the given children under it. The
 primitive behind every node macro.

 @param widget : `The widget behind the element.`
 @param owned : `True when the widget is a heap copy the element must free on release.`
 @param children : `Elements to attach, in order.`
 @return `The new, detached element.`
*>
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

<*
 Attaches a widget to the tree (as root when parent is null). The widget struct
 is owned by the caller and must outlive the element.

 @param widget : `A pointer to a widget the caller keeps alive.`
 @param parent : `The element to attach under; null makes it the root.`
 @return `The new element.`
*>
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

<*
 Removes an element (and its subtree) while the app runs. Widgets get their
 `unmount()` hook to free whatever they own; elements go back to the free-list.

 @param element : `The element to remove.`
 @require element != null : `Ui.unmount needs an element.`
*>
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

<*
 Recycles an element and its subtree: unmount hooks fire, owned widgets and
 palette slots are freed, and the elements return to the free-list. Interactivity
 pointers into the subtree are cleared — a stale one would silently retarget
 whatever reuses the slot.

 @param element : `The root of the subtree to release.`
*>
fn void Ui.release(&self, Element* element)
{
	foreach (child : element.children) self.release(child);
	if (&element.widget.unmount) element.widget.unmount(element);
	if (element.owns_widget) mem::free(((any)element.widget).ptr);
	if (element.transform_slot != NO_TRANSFORM) self.free_transform_slots.push(element.transform_slot);
	if (self.hovered == element) self.hovered = null;
	if (self.captured == element) self.captured = null;

	// The keyboard moves up to the parent rather than going out. Children are
	// released first, so a subtree containing the focused element hands it up
	// one level at a time and it comes to rest on the nearest survivor — the
	// element whose subtree was replaced, not null. Null would leave the whole
	// application deaf to keys until the next left press, which is the only
	// thing that assigns focus: dismissing a dialog that had a text field in it
	// would silently disable every shortcut in the window.
	if (self.focused == element) self.focused = element.parent;
	element.children.free();
	element.local_drawings.free();
	*element = { };
	self.free_elements.push(element);
}

<*
 An element off the free-list, or a fresh one. `all_elements` keeps every
 allocation for final cleanup.

 @return `A zeroed element owned by this Ui.`
*>
fn Element* Ui.alloc_element(&self)
{
	if (try element = self.free_elements.pop()) return element;
	Element* element = mem::new(Element);
	self.all_elements.push(element);
	return element;
}

// ---------------------------------------------------------------------------
// Invalidation — the only way anything gets recomputed.

<*
 Schedules a frame. An on-demand render loop (one that sleeps when nothing is
 happening) wakes and draws when this is set. Every invalidation below calls it,
 so ordinary state changes schedule a frame for free; a continuous animation
 keeps calling it each frame itself — the analog of a Flutter Ticker
 re-scheduling — and simply stops when it's done, letting the loop sleep.
*>
fn void Ui.request_frame(&self)
{
	self.frame_requested = true;
}

<*
 Size or child structure changed: re-layout from here, repaint here. Ancestors
 are marked so the layout walk descends to this element; their own cached sizes
 still short-circuit if nothing about them changes.
*>
fn void Element.request_layout(&self)
{
	self.dirty.layout = true;
	self.dirty.paint = true;
	for (Element* p = self.parent; p != null && !p.dirty.layout; p = p.parent) p.dirty.layout = true;
	self.ui.layout_pending = true;
	self.ui.paint_pending = true;
	self.ui.frame_requested = true;
}

<*
 Composite state changed: drop the built subtree and re-run `build()` on the
 next flush — CUI's setState. The release is DEFERRED to the build pass, so this
 is safe to call from event handlers running inside the subtree it condemns
 (releasing immediately would free the very widget whose callback is on the
 stack). Rebuilding cascades: nested composites in the fresh subtree are built in
 the same pass, Flutter-style.

 @require &self.widget.build != null : `request_build needs a widget that implements build().`
*>
fn void Element.request_build(&self)
{
	self.dirty.build = true;
	self.ui.build_pending = true;
	self.ui.frame_requested = true;
}

<*
 Appearance changed but not size: only this element's `paint()` re-runs. On a
 build widget this routes to `request_build` — a composite has no paint of its
 own, so "appearance changed" can only mean "regenerate the subtree". That makes
 `@modify` work uniformly: mutate fields, and a leaf repaints while a composite
 rebuilds.
*>
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

<*
 A provided value changed: invalidate every element that watched it, each in the
 phase it was watched from. See `Element.watch`.

 Costs one walk of the tree — the same walk `emit` makes every frame anyway —
 rather than keeping subscriber lists on the providers. Elements recycle through
 a free-list, so a stored `Element*` subscriber would have to be unsubscribed in
 `release`, and a missed one would invalidate whatever reused the slot.

 A no-op when nothing watched the type, including when nothing provided it: this
 does not check, so a writer may call it unconditionally.

 @param $Type : `The provided type that changed, not its pointer.`
*>
macro Ui.invalidate(&self, $Type)
{
	// See Element.watch for why the type is assigned rather than used directly.
	typeid changed = $Type;
	if (self.root) self.invalidate_watchers(self.root, changed);
}

<*
 The tree walk behind `Ui.invalidate`. Public only because the macro above
 expands into it.

 @param element : `Subtree root to visit.`
 @param type : `The provided type that changed.`
*>
fn void Ui.invalidate_watchers(&self, Element* element, typeid type)
{
	for (uint i = 0; i < element.watch_count; i++)
	{
		if (element.watches[i].type != type) continue;
		switch (element.watches[i].kind)
		{
			case BUILD: element.request_build();
			case LAYOUT: element.request_layout();
			case PAINT: element.request_paint();
		}
	}
	foreach (child : element.children) self.invalidate_watchers(child, type);
}

<*
 Manual placement under an absolute container (Stack). Cheap: the subtree's
 cached drawings are re-emitted at the new origin, no `paint()` calls.

 @param offset : `The new offset relative to the parent, in pixels.`
*>
fn void Element.set_offset(&self, Vec2 offset)
{
	self.offset = offset;
	self.ui.paint_pending = true;
	self.ui.frame_requested = true;
}

<*
 Asks for a pointer shape while this element is hovered. Callable from any hook,
 and `on_hover` is where it usually belongs: most interactive widgets implement
 it already to light themselves up, and a shape is only ever wanted for the
 element the pointer is on.

 The shape is resolved at the end of every `process_input`, after that frame's
 events are dispatched, so a call from `on_mouse` — the same handle closing its
 hand on the press that starts a drag — takes effect on the frame that made it,
 not the one after. It sticks until something writes another: only the hovered
 element and its ancestors are ever asked, so there is nothing to clear on the
 way out, but a widget that changes shape must write the shape BACK. A handle
 that sets CLOSED_HAND on press has to set OPEN_HAND on release, wherever the
 pointer has wandered to by then.

 Hover fires on the deepest element under the pointer, never on its ancestors.
 A widget that wants to name the shape over its whole subtree — a viewport with
 an overlay on top of it — has no hover to hang that on and should declare it
 from `mount`, which runs once and needs no layout to live in. Resolution walks
 up from the hovered element, so one declaration answers for everything inside
 that does not ask for its own.

 @param cursor : `The shape, or DEFAULT to defer to the ancestors.`
*>
fn void Element.set_cursor(&self, Cursor cursor)
{
	// Asking for the shape it already has is the common case — a layout that
	// declares one runs again on every resize — and scheduling a frame for it
	// would keep an on-demand loop awake for nothing.
	if (self.cursor == cursor) return;
	self.cursor = cursor;
	// Nothing else is invalidated: the shape is not drawn into the canvas, it is
	// handed to the window. But a loop asleep on the last frame has to wake to
	// hand it over — a cursor set from `update()` or from app code between
	// frames would otherwise not reach the pointer until something unrelated
	// happened to schedule a frame.
	self.ui.frame_requested = true;
}

<*
 Directs key events to this element (a left click on an element whose widget
 implements `on_key` does the same automatically).
*>
fn void Element.request_focus(&self)
{
	self.ui.focused = self;
}

<*
 Animation path: writes one matrix into the palette. The first call allocates a
 slot (forcing one re-emit so the subtree picks up the slot id); every call after
 that costs a 64-byte write plus a palette upload, regardless of how many
 drawings sit under this element.

 @param transform : `The matrix applied to this element's subtree, in UI pixels.`
*>
fn void Element.set_transform(&self, Matrix4f transform)
{
	Ui* ui = self.ui;
	if (self.transform_slot == NO_TRANSFORM)
	{
		self.transform_slot = ui.alloc_transform_slot();
		ui.paint_pending = true;
	}
	// Stored as-is: the shader reads the palette as raw float4s matching
	// Matrix4f's column-major storage (see shaders/shader.slang PushData).
	ui.canvas.transforms[self.transform_slot] = transform;
	ui.canvas.transforms_dirty = true;
	ui.frame_requested = true;
}

<*
 A palette slot off the free-list, or a fresh identity one.

 @return `The slot index, for Element.transform_slot.`
*>
fn uint Ui.alloc_transform_slot(&self)
{
	if (try slot = self.free_transform_slots.pop()) return slot;
	self.canvas.transforms.push(matrix::IDENTITY4);
	return (uint)self.canvas.transforms.len() - 1;
}

// ---------------------------------------------------------------------------
// Layout helpers available to Widget.layout implementations.

<*
 Lays out one child under the given constraints and returns the size it took.
 The cache short-circuits this when the child is clean and the constraints are
 unchanged, so calling it for every child on every layout is the normal thing.

 @param index : `Index into this element's children.`
 @param constraints : `The size range offered to the child.`
 @require index < self.children.len() : `layout_child index is out of range — the widget asked for a child it does not have.`
 @return `The size the child chose.`
*>
fn Vec2 Element.layout_child(&self, sz index, Constraints constraints)
{
	return self.ui.layout_element(self.children[index], constraints);
}

<*
 Positions a child relative to this element's origin. Call it after
 `layout_child`, from the same `layout()`.

 @param index : `Index into this element's children.`
 @param offset : `The child's origin relative to this element, in pixels.`
 @require index < self.children.len() : `place_child index is out of range — the widget placed a child it does not have.`
*>
fn void Element.place_child(&self, sz index, Vec2 offset)
{
	self.children[index].offset = offset;
}

<*
 Lays every child out under the same constraints, discarding the sizes and
 leaving the offsets alone — what a container that stacks its children in one
 place does, and what the framework itself does for a widget with no `layout`.

 For anything that positions children by measuring them, use `layout_child` per
 child and keep the size it returns.

 @param constraints : `The range offered to each child.`
*>
fn void Element.layout_children(&self, Constraints constraints)
{
	foreach (child : self.children) self.ui.layout_element(child, constraints);
}

// ---------------------------------------------------------------------------
// Frame flush: build pass, then layout pass, then paint + emit pass.

<*
 Services whatever was invalidated since the last frame — build, then layout,
 then paint + emit — and leaves the result in `ui.canvas` for the renderer. Call
 once per frame, after `process_input` and after any app-side mutation. Returns
 immediately when nothing is pending, which is what lets an idle UI cost nothing.
*>
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

<*
 Build pass: materialize composite widgets. Runs before layout, so `build` may
 freely append / request_layout — nothing is mid-pass yet. Recursing into
 children AFTER building the element means composites nested inside a freshly
 built subtree are built in the same pass, however deep they stack — so a rebuild
 regenerates its nested composites too, Flutter-style.

 A rebuild is a naive replace: the old subtree is released wholesale (unmount
 hooks fire, elements recycle) and `build()` runs fresh. The contract that makes
 this correct rather than lossy: build is a pure function of the composite's OWN
 fields — state that must survive a rebuild belongs on the composite (or above),
 not on widgets inside the built subtree. See build.md.

 @param element : `The subtree root to build.`
*>
fn void Ui.build_element(&self, Element* element)
{
	if (element.dirty.build)
	{
		element.dirty.build = false;
		foreach (child : element.children) self.release(child);
		element.children.clear();
		Element* subtree;
		self.@watching(element, WatchKind.BUILD)
		{
			subtree = element.widget.build(element);
		};
		subtree.parent = element;
		element.children.push(subtree);
		element.request_layout();
	}
	foreach (child : element.children) self.build_element(child);
}

<*
 Layout pass: size one element under constraints, recursing through whatever its
 `layout()` asks for. Not dirty and same constraints means same size, so none of
 the subtree's layout code runs — that cache is what keeps a local change local.

 Also where `mount` fires, the first time an element is reached. Every element
 in the tree is reached by this walk before it can be painted or hit tested, so
 that is the earliest point at which a hook can see a wired parent chain.

 @param element : `The element to size.`
 @param constraints : `The size range offered to it.`
 @return `The size it took.`
*>
fn Vec2 Ui.layout_element(&self, Element* element, Constraints constraints)
{
	// Ahead of the cache check, so mounting is the first thing that ever
	// happens to an element: a fresh one is always dirty and cannot reach the
	// early return, but a hook that runs before the size is decided is the
	// contract, not an accident of the flags.
	if (!element.mounted)
	{
		element.mounted = true;
		if (&element.widget.mount) element.widget.mount(element);
	}

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
		self.@watching(element, WatchKind.LAYOUT)
		{
			size = element.widget.layout(element, constraints);
		};
	}
	else if (element.auto_size)
	{
		// The size-field convention: the widget's `Vec2 size` field, read live
		// through the getter the node macro planted. Per axis it means what it
		// means on the built-in containers — a set component is that many
		// pixels, a zero component fills whatever the parent offered — so a
		// widget gets fixed, fill or a mix of the two with no layout code.
		size = constraints.fill(element.auto_size(((any)element.widget).ptr));
		element.layout_children(loose(size));
	}
	else if (&element.widget.build)
	{
		// Composite default: single-child passthrough — the built subtree
		// decides the size. Implement layout to override.
		size = element.layout_child(0, constraints);
		element.place_child(0, { 0, 0 });
	}
	else
	{
		// A widget that says nothing about size fills what it is offered —
		// children get loose constraints and keep their offsets. One rule for
		// leaves and containers alike, and the same answer a zero size field
		// gives, so "no sizing code" always means "inherit from the parent".
		size = constraints.max;
		element.layout_children(loose(size));
	}

	if (!vec2_eq(size, element.size))
	{
		element.size = size;
		element.dirty.paint = true;
		self.paint_pending = true;
	}
	return size;
}

<*
 Paint + emit pass: repaint dirty elements into their local caches, then append
 every element's drawings to the canvas shifted to absolute coordinates, stamped
 with the transform slot and clip id in force. A moved-but-clean element re-emits
 from cache without its `paint()` running.

 @param element : `The subtree root to emit.`
 @param origin : `The parent's absolute origin, in UI pixels.`
 @param inherited_slot : `The transform palette slot in force, 0 = identity.`
 @param inherited_clip : `The clip entry in force, 0 = unclipped.`
*>
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
			self.@watching(element, WatchKind.PAINT)
			{
				Painter painter = { .element = element };
				element.widget.paint(element, &painter);
			};
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

<*
 Exact component-wise equality — what the layout cache compares sizes and
 constraints with.

 @param a : `First vector.`
 @param b : `Second vector.`
 @return `True when both components match exactly.`
*>
fn bool vec2_eq(Vec2 a, Vec2 b) => a.x == b.x && a.y == b.y;

// ---------------------------------------------------------------------------
// Painter: what Widget.paint implementations draw with.

<*
 Style for `Painter.rect`. Corner radii run {top-left, top-right, bottom-right,
 bottom-left} and are clamped to what the shape can fit; the border is drawn
 inside the edge.
*>
struct RectStyle
{
	Color color;
	Color border_color;
	float border_width; // px, inside the edge
	Vec4 border_radius; // per-corner px {TL, TR, BR, BL}
	Texture texture; // from Renderer.load_image; default = untextured
}

<*
 Style for `Painter.circle` / `Painter.ellipse`. The border is drawn inside the
 edge; a texture is sampled across the shape's bounding box.
*>
struct CircleStyle
{
	Color color;
	Color border_color;
	float border_width; // px, inside the edge
	Texture texture; // sampled across the shape's bounding box
}

<*
 What `Widget.paint` draws with. Positions are LOCAL to the element; the emit
 pass translates them to absolute coordinates, which is why a moved element does
 not repaint.

 All units are pixels; angles are radians with 0 = +x, increasing clockwise on
 screen (y points down).
*>
struct Painter
{
	Element* element;
}

<*
 A (rounded) rectangle.

 @param pos : `Top-left corner, local to the element.`
 @param size : `Width and height in pixels.`
 @param style : `Fill, border and corner radii.`
 @require size.x >= 0 && size.y >= 0 : `A rect cannot have a negative size.`
*>
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

<*
 A circle.

 @param center : `Center, local to the element.`
 @param radius : `Radius in pixels.`
 @param style : `Fill and border.`
 @require radius >= 0 : `A circle cannot have a negative radius.`
*>
fn void Painter.circle(&self, Vec2 center, float radius, CircleStyle style = { })
{
	self.ellipse(center, { radius, radius }, style);
}

<*
 An axis-aligned ellipse.

 @param center : `Center, local to the element.`
 @param radii : `Horizontal and vertical radius in pixels.`
 @param style : `Fill and border.`
 @require radii.x >= 0 && radii.y >= 0 : `An ellipse cannot have negative radii.`
*>
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

<*
 A line segment with rounded caps.

 @param from : `Start point, local to the element.`
 @param to : `End point, local to the element.`
 @param thickness : `Stroke width in pixels.`
 @param color : `Stroke color.`
 @require thickness >= 0 : `A line cannot have a negative thickness.`
*>
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

<*
 A stroked circular arc with rounded caps — progress rings and spinners.

 @param center : `Center of the circle, local to the element.`
 @param radius : `Radius of the arc's centerline, in pixels.`
 @param start : `Start angle in radians (0 = +x, increasing clockwise).`
 @param sweep : `Angle spanned, in radians. 2π or more draws the full ring.`
 @param thickness : `Stroke width in pixels.`
 @param color : `Stroke color.`
 @require radius >= 0 : `An arc cannot have a negative radius.`
 @require thickness >= 0 : `An arc cannot have a negative thickness.`
*>
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

<*
 A soft drop shadow of a (rounded) rect: the edge fades over `blur` px each way.
 Paint it before the shape casting it; a border_radius of half the size makes it
 circular.

 @param pos : `Top-left corner of the shape casting the shadow, local to the element.`
 @param size : `Size of that shape, in pixels.`
 @param blur : `Fade distance each way from the edge, in pixels.`
 @param color : `Shadow color.`
 @param border_radius : `Per-corner radii {TL, TR, BR, BL} of the shape.`
 @require size.x >= 0 && size.y >= 0 : `A shadow cannot have a negative size.`
 @require blur >= 0 : `A shadow cannot have a negative blur.`
*>
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
