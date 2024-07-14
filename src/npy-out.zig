const std = @import("std");
const dtype = @import("dtype.zig");

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

/// Amount of additional padding in the header in "appendable" mode to allow for increasing the
/// header size. The only variable element is the length (fist dimension of the shape tuple). 20
/// decimal digits are enough to represent a 64-bit integer.
const EXTRA_HEADER_SPACE_IN_APPENDABLE_MODE = 20;

pub fn NpyOut(comptime T: type) type {
    return struct {
        file: std.fs.File,
        start_offset: u64, // offset to the first byte of the MAGIC value
        appendable: bool,
        len: u64, // number of T-type elements written (first dimension of output shape)
        tail_offset: u64, // offset to the first byte after the last written data
        bin_start_offset: ?u64, // offset to the first byte of the binary data

        const Self = @This();

        pub fn init(file: std.fs.File, appendable: bool) !Self {
            const off = try file.getPos();
            var result = Self{
                .file = file,
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

        fn parseExistingHeader(self: *Self) !void {
            var file = self.file;
            try file.seekTo(self.start_offset);

            // verify that the magic value and version are correct
            var magic = std.mem.zeroes([MAGIC.len]u8);
            _ = try file.readAll(&magic);
            if (!std.mem.eql(u8, MAGIC, &magic)) {
                return error.InvalidHeader;
            }
            var version = std.mem.zeroes([VERSION.len]u8);
            _ = try file.readAll(&version);
            if (!std.mem.eql(u8, VERSION, &version)) {
                return error.InvalidHeader;
            }

            // read the len and re-write the header
            self.len = try parseAsciiHeaderLen(file.reader().any());
            try self.writeHeader();
            // TODO: make sure that the new header is exactly equal with the old one, perhaps using
            // a ChangeDetectionStream for writing

            // derive the tail offset from length and record size
            self.tail_offset = @sizeOf(T) * self.len + self.bin_start_offset.?;
        }

        fn writeHeader(self: *Self) !void {
            const dtinfo = dtype.dtypeOf(T);
            var file = self.file;
            try file.seekTo(self.start_offset);

            try file.writeAll(MAGIC);
            try file.writeAll(VERSION);

            // HEADER_LEN will be filled in later
            const header_len_off = try file.getPos();
            try file.writeAll(&[2]u8{ 0, 0 });

            // write the header ASCII string
            try file.writeAll("{'descr': ");
            try file.writeAll(dtinfo.dtype);
            try file.writeAll(", 'fortran_order': False, 'shape': ");
            try dtype.prependShape(file.writer().any(), self.len, dtinfo.shape);
            try file.writeAll(", }");

            // pad with extra spaces to allow for header growth and make sure that the start of
            // binary data is aligned to 64 bytes
            if (self.appendable) {
                try file.writer().writeByteNTimes(0x20, EXTRA_HEADER_SPACE_IN_APPENDABLE_MODE);
            }
            while ((try file.getPos() - self.start_offset + 1) % 64 != 0) {
                try file.writer().writeByte(0x20);
            }
            try file.writer().writeByte(0x0a); // newline marks the end of the header

            const bin_start_offset = try file.getPos();
            if (self.bin_start_offset) |x| {
                if (x != bin_start_offset) {
                    // this leaves the file in corrupted state but should never happen as long as
                    // EXTRA_HEADER_SPACE_IN_APPENDABLE_MODE is big enough
                    @panic("NPY header overlaps with binary data");
                }
            } else {
                self.bin_start_offset = bin_start_offset;
            }

            // update HEADER_LEN before the ASCII header
            const header_len: u16 = @intCast(bin_start_offset - header_len_off - 2);
            try file.seekTo(header_len_off);
            try file.writer().writeInt(u16, header_len, .little);
            try file.seekTo(bin_start_offset);
        }

        pub fn appendSlice(self: *Self, data: []const T) !void {
            if (!self.appendable and self.len != 0) {
                return error.NotAppendable;
            }

            // update the length and write the header
            self.len += data.len;
            try self.writeHeader();

            // write the binary data
            try self.file.seekTo(self.tail_offset);
            const ptr: [*]const u8 = @ptrCast(data.ptr);
            const bytes_out = @sizeOf(T) * data.len;
            try self.file.writeAll(ptr[0..bytes_out]);

            self.tail_offset = try self.file.getPos();
        }

        pub fn append(self: *Self, sample: T) !void {
            return self.appendSlice(&[1]T{sample});
        }
    };
}

pub fn save(file: std.fs.File, slice: anytype) !void {
    ensureSliceOrArrayPointer(@TypeOf(slice)); // only needed for nicer error messages
    const T = @TypeOf(slice.ptr[0]);
    var out = try NpyOut(T).init(file, false);
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
