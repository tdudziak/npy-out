const std = @import("std");
const dtype = @import("dtype.zig");
const helper = @import("helper.zig");

pub const types = @import("types.zig");
pub const ZipOut = @import("zip-out.zig").ZipOut;

const AnyWriter = std.io.AnyWriter;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const MAGIC = "\x93NUMPY";
const VERSION = "\x01\x00";

inline fn ensureSliceOrArrayPointer(comptime T: type) void {
    const tinfo = @typeInfo(T);
    if (tinfo == .Pointer) {
        if (tinfo.Pointer.size == .Slice) {
            return; // slice
        }
        if (tinfo.Pointer.size == .One) {
            const child = @typeInfo(tinfo.Pointer.child);
            if (child == .Array) {
                return; // pointer to an array
            }
        }
    }
    @compileError(std.fmt.comptimePrint("Expected a slice or array argument, got '{}'", .{T}));
}

/// Try to parse the length (first dimension of the shape) from the ASCII header of a .npy file. The
/// current position of the file is expected to be at the '{' character and the function, if
/// successful, will leave the file at the first character after the closing '}'.
fn parseAsciiHeaderLen(reader: std.io.AnyReader) !u64 {
    // TODO: Do we need this to be more sophisticated than a simple scan for "shape': ("? As long
    // as we only parse the output of our own writeHeader() function, it should be enough.
    const pattern: []const u8 = "shape': (";
    var result: u64 = 0;
    var state: union(enum) {
        pre_pattern: void,
        in_pattern_idx: usize,
        in_number: void,
        post_number: void,
    } = .pre_pattern;
    while (true) {
        const c = try reader.readByte();
        switch (state) {
            .pre_pattern => {
                if (c == pattern[0]) {
                    state = .{ .in_pattern_idx = 1 };
                }
            },
            .in_pattern_idx => |i| {
                if (c == pattern[i]) {
                    if (i == pattern.len - 1) {
                        state = .{ .in_number = void{} };
                    } else {
                        state = .{ .in_pattern_idx = i + 1 };
                    }
                } else {
                    state = .{ .pre_pattern = void{} };
                }
            },
            .in_number => {
                if (std.ascii.isDigit(c)) {
                    result = result * 10 + @as(u64, (c - '0'));
                } else {
                    state = .{ .post_number = void{} };
                }
            },
            .post_number => {
                if (c == '}') {
                    return result;
                }
            },
        }
    }
}

/// Amount of additional padding in the header to allow for increasing the length (first dimension
/// of the shape tuple) without moving the whole binary data block. This amount is more than enough
/// to fit a 64-bit integer in decimal ASCII representation.
///
/// Incidentally, numpy.save() also adds a similar amount of extra padding to the header, probably
/// for similar reasons. This is not required by the specs (which only mentions 64-byte alignment)
/// but means we can conveniently compare byte-by-byte with numpy-generated files in tests.zig.
const EXTRA_HEADER_SPACE = 22;

/// Offset at which the 16-bit header length field is located in the header.
const HLEN_OFFSET = 8;

/// Writes the NPY header to a given writer.
///
/// Returns the header size in bytes, as it appears in the `hlen` field, i.e. without the magic
/// values and the header length field itself.
///
/// If `dummy_hlen` is set to true, the header length field will in the output will be set to 0 and
/// needs to be updated afterwards. When set to false, the header will be generated twice to
/// calculate its length first which is less efficient but doesn't require further seeking in the
/// output file or buffer.
fn writeHeader(comptime T: type, _writer: AnyWriter, len: u64, dummy_hlen: bool) !u16 {
    const dtinfo = dtype.dtypeOf(T);
    var counter = std.io.countingWriter(_writer);
    var w = counter.writer().any();
    try w.writeAll(MAGIC);
    try w.writeAll(VERSION);

    // determine and write HEADER_LEN by calling recursively if needed
    if (dummy_hlen) {
        try w.writeInt(u16, 0, .little);
    } else {
        const hlen = try writeHeader(T, std.io.null_writer.any(), len, true);
        try w.writeInt(u16, hlen, .little);
    }

    // write the header ASCII string
    try w.writeAll("{'descr': ");
    try w.writeAll(dtinfo.dtype);
    try w.writeAll(", 'fortran_order': False, 'shape': ");
    try dtype.prependShape(w, len, dtinfo.shape);
    try w.writeAll(", }");

    // pad with extra spaces to allow for header growth and make sure that the start of
    // binary data is aligned to 64 bytes
    try w.writeByteNTimes(0x20, EXTRA_HEADER_SPACE);
    while ((counter.bytes_written + 1) % 64 != 0) {
        try w.writeByte(0x20);
    }
    try w.writeByte(0x0a); // newline marks the end of the header

    const hlen = counter.bytes_written - 10;
    if (hlen > std.math.maxInt(u16)) {
        // This means that the ASCII representation of the NumPy data type is too long for the
        // length of the header to fit in u16. This can happen in some unusual cases and is
        // supported in a newer version of the NPY format but this is not implemented here.
        return error.UnsupportedDataType;
    }
    return @intCast(hlen);
}

fn writeData(comptime T: type, writer: AnyWriter, data: []const T) !void {
    const ptr: [*]const u8 = @ptrCast(data.ptr);
    const bytes_out = @sizeOf(T) * data.len;
    try writer.writeAll(ptr[0..bytes_out]);
}

/// Allows to write output .npy files in a streaming fashion.
///
/// Individual records (see `append()`) or whole slices (see `appendSlice()`) can be appended to the
/// output file. In order to accomplish that, the header will change after every append. If the
/// whole data is available at once, consider using the save() function instead.
pub fn NpyOut(comptime T: type) type {
    return struct {
        stream: std.io.StreamSource,
        start_offset: u64, // offset to the first byte of the MAGIC value
        len: u64, // number of T-type elements written (first dimension of output shape)
        tail_offset: u64, // offset to the first byte after the last written data
        bin_start_offset: ?u64, // offset to the first byte of the binary data

        const Self = @This();

        pub fn fromFile(file: File) !Self {
            const off = try file.getPos();
            var result = Self{
                .stream = .{ .file = file },
                .start_offset = off,
                .len = 0,
                .tail_offset = 0,
                .bin_start_offset = null,
            };

            try file.seekFromEnd(0);
            if (off != try file.getPos()) {
                // there is existing data in the file
                try result.parseExistingHeader(); // updates len and offsets
            } else {
                // new file; write full header
                try result.updateHeader(); // also updates bin_start_offset
                result.tail_offset = result.bin_start_offset.?;
            }

            return result;
        }

        pub fn fromStreamSource(ssource: std.io.StreamSource) !Self {
            var result = Self{
                .stream = ssource,
                .start_offset = 0,
                .len = 0,
                .tail_offset = 0,
                .bin_start_offset = null,
            };
            try result.updateHeader(); // also updates bin_start_offset
            result.tail_offset = result.bin_start_offset.?;
            return result;
        }

        fn parseExistingHeader(self: *Self) !void {
            var reader = self.stream.reader();
            try self.stream.seekTo(self.start_offset);

            // verify that the magic value and version are correct
            var magic = std.mem.zeroes([MAGIC.len]u8);
            _ = try reader.readAll(&magic);
            if (!std.mem.eql(u8, MAGIC, &magic)) {
                return error.InvalidHeader;
            }
            var version = std.mem.zeroes([VERSION.len]u8);
            _ = try reader.readAll(&version);
            if (!std.mem.eql(u8, VERSION, &version)) {
                return error.InvalidHeader;
            }

            // read the len confirm that the header that we would have written is equal to the
            // header in the file
            self.len = try parseAsciiHeaderLen(reader.any());
            try self.stream.seekTo(self.start_offset);
            var change_detector = helper.changeDetectionWriter(reader.any());
            _ = try writeHeader(T, change_detector.writer(), self.len, false);
            if (change_detector.anything_changed) {
                return error.InvalidHeader;
            }

            // derive the tail offset from length and record size
            self.bin_start_offset = try self.stream.getPos();
            self.tail_offset = @sizeOf(T) * self.len + self.bin_start_offset.?;
        }

        fn updateHeader(self: *Self) !void {
            try self.stream.seekTo(self.start_offset);
            const hlen: u16 = try writeHeader(T, self.stream.writer().any(), self.len, true);
            const bin_start_offset = try self.stream.getPos();

            // update the header length field; typically will only be different when the header is
            // written for the first time
            try self.stream.seekTo(self.start_offset + HLEN_OFFSET);
            try self.stream.writer().writeInt(u16, hlen, .little);

            if (self.bin_start_offset) |x| {
                if (x != bin_start_offset) {
                    // this leaves the file in corrupted state but should never happen as long as
                    // EXTRA_HEADER_SPACE is big enough
                    @panic("NPY header overlaps with binary data");
                }
            } else {
                self.bin_start_offset = bin_start_offset;
            }
        }

        pub fn appendSlice(self: *Self, data: []const T) !void {
            // update the length and write the header
            self.len += data.len;
            try self.updateHeader();

            // write the binary data
            try self.stream.seekTo(self.tail_offset);
            const ptr: [*]const u8 = @ptrCast(data.ptr);
            const bytes_out = @sizeOf(T) * data.len;
            try self.stream.writer().writeAll(ptr[0..bytes_out]);

            self.tail_offset = try self.stream.getPos();
        }

        pub fn append(self: *Self, sample: T) !void {
            return self.appendSlice(&[1]T{sample});
        }
    };
}

/// Creates and writes .npz files.
///
/// These files are ZIP archives that can be created with `numpy.savez()` and
/// `numpy.savez_compressed()` in Python and contain multiple .npy files.
pub const NpzOut = struct {
    zip_out: ZipOut,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, file: File, compress: bool) !NpzOut {
        return .{
            .zip_out = try ZipOut.init(allocator, file, compress),
            .allocator = allocator,
        };
    }

    /// Adds another value to the archive.
    ///
    /// The extension ".npy" will be appended to the given name following the Python API. The
    /// argument `slice` works the same way as in the `save()` function.
    pub fn save(self: *Self, name: []const u8, slice: anytype) !void {
        const data = try allocateSave(self.allocator, slice);
        defer self.allocator.free(data);
        const fileName = try std.fmt.allocPrint(self.allocator, "{s}.npy", .{name});
        defer self.allocator.free(fileName);
        try self.zip_out.write(fileName, data);
    }

    pub fn deinit(self: *Self) void {
        self.zip_out.deinit();
    }
};

/// Forms a full .npy file in newly allocated memory.
///
/// The result is owned by the caller and needs to be freed using the allocator passed to the
/// function. The `slice` argument works the same way as in the `save()` function.
pub fn allocateSave(allocator: Allocator, slice: anytype) ![]const u8 {
    ensureSliceOrArrayPointer(@TypeOf(slice)); // only needed for nicer error messages
    const T = @TypeOf(slice.ptr[0]);
    var buf = std.ArrayList(u8).init(allocator);

    // we could simply call save(buf.writer...) but we can save a little bit of time by writing the
    // header with dummy length field value first and fixing it afterwards
    const hlen: u16 = try writeHeader(T, buf.writer().any(), slice.len, true);
    @memcpy(buf.items[HLEN_OFFSET .. HLEN_OFFSET + 2], &std.mem.toBytes(hlen));
    try writeData(T, buf.writer().any(), slice);

    return buf.toOwnedSlice();
}

/// Writes a slice to a given writer in .npy format.
///
/// Corresponds to `numpy.save()` in Python. The argument `slice` can be a slice or a pointer to an
/// array of supported basic types or structures. Structures are supported as long as they're marked
/// as "extern" or "packed" and there is a corresponding NumPy type with the exact same layout.
pub fn save(writer: AnyWriter, slice: anytype) !void {
    ensureSliceOrArrayPointer(@TypeOf(slice)); // only needed for nicer error messages
    const T = @TypeOf(slice.ptr[0]);
    _ = try writeHeader(T, writer, slice.len, false);
    try writeData(T, writer, slice);
}

/// Writes a bunch of values as an .npz archive.
///
/// Works like `numpy.savez()` and `numpy.savez_compressed() in Python. The argument can be an
/// anonymous struct or a tuple. Following the Python API, the keys in the tuple case will be named
/// "arr_0", "arr_1", etc. The values should be slices of pointer arrays similar to the `save()`
/// argument.
pub fn savez(file: File, allocator: Allocator, compressed: bool, args: anytype) !void {
    var npz_out = try NpzOut.init(allocator, file, compressed);
    defer npz_out.deinit();
    inline for (comptime std.meta.fieldNames(@TypeOf(args))) |field_name| {
        const key = comptime key: {
            var is_number = true;
            for (field_name) |c| {
                if (!std.ascii.isDigit(c)) {
                    is_number = false;
                    break;
                }
            }
            if (is_number) {
                break :key std.fmt.comptimePrint("arr_{s}", .{field_name});
            } else {
                break :key field_name;
            }
        };
        const value = @field(args, field_name);
        try npz_out.save(key, value);
    }
}

test "parseAsciiHeaderLen()" {
    const expectEqual = std.testing.expectEqual;
    var buff: std.io.FixedBufferStream([]const u8) = undefined;

    buff = .{ .buffer = "{'descr': '<f4', 'fortran_order': False, 'shape': (0,), }", .pos = 0 };
    try expectEqual(0, parseAsciiHeaderLen(buff.reader().any()));

    buff = .{ .buffer = "{'descr': '<f4', 'fortran_order': False, 'shape': (0, 1), }", .pos = 0 };
    try expectEqual(0, parseAsciiHeaderLen(buff.reader().any()));

    buff = .{ .buffer = "{'descr': '<f4', 'fortran_order': False, 'shape': (0, 1, 2), }", .pos = 0 };
    try expectEqual(0, parseAsciiHeaderLen(buff.reader().any()));

    buff = .{ .buffer = "{'descr': '<f4', 'fortran_order': False, 'shape': (123456,), }", .pos = 0 };
    try expectEqual(123456, parseAsciiHeaderLen(buff.reader().any()));

    buff = .{ .buffer = "{'descr': '<f4', 'fortran_order': False, 'shape': (123, 456, 789), }", .pos = 0 };
    try expectEqual(123, parseAsciiHeaderLen(buff.reader().any()));

    // make sure a field called 'shape' in 'descr' doesn't confuse the parser
    buff = .{
        .buffer = "{'descr': [('color', '<u4'), ('shape', '|i1')], 'fortran_order': False, 'shape': (5,), }",
        .pos = 0,
    };
    try expectEqual(5, parseAsciiHeaderLen(buff.reader().any()));

    // TODO: make sure invalid headers are handled reasonably
}

// vim: set tw=100 sw=4 expandtab:
