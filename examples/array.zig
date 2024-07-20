const std = @import("std");
const npy_out = @import("npy-out");

pub fn main() !void {
    // prepare an array of numbers
    var numbers: [1000]f32 = undefined;
    for (0..numbers.len) |i| {
        numbers[i] = @floatFromInt(i);
    }

    // save it to a file
    var fp = try std.fs.cwd().createFile("array.npy", .{});
    defer fp.close();
    try npy_out.save(fp.writer().any(), &numbers);
}
