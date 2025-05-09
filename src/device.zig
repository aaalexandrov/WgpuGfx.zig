const std = @import("std");
const wgpu = @import("wgpu");

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
        }).adapter.?;

        var adapterInfo: wgpu.AdapterInfo = undefined;
        self.adapter.getInfo(&adapterInfo);
        defer adapterInfo.freeMembers();
        std.debug.print("Adapter: {s}, type: {?s}, backend: {?s}\n", .{ adapterInfo.device, std.enums.tagName(wgpu.AdapterType, adapterInfo.adapter_type), std.enums.tagName(wgpu.BackendType, adapterInfo.backend_type) });

        std.debug.assert(surface.format == wgpu.TextureFormat.@"undefined");
        surface.format = surf.getSurfaceFormat(surface.surface, self.adapter).?;
        std.debug.print("Surface format: {?s}\n", .{std.enums.tagName(wgpu.TextureFormat, surface.format)});

        self.device = self.adapter.requestDeviceSync(&wgpu.DeviceDescriptor{
            .required_limits = null,
        }).device.?;
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
        releaseObj(&cmds.commands);
        if (submitUploads)
            releaseObj(&self.uploadCommands.commands);
    }
};

pub fn releaseObj(ptr: anytype) void {
    if (ptr.*) |*obj| {
        obj.*.release();
        ptr.* = null;
    }
}

pub fn deinitObj(ptr: anytype) void {
    if (ptr.*) |*obj| {
        obj.*.deinit();
        ptr.* = null;
    }
}

pub fn copyNameFromDescLabel(desc: anytype, alloc: std.mem.Allocator) [:0]const u8 {
    return if (desc.label) |label| blk: {
        const len = std.mem.len(label);
        break :blk (alloc.dupeZ(u8, label[0..len]) catch unreachable)[0..len :0];
    } else "";
}

fn logCallback(level: wgpu.LogLevel, message: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.C) void {
    _ = userdata;
    std.debug.print("Wgpu {?s}: {?s}\n", .{ std.enums.tagName(wgpu.LogLevel, level), message });
}
