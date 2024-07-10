const std = @import("std");
const dtypeOf = @import("dtype.zig").dtypeOf;

const MAGIC = "\x93NUMPY";
const VERSION = "\x01\x00";

pub fn save(file: std.fs.File, slice: anytype) !void {
    // TODO: nicer error messages when wrong argument passed as 'slice'?
    const T = @TypeOf(slice.ptr[0]);

    const start_off = try file.getPos(); // TODO: will this ever be nonzero?
    try file.writeAll(MAGIC);
    try file.writeAll(VERSION);

    // HEADER_LEN will be filled in later
    const header_len_off = try file.getPos();
    try file.writeAll(&[2]u8{ 0, 0 });

    // write the header ASCII string
    try file.writeAll("{'descr': ");
    try file.writeAll(dtypeOf(T));
    try file.writeAll(", 'fortran_order': False, 'shape': (");
    try file.writer().print("{},), }}", .{slice.len});

    // pad with spaces so that start of binary data is aligned to 64 bytes
    while ((try file.getPos() - start_off) % 64 != 0) {
        try file.writer().writeByte(0x20);
    }
    _ = try file.seekBy(-1);
    try file.writer().writeByte(0x0a); // newline marks the end of the header
    const bin_start_off = try file.getPos();

    // update HEADER_LEN before the ASCII header
    const header_len: u16 = @intCast(bin_start_off - header_len_off - 2);
    try file.seekTo(header_len_off);
    try file.writer().writeInt(u16, header_len, .little);

    // write the binary data
    try file.seekTo(bin_start_off);
    const ptr: [*]const u8 = @ptrCast(slice.ptr);
    const bytes_out = @sizeOf(T) * slice.len;
    try file.writeAll(ptr[0..bytes_out]);
}

test "points.npy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Point = extern struct {
        x: f32,
        y: f32,
    };
    const data = [_]Point{ .{ .x = 10, .y = -100 }, .{ .x = 11, .y = -101 }, .{ .x = 12, .y = -102 } };
    var fp = try tmp.dir.createFile("points.npy", .{ .read = true });
    defer fp.close();
    try save(fp, &data);

    return @import("tests.zig").expectReference("points.npy", fp);
}

test "padding.npy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

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
    var fp = try tmp.dir.createFile("padding.npy", .{ .read = true });
    defer fp.close();
    try save(fp, &data);

    return @import("tests.zig").expectReference("padding.npy", fp);
}

// vim: set tw=100 sw=4 expandtab:
