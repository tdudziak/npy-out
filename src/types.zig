//! Provides custom data types that can be used in structures and arrays saved into .npy and .npz
//! files.

const std = @import("std");
const time = std.time;

/// Time unit for `DateTime64` type.
pub const TimeUnit = enum { s, ms, m, h, D, W, M, Y };

/// A timestamp representation that will be encoded as `numpy.datetime64`.
///
/// Internally it's a 64-bit signed integer Unix timestamp with a customizable time unit. The time
/// unit is stored in the NumPy dtype string and is used by NumPy to convert to other time
/// representations. Time zone information is not stored.
pub fn DateTime64(comptime unit: TimeUnit) type {
    return packed struct(i64) {
        value: i64,

        /// Time unit associated with this type.
        pub const Unit: TimeUnit = unit;

        /// Special value handled as `NaT` (Not a Time) by NumPy
        pub const NaT: @This() = DateTime64(unit){ .value = std.math.minInt(i64) };

        /// NumPy dtype string representation of this type.
        pub const DType: []const u8 = ret: {
            const e_code = @import("dtype.zig").EndianessCharacter;
            const u_code = @tagName(unit);
            break :ret std.fmt.comptimePrint("'{c}M8[{s}]'", .{ e_code, u_code });
        };
    };
}

/// Creates a `DateTime64` value from a given Unix timestamp and time unit.
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
