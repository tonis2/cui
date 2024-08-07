#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_nonuniform_qualifier : require

#include "types.glsl"

layout(location = 0) out vec2 texture_pos;

// Default vertices, for drawing the SDF primitives on
vec2 vertices[6] = vec2[](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0),
    vec2(0.0, 0.0)
);

void main() {
    CanvasBuffer canvas_item = canvas_buffer[draw_index];
    vec2 vertex = vertices[gl_VertexIndex];

    vec2 corner = canvas_item.corner / resolution;
    vec2 size = canvas_item.size / resolution;

    vec2 vertex_pos = (vertex * size + corner);

    texture_pos = vertex;

    gl_Position = projection * view * canvas_item.transform * vec4(vertex_pos, 0.0, 1.0) + vec4(-1.0, -1.0, 0.0, 0.0);
}