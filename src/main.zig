const std = @import("std");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const zm = @import("zmath");
const zstbi = @import("zstbi");

const wgfx = @import("wgfx.zig");

const PlainUniforms = extern struct {
    worldViewProj: [4][4]f32 = zm.identity(),
};

const PlainVertexPosColorUv = extern struct {
    pos: [3]f32,
    color: [3]f32,
    uv: [2]f32,
};

const PlainVertices = [_]PlainVertexPosColorUv{
    .{ .pos = .{ -0.5, -0.5, 0.0 }, .color = .{ 1, 0, 0 }, .uv = .{ 0, 0 } },
    .{ .pos = .{ 0.5, -0.5, 0.0 }, .color = .{ 0, 1, 0 }, .uv = .{ 0, 1 } },
    .{ .pos = .{ 0.0, 0.5, 0.0 }, .color = .{ 0, 0, 1 }, .uv = .{ 1, 1 } },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak)
            @panic("Memory leaks detected!");
    }
    zstbi.init(alloc);
    defer zstbi.deinit();

    var device = wgfx.Device.create(alloc);
    defer device.deinit();

    try glfw.init();
    defer glfw.terminate();

    const windowName = "Wgpu Gfx";
    glfw.windowHint(.client_api, .no_api);
    const window = try glfw.Window.create(600, 600, windowName, null);
    defer window.destroy();

    var surface = wgfx.Surface.create(&device, window, windowName);
    defer surface.deinit();

    device.init(&surface);

    var plainShader = try wgfx.Shader.createRendering(&device, "data/plain.wgsl", &[_]wgpu.VertexBufferLayout{
        wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
    }, &[_]wgpu.ColorTargetState{
        .{
            .format = surface.format,
        },
    });
    defer plainShader.deinit();

    var fontShader = try wgfx.Shader.createRendering(&device, "data/plain.wgsl", &[_]wgpu.VertexBufferLayout{
        wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
    }, &[_]wgpu.ColorTargetState{
        .{
            .format = surface.format,
            .blend = &wgpu.BlendState.alpha_blending,
        },
    });
    defer fontShader.deinit();

    var plainVerticesBuffer = wgfx.Buffer.create(&device, "PlainVertices", wgpu.BufferUsage.vertex, std.mem.sliceAsBytes(&PlainVertices));
    defer plainVerticesBuffer.deinit();

    var plainUniforms = PlainUniforms{};
    var plainUniformsBuffer = wgfx.Buffer.createFromPtr(&device, "PlainUniforms", wgpu.BufferUsage.uniform, &plainUniforms);
    defer plainUniformsBuffer.deinit();

    var linearRepeatSampler = wgfx.Sampler.create(&device, &wgpu.SamplerDescriptor{
        .label = "LinearRepeat",
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
    });
    defer linearRepeatSampler.deinit();

    var texData: [512][512]@Vector(4, u8) = undefined;
    for (&texData, 0..) |*row, y| {
        for (row, 0..) |*e, x| {
            e.* = @splat(@truncate(255 * ((x / 16 + y / 16) % 2)));
        }
    }
    var plainTexture = wgfx.Texture.createFromDesc(&device, &wgpu.TextureDescriptor{
        .label = "Texture",
        .usage = wgpu.TextureUsage.texture_binding | wgpu.TextureUsage.copy_dst | wgpu.TextureUsage.storage_binding,
        .format = .rgba8_unorm,
        .mip_level_count = wgfx.Texture.getMaxNumLevels(@intCast(texData[0].len), @intCast(texData.len), 1),
        .size = .{
            .width = @intCast(texData[0].len),
            .height = @intCast(texData.len),
        },
    });
    defer plainTexture.deinit();
    plainTexture.writeLevel(0, 0, std.mem.sliceAsBytes(&texData));
    device.downsample.downsample(&plainTexture, null);

    var fontRender = try FontRender.init(&device, "data/font_rgba_10x20.png", &fontShader, &linearRepeatSampler);
    defer fontRender.deinit();

    const plainBindGroup = plainShader.createBindGroup("Plain", 0, .{ plainUniformsBuffer.buffer, linearRepeatSampler.sampler, plainTexture.view }).?;
    defer plainBindGroup.release();

    var commands = wgfx.Commands.create(&device, "commands");
    defer commands.deinit();
    var frames: i64 = 0;
    const timeStart = std.time.microTimestamp();
    var timePrev = timeStart;
    while (!window.shouldClose()) {
        const surfTexViewOrError = surface.acquireTexture();
        if (surfTexViewOrError) |surfTexView| {
            const width, const height = window.getSize();
            {
                const timeNow = std.time.microTimestamp();
                const rot = zm.matFromAxisAngle(.{ 0, 0, 1, 0 }, @floatCast(@as(f64, @floatFromInt(timeNow - timeStart)) / 1e6));
                const wtoh = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                const ortho = zm.orthographicOffCenterLh(-1 * wtoh, 1 * wtoh, -1, 1, 0, 1);
                plainUniforms.worldViewProj = zm.mul(rot, ortho);
                plainUniformsBuffer.writePtr(0, &plainUniforms);

                var msgBuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msgBuf, "{d:.2} fps", .{1e6 / @as(f64, @floatFromInt(timeNow - timePrev))}) catch unreachable;
                timePrev = timeNow;

                fontRender.clear();
                fontRender.addLine(msg, .{ 20, 20 }, .{ 0, 0, 1 }, .{ 2, 2 });
            }

            commands.start();
            const renderPass = commands.beginRenderPass("main", &[_]wgpu.ColorAttachment{
                .{
                    .view = surfTexView,
                    .clear_value = wgpu.Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 },
                },
            }, null);

            renderPass.setPipeline(plainShader.pipeline.render);
            renderPass.setVertexBuffer(0, plainVerticesBuffer.buffer, 0, plainVerticesBuffer.buffer.getSize());
            renderPass.setBindGroup(0, plainBindGroup, 0, null);
            renderPass.draw(3, 1, 0, 0);

            fontRender.render(renderPass, .{ @intCast(width), @intCast(height) });

            renderPass.end();
            renderPass.release();

            device.submit(&commands, true);

            surface.present();
            frames += 1;
        } else |err| switch (err) {
            wgfx.AcquireTextureError.SurfaceNeedsConfigure => {
                const width, const height = window.getSize();
                surface.configure(.{ @intCast(width), @intCast(height) }, wgpu.PresentMode.immediate);
            },
            wgfx.AcquireTextureError.SurfaceLost => break,
        }

        _ = device.device.poll(false, null);
        glfw.pollEvents();
    }

    const timeNow = std.time.microTimestamp();
    const durationSecs: f64 = @as(f64, @floatFromInt(timeNow - timeStart)) / 1e6;
    std.debug.print("Frames: {d}, seconds: {d:.3}, FPS: {d:.3}\n", .{ frames, durationSecs, @as(f64, @floatFromInt(frames)) / durationSecs });
}

const FontRender = struct {
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
    const VertexStruct = PlainVertexPosColorUv;
    const UniformStruct = PlainUniforms;
    const Coord = wgfx.FixedFont.Coord;
    const TexCoord = wgfx.FixedFont.TexCoord;

    pub fn init(device: *wgfx.Device, fontfile: [:0]const u8, shader: *wgfx.Shader, sampler: *wgfx.Sampler) !FontRender {
        const maxChars = 4096;
        var indices: [maxChars * 6]u16 = undefined;
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
                .label = "FontUniforms",
                .usage = wgpu.BufferUsage.uniform | wgpu.BufferUsage.copy_dst,
                .size = @sizeOf(UniformStruct),
            }),
            .vertexBuffer = .createFromDesc(device, &wgpu.BufferDescriptor{
                .label = "FontVertices",
                .usage = wgpu.BufferUsage.vertex | wgpu.BufferUsage.copy_dst,
                .size = @sizeOf(VertexStruct) * maxChars * 4,
            }),
            .indexBuffer = .create(device, "FontIndices", wgpu.BufferUsage.index, std.mem.sliceAsBytes(&indices)),
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
            renderPass.setIndexBuffer(self.indexBuffer.buffer, wgpu.IndexFormat.uint16, 0, self.currentNumChars * 6 * @sizeOf(u16));
            renderPass.setBindGroup(0, self.bindGroup, 0, null);
            renderPass.drawIndexed(self.currentNumChars * 6, 1, 0, 0, 0);
        }
    }
};
