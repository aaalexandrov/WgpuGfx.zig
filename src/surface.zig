const std = @import("std");
const wgpu = @import("wgpu");
const glfw = @import("zglfw");

const util = @import("util.zig");
const devi = @import("device.zig");
const Device = devi.Device;

pub const AcquireTextureError = error{
    SurfaceNeedsConfigure,
    SurfaceLost,
};

pub const Surface = struct {
    surface: *wgpu.Surface,
    format: wgpu.TextureFormat = wgpu.TextureFormat.undefined,
    name: []const u8,
    device: *Device,
    surfaceView: ?*wgpu.TextureView = null,
    configured: bool = false,

    const Self = @This();

    pub fn create(device: *Device, window: *glfw.Window, name: []const u8) Self {
        const chained = getSurfaceChain(window);
        const ownName = device.alloc.dupe(u8, name) catch unreachable;
        return .{
            .surface = device.instance.createSurface(&wgpu.SurfaceDescriptor{
                .next_in_chain = chained.getChain().?,
                .label = wgpu.StringView.fromSlice(ownName),
            }).?,
            .name = ownName,
            .device = device,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.surfaceView == null);
        self.surface.release();
        self.device.alloc.free(self.name);
    }

    pub fn configure(self: *Self, size: [2]u32, presentMode: wgpu.PresentMode) void {
        std.debug.assert(self.surfaceView == null);
        self.surface.configure(&wgpu.SurfaceConfiguration{
            .device = self.device.device,
            .format = self.format,
            .width = size[0],
            .height = size[1],
            .present_mode = presentMode,
        });
        self.configured = true;
    }

    pub fn acquireTexture(self: *Self) AcquireTextureError!*wgpu.TextureView {
        std.debug.assert(self.surfaceView == null);
        if (!self.configured)
            return AcquireTextureError.SurfaceNeedsConfigure;
        var surfTex: wgpu.SurfaceTexture = undefined;
        self.surface.getCurrentTexture(&surfTex);
        switch (surfTex.status) {
            .success_optimal => {
                self.surfaceView = surfTex.texture.?.createView(null).?;
                return self.surfaceView.?;
            },
            .outdated, .lost, .success_suboptimal => return AcquireTextureError.SurfaceNeedsConfigure,
            else => return AcquireTextureError.SurfaceLost,
        }
    }

    pub fn present(self: *Self) void {
        std.debug.assert(self.surfaceView != null);
        _ = self.surface.present();
        util.releaseObj(&self.surfaceView);
    }
};

const SurfaceChain = union(enum) {
    win32: wgpu.SurfaceSourceWindowsHWND,
    x11: wgpu.SurfaceSourceXlibWindow,
    wayland: wgpu.SurfaceSourceWaylandSurface,
    empty,

    const Self = @This();

    pub fn getChain(self: *const Self) ?*const wgpu.ChainedStruct {
        return switch (self.*) {
            .win32 => |val| &val.chain,
            .x11 => |val| &val.chain,
            .wayland => |val| &val.chain,
            .empty => null,
        };
    }
};

const builtin = @import("builtin");
pub const getSurfaceChain: fn (window: *glfw.Window) SurfaceChain = switch (builtin.target.os.tag) {
    .windows => getSurfaceChainWin32,
    .linux => getSurfaceChainLinux,
    else => unreachable
};

fn getSurfaceChainLinux(window: *glfw.Window) SurfaceChain {
    return if (glfw.getX11Display()) |display|
        SurfaceChain{ .x11 = wgpu.SurfaceSourceXlibWindow{
            .display = display,
            .window = glfw.getX11Window(window),
        } }
    else
        SurfaceChain{ .wayland = wgpu.SurfaceSourceWaylandSurface{
            .display = glfw.getWaylandDisplay().?,
            .surface = glfw.getWaylandWindow(window).?,
        } };
}

fn getSurfaceChainWin32(window: *glfw.Window) SurfaceChain {
    return SurfaceChain{ .win32 = wgpu.SurfaceSourceWindowsHWND{
        .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
        .hwnd = glfw.getWin32Window(window).?,
    } };
}

pub fn getSurfaceFormat(surface: *wgpu.Surface, adapter: *wgpu.Adapter) ?wgpu.TextureFormat {
    var surfaceCaps: wgpu.SurfaceCapabilities = undefined;
    if (surface.getCapabilities(adapter, &surfaceCaps) != .success)
        return null;
    defer surfaceCaps.freeMembers();
    return if (surfaceCaps.format_count > 0) surfaceCaps.formats[0] else null;
}
