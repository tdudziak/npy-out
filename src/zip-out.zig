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
const File = std.fs.File;
const Writer = File.Writer;

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

pub const Error = Writer.Error || File.GetSeekPosError || error{
    InputFileTooLarge,
    OutputFileTooLarge,
    TooManyFilesInZip,
    FileNameTooLong,
};

// ZipOut.write() is the only function that truncates or allocates, so it can fail in some other
// ways.
pub const WriteError = Error || File.SetEndPosError || std.mem.Allocator.Error || error{CompressionFailed};

inline fn offsetCast(offset: u64) Error!u32 {
    if (offset > std.math.maxInt(u32)) {
        return error.OutputFileTooLarge;
    }
    return @intCast(offset);
}

inline fn countCast(count: usize) Error!u16 {
    if (count > std.math.maxInt(u16)) {
        return error.TooManyFilesInZip;
    }
    return @intCast(count);
}

inline fn inputSizeCast(size: usize) Error!u32 {
    if (size > std.math.maxInt(u32)) {
        return error.InputFileTooLarge;
    }
    return @intCast(size);
}

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

    fn writeCommonHeaderPart(self: *const Self, w: Writer) Error!void {
        if (self.fileName.len > std.math.maxInt(u16)) {
            return error.FileNameTooLong;
        }
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

    fn writeLocalFileHeader(self: *const Self, w: Writer) Error!void {
        try w.writeAll(SIG_LFH); // header signature
        try w.writeInt(u16, VERSION_EXTRACT, .little); // version
        try writeCommonHeaderPart(self, w);
        try w.writeAll(self.fileName); // file name
    }

    fn writeCentralDirectoryHeader(self: *const Self, w: Writer) Error!void {
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

/// Creates and writes .zip files.
///
/// Compression via "deflate" is supported optionally, if requested during `init()`. Calling
/// `deinit()` will deallocate all memory used by the instance but does not affect the output file,
/// which is left in a valid state after every call to `write()`.
pub const ZipOut = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator, // mostly for file names
    entries: std.ArrayList(Entry),
    file: File,
    compress: bool,
    require_flush: bool, // don't write the central directory in every write() call
    offset_start: u64, // file offset to the start of zip data
    offset_cd: u64, // file offset to the start of central directory

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file: File, compress: bool) Error!ZipOut {
        const off = try file.getPos();
        var result = Self{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.ArrayList(Entry).init(allocator),
            .file = file,
            .compress = compress,
            .require_flush = false,
            .offset_start = off,
            .offset_cd = off,
        };
        try result.flush();
        return result;
    }

    pub fn deinit(self: *Self) void {
        // the Central Directory is already written; either in init() for an empty file or after the
        // last write() call
        self.entries.deinit();
        self.arena.deinit();
    }

    pub fn write(self: *Self, fileName: []const u8, data: []const u8) WriteError!void {
        // remove the old central directory
        try self.file.setEndPos(self.offset_cd);
        try self.file.seekTo(self.offset_cd);

        const lfh_offset: u32 = try offsetCast(self.offset_cd);
        const uncompressedSize: u32 = try inputSizeCast(data.len);

        const writer = self.file.writer();
        const fileNameCopy = try self.arena.allocator().dupe(u8, fileName);
        const entry_ptr = try self.entries.addOne();
        var crc = std.hash.crc.Crc32.init();
        crc.update(data);
        entry_ptr.* = .{
            .crc32 = crc.final(),
            .fileName = fileNameCopy,
            .compressionMethod = CompressionMethod.Store,
            .compressedSize = uncompressedSize,
            .uncompressedSize = uncompressedSize,
            .localFileHeaderOffset = lfh_offset,
            .unixPermissions = 0o644,
        };
        var written = false;
        if (self.compress) {
            var buff = std.ArrayList(u8).init(self.allocator);
            defer buff.deinit();
            var data_stream = std.io.fixedBufferStream(data);
            std.compress.flate.deflate.compress(.raw, data_stream.reader(), buff.writer(), .{}) catch {
                return error.CompressionFailed;
            };
            const compressedSize = try inputSizeCast(buff.items.len);
            if (compressedSize < uncompressedSize) {
                entry_ptr.compressionMethod = CompressionMethod.Deflate;
                entry_ptr.compressedSize = compressedSize;
                try entry_ptr.writeLocalFileHeader(writer);
                try writer.writeAll(buff.items);
                written = true;
            }
        }
        if (!written) {
            // compression disabled or compressed data bigger than original
            try entry_ptr.writeLocalFileHeader(writer);
            try writer.writeAll(data);
        }

        // update the central directory offset and write it
        self.offset_cd = try self.file.getPos();
        if (!self.require_flush) {
            try self.flush();
        }
    }

    // Writes the central directory at the file offset `offset_cd`.
    pub fn flush(self: *Self) !void {
        try self.file.seekTo(self.offset_cd);
        const w = self.file.writer();

        for (self.entries.items) |entry| {
            try entry.writeCentralDirectoryHeader(w);
        }

        const cdr_count: u16 = try countCast(self.entries.items.len);
        const cdr_size: u32 = try offsetCast(try self.file.getPos() - self.offset_cd);
        const offset_cd: u32 = try offsetCast(self.offset_cd);

        // write the end of central directory record
        try w.writeAll(SIG_EOCDR); // header signature
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // disk where central directory starts
        try w.writeInt(u16, cdr_count, .little); // number of central directory records on this disk
        try w.writeInt(u16, cdr_count, .little); // total number of central directory records
        try w.writeInt(u32, cdr_size, .little); // size of central directory
        try w.writeInt(u32, offset_cd, .little); // offset of central directory
        try w.writeInt(u16, 0, .little); // zip file comment length
    }
};

// vim: set tw=100 sw=4 expandtab:
