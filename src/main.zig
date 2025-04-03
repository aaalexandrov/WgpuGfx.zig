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

    var plainShader = try wgfx.Shader.createRendering(
        &device, 
        "data/plain.wgsl", 
        &[_]wgpu.VertexBufferLayout{ wgfx.getVertexBufferLayout(PlainVertexPosColorUv), }, 
        &[_]wgpu.ColorTargetState{ .{ .format = surface.format, }, }
    );
    defer plainShader.deinit();

    const plainBindGroupLayout = plainShader.pipeline.render.getBindGroupLayout(0).?;
    defer plainBindGroupLayout.release();

    const plainVerticesBuffer = device.device.?.createBuffer(&wgpu.BufferDescriptor{
        .label = "PlainVertices",
        .usage = wgpu.BufferUsage.vertex | wgpu.BufferUsage.copy_dst,
        .size = std.mem.sliceAsBytes(&PlainVertices).len,
    }).?;
    defer plainVerticesBuffer.release();
    device.queue.?.writeBuffer(plainVerticesBuffer, 0, (&PlainVertices).ptr, std.mem.sliceAsBytes(&PlainVertices).len);

    var plainUniforms = PlainUniforms{};
    const plainUniformsBuffer = device.device.?.createBuffer(&wgpu.BufferDescriptor{
        .label = "PlainUniforms",
        .usage = wgpu.BufferUsage.uniform | wgpu.BufferUsage.copy_dst,
        .size = @sizeOf(PlainUniforms),
    }).?;
    defer plainUniformsBuffer.release();
    device.queue.?.writeBuffer(plainUniformsBuffer, 0, &plainUniforms, @sizeOf(PlainUniforms));

    const linearRepeatSampler = device.device.?.createSampler(&wgpu.SamplerDescriptor{
        .label = "LinearRepeat",
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
    }).?;
    defer linearRepeatSampler.release();

    const plainTexture = device.device.?.createTexture(&wgpu.TextureDescriptor{
        .label = "Texture",
        .usage = wgpu.TextureUsage.texture_binding | wgpu.TextureUsage.copy_dst,
        .format = .rgba8_unorm,
        .size = .{ .width = 4, .height = 4, .depth_or_array_layers = 1 },
    }).?;
    defer plainTexture.release();
    const plainTextureView = plainTexture.createView(null).?;
    defer plainTextureView.release();

    var texData: [4 * 4]@Vector(4, u8) = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            texData[y * 4 + x] = @splat(@truncate(255 * ((x + y) % 2)));
        }
    }
    device.queue.?.writeTexture(&wgpu.ImageCopyTexture{
        .texture = plainTexture,
        .origin = .{},
    }, &texData[0], std.mem.sliceAsBytes(&texData).len, &wgpu.TextureDataLayout{ .bytes_per_row = 4 * @sizeOf(std.meta.Elem(@TypeOf(texData))) }, &wgpu.Extent3D{ .width = 4, .height = 4, .depth_or_array_layers = 1 });

    const plainBindGroup = device.device.?.createBindGroup(&wgpu.BindGroupDescriptor{
        .label = "Plain",
        .layout = plainBindGroupLayout,
        .entry_count = 3,
        .entries = &[_]wgpu.BindGroupEntry{
            .{
                .binding = 0,
                .buffer = plainUniformsBuffer,
            },
            .{
                .binding = 1,
                .sampler = linearRepeatSampler,
            },
            .{
                .binding = 2,
                .texture_view = plainTextureView,
            },
        },
    }).?;
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
                device.queue.?.writeBuffer(plainUniformsBuffer, 0, &plainUniforms, @sizeOf(PlainUniforms));
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
            renderPass.setVertexBuffer(0, plainVerticesBuffer, 0, plainVerticesBuffer.getSize());
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
                surface.configure(&device, .{ @intCast(width), @intCast(height) }, wgpu.PresentMode.immediate);
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
