// CUI shader: every UI drawing is one instance of a unit quad, shaped in the
// fragment stage by an SDF picked via Drawing.kind. Drawings, the transform
// palette and the clip list are read through buffer device addresses; one
// instanced draw call renders the whole canvas.
//
// SDF code adapted from
// https://thebookofshaders.com/edit.php?log=160414041142
// https://www.shadertoy.com/view/tltXDl

// Must match cui::Drawing in render/canvas.c3 (scalar layout).
struct Drawing
{
    uint kind;
    int tex_id;             // 0 = none, else textures[tex_id - 1]
    float border_width;     // px; LINE/ARC thickness, SHADOW blur
    uint transform_id;      // index into PushData.transforms

    float2 size;            // quad bounds in pixels
    float2 corner;

    float4 params;          // per-kind data, see cui::Drawing
    float4 color;
    float4 border_color;

    uint clip_id;           // index into PushData.clips; 0 = unclipped
    uint reserved0;
    uint reserved1;
    uint reserved2;
};

// Drawing kinds — must match cui::DrawingKind in render/canvas.c3.
static const uint KIND_RECT = 0;
static const uint KIND_ELLIPSE = 1;
static const uint KIND_LINE = 2;
static const uint KIND_ARC = 3;
static const uint KIND_SHADOW = 4;
static const uint KIND_GLYPH = 5;

static const float TAU = 6.28318530718;

// The transform palette is read as raw float4 vectors, 4 per matrix. C3's
// Matrix4f stores column-major, so each float4 is one column of the logical
// matrix; multiplying with the position as a ROW vector (mul(v, M)) applies
// the intended M*v without an explicit transpose. Reading through float4x4*
// instead makes Slang wrap the matrix in a MatrixStorage struct that loads
// scrambled on this driver stack - avoid it.
struct PushData
{
    Drawing* drawings;
    float4* transforms;
    float4* clips;          // 5 float4s per entry, see cui::ClipEntry
};
[vk_push_constant] const PushData push_constant;

[vk_binding(0, 0)]
cbuffer Uniforms
{
    float4x4 projection;
    float4x4 view;
    float2 resolution;
}

[vk_binding(1, 0)]
Sampler2D textures[];

// Unit quad the SDF primitives are drawn on.
static const float2 QUAD[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
    float2(0.0, 0.0),
};

struct VertexOutput
{
    float2 tex_pos;
    float2 screen_pos;      // UI pixels after the transform: what clips from other slots compare
    int draw_id;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    Drawing item = push_constant.drawings[iid];
    float2 vertex = QUAD[vid];

    // Transforms are in UI pixels (see cui transform.c3), so the palette
    // matrix is applied before the position is normalized to the resolution.
    float2 vertex_px = vertex * item.size + item.corner;

    uint base = item.transform_id * 4;
    float4x4 model = float4x4(
        push_constant.transforms[base + 0],
        push_constant.transforms[base + 1],
        push_constant.transforms[base + 2],
        push_constant.transforms[base + 3]);
    float4 world_px = mul(float4(vertex_px, 0.0, 1.0), model);
    // z keeps the scale it had when the palette worked in normalized units, so
    // a card rotated out of the plane foreshortens as it always did.
    float4 world = float4(world_px.xy / resolution, world_px.z / resolution.x, world_px.w);

    VertexOutput output;
    output.tex_pos = vertex;
    output.screen_pos = world_px.xy / world_px.w;
    output.draw_id = int(iid);
    output.sv_position = mul(projection, mul(view, world)) + float4(-1.0, -1.0, 0.0, 0.0);
    return output;
}

// All SDFs work in quad-centered pixel coordinates, so distances, widths and
// radii are pixels. The antialiasing band is one SCREEN pixel: `aa` below is
// half a screen pixel measured in those coordinates, which is 0.5 untransformed
// and shrinks or grows with a zoom, so edges stay crisp at any scale.

// Half a screen pixel in the drawing's own pixels, from how fast its
// coordinates change across the screen (the square root of the Jacobian's
// determinant: exact for any scale and rotation).
float half_pixel(float2 p)
{
    float2 dx = ddx(p);
    float2 dy = ddy(p);
    float area = abs(dx.x * dy.y - dx.y * dy.x);
    return 0.5 * max(sqrt(area), 1e-4);
}

// Coverage of an axis-aligned screen box at a screen position, half a screen
// pixel of AA either side of the edge.
float box_factor(float4 box, float2 screen_pos)
{
    float2 d2 = max(box.xy - screen_pos, screen_pos - box.zw);
    float d = max(d2.x, d2.y);
    return 1.0 - smoothstep(-0.5, 0.5, d);
}

// Rounded box; radius = per-corner px {top-left, top-right, bottom-right,
// bottom-left} (y points down), clamped to what the box can fit.
float sd_round_box(float2 p, float2 half_size, float4 radius)
{
    float r = (p.x < 0.0) ? ((p.y < 0.0) ? radius.x : radius.w)
                          : ((p.y < 0.0) ? radius.y : radius.z);
    r = min(r, min(half_size.x, half_size.y));
    float2 q = abs(p) - half_size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Clip factor for a fragment: 1 = keep, 0 = clipped, with the same one
// screen-pixel AA band as the shape edges. A drawing in the clip's own
// transform slot is compared in PRE-transform UI space (corner is absolute
// after emit), exactly and with the rounded corners, so a clip moves with its
// transform. A drawing under another transform — content zoomed inside a
// clipping viewport — is compared on screen against the clip's screen box.
// Either way the enclosing clips from other slots (`outer`) apply on screen.
float clip_factor(Drawing item, float2 tex_pos, float2 screen_pos, float aa)
{
    if (item.clip_id == 0) return 1.0;
    uint at = item.clip_id * 5;
    float4 rect   = push_constant.clips[at + 0];
    float4 radii  = push_constant.clips[at + 1];
    float4 screen = push_constant.clips[at + 2];
    float4 outer  = push_constant.clips[at + 3];
    uint slot     = asuint(push_constant.clips[at + 4].x);

    float keep;
    if (slot == item.transform_id)
    {
        float2 frag_ui   = item.corner + tex_pos * item.size;
        float2 center    = (rect.xy + rect.zw) * 0.5;
        float2 half_size = max((rect.zw - rect.xy) * 0.5, float2(0.0));
        float d = sd_round_box(frag_ui - center, half_size, radii);
        keep = 1.0 - smoothstep(-aa, aa, d);
    }
    else
    {
        keep = box_factor(screen, screen_pos);
    }
    return keep * box_factor(outer, screen_pos);
}

// Gradient-normalized ellipse approximation (exact for circles).
float sd_ellipse(float2 p, float2 r)
{
    float k2 = length(p / (r * r));
    if (k2 == 0.0) return -min(r.x, r.y);   // exact center: 0/0 otherwise
    float k1 = length(p / r);
    return k1 * (k1 - 1.0) / k2;
}

float sd_segment(float2 p, float2 a, float2 b)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// Distance to the centerline of an arc of radius ra spanning sweep radians
// from start (0 = +x, increasing clockwise on screen since y points down).
float sd_arc(float2 p, float ra, float start, float sweep)
{
    if (sweep >= TAU) return abs(length(p) - ra);
    float mid = start + sweep * 0.5;
    // Rotate into the frame where the arc midpoint lies on +y.
    float2 q = float2(dot(p, float2(-sin(mid), cos(mid))),
                      dot(p, float2(cos(mid), sin(mid))));
    q.x = abs(q.x);
    float2 sc = float2(sin(sweep * 0.5), cos(sweep * 0.5));
    return (sc.y * q.x > sc.x * q.y) ? length(q - sc * ra) : abs(length(q) - ra);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    Drawing item = push_constant.drawings[input.draw_id];

    float2 p = (input.tex_pos - 0.5) * item.size;   // quad-centered pixels
    float2 half_size = item.size * 0.5;
    // Measured before the switch: derivatives need every fragment of the quad.
    float aa = half_pixel(p);

    float dist;
    float border = 0.0;         // border band width; 0 = no border shading
    float4 fill = item.color;

    switch (item.kind)
    {
    case KIND_ELLIPSE:
    {
        float2 radii = item.params.xy;
        dist = sd_ellipse(p, radii);
        border = item.border_width;
        if (item.tex_id > 0) fill = textures[item.tex_id - 1].Sample(p / (radii * 2.0) + 0.5);
        break;
    }
    case KIND_LINE:
        dist = sd_segment(p, item.params.xy, item.params.zw) - item.border_width * 0.5;
        break;
    case KIND_ARC:
        dist = sd_arc(p, item.params.x, item.params.y, item.params.z) - item.border_width * 0.5;
        break;
    case KIND_SHADOW:
    {
        float blur = max(item.border_width, 0.5);
        float4 shadow = item.color;
        shadow.a *= 1.0 - smoothstep(-blur, blur, sd_round_box(p, half_size - blur, item.params));
        shadow.a *= clip_factor(item, input.tex_pos, input.screen_pos, aa);
        return shadow;
    }
    case KIND_GLYPH:
    {
        // params = SDF atlas UV rect; the sampled value maps distance with
        // 0.5 at the glyph edge, higher inside. fwidth-derived band width
        // keeps the edge ~1 screen px under any quad size or transform
        // (the same thing `half_pixel` measures for the other shapes).
        if (item.tex_id <= 0) return float4(0.0);
        float2 uv = item.params.xy + input.tex_pos * (item.params.zw - item.params.xy);
        float sd = textures[item.tex_id - 1].Sample(uv).r;
        float band = max(fwidth(sd), 1e-4);
        float4 text = item.color;
        text.a *= smoothstep(0.5 - band, 0.5 + band, sd);
        text.a *= clip_factor(item, input.tex_pos, input.screen_pos, aa);
        return text;
    }
    default: // KIND_RECT
        dist = sd_round_box(p, half_size, item.params);
        border = item.border_width;
        if (item.tex_id > 0) fill = textures[item.tex_id - 1].Sample(input.tex_pos);
        break;
    }

    // Border drawn inside the shape edge; both edges get the AA band.
    float4 color = fill;
    if (border > 0.0)
    {
        color = lerp(fill, item.border_color, smoothstep(-border - aa, -border + aa, dist));
    }
    color.a *= 1.0 - smoothstep(-aa, aa, dist);
    color.a *= clip_factor(item, input.tex_pos, input.screen_pos, aa);
    return color;
}
