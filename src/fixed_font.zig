const std = @import("std");
const wgpu = @import("wgpu");

const wgfx = @import("wgfx.zig");

pub const FixedFont = struct {
    device: *wgfx.Device,
    texture: wgfx.Texture,
    charSize: @Vector(2, u32),

    const Self = @This();

    pub fn create(device: *wgfx.Device, fontfile: [:0]const u8, charSize: @Vector(2, u32)) FixedFont {
        return .{
            .device = device,
            .texure = wgfx.Texture.load(device, fontfile, wgpu.TextureUsage.texture_binding | wgpu.TextureUsage.copy_dst | wgpu.TextureUsage.storage_binding, 0, 4),
            .charSize = charSize,
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.deinit();
    }
};
