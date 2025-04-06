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
