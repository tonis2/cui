module cui::vulkan;
import std::math;
import std::io;
import std::collections;
import vk;
import image;

alias DescriptorImages = List{DescriptorImageInfo};

faultdef FILE_NOT_FOUND;

<*
 @param out_image : `Receives the created image, which the caller then owns: a DescriptorImageInfo carries only the sampler and the view, so nothing else can destroy it.`
*>
fn void? DescriptorImages.loadPath(
	&self,
	String path,
	vk::MemoryAllocator* allocator,
	vk::DeviceQueue queue,
	vk::Image* out_image = null
)
{
	image::Image img;
	if (path.ends_with(".png"))
	{
		img = image::png::load_file(path)!;
	}
	else if (path.ends_with(".jpg") || path.ends_with(".jpeg"))
	{
		img = image::jpeg::load_file(path)!;
	}
	else
	{
		io::printfn("Unsupported image format: %s", path);
		return FILE_NOT_FOUND~;
	}
	defer img.free();

	char[] rgba = img.to_rgba();
	defer alloc::free(mem, rgba);
	self.load_rgba(rgba, img.width, img.height, allocator, queue, out_image)!;
}

// The whole of a one-level colour image.
const ImageSubresourceRange COLOR_RANGE = {
	.aspectMask = IMAGE_ASPECT_COLOR_BIT,
	.baseMipLevel = 0,
	.levelCount = 1,
	.baseArrayLayer = 0,
	.layerCount = 1,
};

<*
 A sampled 2D image in device memory, ready for `update_atlas_image`.
*>
fn vk::Image? new_texture_image(uint width, uint height, Format format, vk::MemoryAllocator* allocator) @local
{
	vk::Image image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D)
		.setExtent({ .width = width, .height = height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setUsage(IMAGE_USAGE_TRANSFER_DST_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setFormat(format)
		.build(allocator.device)!;
	vk::create_image_buffer(image, allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;
	return image;
}

<*
 The sampler and view a shader reads an image through, clamped at the edges.
*>
fn DescriptorImageInfo? texture_descriptor(vk::Image image, Format format, Filter filter, vk::Device device) @local
{
	DescriptorImageInfo texture = { .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
	texture.sampler = vk::samplerCreateInfo().setMagFilter(filter).setMinFilter(filter)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setMipLodBias(0.0)
		.setMinLod(0.0)
		.setMaxLod(1.0)
		.setMaxAnisotropy(1.0)
		.setAnisotropyEnable(vk::FALSE)
		.setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE)
		.build(device)!;
	texture.imageView = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(format)
		.setSubresourceRange(COLOR_RANGE)
		.setImage(image)
		.build(device)!;
	return texture;
}

<*
 Uploads RGBA pixels as a new texture.

 @param out_image : `Receives the created image, which the caller then owns: a DescriptorImageInfo carries only the sampler and the view, so nothing else can destroy it.`
 @param linear : `Linear filtering, for a picture shown at whatever size fits; nearest suits pixel art and icons at their own size.`
*>
fn void? DescriptorImages.load_rgba(
	&self,
	char[] rgba,
	uint width,
	uint height,
	vk::MemoryAllocator* allocator,
	vk::DeviceQueue queue,
	vk::Image* out_image = null,
	bool linear = false
)
{
	vk::Image image = new_texture_image(width, height, FORMAT_R8G8B8A8_UNORM, allocator)!;
	update_atlas_image(image, rgba, width, height, true, allocator, queue, 4)!;
	self.push(texture_descriptor(image, FORMAT_R8G8B8A8_UNORM, linear ? FILTER_LINEAR : FILTER_NEAREST, allocator.device)!);
	if (out_image) *out_image = image;
}

<*
 Creates the dynamic glyph-atlas texture: R8, linearly filtered (an SDF must be
 interpolated), its image returned for later `update_atlas_image` calls.
*>
fn void? DescriptorImages.load_atlas(
	&self,
	char[] pixels,
	uint width,
	uint height,
	vk::MemoryAllocator* allocator,
	vk::DeviceQueue queue,
	vk::Image* out_image
)
{
	vk::Image image = new_texture_image(width, height, FORMAT_R8_UNORM, allocator)!;
	update_atlas_image(image, pixels, width, height, true, allocator, queue)!;
	self.push(texture_descriptor(image, FORMAT_R8_UNORM, FILTER_LINEAR, allocator.device)!);
	*out_image = image;
}

<*
 (Re)uploads the full pixel contents of an image made here. `first` selects the
 source barrier: UNDEFINED right after creation, otherwise the shader-read
 layout every update leaves the image in.
*>
fn void? update_atlas_image(
	vk::Image image,
	char[] pixels,
	uint width,
	uint height,
	bool first,
	vk::MemoryAllocator* allocator,
	vk::DeviceQueue queue,
	uint texel_size = 1
)
{
	vk::Device device = allocator.device;

	vk::Memory stage = vk::new_buffer(
		allocator,
		usage: BUFFER_USAGE_TRANSFER_SRC_BIT,
		properties: MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT,
		data: pixels.ptr,
		data_size: (sz)width * height * texel_size,
	)!;
	defer stage.free();

	device.@single_time_command(queue ; CommandBuffer command_buffer)
	{
		vk::ImageMemoryBarrier2 transfer_barrier = {
			.sType = STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
			.image = image,
			.srcStageMask = first ? PIPELINE_STAGE_2_TOP_OF_PIPE_BIT : PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
			.srcAccessMask = first ? (vk::AccessFlags2)0 : ACCESS_2_SHADER_READ_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = first ? IMAGE_LAYOUT_UNDEFINED : IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = COLOR_RANGE,
		};
		vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ transfer_barrier }));

		BufferImageCopy copy_region = {
			.imageSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
			.imageExtent = { .width = width, .height = height, .depth = 1 }
		};
		vk::cmdCopyBufferToImage(command_buffer, stage.buffer, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy_region);

		vk::ImageMemoryBarrier2 finalize_barrier = vk::transferBarrier(
			image,
			IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
		);
		vk::cmdPipelineBarrier2(command_buffer, &&vk::dependencyInfo().setImageMemoryBarriers({ finalize_barrier }));
	}!;
}

<*
 @param out_image : `Receives the created image, which the caller then owns: a DescriptorImageInfo carries only the sampler and the view, so nothing else can destroy it.`
*>
fn void? DescriptorImageInfo.createDepthTexture(
	&self,
	vk::MemoryAllocator* allocator,
	vk::DeviceQueue queue,
	Vec2 size,
	vk::Format format,
	vk::Image* out_image = null
)
{
	vk::Device device = allocator.device;

	self.imageLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

	vk::Image depth_image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D)
		.setExtent({ .width = (uint)size.x, .height = (uint)size.y, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setFormat(format)
		.build(device)!;

	vk::create_image_buffer(depth_image, allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_REPEAT)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_REPEAT)
		.setMipLodBias(0.0)
		.setMinLod(0.0)
		.setMaxLod(1.0)
		.setMaxAnisotropy(1.0)
		.setAnisotropyEnable(vk::FALSE)
		.setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE)
		.build(device)!;

	self.imageView = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(format)
		.setSubresourceRange(
			{
				.aspectMask = IMAGE_ASPECT_DEPTH_BIT,
				.baseMipLevel = 0,
				.baseArrayLayer = 0,
				.layerCount = 1,
				.levelCount = 1,
			}
		)
		.setImage(depth_image)
		.build(device)!;

	device.@single_time_command(queue ; CommandBuffer command_buffer)
	{
		ImageMemoryBarrier imageMemoryBarrier = vk::imageMemoryBarrier().setImage(depth_image)
			.setSubresourceRange(
				{
					.aspectMask = IMAGE_ASPECT_DEPTH_BIT,
					.baseMipLevel = 0,
					.baseArrayLayer = 0,
					.layerCount = 1,
					.levelCount = 1,
				}
			)
			.setSrcAccessMask((AccessFlags)0)
			.setDstAccessMask(ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
			.setOldLayout(IMAGE_LAYOUT_UNDEFINED)
			.setNewLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);

		vk::cmdPipelineBarrier(
			command_buffer,
			PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
			PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
			(DependencyFlags)0,
			0,
			null,
			0,
			null,
			1,
			&imageMemoryBarrier
		);
	}!;

	if (out_image) *out_image = depth_image;
}

// One pipeline stage; several stages may share the same spirv blob when it is
// a single shader module with multiple entry points.
struct ShaderStageConfig
{
	char[] spirv;
	ZString entry;
	ShaderStageFlagBits stage;
}

struct RenderState
{
	ShaderStageConfig[] shaders;

	DescriptorSetLayout descriptor_layout;
	PipelineLayout pipeline_layout;
	Pipeline pipeline;

	PrimitiveTopology topology;
	PolygonMode polygon_mode;
	CullModeFlagBits cull_mode;
	FrontFace front_face;

	bool enable_depth;

	vk::Format[] color_attachments;
	vk::Format depth_format;
	vk::PipelineColorBlendAttachmentState[] blend_attachments;
	vk::DynamicState[] dynamic_states;
	PushConstantRange[] push_constants;
}

fn void RenderState.free(self, Device device)
{
	self.descriptor_layout.free(device);
	self.pipeline_layout.free(device);
	self.pipeline.free(device);
}

fn RenderState? RenderState.build(&self, Device device)
{
	ShaderModule[8] modules;
	PipelineShaderStageCreateInfo[8] shader_stages;
	usz stage_count = self.shaders.len;

	for (usz i = 0; i < stage_count; ++i)
	{
		modules[i] = vk::loadShaderModule(device, self.shaders[i].spirv)!;
		shader_stages[i] = vk::pipelineShaderStageCreateInfo().setStage(self.shaders[i].stage).setMod(modules[i])
			.setName(self.shaders[i].entry);
	}

	PipelineVertexInputStateCreateInfo vertex_info = vk::pipelineVertexInputStateCreateInfo()
		.setVertexBindingDescriptionCount(0);

	PipelineInputAssemblyStateCreateInfo assembly_state = vk::pipelineInputAssemblyStateCreateInfo()
		.setTopology(self.topology);

	PipelineRasterizationStateCreateInfo rasterization_state = vk::pipelineRasterizationStateCreateInfo()
		.setDepthClampEnable(vk::FALSE)
		.setRasterizerDiscardEnable(vk::FALSE)
		.setDepthBiasEnable(vk::FALSE)
		.setPolygonMode(self.polygon_mode)
		.setLineWidth(1.0)
		.setCullMode(self.cull_mode)
		.setFrontFace(self.front_face);

	PipelineViewportStateCreateInfo view_port_state = {
		.sType = STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		.viewportCount = 1,
		.scissorCount = 1,
	};

	PipelineMultisampleStateCreateInfo multi_sample_state = vk::pipelineMultisampleStateCreateInfo()
		.setSampleShadingEnable(vk::FALSE)
		.setRasterizationSamples(SAMPLE_COUNT_1_BIT)
		.setMinSampleShading(1.0)
		.setAlphaToCoverageEnable(vk::FALSE)
		.setAlphaToOneEnable(vk::FALSE);

	PipelineColorBlendStateCreateInfo color_blend_state = vk::pipelineColorBlendStateCreateInfo()
		.setBlendConstants({ 0.0, 0.0, 0.0, 0.0 })
		.setLogicOp(LOGIC_OP_COPY)
		.setAttachments(self.blend_attachments);

	PipelineDynamicStateCreateInfo dynamic_states = vk::pipelineDynamicStateCreateInfo()
		.setDynamicStates(self.dynamic_states);

	PipelineRenderingCreateInfo rendering_info = vk::pipelineRenderingCreateInfo()
		.setColorAttachmentFormats(self.color_attachments)
		.setDepthAttachmentFormat(self.depth_format);

	PipelineDepthStencilStateCreateInfo depth_state = vk::pipelineDepthStencilStateCreateInfo()
		.setDepthTestEnable((uint)self.enable_depth)
		.setDepthWriteEnable((uint)self.enable_depth)
		.setDepthCompareOp(COMPARE_OP_LESS_OR_EQUAL)
		.setBack({ .compareOp = COMPARE_OP_ALWAYS });

	self.pipeline_layout = vk::pipelineLayoutCreateInfo().setPushConstantRanges(self.push_constants)
		.setSetLayouts({ self.descriptor_layout })
		.build(device)!;

	GraphicsPipelineCreateInfo pipeline_info = vk::graphicsPipelineCreateInfo().setStages(shader_stages[:stage_count])
		.setLayout(self.pipeline_layout)
		.setVertexInputState(&vertex_info)
		.setDynamicState(&dynamic_states)
		.setRasterizationState(&rasterization_state)
		.setInputAssemblyState(&assembly_state)
		.setMultisampleState(&multi_sample_state)
		.setColorBlendState(&color_blend_state)
		.setViewportState(&view_port_state)
		.setDepthStencilState(&depth_state)
		.setNext(&rendering_info);

	self.pipeline = pipeline_info.build(device)!;

	for (usz i = 0; i < stage_count; ++i) modules[i].free(device);

	return *self;
}