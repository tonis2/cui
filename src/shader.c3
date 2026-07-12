module cui;
import std::math;

// The GPU contract for embedding cui in an existing Vulkan engine.
//
// cui core produces a Canvas (drawings + transform palette + clips, see
// canvas.c3); this file provides everything a backend needs to render it: the
// compiled SPIR-V and the CPU-side layouts of the shader's uniform block and
// push constants. The reference backend lives in src/vulkan/ — engines with
// their own device/swapchain implement the same few steps against these
// exports. See "Embedding in a Vulkan engine" in README.md.

<*
 Compiled SPIR-V of src/shaders/shader.slang, embedded so consumers create their
 VkShaderModule straight from the library with no file management. One module,
 two entry points (`SHADER_VERTEX_ENTRY` and `SHADER_FRAGMENT_ENTRY`).
*>
char[*] shader_spirv = $embed("shaders/shader.spv");

<*
 Name of the vertex entry point in `shader_spirv`.
*>
const ZString SHADER_VERTEX_ENTRY   = "vertexMain";

<*
 Name of the fragment entry point in `shader_spirv`.
*>
const ZString SHADER_FRAGMENT_ENTRY = "fragmentMain";

<*
 Uniform block at descriptor set 0, binding 0 (scalar layout, 136 bytes).

 The cbuffer of the shader reads matrices as column-major bytes relative to how
 `cui::camera` fills Matrix4f, so upload both matrices with `.transpose()`
 (verified against the SPIR-V: clip w collapses to 0 otherwise).
*>
struct ShaderUniforms
{
	Matrix4f projection;
	Matrix4f view;
	Vec2 resolution; // window size in pixels; drawings are in pixels
}

<*
 Push constant block, 24 bytes, visible to vertex + fragment stages: buffer
 device addresses of the Drawing array, the transform palette and the clip list.

 All three buffers need BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT. The palette is
 read as raw float4s (4 per matrix), so Matrix4f data is uploaded as-is,
 untransposed; clips are read the same way (2 float4s per ClipEntry).
*>
struct ShaderPushConstants
{
	ulong drawings; // VkDeviceAddress of Drawing[canvas.drawings.len()]
	ulong transforms; // VkDeviceAddress of Matrix4f[canvas.transforms.len()]
	ulong clips; // VkDeviceAddress of ClipEntry[canvas.clips.len()]
}
