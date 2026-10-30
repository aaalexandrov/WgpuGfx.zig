const std = @import("std");

pub const IntegerRange = struct { start: usize, end: usize };

pub fn findFirstIntegerRange(str: []const u8) ?IntegerRange {
    var start: usize = 0;
    while (start < str.len and !std.ascii.isDigit(str[start])) {
        start += 1;
    }

    var end = start;
    while (end < str.len and std.ascii.isDigit(str[end])) {
        end += 1;
    }

    return if (end > start) .{ .start = start, .end = end } else null;
}

pub fn findFirstInteger(str: []const u8) []const u8 {
    return if (findFirstIntegerRange(str)) |r| str[r.start..r.end] else "";
}

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

pub fn copyNameFromDescLabel(desc: anytype, alloc: std.mem.Allocator) []const u8 {
    return if (desc.label.toSlice()) |label| 
        alloc.dupe(u8, label) catch unreachable
    else 
        "";
}
