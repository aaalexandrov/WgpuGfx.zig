const std = @import("std");
const wgpu = @import("wgpu");

const devi = @import("device.zig");
const Device = devi.Device;

pub const Commands = struct {
    encoder: ?*wgpu.CommandEncoder = null,
    commands: ?*wgpu.CommandBuffer = null,
    name: [:0]const u8,
    device: *Device,

    const Self = @This();

    pub fn create(device: *Device, name: [:0]const u8) Commands {
        return .{
            .name = device.alloc.dupeZ(
                u8,
                name,
            ) catch unreachable,
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
        self.encoder = self.device.device.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = self.name,
        }).?;
    }

    pub fn finish(self: *Self) void {
        std.debug.assert(self.commands == null);
        if (self.encoder == null)
            return;
        self.commands = self.encoder.?.finish(&wgpu.CommandBufferDescriptor{
            .label = self.name,
        }).?;
        devi.releaseObj(&self.encoder);
    }

    pub fn beginRenderPass(self: *Self, passName: [:0]const u8, colorAttachments: []const wgpu.ColorAttachment, depthAttachment: ?*const wgpu.DepthStencilAttachment) *wgpu.RenderPassEncoder {
        if (self.encoder == null)
            self.start();
        return self.encoder.?.beginRenderPass(&wgpu.RenderPassDescriptor{
            .label = passName,
            .depth_stencil_attachment = depthAttachment,
            .color_attachment_count = colorAttachments.len,
            .color_attachments = colorAttachments.ptr,
        }).?;
    }

    pub fn beginComputePass(self: *Self, passName: [:0]const u8) *wgpu.ComputePassEncoder {
        if (self.encoder == null)
            self.start();
        return self.encoder.?.beginComputePass(&wgpu.ComputePassDescriptor{
            .label = passName,
        }).?;
    }
};
