const std = @import("std");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const zm = @import("zmath");
const zstbi = @import("zstbi");

const wgfx = @import("wgfx.zig");
const font = @import("font_render.zig");

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

    const depthStencilFormat = wgpu.TextureFormat.depth32_float;

    var plainShader = try wgfx.Shader.createRendering(&device, "data/plain.wgsl", &[_]wgpu.VertexBufferLayout{
            wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
        },
        &wgpu.DepthStencilState {
            .format = depthStencilFormat,
            .depth_write_enabled = @intFromBool(true),
            .depth_compare = .less,
            .stencil_front = .{},
            .stencil_back = .{},
        }, 
        &[_]wgpu.ColorTargetState{
            .{ .format = surface.format, },
        }
    );
    defer plainShader.deinit();

    var fontShader = try wgfx.Shader.createRendering(&device, "data/plain.wgsl", &[_]wgpu.VertexBufferLayout{
            wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
        },
        &wgpu.DepthStencilState {
            .format = depthStencilFormat,
            .depth_compare = .always,
            .stencil_front = .{},
            .stencil_back = .{},
        }, 
        &[_]wgpu.ColorTargetState{
            .{
                .format = surface.format,
                .blend = &wgpu.BlendState.alpha_blending,
            },
        }
    );
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

    var fontRender = try font.FontRender.init(&device, "data/font_rgba_10x20.png", &fontShader, &linearRepeatSampler);
    defer fontRender.deinit();

    const plainBindGroup = plainShader.createBindGroup("Plain", 0, .{ plainUniformsBuffer.buffer, linearRepeatSampler.sampler, plainTexture.view }).?;
    defer plainBindGroup.release();

    var commands = wgfx.Commands.create(&device, "commands");
    defer commands.deinit();

    var depthTexture: ?wgfx.Texture = null;
    defer wgfx.deinitObj(&depthTexture);

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
                fontRender.addLine(msg, .{ 20, 20 }, .{ 0, 0, 1 }, .{ 1.5, 1.5 });
            }

            commands.start();
            const renderPass = commands.beginRenderPass("main", &[_]wgpu.ColorAttachment{
                    .{
                        .view = surfTexView,
                        .clear_value = wgpu.Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 },
                    },
                }, 
                &wgpu.DepthStencilAttachment {
                    .view = depthTexture.?.view,
                    .depth_load_op = .clear,
                    .depth_store_op = .store,
                    .depth_clear_value = 1.0,
                }
            );

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

                wgfx.deinitObj(&depthTexture);
                depthTexture = wgfx.Texture.createFromDesc(&device, &wgpu.TextureDescriptor{
                    .label = "Depth",
                    .format = depthStencilFormat,
                    .usage = wgpu.TextureUsage.render_attachment,
                    .size = .{.width = @intCast(width), .height = @intCast(height), },
                });
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

