const std = @import("std");
const print = std.debug.print;
const time = std.time;

const npy_out = @import("npy-out");
const npyt = npy_out.types;

const Sample = extern struct {
    timestamp: npyt.DateTime64(npyt.TimeUnit.s),
    temperature: f32,
    humidity: f32,
};

pub fn main() !void {
    var rng = std.rand.DefaultPrng.init(0);
    var fp = try std.fs.cwd().createFile("sensor.npy", .{
        .read = true,
        .truncate = false,
    });
    defer fp.close();
    var out = try npy_out.NpyOut(Sample).fromFile(fp);

    print("Appending to sensor.npy in a loop until interrupted...\n", .{});
    while (true) {
        const sample = Sample{
            .timestamp = npyt.datetime64(time.timestamp(), npyt.TimeUnit.s),
            .temperature = rng.random().floatNorm(f32) + 25.0,
            .humidity = rng.random().floatNorm(f32) * 10 + 50.0,
        };
        try out.append(sample);
        print("{d:02.2} deg.C\t{d:02.2} %RH\n", .{sample.temperature, sample.humidity});
        time.sleep(time.ns_per_s);
    }
}
