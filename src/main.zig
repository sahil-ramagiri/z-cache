const std = @import("std");
const Io = std.Io;
pub const resp = @import("resp.zig");
pub const store = @import("store.zig");

test {
    std.testing.refAllDecls(@This());
}


pub fn executeCommand(
    kv: *store.Store,
    command: resp.Command,
    writer: *Io.Writer,
) (store.StoreError || Io.Writer.Error)!void {
    switch (command) {
        .ping => try writer.writeAll("+PONG\r\n"),
        .set => |set| {
            try kv.set(set.key, set.value);
            try writer.writeAll("+OK\r\n");
        },
        .get => |key| {
            if (kv.get(key)) |value| {
                try writer.print("${d}\r\n{s}\r\n", .{ value.len, value });
            } else {
                try writer.writeAll("$-1\r\n");
            }
        },
        .exists => |key| {
            const reply = if (kv.exists(key)) ":1\r\n" else ":0\r\n";
            try writer.writeAll(reply);
        },
        .del => |key| {
            const reply = if (kv.del(key)) ":1\r\n" else ":0\r\n";
            try writer.writeAll(reply);
        },
        .strlen => |key| {
            const len = kv.strlen(key);
            try writer.print(":{d}\r\n", .{len});
        },
        .append => |append| {
            const len = try kv.append(append.key, append.value);
            try writer.print(":{d}\r\n", .{len});
        },
        .setnx => |setnx| {
            const reply = if (try kv.setnx(setnx.key, setnx.value)) ":1\r\n" else ":0\r\n";
            try writer.writeAll(reply);
        },
        .getdel => |key| {
            if (kv.getdel(key)) |value| {
                try writer.print("${d}\r\n{s}\r\n", .{ value.len, value });
            } else {
                try writer.writeAll("$-1\r\n");
            }
        },
    }
}

pub fn processStream(
    kv: *store.Store,
    reader: *Io.Reader,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    while (true) {
        const maybe_cmd = resp.parseCommand(reader) catch |err| {
            try writer.print("-ERR {t}\r\n", .{err});
            switch (err) {
                error.UnknownCommand, error.InvalidArity => continue,
                else => break,
            }
        };
        const cmd = maybe_cmd orelse break;
        executeCommand(kv, cmd, writer) catch |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            else => try writer.print("-ERR {t}\r\n", .{err}),
        };
    }
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = @splat(0);
    var std_writer = Io.File.stdout().writer(init.io, &out_buf);
    const writer = &std_writer.interface;

    const gpa = init.gpa;

    var kv = try store.Store.init(gpa, 1024);
    defer kv.deinit(gpa);

    const file = try Io.Dir.cwd().openFile(init.io, "tests/commands/1-input.resp", .{});
    defer file.close(init.io);

    var read_buf: [resp.buffer_size_min]u8 = @splat(0);
    var file_reader = file.reader(init.io, &read_buf);
    const reader = &file_reader.interface;

    try processStream(&kv, reader, writer);
    try writer.flush();
}

test "1-input.resp matches 1-expected.resp" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var kv = try store.Store.init(gpa, 1024);
    defer kv.deinit(gpa);

    const in_file = try Io.Dir.cwd().openFile(io, "tests/commands/1-input.resp", .{});
    defer in_file.close(io);

    var read_buf: [resp.buffer_size_min]u8 = @splat(0);
    var file_reader = in_file.reader(io, &read_buf);

    var out_alloc: Io.Writer.Allocating = .init(gpa);
    defer out_alloc.deinit();

    try processStream(&kv, &file_reader.interface, &out_alloc.writer);

    const expected = try Io.Dir.cwd().readFileAlloc(
        io,
        "tests/commands/1-expected.resp",
        gpa,
        .limited(64 * 1024),
    );
    defer gpa.free(expected);

    try std.testing.expectEqualStrings(expected, out_alloc.written());
}