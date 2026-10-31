const std = @import("std");
const wgpu = @import("wgpu");

const handles = @import("handles.zig");
const util = @import("util.zig");

const surf = @import("surface.zig");
const Surface = surf.Surface;

const Downsample = @import("downsample.zig").Downsample;
const Commands = @import("commands.zig").Commands;

pub const Device = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    instance: handles.Instance,
    inited: bool = false,
    adapter: handles.Adapter = undefined,
    device: handles.Device = undefined,
    queue: handles.Queue = undefined,
    uploadCommands: Commands = undefined,
    downsample: Downsample = undefined,

    const Self = @This();

    pub fn create(alloc: std.mem.Allocator, io: std.Io) Self {
        wgpu.wgpuSetLogCallback(logCallback, null);
        wgpu.wgpuSetLogLevel(wgpu.WGPULogLevel_Warn);
        return .{
            .alloc = alloc,
            .io = io,
            .instance = wgpu.wgpuCreateInstance(null) orelse @panic("wgpuCreateInstance failed"),
        };
    }

    pub fn init(self: *Self, surface: *Surface) void {
        std.debug.assert(!self.inited);

        self.adapter = self.requestAdapter(surface).?;

        var adapterInfo: wgpu.WGPUAdapterInfo = undefined;
        if (self.adapter.wgpuAdapterGetInfo(&adapterInfo) == wgpu.WGPUStatus_Success) {
            defer wgpu.wgpuAdapterInfoFreeMembers(adapterInfo);
            std.debug.print("Adapter: {s}, type: {s}, backend: {s}\n", .{
                handles.stringSlice(adapterInfo.device) orelse "",
                adapterTypeName(adapterInfo.adapterType),
                backendTypeName(adapterInfo.backendType),
            });
        }

        std.debug.assert(surface.format == wgpu.WGPUTextureFormat_Undefined);
        surface.format = surf.getSurfaceFormat(surface.surface, self.adapter).?;
        std.debug.print("Surface format: {s}\n", .{formatName(surface.format)});

        self.device = self.requestDevice().?;
        self.queue = self.device.wgpuDeviceGetQueue() orelse @panic("wgpuDeviceGetQueue failed");

        self.uploadCommands = Commands.create(self, "DeviceUpload");

        self.downsample = Downsample.create(self, "data/downsample.wgsl") catch unreachable;

        self.inited = true;
    }

    fn waitFor(instance: handles.Instance, completed: *const bool) void {
        while (!completed.*) {
            _ = instance.wgpuInstanceProcessEvents();
            var req = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
            _ = std.c.nanosleep(&req, null);
        }
    }

    fn requestAdapter(self: *Self, surface: *Surface) ?handles.Adapter {
        var result = RequestAdapterResult{};
        const options = wgpu.WGPURequestAdapterOptions{
            .compatibleSurface = surface.surface,
            .powerPreference = wgpu.WGPUPowerPreference_HighPerformance,
        };
        _ = self.instance.wgpuInstanceRequestAdapter(&options, .{
            .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
            .callback = requestAdapterCallback,
            .userdata1 = &result,
        });
        waitFor(self.instance, &result.completed);
        return result.adapter;
    }

    fn requestDevice(self: *Self) ?handles.Device {
        var result = RequestDeviceResult{};
        var desc = wgpu.WGPUDeviceDescriptor{
            .label = handles.stringView("Device"),
            .uncapturedErrorCallbackInfo = .{ .callback = uncapturedErrorCallback },
        };
        _ = self.adapter.wgpuAdapterRequestDevice(&desc, .{
            .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
            .callback = requestDeviceCallback,
            .userdata1 = &result,
        });
        waitFor(self.instance, &result.completed);
        return result.device;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.inited);
        self.downsample.deinit();
        self.uploadCommands.deinit();
        wgpu.wgpuQueueRelease(self.queue);
        wgpu.wgpuDeviceRelease(self.device);
        wgpu.wgpuAdapterRelease(self.adapter);
        wgpu.wgpuInstanceRelease(self.instance);

        wgpu.wgpuSetLogLevel(wgpu.WGPULogLevel_Off);

        self.inited = false;
    }

    pub fn submit(self: *Self, cmds: *Commands, submitUploads: bool) void {
        var buffers: [2]wgpu.WGPUCommandBuffer = undefined;
        var buffersSlice: []wgpu.WGPUCommandBuffer = buffers[0..0];
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
            self.queue.wgpuQueueSubmit(buffersSlice.len, buffersSlice.ptr);
        util.releaseObj(wgpu.wgpuCommandBufferRelease, &cmds.commands);
        if (submitUploads)
            util.releaseObj(wgpu.wgpuCommandBufferRelease, &self.uploadCommands.commands);
    }
};

const RequestAdapterResult = struct {
    completed: bool = false,
    status: wgpu.WGPURequestAdapterStatus = 0,
    adapter: wgpu.WGPUAdapter = null,
};

const RequestDeviceResult = struct {
    completed: bool = false,
    status: wgpu.WGPURequestDeviceStatus = 0,
    device: wgpu.WGPUDevice = null,
};

fn requestAdapterCallback(
    status: wgpu.WGPURequestAdapterStatus,
    adapter: wgpu.WGPUAdapter,
    message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const result: *RequestAdapterResult = @ptrCast(@alignCast(userdata1));
    result.completed = true;
    result.status = status;
    result.adapter = adapter;
    if (status != wgpu.WGPURequestAdapterStatus_Success)
        std.debug.print("requestAdapter failed ({d}): {s}\n", .{ status, handles.stringSlice(message) orelse "" });
}

fn requestDeviceCallback(
    status: wgpu.WGPURequestDeviceStatus,
    device: wgpu.WGPUDevice,
    message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const result: *RequestDeviceResult = @ptrCast(@alignCast(userdata1));
    result.completed = true;
    result.status = status;
    result.device = device;
    if (status != wgpu.WGPURequestDeviceStatus_Success)
        std.debug.print("requestDevice failed ({d}): {s}\n", .{ status, handles.stringSlice(message) orelse "" });
}

fn uncapturedErrorCallback(
    device: [*c]const wgpu.WGPUDevice,
    errtype: wgpu.WGPUErrorType,
    message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    std.debug.print("Wgpu error ({d}): {s}\n", .{ errtype, handles.stringSlice(message) orelse "" });
}

fn logCallback(level: wgpu.WGPULogLevel, message: wgpu.WGPUStringView, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    std.debug.print("Wgpu {s}: {s}\n", .{ logLevelName(level), handles.stringSlice(message) orelse "" });
}

fn logLevelName(level: wgpu.WGPULogLevel) []const u8 {
    return switch (level) {
        wgpu.WGPULogLevel_Off => "off",
        wgpu.WGPULogLevel_Error => "error",
        wgpu.WGPULogLevel_Warn => "warn",
        wgpu.WGPULogLevel_Info => "info",
        wgpu.WGPULogLevel_Debug => "debug",
        wgpu.WGPULogLevel_Trace => "trace",
        else => "unknown",
    };
}

fn backendTypeName(backend: wgpu.WGPUBackendType) []const u8 {
    return switch (backend) {
        wgpu.WGPUBackendType_Undefined => "undefined",
        wgpu.WGPUBackendType_Null => "null",
        wgpu.WGPUBackendType_WebGPU => "webgpu",
        wgpu.WGPUBackendType_D3D11 => "d3d11",
        wgpu.WGPUBackendType_D3D12 => "d3d12",
        wgpu.WGPUBackendType_Metal => "metal",
        wgpu.WGPUBackendType_Vulkan => "vulkan",
        wgpu.WGPUBackendType_OpenGL => "opengl",
        wgpu.WGPUBackendType_OpenGLES => "opengles",
        else => "unknown",
    };
}

fn adapterTypeName(adapter_type: wgpu.WGPUAdapterType) []const u8 {
    return switch (adapter_type) {
        wgpu.WGPUAdapterType_DiscreteGPU => "discreteGPU",
        wgpu.WGPUAdapterType_IntegratedGPU => "integratedGPU",
        wgpu.WGPUAdapterType_CPU => "cpu",
        wgpu.WGPUAdapterType_Unknown => "unknown",
        else => "?",
    };
}

fn formatName(format: wgpu.WGPUTextureFormat) []const u8 {
    return switch (format) {
        wgpu.WGPUTextureFormat_Undefined => "undefined",
        wgpu.WGPUTextureFormat_R8Unorm => "r8unorm",
        wgpu.WGPUTextureFormat_RG8Unorm => "rg8unorm",
        wgpu.WGPUTextureFormat_RGBA8Unorm => "rgba8unorm",
        wgpu.WGPUTextureFormat_RGBA8UnormSrgb => "rgba8unorm-srgb",
        wgpu.WGPUTextureFormat_BGRA8Unorm => "bgra8unorm",
        wgpu.WGPUTextureFormat_BGRA8UnormSrgb => "bgra8unorm-srgb",
        wgpu.WGPUTextureFormat_Depth32Float => "depth32float",
        wgpu.WGPUTextureFormat_Depth24Plus => "depth24plus",
        wgpu.WGPUTextureFormat_Depth24PlusStencil8 => "depth24plus-stencil8",
        else => "unknown",
    };
}
