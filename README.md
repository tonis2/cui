# CUI

GPU-rendered retained-mode UI library for C3. Widgets form a retained element
tree with cached layout and paint; every drawing is an SDF primitive rendered
in a single instanced draw call. Transform animations write one matrix into a
GPU palette and re-run neither layout nor paint.

The library is split so it can be embedded in an existing Vulkan engine:

- `cui` — the core: element tree, the `Widget` interface, and the `Canvas`
  output (drawings + transform palette). No Vulkan or windowing dependencies.
  Also exports the compiled shader (`cui::shader_spirv`) and the GPU binding
  contract (`cui::ShaderUniforms`, `cui::ShaderPushConstants`) — see
  `src/shader.c3`.
- `cui::widgets` — the built-in widgets: `Rectangle`, `Column`, `Row`
  (gap, main/cross alignment, optional fixed size), `Stack` (absolute
  positioning) and `Padding`. Apps can use these or implement `Widget`
  themselves.
- `cui::camera` — projection/view helpers producing the matrices the shader
  expects. Pure math.
- `cui::vulkan` — a standalone reference renderer (window, swapchain, frame
  loop) used by the example. Engines with their own device skip it and follow
  the embedding steps below.

### Building UI

Trees are declared with `Ui.@node` and installed with
`Ui.build`:

```c3
ui.build(
    ui.@node((Column){ .gap = 8.0 },
        ui.@node((Rectangle){ .size = {100, 40}, .style = { .color = cui::WHITE } }),
        ui.@node((Rectangle){ .size = {100, 40} })));
```

`@node` takes the widget either as a **value** (a struct literal, as above —
the element makes a heap copy it owns and frees on unmount) or as a
**pointer** (`ui.@node(&my_widget, ...)` — borrowed; the app owns the struct,
can mutate it between frames, and must keep it alive). Children follow as
extra arguments; `Element.append` grafts nodes built in loops, and
`Ui.mount` / `Ui.unmount` add and remove widgets incrementally at runtime.

Images are uploaded to the renderer, which returns the `Texture` handle that
widget styles reference (textures can be loaded at any time; the renderer
rebuilds its pipeline when the count grows):

```c3
Texture portrait = renderer.load_image("assets/portrait.png")!!;
// or from raw RGBA8 pixels: renderer.load_pixels(rgba, width, height)
ui.@node((Rectangle){ .size = {260, 300}, .style = { .texture = portrait } });
```

`test/layout.c3` is a full declarative example; `test/main.c3` uses app-owned
widgets so it can animate their elements every frame.

### Custom widgets and the Painter

A widget's `paint` receives a `Painter` and draws SDF primitives in
element-local coordinates. All units are pixels; angles are radians with
0 = +x, increasing clockwise on screen (y points down); corner radii run
`{top-left, top-right, bottom-right, bottom-left}` and clamp to what the
shape can fit; borders draw inside the shape's edge. Everything is
antialiased over a 1px band.

```c3
painter.rect(pos, size, (RectStyle){ .color = ..., .border_radius = {8, 8, 8, 8} });
painter.circle(center, radius, (CircleStyle){ .texture = avatar });   // round images work
painter.ellipse(center, radii, style);
painter.line(from, to, thickness, color);                  // rounded caps
painter.arc(center, radius, start, sweep, thickness, color); // sweep >= 2π = full ring
painter.rect_shadow(pos, size, blur, color, border_radius);  // soft shadow / glow
```

The `Dial` widget in `test/layout.c3` combines them into a gauge — face,
tick marks, progress arc, needle — in ~30 lines of paint code.

### Interactivity

Input flows through `Ui.process_input` (the reference renderer calls it every
frame before your `@on_frame` body; embedding engines call it themselves).
Widgets receive events through optional interface methods — the same
interface as layout/paint, so any widget can opt in:

```c3
fn bool on_mouse(Element* elem, MouseEvent event) @optional;  // press/release/move/scroll
fn void on_hover(Element* elem, bool entered) @optional;
fn bool on_key(Element* elem, KeyEvent event) @optional;
fn void update(Element* elem, float dt) @optional;            // every frame
```

Semantics:

- **Hit testing + bubbling** — the deepest element under the pointer gets
  `on_mouse` first; returning `true` consumes the event. Positions arrive in
  element-local coordinates. (Transform-palette matrices are not applied to
  hit tests.)
- **Capture** — consuming a PRESS routes all mouse events to that element
  until the button releases, so drags keep working outside its bounds.
- **Focus** — left-clicking an element whose widget implements `on_key`
  focuses it (or call `Element.request_focus()`); key press/release edges
  are delivered there and bubble up.
- **Context** — every widget can read `elem.ui.input` (an `Input` struct):
  mouse position, button/key state with per-frame edges, scroll delta, typed
  UTF-8 text, `time`/`dt`. Don't read it from `paint()` — paint output is
  cached; react in event callbacks or `update()`, then `request_paint()`.
- **Cursor** — set `Element.cursor` (e.g. `Cursor.POINTING_HAND`) and the
  deepest hovered element with a preference wins; the renderer applies it to
  the OS pointer.

`Button` in `cui::widgets` is the worked example (hover/press styles). Its
`on_click` is a plain contextless callback; a callback that needs to reach
another widget queries the tree for it instead of carrying a handle:

```c3
fn void reset_clicked() {
    cui::get_widget(Dial).value = 0;   // find the widget by type…
    cui::request_paint(Dial);          // …and invalidate it
}
ui.@node((Button){ .size = {130, 40}, .on_click = &reset_clicked });
```

`cui::get_widget($Type)` returns a pointer to the first widget of that type in
the *active* UI (the one `new_ui` created; `Ui.make_active` switches it) — CUI's
answer to Flutter's `findAncestorStateOfType`, and to "how does a callback with
no context reach the rest of the tree." For a stable handle you can also keep
the `Element*` that `@node` returns and read it back with `Element.widget_as`
(`ui.find($Type)` is the explicit, non-ambient form). Type-based lookup fits
singletons; hold an explicit handle when several widgets of a kind coexist.

The `Dial` in `test/layout.c3` shows drag with capture, scroll, and
arrow-key focus handling.

### Frame loop: continuous vs. on-demand

The reference renderer runs one of two loop modes, picked at `cui::vulkan::new`:

- `CONTINUOUS` (default) redraws every frame and polls input, running at the
  display's refresh rate forever. Lowest latency, but a CPU core stays busy —
  right when something is always animating (the `ui` example rotates its cards
  every frame).
- `ON_DEMAND` sleeps when idle: once a frame settles with nothing scheduled,
  the loop blocks for input and the thread parks at ~0% CPU until the user does
  something. Right for mostly-static desktop UIs — the `layout` example uses it.

  ```c3
  cui::vulkan::new(window_size: size, loop_mode: cui::vulkan::LoopMode.ON_DEMAND)
  ```

Animation still plays smoothly under `ON_DEMAND` because it rides the same
scheduling as everything else: any invalidation (`request_paint`,
`request_layout`, `set_transform`, mount/unmount, …) sets `ui.frame_requested`,
and the loop only sleeps after a frame produces no new request. A running
animation re-schedules every frame — the way a Flutter `Ticker` re-arms itself —
so it keeps drawing and the loop parks only once it finishes. The one gap:
waking for a *non-input* reason (a timer firing, a background thread calling
`request_paint` while asleep) needs the platform to post a wake event;
input-driven UIs don't hit this.

Embedding engines own their own loop, so this is a reference-renderer feature —
but `ui.frame_requested` is the reusable primitive if you build the same
idle-sleep against your own frame loop.

### Running the example

Install C3 from https://c3-lang.org/

Install the Vulkan SDK (the example links against `libvulkan` in
`/usr/local/lib`; on macOS a Vulkan-on-Metal driver such as KosmicKrisp or
MoltenVK is required).

Shaders are written in [Slang](https://shader-slang.org/). Rebuild the SPIR-V
after editing `src/shaders/shader.slang`:

```
c3c build shaders
```

(a prebuilt `shader.spv` is checked in, so this is only needed when the shader
changes).

Then run the examples:

```
c3c run ui        # textured cards animated through the transform palette
c3c run layout    # Column / Row / Padding layout widgets (test/layout.c3)
```

In the `ui` example, drag with the left mouse button to rotate the cards.
In the `layout` example, drag/scroll the dial (or click it and use the arrow
keys), and try the two buttons under the shelf. Escape or the close button
quits.

### Embedding in a Vulkan engine

The engine owns the device, swapchain, and frame loop; cui produces a
`Canvas` the engine renders with one pipeline and one instanced draw call.
`src/vulkan/renderer.c3` is the worked example of every step below.

**Per frame** — fill a `cui::InputFrame` from your engine's input (pointer in
UI coordinates, button level-states, scroll, typed text, held keys as
`cui::Key` X11 codes) and call `ui.process_input(frame, dt)`; apply
`ui.cursor` to the OS pointer if it changed. Then build/mutate the widget
tree, call `ui.flush()`, and consume `ui.canvas` while recording your command
buffer.

**Pipeline** — create one `VkShaderModule` from `cui::shader_spirv` (a single
module with entry points `cui::SHADER_VERTEX_ENTRY` and
`cui::SHADER_FRAGMENT_ENTRY`). No vertex input state (the quad comes from
`SV_VertexID`), triangle list, culling off, standard alpha blending
(`src_alpha` / `one_minus_src_alpha`), depth test optional.

**Descriptor set 0** —
- binding 0: uniform buffer holding a `cui::ShaderUniforms`
  (vertex + fragment stages). Upload `projection` and `view` **transposed**;
  use `Camera.perspective` and `Camera.ui_view()` from `cui::camera` —
  `ui_view()` bakes a compensating scale into the view so canvas coordinates
  are pixel-exact under the perspective projection. `resolution` is the
  drawable size in pixels — drawing coordinates are pixels.
- binding 1: array of combined image samplers, one per UI texture.
  `Drawing.texture` / `RectStyle.texture` carry `cui::Texture` handles:
  1-based indices into this array (0 means untextured), so the engine defines
  handle values by how it populates the array. The reference renderer hands
  them out from `load_image` / `load_pixels` and keeps a built-in 1x1 white
  placeholder in slot 1 so the binding is never empty.

**Buffers** — two buffers created with
`BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT`: the drawing list and the transform
palette. Each frame, if `canvas.drawings_dirty`, upload
`canvas.drawings.entries` (`Drawing` is a plain struct, scalar layout) and
clear the flag; likewise `canvas.transforms_dirty` / `canvas.transforms`
(raw `Matrix4f` bytes, **not** transposed). Grow the buffers when the counts
outgrow them — a clean frame uploads nothing.

**Draw** — push a `cui::ShaderPushConstants` (16 bytes, both buffer device
addresses, vertex + fragment stages), then
`vkCmdDraw(cmd, 6, canvas.drawings.len, 0, 0)`.

**Device features** — `bufferDeviceAddress`, `shaderDrawParameters` and
`scalarBlockLayout` must be enabled. The reference renderer queries the
`PhysicalDeviceVulkan11/12/13Features` chain and passes it back at device
creation, which enables everything the driver supports.
