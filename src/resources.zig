const std = @import("std");
const wgpu = @import("wgpu");

const devi = @import("device.zig");
const Device = devi.Device;

pub const Buffer = struct {
    buffer: *wgpu.Buffer,
    name: [:0]const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromDesc(device: *Device, desc: *const wgpu.BufferDescriptor) Buffer {
        return .{
            .buffer = device.device.?.createBuffer(desc).?,
            .name = getNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn create(device: *Device, name: [:0]const u8, usage: wgpu.BufferUsageFlags, content: []const u8) Buffer {
        var buf = createFromDesc(device, &wgpu.BufferDescriptor{
            .label = name,
            .usage = usage | wgpu.BufferUsage.copy_dst,
            .size = content.len,
        });
        buf.write(0, content);
        return buf;
    }

    pub fn createFromPtr(device: *Device, name: [:0]const u8, usage: wgpu.BufferUsageFlags, contentPtr: anytype) Buffer {
        return create(device, name, usage, std.mem.sliceAsBytes(contentPtr[0..1]));
    }

    pub fn deinit(self: *Self) void {
        self.buffer.release();
        self.device.alloc.free(self.name);
    }

    pub fn write(self: *Self, offset: u64, content: []const u8) void {
        self.device.queue.?.writeBuffer(self.buffer, offset, content.ptr, content.len);
    }

    pub fn writePtr(self: *Self, offset: u64, contentPtr: anytype) void {
        self.write(offset, std.mem.sliceAsBytes(contentPtr[0..1]));
    }
};

pub const Sampler = struct {
    sampler: *wgpu.Sampler,
    name: [:0]const u8,
    device: *Device,

    const Self = @This();

    pub fn create(device: *Device, desc: *const wgpu.SamplerDescriptor) Sampler {
        return .{
            .sampler = device.device.?.createSampler(desc).?,
            .name = getNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        self.sampler.release();
        self.device.alloc.free(self.name);
    }
};

pub const Texture = struct {
    texture: *wgpu.Texture,
    view: *wgpu.TextureView,
    name: [:0]const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromDesc(device: *Device, desc: *const wgpu.TextureDescriptor) Texture {
        const tex = device.device.?.createTexture(desc).?;
        return .{
            .texture = tex,
            .view = tex.createView(null),
            .name = getNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.release();
        self.view.release();
        self.device.alloc.free(self.name);
    }

    pub fn getView(self: *Self) *wgpu.TextureView {
        self.view.reference();
        return self.view;
    }

    pub fn getSize(self: *Self) [4]u32 {
        return .{
            self.texture.getWidth(),
            self.texture.getHeight(),
            self.texture.getDepthOrArrayLayers(),
            self.texture.getMipLevelCount(),
        };
    }

    // pub fn writeLevel(self: *Self, level: u32, content: []const u8) void {
    //     self.device.queue.?.writeTexture(&wgpu.ImageCopyTexture{
    //         .texture = self.texture,
    //         .mip_level = level,
    //         .origin = .{},
    //     }, content.ptr, content.len,
    //     data_layout: *const TextureDataLayout, write_size: *const Extent3D);
    // }
};

pub fn getTextureFormatSize(format: wgpu.TextureFormat) u32 {
    switch (format) {
        .bgra8_unorm, .bgra8_srgb, .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_uint, .rgba8_sint => 4,
        .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint => 2,
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint => 1,
        else => unreachable,
    }
}

pub fn getNameFromDescLabel(desc: anytype, alloc: std.mem.Allocator) [:0]const u8 {
    return if (desc.label) |label| blk: {
        const len = std.mem.len(label);
        break :blk (alloc.dupeZ(u8, label[0..len]) catch unreachable)[0..len :0];
    } else "";
}
