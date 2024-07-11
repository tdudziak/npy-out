const std = @import("std");
const dtype = @import("dtype.zig");

const MAGIC = "\x93NUMPY";
const VERSION = "\x01\x00";

pub fn save(file: std.fs.File, slice: anytype) !void {
    // TODO: prependShape() could use a writer to avoid the extra allocation
    const allocator = std.heap.c_allocator;

    // TODO: nicer error messages when wrong argument passed as 'slice'?
    const T = @TypeOf(slice.ptr[0]);
    const dtinfo = dtype.dtypeOf(T);
    const shape = try dtype.prependShape(allocator, slice.len, dtinfo.shape);
    defer allocator.free(shape);

    const start_off = try file.getPos(); // TODO: will this ever be nonzero?
    try file.writeAll(MAGIC);
    try file.writeAll(VERSION);

    // HEADER_LEN will be filled in later
    const header_len_off = try file.getPos();
    try file.writeAll(&[2]u8{ 0, 0 });

    // write the header ASCII string
    try file.writeAll("{'descr': ");
    try file.writeAll(dtinfo.dtype);
    try file.writeAll(", 'fortran_order': False, 'shape': ");
    try file.writeAll(shape);
    try file.writeAll(", }");

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

// vim: set tw=100 sw=4 expandtab:
