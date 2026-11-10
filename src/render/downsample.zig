const std = @import("std");
const wgpu = @import("wgpu");

const handles = @import("handles.zig");

const devi = @import("device.zig");
const Device = devi.Device;

const shdr = @import("shader.zig");
const Shader = shdr.Shader;

const reso = @import("resources.zig");
const Texture = reso.Texture;

const cmds = @import("commands.zig");
const Commands = cmds.Commands;

pub const Downsample = struct {
    device: *Device,
    shader: Shader,

    const Self = @This();
    const groupSize: @Vector(2, u32) = .{8, 8};

    pub fn create(device: *Device, shaderFile: [:0]const u8) !Downsample {
        const shader = try Shader.createCompute(device, shaderFile);
        return .{
            .device = device,
            .shader = shader,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shader.deinit();
    }

    pub fn downsamplePass(self: *Self, computePass: handles.ComputePassEncoder, texture: *Texture) void {
        std.debug.assert(texture.texture.wgpuTextureGetFormat() == wgpu.WGPUTextureFormat_RGBA8Unorm);
        computePass.wgpuComputePassEncoderSetPipeline(self.shader.pipeline.compute);
        const mips = texture.texture.wgpuTextureGetMipLevelCount();
        const texSize: @Vector(2, u32) = .{ texture.texture.wgpuTextureGetWidth(), texture.texture.wgpuTextureGetHeight() };
        var srcView = texture.getViewForLevel(0);
        for (1..mips) |mip| {
            const dstView = texture.getViewForLevel(@intCast(mip));
            var entries = [_]wgpu.WGPUBindGroupEntry{
                .{ .binding = 0, .textureView = srcView },
                .{ .binding = 1, .textureView = dstView },
            };
            const bindGroup = self.shader.createBindGroupFromEntries("downsample", 0, &entries).?;
            computePass.wgpuComputePassEncoderSetBindGroup(0, bindGroup, 0, null);
            const sizeX = std.math.divCeil(u32, @max(texSize[0] >> @intCast(mip), 1), groupSize[0]) catch unreachable;
            const sizeY = std.math.divCeil(u32, @max(texSize[1] >> @intCast(mip), 1), groupSize[1]) catch unreachable;
            computePass.wgpuComputePassEncoderDispatchWorkgroups(sizeX, sizeY, 1);
            wgpu.wgpuBindGroupRelease(bindGroup);
            wgpu.wgpuTextureViewRelease(srcView);
            srcView = dstView;
        }
        wgpu.wgpuTextureViewRelease(srcView);
    }

    pub fn downsample(self: *Self, texture: *Texture, commands: ?*Commands) void {
        var computePass = (commands orelse &self.device.uploadCommands).beginComputePass("downsample");
        self.downsamplePass(computePass, texture);
        computePass.wgpuComputePassEncoderEnd();
        wgpu.wgpuComputePassEncoderRelease(computePass);
    }
};
