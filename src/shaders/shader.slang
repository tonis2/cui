// CUI shader: every UI drawing is one instance of a unit quad, shaped in the
// fragment stage by an SDF picked via Drawing.kind. Drawings and the transform
// palette are read through buffer device addresses; one instanced draw call
// renders the whole canvas.
//
// SDF code adapted from
// https://thebookofshaders.com/edit.php?log=160414041142
// https://www.shadertoy.com/view/tltXDl

// Must match cui::Drawing in canvas.c3 (scalar layout).
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
};

// Drawing kinds — must match cui::DrawingKind in canvas.c3.
static const uint KIND_RECT = 0;
static const uint KIND_ELLIPSE = 1;
static const uint KIND_LINE = 2;
static const uint KIND_ARC = 3;
static const uint KIND_SHADOW = 4;

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
    int draw_id;
    float4 sv_position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID, uint iid : SV_InstanceID)
{
    Drawing item = push_constant.drawings[iid];
    float2 vertex = QUAD[vid];

    float2 corner = item.corner / resolution;
    float2 size = item.size / resolution;
    float2 vertex_pos = vertex * size + corner;

    uint base = item.transform_id * 4;
    float4x4 model = float4x4(
        push_constant.transforms[base + 0],
        push_constant.transforms[base + 1],
        push_constant.transforms[base + 2],
        push_constant.transforms[base + 3]);
    float4 world = mul(float4(vertex_pos, 0.0, 1.0), model);

    VertexOutput output;
    output.tex_pos = vertex;
    output.draw_id = int(iid);
    output.sv_position = mul(projection, mul(view, world)) + float4(-1.0, -1.0, 0.0, 0.0);
    return output;
}

// All SDFs work in quad-centered pixel coordinates, so distances, widths and
// radii are pixels and antialiasing is a fixed 1px band.

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
        return shadow;
    }
    default: // KIND_RECT
        dist = sd_round_box(p, half_size, item.params);
        border = item.border_width;
        if (item.tex_id > 0) fill = textures[item.tex_id - 1].Sample(input.tex_pos);
        break;
    }

    // Border drawn inside the shape edge; both edges get the 1px AA band.
    float4 color = fill;
    if (border > 0.0)
    {
        color = lerp(fill, item.border_color, smoothstep(-border - 0.5, -border + 0.5, dist));
    }
    color.a *= 1.0 - smoothstep(-0.5, 0.5, dist);
    return color;
}
