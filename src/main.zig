const std = @import("std");
const glfw = @import("zglfw");
const wgpu = @import("wgpu");
const zm = @import("zmath");

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

    var device = wgfx.Device.create(alloc);
    defer device.deinit();

    try glfw.init();
    defer glfw.terminate();

    const windowName = "Wgpu Thin";
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

    const plainTexture = device.device.?.createTexture(&wgpu.TextureDescriptor{
        .label = "Texture",
        .usage = wgpu.TextureUsage.texture_binding | wgpu.TextureUsage.copy_dst,
        .format = .rgba8_unorm,
        .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
    }).?;
    defer plainTexture.release();
    const plainTextureView = plainTexture.createView(null).?;
    defer plainTextureView.release();

    var texData: [4][4]@Vector(4, u8) = undefined;
    for (&texData, 0..) |*row, y| {
        for (row, 0..) |*e, x| {
            e.* = @splat(@truncate(255 * ((x + y) % 2)));
        }
    }
    device.queue.?.writeTexture(&wgpu.ImageCopyTexture{
        .texture = plainTexture,
        .origin = .{},
    }, &texData[0], std.mem.sliceAsBytes(&texData).len, &wgpu.TextureDataLayout{ .bytes_per_row = @sizeOf(std.meta.Elem(@TypeOf(texData))) }, &wgpu.Extent3D{ .width = texData[0].len, .height = texData.len, .depth_or_array_layers = 1 });

    const plainBindGroup = plainShader.createBindGroup("Plain", 0, .{ plainUniformsBuffer.buffer, linearRepeatSampler.sampler, plainTextureView }).?;
    defer plainBindGroup.release();

    const timeStart = std.time.microTimestamp();
    var frames: i64 = 0;
    while (!window.shouldClose()) {
        const surfTexViewOrError = surface.acquireTexture();
        if (surfTexViewOrError) |surfTexView| {
            {
                const timeNow = std.time.microTimestamp();
                const rot = zm.matFromAxisAngle(.{ 0, 0, 1, 0 }, @floatCast(@as(f64, @floatFromInt(timeNow - timeStart)) / 1e6));
                const width, const height = window.getSize();
                const wtoh = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                const ortho = zm.orthographicOffCenterLh(-1 * wtoh, 1 * wtoh, -1, 1, 0, 1);
                plainUniforms.worldViewProj = zm.mul(rot, ortho);
                plainUniformsBuffer.writePtr(0, &plainUniforms);
            }

            const encoder = device.device.?.createCommandEncoder(&wgpu.CommandEncoderDescriptor{ .label = "Commands" }).?;

            const renderPass = encoder.beginRenderPass(&wgpu.RenderPassDescriptor{
                .label = "main",
                .color_attachment_count = 1,
                .color_attachments = &[_]wgpu.ColorAttachment{
                    .{
                        .view = surfTexView,
                        .load_op = .clear,
                        .store_op = .store,
                        .clear_value = wgpu.Color{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 },
                    },
                },
            }).?;

            renderPass.setPipeline(plainShader.pipeline.render);
            renderPass.setVertexBuffer(0, plainVerticesBuffer.buffer, 0, plainVerticesBuffer.buffer.getSize());
            renderPass.setBindGroup(0, plainBindGroup, 0, null);
            renderPass.draw(3, 1, 0, 0);

            renderPass.end();
            renderPass.release();

            const commands = encoder.finish(&wgpu.CommandBufferDescriptor{ .label = "main" }).?;
            encoder.release();

            device.queue.?.submit(&[_]*wgpu.CommandBuffer{commands});
            commands.release();

            surface.present();
            frames += 1;
        } else |err| switch (err) {
            wgfx.AcquireTextureError.SurfaceNeedsConfigure => {
                const width, const height = window.getSize();
                surface.configure(.{ @intCast(width), @intCast(height) }, wgpu.PresentMode.immediate);
            },
            wgfx.AcquireTextureError.SurfaceLost => break,
        }

        _ = device.device.?.poll(false, null);
        glfw.pollEvents();
    }

    const timeNow = std.time.microTimestamp();
    const durationSecs: f64 = @as(f64, @floatFromInt(timeNow - timeStart)) / 1e6;
    std.debug.print("Frames: {d}, seconds: {d:.3}, FPS: {d:.3}\n", .{ frames, durationSecs, @as(f64, @floatFromInt(frames)) / durationSecs });
}
