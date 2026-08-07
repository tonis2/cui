<*
 Draws a cui Canvas into somebody else's command buffer.

 This is everything it takes to put a cui interface on screen and nothing else:
 one pipeline, the three device-address buffers the shader reads, the uniform
 buffer and the texture array. No window, no swapchain, no device creation, no
 frame loop, no present — those belong to whoever is hosting.

 Two calls per frame:

     `pass.upload(ui, window_size)!;   // outside a render pass`
     `pass.record(cmd, extent)!;       // inside one`

 `upload` flushes the Ui and moves everything that changed to the GPU; `record`
 binds and emits a single instanced draw. They are separate because engines
 separate them: uploads and pipeline rebuilds want to happen before recording
 starts, and one of them idles the GPU when a buffer has to grow.

 A host must have waited for the frame `CANVAS_SLOTS` submissions back before it
 calls `upload`, and must call `upload` once per submitted frame. That is the
 whole of what keeps the memcpy off a buffer a queued draw is still reading; see
 CANVAS_SLOTS for the depth and for what happens when it is not kept.

 `cui::vulkan::Renderer` is a host built on this — window, swapchain, input and
 frame loop wrapped around one CanvasPass. An engine that already has those
 writes its own host and uses this directly, which is the whole point: the
 fiddly half is shared code rather than a page of documentation to reimplement.
 See docs/embedding.md.
*>
module cui::vulkan;
import std::math;
import cui;
import cui::camera;
import vk;

<*
 A cui interface as a single render pass contribution.

 Create with `new_canvas_pass`, feed with `upload`, draw with `record`, release
 with `free`. Textures come from `load_image` / `load_pixels`.
*>
struct CanvasPass {
    // The UI camera. `ui_view()` bakes in the scale that makes canvas
    // coordinates land on exact pixels under the perspective projection, so
    // this is not a camera the host is meant to move — it exists so the shader
    // gets matrices, and `upload` keeps it sized to the viewport.
    Camera camera;

    Device device;
    vk::DeviceQueue queue;
    vk::MemoryAllocator* allocator;  // borrowed; the host owns it

    // One copy per in-flight slot, not one buffer each — see CANVAS_SLOTS.
    vk::Memory[CANVAS_SLOTS] canvas_buffers;
    vk::Memory[CANVAS_SLOTS] transform_buffers;
    vk::Memory[CANVAS_SLOTS] clip_buffers;
    vk::Memory[CANVAS_SLOTS] uniform_buffers;

    // The copy the last `upload` wrote, and the one `record` reads from.
    uint slot;

    // How many times each list has changed, against the count each copy holds.
    // A list left alone since the last frame still has to be written into a
    // copy that predates it, so the canvas's own dirty flags cannot decide an
    // upload on their own: they say "changed since anyone looked", and what is
    // needed here is "changed since this copy was filled".
    uint drawings_revision;
    uint transforms_revision;
    uint clips_revision;
    uint[CANVAS_SLOTS] drawings_in_slot;
    uint[CANVAS_SLOTS] transforms_in_slot;
    uint[CANVAS_SLOTS] clips_in_slot;

    DescriptorImages textures;

    // A DescriptorImageInfo is sampler + view only, so the images behind them
    // have to be owned separately or nothing can destroy them. Parallel to
    // `textures`.
    vk::ImageList texture_images;
    vk::Image atlas_image;      // the Ui's glyph atlas, once created (see sync_text);
                                // owned by texture_images, this is a bare handle
                                // for update_atlas_image

    RenderState pipeline;
    DescriptorSetLayout descriptor_layout;
    sz pipeline_texture_count;  // texture count the pipeline was built for;
                                // 0 = not built yet (see rebuild_pipeline)

    vk::Format color_format;
    vk::Format depth_format;    // FORMAT_UNDEFINED when the host's pass has no
                                // depth attachment

    Vec2 uniform_size;          // window size the uniform buffer holds
    sz draw_count;              // drawings uploaded by the last `upload`
}

<*
 How many copies of each host-visible buffer the pass rotates through.

 These buffers are mapped and written with a plain memcpy, and the shader reads
 them by device address for the whole of a queued frame. Writing the one copy a
 frame still on the GPU is reading tears it: the draw picks up some entries from
 the frame being submitted and some from the frame before, and a `Drawing` whose
 `kind` arrived from its successor is a glyph painted as a filled rect — white
 flecks over text and borders, worst where the display list is largest and the
 frames come fastest. So each upload goes to a different copy from the last.

 Two suffices for a host that keeps two frames in flight, which is what
 `Renderer` does. The contract a host has to keep, whatever its depth:

 - one `upload` per submitted frame, and
 - before calling it, wait for the frame CANVAS_SLOTS submissions back.

 With N copies, the frame that last wrote the copy `upload` is about to write is
 the one N submissions ago; waiting for it is what makes the copy free. A host
 that keeps more frames in flight than this must raise it to match.
*>
const CANVAS_SLOTS = 2;

// Initial GPU buffer capacities, per slot. Buffers are sized by what the UI
// actually draws: whenever an upload outgrows its buffer, the buffer is
// reallocated at the next power of two (see ensure_capacity).
const INITIAL_DRAWINGS = 64;
const INITIAL_TRANSFORMS = 16;
const INITIAL_CLIPS = 16;

<*
 Builds the buffers and texture array for a canvas pass.

 The pipeline itself is built lazily on the first `upload`, and rebuilt whenever
 the texture count changes, because the sampler-array binding is sized by it.

 @param device : `The host's device. Borrowed — free destroys only what this pass created.`
 @param allocator : `The host's allocator. Borrowed, and must outlive the pass. It needs MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT.`
 @param queue : `A graphics queue, used for the one-shot uploads that move image data.`
 @param color_format : `Format of the color attachment the pass will draw into.`
 @param depth_format : `Format of the depth attachment, or FORMAT_UNDEFINED when the host's pass has none. cui never tests or writes depth; this only has to match the pass it is recorded into.`
 @param window_size : `Logical size of the surface, in the same pixels the Ui lays out in.`
*>
fn CanvasPass? new_canvas_pass(Device device, vk::MemoryAllocator* allocator, vk::DeviceQueue queue,
                   vk::Format color_format, vk::Format depth_format, Vec2 window_size)
{
    CanvasPass pass = {
        .device = device,
        .queue = queue,
        .allocator = allocator,
        .color_format = color_format,
        .depth_format = depth_format,
        .camera = camera::new(eye: {0.0, 0.0, 1.0}, aspect: window_size.x / window_size.y,
                              min_zoom: 0.1, max_zoom: 10),
        .uniform_size = window_size,
    };

    // 1x1 white placeholder in texture slot 1 so the sampler-array binding is
    // never empty; user images get their handles from load_image/load_pixels.
    char[4] white_pixel = { 255, 255, 255, 255 };
    vk::Image white_image;
    pass.textures.load_rgba(white_pixel[..], 1, 1, allocator, queue, &white_image)!;
    pass.texture_images.push(white_image);

    // Slang's cbuffer matrix layout reads column-major bytes, which is exactly
    // how Matrix4f stores them, so the matrices go up as-is — no transpose
    // anywhere. A matrix filled row-major collapses clip w to 0.
    ShaderUniforms uniform_data = {
        pass.camera.perspective,
        pass.camera.ui_view(),
        window_size,
    };

    // Retained display list + transform palette + clip list, one copy per slot.
    // The copies are independent buffers rather than offsets into one, so that
    // growing the copy this frame outgrew leaves the others — and what they
    // already hold — alone.
    for (uint i = 0; i < CANVAS_SLOTS; i++) {
        pass.uniform_buffers[i] = vk::new_buffer(
            allocator,
            usage: BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
            data: &uniform_data,
            data_size: ShaderUniforms::size,
        )!;

        pass.canvas_buffers[i] = vk::new_buffer(
            allocator,
            usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
            data: null,
            data_size: Drawing::size * INITIAL_DRAWINGS,
        )!;

        pass.transform_buffers[i] = vk::new_buffer(
            allocator,
            usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
            data: null,
            data_size: Matrix4f::size * INITIAL_TRANSFORMS,
        )!;

        pass.clip_buffers[i] = vk::new_buffer(
            allocator,
            usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
            data: null,
            data_size: ClipEntry::size * INITIAL_CLIPS,
        )!;
    }

    // Ahead of every slot's 0, so the first upload into each fills it whatever
    // the canvas's dirty flags happen to say.
    pass.drawings_revision = 1;
    pass.transforms_revision = 1;
    pass.clips_revision = 1;

    return pass;
}

<*
 Re-points the pass and its buffers at `allocator`.

 Every `vk::Memory` captures the allocator address it was created from, so a
 host that builds its allocator inside a struct and returns that struct by value
 leaves those pointers dangling — freeing through one reads a garbage device.
 `Renderer` does exactly that, and calls this at the top of every frame.

 A host whose allocator never moves does not need this.
*>
fn void CanvasPass.adopt(&self, vk::MemoryAllocator* allocator)
{
    self.allocator = allocator;
    for (uint i = 0; i < CANVAS_SLOTS; i++) {
        self.canvas_buffers[i].allocator = allocator;
        self.transform_buffers[i].allocator = allocator;
        self.clip_buffers[i].allocator = allocator;
        self.uniform_buffers[i].allocator = allocator;
    }
}

<*
 Flush the Ui and move everything that changed to the GPU.

 Call once per submitted frame, outside a render pass — it may idle the GPU to
 grow a buffer, and it may rebuild the pipeline when the texture count changed.

 Not safe to call until the host has waited for the frame `CANVAS_SLOTS`
 submissions back: this writes mapped memory with no barrier of any kind, and
 the copy it advances to is only free because that frame has finished with it.
 Calling it twice for one submitted frame breaks the same guarantee, since the
 second call moves on to a copy that is still in flight.

 This calls `ui.flush()` itself, bracketed by the two glyph-atlas syncs it has
 to sit between: the atlas texture must exist before the first `Painter.text`
 caches a drawing with its handle, and glyphs baked during paint must reach the
 GPU before the draw that samples them. Getting that order wrong is the classic
 embedding bug, so the order is not the host's to get wrong.

 @param ui : `The Ui to flush and upload.`
 @param window_size : `Logical surface size. Re-uploads the uniform block when it changes.`
*>
fn void? CanvasPass.upload(&self, Ui* ui, Vec2 window_size)
{
    self.sync_text(ui, true)!;
    ui.flush();
    self.sync_text(ui, false)!;

    // First frame, or textures were added since: (re)build the pipeline so the
    // sampler-array binding matches the texture count.
    if (self.pipeline_texture_count != self.textures.len()) self.rebuild_pipeline()!;

    // A different copy from the one the last upload wrote, so this write cannot
    // land in the one a queued draw is still reading. Safe only because the host
    // has already waited for the frame CANVAS_SLOTS submissions back — see there.
    self.slot = (self.slot + 1) % CANVAS_SLOTS;

    if (window_size != self.uniform_size) {
        self.camera = camera::new(eye: {0.0, 0.0, 1.0}, aspect: window_size.x / window_size.y,
                                  min_zoom: 0.1, max_zoom: 10);
        self.uniform_size = window_size;
    }
    ShaderUniforms uniform_data = { self.camera.perspective, self.camera.ui_view(), window_size };
    self.uniform_buffers[self.slot].upload(&uniform_data, ShaderUniforms::size);

    // Note the change and clear the flag whether or not this slot needs writing:
    // the flag means "changed since anyone looked", and the slots are what
    // remember who has seen what. Leaving it set would re-count one change once
    // per slot and re-upload for ever.
    Canvas* canvas = &ui.canvas;
    if (canvas.drawings_dirty) { self.drawings_revision++; canvas.drawings_dirty = false; }
    if (canvas.transforms_dirty) { self.transforms_revision++; canvas.transforms_dirty = false; }
    if (canvas.clips_dirty) { self.clips_revision++; canvas.clips_dirty = false; }

    // Re-upload only what this slot is behind on, growing its buffers to
    // whatever the UI actually produced. A slot brought up to the current
    // revision holds the current lists, so the counts below describe it too.
    self.draw_count = canvas.drawings.len();

    if (self.drawings_in_slot[self.slot] != self.drawings_revision) {
        if (self.draw_count > 0) {
            self.ensure_capacity(&self.canvas_buffers[self.slot], Drawing::size * self.draw_count)!;
            self.canvas_buffers[self.slot].upload(canvas.drawings.entries, Drawing::size * self.draw_count);
        }
        self.drawings_in_slot[self.slot] = self.drawings_revision;
    }

    if (self.transforms_in_slot[self.slot] != self.transforms_revision) {
        sz transform_count = canvas.transforms.len();
        if (transform_count > 0) {
            self.ensure_capacity(&self.transform_buffers[self.slot], Matrix4f::size * transform_count)!;
            self.transform_buffers[self.slot].upload(canvas.transforms.entries, Matrix4f::size * transform_count);
        }
        self.transforms_in_slot[self.slot] = self.transforms_revision;
    }

    if (self.clips_in_slot[self.slot] != self.clips_revision) {
        sz clip_count = canvas.clips.len();
        if (clip_count > 0) {
            self.ensure_capacity(&self.clip_buffers[self.slot], ClipEntry::size * clip_count)!;
            self.clip_buffers[self.slot].upload(canvas.clips.entries, ClipEntry::size * clip_count);
        }
        self.clips_in_slot[self.slot] = self.clips_revision;
    }
}

<*
 Record the interface into a command buffer, inside an already-begun render pass.

 Binds its own pipeline, pushes its own descriptors and push constants, and sets
 no dynamic state beyond what it is given — the host's viewport and scissor are
 used as they stand, so scissoring the UI to a sub-rect is the host's call.

 A frame with nothing to draw records nothing.

 @param command_buffer : `Inside a begun render pass whose attachments match the formats this pass was created with.`
 @param extent : `Unused today; taken so a host that scissors per pass has somewhere obvious to say so, and so the signature matches SceneRecorder.`
*>
fn void? CanvasPass.record(&self, CommandBuffer command_buffer, Extent2D extent)
{
    if (self.pipeline_texture_count == 0 || self.draw_count == 0) return;

    vk::cmdBindPipeline(command_buffer, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.pipeline);

    // Descriptor writes are built here rather than cached so the pBufferInfo /
    // pImageInfo pointers reference data that is alive at record time.
    DescriptorBufferInfo[1] uniform_info = {
        { .buffer = self.uniform_buffers[self.slot].buffer, .offset = 0, .range = ShaderUniforms::size },
    };
    WriteDescriptorSet[2] descriptor_writes = {
        vk::writeDescriptorSet()
        .setDescriptorType(DESCRIPTOR_TYPE_UNIFORM_BUFFER)
        .setDstBinding(0)
        .setBufferInfo(uniform_info[..]),
        vk::writeDescriptorSet()
        .setDstBinding(1)
        .setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
        .setImageInfo(self.textures.array_view()),
    };
    vk::cmdPushDescriptorSetKHR(command_buffer, PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline.pipeline_layout, 0, descriptor_writes.len, &descriptor_writes[0]);

    // The slot `upload` just filled. Addresses are pushed every frame anyway, so
    // a slot whose buffer moved under ensure_capacity needs nothing extra said.
    ShaderPushConstants constant_data = {
        .drawings = self.canvas_buffers[self.slot].address,
        .transforms = self.transform_buffers[self.slot].address,
        .clips = self.clip_buffers[self.slot].address,
    };
    vk::cmdPushConstants(command_buffer, self.pipeline.pipeline_layout,
        SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT, 0, ShaderPushConstants::size, &constant_data);

    // The whole canvas in one instanced draw; the vertex shader indexes
    // drawings by SV_InstanceID.
    vk::cmdDraw(command_buffer, 6, (uint)self.draw_count, 0, 0);
}

<*
 Uploads an image file (png/jpg) to the GPU and returns the handle to reference
 it with (`RectStyle.texture` / `CircleStyle.texture`).

 Textures can be loaded at any time; ones loaded between frames become valid on
 the next `upload`, which rebuilds the pipeline for the new sampler count.

 @param path : `Path to a png or jpg file.`
 @return `The texture handle.`
*>
fn cui::Texture? CanvasPass.load_image(&self, String path)
{
    vk::Image image;
    self.textures.loadPath(path, self.allocator, self.queue, &image)!;
    self.texture_images.push(image);
    return (cui::Texture)self.textures.len();
}

<*
 Uploads raw RGBA8 pixels (a generated atlas, say) and returns the handle to
 reference them with.

 @param rgba : `Tightly packed RGBA8 pixels, width * height * 4 bytes.`
 @param width : `Image width in pixels.`
 @param height : `Image height in pixels.`
 @require rgba.len >= (usz)width * height * 4 : `The pixel buffer is smaller than width * height * 4 bytes.`
 @return `The texture handle.`
*>
fn cui::Texture? CanvasPass.load_pixels(&self, char[] rgba, uint width, uint height)
{
    vk::Image image;
    self.textures.load_rgba(rgba, width, height, self.allocator, self.queue, &image)!;
    self.texture_images.push(image);
    return (cui::Texture)self.textures.len();
}

<*
 Destroys everything this pass created. The device, queue and allocator are the
 host's and are left alone.
*>
fn void CanvasPass.free(&self)
{
    self.device.waitIdle();

    for (uint i = 0; i < CANVAS_SLOTS; i++) {
        self.uniform_buffers[i].free();
        self.canvas_buffers[i].free();
        self.transform_buffers[i].free();
        self.clip_buffers[i].free();
    }

    // Teardown is strictly inside-out, and each step here outlives the one
    // before it: a view reads an image, an image is bound to allocator memory.
    foreach (&texture : self.textures) texture.free(self.device);
    foreach (image : self.texture_images) image.free(self.device);

    self.textures.free();
    self.texture_images.free();

    // RenderState.free also frees the descriptor layout it holds.
    if (self.pipeline_texture_count > 0) self.pipeline.free(self.device);

    *self = {};
}

<*
 Keeps the GPU copy of the Ui's glyph atlas in step with the CPU one.

 Before `flush` (with `creating` true): once the Ui has fonts, the atlas texture
 is created up front — paint caches drawings with the texture handle baked in,
 so the handle must exist before the first `Painter.text` runs. After `flush`
 (`creating` false): re-upload the pixels whenever glyph baking marked them
 dirty, so glyphs painted this frame are sampled this frame.

 @param ui : `The Ui whose text system to sync.`
 @param creating : `True for the pre-flush texture-creation step.`
*>
fn void? CanvasPass.sync_text(&self, Ui* ui, bool creating)
{
    cui::TextSystem* text = &ui.text;
    if (creating) {
        if (text.texture == cui::NO_TEXTURE && text.fonts.len() > 0) {
            self.textures.load_atlas(text.atlas, text.atlas_width, text.atlas_height,
                self.allocator, self.queue, &self.atlas_image)!;
            self.texture_images.push(self.atlas_image);
            text.texture = (cui::Texture)self.textures.len();
            text.dirty = false;
        }
        return;
    }
    if (text.dirty && text.texture != cui::NO_TEXTURE) {
        vulkan::update_atlas_image(self.atlas_image, text.atlas, text.atlas_width, text.atlas_height,
            false, self.allocator, self.queue)!;
        text.dirty = false;
    }
}

<*
 (Re)creates the descriptor layout and pipeline for the current texture count.

 Runs before the first frame and again whenever `load_image` grew the texture
 array; the GPU is idled first, since in-flight frames still use the old
 pipeline.
*>
fn void? CanvasPass.rebuild_pipeline(&self)
{
    if (self.pipeline_texture_count > 0) {
        self.device.waitIdle();
        self.pipeline.free(self.device);    // also frees the descriptor layout
    }

    self.descriptor_layout = vk::descriptorSetLayoutCreateInfo()
    .setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT)
    .setBindings({
        {
            .binding = 0,
            .descriptorType = DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT
        },
        {
            .binding = 1,
            .descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = (uint)self.textures.len(),
            .stageFlags = SHADER_STAGE_FRAGMENT_BIT
        },
    }).build(self.device)!;

    self.pipeline = (RenderState) {
        .descriptor_layout = self.descriptor_layout,
        .shaders = {
            { .spirv = cui::shader_spirv[..], .entry = cui::SHADER_VERTEX_ENTRY, .stage = SHADER_STAGE_VERTEX_BIT },
            { .spirv = cui::shader_spirv[..], .entry = cui::SHADER_FRAGMENT_ENTRY, .stage = SHADER_STAGE_FRAGMENT_BIT },
        },
        .cull_mode = CULL_MODE_NONE,
        .front_face = FRONT_FACE_COUNTER_CLOCKWISE,
        .topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        // The UI composites over whatever is already there, in paint order.
        // Leaving depth alone is what lets a host draw 3D underneath it.
        .enable_depth = false,
        .push_constants = {
            {
                .offset = 0,
                .size = ShaderPushConstants::size,
                .stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
            },
        },
        .dynamic_states = {
            DYNAMIC_STATE_VIEWPORT,
            DYNAMIC_STATE_SCISSOR,
        },
        .blend_attachments = {
            {
                .colorWriteMask =
                    COLOR_COMPONENT_R_BIT |
                    COLOR_COMPONENT_G_BIT |
                    COLOR_COMPONENT_B_BIT |
                    COLOR_COMPONENT_A_BIT,
                .blendEnable = vk::TRUE,
                .srcColorBlendFactor = BLEND_FACTOR_SRC_ALPHA,
                .dstColorBlendFactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .colorBlendOp = BLEND_OP_ADD,
                .srcAlphaBlendFactor = BLEND_FACTOR_ONE,
                .dstAlphaBlendFactor = BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
                .alphaBlendOp = BLEND_OP_ADD,
            }
        },
        .color_attachments = { self.color_format },
        .depth_format = self.depth_format,
    }.build(self.device)!;

    self.pipeline_texture_count = self.textures.len();
}

<*
 Grows a device-address buffer to fit `needed` bytes, doubling so growth is rare.

 The GPU is idled first: frames in flight may still read the old buffer. The
 address is re-pushed every frame, so nothing else needs to know it moved.

 @param buffer : `The buffer to grow in place. Freed and reallocated when it is too small.`
 @param needed : `The size the next upload needs, in bytes.`
*>
fn void? CanvasPass.ensure_capacity(&self, vk::Memory* buffer, sz needed)
{
    if (needed <= buffer.size) return;

    sz new_size = buffer.size > 0 ? buffer.size : 1024;
    while (new_size < needed) new_size *= 2;

    self.device.waitIdle();
    buffer.free();
    *buffer = vk::new_buffer(
        self.allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: new_size,
    )!;
}
