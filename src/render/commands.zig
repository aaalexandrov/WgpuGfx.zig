const std = @import("std");
const wgpu = @import("wgpu");

const handles = @import("handles.zig");
const util = @import("util.zig");

const devi = @import("device.zig");
const Device = devi.Device;

pub const Commands = struct {
    encoder: ?handles.CommandEncoder = null,
    commands: ?wgpu.WGPUCommandBuffer = null,
    name: []const u8,
    device: *Device,

    const Self = @This();

    pub fn create(device: *Device, name: []const u8) Commands {
        return .{
            .name = device.alloc.dupe(u8, name) catch unreachable,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.encoder == null);
        std.debug.assert(self.commands == null);
        self.device.alloc.free(self.name);
    }

    pub fn start(self: *Self) void {
        std.debug.assert(self.encoder == null);
        std.debug.assert(self.commands == null);
        self.encoder = self.device.device.wgpuDeviceCreateCommandEncoder(&.{
            .label = handles.stringView(self.name),
        }) orelse @panic("wgpuDeviceCreateCommandEncoder failed");
    }

    pub fn finish(self: *Self) void {
        std.debug.assert(self.commands == null);
        if (self.encoder == null)
            return;
        self.commands = self.encoder.?.wgpuCommandEncoderFinish(&.{
            .label = handles.stringView(self.name),
        });
        util.releaseObj(wgpu.wgpuCommandEncoderRelease, &self.encoder);
    }

    pub fn beginRenderPass(
        self: *Self,
        passName: []const u8,
        colorAttachments: []const wgpu.WGPURenderPassColorAttachment,
        depthAttachment: ?*const wgpu.WGPURenderPassDepthStencilAttachment,
    ) handles.RenderPassEncoder {
        if (self.encoder == null)
            self.start();
        return self.encoder.?.wgpuCommandEncoderBeginRenderPass(&.{
            .label = handles.stringView(passName),
            .depthStencilAttachment = depthAttachment,
            .colorAttachmentCount = colorAttachments.len,
            .colorAttachments = colorAttachments.ptr,
        }) orelse @panic("wgpuCommandEncoderBeginRenderPass failed");
    }

    pub fn beginComputePass(self: *Self, passName: []const u8) handles.ComputePassEncoder {
        if (self.encoder == null)
            self.start();
        return self.encoder.?.wgpuCommandEncoderBeginComputePass(&.{
            .label = handles.stringView(passName),
        }) orelse @panic("wgpuCommandEncoderBeginComputePass failed");
    }
};
