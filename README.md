# CUI

GPU-rendered retained-mode UI library for C3.

Every drawing is an SDF primitive — rounded rects, circles, ellipses, lines,
arcs, shadows, all antialiased — and the entire canvas renders in a **single
instanced draw call**.

- **Declarative trees** — scoped builder macros where the nesting of the code is
  the nesting of the tree.
- **Composite widgets** — a widget can `build()` a subtree of other widgets
  instead of painting.
- **Clipping and scrolling** — resolved per fragment in the shader, so rounded
  clips antialias and nested clips intersect without breaking the single draw.
- **Input** — hit testing with bubbling, pointer capture for drags, keyboard
  focus, hover, and cursor shapes.
- **Media** — `elem.media()` tells any widget how big the screen it is on is,
  where that screen sits and at what pixel density, so it can size itself
  against the display and not just against its parent. A split pane publishes
  itself as the screen for the view inside it.
- **Idle-sleep loop** — an `ON_DEMAND` mode that parks the thread at ~0% CPU
  until the user does something, while animations keep it awake on their own.

## Install

CUI needs **two** libraries, and they are downloaded separately. The Vulkan
bindings are **not** part of this repository and are **not** bundled inside
`cui.c3l` — you always fetch them yourself:

```sh
mkdir -p lib

# 1. cui itself — windowing, image and font libraries are vendored inside
curl -fsSL -o lib/cui.c3l \
  https://github.com/tonis2/cui/releases/latest/download/cui.c3l

# 2. Vulkan bindings — a separate project, rolling `latest`
curl -fsSL -o lib/vulkan.c3l \
  https://github.com/tonis2/Vulkan.c3/releases/download/latest/vulkan.c3l
```

Then point `project.json` at both:

```json
{
  "dependency-search-paths": [ "lib" ],
  "dependencies": [ "cui", "vk" ],
  "targets": {
    "app": { "type": "executable" }
  }
}
```

`vk` is what `vulkan.c3l` provides — c3c resolves a dependency by the manifest's
`provides`, not by the file name. c3c reads a `.c3l` as either a zip or a
directory, so the downloaded files work as-is.

**There is no Vulkan SDK to install.** No `linked-libraries`, no
`linker-search-paths`: nothing links against Vulkan, every command is resolved
at runtime, on every platform. On macOS `vulkan.c3l` also carries its own loader
and driver, so an app runs with nothing installed at all. On Linux and Windows
the machine's own loader and GPU driver are used.

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
    ui.@modify(Dial; d) { d.value = 0; };            // resolve, mutate, repaint
}

fn void recolor_card(Ui* ui)
{
    ui.@modify_id("teal", Rectangle; card)
    {
        card.style.color = (Color) { 0.55, 0.30, 0.50, 1.0 };
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

## Modules

| Module | What it is |
| --- | --- |
| `cui` | The core: element tree, the `Widget` interface, the `Canvas` output, and the GPU binding contract. No Vulkan or windowing dependency. |
| `cui::widgets` | Built-ins: `Rectangle`, `Column`, `Row`, `Stack`, `Padding`, `Clip`, `Scroll`, `Button`. Apps use these or implement `Widget` themselves. |
| `cui::camera` | Projection/view helpers producing the matrices the shader expects. Pure math. |
| `cui::vulkan` | Two things. `CanvasPass` draws a `Canvas` into a command buffer you supply — no window, no swapchain, no frame loop — and is what an engine with its own Vulkan device uses. `Renderer` is a standalone host built on it (window, swapchain, input, frame loop) and is what the examples use. See [docs/embedding.md](docs/embedding.md). |

## Working on cui itself

Clone with `--recurse-submodules` — window, image and font live in `lib/` as
submodules. `vk` is not a submodule, so download it exactly like a consumer
does:

```sh
curl -fsSL -o lib/vulkan.c3l \
  https://github.com/tonis2/Vulkan.c3/releases/download/latest/vulkan.c3l
```

The sources in `test/` double as the worked examples for each feature:

```sh
c3c run ui         # textured cards animated through the transform palette
c3c run layout     # Column / Row / Padding, plus a custom Dial widget
c3c run composite  # a widget composed from other widgets
c3c run scroll     # clipping, a scrolling card list, nested clips
c3c run text       # text rendering
c3c test unittest  # headless unit tests — no GPU or window needed
```

Shaders are written in [Slang](https://shader-slang.org/). A prebuilt
`shader.spv` is checked in; rebuild it with `c3c build shaders` only after
editing `src/shaders/shader.slang`.
