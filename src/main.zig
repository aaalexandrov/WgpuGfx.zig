const std = @import("std");
const sdl = @import("sdl3");
const wgpu = @import("wgpu");
const zstbi = @import("zstbi");

const wgfx = @import("render/wgfx.zig");
const handles = wgfx.handles;
const font = @import("render/font_render.zig");
const vm = @import("math/vec_math.zig");

const Mat4 = vm.Mat(4, 4, f32);


const PlainUniforms = extern struct {
    worldViewProj: [4][4]f32 = @bitCast(Mat4.diag(1.0)),
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

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    try zstbi.init(alloc);
    defer zstbi.deinit();

    var device = wgfx.Device.create(alloc, io);
    defer device.deinit();

    try sdl_errify(sdl.SDL_Init(sdl.SDL_INIT_VIDEO));
    defer sdl.SDL_Quit();

    const windowName = "Wgpu Gfx";
    const window = sdl.SDL_CreateWindow(windowName, 600, 600, sdl.SDL_WINDOW_RESIZABLE).?;
    defer sdl.SDL_DestroyWindow(window);

    var surface = wgfx.Surface.create(&device, window, windowName);
    defer surface.deinit();

    device.init(&surface);

    const depthStencilFormat = wgpu.WGPUTextureFormat_Depth32Float;

    var plainShader = try wgfx.Shader.createRendering(
        &device,
        "data/plain.wgsl",
        &[_]wgpu.WGPUVertexBufferLayout{
            wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
        },
        &wgpu.WGPUDepthStencilState{
            .format = depthStencilFormat,
            .depthWriteEnabled = wgpu.WGPUOptionalBool_True,
            .depthCompare = wgpu.WGPUCompareFunction_Less,
            .stencilReadMask = 0xFFFFFFFF,
            .stencilWriteMask = 0xFFFFFFFF,
            .stencilFront = wgfx.defaultStencilFace,
            .stencilBack = wgfx.defaultStencilFace,
        },
        &[_]wgpu.WGPUColorTargetState{
            .{
                .format = surface.format,
                .writeMask = wgpu.WGPUColorWriteMask_All,
            },
        },
    );
    defer plainShader.deinit();

    var fontShader = try wgfx.Shader.createRendering(
        &device,
        "data/plain.wgsl",
        &[_]wgpu.WGPUVertexBufferLayout{
            wgfx.getVertexBufferLayout(PlainVertexPosColorUv),
        },
        &wgpu.WGPUDepthStencilState{
            .format = depthStencilFormat,
            .depthWriteEnabled = wgpu.WGPUOptionalBool_False,
            .depthCompare = wgpu.WGPUCompareFunction_Always,
            .stencilReadMask = 0xFFFFFFFF,
            .stencilWriteMask = 0xFFFFFFFF,
            .stencilFront = wgfx.defaultStencilFace,
            .stencilBack = wgfx.defaultStencilFace,
        },
        &[_]wgpu.WGPUColorTargetState{
            .{
                .format = surface.format,
                .blend = &wgfx.BlendStates.alpha_blending,
                .writeMask = wgpu.WGPUColorWriteMask_All,
            },
        },
    );
    defer fontShader.deinit();

    var plainVerticesBuffer = wgfx.Buffer.create(&device, "PlainVertices", wgpu.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(&PlainVertices));
    defer plainVerticesBuffer.deinit();

    var plainUniforms = PlainUniforms{};
    var plainUniformsBuffer = wgfx.Buffer.createFromPtr(&device, "PlainUniforms", wgpu.WGPUBufferUsage_Uniform, &plainUniforms);
    defer plainUniformsBuffer.deinit();

    var linearRepeatSampler = wgfx.Sampler.create(&device, &wgpu.WGPUSamplerDescriptor{
        .label = handles.stringView("LinearRepeat"),
        .addressModeU = wgpu.WGPUAddressMode_Repeat,
        .addressModeV = wgpu.WGPUAddressMode_Repeat,
        .addressModeW = wgpu.WGPUAddressMode_Repeat,
        .minFilter = wgpu.WGPUFilterMode_Linear,
        .magFilter = wgpu.WGPUFilterMode_Linear,
        .mipmapFilter = wgpu.WGPUMipmapFilterMode_Linear,
        .lodMaxClamp = 32,
        .maxAnisotropy = 1,
    });
    defer linearRepeatSampler.deinit();
    var texData: [512][512][4]u8 = undefined;
    for (&texData, 0..) |*row, y| {
        for (row, 0..) |*pixel, x| {
            const v: u8 = @truncate(255 * ((x / 16 + y / 16) % 2));
            pixel.* = @splat(v);
        }
    }
    var plainTexture = wgfx.Texture.createFromDesc(&device, &wgpu.WGPUTextureDescriptor{
        .label = handles.stringView("Texture"),
        .usage = wgpu.WGPUTextureUsage_TextureBinding | wgpu.WGPUTextureUsage_CopyDst | wgpu.WGPUTextureUsage_StorageBinding,
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = wgfx.Texture.getMaxNumLevels(@intCast(texData[0].len), @intCast(texData.len), 1),
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
    defer wgpu.wgpuBindGroupRelease(plainBindGroup);

    var commands = wgfx.Commands.create(&device, "commands");
    defer commands.deinit();

    var depthTexture: ?wgfx.Texture = null;
    defer wgfx.deinitObj(&depthTexture);

    var frames: i64 = 0;
    const timeStart = std.Io.Timestamp.now(io, .awake);
    var timePrev = timeStart;
    var running = true;
    var event = std.mem.zeroes(sdl.SDL_Event);
    while (running) {
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => running = false,
                else => {},
            }
        }
        const width, const height = try getWindowSize(window);
        var needReconfigure = if (surface.config) |*surfConfig|
            surfConfig.width != width or surfConfig.height != height
        else
            false;
        if (!needReconfigure) {
            const surfTexViewOrError = surface.acquireTexture();
            if (surfTexViewOrError) |surfTexView| {
                {
                    const timeNow = std.Io.Timestamp.now(io, .awake);
                    const angle = @as(f64, @floatFromInt(timeStart.durationTo(timeNow).toNanoseconds())) / 1e9;
                    const rot = Mat4.rotate3D(4, @floatCast(angle), .{ 0, 0, -1, 0 });
                    const wtoh = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
                    const ortho = Mat4.orthographic(-1 * wtoh, 1 * wtoh, -1, 1, 0, 1);
                    plainUniforms.worldViewProj = @bitCast(Mat4.mul(4, ortho, rot));
                    plainUniformsBuffer.writePtr(0, &plainUniforms);

                    var msgBuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msgBuf, "{d:.2} fps", .{1e9 / @as(f64, @floatFromInt(timePrev.durationTo(timeNow).toNanoseconds()))}) catch unreachable;
                    timePrev = timeNow;

                    fontRender.clear();
                    fontRender.addLine(msg, .{ 20, 20 }, .{ 0, 0, 1 }, .{ 1, 1 });
                }

                commands.start();
                const renderPass = commands.beginRenderPass("main", &[_]wgpu.WGPURenderPassColorAttachment{
                    .{
                        .view = surfTexView,
                        .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
                        .loadOp = wgpu.WGPULoadOp_Clear,
                        .storeOp = wgpu.WGPUStoreOp_Store,
                        .clearValue = .{ .r = 0.3, .g = 0.3, .b = 0.3, .a = 1.0 },
                    },
                }, &wgpu.WGPURenderPassDepthStencilAttachment{
                    .view = depthTexture.?.view,
                    .depthLoadOp = wgpu.WGPULoadOp_Clear,
                    .depthStoreOp = wgpu.WGPUStoreOp_Store,
                    .depthClearValue = 1.0,
                });

                renderPass.wgpuRenderPassEncoderSetPipeline(plainShader.pipeline.render);
                renderPass.wgpuRenderPassEncoderSetVertexBuffer(0, plainVerticesBuffer.buffer, 0, plainVerticesBuffer.buffer.wgpuBufferGetSize());
                renderPass.wgpuRenderPassEncoderSetBindGroup(0, plainBindGroup, 0, null);
                renderPass.wgpuRenderPassEncoderDraw(3, 1, 0, 0);

                fontRender.render(renderPass, .{ width, height });

                renderPass.wgpuRenderPassEncoderEnd();
                wgpu.wgpuRenderPassEncoderRelease(renderPass);

                device.submit(&commands, true);

                surface.present();
                frames += 1;
            } else |err| switch (err) {
                wgfx.AcquireTextureError.SurfaceNeedsConfigure => needReconfigure = true,
                wgfx.AcquireTextureError.SurfaceLost => break,
            }
        }
        if (needReconfigure) {
            surface.configure(.{ width, height }, wgpu.WGPUPresentMode_Immediate);

            wgfx.deinitObj(&depthTexture);
            depthTexture = wgfx.Texture.createFromDesc(&device, &wgpu.WGPUTextureDescriptor{
                .label = handles.stringView("Depth"),
                .format = depthStencilFormat,
                .usage = wgpu.WGPUTextureUsage_RenderAttachment,
                .size = .{ .width = width, .height = height },
            });
        }

        _ = device.device.wgpuDevicePoll(0, null);
    }

    const timeNow = std.Io.Timestamp.now(io, .awake);
    const durationSecs: f64 = @as(f64, @floatFromInt(timeStart.durationTo(timeNow).toNanoseconds())) / 1e9;
    std.debug.print("Frames: {d}, seconds: {d:.3}, FPS: {d:.3}\n", .{ frames, durationSecs, @as(f64, @floatFromInt(frames)) / durationSecs });
}

fn getWindowSize(window: *sdl.SDL_Window) !struct { u32, u32 } {
    var width: c_int = undefined;
    var height: c_int = undefined;
    if (!sdl.SDL_GetWindowSize(window, &width, &height))
        return error.SdlError;
    return .{ @intCast(width), @intCast(height) };
}

/// Converts the return value of an SDL function to an error union.
pub fn sdl_errify(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}
