module cui;
import std::collections::list;
import std::math;
import std::math::matrix;

<*
 SDF primitive kinds, dispatched in the fragment shader. The values are the GPU
 contract: they must match the KIND_* constants in shader.slang.
*>
constdef DrawingKind : inline uint
{
    RECT = 0,
    ELLIPSE = 1,
    LINE = 2,
    ARC = 3,
    SHADOW = 4,
}

<*
 Opaque texture handle referenced by drawings; 0 = untextured. Handles come from
 the backend that consumes the canvas — with the built-in renderer, from
 `cui::vulkan` `Renderer.load_image` / `load_pixels`. The value is a 1-based
 index into the sampler array of the backend (shader binding 1).
*>
typedef Texture = int;

<*
 The untextured handle: a drawing carrying this samples no image.
*>
const Texture NO_TEXTURE = (Texture)0;

<*
 One GPU-side primitive, produced by Painter and consumed by the renderer.

 Field order and sizes must match `struct Drawing` in shader.slang (scalar
 layout): keep 4-byte fields in groups of four so the Vec2/Vec4 members land on
 the same offsets on both sides.
*>
struct Drawing {
    DrawingKind kind;
    int texture;            // Texture handle as raw int; 0 = untextured
    float border_width;     // px; LINE/ARC store their thickness here, SHADOW its blur
    uint transform_id;      // index into Canvas.transforms

    Vec2 size;              // quad bounds in pixels
    Vec2 corner;

    Vec4 params;            // per-kind data (pixels / radians), filled by Painter:
                            //   RECT/SHADOW  corner radii {TL, TR, BR, BL}
                            //   ELLIPSE      radii in xy
                            //   LINE         endpoints {a.x, a.y, b.x, b.y}, quad-centered
                            //   ARC          {radius, start, sweep, -}
    Vec4 color;
    Vec4 border_color;

    uint clip_id;           // index into Canvas.clips, assigned by emit; 0 = unclipped
    uint reserved0;         // pad to a full group of four (see the layout rule above)
    uint reserved1;
    uint reserved2;
}

<*
 One clip region, in absolute PRE-transform UI pixels: the fragment shader
 compares the UI-space position a drawing was emitted at, so a clip travels with
 any palette transform applied on top (Flutter-consistent) instead of staying
 screen-fixed. Read by the shader as two raw float4s per entry — no matrices, no
 structs (see the BDA note in shader.slang).
*>
struct ClipEntry {
    Vec4 rect;              // {min.x, min.y, max.x, max.y}
    Vec4 radii;             // per-corner px {TL, TR, BR, BL}
}

<*
 Slot 0 = "no clip". The shader early-outs on `clip_id == 0`; the huge rect is
 belt and braces.
*>
const ClipEntry NO_CLIP_ENTRY = { .rect = { -1e9, -1e9, 1e9, 1e9 }, .radii = {} };

<*
 Everything the renderer consumes per frame: the retained display list, the
 transform palette and the clip list.

 Slot 0 of the palette is always identity; elements without their own transform
 inherit whatever slot their ancestor uses. The clip list is rebuilt on every
 emit (clip rects depend on absolute origins); slot 0 is always `NO_CLIP_ENTRY`.
 The `*_dirty` flags tell the backend which of the three buffers to re-upload.
*>
struct Canvas {
    List{Drawing} drawings;
    List{Matrix4f} transforms;
    List{ClipEntry} clips;
    bool drawings_dirty;
    bool transforms_dirty;
    bool clips_dirty;
}

<*
 Seeds the identity transform and the no-clip entry in slot 0 of each list.
 Called by `new_ui`.
*>
fn void Canvas.init(&self)
{
    self.transforms.push(matrix::IDENTITY4);
    self.clips.push(NO_CLIP_ENTRY);
    self.drawings_dirty = true;
    self.transforms_dirty = true;
    self.clips_dirty = true;
}

<*
 Frees the three lists. Called by `Ui.free`.
*>
fn void Canvas.free(&self)
{
    self.drawings.free();
    self.transforms.free();
    self.clips.free();
}
