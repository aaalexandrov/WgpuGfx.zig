const std = @import("std");
const wgpu = @import("wgpu");

const devi = @import("device.zig");
const Device = devi.Device;

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
    name: [:0]const u8,
    alloc: std.mem.Allocator,

    const Self = @This();

    pub fn createFromObjects(device: *Device, module: *wgpu.ShaderModule, pipeline: ShaderPipeline, name: [:0]const u8) Shader {
        return .{
            .module = module,
            .pipeline = pipeline,
            .name = device.alloc.dupeZ(u8, name) catch unreachable,
            .alloc = device.alloc,
        };
    }

    pub fn createRenderingFromDesc(device: *Device, desc: *const wgpu.RenderPipelineDescriptor) Shader {
        return createFromObjects(device, desc.vertex.module, .{ .render = device.device.?.createRenderPipeline(desc).? }, if (desc.label) |label| label[0..std.mem.len(label) :0] else "");
    }

    pub fn createRendering(device: *Device, filename: [:0]const u8, vertexBuffers: []const wgpu.VertexBufferLayout, colorTargets: []const wgpu.ColorTargetState) !Shader {
        const module = try loadModule(device, filename);
        return createRenderingFromDesc(device, &wgpu.RenderPipelineDescriptor{
            .label = filename,
            .vertex = .{
                .module = module,
                .entry_point = "vs_main",
                .buffer_count = vertexBuffers.len,
                .buffers = vertexBuffers.ptr,
            },
            .primitive = .{},
            .multisample = .{},
            .fragment = &wgpu.FragmentState{
                .module = module,
                .entry_point = "fs_main",
                .target_count = colorTargets.len,
                .targets = colorTargets.ptr,
            },
        });
    }

    pub fn loadModule(device: *Device, filename: [*:0]const u8) !*wgpu.ShaderModule {
        const file = try std.fs.cwd().openFileZ(filename, .{});
        const content = try file.readToEndAllocOptions(device.alloc, std.math.maxInt(i32), null, @alignOf(u8), 0);
        defer device.alloc.free(content);
        return device.device.?.createShaderModule(&wgpu.ShaderModuleDescriptor{
            .next_in_chain = @ptrCast(&wgpu.ShaderModuleWGSLDescriptor{
                .code = content,
            }),
            .label = filename,
        }).?;
    }

    pub fn deinit(self: *Self) void {
        self.pipeline.release();
        self.module.release();
        self.alloc.free(self.name);
    }
};

pub fn getVertexFormat(comptime T: anytype) wgpu.VertexFormat {
    return switch (@typeInfo(T)) {
        .array => |a| switch (a.child) {
            f32 => switch (a.len) {
                2 => wgpu.VertexFormat.float32x2,
                3 => wgpu.VertexFormat.float32x3,
                4 => wgpu.VertexFormat.float32x4,
                else => unreachable,
            },
            else => unreachable,
        },
        .int => |i| switch (i) {
            @typeInfo(u32).int => wgpu.VertexFormat.uint32,
            @typeInfo(i32).int => wgpu.VertexFormat.sint32,
            else => unreachable,
        },
        .float => |f| switch (f) {
            @typeInfo(f32).float => wgpu.VertexFormat.float32,
            else => unreachable,
        },
        else => unreachable,
    };
}

pub fn getVertexAttributes(comptime T: anytype) [std.meta.fields(T).len]wgpu.VertexAttribute {
    var attrs: [std.meta.fields(T).len]wgpu.VertexAttribute = undefined;
    inline for (std.meta.fields(T), 0..) |field, i| {
        attrs[i] = .{
            .format = getVertexFormat(field.type),
            .offset = @offsetOf(T, field.name),
            .shader_location = i,
        };
    }
    return attrs;
}

pub fn getVertexBufferLayout(comptime T: anytype) wgpu.VertexBufferLayout {
    const attrs = struct {
        const attr = getVertexAttributes(T);
    };
    return wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(T),
        .attribute_count = attrs.attr.len,
        .attributes = &attrs.attr,
    };
}
