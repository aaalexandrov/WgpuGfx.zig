const wgpu = @import("wgpu");

fn Payload(comptime handle: type) type {
    return @typeInfo(handle).optional.child;
}

pub const Instance = Payload(wgpu.WGPUInstance);
pub const Adapter = Payload(wgpu.WGPUAdapter);
pub const Device = Payload(wgpu.WGPUDevice);
pub const Queue = Payload(wgpu.WGPUQueue);
pub const Surface = Payload(wgpu.WGPUSurface);
pub const SurfaceTexture = wgpu.WGPUSurfaceTexture;
pub const Texture = Payload(wgpu.WGPUTexture);
pub const TextureView = Payload(wgpu.WGPUTextureView);
pub const Sampler = Payload(wgpu.WGPUSampler);
pub const Buffer = Payload(wgpu.WGPUBuffer);
pub const ShaderModule = Payload(wgpu.WGPUShaderModule);
pub const BindGroupLayout = Payload(wgpu.WGPUBindGroupLayout);
pub const BindGroup = Payload(wgpu.WGPUBindGroup);
pub const RenderPipeline = Payload(wgpu.WGPURenderPipeline);
pub const ComputePipeline = Payload(wgpu.WGPUComputePipeline);
pub const CommandEncoder = Payload(wgpu.WGPUCommandEncoder);
pub const CommandBuffer = Payload(wgpu.WGPUCommandBuffer);
pub const RenderPassEncoder = Payload(wgpu.WGPURenderPassEncoder);
pub const ComputePassEncoder = Payload(wgpu.WGPUComputePassEncoder);

pub const StringView = wgpu.WGPUStringView;

pub inline fn stringView(s: []const u8) StringView {
    return .{ .data = s.ptr, .length = s.len };
}

pub inline fn stringSlice(v: StringView) []const u8 {
    if (v.data == null or v.length == 0) return "";
    return v.data[0 .. v.length];
}
