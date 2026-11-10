const std = @import("std");

const wgfx = @import("../render/wgfx.zig");

const vm = @import("../math/vec_math.zig");
const geom = @import("../math/geom.zig");
const spatial = @import("../math/spatial.zig");

const rc = @import("../util/rc_ptr.zig");

const Vec3 = vm.Vec(3, f32);
const Mat4 = vm.Mat(4, 4, f32);
const Transform = geom.Transform(3, f32);

pub const ShaderPtr = rc.SharedPtr(wgfx.Shader, rc.DeinitCallContext);
pub const LightPtr = rc.SharedPtr(Light, Light);
pub const MaterialPtr = rc.SharedPtr(Material, Material);
pub const MeshPtr = rc.SharedPtr(Mesh, Mesh);
pub const ObjectPtr = rc.SharedPtr(Object, Object);

pub const Camera = struct {
    transform: Transform = .{},
    proj: Mat4,

    const Self = @This();
    pub fn getView(self: *const Self) Mat4 {
        return self.transform.rotation
    }


};

pub const Light = struct {
    params: []u8,
    paramsBuffer: wgfx.Buffer,

    const Self = @This();

    pub fn init() !Light {

    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {

    }
};

pub const Material = struct {
    shader: ShaderPtr,
    params: []u8,
    paramsBuffer: wgfx.Buffer,

    const Self = @This();

    pub fn init() !Material {

    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {

    }
};

pub const Mesh = struct {
    vertices: wgfx.Buffer,
    indices: wgfx.Buffer,
    numIndices: u32,

    const Self = @This();

    pub fn init() !Mesh {

    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {

    }
};

pub const Object = struct {
    material: MaterialPtr = .{},
    mesh: MeshPtr = {},
    transform: Transform = .{},

    const Self = @This();

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {

    }
};

pub const Scene = struct {
    tree: SpatialTree,
    light: Light,
    camera: Camera,

    const Self = @This();
    const SpatialTree = spatial.GeomTree(3, ObjectPtr);

    pub fn deinit(self: *Self) void {

    }

    pub fn render(self: *const Self) void {

    }
};