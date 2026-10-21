const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var buf: [100]u8 = @splat(0);
    var stdWriter = Io.File.stdout().writer(init.io, &buf);
    const writer = &stdWriter.interface;

    try writer.writeAll("Hello World!");
    try writer.flush();
}