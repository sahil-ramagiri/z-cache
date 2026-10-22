const std = @import("std");
const Io = std.Io;
pub const resp = @import("resp.zig");
pub const store = @import("store.zig");

test {
    std.testing.refAllDecls(@This());
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = @splat(0);
    var stdWriter = Io.File.stdout().writer(init.io, &buf);
    const writer = &stdWriter.interface;

    const gpa = init.gpa;
    
    var kv = try store.Store.init(gpa, 10);
    defer kv.deinit(gpa);

    try kv.set("Hello", "World!");

    try writer.print("{s} : {s}\n", .{ "Hello", (kv.get("Hello") orelse "empty") });

    _ = kv.del("Hello");
    try writer.print("{s} : {any}\n", .{ "Hello", kv.exists("Hello") });

    try writer.flush();
}