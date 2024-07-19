//! Zip file output module.
//!
//! This module provides a simple API to create zip files with enough support for the format to
//! generate .npz files similar to ones produced by NumPy. Compression with deflate is supported
//! optionally.
//!
//! The full specification of the format can be found in the Pkware's APPNOTE.TXT file:
//! https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
//!
//! The references to the sections in the comments are to the version 6.3.9 of the document.

const std = @import("std");
const AnyWriter = std.io.AnyWriter;

const SIG_LFH = "PK\x03\x04";
const SIG_CDFH = "PK\x01\x02";
const SIG_EOCDR = "PK\x05\x06";

// Upper byte (3) says that file attributes contain Unix permissions. Lower byte (decimal 63)
// identifies the specification version 6.3. See Section 4.4.2 of the specification.
const VERSION_MADE = (3 << 8) | 63;

// Minimal version of the specification needed to extract the files. Decimal 20 corresponds to
// version 2.0 which supports the "deflate" compression method but not much more (e.g. no ZIP64).
// See Section 4.4.3 of the specification.
const VERSION_EXTRACT = 20;

// See Section 4.4.5 for other possible values.
const CompressionMethod = enum(u16) {
    Store = 0,
    Deflate = 8,
};

const Entry = struct {
    crc32: u32,
    fileName: []const u8,
    compressionMethod: CompressionMethod,
    compressedSize: u32,
    uncompressedSize: u32,
    localFileHeaderOffset: u32,
    unixPermissions: u16,

    const Self = @This();

    fn writeCommonHeaderPart(self: *const Self, w: AnyWriter) !void {
        try w.writeInt(u16, 0, .little); // general purpose bit flag
        try w.writeInt(u16, @intFromEnum(self.compressionMethod), .little); // compression method
        try w.writeInt(u16, 0, .little); // last modify time
        try w.writeInt(u16, 0, .little); // last modify date
        try w.writeInt(u32, self.crc32, .little); // crc32
        try w.writeInt(u32, self.compressedSize, .little); // compressed size
        try w.writeInt(u32, self.uncompressedSize, .little); // uncompressed size
        try w.writeInt(u16, @intCast(self.fileName.len), .little); // file name length
        try w.writeInt(u16, 0, .little); // extra field length
    }

    pub fn writeLocalFileHeader(self: *const Self, w: AnyWriter) !void {
        try w.writeAll(SIG_LFH); // header signature
        try w.writeInt(u16, VERSION_EXTRACT, .little); // version
        try writeCommonHeaderPart(self, w);
        try w.writeAll(self.fileName); // file name
    }

    pub fn writeCentralDirectoryHeader(self: *const Self, w: AnyWriter) !void {
        try w.writeAll(SIG_CDFH); // header signature
        try w.writeInt(u16, VERSION_MADE, .little); // version made by
        try w.writeInt(u16, VERSION_EXTRACT, .little); // version needed to extract
        try writeCommonHeaderPart(self, w);
        try w.writeInt(u16, 0, .little); // file comment length
        try w.writeInt(u16, 0, .little); // disk number start
        try w.writeInt(u16, 0, .little); // internal file attributes
        try w.writeInt(u32, @as(u32, self.unixPermissions) << 16, .little); // external file attributes
        try w.writeInt(u32, self.localFileHeaderOffset, .little); // offset of local file header
        try w.writeAll(self.fileName); // file name
    }
};

pub const ZipOut = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator, // mostly for file names
    entries: std.ArrayList(Entry),
    writer: std.io.CountingWriter(AnyWriter),
    compress: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, writer: AnyWriter, compress: bool) !ZipOut {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.ArrayList(Entry).init(allocator),
            .writer = std.io.countingWriter(writer),
            .compress = compress,
        };
    }

    pub fn deinit(self: *Self) void {
        self.writeCentralDirectory() catch {
            // do nothing, we cannot fail in deinit()
            // TODO: should we log or perhaps provide a separate function to write the central
            // directory?
        };
        self.entries.deinit();
        self.arena.deinit();
    }

    pub fn write(self: *Self, fileName: []const u8, data: []const u8) !void {
        const fileNameCopy = try self.arena.allocator().dupe(u8, fileName);
        const lfh_offset: u32 = @intCast(self.writer.bytes_written);
        const entry_ptr = try self.entries.addOne();
        var crc = std.hash.crc.Crc32.init();
        crc.update(data);
        entry_ptr.* = .{
            .crc32 = crc.final(),
            .fileName = fileNameCopy,
            .compressionMethod = CompressionMethod.Store,
            .compressedSize = @intCast(data.len),
            .uncompressedSize = @intCast(data.len),
            .localFileHeaderOffset = lfh_offset,
            .unixPermissions = 0o644,
        };
        if (self.compress) {
            var buff = std.ArrayList(u8).init(self.allocator);
            defer buff.deinit();
            var data_stream = std.io.fixedBufferStream(data);
            try std.compress.flate.deflate.compress(.raw, data_stream.reader(), buff.writer(), .{});
            if (buff.items.len < data.len) {
                entry_ptr.compressionMethod = CompressionMethod.Deflate;
                entry_ptr.compressedSize = @intCast(buff.items.len);
                try entry_ptr.writeLocalFileHeader(self.writer.writer().any());
                try self.writer.writer().writeAll(buff.items);
                return; // compressed data written
            }
        }
        // compression disabled or compressed data bigger than original
        try entry_ptr.writeLocalFileHeader(self.writer.writer().any());
        try self.writer.writer().writeAll(data);
    }

    fn writeCentralDirectory(self: *Self) !void {
        const cdfh_offset: u32 = @intCast(self.writer.bytes_written);
        for (self.entries.items) |entry| {
            try entry.writeCentralDirectoryHeader(self.writer.writer().any());
        }
        const cdr_count: u16 = @intCast(self.entries.items.len);
        const cdr_size: u32 = @intCast(self.writer.bytes_written - cdfh_offset);

        // write the end of central directory record
        const w = self.writer.writer();
        try w.writeAll(SIG_EOCDR); // header signature
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // disk where central directory starts
        try w.writeInt(u16, cdr_count, .little); // number of central directory records on this disk
        try w.writeInt(u16, cdr_count, .little); // total number of central directory records
        try w.writeInt(u32, cdr_size, .little); // size of central directory
        try w.writeInt(u32, cdfh_offset, .little); // offset of central directory
        try w.writeInt(u16, 0, .little); // zip file comment length
    }
};

// vim: set tw=100 sw=4 expandtab:
