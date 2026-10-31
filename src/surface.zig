const std = @import("std");
const wgpu = @import("wgpu");
const sdl = @import("sdl3");

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

    pub fn create(device: *Device, window: *sdl.SDL_Window, name: []const u8) Self {
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
    metal: wgpu.WGPUSurfaceSourceMetalLayer,

    const Self = @This();

    pub fn ptr(self: *Self) [*c]wgpu.WGPUChainedStruct {
        return switch (self.*) {
            .win32 => |*v| &v.chain,
            .x11 => |*v| &v.chain,
            .xcb => |*v| &v.chain,
            .wayland => |*v| &v.chain,
            .metal => |*v| &v.chain,
        };
    }
};

const builtin = @import("builtin");
pub const getSurfaceChain: fn (window: *sdl.SDL_Window) SurfaceChain = switch (builtin.target.os.tag) {
    .windows => getSurfaceChainWin32,
    .linux => getSurfaceChainLinux,
    .macos => getSurfaceChainMetal,
    else => @panic("unsupported platform for wgpu surfaces"),
};

fn getSurfaceChainLinux(window: *sdl.SDL_Window) SurfaceChain {
    const windowPropsId = sdl.SDL_GetWindowProperties(window);
    const driverName = sdl.SDL_GetCurrentVideoDriver();
    if (std.mem.eql(u8, driverName[0..std.mem.len(driverName)], "x11"))
        return .{ .x11 = .{
            .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceXlibWindow },
            .display = sdl.SDL_GetPointerProperty(windowPropsId, sdl.SDL_PROP_WINDOW_X11_DISPLAY_POINTER, null),
            .window = @intCast(sdl.SDL_GetNumberProperty(windowPropsId, sdl.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0)),
        } };

    return .{ .wayland = .{
        .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWaylandSurface },
        .display = sdl.SDL_GetPointerProperty(windowPropsId, sdl.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, null),
        .surface = sdl.SDL_GetPointerProperty(windowPropsId, sdl.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, null),
    } };
}

fn getSurfaceChainWin32(window: *sdl.SDL_Window) SurfaceChain {
    const windowPropsId = sdl.SDL_GetWindowProperties(window);
    return .{ .win32 = .{
        .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWindowsHWND },
        .hinstance = sdl.SDL_GetPointerProperty(windowPropsId, sdl.SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER, null),
        .hwnd = sdl.SDL_GetPointerProperty(windowPropsId, sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null),
    } };
}

fn getSurfaceChainMetal(window: *sdl.SDL_Window) SurfaceChain {
    const metalView = sdl.SDL_Metal_CreateView(window);
    return .{ .metal = .{
        .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceMetalLayer },
        .layer = sdl.SDL_Metal_GetLayer(metalView),
    } };
}

pub fn getSurfaceFormat(surface: handles.Surface, adapter: handles.Adapter) ?wgpu.WGPUTextureFormat {
    var caps: wgpu.WGPUSurfaceCapabilities = undefined;
    if (wgpu.wgpuSurfaceGetCapabilities(surface, adapter, &caps) != wgpu.WGPUStatus_Success)
        return null;
    defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(caps);
    return if (caps.formatCount > 0) caps.formats[0] else null;
}
