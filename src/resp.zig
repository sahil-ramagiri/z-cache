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

pub const Command = union(enum) {
    ping: void,
    set: struct {
        key: []const u8,
        value: []const u8,
    },
    get: []const u8,
    exists: []const u8,
    del: []const u8,
};

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
        reader.buffer.len - reader.seek < command_size_max) {
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

    if (std.ascii.eqlIgnoreCase(cmd_name, "PING")) {
        if (arity != 1) {
            try skipBulkString(reader, remaining);
            return error.InvalidArity;
        }
        return .ping;
    } else if (std.ascii.eqlIgnoreCase(cmd_name, "SET")) {
        if (arity != 3) {
            try skipBulkString(reader, remaining);
            return error.InvalidArity;
        }
        const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
        const value = try readBulkString(reader, value_size_max, error.ValueTooLarge);
        return .{ .set = .{ .key = key, .value = value } };
    } else if (std.ascii.eqlIgnoreCase(cmd_name, "GET")) {
        if (arity != 2) {
            try skipBulkString(reader, remaining);
            return error.InvalidArity;
        }
        const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
        return .{ .get = key };
    } else if (std.ascii.eqlIgnoreCase(cmd_name, "EXISTS")) {
        if (arity != 2) {
            try skipBulkString(reader, remaining);
            return error.InvalidArity;
        }
        const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
        return .{ .exists = key };
    } else if (std.ascii.eqlIgnoreCase(cmd_name, "DEL")) {
        if (arity != 2) {
            try skipBulkString(reader, remaining);
            return error.InvalidArity;
        }
        const key = try readBulkString(reader, key_size_max, error.KeyTooLarge);
        return .{ .del = key };
    } else {
        try skipBulkString(reader, remaining);
        return error.UnknownCommand;
    }
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