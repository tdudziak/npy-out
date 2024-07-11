comptime {
    _ = @import("npy-out.zig");
    _ = @import("dtype.zig");
}
const std = @import("std");

fn openDataDir(allocator: std.mem.Allocator) !std.fs.Dir {
    const src_file = try std.fs.cwd().realpathAlloc(allocator, @src().file);
    defer allocator.free(src_file);
    const src_dir = std.fs.path.dirname(src_file) orelse "";
    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{ src_dir, "..", "data" });
    defer allocator.free(data_dir);
    return std.fs.openDirAbsolute(data_dir, .{});
}

/// Verifies that the contents of the file pointed to by `fp` match the contents of the file with a
/// given name in the `data` directory.
pub fn expectEqualsReferenceFile(fname: []const u8, fp: std.fs.File) !void {
    var data_dir = try openDataDir(std.testing.allocator);
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

/// Allows to override the output directory for the tests by setting the `NPY_OUT_DIR` environment
/// variable. If the variable is not set, a temporary directory is used and the output file is
/// deleted after the test.
const OutDir = union(enum) {
    tmpDir: std.testing.TmpDir,
    outDir: std.fs.Dir,

    const Self = @This();

    fn init() !Self {
        if (std.process.getEnvVarOwned(std.testing.allocator, "NPY_OUT_DIR")) |path| {
            defer std.testing.allocator.free(path);
            const out_dir = try std.fs.openDirAbsolute(path, .{});
            return Self{ .outDir = out_dir };
        } else |_| {
            const tmp_dir = std.testing.tmpDir(.{});
            return Self{ .tmpDir = tmp_dir };
        }
    }

    fn dir(self: *const Self) std.fs.Dir {
        return switch (self.*) {
            .tmpDir => self.tmpDir.dir,
            .outDir => self.outDir,
        };
    }

    fn deinit(self: *Self) void {
        switch (self.*) {
            .tmpDir => self.tmpDir.cleanup(),
            .outDir => self.outDir.close(),
        }
    }
};

/// Serializes the given slice to a temporary file with `save()` and verifies that the output
/// matches the contents of a file with a given name in the `data` directory.
pub fn expectEqualsReferenceSaved(fname: []const u8, slice: anytype) !void {
    var out = try OutDir.init();
    defer out.deinit();
    var fp = try out.dir().createFile(fname, .{ .read = true });
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

test "embedded_struct.npy" {
    const Foo = extern struct {
        a: i16,
        b: i16,
        point: extern struct {
            x: f32,
            y: f32,
        },

        inline fn init(n: i16) @This() {
            const nf: f32 = @floatFromInt(n);
            return @This(){ .a = n, .b = 10 + n, .point = .{ .x = -nf, .y = 100 + nf } };
        }
    };
    const data = [_]Foo{
        Foo.init(1),
        Foo.init(2),
        Foo.init(3),
        Foo.init(4),
    };
    return expectEqualsReferenceSaved("embedded_struct.npy", &data);
}

test "matrix.npy" {
    const data = [3][3]f32{
        [3]f32{ 1.0, 2.0, 3.0 },
        [3]f32{ 4.0, 5.0, 6.0 },
        [3]f32{ 7.0, 8.0, 9.0 },
    };
    return expectEqualsReferenceSaved("matrix.npy", &data);
}

test "embedded_array.npy" {
    const Foo = extern struct {
        vals16: [4]i16,
        vals32: [2]f32,
        matrix: [2][2]f32,

        inline fn init(comptime n: comptime_int) @This() {
            const nf: f32 = @floatFromInt(n);
            return @This(){
                .vals16 = [4]i16{ n, n + 1, n + 2, n + 3 },
                .vals32 = [2]f32{ nf, -nf },
                .matrix = [2][2]f32{
                    [2]f32{ nf, nf + 1 },
                    [2]f32{ nf + 2, nf + 3 },
                },
            };
        }
    };
    const data = [_]Foo{
        Foo.init(-10),
        Foo.init(0),
        Foo.init(10),
    };
    return expectEqualsReferenceSaved("embedded_array.npy", &data);
}

// vim: set tw=100 sw=4 expandtab:
