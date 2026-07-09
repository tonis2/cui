module cui;
import std::collections::list;
import std::math;
import std::math::matrix;

// SDF primitive kinds, dispatched in the fragment shader. The values are the
// GPU contract: they must match the KIND_* constants in shader.slang.
constdef DrawingKind : inline uint
{
    RECT = 0,
    ELLIPSE = 1,
    LINE = 2,
    ARC = 3,
    SHADOW = 4,
}

// Opaque texture handle referenced by drawings; 0 = untextured. Handles come
// from the backend that consumes the canvas — with the built-in renderer,
// from cui::vulkan Renderer.load_image / load_pixels. The value is a 1-based
// index into the backend's sampler array (shader binding 1).
typedef Texture = int;
const Texture NO_TEXTURE = (Texture)0;

// One GPU-side primitive. Field order and sizes must match struct Drawing in
// shader.slang (scalar layout): keep 4-byte fields in groups of four so the
// Vec2/Vec4 members land on the same offsets on both sides.
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
}

// Everything the renderer consumes per frame: the retained display list and
// the transform palette. Slot 0 of the palette is always identity; elements
// without their own transform inherit whatever slot their ancestor uses.
struct Canvas {
    List{Drawing} drawings;
    List{Matrix4f} transforms;
    bool drawings_dirty;
    bool transforms_dirty;
}

fn void Canvas.init(&self)
{
    self.transforms.push(matrix::IDENTITY4);
    self.drawings_dirty = true;
    self.transforms_dirty = true;
}

fn void Canvas.free(&self)
{
    self.drawings.free();
    self.transforms.free();
}
