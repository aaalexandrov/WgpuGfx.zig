const std = @import("std");
const wgpu = @import("wgpu");

const util = @import("util.zig");

const surf = @import("surface.zig");
const Surface = surf.Surface;

const Downsample = @import("downsample.zig").Downsample;
const Commands = @import("commands.zig").Commands;

pub const Device = struct {
    alloc: std.mem.Allocator,
    instance: *wgpu.Instance,
    inited: bool = false,
    adapter: *wgpu.Adapter = undefined,
    device: *wgpu.Device = undefined,
    queue: *wgpu.Queue = undefined,
    uploadCommands: Commands = undefined,
    downsample: Downsample = undefined,

    const Self = @This();

    pub fn create(alloc: std.mem.Allocator) Self {
        wgpu.setLogCallback(logCallback, null);
        wgpu.setLogLevel(.warn);
        return .{
            .alloc = alloc,
            .instance = wgpu.Instance.create(null).?,
        };
    }

    pub fn init(self: *Self, surface: *Surface) void {
        std.debug.assert(!self.inited);

        self.adapter = self.instance.requestAdapterSync(&wgpu.RequestAdapterOptions{
            .compatible_surface = surface.surface,
            .power_preference = .high_performance,
        }, 1000).adapter.?;

        var adapterInfo: wgpu.AdapterInfo = undefined;
        if (self.adapter.getInfo(&adapterInfo) == .success) {
            defer adapterInfo.freeMembers();
            std.debug.print("Adapter: {?s}, type: {?s}, backend: {?s}\n", .{ adapterInfo.device.toSlice(), std.enums.tagName(wgpu.AdapterType, adapterInfo.adapter_type), std.enums.tagName(wgpu.BackendType, adapterInfo.backend_type) });
        }

        std.debug.assert(surface.format == wgpu.TextureFormat.@"undefined");
        surface.format = surf.getSurfaceFormat(surface.surface, self.adapter).?;
        std.debug.print("Surface format: {?s}\n", .{std.enums.tagName(wgpu.TextureFormat, surface.format)});

        self.device = self.adapter.requestDeviceSync(self.instance, &wgpu.DeviceDescriptor{
            .required_limits = null,
        }, 1000).device.?;
        self.queue = self.device.getQueue().?;

        self.uploadCommands = Commands.create(self, "DeviceUpload");

        self.downsample = Downsample.create(self, "data/downsample.wgsl") catch unreachable;

        self.inited = true;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.inited);
        self.downsample.deinit();
        self.uploadCommands.deinit();
        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.instance.release();

        wgpu.setLogLevel(.off);

        self.inited = false;
    }

    pub fn submit(self: *Self, cmds: *Commands, submitUploads: bool) void {
        var buffers: [2]*wgpu.CommandBuffer = undefined;
        var buffersSlice: []*wgpu.CommandBuffer = buffers[0..0];
        if (submitUploads) {
            self.uploadCommands.finish();
            if (self.uploadCommands.commands) |uploads| {
                buffers[buffersSlice.len] = uploads;
                buffersSlice.len += 1;
            }
        }
        cmds.finish();
        if (cmds.commands) |commands| {
            buffers[buffersSlice.len] = commands;
            buffersSlice.len += 1;
        }
        if (buffersSlice.len > 0)
            self.queue.submit(buffersSlice);
        util.releaseObj(&cmds.commands);
        if (submitUploads)
            util.releaseObj(&self.uploadCommands.commands);
    }
};

fn logCallback(level: wgpu.LogLevel, message: wgpu.StringView, userdata: ?*anyopaque) callconv(.C) void {
    _ = userdata;
    std.debug.print("Wgpu {?s}: {?s}\n", .{ std.enums.tagName(wgpu.LogLevel, level), message.toSlice() });
}
