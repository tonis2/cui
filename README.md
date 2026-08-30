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

CUI is its own sources and nothing else. It **vendors no dependencies**: the
windowing, image, font and Vulkan libraries are separate projects, and you
install them yourself next to `cui.c3l`. That is what keeps an engine that
already uses `c3w` or `image` from compiling a second, colliding copy of them.

Run this in **your own project**, not in a clone of cui:

```sh
mkdir -p lib

# cui itself
curl -fsSL -o lib/cui.c3l \
  https://github.com/tonis2/cui/releases/latest/download/cui.c3l


# vk is the exception, and the only one that has to come from a release: the
# artifact carries the prebuilt macOS loader + driver dylibs, which are not in
# the repo. It dlopens them relative to its own sources at runtime.
curl -fsSL -o lib/vulkan.c3l \
  https://github.com/tonis2/Vulkan.c3/releases/download/latest/vulkan.c3l
```


```json
{
  "dependency-search-paths": [ "lib" ],
  "dependencies": [ "cui", "vk", "c3w", "image", "font" ],
  "targets": {
    "app": { "type": "executable" }
  }
}
```

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

The source is grouped the same way, one directory per layer:

```
src/core/      the element tree and the frame — ui.c3, input.c3, media.c3
src/render/    what a frame turns into — canvas.c3 (the drawing list), text.c3
               (fonts and the glyph atlas), camera.c3, shader.c3 (GPU contract)
src/widgets/   the built-ins — basic.c3, menu.c3, dialog.c3, area.c3
src/vulkan/    the reference backend
src/shaders/   the Slang source and the compiled SPIR-V
```

Nothing below `src/core` and `src/render` is required to use cui: an app can
implement `Widget` without `src/widgets`, and an engine with its own device
draws a `Canvas` without `src/vulkan`.

## Working on cui itself

Clone with `--recurse-submodules` — window, image and font live in `lib/` as
submodules **for building cui itself**. They are not part of the library: a
release ships `manifest.json` and `src/` only, and `project.json` (which points
at `lib/`) is left out of it. `vk` is not a submodule, so download it exactly
like a consumer does:

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
