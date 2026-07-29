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

    vk::Memory canvas_buffer;
    vk::Memory transform_buffer;
    vk::Memory clip_buffer;
    vk::Memory uniform_buffer;

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

// Initial GPU buffer capacities. Buffers are sized by what the UI actually
// draws: whenever an upload outgrows its buffer, the buffer is reallocated at
// the next power of two (see ensure_capacity).
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

    pass.uniform_buffer = vk::new_buffer(
        allocator,
        usage: BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: &uniform_data,
        data_size: ShaderUniforms::size,
    )!;

    // Retained display list + transform palette + clip list; re-uploaded only
    // when the widget layer marks them dirty.
    pass.canvas_buffer = vk::new_buffer(
        allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: Drawing::size * INITIAL_DRAWINGS,
    )!;

    pass.transform_buffer = vk::new_buffer(
        allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: Matrix4f::size * INITIAL_TRANSFORMS,
    )!;

    pass.clip_buffer = vk::new_buffer(
        allocator,
        usage: BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_CACHED_BIT,
        data: null,
        data_size: ClipEntry::size * INITIAL_CLIPS,
    )!;

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
    self.canvas_buffer.allocator = allocator;
    self.transform_buffer.allocator = allocator;
    self.clip_buffer.allocator = allocator;
    self.uniform_buffer.allocator = allocator;
}

<*
 Flush the Ui and move everything that changed to the GPU.

 Call once per frame, outside a render pass — it may idle the GPU to grow a
 buffer, and it may rebuild the pipeline when the texture count changed.

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

    if (window_size != self.uniform_size) {
        self.camera = camera::new(eye: {0.0, 0.0, 1.0}, aspect: window_size.x / window_size.y,
                                  min_zoom: 0.1, max_zoom: 10);
        self.uniform_size = window_size;
    }
    ShaderUniforms uniform_data = { self.camera.perspective, self.camera.ui_view(), window_size };
    self.uniform_buffer.upload(&uniform_data, ShaderUniforms::size);

    // Re-upload only what changed since the last frame, growing the buffers to
    // whatever the UI actually produced.
    Canvas* canvas = &ui.canvas;
    self.draw_count = canvas.drawings.len();

    if (canvas.drawings_dirty) {
        if (self.draw_count > 0) {
            self.ensure_capacity(&self.canvas_buffer, Drawing::size * self.draw_count)!;
            self.canvas_buffer.upload(canvas.drawings.entries, Drawing::size * self.draw_count);
        }
        canvas.drawings_dirty = false;
    }

    if (canvas.transforms_dirty) {
        sz transform_count = canvas.transforms.len();
        if (transform_count > 0) {
            self.ensure_capacity(&self.transform_buffer, Matrix4f::size * transform_count)!;
            self.transform_buffer.upload(canvas.transforms.entries, Matrix4f::size * transform_count);
        }
        canvas.transforms_dirty = false;
    }

    if (canvas.clips_dirty) {
        sz clip_count = canvas.clips.len();
        if (clip_count > 0) {
            self.ensure_capacity(&self.clip_buffer, ClipEntry::size * clip_count)!;
            self.clip_buffer.upload(canvas.clips.entries, ClipEntry::size * clip_count);
        }
        canvas.clips_dirty = false;
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
        { .buffer = self.uniform_buffer.buffer, .offset = 0, .range = ShaderUniforms::size },
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

    ShaderPushConstants constant_data = {
        .drawings = self.canvas_buffer.address,
        .transforms = self.transform_buffer.address,
        .clips = self.clip_buffer.address,
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

    self.uniform_buffer.free();
    self.canvas_buffer.free();
    self.transform_buffer.free();
    self.clip_buffer.free();

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
