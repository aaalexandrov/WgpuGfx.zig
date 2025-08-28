const std = @import("std");

pub fn findFirstInteger(str: []const u8) []const u8 {
    var start: u32 = 0;
    while (start < str.len and !std.ascii.isDigit(str[start])) {
        start += 1;
    }

    var end = start;
    while (end < str.len and std.ascii.isDigit(str[end])) {
        end += 1;
    }

    return str[start..end];
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
