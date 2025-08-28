const std = @import("std");
const wgpu = @import("wgpu");
const zm = @import("zmath");

const wgfx = @import("wgfx.zig");

pub const FontUniforms = extern struct {
    worldViewProj: [4][4]f32 = zm.identity(),
};

pub const FontVertexPosColorUv = extern struct {
    pos: [3]f32,
    color: [3]f32,
    uv: [2]f32,
};

pub const FontRender = struct {
    font: wgfx.FixedFont,
    shader: *wgfx.Shader,
    sampler: *wgfx.Sampler,
    vertices: std.ArrayList(VertexStruct),
    bindGroup: *wgpu.BindGroup = undefined,
    uniformBuffer: wgfx.Buffer,
    vertexBuffer: wgfx.Buffer,
    indexBuffer: wgfx.Buffer,
    modified: bool = false,
    currentNumChars: u32 = 0,
    currentTargetSize: Coord = .{ 0, 0 },

    const Self = @This();
    const IndexType = u16;
    const VertexStruct = FontVertexPosColorUv;
    const UniformStruct = FontUniforms;
    const Coord = wgfx.FixedFont.Coord;
    const TexCoord = wgfx.FixedFont.TexCoord;

    pub fn init(device: *wgfx.Device, fontfile: [:0]const u8, shader: *wgfx.Shader, sampler: *wgfx.Sampler) !FontRender {
        const maxChars = 4096;
        var indices: [maxChars * 6]IndexType = undefined;
        for (0..maxChars) |c| {
            indices[c * 6 + 0] = @intCast(c * 4 + 0);
            indices[c * 6 + 1] = @intCast(c * 4 + 1);
            indices[c * 6 + 2] = @intCast(c * 4 + 2);
            indices[c * 6 + 3] = @intCast(c * 4 + 1);
            indices[c * 6 + 4] = @intCast(c * 4 + 2);
            indices[c * 6 + 5] = @intCast(c * 4 + 3);
        }
        var fontRender = FontRender{
            .font = try wgfx.FixedFont.create(device, fontfile),
            .shader = shader,
            .sampler = sampler,
            .vertices = .init(device.alloc),
            .uniformBuffer = .createFromDesc(device, &wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("FontUniforms"),
                .usage = wgpu.BufferUsages.uniform | wgpu.BufferUsages.copy_dst,
                .size = @sizeOf(UniformStruct),
            }),
            .vertexBuffer = .createFromDesc(device, &wgpu.BufferDescriptor{
                .label = wgpu.StringView.fromSlice("FontVertices"),
                .usage = wgpu.BufferUsages.vertex | wgpu.BufferUsages.copy_dst,
                .size = @sizeOf(VertexStruct) * maxChars * 4,
            }),
            .indexBuffer = .create(device, "FontIndices", wgpu.BufferUsages.index, std.mem.sliceAsBytes(&indices)),
        };
        fontRender.bindGroup = shader.createBindGroup("FontBinds", 0, .{
            fontRender.uniformBuffer.buffer,
            fontRender.sampler.sampler,
            fontRender.font.texture.view,
        }).?;
        return fontRender;
    }

    pub fn deinit(self: *Self) void {
        self.bindGroup.release();
        self.indexBuffer.deinit();
        self.vertexBuffer.deinit();
        self.uniformBuffer.deinit();
        self.vertices.deinit();
        self.font.deinit();
    }

    pub fn addLine(self: *Self, line: []const u8, startPos: Coord, color: [3]f32, scale: TexCoord) void {
        const texScale = self.font.getTextureScale();
        const charSize = @as(TexCoord, @floatFromInt(self.font.charSize));
        const charTexSize = charSize * texScale;
        const charScaled = charSize * scale;
        for (line, 0..) |c, i| {
            var pos: TexCoord = @floatFromInt(startPos);
            pos[0] += @as(f32, @floatFromInt(i)) * charScaled[0];
            const charPos = self.font.getCharCoord(c);
            const charTc = @as(TexCoord, @floatFromInt(charPos)) * texScale;

            var y: f32 = 0;
            while (y < 2) : (y += 1) {
                var x: f32 = 0;
                while (x < 2) : (x += 1) {
                    const xy = TexCoord{ x, y };
                    const vertPos = pos + xy * charScaled;
                    self.vertices.append(.{
                        .pos = .{ vertPos[0], vertPos[1], 0 },
                        .color = color,
                        .uv = charTc + xy * charTexSize,
                    }) catch unreachable;
                }
            }
        }
        self.modified = true;
    }

    pub fn clear(self: *Self) void {
        self.vertices.resize(0) catch unreachable;
    }

    pub fn update(self: *Self, targetSize: Coord) void {
        if (@reduce(.Or, targetSize != self.currentTargetSize)) {
            const uniforms = UniformStruct{
                .worldViewProj = zm.orthographicOffCenterLh(0, @floatFromInt(targetSize[0]), 0, @floatFromInt(targetSize[1]), 0, 1),
            };
            self.uniformBuffer.writePtr(0, &uniforms);
            self.currentTargetSize = targetSize;
        }
        if (self.modified) {
            std.debug.assert(self.vertices.items.len % 4 == 0);
            self.currentNumChars = @intCast(self.vertices.items.len / 4);
            if (self.vertices.items.len > 0) {
                self.vertexBuffer.write(0, std.mem.sliceAsBytes(self.vertices.items));
                self.vertices.resize(0) catch unreachable;
            }
            self.modified = false;
        }
    }

    pub fn render(self: *Self, renderPass: *wgpu.RenderPassEncoder, targetSize: Coord) void {
        self.update(targetSize);
        if (self.currentNumChars > 0) {
            renderPass.setPipeline(self.shader.pipeline.render);
            renderPass.setVertexBuffer(0, self.vertexBuffer.buffer, 0, self.currentNumChars * 4 * @sizeOf(VertexStruct));
            renderPass.setIndexBuffer(self.indexBuffer.buffer, wgfx.getIndexFormat(IndexType), 0, self.currentNumChars * 6 * @sizeOf(IndexType));
            renderPass.setBindGroup(0, self.bindGroup, 0, null);
            renderPass.drawIndexed(self.currentNumChars * 6, 1, 0, 0, 0);
        }
    }
};
