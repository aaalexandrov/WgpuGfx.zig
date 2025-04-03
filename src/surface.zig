const std = @import("std");
const wgpu = @import("wgpu");
const glfw = @import("zglfw");

const devi = @import("device.zig");
const Device = devi.Device;

pub const AcquireTextureError = error {
    SurfaceNeedsConfigure,
    SurfaceLost,
};

pub const Surface = struct {
    surface: *wgpu.Surface,
    format: wgpu.TextureFormat = wgpu.TextureFormat.@"undefined",
    name: [:0]const u8,
    alloc: std.mem.Allocator,
    surfaceView: ?*wgpu.TextureView = null,
    configured: bool = false,

    const Self = @This();

    pub fn create(device: *Device, window: *glfw.Window, name: [:0]const u8) Self {
        const chained = getSurfaceChain(window);
        const ownName = device.alloc.dupeZ(u8, name) catch unreachable;
        return .{
            .surface = device.instance.createSurface(&wgpu.SurfaceDescriptor{
                .next_in_chain = &chained.chain,
                .label = ownName,
            }).?,
            .name = ownName,
            .alloc = device.alloc,
        };
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.surfaceView == null);
        self.surface.release();
        self.alloc.free(self.name);
    }

    pub fn configure(self: *Self, device: *Device, size: [2]u32, presentMode: wgpu.PresentMode) void {
        std.debug.assert(self.surfaceView == null);
        self.surface.configure(&wgpu.SurfaceConfiguration{
            .device = device.device.?,
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
        if (surfTex.suboptimal != 0)
            return AcquireTextureError.SurfaceNeedsConfigure;
        switch (surfTex.status) {
            .success => {
                self.surfaceView = surfTex.texture.createView(null).?;
                return self.surfaceView.?;
            },
            .outdated, .lost => return AcquireTextureError.SurfaceNeedsConfigure,
            else => return AcquireTextureError.SurfaceLost,
        }
    }

    pub fn present(self: *Self) void {
        std.debug.assert(self.surfaceView != null);
        self.surface.present();
        devi.releaseObj(&self.surfaceView);
    }
};

const builtin = @import("builtin");
pub const getSurfaceChain = switch (builtin.target.os.tag) {
    .windows => getSurfaceChainWin32,
    .linux => getSurfaceChainX11,
    else => unreachable,
};

fn getSurfaceChainX11(window: *glfw.Window) wgpu.SurfaceDescriptorFromXlibWindow {
    return wgpu.SurfaceDescriptorFromXlibWindow{
        .display = glfw.getX11Display().?,
        .window = glfw.getX11Window(window),
    };
}

fn getSurfaceChainWin32(window: *glfw.Window) wgpu.SurfaceDescriptorFromWindowsHWND {
    return wgpu.SurfaceDescriptorFromWindowsHWND{
        .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
        .hwnd = glfw.getWin32Window(window).?,
    };
}

pub fn getSurfaceFormat(surface: *wgpu.Surface, adapter: *wgpu.Adapter) ?wgpu.TextureFormat {
    var surfaceCaps: wgpu.SurfaceCapabilities = undefined;
    surface.getCapabilities(adapter, &surfaceCaps);
    defer surfaceCaps.freeMembers();
    return if (surfaceCaps.format_count > 0) surfaceCaps.formats[0] else null;
}
