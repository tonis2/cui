# Embedding CUI in a Vulkan engine

The engine owns the device, swapchain and frame loop; cui produces a `Canvas`
the engine renders with one pipeline and one instanced draw call. Nothing here
depends on `cui::vulkan` — that module is only the reference renderer, and
`src/vulkan/renderer.c3` is the worked example of every step below.

## Per frame

Fill a `cui::InputFrame` from your engine's input (pointer in UI coordinates,
button level-states, scroll, typed text, held keys as `cui::Key` X11 codes) and
call `ui.process_input(frame, dt)`; apply `ui.cursor` to the OS pointer if it
changed. Then build or mutate the widget tree, call `ui.flush()`, and consume
`ui.canvas` while recording your command buffer.

## Pipeline

Create one `VkShaderModule` from `cui::shader_spirv` — a single module with
entry points `cui::SHADER_VERTEX_ENTRY` and `cui::SHADER_FRAGMENT_ENTRY`. No
vertex input state (the quad comes from `SV_VertexID`), triangle list, culling
off, standard alpha blending (`src_alpha` / `one_minus_src_alpha`), depth test
optional.

## Descriptor set 0

**binding 0** — a uniform buffer holding a `cui::ShaderUniforms` (vertex +
fragment stages). Upload `projection` and `view` **transposed**; use
`Camera.perspective` and `Camera.ui_view()` from `cui::camera` — `ui_view()`
bakes a compensating scale into the view so canvas coordinates stay pixel-exact
under the perspective projection. `resolution` is the drawable size in pixels;
drawing coordinates are pixels.

**binding 1** — an array of combined image samplers, one per UI texture.
`Drawing.texture` / `RectStyle.texture` carry `cui::Texture` handles: 1-based
indices into this array (0 means untextured), so the engine defines handle
values by how it populates the array. The reference renderer hands them out from
`load_image` / `load_pixels` and keeps a built-in 1x1 white placeholder in slot 1
so the binding is never empty.

## Buffers

Three buffers created with `BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT`: the drawing
list, the transform palette and the clip list. Each frame:

| If | Upload | Notes |
| --- | --- | --- |
| `canvas.drawings_dirty` | `canvas.drawings.entries` | `Drawing` is a plain struct, scalar layout |
| `canvas.transforms_dirty` | `canvas.transforms` | Raw `Matrix4f` bytes, **not** transposed |
| `canvas.clips_dirty` | `canvas.clips` | `ClipEntry`, two `Vec4`s per entry |

Clear each flag after uploading, and grow the buffers when the counts outgrow
them. A clean frame uploads nothing.

## Draw

Push a `cui::ShaderPushConstants` (24 bytes: the three buffer device addresses,
vertex + fragment stages), then:

```c3
vkCmdDraw(cmd, 6, canvas.drawings.len, 0, 0);
```

## Clipping

`Drawing.clip_id` indexes `canvas.clips`; 0 means unclipped. Clip rects are
absolute, **pre-transform** UI pixels — the fragment shader reconstructs the
drawing's UI-space position, so a clip travels with any palette transform
applied on top (Flutter-consistent) rather than staying screen-fixed. The clip
list is rebuilt on every emit; there is nothing to do beyond uploading it when
dirty.

## Device features

`bufferDeviceAddress`, `shaderDrawParameters` and `scalarBlockLayout` must be
enabled. The reference renderer queries the `PhysicalDeviceVulkan11/12/13Features`
chain and passes it back at device creation, which enables everything the driver
supports.

## Idle sleep

`Renderer.frame` is a reference-renderer feature, but the primitive behind its
`ON_DEMAND` mode is reusable: any invalidation (`request_paint`,
`request_layout`, `set_transform`, mount/unmount, …) sets `ui.frame_requested`.
Sleep only when a frame settles with no request pending, and a running animation
— which re-schedules every frame, like a Flutter `Ticker` re-arming itself —
keeps the loop awake on its own. The one gap: waking for a *non-input* reason (a
timer, a background thread calling `request_paint` while asleep) needs the
platform to post a wake event.
