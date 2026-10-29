// NodeGraph: cards placed on the plane with their ports measured, and the
// gestures — select, move as one undo step, wire, refuse, pick a wire up, box
// select, select a wire — reported through the callbacks while the data stays
// the app's.
module cui_tests::node_graphs;
import cui;
import cui::widgets;
import cui_tests;
import std::math;
import std::core::test;

// Two nodes: A has an output with a row of its own; B has an input with a row
// of its own and a second input beside a row of its body.
GraphNode[2] g_nodes;
GraphPort[3] g_ports;
GraphWire[1] g_wires;
usz g_wire_count;

sz selected_node = -2;
SelectMode selected_mode;
int moves;
bool move_done;
sz connect_from = -1;
sz connect_to = -1;
sz disconnected = -1;
sz wire_selected = -1;
usz[4] boxed;
usz boxed_count;
bool refuse;
sz dropped_port = -1;
EventRecord body_rec;

fn void reset()
{
	g_nodes = {
		{ .pos = { 0, 0 }, .title = "A" },
		{ .pos = { 300, 0 }, .title = "B" },
	};
	g_ports = {
		{ .node = 0, .output = true, .label = "out", .color = { 1, 0.5, 0, 1 } },
		{ .node = 1, .label = "in", .color = { 1, 0.5, 0, 1 } },
		{ .node = 1, .label = "seed", .color = { 0, 0.5, 1, 1 } },
	};
	g_wire_count = 0;
	selected_node = -2;
	moves = 0;
	move_done = false;
	connect_from = connect_to = disconnected = wire_selected = dropped_port = -1;
	boxed_count = 0;
	refuse = false;
	body_rec = { };
}

fn void on_select(Ui* ui, sz node, SelectMode mode)
{
	selected_node = node;
	selected_mode = mode;
	if (mode == SelectMode.REPLACE) foreach (&n : g_nodes) n.flags.selected = false;
	if (node >= 0) g_nodes[node].flags.selected = mode == SelectMode.TOGGLE ? !g_nodes[node].flags.selected : true;
}

fn void on_move(Ui* ui, Vec2 delta, bool done)
{
	moves++;
	move_done = done;
	foreach (&n : g_nodes) if (n.flags.selected) n.pos += delta;
}

fn bool can_connect(Ui* ui, usz from, usz to) => !refuse;
fn void on_connect(Ui* ui, usz from, usz to)
{
	connect_from = (sz)from;
	connect_to = (sz)to;
}
fn void on_disconnect(Ui* ui, usz wire)
{
	disconnected = (sz)wire;
	g_wire_count = 0;
}
fn void on_wire_select(Ui* ui, usz wire, SelectMode mode) => wire_selected = (sz)wire;
fn void on_box(Ui* ui, usz[] nodes, SelectMode mode)
{
	boxed_count = nodes.len;
	foreach (i, n : nodes) if (i < 4) boxed[i] = n;
}
fn void on_wire_dropped(Ui* ui, usz port, Vec2 plane, Vec2 screen) => dropped_port = (sz)port;

fn Element* build_graph(Ui* ui, View2D view = { })
{
	reset();
	Element* graph = ui.@node((NodeGraph) {
		.nodes = &g_nodes,
		.ports = &g_ports,
		.wires = g_wires[:g_wire_count],
		.view = view,
		.on_select = &on_select,
		.on_move = &on_move,
		.can_connect = &can_connect,
		.on_connect = &on_connect,
		.on_disconnect = &on_disconnect,
		.on_wire_select = &on_wire_select,
		.on_box = &on_box,
		.on_wire_dropped = &on_wire_dropped,
	},
		ui.@node((NodeCard) { .node = 0 }),
		ui.@node((NodeCard) { .node = 1 },
			ui.@node((PortRow) { .port = 2 }, ui.@node((EventProbe) { .pref = { 100, 20 }, .rec = &body_rec }))));
	ui.build(graph);
	ui.flush();
	return graph;
}

fn void set_wires(Element* graph)
{
	graph.widget_as(NodeGraph).wires = g_wires[:g_wire_count];
	graph.request_paint();
}

macro void drag(Ui* ui, Vec2 from, Vec2 to, Key[] keys = { })
{
	cui_tests::frame(ui, from, keys: keys);
	cui_tests::frame(ui, from, left: true, keys: keys);
	cui_tests::frame(ui, (from + to) * 0.5f, left: true, keys: keys);
	cui_tests::frame(ui, to, left: true, keys: keys);
	cui_tests::frame(ui, to, keys: keys);
	ui.flush();
}

// Header 26 + half a pad 4 = 30 down to the rows; a port row is 22.
fn void cards_measure_their_ports() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	Element* graph = build_graph(ui);
	NodeGraph* g = graph.widget_as(NodeGraph);

	cui_tests::eq_vec2(g.port_pos(0), { 220, 41 }); // A's output, right edge
	cui_tests::eq_vec2(g.port_pos(1), { 300, 41 }); // B's own-row input
	// B's body sits below its one port row, at 30 + 22 = 52; the PortRow is 20
	// tall, so the seed port is level with its middle.
	cui_tests::eq_vec2(g.port_pos(2), { 300, 62 });
	cui_tests::eq_vec2(g.card_size(0), { 220, 60 });
	cui_tests::eq_vec2(g.card_size(1), { 220, 80 });
}

fn void dragging_a_card_selects_and_moves_it_as_one_step() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	Element* graph = build_graph(ui);

	drag(ui, { 50, 10 }, { 90, 30 });
	test::eq(selected_node, (sz)0);
	test::eq(selected_mode, SelectMode.REPLACE);
	test::eq(move_done, true);
	test::eq(moves >= 2, true);
	cui_tests::eq_vec2(g_nodes[0].pos, { 40, 20 });
	// The card followed, after the graph re-laid it out.
	Element* card = graph.widget_as(NodeGraph).card_of(graph, 0);
	cui_tests::eq_vec2(card.offset, { 40, 20 });
	// And it came to the front, keeping its element.
	test::eq(graph.children[graph.children.len() - 2] == card, true);
}

fn void a_wire_runs_from_output_to_input() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	build_graph(ui);

	drag(ui, { 220, 41 }, { 301, 41 });
	test::eq(connect_from, (sz)0);
	test::eq(connect_to, (sz)1);

	// Drawn backwards from a free input, it still reports output first.
	connect_from = connect_to = -1;
	drag(ui, { 300, 62 }, { 221, 41 });
	test::eq(connect_from, (sz)0);
	test::eq(connect_to, (sz)2);
}

fn void a_refused_wire_connects_nothing_and_a_dropped_one_says_so() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	build_graph(ui);

	refuse = true;
	drag(ui, { 220, 41 }, { 300, 41 });
	test::eq(connect_from, (sz)-1);

	refuse = false;
	drag(ui, { 220, 41 }, { 600, 300 });
	test::eq(connect_from, (sz)-1);
	test::eq(dropped_port, (sz)0);
}

fn void a_wired_input_hands_its_wire_over() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	Element* graph = build_graph(ui);
	g_wires[0] = { .from = 0, .to = 1 };
	g_wire_count = 1;
	set_wires(graph);
	ui.flush();

	// Pick the wire up at B's input and drop it on the seed port.
	drag(ui, { 300, 41 }, { 300, 62 });
	test::eq(disconnected, (sz)0);
	test::eq(connect_from, (sz)0);
	test::eq(connect_to, (sz)2);
}

fn void a_box_selects_what_it_touches() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	build_graph(ui);

	drag(ui, { 250, 200 }, { 320, 50 });
	test::eq(boxed_count, (usz)1);
	test::eq(boxed[0], (usz)1);

	drag(ui, { 600, 300 }, { 10, 10 });
	test::eq(boxed_count, (usz)2);
}

fn void a_click_on_a_wire_selects_it_and_on_nothing_clears() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	Element* graph = build_graph(ui);
	g_wires[0] = { .from = 0, .to = 1 };
	g_wire_count = 1;
	set_wires(graph);
	ui.flush();

	cui_tests::frame(ui, { 260, 41 }, left: true);
	cui_tests::frame(ui, { 260, 41 });
	test::eq(wire_selected, (sz)0);

	cui_tests::frame(ui, { 600, 300 }, left: true);
	cui_tests::frame(ui, { 600, 300 });
	test::eq(selected_node, (sz)-1);
}

fn void the_body_takes_its_own_events() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	build_graph(ui);
	body_rec.consume_mouse = true;

	// B's body probe: card at {300, 0}, body at {8, 52}.
	cui_tests::frame(ui, { 320, 60 }, left: true);
	cui_tests::frame(ui, { 320, 60 });
	test::eq(body_rec.presses, 1);
	test::eq(selected_node, (sz)-2);
}

// Zoomed 2x and panned, a card is picked where it is drawn and a move arrives
// in plane units.
fn void a_zoomed_graph_is_used_where_it_is_drawn() @test
{
	Ui* ui = cui::new_ui({ 800, 400 });
	defer ui.free();
	build_graph(ui, { .pan = { -10, -10 }, .zoom = 2 });

	// A's header at plane {50, 10} is on screen at ({50, 10} + 10) * 2.
	drag(ui, { 120, 40 }, { 160, 40 });
	test::eq(selected_node, (sz)0);
	cui_tests::eq_vec2(g_nodes[0].pos, { 20, 0 });

	body_rec.consume_mouse = true;
	// B's body probe at plane {320, 60} → screen {660, 140}.
	cui_tests::frame(ui, { 660, 140 }, left: true);
	cui_tests::frame(ui, { 660, 140 });
	test::eq(body_rec.presses, 1);
	cui_tests::eq_vec2(body_rec.last_pos, { 12, 8 });
}
