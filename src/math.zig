const std = @import("std");
const zm = @import("zmath");

pub fn VecType(comptime N: comptime_int, comptime T: type) type {
    const enumNames = [_][:0]const u8{ "x", "y", "z", "w" };
    const fieldsEnum = DeclEnum(enumNames[0..N]);
    return struct {
        data: Vec,

        const Vec = @Vector(N, T);
        const BVec = @Vector(N, bool);
        const Dim = N;
        const Elem = T;
        const Fields = fieldsEnum;

        const Self = @This();
        const BSelf = if (T == bool) Self else VecType(N, bool);

        pub fn vec(v: Vec) Self {
            return Self{ .data = v };
        }

        pub fn splat(e: Elem) Self {
            return Self{ .data = @splat(e) };
        }

        pub fn swizzle(self: Self, comptime fields: [N]Fields) Self {
            const mask = comptime blk: {
                var inds: [N]i32 = undefined;
                for (fields, 0..) |f, i| {
                    inds[i] = @intFromEnum(f);
                }
                break :blk inds;
            };
            return vec(@shuffle(Elem, self.data, undefined, mask));
        }

        pub fn toVec(v: anytype) Self {
            return switch (@TypeOf(v)) {
                Self => v,
                else => vec(cast(Vec, v)),
            };
        }

        pub fn add(self: Self, v: anytype) Self {
            return vec(self.data + toVec(v).data);
        }

        pub fn sub(self: Self, v: anytype) Self {
            return vec(self.data - toVec(v).data);
        }

        pub fn neg(self: Self) Self {
            return vec(-self.data);
        }

        pub fn mul(self: Self, v: anytype) Self {
            return vec(self.data * toVec(v).data);
        }

        pub fn div(self: Self, v: anytype) Self {
            return vec(self.data / toVec(v).data);
        }

        pub fn rcp(self: Self) Self {
            return vec(@as(Vec, @splat(1)) / self.data);
        }

        pub fn dot(self: Self, v: Self) Elem {
            return vec(@reduce(.Add, self.data * v.data));
        }

        pub fn length2(self: Self) Elem {
            return self.dot(self);
        }

        pub fn length(self: Self) Elem {
            return @sqrt(self.length2());
        }

        pub usingnamespace if (N == 3) struct {
            pub fn cross(self: Self, v: Self) Self {
                var s0 = self.swizzle(.{ .y, .z, .x });
                var v0 = v.swizzle(.{ .z, .x, .y });
                const result = s0.mul(v0);
                s0 = s0.swizzle(.{ .y, .z, .x });
                v0 = v0.swizzle(.{ .z, .x, .y });
                return result.sub(s0.mul(v0));
            }
        } else struct {};

        pub fn min(self: Self, v: anytype) Self {
            return vec(@min(self.data, toVec(v).data));
        }

        pub fn max(self: Self, v: anytype) Self {
            return vec(@max(self.data, toVec(v).data));
        }

        pub fn abs(self: Self) Self {
            return vec(@abs(self.data));
        }

        pub fn approxEql(self: Self, v: anytype, eps: Elem) BSelf {
            return self.sub(v).lessEql(eps);
        }

        pub fn eql(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data == toVec(v).data);
        }

        pub fn notEql(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data <= toVec(v).data);
        }

        pub fn less(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data < toVec(v).data);
        }

        pub fn lessEql(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data <= toVec(v).data);
        }

        pub fn greater(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data > toVec(v).data);
        }

        pub fn greaterEql(self: Self, v: anytype) BSelf {
            return BSelf.vec(self.data >= toVec(v).data);
        }

        pub usingnamespace if (T == bool) struct {
            pub fn all(self: Self) bool {
                return @reduce(.And, self.data);
            }
            pub fn any(self: Self) bool {
                return @reduce(.Or, self.data);
            }
            pub fn @"and"(self: Self, v: Self) Self {
                return vec(self.data & v.data);
            }
            pub fn @"or"(self: Self, v: Self) Self {
                return vec(self.data | v.data);
            }
        } else struct {};
    };
}

test VecType {
    const Vec3f = VecType(3, f32);
    const v1 = Vec3f{ .data = .{ 1, 2, 3 } };
    const v2 = Vec3f.vec(.{ 1, 2, 3 });
    try std.testing.expect(@reduce(.And, v1.data == v2.data));

    try std.testing.expect(v1.approxEql(v1.sub(0.01), 0.1).all());

    const vs = v1.swizzle(.{ .z, .y, .x });
    try std.testing.expect(@reduce(.And, vs.data == Vec3f.vec(.{ 3, 2, 1 }).data));

    try std.testing.expect(@reduce(.And, v1.add(5).data == Vec3f.vec(.{ 6, 7, 8 }).data));

    const vx = Vec3f.vec(.{ 1, 0, 0 });
    const vy = Vec3f.vec(.{ 0, 1, 0 });
    const vz = Vec3f.vec(.{ 0, 0, 1 });
    try std.testing.expect(@reduce(.And, vz.data == vx.cross(vy).data));
    try std.testing.expect(@reduce(.And, vy.cross(vx).data == -vx.cross(vy).data));
}

pub fn DeclEnum(comptime valNames: []const [:0]const u8) type {
    var enumDecls: [valNames.len]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (valNames, 0..) |val, i| {
        enumDecls[i] = .{ .name = val, .value = i };
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, if (valNames.len == 0) 0 else valNames.len - 1),
            .fields = &enumDecls,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}

test DeclEnum {
    const xyz = [_][:0]const u8{ "x", "y", "z" };
    const eXYZ = DeclEnum(&xyz);
    const e_XYZ = enum { x, y, z };
    try std.testing.expect(@typeInfo(eXYZ).@"enum".fields.len == @typeInfo(e_XYZ).@"enum".fields.len);
    try std.testing.expect(@typeInfo(eXYZ).@"enum".tag_type == @typeInfo(e_XYZ).@"enum".tag_type);
    inline for (@typeInfo(eXYZ).@"enum".fields, 0..) |field, i| {
        const field_ = @typeInfo(eXYZ).@"enum".fields[i];
        try std.testing.expect(std.mem.eql(u8, field.name, field_.name));
        try std.testing.expect(field.value == field_.value);
    }
}

pub fn cast(comptime T: type, v: anytype) T {
    if (@TypeOf(v) == T)
        return v;
    return switch (@typeInfo(T)) {
        .float => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float => @as(T, @floatCast(v)),
            .int, .comptime_int => @as(T, @floatFromInt(v)),
            .bool => @as(T, if (v) 1 else 0),
            else => @compileError("Invalid typecast"),
        },
        .int => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float => @as(T, @intFromFloat(v)),
            .int, .comptime_int => @as(T, @intCast(v)),
            .bool => @as(T, if (v) 1 else 0),
            else => @compileError("Invalid typecast"),
        },
        .bool => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float, .int, .comptime_int => v != 0,
            else => @compileError("Invalid typecast"),
        },
        .vector => |vectorT| switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float, .int, .comptime_int, .bool => @as(T, @splat(cast(vectorT.child, v))),
            .vector => |vectorV| blk: {
                if (vectorT.len > vectorV.len)
                    @compileError("Target typecast vector length is greater than the source");
                var res: T = undefined;
                for (0..vectorT.len) |i|
                    res[i] = cast(vectorT.child, v[i]);
                break :blk res;
            },
            else => @compileError("Invalid typecast"),
        },
        else => @compileError("Invalid typecast"),
    };
}

test cast {
    try std.testing.expectEqual(cast(bool, 0), false);
    try std.testing.expectEqual(cast(bool, 5.0), true);
    try std.testing.expectEqual(cast(bool, @as(f32, 0.5)), true);

    try std.testing.expectEqual(cast(f32, @as(u32, 42)), @as(f32, 42));
    try std.testing.expectEqual(cast(@Vector(3, f32), @as(u32, 5)), @Vector(3, f32){ 5, 5, 5 });
    try std.testing.expectEqual(cast(@Vector(3, bool), @as(u32, 5)), @Vector(3, bool){ true, true, true });
    try std.testing.expectEqual(cast(@Vector(2, bool), @Vector(3, f32){ 0, 0.5, 1 }), @Vector(2, bool){ false, true });
}
