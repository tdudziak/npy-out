const std = @import("std");
const npy_out = @import("npy-out.zig");
const OutDir = @import("tests.zig").OutDir;

pub fn expectFileMd5(expected_md5: []const u8, fp: std.fs.File) !void {
    var md5 = std.crypto.hash.Md5.init(.{});
    try fp.seekTo(0);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try fp.read(buf[0..]);
        if (n == 0) {
            break;
        }
        md5.update(buf[0..n]);
    }
    var out_hash: [16]u8 = undefined;
    md5.final(&out_hash);
    if (expected_md5.len == 16) {
        try std.testing.expectEqual(expected_md5, &out_hash);
    } else {
        // convert from a string hex representation to a byte array
        const expected_hash_bin = try std.fmt.hexToBytes(buf[0..], expected_md5);
        try std.testing.expectEqualSlices(u8, expected_hash_bin, &out_hash);
    }
}

// a single dataset with uncompressed size that doesn't fit in a standard ZIP header
test "zip64_dataset.npz" {
    const allocator = std.testing.allocator;
    var out = try OutDir.init();
    defer out.deinit();

    const data = try allocator.alloc(u64, 0xffffffff / 8 + 1);
    defer allocator.free(data);
    for (0..data.len) |i| {
        data[i] = i;
    }

    var fp = try out.dir().createFile("zip64_dataset.npz", .{ .read = true });
    defer fp.close();

    const ret = npy_out.savez(fp, allocator, false, .{ .data = data });
    try std.testing.expectEqual(error.InputFileTooLarge, ret);

    // TODO: implement zip64 and update with the right hash below
    // try expectFileMd5("...", fp);
}

// a ZIP file with a few files smaller than 4 GiB that collectively cause some of the headers to be
// located at offsets that don't fit in a u32
test "zip64_offset.npz" {
    const allocator = std.testing.allocator;
    var out = try OutDir.init();
    defer out.deinit();

    const data = try allocator.alloc(u64, 0xffffffff / 8 / 4);
    defer allocator.free(data);
    for (0..data.len) |i| {
        data[i] = i;
    }

    var fp = try out.dir().createFile("zip64_offset.npz", .{ .read = true });
    defer fp.close();

    const ret = npy_out.savez(fp, allocator, false, .{
        .a = data,
        .b = data,
        .c = data,
        .d = data,
        .e = data,
    });
    try std.testing.expectEqual(error.OutputFileTooLarge, ret);

    // TODO: implement zip64 and update with the right hash below
    // try expectFileMd5("...", fp);
}

// a ZIP file with a large number of tiny files; the overall size is <4GiB
test "zip64_filecount.npz" {
    const allocator = std.testing.allocator;
    var out = try OutDir.init();
    defer out.deinit();
    const data = [_]u8{ 7, 8, 9 };
    var fp = try out.dir().createFile("zip64_filecount.npz", .{ .read = true });
    defer fp.close();

    var zout = try npy_out.NpzOut.init(allocator, fp, false);
    defer zout.deinit();
    zout.zip_out.require_flush = true; // significantly speeds up the test
    var name_buf = std.ArrayList(u8).init(allocator);
    defer name_buf.deinit();

    for (0..(0xffff + 1)) |i| {
        name_buf.clearRetainingCapacity();
        try std.fmt.format(name_buf.writer(), "file_{}", .{ i });
        try zout.save(name_buf.items, &data);
    }

    const ret = zout.zip_out.flush();
    try std.testing.expectEqual(error.TooManyFilesInZip, ret);

    // TODO: implement zip64 and update with the right hash below
    // try expectFileMd5("...", fp);
}

// a ZIP file with a single file with a huge filename that doesn't fit in a standard ZIP header
test "zip64_filename.npz" {
    const allocator = std.testing.allocator;
    var out = try OutDir.init();
    var fp = try out.dir().createFile("zip64_filename.npz", .{ .read = true });
    defer fp.close();

    var fname: [0xffff + 1]u8 = undefined;
    @memset(&fname, 'a');

    var npz_out = try npy_out.NpzOut.init(allocator, fp, false);
    defer npz_out.deinit();
    const ret = npz_out.save(&fname, &[_]f32{ 1, 2, 3 });

    try std.testing.expectEqual(error.FileNameTooLong, ret);

    // TODO: implement zip64 and update with the right hash below
    // try expectFileMd5("...", fp);
}
