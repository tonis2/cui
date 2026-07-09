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

Trees are declared Flutter-style with `Ui.@node` and installed with
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

`test/layout.c3` is a full declarative example; `test/main.c3` uses app-owned
widgets so it can animate their elements every frame.

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
Escape quits.

### Embedding in a Vulkan engine

The engine owns the device, swapchain, and frame loop; cui produces a
`Canvas` the engine renders with one pipeline and one instanced draw call.
`src/vulkan/renderer.c3` is the worked example of every step below.

**Per frame** — build/mutate the widget tree, call `ui.flush()`, then consume
`ui.canvas` while recording your command buffer.

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
  `Drawing.texture` / `RectStyle.texture` are 1-based indices into this array
  (0 means untextured).

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
