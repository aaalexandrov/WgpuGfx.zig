const std = @import("std");
const wgpu = @import("wgpu");
const zstbi = @import("zstbi");

const util = @import("util.zig");
const devi = @import("device.zig");
const Device = devi.Device;

pub const Buffer = struct {
    buffer: *wgpu.Buffer,
    name: [:0]const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromDesc(device: *Device, desc: *const wgpu.BufferDescriptor) Buffer {
        return .{
            .buffer = device.device.createBuffer(desc).?,
            .name = util.copyNameFromDescLabel(desc, device.alloc),
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
        self.device.queue.writeBuffer(self.buffer, offset, content.ptr, content.len);
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
            .sampler = device.device.createSampler(desc).?,
            .name = util.copyNameFromDescLabel(desc, device.alloc),
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
        const tex = device.device.createTexture(desc).?;
        return .{
            .texture = tex,
            .view = tex.createView(null).?,
            .name = util.copyNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn load(device: *Device, filename: [:0]const u8, usage_: wgpu.TextureUsageFlags, numMips: u32, numComponents: u32) !Texture {
        var img = try zstbi.Image.loadFromFile(filename, numComponents);
        defer img.deinit();
        if (img.bytes_per_component != 1)
            return error.InvalidValue;
        const format = switch (img.num_components) {
            1 => wgpu.TextureFormat.r8_unorm,
            2 => wgpu.TextureFormat.rg8_unorm,
            4 => wgpu.TextureFormat.rgba8_unorm,
            else => return error.InvalidEnum,
        };
        const numLevels = if (numMips == 0) getMaxNumLevels(img.width, img.height, 1) else numMips;
        const usage = usage_ | wgpu.TextureUsage.copy_dst | if (numLevels > 1) wgpu.TextureUsage.storage_binding else wgpu.TextureUsage.none;
        var tex = createFromDesc(device, &wgpu.TextureDescriptor{
            .label = filename,
            .format = format,
            .usage = usage,
            .mip_level_count = numLevels,
            .size = wgpu.Extent3D{
                .width = img.width,
                .height = img.height,
            },
        });
        tex.writeLevel(0, img.bytes_per_row, img.data);

        if (numLevels > 0)
            device.downsample.downsample(&tex, null);

        return tex;
    }

    pub fn deinit(self: *Self) void {
        self.texture.release();
        self.view.release();
        self.device.alloc.free(self.name);
    }

    pub fn getMaxNumLevels(width: u32, height: u32, depth: u32) u32 {
        return std.math.log2_int(u32, @max(width, height, depth)) + 1;
    }

    pub fn getViewForLevel(self: *Self, mip: u32) *wgpu.TextureView {
        return self.texture.createView(&wgpu.TextureViewDescriptor{
            .label = self.name,
            .base_mip_level = @intCast(mip),
            .mip_level_count = 1,
        }).?;
    }

    pub fn getSize(self: *Self) [4]u32 {
        return .{
            self.texture.getWidth(),
            self.texture.getHeight(),
            self.texture.getDepthOrArrayLayers(),
            self.texture.getMipLevelCount(),
        };
    }

    pub fn writeLevel(self: *Self, level: u32, bytesPerRow: u32, content: []const u8) void {
        const width = self.texture.getWidth();
        const height = self.texture.getHeight();
        const depth = self.texture.getDepthOrArrayLayers();
        const format = self.texture.getFormat();
        const formatSize = getTextureFormatSize(format);
        const rowSize = if (bytesPerRow == 0) width * formatSize else bytesPerRow;
        std.debug.assert(rowSize * height * depth == content.len);
        self.device.queue.writeTexture(
            &wgpu.ImageCopyTexture{
                .texture = self.texture,
                .mip_level = level,
                .origin = .{},
            },
            content.ptr,
            content.len,
            &wgpu.TextureDataLayout{
                .bytes_per_row = rowSize,
                .rows_per_image = height,
            },
            &wgpu.Extent3D{
                .width = width,
                .height = height,
                .depth_or_array_layers = depth,
            },
        );
    }
};

pub fn getTextureFormatSize(format: wgpu.TextureFormat) u32 {
    return switch (format) {
        .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_uint, .rgba8_sint => 4,
        .rg8_unorm, .rg8_snorm, .rg8_uint, .rg8_sint => 2,
        .r8_unorm, .r8_snorm, .r8_uint, .r8_sint => 1,
        else => unreachable,
    };
}
