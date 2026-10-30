const std = @import("std");
const wgpu = @import("wgpu");
const glfw = @import("zglfw");

const handles = @import("handles.zig");
const util = @import("util.zig");
const devi = @import("device.zig");
const Device = devi.Device;

pub const AcquireTextureError = error{
    SurfaceNeedsConfigure,
    SurfaceLost,
};

pub const Surface = struct {
    surface: handles.Surface,
    format: wgpu.WGPUTextureFormat = wgpu.WGPUTextureFormat_Undefined,
    name: []const u8,
    device: *Device,
    surfaceView: ?handles.TextureView = null,
    configured: bool = false,

    const Self = @This();

    pub fn create(device: *Device, window: *glfw.Window, name: []const u8) Self {
        var chain = getSurfaceChain(window);
        const ownName = device.alloc.dupe(u8, name) catch unreachable;
        return .{
            .surface = device.instance.wgpuInstanceCreateSurface(&.{
                .nextInChain = chain.ptr(),
                .label = handles.stringView(ownName),
            }) orelse @panic("wgpuInstanceCreateSurface failed"),
            .name = ownName,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.surfaceView == null);
        wgpu.wgpuSurfaceRelease(self.surface);
        self.device.alloc.free(self.name);
    }

    pub fn configure(self: *Self, size: [2]u32, presentMode: wgpu.WGPUPresentMode) void {
        std.debug.assert(self.surfaceView == null);
        // wgpu refuses to re-configure a surface that still has a presentation;
        // an explicit unconfigure keeps resize/reconfigure legal.
        if (self.configured)
            wgpu.wgpuSurfaceUnconfigure(self.surface);
        var config = wgpu.WGPUSurfaceConfiguration{
            .device = self.device.device,
            .format = self.format,
            .usage = wgpu.WGPUTextureUsage_RenderAttachment,
            .width = size[0],
            .height = size[1],
            .presentMode = presentMode,
        };
        wgpu.wgpuSurfaceConfigure(self.surface, &config);
        self.configured = true;
    }

    pub fn acquireTexture(self: *Self) AcquireTextureError!handles.TextureView {
        std.debug.assert(self.surfaceView == null);
        if (!self.configured)
            return AcquireTextureError.SurfaceNeedsConfigure;
        var surfTex: wgpu.WGPUSurfaceTexture = undefined;
        wgpu.wgpuSurfaceGetCurrentTexture(self.surface, &surfTex);
        return switch (surfTex.status) {
            wgpu.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal => blk: {
                const view = surfTex.texture.?.wgpuTextureCreateView(null) orelse
                    return AcquireTextureError.SurfaceNeedsConfigure;
                self.surfaceView = view;
                break :blk view;
            },
            // Transient states: unconfigure and configure again with the new size.
            wgpu.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal,
            wgpu.WGPUSurfaceGetCurrentTextureStatus_Outdated,
            wgpu.WGPUSurfaceGetCurrentTextureStatus_Timeout,
            wgpu.WGPUSurfaceGetCurrentTextureStatus_Occluded,
            => AcquireTextureError.SurfaceNeedsConfigure,
            else => AcquireTextureError.SurfaceLost,
        };
    }

    pub fn present(self: *Self) void {
        std.debug.assert(self.surfaceView != null);
        _ = wgpu.wgpuSurfacePresent(self.surface);
        util.releaseObj(wgpu.wgpuTextureViewRelease, &self.surfaceView);
    }
};

const SurfaceChain = union(enum) {
    win32: wgpu.WGPUSurfaceSourceWindowsHWND,
    x11: wgpu.WGPUSurfaceSourceXlibWindow,
    xcb: wgpu.WGPUSurfaceSourceXCBWindow,
    wayland: wgpu.WGPUSurfaceSourceWaylandSurface,

    const Self = @This();

    pub fn ptr(self: *Self) [*c]wgpu.WGPUChainedStruct {
        return switch (self.*) {
            .win32 => |*v| &v.chain,
            .x11 => |*v| &v.chain,
            .xcb => |*v| &v.chain,
            .wayland => |*v| &v.chain,
        };
    }
};

const builtin = @import("builtin");
pub const getSurfaceChain: fn (window: *glfw.Window) SurfaceChain = switch (builtin.target.os.tag) {
    .windows => getSurfaceChainWin32,
    .linux => getSurfaceChainLinux,
    else => @panic("unsupported platform for wgpu surfaces"),
};

fn getSurfaceChainLinux(window: *glfw.Window) SurfaceChain {
    if (glfw.getX11Display()) |display| {
        return .{ .x11 = .{
            .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceXlibWindow },
            .display = display,
            .window = glfw.getX11Window(window),
        } };
    }
    return .{ .wayland = .{
        .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWaylandSurface },
        .display = glfw.getWaylandDisplay() orelse @panic("no wayland display"),
        .surface = glfw.getWaylandWindow(window) orelse @panic("no wayland surface"),
    } };
}

fn getSurfaceChainWin32(window: *glfw.Window) SurfaceChain {
    return .{ .win32 = .{
        .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWindowsHWND },
        .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
        .hwnd = glfw.getWin32Window(window).?,
    } };
}

pub fn getSurfaceFormat(surface: handles.Surface, adapter: handles.Adapter) ?wgpu.WGPUTextureFormat {
    var caps: wgpu.WGPUSurfaceCapabilities = undefined;
    if (wgpu.wgpuSurfaceGetCapabilities(surface, adapter, &caps) != wgpu.WGPUStatus_Success)
        return null;
    defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);
    return if (caps.formatCount > 0) caps.formats[0] else null;
}
