const std = @import("std");
const dtype = @import("dtype.zig");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    const testing = std.testing;
    try testing.expect(add(3, 7) == 10);
}

// vim: set tw=100 sw=4 expandtab:
