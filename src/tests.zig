comptime {
    _ = @import("npy-out.zig");
    _ = @import("dtype.zig");
}
const std = @import("std");

pub fn expectReference(fname: []const u8, fp: std.fs.File) !void {
    // TODO: find project root with @src()?
    var data_dir = try std.fs.cwd().openDir("data", .{});
    defer data_dir.close();
    var fp_ref = try data_dir.openFile(fname, .{});
    defer fp_ref.close();
    try fp.seekTo(0);

    var off: usize = 0;
    while (true) {
        const a: i16 = if (fp_ref.reader().readByte()) |x| @intCast(x) else |_| -1;
        const b: i16 = if (fp.reader().readByte()) |x| @intCast(x) else |_| -1;
        if (a != b) {
            std.debug.print("Mismatch in {s} offset {}: {d} vs {d}\n", .{ fname, off, a, b });
            return error.TestUnexpectedResult;
        }
        if (a == -1) {
            break;
        }
        off += 1;
    }
}

// vim: set tw=100 sw=4 expandtab:
