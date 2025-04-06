const std = @import("std");
const wgpu = @import("wgpu");

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

    pub fn downsamplePass(self: *Self, computePass: *wgpu.ComputePassEncoder, texture: *Texture) void {
        std.debug.assert(texture.texture.getFormat() == wgpu.TextureFormat.rgba8_unorm);
        computePass.setPipeline(self.shader.pipeline.compute);
        const mips = texture.texture.getMipLevelCount();
        const texSize: @Vector(2, u32) = .{ texture.texture.getWidth(), texture.texture.getHeight() };
        var srcView = texture.getViewForLevel(0);
        for (1..mips) |mip| {
            const dstView = texture.getViewForLevel(@intCast(mip));
            const bindGroup = self.shader.createBindGroupFromEntries("downsample", 0, &[_]wgpu.BindGroupEntry{
                .{.binding = 0, .texture_view = srcView},
                .{.binding = 1, .texture_view = dstView},
            }).?;
            computePass.setBindGroup(0, bindGroup, 0, null);
            const sizeX = std.math.divCeil(u32, @max(texSize[0] >> @intCast(mip), 1), groupSize[0]) catch unreachable;
            const sizeY = std.math.divCeil(u32, @max(texSize[1] >> @intCast(mip), 1), groupSize[1]) catch unreachable;
            computePass.dispatchWorkgroups(sizeX, sizeY, 1);
            bindGroup.release();
            srcView.release();
            srcView = dstView;
        }
        srcView.release();
    }

    pub fn downsampleCommands(self: *Self, commands: *Commands, texture: *Texture) void {
        var computePass = commands.beginComputePass("downsample");
        self.downsamplePass(computePass, texture);
        computePass.end();
        computePass.release();
    }

    pub fn downsample(self: *Self, texture: *Texture) void {
        var commands = Commands.create(self.device, "downsample");
        commands.start();
        downsampleCommands(self, &commands, texture);
        commands.submit();
        commands.deinit();
    }
};
