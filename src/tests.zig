comptime {
    _ = @import("npy-out.zig");
    _ = @import("dtype.zig");
}
const std = @import("std");

/// Verifies that the contents of the file pointed to by `fp` match the contents of the file with a
/// given name in the `data` directory.
pub fn expectEqualsReferenceFile(fname: []const u8, fp: std.fs.File) !void {
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

/// Serializes the given slice to a temporary file with `save()` and verifies that the output
/// matches the contents of a file with a given name in the `data` directory.
pub fn expectEqualsReferenceSaved(fname: []const u8, slice: anytype) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fp = try tmp.dir.createFile(fname, .{ .read = true });
    defer fp.close();
    try @import("npy-out.zig").save(fp, slice);
    return expectEqualsReferenceFile(fname, fp);
}

test "empty.npy" {
    const data = [_]f32{};
    return expectEqualsReferenceSaved("empty.npy", &data);
}

test "array.npy" {
    const data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    return expectEqualsReferenceSaved("array.npy", &data);
}

test "points.npy" {
    const Point = extern struct {
        x: f32,
        y: f32,
    };
    const data = [_]Point{ .{ .x = 10, .y = -100 }, .{ .x = 11, .y = -101 }, .{ .x = 12, .y = -102 } };
    return expectEqualsReferenceSaved("points.npy", &data);
}

test "padding.npy" {
    const Paddington = extern struct {
        smol: u8,
        // _: [7]u8,
        beeg: u64,
        teeny: i8,
        // _: [7]u8,
    };
    const data = [_]Paddington{
        .{ .smol = 1, .beeg = 1111111111111111111, .teeny = -2 },
        .{ .smol = 2, .beeg = 2222222222222222222, .teeny = -3 },
        .{ .smol = 3, .beeg = 3333333333333333333, .teeny = -4 },
        .{ .smol = 4, .beeg = 4444444444444444444, .teeny = -5 },
    };
    return expectEqualsReferenceSaved("padding.npy", &data);
}

test "person.npy" {
    const Person = extern struct {
        name: [6:0]u8,
        age: u8,

        inline fn init(name: []const u8, age: u8) @This() {
            var p = std.mem.zeroes(@This());
            p.age = age;
            if (name.len > p.name.len) {
                @panic("name too long");
            }
            @memcpy(p.name[0..name.len], name);
            return p;
        }
    };
    const data = [_]Person{
        Person.init("Alice", 25),
        Person.init("Bob", 30),
        Person.init("Albert", 35),
    };
    return expectEqualsReferenceSaved("person.npy", &data);
}

// vim: set tw=100 sw=4 expandtab:
