<*
 A node editor: cards on a pannable, zoomable plane, with ports on their edges
 and wires between them.

 `@tree((NodeGraph) { .nodes = nodes, .ports = ports, .wires = wires, .on_connect = &wired })
 { foreach (i, n : nodes) @tree((NodeCard) { .node = i }) { body of node i }; };`

 **The data is the app's**, borrowed like `CurvePlot`'s: `nodes`, `ports` and
 `wires` are slices the app owns and keeps alive, and nothing here changes them.
 The graph reports what the user did through the callbacks and the app updates
 its data — moves the selected nodes, adds the wire, flips `flags.selected` —
 then calls `refresh(elem)` if it changed anything the graph did not ask for.
 Selection and undo stay with the app: a move arrives as deltas and one final
 call with `done` set, which is the app's single undo step.

 **Each node is a `NodeCard` child** naming its node by index, holding that
 node's body: any widgets — fields, sliders, a preview image. The body is laid
 out at the card's width under the header, and works at any zoom, because the
 plane is drawn through a content transform (see `Viewport2D`): a TextField on a
 card is clicked and typed into where it is drawn. Cards paint over the cards
 before them, editors included; pressing a card brings it to the front.

 **Ports** sit on the card's edges, inputs left and outputs right. A port the
 body names with a `PortRow` sits beside that row — the socket of a setting
 that can also be wired; any other port gets a labelled row of its own under
 the header, inputs and outputs side by side.

 **The pointer:**
 - drag a card to move it, with everything selected; click to select, Shift
 to add, Ctrl to toggle;
 - drag from an output to wire it; only ports `can_connect` accepts light up.
 Dragging from a wired input picks its wire up (`on_disconnect`, then the drag
 continues from the wire's source); from a free input, a wire is drawn
 backwards. A wire dropped on empty space calls `on_wire_dropped`, so the app
 can offer the nodes that would accept it;
 - drag on empty space for a selection box; click a wire to select it;
 - double-click empty space, or Space or Tab, for `on_add_request`;
 - right-click anything for `on_context`; a right or middle drag pans, the
 wheel zooms (see `Viewport2D` for trackpads).

 **Keys** while the graph has the focus (a click on it gives it): Delete,
 Ctrl+C/X/V/D/A/Z/Y arrive as `GraphCommand`s, F frames the selection (or
 everything), Esc cancels a drag in progress.
*>
module cui::widgets;
import std::math;
import std::collections::list;

import cui;

<*
 What a node shows besides its title: whether it is selected, and the states
 an app running the graph wants seen — failed, running, bypassed.
*>
struct NodeFlags
{
	bool selected;
	bool error;
	bool running;
	bool muted;
}

<*
 One node: where its card sits on the plane, and what its header says.
*>
struct GraphNode
{
	Vec2 pos; // top-left, plane units
	float width; // 0 = the style's node_width
	String title; // borrowed
	String tag; // borrowed; dim, right of the title — an id, or "cached"
	Color header; // the header band; zero alpha = the style's
	NodeFlags flags;
	float progress; // 0..1, a bar under the header while running; 0 = none
}

<*
 How a port is drawn.
*>
enum PortShape : char
{
	CIRCLE,
	SQUARE,
}

<*
 One port: which node it is on, which side, and how it looks. Wires name ports
 by index into `NodeGraph.ports`.
*>
struct GraphPort
{
	usz node;
	bool output;
	String label; // borrowed; drawn beside a port with its own row
	Color color;
	PortShape shape;
	bool hollow; // drawn as a ring — an optional input, a setting nothing feeds
}

<*
 A wire from an output port to an input port, by index into `NodeGraph.ports`.
*>
struct GraphWire
{
	usz from;
	usz to;
	Color color; // zero alpha = the source port's
	bool selected;
}

<*
 What a context click landed on.
*>
enum GraphTarget : char
{
	BACKGROUND,
	NODE,
	PORT,
	WIRE,
}

<*
 The keys a node editor shares with every editor, passed to the app to carry
 out on its own data.
*>
enum GraphCommand : char
{
	DELETE,
	COPY,
	CUT,
	PASTE,
	DUPLICATE,
	SELECT_ALL,
	UNDO,
	REDO,
}

alias OnGraphSelect = fn void(Ui* ui, sz node, SelectMode mode); // node -1 = empty space
alias OnGraphBox = fn void(Ui* ui, usz[] nodes, SelectMode mode);
alias OnGraphMove = fn void(Ui* ui, Vec2 delta, bool done);
alias CanConnect = fn bool(Ui* ui, usz from_port, usz to_port);
alias OnGraphConnect = fn void(Ui* ui, usz from_port, usz to_port);
alias OnGraphWire = fn void(Ui* ui, usz wire);
alias OnWireSelect = fn void(Ui* ui, usz wire, SelectMode mode);
alias OnWireDropped = fn void(Ui* ui, usz port, Vec2 plane, Vec2 screen);
alias OnGraphContext = fn void(Ui* ui, GraphTarget target, sz index, Vec2 plane, Vec2 screen);
alias OnGraphCommand = fn void(Ui* ui, GraphCommand command);
alias OnGraphAdd = fn void(Ui* ui, Vec2 plane, Vec2 screen);

<*
 One look for a node editor. Pass a complete style or none at all: a zero
 `node_width` means "use DEFAULT_NODE_GRAPH_STYLE wholesale".
*>
struct NodeGraphStyle
{
	ViewportStyle plane; // background and grid
	Color card;
	Color card_border;
	Color header;
	Color title;
	Color dim; // tags and port labels of hollow ports
	Color label; // port labels
	Color selected; // the border of a selected card, and selected wires
	Color error;
	Color running;
	Color box_fill;
	Color box_border;
	Color shadow;
	FontId font;
	float text_size;
	float node_width; // 0 = the whole style defaults
	float header_height;
	float row_height; // a port's own row
	float pad; // inside the card, around the body
	float radius; // card corners
	float port_radius;
	float wire_width; // on screen
	float port_reach; // screen px around a port that still picks it
}

const NodeGraphStyle DEFAULT_NODE_GRAPH_STYLE = {
	.plane = DEFAULT_VIEWPORT_STYLE,
	.card = { 0.15, 0.16, 0.20, 1.0 },
	.card_border = { 0.26, 0.28, 0.34, 1.0 },
	.header = { 0.20, 0.22, 0.28, 1.0 },
	.title = { 0.92, 0.93, 0.95, 1.0 },
	.dim = { 0.55, 0.58, 0.66, 1.0 },
	.label = { 0.80, 0.82, 0.86, 1.0 },
	.selected = { 0.95, 0.60, 0.20, 1.0 },
	.error = { 0.90, 0.30, 0.30, 1.0 },
	.running = { 0.35, 0.75, 0.45, 1.0 },
	.box_fill = { 0.95, 0.60, 0.20, 0.10 },
	.box_border = { 0.95, 0.60, 0.20, 0.80 },
	.shadow = { 0.0, 0.0, 0.0, 0.45 },
	.text_size = 13.0,
	.node_width = 220.0,
	.header_height = 26.0,
	.row_height = 22.0,
	.pad = 8.0,
	.radius = 6.0,
	.port_radius = 5.0,
	.wire_width = 2.2,
	.port_reach = 6.0,
};

fn NodeGraphStyle NodeGraphStyle.resolved(self)
{
	return self.node_width > 0 ? self : DEFAULT_NODE_GRAPH_STYLE;
}

<*
 What the pointer is doing on the graph.
*>
enum GraphGesture : char
{
	NONE,
	PAN,
	MOVE,
	WIRE,
	BOX,
	CONTEXT, // a right press that has not moved: a context click, or a pan
}

struct NodeGraph (Widget)
{
	GraphNode[] nodes; // borrowed
	GraphPort[] ports; // borrowed
	GraphWire[] wires; // borrowed
	View2D view;
	NodeGraphStyle style;
	Vec2 size; // per axis: 0 = fill

	OnGraphSelect on_select;
	OnGraphBox on_box;
	OnGraphMove on_move;
	CanConnect can_connect; // null = any output to any input on another node
	OnGraphConnect on_connect;
	OnGraphWire on_disconnect;
	OnWireSelect on_wire_select;
	OnWireDropped on_wire_dropped;
	OnGraphContext on_context;
	OnGraphCommand on_command;
	OnGraphAdd on_add_request;
	OnViewChange on_view;

	// The graph's own state: the gesture in progress, and where everything
	// was measured at the last layout.
	DragTracker drag;
	GraphGesture gesture;
	sz anchor_port; // the port a dragged wire hangs from
	sz target_port; // the acceptable port under a dragged wire's end, -1 = none
	sz pressed_node; // the card a MOVE started on
	bool select_on_click; // a press on a selected card: replace the selection only if it does not become a drag
	SelectMode press_mode;
	Vec2 pointer; // plane units
	Vec2 last_plane; // plane units, the previous move of a MOVE
	Vec2 moved; // plane units, the total of a MOVE, so Esc can put it back
	Vec2 box_start; // plane units
	bool pointer_known;
	List{Vec2} port_local; // per port: its centre, relative to its card
	List{Vec2} node_size; // per node: its card's size at the last layout
	Element* overlay;
}

<*
 Repaints and re-measures every card and the wires: call after changing the
 data in a way the graph did not ask for — nodes or ports added, a title
 renamed, a flag flipped from outside.

 @param elem : `The graph's element.`
*>
fn void NodeGraph.refresh(&self, Element* elem)
{
	foreach (child : elem.children) child.request_layout();
	elem.request_layout();
}

<*
 Repaints the cards, the wires and the overlay without re-measuring: what a
 selection change needs.

 @param elem : `The graph's element.`
*>
fn void NodeGraph.repaint(&self, Element* elem)
{
	foreach (child : elem.children) child.request_paint();
	elem.request_paint();
}

<*
 Moves the view from code, and reports it through `on_view`.

 @param elem : `The graph's element.`
 @param view : `The new view.`
*>
fn void NodeGraph.set_view(&self, Element* elem, View2D view)
{
	self.view = view;
	elem.set_content_transform(view.matrix());
	elem.request_paint();
	if (self.overlay) self.overlay.request_paint();
	if (self.on_view) self.on_view(elem.ui, view);
}

<*
 Frames the selected nodes, or every node when none is selected.

 @param elem : `The graph's element.`
 @param margin : `Screen pixels left around them.`
*>
fn void NodeGraph.frame(&self, Element* elem, float margin = 40)
{
	bool any_selected;
	foreach (n : self.nodes) if (n.flags.selected) any_selected = true;
	float big = (float)math::FLOAT_MAX;
	Vec4 box = { big, big, -big, -big };
	bool found;
	foreach (i, n : self.nodes)
	{
		if (any_selected && !n.flags.selected) continue;
		Vec2 size = self.card_size((usz)i);
		box = { math::min(box.x, n.pos.x), math::min(box.y, n.pos.y),
			math::max(box.z, n.pos.x + size.x), math::max(box.w, n.pos.y + size.y) };
		found = true;
	}
	if (!found) return;
	View2D view = self.view;
	view.frame(box, elem.size, margin, 1.2f);
	self.set_view(elem, view);
}

<*
 A node's card size at the last layout: its width, and a header's height
 before it has been measured.
*>
fn Vec2 NodeGraph.card_size(&self, usz node)
{
	if ((sz)node < self.node_size.len()) return self.node_size[(sz)node];
	NodeGraphStyle s = self.style.resolved();
	return { self.node_width(node, s), s.header_height };
}

fn float NodeGraph.node_width(&self, usz node, NodeGraphStyle s)
{
	float w = self.nodes[node].width;
	return w > 0 ? w : s.node_width;
}

<*
 Where a port's centre is on the plane, from the last layout.
*>
fn Vec2 NodeGraph.port_pos(&self, usz port)
{
	GraphPort p = self.ports[port];
	Vec2 local = (sz)port < self.port_local.len() ? self.port_local[(sz)port] : (Vec2) { 0, 0 };
	return self.nodes[p.node].pos + local;
}

<*
 The colour a port and the wires from it are drawn in.
*>
fn Color NodeGraph.wire_color(&self, GraphWire wire)
{
	return ((Vec4)wire.color).w > 0 ? wire.color : self.ports[wire.from].color;
}

<*
 Whether a wire may run from one port to another, in either order of
 picking: the app's `can_connect` with the output first, or by default any
 output to any input of another node.
*>
fn bool NodeGraph.fits(&self, Ui* ui, usz a, usz b)
{
	GraphPort pa = self.ports[a];
	GraphPort pb = self.ports[b];
	if (pa.output == pb.output) return false;
	usz from = pa.output ? a : b;
	usz to = pa.output ? b : a;
	if (self.can_connect) return self.can_connect(ui, from, to);
	return self.ports[from].node != self.ports[to].node;
}

fn void NodeGraph.mount(&self, Element* elem) @dynamic
{
	self.anchor_port = -1;
	self.target_port = -1;
	self.pressed_node = -1;
	self.port_local.init(mem, 0);
	self.node_size.init(mem, 0);
	// The overlay — the wire being dragged, the selection box — is a child of
	// the graph so it rides the content transform, and the last one so it
	// paints over every card.
	self.overlay = elem.ui.@node((NodeGraphOverlay) { .graph = elem });
	elem.append(self.overlay);
}

fn void NodeGraph.unmount(&self, Element* elem) @dynamic
{
	self.port_local.free();
	self.node_size.free();
	self.overlay = null;
}

fn Vec2 NodeGraph.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.clips = true;
	Vec2 own = constraints.fill(self.size);

	// The tables are sized here and filled by the cards' own layouts; a change
	// in how many nodes or ports there are re-measures every card, since
	// their cached answers were for different data.
	bool reshaped = self.port_local.len() != (sz)self.ports.len || self.node_size.len() != (sz)self.nodes.len;
	if (reshaped)
	{
		self.port_local.clear();
		for (usz i = 0; i < self.ports.len; i++) self.port_local.push({ 0, 0 });
		self.node_size.clear();
		for (usz i = 0; i < self.nodes.len; i++) self.node_size.push({ 0, 0 });
	}

	// The overlay stays last whatever was appended after it.
	if (self.overlay && elem.children.len() > 0 && elem.children[elem.children.len() - 1] != self.overlay)
	{
		foreach (i, child : elem.children)
		{
			if (child == self.overlay)
			{
				elem.move_child((sz)i, elem.children.len() - 1);
				break;
			}
		}
	}

	foreach (i, child : elem.children)
	{
		if (child.is_widget(NodeCard))
		{
			NodeCard* card = child.widget_as(NodeCard);
			if (card.node >= self.nodes.len)
			{
				elem.layout_child((sz)i, cui::tight({ 0, 0 }));
				continue;
			}
			if (reshaped) child.dirty.layout = true;
			Vec2 size = elem.layout_child((sz)i, cui::loose({ cui::UNBOUNDED, cui::UNBOUNDED }));
			self.node_size[(sz)card.node] = size;
			elem.place_child((sz)i, self.nodes[card.node].pos);
		}
		else
		{
			elem.layout_child((sz)i, cui::tight({ 0, 0 }));
			elem.place_child((sz)i, { 0, 0 });
		}
	}
	elem.set_content_transform(self.view.matrix());
	// The wires follow the cards; they are painted here, under them.
	elem.request_paint();
	return own;
}

<*
 The plane behind everything, and the wires under the cards — in screen
 space, through the view, so they keep their width at any zoom.
*>
fn void NodeGraph.paint(&self, Element* elem, Painter* painter) @dynamic
{
	NodeGraphStyle s = self.style.resolved();
	paint_plane_grid(painter, elem.size, self.view, s.plane.resolved());
	float z = self.view.scale();
	float width = s.wire_width * math::clamp(z, 0.6f, 1.5f);
	foreach (w : self.wires)
	{
		if (w.from >= self.ports.len || w.to >= self.ports.len) continue;
		Vec2 a = self.view.to_screen(self.port_pos(w.from));
		Vec2 b = self.view.to_screen(self.port_pos(w.to));
		Color color = self.wire_color(w);
		if (w.selected)
		{
			paint_wire(painter, a, b, z, width + 3, s.selected);
		}
		paint_wire(painter, a, b, z, width, color);
	}
}

<*
 A wire between two screen points, leaving and entering horizontally: the
 controls reach half the distance across, and at least 40 plane units, so a
 wire doubling back loops instead of folding.
*>
fn void paint_wire(Painter* painter, Vec2 a, Vec2 b, float zoom, float width, Color color, float dash = 0)
{
	float dx = math::max(40 * zoom, math::abs(b.x - a.x) * 0.5f);
	painter.bezier(a, { a.x + dx, a.y }, { b.x - dx, b.y }, b, width, color, dash);
}

<*
 How far a screen point is from a wire, in screen pixels.
*>
fn float NodeGraph.wire_distance(&self, usz wire, Vec2 screen)
{
	GraphWire w = self.wires[wire];
	Vec2 a = self.view.to_screen(self.port_pos(w.from));
	Vec2 b = self.view.to_screen(self.port_pos(w.to));
	float dx = math::max(40 * self.view.scale(), math::abs(b.x - a.x) * 0.5f);
	return cui::bezier_distance(screen, a, { a.x + dx, a.y }, { b.x - dx, b.y }, b);
}

// ---------------------------------------------------------------------------
// Hit testing, all from the last layout's measurements

<*
 The port under a point in the graph's screen pixels, on the topmost card that
 has one there; -1 when none is within reach.
*>
fn sz NodeGraph.port_at(&self, Element* elem, Vec2 screen)
{
	NodeGraphStyle s = self.style.resolved();
	float z = self.view.scale();
	float reach = s.port_radius * z + s.port_reach;
	foreach_r (child : elem.children)
	{
		if (!child.is_widget(NodeCard)) continue;
		usz node = child.widget_as(NodeCard).node;
		sz best = -1;
		float best_d = reach;
		foreach (i, p : self.ports)
		{
			if (p.node != node) continue;
			float d = (self.view.to_screen(self.port_pos((usz)i)) - screen).length();
			if (d <= best_d)
			{
				best_d = d;
				best = (sz)i;
			}
		}
		if (best >= 0) return best;
	}
	return -1;
}

<*
 The topmost card under a point in the graph's screen pixels, or -1.
*>
fn sz NodeGraph.node_at(&self, Element* elem, Vec2 screen)
{
	Vec2 p = self.view.to_plane(screen);
	foreach_r (child : elem.children)
	{
		if (!child.is_widget(NodeCard)) continue;
		usz node = child.widget_as(NodeCard).node;
		if (node >= self.nodes.len) continue;
		Vec2 at = self.nodes[node].pos;
		Vec2 size = self.card_size(node);
		if (p.x >= at.x && p.y >= at.y && p.x < at.x + size.x && p.y < at.y + size.y) return (sz)node;
	}
	return -1;
}

<*
 The nearest wire within a few pixels of a point in the graph's screen pixels,
 or -1.
*>
fn sz NodeGraph.wire_at(&self, Vec2 screen)
{
	sz best = -1;
	float best_d = 6;
	foreach (i, w : self.wires)
	{
		if (w.from >= self.ports.len || w.to >= self.ports.len) continue;
		float d = self.wire_distance((usz)i, screen);
		if (d < best_d)
		{
			best_d = d;
			best = (sz)i;
		}
	}
	return best;
}

<*
 The card element showing a node, or null.
*>
fn Element* NodeGraph.card_of(&self, Element* elem, usz node)
{
	foreach (child : elem.children)
	{
		if (child.is_widget(NodeCard) && child.widget_as(NodeCard).node == node) return child;
	}
	return null;
}

// ---------------------------------------------------------------------------
// The pointer

fn bool NodeGraph.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	Vec2 screen = event.pos; // the graph's own pixels: its transform moves only the cards
	Vec2 plane = self.view.to_plane(screen);
	switch (event.kind)
	{
		case SCROLL:
			View2D view = self.view;
			if (event.scroll_precise && !event.mods.ctrl)
			{
				view.pan_by({ -event.scroll_x, event.scroll });
			}
			else
			{
				if (event.scroll == 0) return true;
				view.zoom_at(screen, cui::wheel_zoom_factor(event.scroll, event.scroll_precise));
			}
			self.set_view(elem, view);
			return true;
		case PRESS:
			return self.press(elem, event, screen, plane);
		case MOVE:
			return self.move(elem, event, screen, plane);
		case RELEASE:
			return self.release(elem, event, screen, plane);
	}
}

fn bool NodeGraph.press(&self, Element* elem, MouseEvent event, Vec2 screen, Vec2 plane)
{
	if (self.gesture != GraphGesture.NONE) return true;
	self.drag.press(screen, event.button);
	self.pointer = plane;
	if (event.button == MouseButton.MIDDLE)
	{
		self.gesture = PAN;
		return true;
	}
	if (event.button == MouseButton.RIGHT)
	{
		self.gesture = CONTEXT;
		return true;
	}

	SelectMode mode = cui::select_mode(event.mods);
	sz port = self.port_at(elem, screen);
	if (port >= 0)
	{
		self.gesture = WIRE;
		self.anchor_port = port;
		if (!self.ports[port].output)
		{
			// A wired input: take its wire off and carry it from its source.
			sz taken = -1;
			foreach (i, w : self.wires) if (w.to == (usz)port) taken = (sz)i;
			if (taken >= 0)
			{
				self.anchor_port = (sz)self.wires[taken].from;
				if (self.on_disconnect) self.on_disconnect(elem.ui, (usz)taken);
				elem.request_paint();
			}
		}
		self.target_port = -1;
		self.overlay.request_paint();
		return true;
	}

	sz node = self.node_at(elem, screen);
	if (node >= 0)
	{
		self.gesture = MOVE;
		self.pressed_node = node;
		self.last_plane = plane;
		self.moved = { 0, 0 };
		self.press_mode = mode;
		Element* card = self.card_of(elem, (usz)node);
		if (card) card.bring_to_front();
		// A press on a card already in the selection keeps the selection, so
		// the whole of it can be dragged; a click that does not drag narrows it
		// to this card on release.
		self.select_on_click = self.nodes[node].flags.selected && mode == SelectMode.REPLACE;
		if (!self.select_on_click)
		{
			if (self.on_select) self.on_select(elem.ui, node, mode);
			self.repaint(elem);
		}
		// Toggling a card is not the start of moving it.
		if (mode == SelectMode.TOGGLE)
		{
			self.gesture = GraphGesture.NONE;
			self.drag.cancel();
		}
		return true;
	}

	sz wire = self.wire_at(screen);
	if (wire >= 0)
	{
		if (self.on_wire_select) self.on_wire_select(elem.ui, (usz)wire, mode);
		elem.request_paint();
		self.drag.cancel();
		return true;
	}

	if (event.clicks >= 2)
	{
		self.drag.cancel();
		if (self.on_add_request) self.on_add_request(elem.ui, plane, event.absolute);
		return true;
	}
	self.gesture = BOX;
	self.box_start = plane;
	self.press_mode = mode;
	return true;
}

fn bool NodeGraph.move(&self, Element* elem, MouseEvent event, Vec2 screen, Vec2 plane)
{
	self.pointer = plane;
	self.pointer_known = true;
	if (self.gesture == GraphGesture.NONE)
	{
		elem.set_cursor(self.port_at(elem, screen) >= 0 ? Cursor.CROSSHAIR : Cursor.DEFAULT);
		return false;
	}
	Vec2 before = self.drag.last;
	bool started = self.drag.move(screen);
	switch (self.gesture)
	{
		case PAN:
		case CONTEXT:
			if (!self.drag.dragging()) return true;
			self.gesture = PAN;
			View2D view = self.view;
			view.pan_by(started ? screen - self.drag.start : screen - before);
			self.set_view(elem, view);
			elem.set_cursor(Cursor.CLOSED_HAND);
		case MOVE:
			if (!self.drag.dragging()) return true;
			if (started && self.select_on_click)
			{
				// It is a drag of the selection after all; nothing to narrow.
				self.select_on_click = false;
			}
			Vec2 delta = plane - self.last_plane;
			self.last_plane = plane;
			if (started) delta = plane - self.view.to_plane(self.drag.start);
			self.moved += delta;
			if (self.on_move) self.on_move(elem.ui, delta, false);
			elem.request_layout();
		case WIRE:
			sz port = self.port_at(elem, screen);
			sz target = port >= 0 && port != self.anchor_port && self.fits(elem.ui, (usz)self.anchor_port, (usz)port) ? port : -1;
			self.target_port = target;
			self.overlay.request_paint();
		case BOX:
			self.overlay.request_paint();
		case NONE:
			break;
	}
	return true;
}

fn bool NodeGraph.release(&self, Element* elem, MouseEvent event, Vec2 screen, Vec2 plane)
{
	if (self.gesture == GraphGesture.NONE || event.button != self.drag.button)
	{
		return self.gesture != GraphGesture.NONE;
	}
	GraphGesture gesture = self.gesture;
	DragState was = self.drag.release();
	self.gesture = NONE;
	elem.set_cursor(Cursor.DEFAULT);
	switch (gesture)
	{
		case CONTEXT:
			if (self.on_context)
			{
				GraphTarget target = BACKGROUND;
				sz index = -1;
				sz port = self.port_at(elem, screen);
				sz node = port >= 0 ? -1 : self.node_at(elem, screen);
				sz wire = port >= 0 || node >= 0 ? -1 : self.wire_at(screen);
				switch
				{
					case port >= 0:
						target = PORT;
						index = port;
					case node >= 0:
						target = NODE;
						index = node;
					case wire >= 0:
						target = WIRE;
						index = wire;
				}
				self.on_context(elem.ui, target, index, plane, event.absolute);
			}
		case MOVE:
			if (was == DragState.DRAGGING)
			{
				if (self.on_move) self.on_move(elem.ui, { 0, 0 }, true);
			}
			else if (self.select_on_click)
			{
				if (self.on_select) self.on_select(elem.ui, self.pressed_node, REPLACE);
				self.repaint(elem);
			}
		case WIRE:
			sz port = self.port_at(elem, screen);
			if (port >= 0 && port != self.anchor_port && self.fits(elem.ui, (usz)self.anchor_port, (usz)port))
			{
				usz a = (usz)self.anchor_port;
				usz b = (usz)port;
				bool forward = self.ports[a].output;
				if (self.on_connect) self.on_connect(elem.ui, forward ? a : b, forward ? b : a);
			}
			else if (port < 0 && self.node_at(elem, screen) < 0 && was == DragState.DRAGGING)
			{
				if (self.on_wire_dropped) self.on_wire_dropped(elem.ui, (usz)self.anchor_port, plane, event.absolute);
			}
			self.anchor_port = -1;
			self.target_port = -1;
			elem.request_paint();
			self.repaint(elem);
		case BOX:
			if (was == DragState.DRAGGING)
			{
				Vec4 box = cui::box_between(self.box_start, plane);
				@pool()
				{
					List{usz} hits;
					hits.init(tmem);
					foreach (i, n : self.nodes)
					{
						Vec2 size = self.card_size((usz)i);
						if (cui::boxes_overlap(box, { n.pos.x, n.pos.y, n.pos.x + size.x, n.pos.y + size.y })) hits.push((usz)i);
					}
					if (self.on_box) self.on_box(elem.ui, hits.array_view(), self.press_mode);
				};
			}
			else if (self.on_select)
			{
				self.on_select(elem.ui, -1, self.press_mode);
			}
			self.repaint(elem);
		case PAN:
		case NONE:
			break;
	}
	self.pressed_node = -1;
	self.select_on_click = false;
	self.overlay.request_paint();
	return true;
}

fn bool NodeGraph.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	Modifiers mods = elem.ui.input.modifiers();
	bool cmd = mods.ctrl || mods.super;
	switch (event.key)
	{
		case Key.ESCAPE:
			return self.cancel(elem);
		case Key.DELETE:
		case Key.BACKSPACE:
			return self.command(elem, DELETE);
		case Key.F:
			if (cmd) return false;
			self.frame(elem);
			return true;
		case Key.SPACE:
		case Key.TAB:
			if (!self.on_add_request) return false;
			Vec2 plane = self.pointer_known ? self.pointer : self.view.to_plane(elem.size * 0.5f);
			self.on_add_request(elem.ui, plane, elem.to_screen(self.view.to_screen(plane)));
			return true;
		case Key.C: if (cmd) return self.command(elem, COPY);
		case Key.X: if (cmd) return self.command(elem, CUT);
		case Key.V: if (cmd) return self.command(elem, PASTE);
		case Key.D: if (cmd) return self.command(elem, DUPLICATE);
		case Key.A: if (cmd) return self.command(elem, SELECT_ALL);
		case Key.Z: if (cmd) return self.command(elem, mods.shift ? REDO : UNDO);
		case Key.Y: if (cmd) return self.command(elem, REDO);
		default: break;
	}
	return false;
}

fn bool NodeGraph.command(&self, Element* elem, GraphCommand command)
{
	if (!self.on_command) return false;
	self.on_command(elem.ui, command);
	self.refresh(elem);
	return true;
}

<*
 Esc: abandons the gesture in progress. A move is put back where it started;
 a wire being dragged is dropped.

 @return `True when there was something to cancel.`
*>
fn bool NodeGraph.cancel(&self, Element* elem)
{
	if (self.gesture == GraphGesture.NONE) return false;
	if (self.gesture == GraphGesture.MOVE && self.drag.dragging() && self.on_move)
	{
		self.on_move(elem.ui, -self.moved, true);
		elem.request_layout();
	}
	self.drag.cancel();
	self.gesture = NONE;
	self.anchor_port = -1;
	self.target_port = -1;
	elem.set_cursor(Cursor.DEFAULT);
	self.overlay.request_paint();
	elem.request_paint();
	return true;
}

// ---------------------------------------------------------------------------
// NodeCard

<*
 One node's card in a `NodeGraph`: frame, header and ports, around the node's
 body — its single child, if it has one. Must be a direct child of the graph.
*>
struct NodeCard (Widget)
{
	usz node;
}

fn NodeGraph* NodeCard.graph(&self, Element* elem) @inline
{
	return elem.parent.widget_as(NodeGraph);
}

<*
 Lays the body out under the header and the ports' own rows, then measures
 where every port of the node sits — beside the `PortRow` that names it, or in
 a row of its own — for the graph to read.
*>
fn Vec2 NodeCard.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	NodeGraph* g = self.graph(elem);
	NodeGraphStyle s = g.style.resolved();
	float w = g.node_width(self.node, s);

	float body_y = s.header_height + s.pad * 0.5f;
	float body_h = 0;
	if (elem.children.len() > 0)
	{
		Vec2 body = elem.layout_child(0, cui::loose({ w - 2 * s.pad, cui::UNBOUNDED }));
		body_h = body.y;
	}

	// Ports with their own rows: inputs down the left, outputs down the right,
	// side by side, above the body.
	int ins;
	int outs;
	foreach (i, p : g.ports)
	{
		if (p.node != self.node || (sz)i >= g.port_local.len()) continue;
		if (port_row_y(elem, (usz)i) >= 0) continue;
		float row = (float)(p.output ? outs++ : ins++);
		g.port_local[i] = { p.output ? w : 0, body_y + row * s.row_height + s.row_height * 0.5f };
	}
	float rows_h = (float)math::max(ins, outs) * s.row_height;
	if (elem.children.len() > 0) elem.place_child(0, { s.pad, body_y + rows_h });

	// Ports beside body rows, now the body sits where it will be drawn.
	foreach (i, p : g.ports)
	{
		if (p.node != self.node || (sz)i >= g.port_local.len()) continue;
		float y = port_row_y(elem, (usz)i);
		if (y >= 0) g.port_local[i] = { p.output ? w : 0, y };
	}

	float h = body_y + rows_h + body_h + (body_h > 0 || rows_h > 0 ? s.pad : s.pad * 0.5f);
	return { w, h };
}

<*
 The centre y, relative to the card, of the `PortRow` in its body naming a
 port, or -1 when there is none. Reads the offsets of the last layout.
*>
fn float port_row_y(Element* card, usz port)
{
	if (card.children.len() == 0) return -1;
	return find_port_row(card.children[0], card.children[0].offset, port);
}

fn float find_port_row(Element* elem, Vec2 origin, usz port) @local
{
	if (elem.is_widget(PortRow) && elem.widget_as(PortRow).port == port) return origin.y + elem.size.y * 0.5f;
	foreach (child : elem.children)
	{
		float y = find_port_row(child, origin + child.offset, port);
		if (y >= 0) return y;
	}
	return -1;
}

fn void NodeCard.paint(&self, Element* elem, Painter* painter) @dynamic
{
	NodeGraph* g = self.graph(elem);
	if (self.node >= g.nodes.len) return;
	NodeGraphStyle s = g.style.resolved();
	GraphNode n = g.nodes[self.node];
	Vec2 size = elem.size;
	float r = s.radius;

	// The state is the border; the selection is a ring outside it, so a
	// running or failed node still shows that it is selected.
	Color border = s.card_border;
	float border_w = 1;
	switch
	{
		case n.flags.error:
			border = s.error;
			border_w = 2;
		case n.flags.running:
			border = s.running;
			border_w = 2;
		case n.flags.selected:
			border = s.selected;
			border_w = 2;
	}
	painter.rect_shadow({ 0, 3 }, size, 10, s.shadow, { r, r, r, r });
	if (n.flags.selected && (n.flags.error || n.flags.running))
	{
		float ring = r + 3;
		painter.rect({ -3, -3 }, size + (Vec2) { 6, 6 },
			{ .color = { 0, 0, 0, 0 }, .border_color = s.selected, .border_width = 2, .border_radius = { ring, ring, ring, ring } });
	}
	Color card = n.flags.muted ? ((Color)s.card).dim(0.7f) : s.card;
	painter.rect({ 0, 0 }, size, { .color = card, .border_color = border, .border_width = border_w, .border_radius = { r, r, r, r } });
	Color header = ((Vec4)n.header).w > 0 ? n.header : s.header;
	painter.rect({ border_w, border_w }, { size.x - 2 * border_w, s.header_height - border_w },
		{ .color = header, .border_radius = { r - 1, r - 1, 0, 0 } });

	float tag_w = 0;
	if (n.tag.len > 0)
	{
		Vec2 m = elem.ui.text.measure(s.font, n.tag, s.text_size - 2);
		tag_w = m.x + s.pad;
		painter.text({ size.x - s.pad - m.x, (s.header_height - m.y) * 0.5f }, n.tag,
			{ .font = s.font, .size = s.text_size - 2, .color = s.dim });
	}
	Vec2 tm = elem.ui.text.measure(s.font, "Mg", s.text_size);
	painter.text_box({ s.pad, (s.header_height - tm.y) * 0.5f }, n.title,
		{ .font = s.font, .size = s.text_size, .color = s.title }, size.x - 2 * s.pad - tag_w, ELLIPSIS);

	if (n.flags.running && n.progress > 0)
	{
		float p = math::clamp(n.progress, 0.0f, 1.0f);
		painter.rect({ border_w, s.header_height - 3 }, { (size.x - 2 * border_w) * p, 3 }, { .color = s.running });
	}

	// The ports, and the labels of those with rows of their own.
	foreach (i, p : g.ports)
	{
		if (p.node != self.node || (sz)i >= g.port_local.len()) continue;
		Vec2 at = g.port_local[i];
		paint_port(painter, at, s.port_radius, p);
		if (p.label.len == 0 || port_row_y(elem, (usz)i) >= 0) continue;
		Vec2 m = elem.ui.text.measure(s.font, p.label, s.text_size - 1);
		float x = p.output ? at.x - s.port_radius - 6 - m.x : at.x + s.port_radius + 6;
		painter.text({ x, at.y - m.y * 0.5f }, p.label,
			{ .font = s.font, .size = s.text_size - 1, .color = p.hollow ? s.dim : s.label });
	}
}

<*
 One port: a dot or a square in its colour, or a ring when hollow.
*>
fn void paint_port(Painter* painter, Vec2 at, float radius, GraphPort p)
{
	Color clear = { 0, 0, 0, 0 };
	Color fill = p.hollow ? clear : p.color;
	if (p.shape == PortShape.SQUARE)
	{
		painter.rect(at - (Vec2) { radius, radius }, { 2 * radius, 2 * radius },
			{ .color = fill, .border_color = p.color, .border_width = 1.5f, .border_radius = { 1, 1, 1, 1 } });
		return;
	}
	painter.circle(at, radius, { .color = fill, .border_color = p.color, .border_width = 1.5f });
}

// ---------------------------------------------------------------------------
// PortRow

<*
 Marks a row of a node's body as the place of a port: the graph draws that
 port on the card's edge level with this row. Wraps one child and is otherwise
 invisible — `@tree((PortRow) { .port = 7 }) { @node((Slider) { ... }); };`.
*>
struct PortRow (Widget)
{
	usz port; // index into NodeGraph.ports
}

fn Vec2 PortRow.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, 0 });
	Vec2 child = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return child;
}

// ---------------------------------------------------------------------------
// The overlay

<*
 What paints over the cards: the wire being dragged, a ring on the port it
 would land on, and the selection box. Internal; the graph's last child, in
 plane units like the cards.
*>
struct NodeGraphOverlay (Widget)
{
	Element* graph;
}

fn Vec2 NodeGraphOverlay.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	elem.ignores_pointer = true;
	return { 0, 0 };
}

fn void NodeGraphOverlay.paint(&self, Element* elem, Painter* painter) @dynamic
{
	NodeGraph* g = self.graph.widget_as(NodeGraph);
	NodeGraphStyle s = g.style.resolved();
	float z = g.view.scale();
	// Plane units, so a screen-sized stroke is divided by the zoom.
	float px = 1 / z;
	if (g.gesture == GraphGesture.WIRE && g.anchor_port >= 0 && g.drag.dragging())
	{
		GraphPort anchor = g.ports[g.anchor_port];
		Vec2 from = g.port_pos((usz)g.anchor_port);
		Vec2 to = g.target_port >= 0 ? g.port_pos((usz)g.target_port) : g.pointer;
		Vec2 a = anchor.output ? from : to;
		Vec2 b = anchor.output ? to : from;
		float width = s.wire_width * math::clamp(z, 0.6f, 1.5f) * px;
		float dx = math::max(40.0f, math::abs(b.x - a.x) * 0.5f);
		painter.bezier(a, { a.x + dx, a.y }, { b.x - dx, b.y }, b, width, anchor.color,
			g.target_port >= 0 ? 0 : 8 * px);
		if (g.target_port >= 0)
		{
			painter.circle(g.port_pos((usz)g.target_port), s.port_radius + 3 * px,
				{ .color = { 0, 0, 0, 0 }, .border_color = s.selected, .border_width = 2 * px });
		}
	}
	if (g.gesture == GraphGesture.BOX && g.drag.dragging())
	{
		Vec4 box = cui::box_between(g.box_start, g.pointer);
		painter.rect({ box.x, box.y }, { box.z - box.x, box.w - box.y },
			{ .color = s.box_fill, .border_color = s.box_border, .border_width = px });
	}
}
