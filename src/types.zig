const std = @import("std");

pub const TimeUnit = enum { s, ms, m, h, D, W, M, Y };

pub fn DateTime64(comptime unit: TimeUnit) type {
    return packed struct(i64) {
        value: i64,

        pub const Unit = unit;

        /// Special value handled as NaT (Not a Time) by NumPy
        pub const NaT = DateTime64(unit){ .value = std.math.minInt(i64) };

        pub const DType: []const u8 = ret: {
            const e_code = @import("dtype.zig").EndianessCharacter;
            const u_code = @tagName(unit);
            break :ret std.fmt.comptimePrint("'{c}M8[{s}]'", .{ e_code, u_code });
        };
    };
}

pub fn datetime64(value: i64, comptime unit: TimeUnit) DateTime64(unit) {
    return DateTime64(unit){ .value = value };
}

test "DateTime64 dtypes" {
    const t = std.testing;
    try t.expectEqualStrings("'<M8[ms]'", DateTime64(.ms).DType);
    try t.expectEqualStrings("'<M8[s]'", DateTime64(.s).DType);
    try t.expectEqualStrings("'<M8[Y]'", DateTime64(.Y).DType);
}

// vim: set tw=100 sw=4 expandtab:
