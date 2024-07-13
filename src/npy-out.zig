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
            try result.writeHeader(); // also updates bin_start_offset
            result.tail_offset = result.bin_start_offset.?;
            return result;
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

// vim: set tw=100 sw=4 expandtab:
