//! Provides custom data types that can be used in structures and arrays saved into .npy and .npz
//! files.

const std = @import("std");
const time = std.time;

/// Time unit for `DateTime64` and `TimeDelta64` types.
pub const TimeUnit = enum {
    s, // seconds
    ms, // milliseconds
    us, // microseconds
    ns, // nanoseconds
    m, // minutes,
    h, // hours,
    D, // days,
    W, // weeks,
    M, // months,
    Y, // years,

    pub inline fn toNanoseconds(comptime self: TimeUnit) comptime_int {
        return switch (self) {
            .ns => 1,
            .us => time.ns_per_us,
            .ms => time.ns_per_ms,
            .s => time.ns_per_s,
            .m => time.ns_per_min,
            .h => time.ns_per_hour,
            .D => time.ns_per_day,
            .W => time.ns_per_week,
            .M => @compileError("Months cannot be converted to nanoseconds"),
            .Y => @compileError("Years cannot be converted to nanoseconds"),
        };
    }
};

fn TimeType(comptime unit: TimeUnit, comptime dtype_char: u8) type {
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
            break :ret std.fmt.comptimePrint("'{c}{c}8[{s}]'", .{ e_code, dtype_char, u_code });
        };

        /// Adds a TimeDelta64 value with a compatible unit to this value.
        ///
        /// Result is undefined if it cannot be represented as a signed 64-bit integer with a given
        /// unit.
        pub fn add(self: @This(), delta: TimeDelta64(unit)) @This() {
            return @This(){ .value = self.value + delta.value };
        }

        /// Converts this time value to a different unit.
        ///
        /// Result is undefined if it cannot be represented as a signed 64-bit integer with the
        /// target unit.
        pub fn toUnit(self: @This(), comptime new_unit: TimeUnit) TimeType(new_unit, dtype_char) {
            // FIXME: conversion between months and years is not supported
            const old_unit_ns = unit.toNanoseconds();
            const new_unit_ns = new_unit.toNanoseconds();
            if (new_unit_ns >= old_unit_ns) {
                const value = @divTrunc(self.value, @divExact(new_unit_ns, old_unit_ns));
                return TimeType(new_unit, dtype_char){ .value = value };
            } else {
                const value = self.value * @divExact(old_unit_ns, new_unit_ns);
                return TimeType(new_unit, dtype_char){ .value = value };
            }
        }
    };
}

/// A timestamp representation that will be encoded as `numpy.datetime64`.
///
/// Internally it's a 64-bit signed integer Unix timestamp with a customizable time unit. The time
/// unit is stored in the NumPy dtype string and is used by NumPy to convert to other time
/// representations. Time zone information is not stored.
pub fn DateTime64(comptime unit: TimeUnit) type {
    return TimeType(unit, 'M');
}

/// A time difference representation that will be encoded as `numpy.timedelta64`.
pub fn TimeDelta64(comptime unit: TimeUnit) type {
    return TimeType(unit, 'm');
}

/// Creates a `DateTime64` from a given Unix timestamp and time unit.
pub fn datetime64(value: i64, comptime unit: TimeUnit) DateTime64(unit) {
    return DateTime64(unit){ .value = value };
}

/// Creates a `TimeDelta64` from a time value and unit.
pub fn timedelta64(value: i64, comptime unit: TimeUnit) TimeDelta64(unit) {
    return TimeDelta64(unit){ .value = value };
}

test "DateTime64 and TimeDelta64 dtypes" {
    const t = std.testing;
    try t.expectEqualStrings("'<M8[ms]'", DateTime64(.ms).DType);
    try t.expectEqualStrings("'<M8[s]'", DateTime64(.s).DType);
    try t.expectEqualStrings("'<M8[Y]'", DateTime64(.Y).DType);
    try t.expectEqualStrings("'<m8[ms]'", TimeDelta64(.ms).DType);
    try t.expectEqualStrings("'<m8[s]'", TimeDelta64(.s).DType);
    try t.expectEqualStrings("'<m8[Y]'", TimeDelta64(.Y).DType);
}

test "time unit conversions" {
    const t = std.testing;

    const x = timedelta64(24, .h);
    try t.expectEqual(24, x.toUnit(.h).value);
    try t.expectEqual(24 * 60, x.toUnit(.m).value);
    try t.expectEqual(24 * 60 * 60, x.toUnit(.s).value);
    try t.expectEqual(24 * 60 * 60 * 1000, x.toUnit(.ms).value);
    try t.expectEqual(1, x.toUnit(.D).value);

    const y = timedelta64(123123, .us);
    try t.expectEqual(123123, y.toUnit(.us).value);
    try t.expectEqual(123123000, y.toUnit(.ns).value);
    try t.expectEqual(123, y.toUnit(.ms).value);
    try t.expectEqual(0, y.toUnit(.s).value);

    const big = datetime64(9223372036854775000, .ms);
    try t.expectEqual(9223372036854775000, big.toUnit(.ms).value);
    try t.expectEqual(9223372036854775, big.toUnit(.s).value);

    const smol = datetime64(-9223372036854775000, .ms);
    try t.expectEqual(-9223372036854775000, smol.toUnit(.ms).value);
    try t.expectEqual(-9223372036854775, smol.toUnit(.s).value);

    const midyum = datetime64(9223372036854775, .s);
    try t.expectEqual(9223372036854775000, midyum.toUnit(.ms).value);
}

test "time unit addition" {
    const t = std.testing;

    const ten_s = timedelta64(10, .s);
    const hour = timedelta64(1, .h).toUnit(.s);
    try t.expectEqual(3610, ten_s.add(hour).value);

    const big_day = datetime64(9223372036854775800, .s);
    try t.expectEqual(std.math.maxInt(i64), big_day.add(timedelta64(7, .s)).value);
}

// vim: set tw=100 sw=4 expandtab:
