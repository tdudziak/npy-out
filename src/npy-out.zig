const std = @import("std");
const dtype = @import("dtype.zig");
const helper = @import("helper.zig");

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

pub fn NpyOut(comptime T: type) type {
    return struct {
        stream: std.io.StreamSource,
        start_offset: u64, // offset to the first byte of the MAGIC value
        appendable: bool,
        len: u64, // number of T-type elements written (first dimension of output shape)
        tail_offset: u64, // offset to the first byte after the last written data
        bin_start_offset: ?u64, // offset to the first byte of the binary data

        const Self = @This();

        pub fn fromFile(file: std.fs.File, appendable: bool) !Self {
            const off = try file.getPos();
            var result = Self{
                .stream = .{ .file = file },
                .start_offset = off,
                .appendable = appendable,
                .len = 0,
                .tail_offset = 0,
                .bin_start_offset = null,
            };

            try file.seekFromEnd(0);
            if (off != try file.getPos()) {
                // there is existing data in the file
                if (!appendable) {
                    return error.FileNotEmpty;
                }
                try result.parseExistingHeader(); // updates len and offsets
            } else {
                // new file; write full header
                try result.writeHeader(); // also updates bin_start_offset
                result.tail_offset = result.bin_start_offset.?;
            }

            return result;
        }

        pub fn fromStreamSource(ssource: std.io.StreamSource) !Self {
            var result = Self{
                .stream = ssource,
                .start_offset = 0,
                .appendable = false,
                .len = 0,
                .tail_offset = 0,
                .bin_start_offset = null,
            };
            try result.writeHeader(); // also updates bin_start_offset
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
            _ = try self.writeHeaderToWriter(change_detector.writer(), false);
            if (change_detector.anything_changed) {
                return error.InvalidHeader;
            }

            // derive the tail offset from length and record size
            self.bin_start_offset = try self.stream.getPos();
            self.tail_offset = @sizeOf(T) * self.len + self.bin_start_offset.?;
        }

        fn writeHeaderToWriter(self: *const Self, in_writer: std.io.AnyWriter, dummy_hlen: bool) !usize {
            const dtinfo = dtype.dtypeOf(T);
            var counter = std.io.countingWriter(in_writer);
            var writer = counter.writer().any();
            try writer.writeAll(MAGIC);
            try writer.writeAll(VERSION);

            // determine and write HEADER_LEN by calling recursively if needed
            if (dummy_hlen) {
                try writer.writeInt(u16, 0, .little);
            } else {
                const hlen = try self.writeHeaderToWriter(std.io.null_writer.any(), true) - 10;
                // TODO: check for overflow and produce header in newer format
                try writer.writeInt(u16, @intCast(hlen), .little);
            }

            // write the header ASCII string
            try writer.writeAll("{'descr': ");
            try writer.writeAll(dtinfo.dtype);
            try writer.writeAll(", 'fortran_order': False, 'shape': ");
            try dtype.prependShape(writer, self.len, dtinfo.shape);
            try writer.writeAll(", }");

            // pad with extra spaces to allow for header growth and make sure that the start of
            // binary data is aligned to 64 bytes
            try writer.writeByteNTimes(0x20, EXTRA_HEADER_SPACE);
            while ((counter.bytes_written + 1) % 64 != 0) {
                try writer.writeByte(0x20);
            }
            try writer.writeByte(0x0a); // newline marks the end of the header
            return counter.bytes_written;
        }

        fn writeHeader(self: *Self) !void {
            try self.stream.seekTo(self.start_offset);
            _ = try self.writeHeaderToWriter(self.stream.writer().any(), false);
            const bin_start_offset = try self.stream.getPos();
            if (self.bin_start_offset) |x| {
                if (x != bin_start_offset) {
                    // this leaves the file in corrupted state but should never happen as long as
                    // EXTRA_HEADER_SPACE_IN_APPENDABLE_MODE is big enough
                    @panic("NPY header overlaps with binary data");
                }
            } else {
                self.bin_start_offset = bin_start_offset;
            }
        }

        pub fn appendSlice(self: *Self, data: []const T) !void {
            if (!self.appendable and self.len != 0) {
                return error.NotAppendable;
            }

            // update the length and write the header
            self.len += data.len;
            try self.writeHeader();

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

pub const NpzOut = struct {
    zip_out: ZipOut,
    allocator: std.mem.Allocator,

    const ZipOut = @import("zip-out.zig").ZipOut;
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, compress: bool) !NpzOut {
        return .{
            .zip_out = try ZipOut.init(allocator, file, compress),
            .allocator = allocator,
        };
    }

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

pub fn allocateSave(allocator: std.mem.Allocator, slice: anytype) ![]const u8 {
    ensureSliceOrArrayPointer(@TypeOf(slice)); // only needed for nicer error messages
    const T = @TypeOf(slice.ptr[0]);

    // StreamSource currently doesn't support variable-length buffers but the amount of memory
    // we need is mostly predictable
    // FIXME: this still might fail for weird datatypes with long field names
    const buffer = try allocator.alloc(u8, 1000 + @sizeOf(T) * slice.len);
    var out = try NpyOut(T).fromStreamSource(.{ .buffer = std.io.fixedBufferStream(buffer) });
    try out.appendSlice(slice);

    if (allocator.resize(buffer, out.stream.buffer.pos)) {
        return buffer[0..out.stream.buffer.pos];
    } else {
        return allocator.dupe(u8, buffer[0..out.stream.buffer.pos]);
    }
}

pub fn save(file: std.fs.File, slice: anytype) !void {
    ensureSliceOrArrayPointer(@TypeOf(slice)); // only needed for nicer error messages
    const T = @TypeOf(slice.ptr[0]);
    var out = try NpyOut(T).fromFile(file, false);
    try out.appendSlice(slice);
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
