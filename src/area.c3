<*
 Split areas: a Blender-style workspace where the window is a tree of panes,
 every pane can be split in two (side by side or stacked) and closed back into
 its sibling, and each pane picks what it shows from a strip of tabs.

 The app owns the data (AreaLayout: a node tree plus a registry of views) and
 mounts one AreaHost over it; everything else — panes, tab strips, dividers —
 is built and rebuilt from that data by composites. A view is just a function
 returning a detached subtree, so anything buildable is a view; per-view state
 that must survive a tab switch or a split belongs on the app (reached through
 `ui.inherit`, like every other callback here), because the built subtree is
 released wholesale on every structural change.

 Ownership follows the menu widgets: the AreaLayout, its views array and the
 style are borrowed by every widget below and must outlive the Ui. The node
 tree itself is heap-allocated and owned by the AreaLayout.

 One invariant keeps structural changes safe: no widget in this file may
 implement `update()`. A split or close frees AreaNodes whose pointers are
 still held by the condemned subtree's widgets until the next build pass
 releases it (`request_build` defers exactly for this reason) — an update tick
 running on the old tree in between would dereference freed nodes.
*>
module cui::widgets;
import std::math;

import cui;

<*
 How a split divides its pane. HORIZONTAL puts the children side by side
 (a vertical divider between them), VERTICAL stacks them (a horizontal one) —
 named for the axis the panes are laid out along, as Row and Column are.
*>
enum SplitAxis
{
	HORIZONTAL,
	VERTICAL,
}

<*
 One look for the whole area system. Pass a complete style or none at all: a
 zero `tab_height` means "use DEFAULT_AREA_STYLE wholesale", and a partially
 filled style is not merged field-by-field (the MenuStyle convention).
*>
struct AreaStyle
{
	Color strip_color; // tab strip background
	Color strip_border; // the 1px line under the strip
	Color tab_active; // behind the active tab
	Color hover_color; // behind the hovered tab, glyph or dragged divider
	Color text_color; // active tab label and glyph ink
	Color dim_color; // inactive tab labels; the root's dead close glyph
	Color splitter_color; // divider bar at rest
	FontId font; // 0 = the first loaded font
	float text_size;
	float tab_height; // 0 = the whole style defaults
	float pad_x; // horizontal padding inside a tab
	float splitter_px; // divider thickness
	float min_pane; // least extent a pane keeps on the split axis
}

const AreaStyle DEFAULT_AREA_STYLE = {
	.strip_color = { 0.13, 0.14, 0.18, 1.0 },
	.strip_border = { 0.28, 0.30, 0.38, 1.0 },
	.tab_active = { 0.22, 0.24, 0.31, 1.0 },
	.hover_color = { 0.28, 0.31, 0.40, 1.0 },
	.text_color = { 0.92, 0.93, 0.95, 1.0 },
	.dim_color = { 0.55, 0.58, 0.66, 1.0 },
	.splitter_color = { 0.28, 0.30, 0.38, 1.0 },
	.text_size = 13.0,
	.tab_height = 24.0,
	.pad_x = 12.0,
	.splitter_px = 5.0,
	.min_pane = 100.0,
};

fn AreaStyle AreaStyle.resolved(self)
{
	return self.tab_height > 0 ? self : DEFAULT_AREA_STYLE;
}

<*
 Builds one view's content as a detached subtree (the shape `@subtree` returns).
 Receives only the Ui, like OnClick — the builder reaches the app through
 `ui.inherit`, since the registry is data and C3 functions close over nothing.
*>
alias ViewBuilder = fn Element*(Ui* ui);

<*
 One entry in the view registry: the tab label and the builder behind it.
*>
struct AreaView
{
	String name; // borrowed; must outlive the widget
	ViewBuilder build;
}

<*
 One node of the area tree. A null `first` marks a leaf showing a view; a split
 carries its two children, the axis and where the divider sits.
*>
struct AreaNode
{
	AreaNode* first; // null = leaf
	AreaNode* second;
	SplitAxis axis;
	float ratio; // the first child's share of the split, 0..1
	usz active; // leaf: index into AreaLayout.views
}

fn bool AreaNode.is_leaf(&self)
{
	return self.first == null;
}

<*
 The app-owned model an AreaHost renders: the node tree, the views every leaf
 offers as tabs, and the style. Operations here only mutate the tree — the
 caller (in practice AreaTabStrip) requests the rebuild that makes them
 visible.
*>
struct AreaLayout
{
	AreaNode* root; // owned; allocated by init, released by free
	AreaView[] views; // borrowed
	AreaStyle style;
}

<*
 Starts (or restarts) the layout as a single leaf showing the first view. Safe
 to call on a live AreaLayout: a previous tree is released first, so a fixture
 that rebuilds its UI can share one global.

 @param views : `The view registry, borrowed. Every leaf offers all of them.`
 @param style : `A complete style, or {} for DEFAULT_AREA_STYLE.`
 @require views.len > 0 : `An area layout needs at least one view to show.`
*>
fn void AreaLayout.init(&self, AreaView[] views, AreaStyle style = {})
{
	if (self.root) free_node(self.root);
	self.views = views;
	self.style = style;
	self.root = mem::new(AreaNode);
	self.root.ratio = 0.5;
}

<*
 Releases the node tree. The views array and style are borrowed and untouched.
*>
fn void AreaLayout.free(&self)
{
	if (self.root) free_node(self.root);
	self.root = null;
}

fn void free_node(AreaNode* node) @private
{
	if (!node.is_leaf())
	{
		free_node(node.first);
		free_node(node.second);
	}
	mem::free(node);
}

<*
 Turns a leaf into an even split whose two new leaves both keep the view the
 leaf was showing.

 @param leaf : `The leaf to split.`
 @param axis : `HORIZONTAL for side by side, VERTICAL for stacked.`
 @require leaf.is_leaf() : `Only a leaf can be split — a split node already is one.`
*>
fn void AreaLayout.split_leaf(&self, AreaNode* leaf, SplitAxis axis)
{
	AreaNode* a = mem::new(AreaNode);
	AreaNode* b = mem::new(AreaNode);
	a.ratio = 0.5;
	a.active = leaf.active;
	b.ratio = 0.5;
	b.active = leaf.active;
	leaf.first = a;
	leaf.second = b;
	leaf.axis = axis;
	leaf.ratio = 0.5;
}

<*
 Closes a leaf: its sibling takes over the parent's spot, whether that sibling
 is a leaf or a whole subtree. The root cannot close — false says nothing
 changed, so the caller skips the rebuild.

 @param leaf : `The leaf to close.`
 @require leaf.is_leaf() : `Only a leaf can be closed — its strip is where the control lives.`
 @return `True when the tree changed.`
*>
fn bool AreaLayout.close_leaf(&self, AreaNode* leaf)
{
	if (leaf == self.root) return false;
	AreaNode* parent = find_parent(self.root, leaf);
	if (!parent) return false;
	AreaNode* sibling = parent.first == leaf ? parent.second : parent.first;
	*parent = *sibling;
	mem::free(sibling);
	mem::free(leaf);
	return true;
}

fn AreaNode* find_parent(AreaNode* node, AreaNode* child) @private
{
	if (node.is_leaf()) return null;
	if (node.first == child || node.second == child) return node;
	AreaNode* hit = find_parent(node.first, child);
	return hit ? hit : find_parent(node.second, child);
}

// ---------------------------------------------------------------------------
// Widgets. AreaHost is the one the app mounts; the rest are built from the
// node tree by the composites.

<*
 The mount point: renders an AreaLayout inside its own rect. Sized by the
 `size` field (zero = fill). Structural changes — split, close — rebuild from
 here; a tab switch rebuilds only its own pane.
*>
struct AreaHost (Widget)
{
	AreaLayout* areas; // borrowed
	Vec2 size; // per axis: 0 = fill the available space
}

<*
 @param elem : `The element this widget is attached to.`
 @require self.areas != null && self.areas.root != null : `An AreaHost needs an initialized AreaLayout — call AreaLayout.init first.`
 @return `The pane tree for the root node.`
*>
fn Element* AreaHost.build(&self, Element* elem) @dynamic
{
	return elem.ui.@node((AreaPane) { .areas = self.areas, .node = self.areas.root, .host = elem });
}

<*
 One composite per AreaNode. A leaf builds its tab strip over the active view's
 subtree; a split builds two nested panes and the divider between them. Nested
 panes are composites too, so the whole tree materializes in one build pass.
*>
struct AreaPane (Widget)
{
	AreaLayout* areas; // borrowed
	AreaNode* node; // borrowed from the layout's tree
	Element* host; // the AreaHost element — structural changes rebuild there
}

fn Element* AreaPane.build(&self, Element* elem) @dynamic
{
	Ui* ui = elem.ui;
	if (self.node.is_leaf())
	{
		Element* strip = ui.@node((AreaTabStrip) {
			.areas = self.areas,
			.node = self.node,
			.pane = elem,
			.host = self.host,
		});
		Element* content = self.areas.views[self.node.active].build(ui);
		return ui.@node((Column) { }, strip, content);
	}

	AreaStyle s = self.areas.style.resolved();
	Element* a = ui.@node((AreaPane) { .areas = self.areas, .node = self.node.first, .host = self.host });
	Element* b = ui.@node((AreaPane) { .areas = self.areas, .node = self.node.second, .host = self.host });
	// The handle last: siblings hit-test in reverse order, so the divider wins
	// the boundary pixels it shares with the panes.
	Element* handle = ui.@node((AreaSplitter) { .node = self.node, .style = s });
	return ui.@node((AreaSplit) { .node = self.node, .style = s }, a, b, handle);
}

<*
 The divider's owner: places the two panes and the handle from the node's ratio
 under TIGHT constraints, so each pane is exactly its share and a ratio change
 is a relayout away.
*>
struct AreaSplit (Widget)
{
	AreaNode* node; // borrowed
	AreaStyle style; // resolved by the pane that built it
}

<*
 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() == 3 : `AreaSplit is built by AreaPane with exactly two panes and a handle.`
 @return `The size taken: everything offered.`
*>
fn Vec2 AreaSplit.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	AreaStyle s = self.style;
	Vec2 own = constraints.max;
	bool side = self.node.axis == SplitAxis.HORIZONTAL;

	float extent = side ? own.x : own.y;
	float total = math::max(extent - s.splitter_px, 0.0f);
	float first = self.node.ratio * total;
	// Clamp to the minimum pane on both ends; a pane too small to hold two
	// minimums (a degenerate host, mostly in tests) falls back to the raw ratio.
	if (total >= 2 * s.min_pane) first = math::clamp(first, s.min_pane, total - s.min_pane);

	Vec2 a = side ? (Vec2) { first, own.y } : (Vec2) { own.x, first };
	Vec2 b = side ? (Vec2) { total - first, own.y } : (Vec2) { own.x, total - first };
	Vec2 handle = side ? (Vec2) { s.splitter_px, own.y } : (Vec2) { own.x, s.splitter_px };

	elem.layout_child(0, { .min = a, .max = a });
	elem.place_child(0, { 0, 0 });
	elem.layout_child(1, { .min = b, .max = b });
	elem.place_child(1, side ? (Vec2) { first + s.splitter_px, 0 } : (Vec2) { 0, first + s.splitter_px });
	elem.layout_child(2, { .min = handle, .max = handle });
	elem.place_child(2, side ? (Vec2) { first, 0 } : (Vec2) { 0, first });
	return own;
}

<*
 The draggable divider. Consuming the press captures the pointer, so the drag
 keeps working however far it outruns this thin bar; the ratio is recomputed
 from the absolute pointer position against the parent split's rect.
*>
struct AreaSplitter (Widget)
{
	AreaNode* node; // borrowed
	AreaStyle style; // resolved by the pane that built it
	bool dragging;
	bool hovered;
}

fn Vec2 AreaSplitter.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = self.node.axis == SplitAxis.HORIZONTAL ? Cursor.RESIZE_H : Cursor.RESIZE_V;
	return constraints.max;
}

fn void AreaSplitter.paint(&self, Element* elem, Painter* painter) @dynamic
{
	bool lit = self.dragging || self.hovered;
	painter.rect({ 0, 0 }, elem.size, { .color = lit ? self.style.hover_color : self.style.splitter_color });
}

fn void AreaSplitter.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	elem.request_paint();
}

fn bool AreaSplitter.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			self.dragging = true;
			elem.request_paint();
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			elem.request_paint();
			return true;
		case MOVE:
			if (!self.dragging) return false;
			Element* split = elem.parent;
			bool side = self.node.axis == SplitAxis.HORIZONTAL;
			float pos = side ? event.absolute.x - split.absolute.x : event.absolute.y - split.absolute.y;
			float total = (side ? split.size.x : split.size.y) - self.style.splitter_px;
			if (total <= 0) return true;
			// The pointer holds the handle's center; the ratio divides the rest.
			float first = pos - self.style.splitter_px * 0.5f;
			float lo = total >= 2 * self.style.min_pane ? self.style.min_pane / total : 0.0f;
			self.node.ratio = math::clamp(first / total, lo, 1.0f - lo);
			split.request_layout();
			return true;
		default:
			return false;
	}
}

// ---------------------------------------------------------------------------
// The tab strip.

// Hit zones, shared by paint and on_mouse so they cannot disagree. Positive
// values are a tab's index + 1 (zero stays "none", the TintToggles encoding);
// the controls at the right edge get negative codes.
const int AREA_ZONE_NONE = 0;
const int AREA_ZONE_SPLIT_SIDE = -1; // split into left | right
const int AREA_ZONE_SPLIT_STACK = -2; // split into top / bottom
const int AREA_ZONE_CLOSE = -3;

<*
 One leaf's header: a tab per registered view, then three glyph buttons —
 split side-by-side, split stacked, close. Selection state lives on the
 AreaNode, so the strip itself survives nothing and needs to survive nothing:
 a tab switch rebuilds its pane, a split or close rebuilds the whole host.
*>
struct AreaTabStrip (Widget)
{
	AreaLayout* areas; // borrowed
	AreaNode* node; // borrowed from the layout's tree
	Element* pane; // the AreaPane element: tab switches rebuild there
	Element* host; // the AreaHost element: split and close rebuild there
	int lit; // hovered zone code, AREA_ZONE_NONE when the pointer is elsewhere
}

fn Vec2 AreaTabStrip.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.cursor = Cursor.POINTING_HAND;
	AreaStyle s = self.areas.style.resolved();
	return cui::clamp_size({ constraints.max.x, s.tab_height }, constraints);
}

<*
 A tab's width: its measured label plus padding. The padding alone is the
 floor, so a fontless Ui (headless tests) still gets a clickable strip.
*>
fn float AreaTabStrip.tab_width(&self, Ui* ui, AreaStyle s, usz index)
{
	float text = ui.text.measure(s.font, self.areas.views[index].name, s.text_size).x;
	return math::max(text + 2 * s.pad_x, 2 * s.pad_x);
}

<*
 The zone under a point, in element-local pixels. Glyphs are checked first —
 they own the strip's right edge whatever the tabs measure.
*>
fn int AreaTabStrip.zone_at(&self, Element* elem, Vec2 pos)
{
	if (pos.x < 0 || pos.y < 0 || pos.y >= elem.size.y) return AREA_ZONE_NONE;

	float h = elem.size.y;
	float close_x = elem.size.x - h;
	if (pos.x >= close_x) return AREA_ZONE_CLOSE;
	if (pos.x >= close_x - h) return AREA_ZONE_SPLIT_STACK;
	if (pos.x >= close_x - 2 * h) return AREA_ZONE_SPLIT_SIDE;

	AreaStyle s = self.areas.style.resolved();
	float x = 0;
	foreach (i, view : self.areas.views)
	{
		float w = self.tab_width(elem.ui, s, (usz)i);
		if (pos.x < x + w) return (int)i + 1;
		x += w;
	}
	return AREA_ZONE_NONE;
}

fn void AreaTabStrip.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AreaStyle s = self.areas.style.resolved();
	float h = elem.size.y;
	painter.rect({ 0, 0 }, elem.size, { .color = s.strip_color });
	painter.rect({ 0, h - 1 }, { elem.size.x, 1 }, { .color = s.strip_border });

	float x = 0;
	foreach (i, view : self.areas.views)
	{
		float w = self.tab_width(elem.ui, s, (usz)i);
		bool active = self.node.active == (usz)i;
		if (active)
		{
			painter.rect({ x, 0 }, { w, h }, { .color = s.tab_active });
		}
		else if (self.lit == (int)i + 1)
		{
			painter.rect({ x, 0 }, { w, h }, { .color = s.hover_color });
		}
		Vec2 text = elem.ui.text.measure(s.font, view.name, s.text_size);
		painter.text({ x + s.pad_x, (h - text.y) * 0.5f }, view.name, {
			.font = s.font,
			.size = s.text_size,
			.color = active ? s.text_color : s.dim_color,
		});
		x += w;
	}

	int[3] zones = { AREA_ZONE_SPLIT_SIDE, AREA_ZONE_SPLIT_STACK, AREA_ZONE_CLOSE };
	foreach (i, zone : zones)
	{
		float gx = elem.size.x - (float)(3 - i) * h;
		bool dead = zone == AREA_ZONE_CLOSE && self.node == self.areas.root;
		if (self.lit == zone && !dead)
		{
			painter.rect({ gx, 0 }, { h, h }, { .color = s.hover_color });
		}
		paint_area_glyph(painter, zone, { gx, 0 }, h, dead ? s.dim_color.dim(0.55f) : s.text_color);
	}
}

<*
 The three control glyphs, drawn from primitives: a framed pane cut by the
 divider the split would add, and a plain cross for close.

 @param origin : `Top-left of the glyph's square cell, element-local.`
 @param h : `The cell's side — the strip height.`
*>
fn void paint_area_glyph(Painter* painter, int zone, Vec2 origin, float h, Color ink) @private
{
	float inset = h * 0.3f;
	Vec2 lo = origin + inset;
	Vec2 hi = origin + h - inset;
	Vec2 mid = (lo + hi) * 0.5f;
	switch (zone)
	{
		case AREA_ZONE_SPLIT_SIDE:
			painter.rect(lo, hi - lo, { .border_width = 1.2f, .border_color = ink });
			painter.line({ mid.x, lo.y }, { mid.x, hi.y }, 1.2f, ink);
		case AREA_ZONE_SPLIT_STACK:
			painter.rect(lo, hi - lo, { .border_width = 1.2f, .border_color = ink });
			painter.line({ lo.x, mid.y }, { hi.x, mid.y }, 1.2f, ink);
		case AREA_ZONE_CLOSE:
			painter.line(lo, hi, 1.4f, ink);
			painter.line({ lo.x, hi.y }, { hi.x, lo.y }, 1.4f, ink);
		default:
			break;
	}
}

fn bool AreaTabStrip.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int zone = self.zone_at(elem, event.pos);
			switch
			{
				case zone > 0:
					usz index = (usz)(zone - 1);
					if (self.node.active != index)
					{
						self.node.active = index;
						self.pane.request_build();
					}
				case zone == AREA_ZONE_SPLIT_SIDE:
					self.areas.split_leaf(self.node, SplitAxis.HORIZONTAL);
					self.host.request_build();
				case zone == AREA_ZONE_SPLIT_STACK:
					self.areas.split_leaf(self.node, SplitAxis.VERTICAL);
					self.host.request_build();
				case zone == AREA_ZONE_CLOSE:
					if (self.areas.close_leaf(self.node)) self.host.request_build();
				default:
					break;
			}
			// The strip is a control bar: even a miss swallows the press, so a
			// sloppy click cannot land in the content below.
			return true;
		case RELEASE:
			return event.button == MouseButton.LEFT;
		case MOVE:
			int was = self.lit;
			self.lit = self.zone_at(elem, event.pos);
			if (self.lit != was) elem.request_paint();
			return true;
		default:
			return false;
	}
}

fn void AreaTabStrip.on_hover(&self, Element* elem, bool entered) @dynamic
{
	// Leaving produces no MOVE inside the widget, so the highlight has to be
	// cleared here or the last zone stays lit with the pointer gone.
	if (entered || self.lit == AREA_ZONE_NONE) return;
	self.lit = AREA_ZONE_NONE;
	elem.request_paint();
}
