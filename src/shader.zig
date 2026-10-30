const std = @import("std");
const wgpu = @import("wgpu");

const devi = @import("device.zig");
const Device = devi.Device;

const util = @import("util.zig");

pub const ShaderPipeline = union(enum) {
    render: *wgpu.RenderPipeline,
    compute: *wgpu.ComputePipeline,

    const Self = @This();

    pub fn release(self: *Self) void {
        switch (self.*) {
            .render => |render| render.release(),
            .compute => |compute| compute.release(),
        }
    }
};

pub const Shader = struct {
    module: *wgpu.ShaderModule,
    pipeline: ShaderPipeline,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromObjects(device: *Device, module: *wgpu.ShaderModule, pipeline: ShaderPipeline, name: []const u8) Shader {
        return .{
            .module = module,
            .pipeline = pipeline,
            .name = device.alloc.dupe(u8, name) catch unreachable,
            .device = device,
        };
    }

    pub fn createRenderingFromDesc(device: *Device, desc: *const wgpu.RenderPipelineDescriptor) Shader {
        return createFromObjects(
            device, 
            desc.vertex.module, 
            .{ .render = device.device.createRenderPipeline(desc).? }, 
            if (desc.label.toSlice()) |label| label else "",
        );
    }

    pub fn createRendering(device: *Device, filename: []const u8, vertexBuffers: []const wgpu.VertexBufferLayout, depthStencil: ?*const wgpu.DepthStencilState, colorTargets: []const wgpu.ColorTargetState) !Shader {
        const module = try loadModule(device, filename);
        return createRenderingFromDesc(device, &wgpu.RenderPipelineDescriptor{
            .label = wgpu.StringView.fromSlice(filename), 
            .vertex = .{
                .module = module,
                .entry_point = wgpu.StringView.fromSlice("vs_main"),
                .buffer_count = vertexBuffers.len,
                .buffers = vertexBuffers.ptr,
            },
            .primitive = .{},
            .multisample = .{},
            .depth_stencil = depthStencil,
            .fragment = &wgpu.FragmentState{
                .module = module,
                .entry_point = wgpu.StringView.fromSlice("fs_main"),
                .target_count = colorTargets.len,
                .targets = colorTargets.ptr,
            },
        });
    }

    pub fn createComputeFromDesc(device: *Device, desc: *const wgpu.ComputePipelineDescriptor) Shader {
        return createFromObjects(
            device,
            desc.compute.module,
            .{ .compute = device.device.createComputePipeline(desc).? },
            if (desc.label.toSlice()) |label| label else "");
    }

    pub fn createCompute(device: *Device, filename: []const u8) !Shader {
        const module = try loadModule(device, filename);
        return createComputeFromDesc(device, &wgpu.ComputePipelineDescriptor{
            .label = wgpu.StringView.fromSlice(filename),
            .compute = .{
                .module = module,
                .entry_point = wgpu.StringView.fromSlice("cs_main"),
            },
        });
    }

    pub fn loadModule(device: *Device, filename: []const u8) !*wgpu.ShaderModule {
        // Zig 0.17: file I/O goes through an Io implementation (`std.Io.Threaded` by default).
        const content = try std.Io.Dir.cwd().readFileAlloc(
            device.io,
            filename,
            device.alloc,
            .limited(std.math.maxInt(u32)),
        );
        defer device.alloc.free(content);
        return device.device.createShaderModule(&wgpu.ShaderModuleDescriptor{
            .next_in_chain = @ptrCast(&wgpu.ShaderSourceWGSL{
                .code = wgpu.StringView.fromSlice(content),
            }),
            .label = wgpu.StringView.fromSlice(filename),
        }).?;
    }

    pub fn deinit(self: *Self) void {
        self.pipeline.release();
        self.module.release();
        self.device.alloc.free(self.name);
    }

    pub fn getBindGroupLayout(self: *Self, groupIndex: u32) ?*wgpu.BindGroupLayout {
        return switch (self.pipeline) {
            inline else => |pipe| pipe.getBindGroupLayout(groupIndex),
        };
    }

    pub fn createBindGroupFromEntries(self: *Self, name: []const u8, groupIndex: u32, entries: []const wgpu.BindGroupEntry) ?*wgpu.BindGroup {
        const groupLayout = self.getBindGroupLayout(groupIndex) orelse return null;
        defer groupLayout.release();
        return self.device.device.createBindGroup(&wgpu.BindGroupDescriptor{
            .label = wgpu.StringView.fromSlice(name),
            .layout = groupLayout,
            .entry_count = entries.len,
            .entries = entries.ptr,
        });
    }

    pub fn createBindGroup(self: *Self, name: []const u8, groupIndex: u32, args: anytype) ?*wgpu.BindGroup {
        var entries: [args.len]wgpu.BindGroupEntry = undefined;
        inline for (args, 0..) |arg, i| {
            entries[i] = .{
                .binding = @intCast(i),
            };
            switch (@TypeOf(arg)) {
                *wgpu.Buffer => entries[i].buffer = arg,
                *wgpu.Sampler => entries[i].sampler = arg,
                *wgpu.TextureView => entries[i].texture_view = arg,
                else => unreachable,
            }
        }
        return createBindGroupFromEntries(self, name, groupIndex, &entries);
    }
};

pub fn getVertexFormat(comptime T: type) wgpu.VertexFormat {
    return switch (T) {
        f32 => wgpu.VertexFormat.float32,
        [2]f32 => wgpu.VertexFormat.float32x2,
        [3]f32 => wgpu.VertexFormat.float32x3,
        [4]f32 => wgpu.VertexFormat.float32x4,

        u32 => wgpu.VertexFormat.uint32,
        [2]u32 => wgpu.VertexFormat.uint32x2,
        [3]u32 => wgpu.VertexFormat.uint32x3,
        [4]u32 => wgpu.VertexFormat.uint32x4,

        i32 => wgpu.VertexFormat.sint32,
        [2]i32 => wgpu.VertexFormat.sint32x2,
        [3]i32 => wgpu.VertexFormat.sint32x3,
        [4]i32 => wgpu.VertexFormat.sint32x4,

        [2]u8 => wgpu.VertexFormat.uint8x2,
        [4]u8 => wgpu.VertexFormat.uint8x4,
        @Vector(2, u8) => wgpu.VertexFormat.unorm8x2,
        @Vector(4, u8) => wgpu.VertexFormat.unorm8x4,

        [2]i8 => wgpu.VertexFormat.sint8x2,
        [4]i8 => wgpu.VertexFormat.sint8x4,
        @Vector(2, i8) => wgpu.VertexFormat.snorm8x2,
        @Vector(4, i8) => wgpu.VertexFormat.snorm8x4,

        [2]u16 => wgpu.VertexFormat.uint16x2,
        [4]u16 => wgpu.VertexFormat.uint16x4,
        @Vector(2, u16) => wgpu.VertexFormat.unorm16x2,
        @Vector(4, u16) => wgpu.VertexFormat.unorm16x4,

        [2]i16 => wgpu.VertexFormat.sint16x2,
        [4]i16 => wgpu.VertexFormat.sint16x4,
        @Vector(2, i16) => wgpu.VertexFormat.snorm16x2,
        @Vector(4, i16) => wgpu.VertexFormat.snorm16x4,

        else => unreachable,
    };
}

pub fn getVertexAttributes(comptime T: type) [vertexFieldCount(T)]wgpu.VertexAttribute {
    var attrs: [vertexFieldCount(T)]wgpu.VertexAttribute = undefined;
    inline for (vertexFieldNames(T), vertexFieldTypes(T), 0..) |name, field_type, i| {
        attrs[i] = .{
            .format = getVertexFormat(field_type),
            .offset = @offsetOf(T, name),
            .shader_location = i,
        };
    }
    return attrs;
}

// Zig 0.17: `@typeInfo(T).@"struct"` exposes parallel `field_names`/`field_types` arrays
// instead of a `fields` array (and `std.meta.fields` is gone).
fn vertexFieldNames(comptime T: type) []const [:0]const u8 {
    return @typeInfo(T).@"struct".field_names;
}

fn vertexFieldTypes(comptime T: type) []const type {
    return @typeInfo(T).@"struct".field_types;
}

fn vertexFieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

pub fn getVertexBufferLayout(comptime T: type) wgpu.VertexBufferLayout {
    const attrs = struct {
        const attr = getVertexAttributes(T);
    };
    return wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(T),
        .attribute_count = attrs.attr.len,
        .attributes = &attrs.attr,
    };
}

pub fn getIndexFormat(comptime T: type) wgpu.IndexFormat {
    return switch (T) {
        u16 => wgpu.IndexFormat.uint16,
        u32 => wgpu.IndexFormat.uint32,
        else => unreachable,
    };
}