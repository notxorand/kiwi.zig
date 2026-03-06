const std = @import("std");
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.Crc32;
const testing = std.testing;

pub const BinaryMessage = struct {
    const Self = @This();
    const MAGIC = 0x7101;
    const VERSION = 1;

    version: u8 = VERSION,
    flags: u8,
    timestamp: i64,
    key: []const u8,
    payload: []const u8,
    offset: u64,

    pub fn validate(data: []const u8) bool {
        // magic + version + flags + timestamp + key_len + payload_len + offset + crc
        const header_len = 2 + 1 + 1 + 8 + 2 + 4 + 8 + 4;
        if (data.len < header_len) return false;

        const magic = std.mem.readInt(u16, data[0..][0..2], .little);
        if (magic != MAGIC) return false;

        const version = data[2];
        if (version != VERSION) return false;

        const crc_hash = Crc32.hash(data[0 .. data.len - 4]);

        const crc = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);

        if (crc_hash != crc) return false;

        return true;
    }

    /// no validation here. we should panic as we expect the message to be validated earlier
    pub fn peekOffset(data: []const u8) u64 {
        const offset = data.len - 4 - 8;
        return std.mem.readInt(u64, data[offset..][0..8], .little);
    }

    pub fn decode(data: []const u8) !Self {
        // little-endian:
        // [magic:u16][version:u8][flags:u8][timestamp:i64][key_len:u16][payload_len:u32][key:[key_len]u8][payload:[payload_len]u8][offset:u64][crc:u32]

        // magic + version + flags + timestamp + key_len + payload_len + offset + crc
        const header_len = 2 + 1 + 1 + 8 + 2 + 4 + 8 + 4;
        if (data.len < header_len) return error.InvalidMessage;

        const magic = std.mem.readInt(u16, data[0..][0..2], .little);
        if (magic != MAGIC) return error.InvalidMessage;

        const version = data[2];
        if (version != VERSION) return error.InvalidMessage;

        const flags = data[3];

        var offset: usize = 4;
        const timestamp_bits = std.mem.readInt(u64, data[offset..][0..8], .little);
        const timestamp: i64 = @bitCast(timestamp_bits);
        offset += 8;

        const key_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        const payload_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + key_len > data.len) return error.InvalidMessage;
        const key = data[offset..][0..key_len];
        offset += key_len;

        if (offset + payload_len > data.len) return error.InvalidMessage;
        const payload = data[offset..][0..payload_len];
        offset += payload_len;

        const msg_offset = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        if (offset + 4 > data.len) return error.InvalidMessage;

        const crc_hash = Crc32.hash(data[0..offset]);

        const crc = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (crc_hash != crc) return error.CorruptMessage;

        if (offset != data.len) return error.InvalidMessage;

        return .{
            .version = version,
            .flags = flags,
            .timestamp = timestamp,
            .key = key,
            .payload = payload,
            .offset = msg_offset,
        };
    }

    pub fn encode(self: *Self, buffer: []u8) usize {
        buildFrame(&buffer, self.version, self.flags, self.timestamp, self.key, self.payload, self.offset);
        return buffer.len;
    }
};

/// helper function to build a valid encoded frame into `buffer`. returns the slice written.
/// layout in little-endian:
/// [magic:u16][version:u8][flags:u8][timestamp:i64][key_len:u16][payload_len:u32][key:[key_len]u8][payload:[payload_len]u8][crc:u32]
pub fn buildFrame(
    buffer: []u8,
    version: u8,
    flags: u8,
    timestamp: i64,
    key: []const u8,
    payload: []const u8,
    msg_offset: u64,
) []u8 {
    var offset: usize = 0;

    std.mem.writeInt(u16, buffer[offset..][0..2], BinaryMessage.MAGIC, .little);
    offset += 2;
    buffer[offset] = version;
    offset += 1;
    buffer[offset] = flags;
    offset += 1;

    const ts_bits: u64 = @bitCast(timestamp);
    std.mem.writeInt(u64, buffer[offset..][0..8], ts_bits, .little);
    offset += 8;

    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(key.len), .little);
    offset += 2;
    std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(payload.len), .little);
    offset += 4;

    @memcpy(buffer[offset..][0..key.len], key);
    offset += key.len;
    @memcpy(buffer[offset..][0..payload.len], payload);
    offset += payload.len;

    std.mem.writeInt(u64, buffer[offset..][0..8], msg_offset, .little);
    offset += 8;

    const crc = Crc32.hash(buffer[0..offset]);
    std.mem.writeInt(u32, buffer[offset..][0..4], crc, .little);
    offset += 4;

    return buffer[0..offset];
}

test "decode: valid message round-trips correctly" {
    var buffer: [256]u8 = undefined;
    const key = "sensor-1";
    const payload = "hello broker";
    const ts: i64 = 1_700_000_000_000_000_000;

    const frame = buildFrame(&buffer, 1, 0, ts, key, payload, 12345);
    const msg = try BinaryMessage.decode(frame);

    try testing.expectEqual(@as(u8, 1), msg.version);
    try testing.expectEqual(@as(u8, 0), msg.flags);
    try testing.expectEqual(ts, msg.timestamp);
    try testing.expectEqualSlices(u8, key, msg.key);
    try testing.expectEqualSlices(u8, payload, msg.payload);
    try testing.expectEqual(@as(u64, 12345), msg.offset);
}

test "decode: empty key is valid" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "", "some-payload", 12345);
    const msg = try BinaryMessage.decode(frame);
    try testing.expectEqual(@as(usize, 0), msg.key.len);
    try testing.expectEqualSlices(u8, "some-payload", msg.payload);
    try testing.expectEqual(@as(u64, 12345), msg.offset);
}

test "decode: empty payload is valid" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "my-key", "", 12345);
    const msg = try BinaryMessage.decode(frame);
    try testing.expectEqualSlices(u8, "my-key", msg.key);
    try testing.expectEqual(@as(usize, 0), msg.payload.len);
    try testing.expectEqual(@as(u64, 12345), msg.offset);
}

test "decode: flags field is preserved" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0xFF, 0, "k", "v", 12345);
    const msg = try BinaryMessage.decode(frame);
    try testing.expectEqual(@as(u8, 0xFF), msg.flags);
}

test "decode: wrong magic returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "k", "v", 12345);
    buffer[0] = 0xDE;
    buffer[1] = 0xAD;
    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame));
}

test "decode: wrong version returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "k", "v", 12345);
    buffer[2] = 99; // unsupported version — CRC will also fail, but version check fires first
    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame));
}

test "decode: flipped payload byte returns error.CorruptMessage" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 42, "key", "payload", 12345);
    const payload_start = 2 + 1 + 1 + 8 + 2 + 4 + 3; // header + key_len + payload_len + key
    buffer[payload_start] ^= 0xFF;
    try testing.expectError(error.CorruptMessage, BinaryMessage.decode(frame));
}

test "decode: truncated frame returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "key", "payload", 12345);
    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame[0 .. frame.len - 4]));
}

test "decode: trailing garbage bytes returns error.InvalidMessage" {
    var buffer: [260]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "key", "payload", 12345);
    buffer[frame.len] = 0xAB;
    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(buffer[0 .. frame.len + 1]));
}

test "decode: negative timestamp survives bitcast round-trip" {
    var buffer: [256]u8 = undefined;
    const ts: i64 = -9_999_999_999_999;
    const frame = buildFrame(&buffer, 1, 0, ts, "k", "v", 12345);
    const msg = try BinaryMessage.decode(frame);
    try testing.expectEqual(ts, msg.timestamp);
}

test "validate: valid message returns true" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "k", "v", 12345);
    try testing.expect(BinaryMessage.validate(frame));
}

test "validate: invalid message returns false" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "k", "v", 12345);
    buffer[0] = 0xDE;
    buffer[1] = 0xAD;
    try testing.expect(!BinaryMessage.validate(frame));
}

test "peekOffset: returns correct offset" {
    var buffer: [256]u8 = undefined;
    const frame = buildFrame(&buffer, 1, 0, 0, "k", "v", 12345);
    try testing.expectEqual(@as(u64, 12345), BinaryMessage.peekOffset(frame));
}
