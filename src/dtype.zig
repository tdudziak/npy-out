const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const comptimePrint = std.fmt.comptimePrint;

pub const DTypeInfo = struct {
    /// NumPy dtype string. Must be a valid Python expression that can appear in the header of an
    /// NPY file or be passed as argument to `numpy.dtype()`, e.g. "'<f4'".
    dtype: []const u8,

    /// NumPy shape string, e.g. "(3, 4)" or "()" for scalars.
    shape: []const u8,

    inline fn scalar(dtype: []const u8) DTypeInfo {
        return .{ .dtype = dtype, .shape = "()" };
    }

    inline fn isScalar(self: DTypeInfo) bool {
        return std.mem.eql(u8, self.shape, "()");
    }
};

/// Comptime variant of prependShape(). Only used internally in this module to construct dtypes of
/// multidimensional array types.
inline fn comptimePrependShape(comptime n: usize, comptime shape: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, shape, "()")) {
        return comptimePrint("({d},)", .{n});
    }
    if (eql(u8, shape[shape.len - 2 ..], ",)")) {
        // single element tuple, e.g. "(1, )"
        if (shape[0] != '(') {
            @compileError(comptimePrint("Invalid shape string: '{}'", .{shape}));
        }
        return comptimePrint("({d}, {s})", .{ n, shape[1 .. shape.len - 2] });
    }
    if (shape[0] != '(' or shape[shape.len - 1] != ')') {
        @compileError(comptimePrint("Invalid shape string: '{}'", .{shape}));
    }
    return comptimePrint("({d}, {s})", .{ n, shape[1 .. shape.len - 1] });
}

/// Takes a Python tuple `shape` as a string and reformats it to include an additional dimension of
/// given size at position 0. Writes the output to a given writer. Can be used to construct the
/// shape of tuples of arrays, where the first dimension is only known at runtime.
///
/// Example:
///     3, "()" -> "(3,)"
///     3, "(4,)" -> "(3, 4)"
///     3, "(4, 5)" -> "(3, 4, 5)"
pub fn prependShape(writer: std.io.AnyWriter, n: usize, shape: []const u8) !void {
    const eql = std.mem.eql;
    if (eql(u8, shape, "()")) {
        return writer.print("({d},)", .{n});
    }
    if (eql(u8, shape[shape.len - 2 ..], ",)")) {
        // single element tuple, e.g. "(1, )"
        if (shape[0] != '(') {
            return error.InvalidShape;
        }
        return writer.print("({d}, {s})", .{ n, shape[1 .. shape.len - 2] });
    }
    if (shape[0] != '(' or shape[shape.len - 1] != ')') {
        return error.InvalidShape;
    }
    return writer.print("({d}, {s})", .{ n, shape[1 .. shape.len - 1] });
}

inline fn voidField(nbytes: usize) []const u8 {
    return comptimePrint("('', '|V{d}')", .{nbytes});
}

inline fn namedField(field: std.builtin.Type.StructField) []const u8 {
    const dinfo = dtypeOf(field.type);
    if (dinfo.isScalar()) {
        return comptimePrint("('{s}', {s})", .{ field.name, dinfo.dtype });
    } else {
        return comptimePrint("('{s}', {s}, {s})", .{ field.name, dinfo.dtype, dinfo.shape });
    }
}

inline fn handleArray(T: type) DTypeInfo {
    const tinfo = @typeInfo(T).Array;
    if (tinfo.child == u8 and tinfo.sentinel != null) {
        const sentinel: *const u8 = @ptrCast(tinfo.sentinel.?);
        if (sentinel.* != 0) {
            @compileError("Only null-terminated byte strings are supported");
        }
        return DTypeInfo.scalar(comptimePrint("'|S{}'", .{tinfo.len + 1}));
    }
    comptime {
        if (handlePrimitive(tinfo.child)) |dtype| {
            return DTypeInfo{
                .dtype = dtype,
                .shape = comptimePrint("({},)", .{tinfo.len}),
            };
        }
        if (@typeInfo(tinfo.child) == .Array) {
            // call recursively to handle multi-dimensional arrays
            const sub_dinfo = handleArray(tinfo.child);
            return DTypeInfo{
                .dtype = sub_dinfo.dtype,
                .shape = comptimePrependShape(tinfo.len, sub_dinfo.shape),
            };
        }
        @compileError("NumPy export not supported for arrays of non-primitive types");
    }
}

inline fn handleStruct(T: type) DTypeInfo {
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
        break :b DTypeInfo.scalar(result);
    };
}

inline fn handlePrimitive(comptime T: type) ?[]const u8 {
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
    return null;
}

pub inline fn dtypeOf(comptime T: type) DTypeInfo {
    if (handlePrimitive(T)) |dtype| {
        return DTypeInfo.scalar(dtype);
    }
    switch (@typeInfo(T)) {
        .Struct => return handleStruct(T),
        .Array => return handleArray(T),
        else => @compileError(comptimePrint("NumPy export not supported for type: {}", .{T})),
    }
}

test "simple floats and float structs" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings("'<f4'", dtypeOf(f32).dtype);
    try expectEqualStrings("'<f8'", dtypeOf(f64).dtype);
    try expectEqualStrings("[('x', '<f4'), ('y', '<f4')]", dtypeOf(extern struct {
        x: f32,
        y: f32,
    }).dtype);
}

test "struct with internal padding" {
    const t = std.testing;
    const Foo = extern struct {
        a: u8,
        b: i64,
    };
    try t.expectEqual(16, @sizeOf(Foo));
    try t.expectEqual(8, @alignOf(Foo));
    try t.expectEqualStrings("[('a', '|u1'), ('', '|V7'), ('b', '<i8')]", dtypeOf(Foo).dtype);
}

test "struct with alignment requirements" {
    const t = std.testing;
    const Point = extern struct {
        x: f32,
        y: f32,
        shape: u8,
    };
    try t.expectEqual(12, @sizeOf(Point));
    try t.expectEqualStrings("[('x', '<f4'), ('y', '<f4'), ('shape', '|u1'), ('', '|V3')]", dtypeOf(Point).dtype);
}

test "byte strings" {
    const t = std.testing;
    const Person = extern struct {
        name: [6:0]u8, // 7 bytes together with the sentinel
        age: u8,
    };
    try t.expectEqual(8, @sizeOf(Person));
    try t.expectEqualStrings("[('name', '|S7'), ('age', '|u1')]", dtypeOf(Person).dtype);
}

test "arrays" {
    const t = std.testing;
    try t.expectEqualStrings("(5,)", dtypeOf([5]u8).shape);
    try t.expectEqualStrings("(3, 5)", dtypeOf([3][5]i32).shape);
    try t.expectEqualStrings("(3, 5, 7)", dtypeOf([3][5][7]f64).shape);
    try t.expectEqualStrings("'<f4'", dtypeOf([5]f32).dtype);
    try t.expectEqualStrings("'<f8'", dtypeOf([3][5]f64).dtype);
    try t.expectEqualStrings("'|u1'", dtypeOf([3][5][7]u8).dtype);
}

test "comptimePrependShape()" {
    const t = std.testing;
    comptime {
        const scalar = DTypeInfo.scalar("<f4").shape;
        try t.expectEqualStrings("()", scalar);
        const arr1d = comptimePrependShape(5, scalar);
        try t.expectEqualStrings("(5,)", arr1d);
        const arr2d = comptimePrependShape(3, arr1d);
        try t.expectEqualStrings("(3, 5)", arr2d);
        const arr3d = comptimePrependShape(7, arr2d);
        try t.expectEqualStrings("(7, 3, 5)", arr3d);
        const arr4d = comptimePrependShape(11, arr3d);
        try t.expectEqualStrings("(11, 7, 3, 5)", arr4d);
    }
}

test "prependShape()" {
    const t = std.testing;
    const scalar = DTypeInfo.scalar("<f4").shape;

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer().any();

    try prependShape(writer, 5, scalar);
    try t.expectEqualStrings("(5,)", buf.items);

    buf.clearRetainingCapacity();
    try prependShape(writer, 3, "(5,)");
    try t.expectEqualStrings("(3, 5)", buf.items);

    buf.clearRetainingCapacity();
    try prependShape(writer, 7, "(3, 5)");
    try t.expectEqualStrings("(7, 3, 5)", buf.items);

    buf.clearRetainingCapacity();
    try prependShape(writer, 11, "(7, 3, 5)");
    try t.expectEqualStrings("(11, 7, 3, 5)", buf.items);
}

// vim: set tw=100 sw=4 expandtab:
