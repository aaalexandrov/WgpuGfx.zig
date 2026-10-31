const std = @import("std");
const wgpu = @import("wgpu");

const devi = @import("device.zig");
const Device = devi.Device;

const handles = @import("handles.zig");
const util = @import("util.zig");

pub const ShaderPipeline = union(enum) {
    render: handles.RenderPipeline,
    compute: handles.ComputePipeline,

    const Self = @This();

    pub fn release(self: *Self) void {
        switch (self.*) {
            .render => |render| wgpu.wgpuRenderPipelineRelease(render),
            .compute => |compute| wgpu.wgpuComputePipelineRelease(compute),
        }
    }
};

pub const Shader = struct {
    module: handles.ShaderModule,
    pipeline: ShaderPipeline,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromObjects(device: *Device, module: handles.ShaderModule, pipeline: ShaderPipeline, name: []const u8) Shader {
        return .{
            .module = module,
            .pipeline = pipeline,
            .name = device.alloc.dupe(u8, name) catch unreachable,
            .device = device,
        };
    }

    pub fn createRenderingFromDesc(device: *Device, desc: *const wgpu.WGPURenderPipelineDescriptor) Shader {
        return createFromObjects(
            device,
            desc.vertex.module.?,
            .{ .render = device.device.wgpuDeviceCreateRenderPipeline(desc) orelse
                @panic("wgpuDeviceCreateRenderPipeline failed") },
            handles.stringSlice(desc.label) orelse "",
        );
    }

    pub fn createRendering(
        device: *Device,
        filename: []const u8,
        vertexBuffers: []const wgpu.WGPUVertexBufferLayout,
        depthStencil: ?*const wgpu.WGPUDepthStencilState,
        colorTargets: []const wgpu.WGPUColorTargetState,
    ) !Shader {
        const module = try loadModule(device, filename);
        return createRenderingFromDesc(device, &.{
            .label = handles.stringView(filename),
            .vertex = .{
                .module = module,
                .entryPoint = handles.stringView("vs_main"),
                .bufferCount = vertexBuffers.len,
                .buffers = vertexBuffers.ptr,
            },
            .primitive = .{
                .topology = wgpu.WGPUPrimitiveTopology_TriangleList,
                .frontFace = wgpu.WGPUFrontFace_CCW,
                .cullMode = wgpu.WGPUCullMode_None,
            },
            .multisample = .{ .count = 1, .mask = 0xFFFFFFFF },
            .depthStencil = depthStencil,
            .fragment = &.{
                .module = module,
                .entryPoint = handles.stringView("fs_main"),
                .targetCount = colorTargets.len,
                .targets = colorTargets.ptr,
            },
        });
    }

    pub fn createComputeFromDesc(device: *Device, desc: *const wgpu.WGPUComputePipelineDescriptor) Shader {
        return createFromObjects(
            device,
            desc.compute.module.?,
            .{ .compute = device.device.wgpuDeviceCreateComputePipeline(desc) orelse
                @panic("wgpuDeviceCreateComputePipeline failed") },
            handles.stringSlice(desc.label) orelse "",
        );
    }

    pub fn createCompute(device: *Device, filename: []const u8) !Shader {
        const module = try loadModule(device, filename);
        return createComputeFromDesc(device, &.{
            .label = handles.stringView(filename),
            .compute = .{
                .module = module,
                .entryPoint = handles.stringView("cs_main"),
            },
        });
    }
    pub fn loadModule(device: *Device, filename: []const u8) !handles.ShaderModule {
        const content = try std.Io.Dir.cwd().readFileAlloc(
            device.io,
            filename,
            device.alloc,
            .limited(std.math.maxInt(u32)),
        );
        defer device.alloc.free(content);

        const wgsl = wgpu.WGPUShaderSourceWGSL{
            .chain = .{ .sType = wgpu.WGPUSType_ShaderSourceWGSL },
            .code = handles.stringView(content),
        };
        var desc = wgpu.WGPUShaderModuleDescriptor{
            .nextInChain = @constCast(&wgsl.chain),
            .label = handles.stringView(filename),
        };
        return device.device.wgpuDeviceCreateShaderModule(&desc) orelse error.ShaderModuleFailed;
    }

    pub fn deinit(self: *Self) void {
        self.pipeline.release();
        wgpu.wgpuShaderModuleRelease(self.module);
        self.device.alloc.free(self.name);
    }

    pub fn getBindGroupLayout(self: *Self, groupIndex: u32) ?handles.BindGroupLayout {
        return switch (self.pipeline) {
            .render => |pipe| pipe.wgpuRenderPipelineGetBindGroupLayout(groupIndex),
            .compute => |pipe| pipe.wgpuComputePipelineGetBindGroupLayout(groupIndex),
        };
    }

    pub fn createBindGroupFromEntries(self: *Self, name: []const u8, groupIndex: u32, entries: []wgpu.WGPUBindGroupEntry) ?handles.BindGroup {
        const groupLayout = self.getBindGroupLayout(groupIndex) orelse return null;
        defer wgpu.wgpuBindGroupLayoutRelease(groupLayout);

        for (entries) |*entry| {
            if (entry.buffer != null and entry.size == 0) entry.size = wgpu.WGPU_WHOLE_SIZE;
        }

        return self.device.device.wgpuDeviceCreateBindGroup(&.{
            .label = handles.stringView(name),
            .layout = groupLayout,
            .entryCount = entries.len,
            .entries = entries.ptr,
        });
    }

    pub fn createBindGroup(self: *Self, name: []const u8, groupIndex: u32, args: anytype) ?handles.BindGroup {
        var entries: [args.len]wgpu.WGPUBindGroupEntry = undefined;
        inline for (args, 0..) |arg, i| {
            entries[i] = .{
                .binding = @intCast(i),
            };
            switch (@TypeOf(arg)) {
                handles.Buffer => entries[i].buffer = arg,
                handles.Sampler => entries[i].sampler = arg,
                handles.TextureView => entries[i].textureView = arg,
                else => unreachable,
            }
        }
        return createBindGroupFromEntries(self, name, groupIndex, &entries);
    }
};

pub fn getVertexFormat(comptime T: type) wgpu.WGPUVertexFormat {
    return switch (T) {
        f32 => wgpu.WGPUVertexFormat_Float32,
        [2]f32 => wgpu.WGPUVertexFormat_Float32x2,
        [3]f32 => wgpu.WGPUVertexFormat_Float32x3,
        [4]f32 => wgpu.WGPUVertexFormat_Float32x4,

        u32 => wgpu.WGPUVertexFormat_Uint32,
        [2]u32 => wgpu.WGPUVertexFormat_Uint32x2,
        [3]u32 => wgpu.WGPUVertexFormat_Uint32x3,
        [4]u32 => wgpu.WGPUVertexFormat_Uint32x4,

        i32 => wgpu.WGPUVertexFormat_Sint32,
        [2]i32 => wgpu.WGPUVertexFormat_Sint32x2,
        [3]i32 => wgpu.WGPUVertexFormat_Sint32x3,
        [4]i32 => wgpu.WGPUVertexFormat_Sint32x4,

        [2]u8 => wgpu.WGPUVertexFormat_Uint8x2,
        [4]u8 => wgpu.WGPUVertexFormat_Uint8x4,
        @Vector(2, u8) => wgpu.WGPUVertexFormat_Unorm8x2,
        @Vector(4, u8) => wgpu.WGPUVertexFormat_Unorm8x4,

        [2]i8 => wgpu.WGPUVertexFormat_Sint8x2,
        [4]i8 => wgpu.WGPUVertexFormat_Sint8x4,
        @Vector(2, i8) => wgpu.WGPUVertexFormat_Snorm8x2,
        @Vector(4, i8) => wgpu.WGPUVertexFormat_Snorm8x4,

        [2]u16 => wgpu.WGPUVertexFormat_Uint16x2,
        [4]u16 => wgpu.WGPUVertexFormat_Uint16x4,
        @Vector(2, u16) => wgpu.WGPUVertexFormat_Unorm16x2,
        @Vector(4, u16) => wgpu.WGPUVertexFormat_Unorm16x4,

        [2]i16 => wgpu.WGPUVertexFormat_Sint16x2,
        [4]i16 => wgpu.WGPUVertexFormat_Sint16x4,
        @Vector(2, i16) => wgpu.WGPUVertexFormat_Snorm16x2,
        @Vector(4, i16) => wgpu.WGPUVertexFormat_Snorm16x4,

        else => unreachable,
    };
}

pub fn getVertexAttributes(comptime T: type) [vertexFieldCount(T)]wgpu.WGPUVertexAttribute {
    var attrs: [vertexFieldCount(T)]wgpu.WGPUVertexAttribute = undefined;
    inline for (vertexFieldNames(T), vertexFieldTypes(T), 0..) |name, field_type, i| {
        attrs[i] = .{
            .format = getVertexFormat(field_type),
            .offset = @offsetOf(T, name),
            .shaderLocation = i,
        };
    }
    return attrs;
}

fn vertexFieldNames(comptime T: type) []const [:0]const u8 {
    return @typeInfo(T).@"struct".field_names;
}

fn vertexFieldTypes(comptime T: type) []const type {
    return @typeInfo(T).@"struct".field_types;
}

fn vertexFieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

pub fn getVertexBufferLayout(comptime T: type) wgpu.WGPUVertexBufferLayout {
    const attrs = struct {
        const attr = getVertexAttributes(T);
    };
    return .{
        .arrayStride = @sizeOf(T),
        .attributeCount = attrs.attr.len,
        .attributes = &attrs.attr,
    };
}

pub fn getIndexFormat(comptime T: type) wgpu.WGPUIndexFormat {
    return switch (T) {
        u16 => wgpu.WGPUIndexFormat_Uint16,
        u32 => wgpu.WGPUIndexFormat_Uint32,
        else => unreachable,
    };
}

pub const BlendStates = struct {
    pub const alpha_blending = wgpu.WGPUBlendState{
        .color = .{
            .operation = wgpu.WGPUBlendOperation_Add,
            .srcFactor = wgpu.WGPUBlendFactor_SrcAlpha,
            .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
        },
        .alpha = .{
            .operation = wgpu.WGPUBlendOperation_Add,
            .srcFactor = wgpu.WGPUBlendFactor_One,
            .dstFactor = wgpu.WGPUBlendFactor_OneMinusSrcAlpha,
        },
    };

    pub const premultiplied_alpha_blending = wgpu.WGPUBlendState{
        .color = alpha_blending.alpha,
        .alpha = alpha_blending.alpha,
    };
};

pub const defaultStencilFace = wgpu.WGPUStencilFaceState{
    .compare = wgpu.WGPUCompareFunction_Always,
    .failOp = wgpu.WGPUStencilOperation_Keep,
    .depthFailOp = wgpu.WGPUStencilOperation_Keep,
    .passOp = wgpu.WGPUStencilOperation_Keep,
};
