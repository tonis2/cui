// Node editor demo: a NodeGraph with editors on its cards, wires, a selection
// box and an "add node" search menu. Space, Tab or a double-click on empty space
// opens the menu; so does dropping a wire on nothing. Delete removes selected
// wires; F frames.
//
//   c3c run nodes                         interactive
//   c3c run nodes -- --shot build/shots   writes PNGs at three zooms and quits
import cui;
import std::io;
import std::math;
import std::collections::list;

const Color MODEL = { 0.70, 0.45, 0.95, 1.0 };
const Color COND = { 0.95, 0.80, 0.30, 1.0 };
const Color LATENT = { 0.95, 0.45, 0.60, 1.0 };
const Color IMAGE = { 0.35, 0.75, 0.95, 1.0 };
const Color NUMBER = { 0.55, 0.85, 0.55, 1.0 };

GraphNode[5] nodes = {
	{ .pos = { 40, 60 }, .title = "Load model", .tag = "#1" },
	{ .pos = { 40, 230 }, .title = "Prompt", .tag = "#2" },
	{ .pos = { 360, 90 }, .title = "Sampler", .tag = "#3", .flags = { .running = true }, .progress = 0.4 },
	{ .pos = { 680, 130 }, .title = "Decode", .tag = "#4", .width = 160 },
	{ .pos = { 900, 90 }, .title = "Preview", .tag = "#5" },
};

GraphPort[10] ports = {
	{ .node = 0, .output = true, .label = "model", .color = MODEL },
	{ .node = 1, .output = true, .label = "conditioning", .color = COND },
	{ .node = 2, .label = "model", .color = MODEL },
	{ .node = 2, .label = "positive", .color = COND },
	{ .node = 2, .label = "seed", .color = NUMBER, .hollow = true },
	{ .node = 2, .label = "steps", .color = NUMBER, .hollow = true },
	{ .node = 2, .output = true, .label = "latent", .color = LATENT },
	{ .node = 3, .label = "latent", .color = LATENT },
	{ .node = 3, .output = true, .label = "image", .color = IMAGE, .shape = SQUARE },
	{ .node = 4, .label = "image", .color = IMAGE, .shape = SQUARE },
};

GraphWire[32] wire_store = {
	[0] = { .from = 0, .to = 2 },
	[1] = { .from = 1, .to = 3 },
	[2] = { .from = 6, .to = 7 },
	[3] = { .from = 8, .to = 9 },
};
usz wire_count = 4;

ContextMenuItem[] node_types = {
	{ .label = "Load model", .category = "Loaders" },
	{ .label = "Load LoRA", .category = "Loaders" },
	{ .label = "Load image", .category = "Loaders", .hint = "drop a file" },
	{ .label = "Prompt", .category = "Conditioning" },
	{ .label = "Prompt (negative)", .category = "Conditioning" },
	{ .label = "Sampler", .category = "Sampling" },
	{ .label = "Sampler (advanced)", .category = "Sampling", .disabled = true },
	{ .label = "Decode", .category = "Latent" },
	{ .label = "Encode", .category = "Latent" },
	{ .label = "Preview", .category = "Image" },
	{ .label = "Save image", .category = "Image", .hint = "Ctrl+S" },
};

Element* graph_elem;
Element* menu_elem;

fn NodeGraph* graph() => graph_elem.widget_as(NodeGraph);

fn void wires_changed()
{
	graph().wires = wire_store[:wire_count];
	graph().refresh(graph_elem);
}

fn void on_select(Ui* ui, sz node, SelectMode mode)
{
	if (mode == SelectMode.REPLACE)
	{
		foreach (&n : nodes) n.flags.selected = false;
		foreach (&w : wire_store[:wire_count]) w.selected = false;
	}
	if (node >= 0) nodes[node].flags.selected = mode == SelectMode.TOGGLE ? !nodes[node].flags.selected : true;
}

fn void on_box(Ui* ui, usz[] hit, SelectMode mode)
{
	if (mode == SelectMode.REPLACE) foreach (&n : nodes) n.flags.selected = false;
	foreach (i : hit) nodes[i].flags.selected = mode == SelectMode.TOGGLE ? !nodes[i].flags.selected : true;
}

fn void on_move(Ui* ui, Vec2 delta, bool done)
{
	foreach (&n : nodes) if (n.flags.selected) n.pos += delta;
	if (done) io::printn("[nodes] move committed (one undo step)");
}

fn void on_connect(Ui* ui, usz from, usz to)
{
	// An input takes one wire: a new one replaces the old.
	for (usz i = 0; i < wire_count; i++)
	{
		if (wire_store[i].to == to)
		{
			wire_store[i] = wire_store[--wire_count];
			break;
		}
	}
	if (wire_count < wire_store.len) wire_store[wire_count++] = { .from = from, .to = to };
	wires_changed();
}

fn void on_disconnect(Ui* ui, usz wire)
{
	wire_store[wire] = wire_store[--wire_count];
	wires_changed();
}

fn void on_wire_select(Ui* ui, usz wire, SelectMode mode)
{
	if (mode == SelectMode.REPLACE)
	{
		foreach (&n : nodes) n.flags.selected = false;
		foreach (&w : wire_store[:wire_count]) w.selected = false;
	}
	wire_store[wire].selected = !wire_store[wire].selected || mode == SelectMode.REPLACE;
}

fn void on_command(Ui* ui, GraphCommand command)
{
	io::printfn("[nodes] command %s", command);
	if (command != DELETE) return;
	for (usz i = 0; i < wire_count;)
	{
		if (wire_store[i].selected)
		{
			wire_store[i] = wire_store[--wire_count];
			continue;
		}
		i++;
	}
	wires_changed();
}

fn bool can_connect(Ui* ui, usz from, usz to)
{
	return ((Vec4)ports[from].color == (Vec4)ports[to].color) && ports[from].node != ports[to].node;
}

fn void open_menu(Ui* ui, Vec2 plane, Vec2 screen)
{
	menu_elem.widget_as(ContextMenu).open_at(menu_elem, screen);
}

fn void on_wire_dropped(Ui* ui, usz port, Vec2 plane, Vec2 screen) => open_menu(ui, plane, screen);

fn void on_choose(Ui* ui, usz index) => io::printfn("[nodes] add \"%s\"", node_types[index].label);

fn void on_context(Ui* ui, GraphTarget target, sz index, Vec2 plane, Vec2 screen)
{
	io::printfn("[nodes] context on %s %d", target, index);
	open_menu(ui, plane, screen);
}

fn void main(String[] args)
{
	String shots = "";
	for (usz i = 1; i + 1 < args.len; i++) if (args[i] == "--shot") shots = args[i + 1];

	Vec2 window_size = { 1280.0, 720.0 };
	Renderer renderer = cui::vulkan::new(window_size: window_size, quit_on_escape: false, title: "cui node graph")!!;
	defer catch renderer.free();

	Ui* ui = cui::new_ui(window_size);
	defer ui.free();
	ui.load_font("test/assets/DejaVuSans.ttf")!!;

	@canvas(ui)
	{
		@tree((Stack) { })
		{
			@tree(
				(NodeGraph) {
					.nodes = &nodes,
					.ports = &ports,
					.wires = wire_store[:wire_count],
					.view = { .pan = { -20, -20 } },
					.on_select = &on_select,
					.on_box = &on_box,
					.on_move = &on_move,
					.can_connect = &can_connect,
					.on_connect = &on_connect,
					.on_disconnect = &on_disconnect,
					.on_wire_select = &on_wire_select,
					.on_wire_dropped = &on_wire_dropped,
					.on_context = &on_context,
					.on_command = &on_command,
					.on_add_request = &open_menu,
				}
			)
			{
				@tree((NodeCard) { .node = 0 })
				{
					@node((TextField) { .placeholder = "model file" }).with_id("model-path");
				};
				@tree((NodeCard) { .node = 1 })
				{
					@node((TextField) { .placeholder = "a lighthouse at dusk" });
				};
				@tree((NodeCard) { .node = 2 })
				{
					@tree((Column) { .gap = 6 })
					{
						@tree((PortRow) { .port = 4 })
						{
							@node((Slider) { .label = "seed", .value = 42, .min = 0, .max = 1000, .step = 1 });
						};
						@tree((PortRow) { .port = 5 })
						{
							@node((Slider) { .label = "steps", .value = 4, .min = 1, .max = 50, .step = 1 });
						};
						@node((Checkbox) { .label = "tiled VAE" });
					};
				};
				@node((NodeCard) { .node = 3 });
				@tree((NodeCard) { .node = 4 })
				{
					@node((Rectangle) {
						.size = { 204, 140 },
						.style = { .color = { 0.25, 0.32, 0.45, 1.0 }, .border_radius = { 4, 4, 4, 4 } },
					});
				};
			}.with_id("graph");
			@node((ContextMenu) {
				.items = node_types,
				.searchable = true,
				.placeholder = "Add a node",
				.on_choose = &on_choose,
			}).with_id("menu");
		};
	};
	graph_elem = ui.find_id("graph")!!;
	menu_elem = ui.find_id("menu")!!;

	int frame;
	while (renderer.frame(ui)!!)
	{
		frame++;
		if (shots.len == 0) continue;
		@pool()
		{
			switch (frame)
			{
				case 5:
					renderer.request_screenshot(string::tformat("%s/zoom1.png", shots));
				case 8:
					View2D view = graph().view;
					view.zoom_at({ 640, 360 }, 0.4f);
					graph().set_view(graph_elem, view);
				case 12:
					renderer.request_screenshot(string::tformat("%s/zoom04.png", shots));
				case 15:
					View2D view = { .pan = { 380, 120 }, .zoom = 2.5 };
					graph().set_view(graph_elem, view);
				case 19:
					renderer.request_screenshot(string::tformat("%s/zoom25.png", shots));
				case 22:
					graph().set_view(graph_elem, { .pan = { -20, -20 }, .zoom = 1 });
					nodes[2].flags.selected = true;
					wire_store[1].selected = true;
					graph().repaint(graph_elem);
					menu_elem.widget_as(ContextMenu).open_at(menu_elem, { 560, 380 });
				case 26:
					renderer.request_screenshot(string::tformat("%s/menu.png", shots));
				case 30:
					return;
			}
		};
	}
}
