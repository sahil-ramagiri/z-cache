const std = @import("std");
const Io = std.Io;
pub const resp = @import("resp.zig");

test {
    std.testing.refAllDecls(@This());
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = @splat(0);
    var stdWriter = Io.File.stdout().writer(init.io, &buf);
    const writer = &stdWriter.interface;

    const gpa = init.gpa;
    
    var kv = std.StringHashMap([]const u8).init(gpa);
    defer kv.deinit();

    try kv.put("Hello", "World!");

    try writer.print("{s} : {s}\n", .{ "Hello", (kv.get("Hello") orelse "empty") });

    try writer.flush();
}