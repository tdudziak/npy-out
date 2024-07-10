const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const comptimePrint = std.fmt.comptimePrint;

inline fn voidField(nbytes: usize) []const u8 {
    return comptimePrint("('', '|V{d}')", .{nbytes});
}

inline fn namedField(field: std.builtin.Type.StructField) []const u8 {
    return comptimePrint("('{s}', {s})", .{ field.name, dtypeOf(field.type) });
}

inline fn dtypeArray(T: type) []const u8 {
    const tinfo = @typeInfo(T).Array;
    if (tinfo.child == u8 and tinfo.sentinel != null) {
        // TODO: verify that the sentinel is 0
        return comptimePrint("'|S{}'", .{tinfo.len + 1});
    }
    // TODO: support ordinary arrays
    @compileError(comptimePrint("NumPy export not supported for type: {}", .{T}));
}

inline fn dtypeOfStruct(T: type) []const u8 {
    const tinfo = @typeInfo(T).Struct;
    if (tinfo.layout != .@"packed" and tinfo.layout != .@"extern") {
        @compileError("NumPy export only supported for extern or packed structs");
    }
    return comptime b: {
        var offset: usize = 0;
        var result: []const u8 = "[";
        for (tinfo.fields, 0..) |field, i| {
            if (i != 0) {
                result = result ++ ", ";
            }
            const field_offset = @offsetOf(T, field.name);
            if (field_offset != offset) {
                if (field_offset < offset) {
                    @compileError("Negative padding detected (?)");
                }
                // padding is supported by NumPy via unnamed void-type fields
                result = result ++ voidField(field_offset - offset) ++ ", ";
                offset = field_offset;
            }
            result = result ++ namedField(field);
            offset += @sizeOf(field.type);
        }
        if (offset != @sizeOf(T)) {
            // extra padding at the end, might even happen with packed structs!
            result = result ++ ", " ++ voidField(@sizeOf(T) - offset);
        }
        result = result ++ "]";
        break :b result;
    };
}

/// Returns the NumPy type for a given comptime-known Zig type. The result is a valid Python
/// expression that can be stored in the header of an NPY file or passed as argument to
/// `numpy.dtype()`.
pub fn dtypeOf(comptime T: type) []const u8 {
    switch (T) {
        u8 => return "'|u1'",
        i8 => return "'|i1'",
        else => {},
    }
    if (native_endian == .little) {
        switch (T) {
            u16 => return "'<u2'",
            u32 => return "'<u4'",
            u64 => return "'<u8'",
            i16 => return "'<i2'",
            i32 => return "'<i4'",
            i64 => return "'<i8'",
            f32 => return "'<f4'",
            f64 => return "'<f8'",
            else => {},
        }
    } else if (native_endian == .big) {
        switch (T) {
            u16 => return "'>u2'",
            u32 => return "'>u4'",
            u64 => return "'>u8'",
            i16 => return "'>i2'",
            i32 => return "'>i4'",
            i64 => return "'>i8'",
            f32 => return "'>f4'",
            f64 => return "'>f8'",
            else => {},
        }
    } else {
        @compileError("Unknown endianness");
    }
    switch (@typeInfo(T)) {
        .Struct => return dtypeOfStruct(T),
        .Array => return dtypeArray(T),
        else => @compileError(comptimePrint("NumPy export not supported for type: {}", .{T})),
    }
}

test "simple floats and float structs" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings("'<f4'", dtypeOf(f32));
    try expectEqualStrings("'<f8'", dtypeOf(f64));
    try expectEqualStrings("[('x', '<f4'), ('y', '<f4')]", dtypeOf(extern struct {
        x: f32,
        y: f32,
    }));
}

test "struct with internal padding" {
    const t = std.testing;
    const Foo = extern struct {
        a: u8,
        b: i64,
    };
    try t.expectEqual(16, @sizeOf(Foo));
    try t.expectEqual(8, @alignOf(Foo));
    try t.expectEqualStrings("[('a', '|u1'), ('', '|V7'), ('b', '<i8')]", dtypeOf(Foo));
}

test "struct with alignment requirements" {
    const t = std.testing;
    const Point = extern struct {
        x: f32,
        y: f32,
        shape: u8,
    };
    try t.expectEqual(12, @sizeOf(Point));
    try t.expectEqualStrings("[('x', '<f4'), ('y', '<f4'), ('shape', '|u1'), ('', '|V3')]", dtypeOf(Point));
}

test "byte strings" {
    const t = std.testing;
    const Person = extern struct {
        name: [6:0]u8, // 7 bytes together with the sentinel
        age: u8,
    };
    try t.expectEqual(8, @sizeOf(Person));
    try t.expectEqualStrings("[('name', '|S7'), ('age', '|u1')]", dtypeOf(Person));
}

// vim: set tw=100 sw=4 expandtab:
