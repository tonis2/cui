# CUI

GPU-rendered retained-mode UI library for C3.

Widgets form a retained element tree with cached layout and paint. Every drawing
is an SDF primitive — rounded rects, circles, ellipses, lines, arcs, shadows,
all antialiased — and the entire canvas renders in a **single instanced draw
call**. Transform animations write one matrix into a GPU palette and re-run
neither layout nor paint.

- **Declarative trees** — scoped builder macros where the nesting of the code is
  the nesting of the tree.
- **Composite widgets** — a widget can `build()` a subtree of other widgets
  instead of painting.
- **Clipping and scrolling** — resolved per fragment in the shader, so rounded
  clips antialias and nested clips intersect without breaking the single draw.
- **Input** — hit testing with bubbling, pointer capture for drags, keyboard
  focus, hover, and cursor shapes.
- **Idle-sleep loop** — an `ON_DEMAND` mode that parks the thread at ~0% CPU
  until the user does something, while animations keep it awake on their own.

The library is split so it can be embedded in an existing Vulkan engine:

| Module | What it is |
| --- | --- |
| `cui` | The core: element tree, the `Widget` interface, the `Canvas` output, and the GPU binding contract. No Vulkan or windowing dependency. |
| `cui::widgets` | Built-ins: `Rectangle`, `Column`, `Row`, `Stack`, `Padding`, `Clip`, `Scroll`, `Button`. Apps use these or implement `Widget` themselves. |
| `cui::camera` | Projection/view helpers producing the matrices the shader expects. Pure math. |
| `cui::vulkan` | A standalone reference renderer (window, swapchain, frame loop) used by the examples. Engines with their own device skip it — see [docs/embedding.md](docs/embedding.md). |

## Example

`@canvas(ui)` opens a build scope and installs the body's top-level node as the
UI root; inside it `@tree` adds a container (its body fills in the children) and
`@node` adds a leaf. Plain statements — loops, locals — mix freely into the
bodies, because a body is just code:

```c3
@canvas(ui)
{
    @tree((Column){ .gap = 8.0 })
    {
        @node((Rectangle){ .size = {100, 40}, .style = { .color = cui::WHITE } });
        for (int i = 0; i < 4; i++) @node((Rectangle){ .size = {100, 40} });

        @node((Button){ .size = {130, 40}, .on_click = &reset_clicked });
    };
};
```

A widget is passed as a **value** (a struct literal, as above — the element
heap-copies and owns it) or as a **pointer** (borrowed; the app owns the struct
and can mutate it between frames).

Callbacks receive the `Ui` the widget lives in, so they can reach the rest of
the tree without threading any app context through:

```c3
fn void reset_clicked(Ui* ui)
{
    ui.@modify(Dial; d) { d.value = 0; };   // resolve the node once, mutate, repaint
}

fn void recolor_card(Ui* ui)
{
	ui.@modify_id("teal", Rectangle; card)
	{
		Vec4 c = (Vec4)card.style.color;
		card.style.color = c.y > c.x ? (Color) { 0.55, 0.30, 0.50, 1.0 } : (Color) { 0.16, 0.45, 0.42, 1.0 };
		io::printfn("[layout] recolor teal card");
	};
}
```

Then run a frame loop. `Renderer.frame(ui)` polls input, dispatches it to
widgets, flushes, renders and presents, returning `false` when the user quits:

```c3
while (renderer.frame(ui)!!)
{
    // per-frame app or game logic — read ui.input, mutate widgets
}
```

## Running the examples

Install [C3](https://c3-lang.org/) and the Vulkan SDK (on macOS a Vulkan-on-Metal
driver such as KosmicKrisp or MoltenVK is required).

```
c3c run ui         # textured cards animated through the transform palette
c3c run layout     # Column / Row / Padding, plus a custom Dial widget
c3c run composite  # a widget composed from other widgets
c3c run scroll     # clipping, a scrolling card list, nested clips
c3c test unittest  # headless unit tests — no GPU or window needed
```

The sources in `test/` double as the worked examples for each feature.

Shaders are written in [Slang](https://shader-slang.org/). A prebuilt
`shader.spv` is checked in; rebuild it with `c3c build shaders` only after
editing `src/shaders/shader.slang`.

