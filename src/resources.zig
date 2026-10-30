const std = @import("std");
const wgpu = @import("wgpu");
const zstbi = @import("zstbi");

const handles = @import("handles.zig");
const util = @import("util.zig");
const devi = @import("device.zig");
const Device = devi.Device;

pub const Buffer = struct {
    buffer: handles.Buffer,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromDesc(device: *Device, desc: *const wgpu.WGPUBufferDescriptor) Buffer {
        return .{
            .buffer = device.device.wgpuDeviceCreateBuffer(desc) orelse
                @panic("wgpuDeviceCreateBuffer failed"),
            .name = util.copyNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn create(device: *Device, name: []const u8, usage: wgpu.WGPUBufferUsage, content: []const u8) Buffer {
        var buf = createFromDesc(device, &.{
            .label = handles.stringView(name),
            .usage = usage | wgpu.WGPUBufferUsage_CopyDst,
            .size = content.len,
        });
        buf.write(0, content);
        return buf;
    }

    pub fn createFromPtr(device: *Device, name: [:0]const u8, usage: wgpu.WGPUBufferUsage, contentPtr: anytype) Buffer {
        return create(device, name, usage, std.mem.sliceAsBytes(contentPtr[0..1]));
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpuBufferRelease(self.buffer);
        self.device.alloc.free(self.name);
    }

    pub fn write(self: *Self, offset: u64, content: []const u8) void {
        self.device.queue.wgpuQueueWriteBuffer(self.buffer, offset, content.ptr, content.len);
    }

    pub fn writePtr(self: *Self, offset: u64, contentPtr: anytype) void {
        self.write(offset, std.mem.sliceAsBytes(contentPtr[0..1]));
    }
};

pub const Sampler = struct {
    sampler: handles.Sampler,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn create(device: *Device, desc: *const wgpu.WGPUSamplerDescriptor) Sampler {
        // translate-C zeroes every field, but for these the zero value is not the
        // value wgpu expects when a field is left out.
        var filled = desc.*;
        if (filled.lodMaxClamp == 0) filled.lodMaxClamp = 32;
        if (filled.maxAnisotropy == 0) filled.maxAnisotropy = 1;
        return .{
            .sampler = device.device.wgpuDeviceCreateSampler(&filled) orelse
                @panic("wgpuDeviceCreateSampler failed"),
            .name = util.copyNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpuSamplerRelease(self.sampler);
        self.device.alloc.free(self.name);
    }
};

pub const Texture = struct {
    texture: handles.Texture,
    view: handles.TextureView,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn createFromDesc(device: *Device, desc: *const wgpu.WGPUTextureDescriptor) Texture {
        // translate-C zeroes every field, so restore the "omitted field" defaults
        // (`dimension` 0 and `sampleCount` 0 are invalid for wgpu).
        var filled = desc.*;
        if (filled.dimension == wgpu.WGPUTextureDimension_Undefined)
            filled.dimension = @intCast(wgpu.WGPUTextureDimension_2D);
        if (filled.mipLevelCount == 0) filled.mipLevelCount = 1;
        if (filled.sampleCount == 0) filled.sampleCount = 1;
        if (filled.size.depthOrArrayLayers == 0) filled.size.depthOrArrayLayers = 1;
        const tex = device.device.wgpuDeviceCreateTexture(&filled) orelse
            @panic("wgpuDeviceCreateTexture failed");
        return .{
            .texture = tex,
            .view = tex.wgpuTextureCreateView(null) orelse @panic("wgpuTextureCreateView failed"),
            .name = util.copyNameFromDescLabel(desc, device.alloc),
            .device = device,
        };
    }

    pub fn load(device: *Device, filename: [:0]const u8, usage_: wgpu.WGPUTextureUsage, numMips: u32, numComponents: u32) !Texture {
        var img = try zstbi.Image.loadFromFile(filename, numComponents);
        defer img.deinit();
        if (img.bytes_per_component != 1)
            return error.InvalidValue;
        // translate-C types the C enums as `c_uint`; the constants are `c_int`.
        const format: wgpu.WGPUTextureFormat = switch (img.num_components) {
            1 => @intCast(wgpu.WGPUTextureFormat_R8Unorm),
            2 => @intCast(wgpu.WGPUTextureFormat_RG8Unorm),
            4 => @intCast(wgpu.WGPUTextureFormat_RGBA8Unorm),
            else => return error.InvalidEnum,
        };
        const numLevels = if (numMips == 0) getMaxNumLevels(img.width, img.height, 1) else numMips;
        const usage = usage_ | wgpu.WGPUTextureUsage_CopyDst |
            if (numLevels > 1) wgpu.WGPUTextureUsage_StorageBinding else 0;
        var tex = createFromDesc(device, &.{
            .label = handles.stringView(filename),
            .format = format,
            .usage = usage,
            .mipLevelCount = numLevels,
            .size = .{
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
        wgpu.wgpuTextureRelease(self.texture);
        wgpu.wgpuTextureViewRelease(self.view);
        self.device.alloc.free(self.name);
    }

    pub fn getMaxNumLevels(width: u32, height: u32, depth: u32) u32 {
        return std.math.log2_int(u32, @max(width, height, depth)) + 1;
    }

    pub fn getViewForLevel(self: *Self, mip: u32) handles.TextureView {
        return self.texture.wgpuTextureCreateView(&.{
            .label = handles.stringView(self.name),
            .baseMipLevel = @intCast(mip),
            .mipLevelCount = 1,
            .arrayLayerCount = wgpu.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
            .aspect = @intCast(wgpu.WGPUTextureAspect_All),
        }) orelse @panic("wgpuTextureCreateView failed");
    }

    pub fn getSize(self: *Self) [4]u32 {
        return .{
            self.texture.wgpuTextureGetWidth(),
            self.texture.wgpuTextureGetHeight(),
            self.texture.wgpuTextureGetDepthOrArrayLayers(),
            self.texture.wgpuTextureGetMipLevelCount(),
        };
    }

    pub fn writeLevel(self: *Self, level: u32, bytesPerRow: u32, content: []const u8) void {
        const width = self.texture.wgpuTextureGetWidth();
        const height = self.texture.wgpuTextureGetHeight();
        const depth = self.texture.wgpuTextureGetDepthOrArrayLayers();
        const format = self.texture.wgpuTextureGetFormat();
        const formatSize = getTextureFormatSize(format);
        const rowSize = if (bytesPerRow == 0) width * formatSize else bytesPerRow;
        std.debug.assert(rowSize * height * depth == content.len);
        self.device.queue.wgpuQueueWriteTexture(
            &.{
                .texture = self.texture,
                .mipLevel = level,
                .origin = .{},
                .aspect = @intCast(wgpu.WGPUTextureAspect_All),
            },
            content.ptr,
            content.len,
            &.{
                .bytesPerRow = rowSize,
                .rowsPerImage = height,
            },
            &.{
                .width = width,
                .height = height,
                .depthOrArrayLayers = depth,
            },
        );
    }
};

pub fn getTextureFormatSize(format: wgpu.WGPUTextureFormat) u32 {
    return switch (format) {
        wgpu.WGPUTextureFormat_BGRA8Unorm,
        wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
        wgpu.WGPUTextureFormat_RGBA8Unorm,
        wgpu.WGPUTextureFormat_RGBA8UnormSrgb,
        wgpu.WGPUTextureFormat_RGBA8Uint,
        wgpu.WGPUTextureFormat_RGBA8Sint,
        => 4,
        wgpu.WGPUTextureFormat_RG8Unorm,
        wgpu.WGPUTextureFormat_RG8Snorm,
        wgpu.WGPUTextureFormat_RG8Uint,
        wgpu.WGPUTextureFormat_RG8Sint,
        => 2,
        wgpu.WGPUTextureFormat_R8Unorm,
        wgpu.WGPUTextureFormat_R8Snorm,
        wgpu.WGPUTextureFormat_R8Uint,
        wgpu.WGPUTextureFormat_R8Sint,
        => 1,
        else => unreachable,
    };
}
