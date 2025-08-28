const std = @import("std");
const wgpu = @import("wgpu");

const wgfx = @import("wgfx.zig");
const util = @import("util.zig");

pub const FixedFont = struct {
    device: *wgfx.Device,
    texture: wgfx.Texture,
    charSize: Coord,

    pub const Self = @This();
    pub const Coord = @Vector(2, u32);
    pub const TexCoord = @Vector(2, f32);

    pub fn create(device: *wgfx.Device, fontfile: [:0]const u8) !FixedFont {
        const charSize = try getCharSizeFromFilename(fontfile);
        const texture = try wgfx.Texture.load(device, fontfile, wgpu.TextureUsages.texture_binding, 0, 4);
        std.debug.assert(texture.texture.getWidth() % charSize[0] == 0);
        std.debug.assert(texture.texture.getHeight() % charSize[1] == 0);
        return .{
            .device = device,
            .texture = texture,
            .charSize = charSize,
        };
    }

    pub fn deinit(self: *Self) void {
        self.texture.deinit();
    }

    pub fn getTextureSize(self: *Self) Coord {
        return Coord{ self.texture.texture.getWidth(), self.texture.texture.getHeight() };
    }

    pub fn getTextureScale(self: *Self) TexCoord {
        return TexCoord{1, 1} / @as(TexCoord, @floatFromInt(self.getTextureSize()));
    }

    pub fn getCharCoord(self: *Self, c: u8) Coord {
        const texSize = self.getTextureSize();
        const maxCharInd = texSize[0] * texSize[1];
        const charInd: u32 = if (' ' <= c and c < ' ' + maxCharInd) c - ' ' else maxCharInd - 1;
        const cols = texSize[0] / self.charSize[0];
        return Coord{ charInd % cols, charInd / cols } * self.charSize;
    }

    pub fn getCharSizeFromFilename(fontpath: []const u8) !Coord {
        const fontfile = std.fs.path.basename(fontpath);
        const widthInt = util.findFirstInteger(fontfile);
        const fontRest = fontfile[widthInt.ptr - fontfile.ptr + widthInt.len..];
        const heightInt = util.findFirstInteger(fontRest);
        const charSize = Coord{
            try std.fmt.parseInt(u32, widthInt, 10),
            try std.fmt.parseInt(u32, heightInt, 10),
        };
        return charSize;
    }
};
