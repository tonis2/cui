module cui;
import std::collections::list;
import std::math;
import std::math::matrix;

// SDF primitive kinds, dispatched in the fragment shader.
const uint DRAWING_RECT = 0;

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
    uint kind;
    int texture;            // Texture handle as raw int; 0 = untextured
    float border_width;
    uint transform_id;      // index into Canvas.transforms

    Vec2 size;
    Vec2 corner;

    Vec4 border_radius;
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
