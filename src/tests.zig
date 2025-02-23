comptime {
    _ = @import("npy-out.zig");
    _ = @import("zip-out.zig");
    _ = @import("dtype.zig");
    _ = @import("helper.zig");
    _ = @import("types.zig");
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
pub const OutDir = union(enum) {
    tmpDir: std.testing.TmpDir,
    outDir: std.fs.Dir,

    const Self = @This();

    pub fn init() !Self {
        if (std.process.getEnvVarOwned(std.testing.allocator, "NPY_OUT_DIR")) |path| {
            defer std.testing.allocator.free(path);
            const out_dir = try std.fs.openDirAbsolute(path, .{});
            return Self{ .outDir = out_dir };
        } else |_| {
            const tmp_dir = std.testing.tmpDir(.{});
            return Self{ .tmpDir = tmp_dir };
        }
    }

    pub fn dir(self: *const Self) std.fs.Dir {
        return switch (self.*) {
            .tmpDir => self.tmpDir.dir,
            .outDir => self.outDir,
        };
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .tmpDir => self.tmpDir.cleanup(),
            .outDir => self.outDir.close(),
        }
    }
};

/// Serializes the given slice to a temporary file with `save()` and verifies that the output
/// matches the contents of a file with a given name in the `data` directory.
fn expectEqualsReferenceSaved(fname: []const u8, slice: anytype) !void {
    var out = try OutDir.init();
    defer out.deinit();
    var fp = try out.dir().createFile(fname, .{ .read = true });
    defer fp.close();
    try @import("npy-out.zig").save(fp.writer().any(), slice);
    return expectEqualsReferenceFile(fname, fp);
}

/// Like expectEqualsReferenceSaved() but appends the elements of the slice one by one.
fn expectEqualsReferenceAppend(fname: []const u8, slice: anytype) !void {
    var out = try OutDir.init();
    defer out.deinit();
    var fp = try out.dir().createFile(fname, .{ .read = true });
    defer fp.close();
    var npy_out = try @import("npy-out.zig").NpyOut(@TypeOf(slice[0])).fromFile(fp);
    for (slice) |item| {
        try npy_out.append(item);
    }
    return expectEqualsReferenceFile(fname, fp);
}

/// Like expectEqualsReferenceAppend() but closes and re-open the file after each append.
fn expectEqualsReferenceAppendClose(fname: []const u8, slice: anytype) !void {
    const NpyOut = @import("npy-out.zig").NpyOut(@TypeOf(slice[0]));
    var out = try OutDir.init();
    defer out.deinit();

    {
        var fp = try out.dir().createFile(fname, .{ .read = true });
        defer fp.close();
        _ = try NpyOut.fromFile(fp);
    }

    for (slice) |item| {
        var fp = try out.dir().openFile(fname, .{ .mode = .read_write });
        defer fp.close();
        var npy_out = try NpyOut.fromFile(fp);
        try npy_out.append(item);
    }

    var fp = try out.dir().openFile(fname, .{});
    defer fp.close();
    return expectEqualsReferenceFile(fname, fp);
}

/// Like expectEqualsReferenceAppend() but appends the elements of the slice in pairs with
/// appendSlice().
fn expectEqualsReferencePairs(fname: []const u8, slice: anytype) !void {
    var out = try OutDir.init();
    defer out.deinit();
    var fp = try out.dir().createFile(fname, .{ .read = true });
    defer fp.close();
    var npy_out = try @import("npy-out.zig").NpyOut(@TypeOf(slice[0])).fromFile(fp);

    var i: usize = 0;
    while (i < slice.len) {
        if (i + 2 <= slice.len) {
            try npy_out.appendSlice(slice[i .. i + 2]);
            i += 2;
        } else {
            try npy_out.append(slice[i]);
            i += 1;
        }
    }

    return expectEqualsReferenceFile(fname, fp);
}

fn expectEqualsReferenceAll(fname: []const u8, slice: anytype) !void {
    try expectEqualsReferenceSaved(fname, slice);
    try expectEqualsReferenceAppend(fname, slice);
    try expectEqualsReferenceAppendClose(fname, slice);
    try expectEqualsReferencePairs(fname, slice);
}

test "empty.npy" {
    const data = [_]f32{};
    return expectEqualsReferenceSaved("empty.npy", &data);
}

test "array.npy" {
    const data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    return expectEqualsReferenceAll("array.npy", &data);
}

test "points.npy" {
    const Point = extern struct {
        x: f32,
        y: f32,
    };
    const data = [_]Point{ .{ .x = 10, .y = -100 }, .{ .x = 11, .y = -101 }, .{ .x = 12, .y = -102 } };
    return expectEqualsReferenceAll("points.npy", &data);
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
    return expectEqualsReferenceAll("padding.npy", &data);
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
    return expectEqualsReferenceAll("person.npy", &data);
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
    return expectEqualsReferenceAll("embedded_struct.npy", &data);
}

test "matrix.npy" {
    const data = [3][3]f32{
        [3]f32{ 1.0, 2.0, 3.0 },
        [3]f32{ 4.0, 5.0, 6.0 },
        [3]f32{ 7.0, 8.0, 9.0 },
    };
    return expectEqualsReferenceAll("matrix.npy", &data);
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
    return expectEqualsReferenceAll("embedded_array.npy", &data);
}

test "just_strings.npy" {
    const copy = std.mem.copyForwards;
    var data = std.mem.zeroes([5][7:0]u8);
    copy(u8, &data[0], "hello");
    copy(u8, &data[1], "world");
    // empty string at data[2]
    copy(u8, &data[3], "this is");
    copy(u8, &data[4], "a test");
    return expectEqualsReferenceAll("just_strings.npy", &data);
}

test "fixlen_strings.npy" {
    const copy = std.mem.copyForwards;
    var data = std.mem.zeroes([5][7]u8);
    copy(u8, &data[0], "hello");
    copy(u8, &data[1], "world");
    // empty string at data[2]
    copy(u8, &data[3], "this is");
    copy(u8, &data[4], "a test");
    const as_slice: []const [7]u8 = &data; // not needed but just to make sure it also works
    return expectEqualsReferenceAll("fixlen_strings.npy", as_slice);
    // TODO: This gets saved as a matrix of bytes. Is there any scenario where we'd prefer '|S7'
    // instead?
}

test "datetime64.npy" {
    const types = @import("types.zig");
    const TimeUnit = types.TimeUnit;
    const datetime64 = types.datetime64;
    const Timestamps = extern struct {
        ts_s: types.DateTime64(TimeUnit.s),
        ts_ms: types.DateTime64(TimeUnit.ms),
        ts_D: types.DateTime64(TimeUnit.D),
    };
    const data = [_]Timestamps{
        Timestamps{
            // 2024-07-17 18:46:56 UTC
            .ts_s = datetime64(1721242016, TimeUnit.s),
            .ts_ms = datetime64(1721242016000, TimeUnit.ms),
            .ts_D = datetime64(19921, TimeUnit.D),
        },
        Timestamps{
            // 0001-01-01 00:00:00 UTC
            .ts_s = datetime64(-62135596800, TimeUnit.s),
            .ts_ms = datetime64(-62135596800000, TimeUnit.ms),
            .ts_D = datetime64(-719162, TimeUnit.D),
        },
        Timestamps{
            // Not-a-Time
            .ts_s = types.DateTime64(TimeUnit.s).NaT,
            .ts_ms = types.DateTime64(TimeUnit.ms).NaT,
            .ts_D = types.DateTime64(TimeUnit.D).NaT,
        },
    };
    return expectEqualsReferenceAll("datetime64.npy", &data);
}

test "compressed.npz" {
    const npy_out = @import("npy-out.zig");
    const allocator = std.testing.allocator;
    var data: [1000]f32 = undefined;
    for (0..1000) |i| {
        data[i] = @as(f32, @floatFromInt(i)) / 100;
    }
    var out = try OutDir.init();
    defer out.deinit();

    var fp = try out.dir().createFile("compressed.npz", .{ .read = true });
    defer fp.close();
    {
        var npz_out = try npy_out.NpzOut.init(allocator, fp, true);
        defer npz_out.deinit();
        try npz_out.save("all_data", data[0..]);
        try npz_out.save("half_data", data[250..750]);
        try npz_out.save("empty", data[0..0]);
    }
    try fp.seekTo(0);
    try expectEqualsReferenceFile("compressed.npz", fp);

    // truncate the file
    try fp.seekTo(0);
    try fp.setEndPos(0);

    try npy_out.savez(fp, allocator, true, .{
        .all_data = data[0..],
        .half_data = data[250..750],
        .empty = data[0..0],
    });
    try fp.seekTo(0);
    try expectEqualsReferenceFile("compressed.npz", fp);
}

test "uncompressed.npz" {
    const npy_out = @import("npy-out.zig");
    const copy = std.mem.copyForwards;
    const allocator = std.testing.allocator;
    var out = try OutDir.init();
    defer out.deinit();

    const temp_data = [_]f32{ 25.2, 27.8, 30.1, 27.3 };
    var color_data = std.mem.zeroes([4][6:0]u8);
    copy(u8, &color_data[0], "red");
    copy(u8, &color_data[1], "green");
    copy(u8, &color_data[2], "blue");
    copy(u8, &color_data[3], "yellow");
    const byte_data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    var fp = try out.dir().createFile("uncompressed.npz", .{ .read = true });
    defer fp.close();

    try npy_out.savez(fp, allocator, false, .{ &temp_data, &color_data, &byte_data });
    try expectEqualsReferenceFile("uncompressed.npz", fp);
}

test "appending incompatible file" {
    const NpyOut = @import("npy-out.zig").NpyOut;
    var out = try OutDir.init();
    defer out.deinit();
    {
        // create an appendable file of f32 values
        var fp = try out.dir().createFile("bad_append.npy", .{});
        defer fp.close();
        var npy = try NpyOut(f32).fromFile(fp);
        try npy.appendSlice(&[_]f32{ 1.0, 2.0, 3.0 });
    }
    {
        // try to open as f64; should fail
        var fp = try out.dir().openFile("bad_append.npy", .{ .mode = .read_write });
        defer fp.close();
        const ret = NpyOut(f64).fromFile(fp);
        try std.testing.expectEqual(error.InvalidHeader, ret);
    }
    {
        // try to open as f32 but with a different shape; should fail
        var fp = try out.dir().openFile("bad_append.npy", .{ .mode = .read_write });
        defer fp.close();
        const ret = NpyOut([4]f32).fromFile(fp);
        try std.testing.expectEqual(error.InvalidHeader, ret);
    }
    {
        // try to append f32 values; should succeed
        var fp = try out.dir().openFile("bad_append.npy", .{ .mode = .read_write });
        defer fp.close();
        var npy = try NpyOut(f32).fromFile(fp);
        try npy.appendSlice(&[_]f32{ 4.0, 5.0, 6.0 });
    }
}

// vim: set tw=100 sw=4 expandtab:
