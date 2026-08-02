<*
 Split areas: a workspace where the window is a tree of panes,
 every pane can be split in two (side by side or stacked) and closed back into
 its sibling, and each pane picks what it shows from a strip of tabs.

 The app owns the data (AreaLayout: a node tree plus a registry of views) and
 mounts one AreaHost over it; everything else — panes, tab strips, dividers —
 is built and rebuilt from that data by composites. A view is just a function
 returning a detached subtree, so anything buildable is a view; per-view state
 that must survive a tab switch or a split belongs on the app (reached through
 `ui.inherit`, like every other callback here), because the built subtree is
 released wholesale on every structural change.

 Structural changes all go through the context menu: a right press on a pane's
 content (anything deeper that wants the right button just consumes it first)
 offers the splits and close, one on a divider offers merging the two sides.
 Merge directions name the side that remains, the way Photoshop's Merge Down
 leaves the lower layer: Merge Left keeps the left pane and hands it the right
 one's space.

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
	Color hover_color; // behind the hovered tab, menu row or dragged divider
	Color text_color; // active tab label and menu row ink
	Color dim_color; // inactive tab labels; disabled menu rows
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

<*
 Collapses a split to one of its sides: the kept child — a leaf or a whole
 subtree of further splits — takes the split's place, and the other side is
 freed. Where close_leaf retires panes one by one, this is the divider's
 one-step merge, and it works at any depth including the root.

 @param split : `The split whose divider is merged away.`
 @param keep_first : `True keeps the first child (left/top), false the second.`
 @require !split.is_leaf() : `Only a split has two sides to merge.`
*>
fn void AreaLayout.merge_split(&self, AreaNode* split, bool keep_first)
{
	AreaNode* keep = keep_first ? split.first : split.second;
	AreaNode* drop = keep_first ? split.second : split.first;
	free_node(drop);
	*split = *keep;
	mem::free(keep);
}

// ---------------------------------------------------------------------------
// Widgets. AreaHost is the one the app mounts; the rest are built from the
// node tree by the composites.

<*
 The mount point: renders an AreaLayout inside its own rect. Sized by the
 `size` field (zero = fill). Structural changes — split, close, merge — rebuild
 from here; a tab switch rebuilds only its own pane.

 Also the owner of the context menu: a right press on a pane or a divider
 parks the target node here and rebuilds, and the open shape adds a
 window-sized catcher plus the popup over the pane tree — MenuBar's
 escape-the-rect trick. While the menu is open the catcher blankets every
 strip and divider, so nothing else can mutate the tree under the parked
 pointer, which is what keeps holding an AreaNode* across frames sound.
*>
struct AreaHost (Widget)
{
	AreaLayout* areas; // borrowed
	Vec2 size; // per axis: 0 = fill the available space
	AreaNode* menu_node; // the context menu's target; null = no menu open
	bool menu_merge; // true: merge entries for a split; false: split entries for a leaf
	Vec2 menu_at; // where the right press landed, in window coordinates
}

<*
 @param elem : `The element this widget is attached to.`
 @require self.areas != null && self.areas.root != null : `An AreaHost needs an initialized AreaLayout — call AreaLayout.init first.`
 @return `The pane tree for the root node, with the context menu over it while one is open.`
*>
fn Element* AreaHost.build(&self, Element* elem) @dynamic
{
	Ui* ui = elem.ui;
	Element* pane = ui.@node((AreaPane) { .areas = self.areas, .node = self.areas.root, .host = elem });
	if (!self.menu_node) return pane;

	AreaStyle s = self.areas.style.resolved();

	AreaMenuEntry[3] slots;
	AreaMenuEntry[] entries;
	if (self.menu_merge)
	{
		bool side = self.menu_node.axis == SplitAxis.HORIZONTAL;
		slots[0] = { side ? "Merge Left" : "Merge Up", AreaMenuAction.MERGE_FIRST, false };
		slots[1] = { side ? "Merge Right" : "Merge Down", AreaMenuAction.MERGE_SECOND, false };
		entries = slots[:2];
	}
	else
	{
		slots[0] = { "Split Vertical", AreaMenuAction.SPLIT_SIDE, false };
		slots[1] = { "Split Horizontal", AreaMenuAction.SPLIT_STACK, false };
		slots[2] = { "Close", AreaMenuAction.CLOSE, self.menu_node == self.areas.root };
		entries = slots[:3];
	}

	float row_w = AREA_MENU_MIN_W;
	foreach (entry : entries)
	{
		row_w = math::max(row_w, ui.text.measure(s.font, entry.label, s.text_size).x + 2 * s.pad_x);
	}

	Element* column = ui.@node((Column) { });
	foreach (entry : entries)
	{
		column.append(ui.@node((AreaMenuRow) {
			.label = entry.label,
			.action = entry.action,
			.disabled = entry.disabled,
			.style = s,
			.width = row_w,
			.host = elem,
		}).with_id(entry.label));
	}

	// The catcher walks itself back to the window origin so a click anywhere —
	// the menu bar included — dismisses; elem.absolute is the previous emit's
	// value, which is current because opening a menu does not move the host.
	Element* catcher = ui.@node((AreaMenuCatcher) { .host = elem });
	catcher.set_offset({ -elem.absolute.x, -elem.absolute.y });

	Element* panel = ui.@node((PopupPanel) {
		.style = {
			.color = s.strip_color,
			.border_width = 1.0,
			.border_color = s.strip_border,
			.border_radius = { 6.0, 6.0, 6.0, 6.0 },
		},
		.insets = { 0.0, PANEL_PAD_Y, 0.0, PANEL_PAD_Y },
		.shadow = POPUP_SHADOW,
		.shadow_color = { 0.0, 0.0, 0.0, 0.45 },
	}, column);

	// Under the pointer, but clamped inside the host so a click near an edge
	// does not hang the popup off the window.
	Vec2 panel_size = { row_w, (float)entries.len * AREA_MENU_ROW_H + 2 * PANEL_PAD_Y };
	Vec2 at = self.menu_at - elem.absolute;
	at.x = math::clamp(at.x, 0.0f, math::max(elem.size.x - panel_size.x, 0.0f));
	at.y = math::clamp(at.y, 0.0f, math::max(elem.size.y - panel_size.y, 0.0f));
	panel.set_offset(at);

	// Hit tests run in reverse order: rows first, then the catcher, then the
	// pane tree it blankets.
	return ui.@node((Stack) { }, pane, catcher, panel);
}

<*
 Parks the context menu's target on the host and rebuilds into the open shape.
 Shared by the pane (split entries) and the divider (merge entries).
*>
fn void area_open_menu(Element* host_elem, AreaNode* node, bool merge, Vec2 at) @private
{
	AreaHost* host = host_elem.widget_as(AreaHost);
	host.menu_node = node;
	host.menu_merge = merge;
	host.menu_at = at;
	host_elem.request_build();
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
		// A pane is a window onto its view: whatever the content overflows —
		// an overlay line longer than a narrow pane — stops at the pane's
		// edge instead of bleeding into the neighbor. The price, for a view
		// that pops a dropdown near a pane edge, is that popups clip too;
		// float those from something host-sized, the way the context menu is.
		elem.clips = true;
		Element* strip = ui.@node((AreaTabStrip) {
			.areas = self.areas,
			.node = self.node,
			.pane = elem,
		});
		Element* content = self.areas.views[self.node.active].build(ui);
		return ui.@node((Column) { }, strip, content);
	}

	AreaStyle s = self.areas.style.resolved();
	Element* a = ui.@node((AreaPane) { .areas = self.areas, .node = self.node.first, .host = self.host });
	Element* b = ui.@node((AreaPane) { .areas = self.areas, .node = self.node.second, .host = self.host });
	// The handle last: siblings hit-test in reverse order, so the divider wins
	// the boundary pixels it shares with the panes.
	Element* handle = ui.@node((AreaSplitter) { .node = self.node, .style = s, .host = self.host });
	return ui.@node((AreaSplit) { .node = self.node, .style = s }, a, b, handle);
}

<*
 The leaf's context menu: a right press that nothing in the view's content
 wanted bubbles here and opens the split/close entries for this pane. Content
 that consumes the right button for its own gestures simply keeps it — the
 menu is the fallback, not an override.
*>
fn bool AreaPane.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (!self.node.is_leaf()) return false;
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.RIGHT) return false;
			// With the left button held a drag is in flight and the capture
			// routes every press here; opening the menu would rebuild the tree
			// out from under that drag.
			if (elem.ui.input.down[MouseButton.LEFT.ordinal]) return false;
			area_open_menu(self.host, self.node, false, event.absolute);
			return true;
		case RELEASE:
			return event.button == MouseButton.RIGHT;
		default:
			return false;
	}
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
 from the absolute pointer position against the parent split's rect. A right
 press opens the merge menu for the two sides this divider separates.
*>
struct AreaSplitter (Widget)
{
	AreaNode* node; // borrowed
	AreaStyle style; // resolved by the pane that built it
	Element* host; // the AreaHost element: the merge menu opens there
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
			if (event.button == MouseButton.RIGHT && !self.dragging)
			{
				area_open_menu(self.host, self.node, true, event.absolute);
				return true;
			}
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

// The hovered tab as its index + 1, shared by paint and on_mouse so they
// cannot disagree — zero is "none", the TintToggles encoding.
const int AREA_ZONE_NONE = 0;

<*
 One leaf's header: a tab per registered view. Selection state lives on the
 AreaNode, so the strip itself survives nothing and needs to survive nothing —
 a tab switch rebuilds its pane. Structural changes are not the strip's job:
 splitting, closing and merging live in the right-click context menu.
*>
struct AreaTabStrip (Widget)
{
	AreaLayout* areas; // borrowed
	AreaNode* node; // borrowed from the layout's tree
	Element* pane; // the AreaPane element: tab switches rebuild there
	int lit; // hovered tab index + 1, AREA_ZONE_NONE when the pointer is elsewhere
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
 The tab under a point, in element-local pixels, as index + 1.
*>
fn int AreaTabStrip.zone_at(&self, Element* elem, Vec2 pos)
{
	if (pos.x < 0 || pos.y < 0 || pos.y >= elem.size.y) return AREA_ZONE_NONE;

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
}

fn bool AreaTabStrip.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int zone = self.zone_at(elem, event.pos);
			if (zone > 0)
			{
				usz index = (usz)(zone - 1);
				if (self.node.active != index)
				{
					self.node.active = index;
					self.pane.request_build();
				}
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

// ---------------------------------------------------------------------------
// The context menu. AreaHost builds these while a right press has parked a
// target node on it; the rows act on that node and every action ends in a
// host rebuild, which is also what closes the menu.

<*
 What a context menu row does to the parked node. Split and close are the
 pane's entries; the merge halves are the divider's, keeping the named child
 and freeing the other side whole.
*>
enum AreaMenuAction
{
	SPLIT_SIDE, // split into left | right
	SPLIT_STACK, // split into top / bottom
	CLOSE,
	MERGE_FIRST, // keep the first child (left/top)
	MERGE_SECOND, // keep the second child (right/bottom)
}

struct AreaMenuEntry @private
{
	String label;
	AreaMenuAction action;
	bool disabled;
}

const float AREA_MENU_ROW_H = 26.0;
const float AREA_MENU_MIN_W = 140.0;

<*
 One entry in the context menu. Carries its action and target-by-way-of-host
 directly — the no-closures answer to MenuItem's context-free callbacks, the
 same reasoning as the strip's zone codes.
*>
struct AreaMenuRow (Widget)
{
	String label;
	AreaMenuAction action;
	bool disabled;
	AreaStyle style; // resolved by the host that built it
	float width;
	Element* host; // the AreaHost element
	bool hovered;
}

fn Vec2 AreaMenuRow.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (!self.disabled) elem.cursor = Cursor.POINTING_HAND;
	return cui::clamp_size({ self.width, AREA_MENU_ROW_H }, constraints);
}

fn void AreaMenuRow.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AreaStyle s = self.style;
	if (self.hovered && !self.disabled)
	{
		painter.rect({ 2, 0 }, { elem.size.x - 4, elem.size.y }, {
			.color = s.hover_color,
			.border_radius = { 4.0, 4.0, 4.0, 4.0 },
		});
	}
	Vec2 text = elem.ui.text.measure(s.font, self.label, s.text_size);
	painter.text({ s.pad_x, (elem.size.y - text.y) * 0.5f }, self.label, {
		.font = s.font,
		.size = s.text_size,
		.color = self.disabled ? s.dim_color : s.text_color,
	});
}

fn void AreaMenuRow.on_hover(&self, Element* elem, bool entered) @dynamic
{
	self.hovered = entered;
	elem.request_paint();
}

fn bool AreaMenuRow.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			// Consumed even when disabled: a dead row still must not close the
			// menu by letting the press fall through to the catcher.
			return event.button == MouseButton.LEFT;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			bool inside = event.pos.x >= 0 && event.pos.y >= 0
				&& event.pos.x < elem.size.x && event.pos.y < elem.size.y;
			if (inside && !self.disabled) self.act();
			return true;
		default:
			return false;
	}
}

<*
 Runs the row's action on the parked node, then closes the menu — one rebuild
 covers both, and it runs even when the action was a no-op (closing the root)
 so the menu never lingers past a click.
*>
fn void AreaMenuRow.act(&self)
{
	AreaHost* host = self.host.widget_as(AreaHost);
	AreaNode* node = host.menu_node;
	host.menu_node = null;
	switch (self.action)
	{
		case SPLIT_SIDE: host.areas.split_leaf(node, SplitAxis.HORIZONTAL);
		case SPLIT_STACK: host.areas.split_leaf(node, SplitAxis.VERTICAL);
		case CLOSE: host.areas.close_leaf(node);
		case MERGE_FIRST: host.areas.merge_split(node, true);
		case MERGE_SECOND: host.areas.merge_split(node, false);
	}
	self.host.request_build();
}

<*
 The click-anywhere-else-closes surface under the popup — SelectCatcher for the
 area menu. Window-sized whatever it is offered; the host's build offsets it
 back to the window origin.
*>
struct AreaMenuCatcher (Widget)
{
	Element* host; // the AreaHost element
}

fn Vec2 AreaMenuCatcher.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return elem.ui.size;
}

fn bool AreaMenuCatcher.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != MouseEventKind.PRESS && event.kind != MouseEventKind.RELEASE) return false;
	if (event.kind == MouseEventKind.PRESS)
	{
		AreaHost* host = self.host.widget_as(AreaHost);
		host.menu_node = null;
		self.host.request_build();
	}
	return true;
}
