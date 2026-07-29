# Embedding CUI in a Vulkan engine

The engine owns the device, swapchain and frame loop; cui produces a `Canvas`
that goes onto the screen with one pipeline and one instanced draw call.

There are two ways in, and most engines want the first.

## 1. Use `CanvasPass` (recommended)

`cui::vulkan::CanvasPass` *is* the drawing half of the reference renderer, with
the window, swapchain, present and frame loop left out. It owns a pipeline, the
three device-address buffers the shader reads, the uniform buffer and the
texture array — and borrows your device, allocator and queue. It does not create
a device, acquire an image, or present.

```c3
// setup
CanvasPass ui_pass = vulkan::new_canvas_pass(
    device, &allocator, graphics_queue,
    color_format,           // format of the attachment you will draw into
    depth_format,           // or FORMAT_UNDEFINED if your pass has no depth
    window_size)!;
defer ui_pass.free();

Texture logo = ui_pass.load_image("logo.png")!;

// per frame
ui.process_input(input_frame, dt);       // your input, in UI coordinates
// ... mutate the widget tree ...
ui_pass.upload(ui, window_size)!;        // OUTSIDE a render pass

vkCmdBeginRendering(cmd, ...);
//   ... your own scene draws ...
ui_pass.record(cmd, extent)!;            // INSIDE one
vkCmdEndRendering(cmd);
```

That is the whole integration. Two calls per frame.

**`upload` must run outside a render pass.** It bakes glyphs, may grow a buffer
(which idles the GPU) and may rebuild the pipeline when the texture count
changed. It also calls `ui.flush()` for you, bracketed by the two glyph-atlas
syncs it has to sit between — that ordering is the classic embedding bug, so it
is not yours to get wrong.

**`record` sets no dynamic state of its own.** Your viewport and scissor are used
as they stand, so clipping the interface to a sub-rect is your call. It binds its
pipeline, pushes its descriptors and push constants, and draws. A frame with
nothing to draw records nothing.

**cui never tests or writes depth.** `depth_format` only has to match the pass you
record into. That is also what lets you draw 3D underneath: render your scene
with depth on, then record the interface over it untested.

**Texture handles.** `load_image` / `load_pixels` return a `cui::Texture` to put
in `RectStyle.texture` and friends. Textures can be loaded at any time; ones
added between frames become valid at the next `upload`.

**Moving the pass.** Every `vk::Memory` remembers the allocator address it was
created from. If your allocator lives inside a struct you return by value, those
pointers dangle — call `pass.adopt(&allocator)` after the move. A host whose
allocator has a stable address never needs it.

### Depth, color and the render pass

`CanvasPass` is compiled against the formats you pass at creation. Recording it
into a pass with different attachment formats is undefined. If your swapchain
format can change, recreate the pass.

## 2. Implement the contract yourself

Only necessary if you cannot depend on `cui::vulkan` — a different binding
generator, a rendering abstraction of your own, or a non-Vulkan backend. The
exports in `src/shader.c3` are the whole contract; `src/vulkan/canvas_pass.c3` is
the worked implementation of every step below, and is worth reading alongside.

### Pipeline

Create one `VkShaderModule` from `cui::shader_spirv` — a single module with entry
points `cui::SHADER_VERTEX_ENTRY` and `cui::SHADER_FRAGMENT_ENTRY`. No vertex
input state (the quad comes from `SV_VertexID`), triangle list, culling off,
standard alpha blending (`src_alpha` / `one_minus_src_alpha`), depth test off.

### Descriptor set 0

**binding 0** — a uniform buffer holding a `cui::ShaderUniforms` (vertex +
fragment stages). Upload `projection` and `view` **as they are, untransposed**:
the shader reads column-major bytes and `Matrix4f` already stores them that way.
Use `Camera.perspective` and `Camera.ui_view()` from `cui::camera` — `ui_view()`
bakes a compensating scale into the view so canvas coordinates stay pixel-exact
under the perspective projection. `resolution` is the drawable size in pixels;
drawing coordinates are pixels.

**binding 1** — an array of combined image samplers, one per UI texture.
`Drawing.texture` / `RectStyle.texture` carry `cui::Texture` handles: 1-based
indices into this array (0 means untextured), so you define the handle values by
how you populate the array. `CanvasPass` hands them out from `load_image` /
`load_pixels` and keeps a 1x1 white placeholder in slot 1 so the binding is never
empty.

### Buffers

Three buffers created with `BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT`: the drawing
list, the transform palette and the clip list. Each frame:

| If | Upload | Notes |
| --- | --- | --- |
| `canvas.drawings_dirty` | `canvas.drawings.entries` | `Drawing` is a plain struct, scalar layout |
| `canvas.transforms_dirty` | `canvas.transforms` | Raw `Matrix4f` bytes, untransposed |
| `canvas.clips_dirty` | `canvas.clips` | `ClipEntry`, two `Vec4`s per entry |

Clear each flag after uploading, and grow the buffers when the counts outgrow
them. A clean frame uploads nothing.

### Glyph atlas

`ui.text` carries a CPU atlas that has to reach the GPU as a texture. The order
matters and is easy to get wrong:

1. **Before `ui.flush()`** — if `ui.text.texture` is `NO_TEXTURE` and fonts are
   loaded, upload the atlas, set `ui.text.texture` to its handle. Paint caches
   drawings with the handle baked in, so it must exist before the first
   `Painter.text` runs.
2. `ui.flush()`
3. **After `ui.flush()`** — if `ui.text.dirty`, re-upload the atlas pixels, since
   glyphs baked during paint must reach the GPU before the draw that samples
   them.

### Draw

Push a `cui::ShaderPushConstants` (24 bytes: the three buffer device addresses,
vertex + fragment stages), then:

```c3
vkCmdDraw(cmd, 6, canvas.drawings.len, 0, 0);
```

## Input

Fill a `cui::InputFrame` from your engine's input — pointer in UI coordinates,
button level-states, scroll, typed text, held keys as `cui::Key` X11 codes — and
call `ui.process_input(frame, dt)`. Apply `ui.cursor` to the OS pointer if it
changed.

Hit testing picks the **topmost rect containing the point**, whether or not that
widget handles anything, and events then bubble to its *parents* — never to a
sibling underneath. So decoration laid over an interactive surface blocks it,
the same way a `<span>` over a `<canvas>` does. Widgets opt out by setting
`elem.ignores_pointer` from `layout()`; `Label` already does, and children stay
hittable either way.

## Clipping

`Drawing.clip_id` indexes `canvas.clips`; 0 means unclipped. Clip rects are
absolute, **pre-transform** UI pixels — the fragment shader reconstructs the
drawing's UI-space position, so a clip travels with any palette transform applied
on top (Flutter-consistent) rather than staying screen-fixed. The clip list is
rebuilt on every emit; there is nothing to do beyond uploading it when dirty.

## Device features

`bufferDeviceAddress`, `shaderDrawParameters` and `scalarBlockLayout` must be
enabled. The reference renderer queries the
`PhysicalDeviceVulkan11/12/13Features` chain and hands the same chain back at
device creation, so exactly what the driver supports gets enabled.

## Idle sleep

`Renderer.frame` is a reference-renderer feature, but the primitive behind its
`ON_DEMAND` mode is reusable: any invalidation (`request_paint`,
`request_layout`, `set_transform`, mount/unmount, …) sets `ui.frame_requested`.
Sleep only when a frame settles with no request pending, and a running animation
— which re-schedules every frame, like a Flutter `Ticker` re-arming itself —
keeps the loop awake on its own. The one gap: waking for a *non-input* reason (a
timer, a background thread calling `request_paint` while asleep) needs the
platform to post a wake event.
