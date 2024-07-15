const std = @import("std");

/// Can be used like `std.io.ChangeDetectionStream` but without the need of a separate buffer.
///
/// Using the writer returned by `writer()` will not actually write anywhere but instead compares
/// the input with the result of a corresponding read from a reader stored in this structure. The
/// field `anything_changed` will be set to `true` if any difference is detected, including writing
/// past the end of the reader.
pub const ChangeDetectionWriter = struct {
    reader: std.io.AnyReader,
    anything_changed: bool = false,

    pub fn writer(self: *@This()) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = writeFn,
        };
    }

    fn writeFn(opaque_self: *const anyopaque, bytes: []const u8) !usize {
        const self: *ChangeDetectionWriter = @ptrCast(@constCast(@alignCast(opaque_self)));
        for (0..bytes.len) |i| {
            const c = self.reader.readByte() catch |err| {
                if (err == error.EndOfStream) {
                    self.anything_changed = true;
                    continue;
                } else {
                    return err;
                }
            };
            if (c != bytes[i]) {
                self.anything_changed = true;
            }
        }
        return bytes.len;
    }
};

pub fn changeDetectionWriter(reader: std.io.AnyReader) ChangeDetectionWriter {
    return ChangeDetectionWriter{ .reader = reader };
}

test "ChangeDetectionWriter" {
    const t = opaque {
        fn testInputs(a: []const u8, b: []const u8, expected: bool) !void {
            var buf_stream = std.io.fixedBufferStream(a);
            var cdw = changeDetectionWriter(buf_stream.reader().any());

            try cdw.writer().writeAll(b);
            try std.testing.expectEqual(expected, cdw.anything_changed);

            cdw.anything_changed = false;
            try buf_stream.seekTo(0);
            for (b) |c| {
                try cdw.writer().writeByte(c);
            }
            try std.testing.expectEqual(expected, cdw.anything_changed);
        }

        fn expectNotChanged(input: []const u8) !void {
            return testInputs(input, input, false);
        }

        fn expectChanged(a: []const u8, b: []const u8) !void {
            return testInputs(a, b, true);
        }
    };

    try t.expectNotChanged("");
    try t.expectNotChanged("a");
    try t.expectNotChanged("abcdefg");
    try t.expectChanged("a", "b");
    try t.expectChanged("abcdefg", "abcdEfg");
    try t.testInputs("abcdefg", "abcdef", false); // character left but no change in written data
    try t.expectChanged("abcdef", "abcdefg");
    try t.testInputs("abcdef", "abcdefg", true);
}

// vim: set tw=100 sw=4 expandtab:
