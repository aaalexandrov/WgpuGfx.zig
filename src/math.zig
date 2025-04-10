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
        const Eps: T = 1e-6;

        pub fn vec(v: Vec) Self {
            return Self{ .data = v };
        }

        pub fn splat(e: Elem) Self {
            return Self{ .data = @splat(e) };
        }

        pub fn cardinal(e: Elem, d: usize) Self {
            var res: Self = undefined;
            inline for (0..N) |i| {
                res.data[i] = if (i == d) e else 0;
            }
            return res;
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

        pub fn at(self: Self, index: anytype) Elem {
            const i = cast(i32, index);
            const idx = if (i >= 0) i else N + i;
            return self.data[@intCast(idx)];
        }

        pub fn field(self: Self, fld: Fields) Elem {
            return self.data[@intFromEnum(fld)];
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

        pub fn mul(self: Self, v: anytype) if (isMatType(@TypeOf(v))) @TypeOf(v).Row else Self {
            if (comptime isMatType(@TypeOf(v))) {
                const Mat = @TypeOf(v);
                if (Self != Mat.Col)
                    @compileError("Vector doesn't match matrix column type");
                var res: Mat.Row = undefined;
                for (0..Mat.Row.Dim) |c| {
                    res.data[c] = self.dot(v.col(c));
                }
                return res;
            } else {
                return vec(self.data * toVec(v).data);
            }
        }

        pub fn div(self: Self, v: anytype) Self {
            return vec(self.data / toVec(v).data);
        }

        pub fn rcp(self: Self) Self {
            return vec(@as(Vec, @splat(1)) / self.data);
        }

        pub fn sqr(self: Self) Self {
            return self.mul(self);
        }

        pub fn sqrt(self: Self) Self {
            return vec(@sqrt(self.data));
        }

        pub fn dot(self: Self, v: Self) Elem {
            return @reduce(.Add, self.data * v.data);
        }

        pub fn length2(self: Self) Elem {
            return self.dot(self);
        }

        pub fn length(self: Self) Elem {
            return @sqrt(self.length2());
        }

        pub fn normalizeEps(self: Self, eps: T) Self {
            const len = self.length();
            return if (len <= eps) self else self.div(len);
        }

        pub fn normalize(self: Self) Self {
            return self.normalizeEps(Eps);
        }

        pub fn proj(self: Self, onto: Self) Self {
            return onto.mul(self.dot(onto) / onto.dot(onto));
        }

        pub fn ortho(self: Self, orthogonal: Self) Self {
            return self - self.proj(orthogonal);
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

    try std.testing.expect(v1.length() == @sqrt(v1.data[0] * v1.data[0] + v1.data[1] * v1.data[1] + v1.data[2] * v1.data[2]));

    try std.testing.expectEqual(v1.at(Vec3f.Fields.y), 2);
    try std.testing.expectEqual(v1.at(-2), 2);
    try std.testing.expectEqual(v1.field(.z), 3);

    const vs = v1.swizzle(.{ .z, .y, .x });
    try std.testing.expect(@reduce(.And, vs.data == Vec3f.vec(.{ 3, 2, 1 }).data));

    try std.testing.expect(@reduce(.And, v1.add(5).data == Vec3f.vec(.{ 6, 7, 8 }).data));

    const vx = Vec3f.vec(.{ 1, 0, 0 });
    const vy = Vec3f.vec(.{ 0, 1, 0 });
    const vz = Vec3f.vec(.{ 0, 0, 1 });
    try std.testing.expect(@reduce(.And, vz.data == vx.cross(vy).data));
    try std.testing.expect(@reduce(.And, vy.cross(vx).data == -vx.cross(vy).data));
}

pub fn MatType(comptime R: comptime_int, comptime C: comptime_int, T: type) type {
    return struct {
        data: [C]Col.Vec,

        const Row = VecType(C, T);
        const Col = VecType(R, T);
        const Rows = R;
        const Cols = C;
        const Elem = T;

        const Self = @This();
        const Eps: T = 1e-6;

        pub fn fromCols(cols: [C]Col) Self {
            var res: Self = undefined;
            inline for (0..C) |c| {
                res.data[c] = cols[c];
            }
            return res;
        }

        pub fn mat(cols: [C]Col.Vec) Self {
            return Self{ .data = cols };
        }

        pub fn splat(e: T) Self {
            var res: Self = undefined;
            inline for (0..C) |c| {
                res.data[c] = Col.splat(e).data;
            }
            return res;
        }

        pub fn diag(e: anytype) Self {
            var res: Self = Self.splat(0);
            const DiagType = VecType(@min(R, C), T);
            const d = DiagType.toVec(e).data;
            inline for (0..DiagType.Dim) |i| {
                res.data[i][i] = d[i];
            }
            return res;
        }

        pub fn col(self: Self, c: anytype) Col {
            return Col.vec(self.data[cast(usize, c)]);
        }

        pub fn row(self: Self, r: anytype) Row {
            var res: Row = undefined;
            inline for (0..C) |c| {
                res.data[c] = self.data[c][r];
            }
            return res;
        }

        pub fn transpose(self: Self) MatType(C, R, T) {
            var trans: MatType(C, R, T) = undefined;
            inline for (0..R) |r| {
                trans.data[r] = self.row(r).data;
            }
            return trans;
        }

        pub fn opPerColUnary(comptime op: type, self: Self) Self {
            var res: Self = undefined;
            inline for (0..Cols) |c| {
                res.data[c] = op.op(self.data[c]);
            }
            return res;
        }

        pub fn neg(self: Self) Self {
            const op = struct {
                fn op(c: Col.Vec) Col.Vec {
                    return -c;
                }
            };
            return opPerColUnary(op, self);
        }

        pub fn rcp(self: Self) Self {
            const op = struct {
                fn op(c: Col.Vec) Col.Vec {
                    return Col.vec(c).rcp().data;
                }
            };
            return opPerColUnary(op, self);
        }

        pub fn sqrt(self: Self) Self {
            const op = struct {
                fn op(c: Col.Vec) Col.Vec {
                    return @sqrt(c);
                }
            };
            return opPerColUnary(op, self);
        }

        pub fn opPerColBinary(comptime op: anytype, self: Self, m: anytype) Self {
            var res: Self = undefined;
            inline for (0..Cols) |c| {
                var mc: Col.Vec = undefined;
                if (@TypeOf(m) == Self) {
                    mc = m.data[c];
                } else {
                    mc = cast(Col.Vec, m);
                }
                res.data[c] = op.op(self.data[c], mc);
            }
            return res;
        }

        pub fn add(self: Self, m: anytype) Self {
            const op = struct {
                fn op(c: Col.Vec, mc: Col.Vec) Col.Vec {
                    return c + mc;
                }
            };
            return opPerColBinary(op, self, m);
        }

        pub fn sub(self: Self, m: anytype) Self {
            const op = struct {
                fn op(c: Col.Vec, mc: Col.Vec) Col.Vec {
                    return c - mc;
                }
            };
            return opPerColBinary(op, self, m);
        }

        pub fn mul(self: Self, v: anytype) if (@TypeOf(v) == Row) Col else MatType(Rows, @TypeOf(v).Cols, T) {
            if (@TypeOf(v) == Row) {
                var res = self.data[0] * @as(Col.Vec, @splat(v.data[0]));
                inline for (1..C) |c| {
                    res += self.data[c] * @as(Col.Vec, @splat(v.data[c]));
                }
                return Col.vec(res);
            } else if (comptime isMatType(@TypeOf(v))) {
                const Mat = @TypeOf(v);
                if (comptime Cols != Mat.Rows)
                    @compileError("Incompatible matrix dimensions");
                const Res = MatType(Rows, Mat.Cols, T);
                var res: Res = undefined;
                inline for (0..Res.Cols) |c| {
                    var s = @as(Res.Col.Vec, @splat(v.data[c][0]));
                    res.data[c] = self.data[0] * s;
                    inline for (1..C) |i| {
                        s = @as(Res.Col.Vec, @splat(v.data[c][i]));
                        res.data[c] += self.data[i] * s;
                    }
                }
                return res;
            } else {
                const op = struct {
                    fn op(c: Col.Vec, mc: Col.Vec) Col.Vec {
                        return c * mc;
                    }
                };
                return opPerColBinary(op, self, v);
            }
        }

        pub fn div(self: Self, m: anytype) Self {
            const op = struct {
                fn op(c: Col.Vec, mc: Col.Vec) Col.Vec {
                    return c / mc;
                }
            };
            return opPerColBinary(op, self, m);
        }

        pub fn eql(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res.data[c] = self.col(c).eql(m.col(c)).all();
            }
            return res;
        }

        pub fn notEql(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res[c] = self.col(c).notEql(m.col(c)).all();
            }
            return res;
        }

        pub fn less(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res[c] = self.col(c).less(m.col(c)).all();
            }
            return res;
        }

        pub fn lessEql(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res[c] = self.col(c).lessEql(m.col(c)).all();
            }
            return res;
        }

        pub fn greater(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res[c] = self.col(c).greater(m.col(c)).all();
            }
            return res;
        }

        pub fn greaterEql(self: Self, m: Self) Row.BSelf {
            var res: Row.BSelf = undefined;
            inline for (0..C) |c| {
                res[c] = self.col(c).greaterEql(m.col(c)).all();
            }
            return res;
        }
    };
}

test MatType {
    const Mat3x4f = MatType(3, 4, f32);
    const Mat4x3f = MatType(4, 3, f32);
    const Mat3x2f = MatType(3, 2, f32);
    const Mat4x2f = MatType(4, 2, f32);
    const Vec3f = VecType(3, f32);
    const Vec4f = VecType(4, f32);
    const m0 = Mat3x4f.diag(1);
    try std.testing.expect(m0.col(0).eql(Mat3x4f.Col.vec(.{ 1, 0, 0 })).all());
    try std.testing.expect(m0.col(1).eql(Mat3x4f.Col.vec(.{ 0, 1, 0 })).all());
    try std.testing.expect(m0.col(2).eql(Mat3x4f.Col.vec(.{ 0, 0, 1 })).all());
    try std.testing.expect(m0.col(3).eql(Mat3x4f.Col.vec(.{ 0, 0, 0 })).all());

    try std.testing.expect(m0.transpose().eql(Mat4x3f.diag(@Vector(3, i32){ 1, 1, 1 })).all());

    const m1 = Mat4x3f.mat(.{
        .{ 1, 0, 0, 3 },
        .{ 0, 1, 0, 4 },
        .{ 0, 0, 1, 5 },
    });
    const v1 = Vec4f.vec(.{ 0, 1, 0, 1 });
    try std.testing.expect(v1.mul(m1).eql(Vec3f.vec(.{ 3, 5, 5 })).all());
    try std.testing.expect(m1.transpose().mul(v1).eql(Vec3f.vec(.{ 3, 5, 5 })).all());

    const m2 = Mat3x2f.mat(.{
        .{ 2, 0, 0 },
        .{ 0, 2, 0 },
    });
    const res12 = Mat4x2f.mat(.{
        .{ 2, 0, 0, 6 },
        .{ 0, 2, 0, 8 },
    });
    try std.testing.expect(m1.mul(m2).eql(res12).all());
    try std.testing.expect(res12.neg().eql(Mat4x2f.mat(.{
        -res12.data[0],
        -res12.data[1],
    })).all());

    try std.testing.expect(m2.add(5).eql(Mat3x2f.mat(.{
        m2.data[0] + Vec3f.splat(5).data,
        m2.data[1] + Vec3f.splat(5).data,
    })).all());
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

pub fn isVecType(comptime t: type) bool {
    return comptime (std.mem.indexOf(u8, @typeName(t), ".VecType(") != null);
}

pub fn isMatType(comptime t: type) bool {
    return comptime (std.mem.indexOf(u8, @typeName(t), ".MatType(") != null);
}

pub fn cast(comptime T: type, v: anytype) T {
    if (@TypeOf(v) == T)
        return v;
    return switch (@typeInfo(T)) {
        .float => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float => @as(T, @floatCast(v)),
            .int, .comptime_int => @as(T, @floatFromInt(v)),
            .bool => @as(T, if (v) 1 else 0),
            .@"enum" => |enm| @as(T, @floatFromInt(@as(enm.tag_type, @intFromEnum(v)))),
            else => @compileError("Invalid typecast"),
        },
        .int => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float => @as(T, @intFromFloat(v)),
            .int, .comptime_int => @as(T, @intCast(v)),
            .bool => @as(T, if (v) 1 else 0),
            .@"enum" => @as(T, @intFromEnum(v)),
            else => @compileError("Invalid typecast"),
        },
        .bool => switch (@typeInfo(@TypeOf(v))) {
            .float, .comptime_float, .int, .comptime_int => v != 0,
            .@"enum" => @intFromEnum(v) != 0,
            else => @compileError("Invalid typecast"),
        },
        .@"enum" => |enm| @as(T, @enumFromInt(cast(enm.tag_type, v))),
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

    const eXYZ = enum { x, y, z };

    try std.testing.expectEqual(cast(i32, eXYZ.y), @as(i32, 1));
    try std.testing.expectEqual(cast(eXYZ, 2.2), eXYZ.z);

    try std.testing.expectEqual(cast(f32, @as(u32, 42)), @as(f32, 42));
    try std.testing.expectEqual(cast(@Vector(3, f32), @as(u32, 5)), @Vector(3, f32){ 5, 5, 5 });
    try std.testing.expectEqual(cast(@Vector(3, bool), @as(u32, 5)), @Vector(3, bool){ true, true, true });
    try std.testing.expectEqual(cast(@Vector(2, bool), @Vector(3, f32){ 0, 0.5, 1 }), @Vector(2, bool){ false, true });
}
