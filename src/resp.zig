const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

pub const key_size_max: u32 = 1024;
pub const value_size_max: u32 = 1024;
pub const args_count_max: u8 = 16;
/// Worst-case wire size of `*3\r\n$3\r\nSET\r\n$1024\r\n<key>\r\n$1024\r\n<val>\r\n`
pub const command_size_max: u32 = 64 + key_size_max + value_size_max;
/// Minimum reader buffer size (16 KiB, `>= 2 * command_size_max`).
pub const buffer_size_min: u32 = 16 * 1024;

comptime {
    assert(key_size_max == 1024);
    assert(value_size_max == 1024);
    assert(buffer_size_min >= 2 * command_size_max);
}

pub const ParseError = error{
    InvalidFrameType,
    InvalidArity,
    InvalidLength,
    InvalidCRLF,
    UnknownCommand,
    KeyTooLarge,
    ValueTooLarge,
    UnexpectedEndOfStream,
    ReadFailed,
};

pub const Keys = struct {
    items: [args_count_max - 1][]const u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Keys) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const KeyValues = struct {
    items: [(args_count_max - 1) / 2]KeyValue = undefined,
    len: u8 = 0,

    pub fn slice(self: *const KeyValues) []const KeyValue {
        return self.items[0..self.len];
    }
};

pub const Command = union(enum) {
    ping: void,
    set: KeyValue,
    get: []const u8,
    exists: Keys,
    del: Keys,
    strlen: []const u8,
    append: KeyValue,
    setnx: KeyValue,
    getdel: []const u8,
    getset: KeyValue,
    mget: Keys,
    mset: KeyValues,
};

const command_name_max: u8 = 8;

fn cmdWord(word: []const u8) u64 {
    assert(word.len <= command_name_max);
    var bytes: [8]u8 = @splat(0);
    @memcpy(bytes[0..word.len], word);

    inline for (0..8) |i| {
        if (bytes[i] >= 'a' and bytes[i] <= 'z') {
            bytes[i] -= 0x20;
        }
    }

    return std.mem.readInt(u64, &bytes, .little);
}

comptime {
    assert(cmdWord("A") == 0x41);
    assert(cmdWord("a") == 0x41);
    assert(cmdWord("aB") == 0x4241);
}

pub fn readDecimalCRLF(reader: *Io.Reader) ParseError!u32 {
    var value: u32 = 0;
    var digits: u8 = 0;
    const digits_max: u8 = 9; // up to 999,999,999 (fits in u32 without overflow)

    while (digits <= digits_max) : (digits += 1) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEndOfStream,
            error.ReadFailed => return error.ReadFailed,
        };

        if (byte == '\r') {
            if (digits == 0) return error.InvalidLength;
            const lf = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return error.UnexpectedEndOfStream,
                error.ReadFailed => return error.ReadFailed,
            };

            if (lf != '\n') return error.InvalidCRLF;
            return value;
        }

        if (byte < '0' or byte > '9') return error.InvalidLength;
        if (digits == digits_max) return error.InvalidLength;
        value = value * 10 + (byte - '0');
    }

    return error.InvalidLength;
}

pub fn readBulkString(
    reader: *Io.Reader,
    limit_max: u32,
    comptime too_large_err: ParseError,
) ParseError![]const u8 {
    assert(limit_max <= key_size_max or limit_max <= value_size_max);

    const prefix = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    if (prefix != '$') return error.InvalidFrameType;

    const len = try readDecimalCRLF(reader);
    if (len > limit_max) return too_large_err;

    const payload = reader.take(len) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };

    const crlf = reader.take(2) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    if (crlf[0] != '\r' or crlf[1] != '\n') return error.InvalidCRLF;

    assert(payload.len == len);
    assert(payload.len <= limit_max);
    return payload;
}

fn skipBulkString(reader: *Io.Reader, count: u32) ParseError!void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        _ = try readBulkString(reader, value_size_max, error.ValueTooLarge);
    }
}

pub fn parseCommand(reader: *Io.Reader) ParseError!?Command {
    if (reader.buffer.len >= command_size_max and
        reader.buffer.len - reader.seek < command_size_max)
    {
        reader.rebase(command_size_max) catch return error.ReadFailed;
    }

    const prefix = reader.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return error.ReadFailed,
    };

    if (prefix != '*') return error.InvalidFrameType;

    const arity = try readDecimalCRLF(reader);
    if (arity < 1 or arity > args_count_max) return error.InvalidArity;

    const cmd_name = try readBulkString(reader, key_size_max, error.KeyTooLarge);
    const remaining = arity - 1;

    if (cmd_name.len > command_name_max) {
        try skipBulkString(reader, remaining);
        return error.UnknownCommand;
    }
    const word = cmdWord(cmd_name);

    const u_info = @typeInfo(Command).@"union";
    inline for (u_info.field_names, u_info.field_types) |name, Payload| {
        comptime assert(name.len <= command_name_max);

        if (word == comptime cmdWord(name)) {
            if (Payload == void) {
                if (arity != 1) {
                    try skipBulkString(reader, remaining);
                    return error.InvalidArity;
                }
                return @unionInit(Command, name, {});
            } else if (Payload == []const u8) {
                if (arity != 2) {
                    try skipBulkString(reader, remaining);
                    return error.InvalidArity;
                }
                const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
                return @unionInit(Command, name, key);
            } else if (Payload == Keys) {
                if (arity < 2) {
                    try skipBulkString(reader, remaining);
                    return error.InvalidArity;
                }
                var keys: Keys = .{ .len = @intCast(remaining) };
                var i: u32 = 0;
                while (i < remaining) : (i += 1) {
                    keys.items[i] = try readBulkString(reader, key_size_max, error.KeyTooLarge);
                }
                return @unionInit(Command, name, keys);
            } else if (Payload == KeyValues) {
                if (arity < 3 or remaining % 2 != 0) {
                    try skipBulkString(reader, remaining);
                    return error.InvalidArity;
                }
                const pair_count: u8 = @intCast(remaining / 2);
                var kvs: KeyValues = .{ .len = pair_count };
                var i: u8 = 0;
                while (i < pair_count) : (i += 1) {
                    const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
                    const value = try readBulkString(reader, value_size_max, error.ValueTooLarge);
                    kvs.items[i] = .{ .key = key, .value = value };
                }
                return @unionInit(Command, name, kvs);
            } else if (Payload == KeyValue) {
                if (arity != 3) {
                    try skipBulkString(reader, remaining);
                    return error.InvalidArity;
                }
                const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
                const value = try readBulkString(reader, value_size_max, error.ValueTooLarge);
                return @unionInit(Command, name, .{ .key = key, .value = value });
            } else {
                @compileError("Unsupported Command payload type");
            }
        }
    }

    try skipBulkString(reader, remaining);
    return error.UnknownCommand;
}

test readDecimalCRLF {
    var reader: Io.Reader = undefined;

    reader = Io.Reader.fixed("55\r\n");
    try std.testing.expectEqual(@as(u32, 55), try readDecimalCRLF(&reader));

    reader = Io.Reader.fixed("abc\r\n");
    try std.testing.expectError(ParseError.InvalidLength, readDecimalCRLF(&reader));
}

test readBulkString {
    var reader: Io.Reader = undefined;

    reader = Io.Reader.fixed("$5\r\nhello\r\n");
    const bulk = try readBulkString(&reader, key_size_max, error.KeyTooLarge);
    try std.testing.expectEqualStrings("hello", bulk);

    reader = Io.Reader.fixed("$2000\r\n");
    try std.testing.expectError(
        ParseError.KeyTooLarge,
        readBulkString(&reader, key_size_max, error.KeyTooLarge),
    );
}

test parseCommand {
    var reader = Io.Reader.fixed(
        "*3\r\n$3\r\nSET\r\n$5\r\nhello\r\n$6\r\nWorld!\r\n" ++
            "*2\r\n$3\r\nGET\r\n$5\r\nhello\r\n",
    );

    const cmd1 = (try parseCommand(&reader)).?;
    try std.testing.expect(cmd1 == .set);
    try std.testing.expectEqualStrings("hello", cmd1.set.key);
    try std.testing.expectEqualStrings("World!", cmd1.set.value);

    const cmd2 = (try parseCommand(&reader)).?;
    try std.testing.expect(cmd2 == .get);
    try std.testing.expectEqualStrings("hello", cmd2.get);

    try std.testing.expectEqual(@as(?Command, null), try parseCommand(&reader));
}

test "parseCommand strlen, append, setnx, and getdel" {
    var reader = Io.Reader.fixed(
        "*2\r\n$6\r\nSTRLEN\r\n$3\r\nkey\r\n" ++
            "*3\r\n$6\r\nAPPEND\r\n$3\r\nkey\r\n$4\r\ntail\r\n" ++
            "*3\r\n$5\r\nSETNX\r\n$3\r\nkey\r\n$3\r\nval\r\n" ++
            "*2\r\n$6\r\nGETDEL\r\n$3\r\nkey\r\n",
    );

    const c1 = (try parseCommand(&reader)).?;
    try std.testing.expect(c1 == .strlen);
    try std.testing.expectEqualStrings("key", c1.strlen);

    const c2 = (try parseCommand(&reader)).?;
    try std.testing.expect(c2 == .append);
    try std.testing.expectEqualStrings("key", c2.append.key);
    try std.testing.expectEqualStrings("tail", c2.append.value);

    const c3 = (try parseCommand(&reader)).?;
    try std.testing.expect(c3 == .setnx);
    try std.testing.expectEqualStrings("key", c3.setnx.key);
    try std.testing.expectEqualStrings("val", c3.setnx.value);

    const c4 = (try parseCommand(&reader)).?;
    try std.testing.expect(c4 == .getdel);
    try std.testing.expectEqualStrings("key", c4.getdel);

    try std.testing.expectEqual(@as(?Command, null), try parseCommand(&reader));
}

test "parseCommand getset, mget, mset, and variadic del/exists" {
    var reader = Io.Reader.fixed(
        "*3\r\n$6\r\nGETSET\r\n$2\r\nk1\r\n$2\r\nv1\r\n" ++
            "*4\r\n$4\r\nMGET\r\n$2\r\nk1\r\n$2\r\nk2\r\n$2\r\nk3\r\n" ++
            "*5\r\n$4\r\nMSET\r\n$2\r\nk1\r\n$2\r\na1\r\n$2\r\nk2\r\n$2\r\na2\r\n" ++
            "*3\r\n$3\r\nDEL\r\n$2\r\nk1\r\n$2\r\nk2\r\n",
    );

    const c1 = (try parseCommand(&reader)).?;
    try std.testing.expect(c1 == .getset);
    try std.testing.expectEqualStrings("k1", c1.getset.key);
    try std.testing.expectEqualStrings("v1", c1.getset.value);

    const c2 = (try parseCommand(&reader)).?;
    try std.testing.expect(c2 == .mget);
    try std.testing.expectEqual(@as(u8, 3), c2.mget.len);
    try std.testing.expectEqualStrings("k2", c2.mget.slice()[1]);

    const c3 = (try parseCommand(&reader)).?;
    try std.testing.expect(c3 == .mset);
    try std.testing.expectEqual(@as(u8, 2), c3.mset.len);
    try std.testing.expectEqualStrings("k2", c3.mset.slice()[1].key);
    try std.testing.expectEqualStrings("a2", c3.mset.slice()[1].value);

    const c4 = (try parseCommand(&reader)).?;
    try std.testing.expect(c4 == .del);
    try std.testing.expectEqual(@as(u8, 2), c4.del.len);

    try std.testing.expectEqual(@as(?Command, null), try parseCommand(&reader));
}