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
            .name = device.alloc.dupeZ(u8, name, ) catch unreachable,
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
        self.encoder = self.device.device.?.createCommandEncoder(&wgpu.CommandEncoderDescriptor{
            .label = self.name,
        }).?;
    }

    pub fn finish(self: *Self) void {
        std.debug.assert(self.encoder != null);
        std.debug.assert(self.commands == null);
        self.commands = self.encoder.?.finish(&wgpu.CommandBufferDescriptor{
            .label = self.name,
        }).?;
        devi.releaseObj(&self.encoder);
    }

    pub fn submit(self: *Self) void {
        if (self.encoder != null)
            self.finish();
        std.debug.assert(self.encoder == null);
        self.device.queue.?.submit(&[_]*wgpu.CommandBuffer{self.commands.?});
        devi.releaseObj(&self.commands);
    }

    pub fn beginRenderPass(self: *Self, passName: [:0]const u8, colorAttachments: []const wgpu.ColorAttachment, depthAttachment: ?*wgpu.DepthStencilAttachment) *wgpu.RenderPassEncoder {
        return self.encoder.?.beginRenderPass(&wgpu.RenderPassDescriptor{
            .label = passName,
            .depth_stencil_attachment = depthAttachment,
            .color_attachment_count = colorAttachments.len,
            .color_attachments = colorAttachments.ptr,
        }).?;
    }
};
