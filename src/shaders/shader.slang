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
    float border_width;
    uint transform_id;      // index into PushData.transforms

    float2 size;
    float2 corner;

    float4 border_radius;
    float4 color;
    float4 border_color;
};

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

float rounded_box_sdf(float2 center, float2 size, float4 radius)
{
    radius.xy = (center.x > 0.0) ? radius.xy : radius.zw;
    radius.x = (center.y > 0.0) ? radius.x : radius.y;

    float2 q = abs(center) - size + radius.x;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius.x;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target
{
    Drawing item = push_constant.drawings[input.draw_id];

    float border_size = item.border_width / 100.0;
    float2 widget_size = float2(0.5, 0.5) - float2(border_size, border_size);

    float dist = rounded_box_sdf(input.tex_pos - border_size - widget_size, widget_size, item.border_radius / 10.0);

    float4 color = float4(0.5, 0.5, 0.5, 0.0);
    if (dist < 0.0)
    {
        color = item.tex_id > 0 ? textures[item.tex_id - 1].Sample(input.tex_pos) : item.color;
    }

    float border_alpha = smoothstep(border_size - 0.002, border_size, abs(dist));
    return lerp(item.border_color, color, border_alpha);
}
