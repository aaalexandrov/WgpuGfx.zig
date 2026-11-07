const std = @import("std");
const wgpu = @import("wgpu");

const wgfx = @import("wgfx.zig");
const wgpuHandles = @import("handles.zig");
const vm = @import("vec_math.zig");

const Mat4 = vm.Mat(4, 4, f32);

pub const FontUniforms = extern struct {
    worldViewProj: [4][4]f32 = @bitCast(Mat4.diag(1.0)),
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
    alloc: std.mem.Allocator,
    vertices: std.ArrayList(VertexStruct),
    bindGroup: wgpuHandles.BindGroup = undefined,
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
            .alloc = device.alloc,
            .vertices = std.ArrayList(VertexStruct).initCapacity(device.alloc, maxChars * 4) catch unreachable,
            .uniformBuffer = .createFromDesc(device, &.{
                .label = wgpuHandles.stringView("FontUniforms"),
                .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
                .size = @sizeOf(UniformStruct),
            }),
            .vertexBuffer = .createFromDesc(device, &.{
                .label = wgpuHandles.stringView("FontVertices"),
                .usage = wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
                .size = @sizeOf(VertexStruct) * maxChars * 4,
            }),
            .indexBuffer = .create(device, "FontIndices", wgpu.WGPUBufferUsage_Index, std.mem.sliceAsBytes(&indices)),
        };
        fontRender.bindGroup = shader.createBindGroup("FontBinds", 0, .{
            fontRender.uniformBuffer.buffer,
            fontRender.sampler.sampler,
            fontRender.font.texture.view,
        }).?;
        return fontRender;
    }

    pub fn deinit(self: *Self) void {
        wgpu.wgpuBindGroupRelease(self.bindGroup);
        self.indexBuffer.deinit();
        self.vertexBuffer.deinit();
        self.uniformBuffer.deinit();
        self.vertices.deinit(self.alloc);
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
                    self.vertices.appendAssumeCapacity(.{
                        .pos = .{ vertPos[0], vertPos[1], 0 },
                        .color = color,
                        .uv = charTc + xy * charTexSize,
                    });
                }
            }
        }
        self.modified = true;
    }

    pub fn clear(self: *Self) void {
        self.vertices.clearRetainingCapacity();
    }

    pub fn update(self: *Self, targetSize: Coord) void {
        if (@reduce(.Or, targetSize != self.currentTargetSize)) {
            const uniforms = UniformStruct{
                .worldViewProj = @bitCast(Mat4.orthographic(0, @floatFromInt(targetSize[0]), @floatFromInt(targetSize[1]), 0, -1, 1)),
            };
            self.uniformBuffer.writePtr(0, &uniforms);
            self.currentTargetSize = targetSize;
        }
        if (self.modified) {
            std.debug.assert(self.vertices.items.len % 4 == 0);
            self.currentNumChars = @intCast(self.vertices.items.len / 4);
            if (self.vertices.items.len > 0) {
                self.vertexBuffer.write(0, std.mem.sliceAsBytes(self.vertices.items));
                self.vertices.clearRetainingCapacity();
            }
            self.modified = false;
        }
    }

    pub fn render(self: *Self, renderPass: wgpuHandles.RenderPassEncoder, targetSize: Coord) void {
        self.update(targetSize);
        if (self.currentNumChars > 0) {
            renderPass.wgpuRenderPassEncoderSetPipeline(self.shader.pipeline.render);
            renderPass.wgpuRenderPassEncoderSetVertexBuffer(0, self.vertexBuffer.buffer, 0, self.currentNumChars * 4 * @sizeOf(VertexStruct));
            renderPass.wgpuRenderPassEncoderSetIndexBuffer(self.indexBuffer.buffer, wgfx.getIndexFormat(IndexType), 0, self.currentNumChars * 6 * @sizeOf(IndexType));
            renderPass.wgpuRenderPassEncoderSetBindGroup(0, self.bindGroup, 0, null);
            renderPass.wgpuRenderPassEncoderDrawIndexed(self.currentNumChars * 6, 1, 0, 0, 0);
        }
    }
};
