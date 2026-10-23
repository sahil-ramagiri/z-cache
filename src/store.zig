const std = @import("std");
const resp = @import("resp.zig");
const assert = std.debug.assert;

pub const StoreError = error{
    StoreFull,
    InvalidKeySize,
    InvalidValueSize,
};

pub const Store = struct {
    /// Maps key slice -> slot index (u32)
    index: std.StringHashMapUnmanaged(u32) = undefined,

    /// Pre-allocated fixed 1KiB key & value buffers (`entries_max` slots)
    keys: [][resp.key_size_max]u8,
    key_lengths: []u16,

    values: [][resp.value_size_max]u8,
    value_lengths: []u16,

    /// Free slot stack (LIFO index list)
    free_slots: []u32,
    free_count: u32,

    pub fn init(alloc: std.mem.Allocator, entries_max: u32) !Store {
        assert(entries_max > 0);

        var index: std.StringHashMapUnmanaged(u32) = .empty;
        try index.ensureTotalCapacity(alloc, entries_max);
        errdefer index.deinit(alloc);

        const keys = try alloc.alloc([resp.key_size_max]u8, entries_max);
        errdefer alloc.free(keys);

        const key_lengths = try alloc.alloc(u16, entries_max);
        errdefer alloc.free(key_lengths);
        @memset(key_lengths, 0);

        const values = try alloc.alloc([resp.value_size_max]u8, entries_max);
        errdefer alloc.free(values);

        const value_lengths = try alloc.alloc(u16, entries_max);
        errdefer alloc.free(value_lengths);
        @memset(value_lengths, 0);

        const free_slots = try alloc.alloc(u32, entries_max);
        errdefer alloc.free(free_slots);
        for (free_slots, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }

        return .{
            .index = index,
            .keys = keys,
            .key_lengths = key_lengths,
            .values = values,
            .value_lengths = value_lengths,
            .free_slots = free_slots,
            .free_count = entries_max,
        };
    }

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        alloc.free(self.free_slots);
        alloc.free(self.value_lengths);
        alloc.free(self.values);
        alloc.free(self.key_lengths);
        alloc.free(self.keys);
        self.index.deinit(alloc);
        self.* = undefined;
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) StoreError!void {
        if(key.len > resp.key_size_max) return error.InvalidKeySize;
        if(value.len > resp.value_size_max) return error.InvalidValueSize;

        
        if (self.index.get(key)) |slot| {
            @memcpy(self.values[slot][0..value.len], value);
            self.value_lengths[slot] = @intCast(value.len);
            return;
        }

        if (self.free_count == 0) return error.StoreFull;

        self.free_count -= 1;
        const slot = self.free_slots[self.free_count];

        @memcpy(self.keys[slot][0..key.len], key);
        self.key_lengths[slot] = @intCast(key.len);
        
        @memcpy(self.values[slot][0..value.len], value);
        self.value_lengths[slot] = @intCast(value.len);

        const stable_key = self.keys[slot][0..key.len];

        if (self.index.available == 0) {
            self.index.rehash(std.hash_map.StringContext{});
        }
        self.index.putAssumeCapacityNoClobber(stable_key, slot);
    }

    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        const slot = self.index.get(key) orelse return null;
        const len = self.value_lengths[slot];
        return self.values[slot][0..len];
    }

    pub fn exists(self: *const Store, key: []const u8) bool {
        return self.index.contains(key);
    }

    pub fn del(self: *Store, key: []const u8) bool {
        const removed = self.index.fetchRemove(key) orelse return false;
        const slot = removed.value;
        self.key_lengths[slot] = 0;
        self.value_lengths[slot] = 0;
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        return true;
    }

    pub fn strlen(self: *Store, key: []const u8) u32 {
        const slot = self.index.get(key) orelse return 0;
        return self.value_lengths[slot];
    }

    pub fn append(self: *Store, key: []const u8, value: []const u8) StoreError!u32 {
        //TODO: optimize to remove extra compares and gets

        const slot = self.index.get(key) orelse {
            try self.set(key, value);
            return @intCast(value.len);
        };
        const old_len = self.value_lengths[slot];
        const new_len = old_len + value.len;

        if (new_len > resp.value_size_max) return error.InvalidValueSize;

        @memcpy(self.values[slot][old_len..new_len], value);
        self.value_lengths[slot] = @intCast(new_len);

        return @intCast(new_len);
    }

    pub fn setnx(self: *Store, key: []const u8, value: []const u8) StoreError!bool {
        //TODO: optimize to remove extra compares and gets

        if (self.index.contains(key)) return false;
        
        try self.set(key, value);
        return true;
    }

    pub fn getdel(self: *Store, key: []const u8) ?[]const u8 {
        const removed = self.index.fetchRemove(key) orelse return null;
        const slot = removed.value;
        const len = self.value_lengths[slot];

        self.key_lengths[slot] = 0;
        self.value_lengths[slot] = 0;
        self.free_slots[self.free_count] = slot;
        self.free_count += 1;

        return self.values[slot][0..len];
    }
};

test "Store set, get, exists, del, and capacity reuse" {
    const gpa = std.testing.allocator;
    var kv = try Store.init(gpa, 2);
    defer kv.deinit(gpa);

    try std.testing.expect(!kv.exists("k1"));
    try std.testing.expectEqual(@as(?[]const u8, null), kv.get("k1"));

    try kv.set("k1", "v1");
    try std.testing.expect(kv.exists("k1"));
    try std.testing.expectEqualStrings("v1", kv.get("k1").?);

    // Overwrite existing key in-place without consuming another slot
    try kv.set("k1", "updated");
    try std.testing.expectEqualStrings("updated", kv.get("k1").?);
    try std.testing.expectEqual(@as(u32, 1), kv.free_count);

    // Fill second slot
    try kv.set("k2", "v2");
    try std.testing.expectEqual(@as(u32, 0), kv.free_count);

    // Third distinct key must fail with StoreFull
    try std.testing.expectError(StoreError.StoreFull, kv.set("k3", "v3"));

    // Delete k1 and verify slot is recycled for k3 (including across many cycles to test tombstone rehash)
    try std.testing.expect(kv.del("k1"));
    try std.testing.expect(!kv.exists("k1"));
    try std.testing.expect(!kv.del("k1"));

    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try kv.set("k3", "v3");
        try std.testing.expectEqualStrings("v3", kv.get("k3").?);
        try std.testing.expect(kv.del("k3"));
    }
}

test "Store strlen, append, setnx, and getdel" {
    const gpa = std.testing.allocator;
    var kv = try Store.init(gpa, 4);
    defer kv.deinit(gpa);

    // STRLEN on missing key returns 0
    try std.testing.expectEqual(@as(u32, 0), kv.strlen("msg"));

    // APPEND on missing key creates key and returns length
    try std.testing.expectEqual(@as(u32, 5), try kv.append("msg", "Hello"));
    try std.testing.expectEqual(@as(u32, 5), kv.strlen("msg"));
    try std.testing.expectEqualStrings("Hello", kv.get("msg").?);

    // APPEND on existing key concatenates in-place
    try std.testing.expectEqual(@as(u32, 12), try kv.append("msg", ", World"));
    try std.testing.expectEqual(@as(u32, 12), kv.strlen("msg"));
    try std.testing.expectEqualStrings("Hello, World", kv.get("msg").?);

    // APPEND exceeding value_size_max returns InvalidValueSize without corrupting value
    const big: [resp.value_size_max]u8 = @splat('x');
    try std.testing.expectError(StoreError.InvalidValueSize, kv.append("msg", &big));
    try std.testing.expectEqualStrings("Hello, World", kv.get("msg").?);

    // SETNX on existing key returns false and preserves old value
    try std.testing.expect(!(try kv.setnx("msg", "overwrite")));
    try std.testing.expectEqualStrings("Hello, World", kv.get("msg").?);

    // SETNX on new key returns true and sets value
    try std.testing.expect(try kv.setnx("fresh", "abc"));
    try std.testing.expectEqualStrings("abc", kv.get("fresh").?);

    // GETDEL returns value and removes key + recycles slot
    try std.testing.expectEqualStrings("Hello, World", kv.getdel("msg").?);
    try std.testing.expect(!kv.exists("msg"));
    try std.testing.expectEqual(@as(?[]const u8, null), kv.getdel("msg"));
}
