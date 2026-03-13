const std = @import("std");
const Crc32 = std.hash.Crc32;
const testing = std.testing;

pub const BinaryMessage = struct {
    const Self = @This();
    const MAGIC = 0x7102;
    const VERSION = 1;

    version: u8 = VERSION,
    topic_len: u16,
    topic: []const u8,
    partition: u32,
    msg_offset: u64,
    max_bytes: u32,

    pub fn validate(data: []const u8) bool {
        // magic + version + topic_len + partition + msg_offset + max_bytes + crc
        const min_len = 2 + 1 + 2 + 4 + 8 + 4 + 4;
        if (data.len < min_len) return false;

        const magic = std.mem.readInt(u16, data[0..2], .little);
        if (magic != MAGIC) return false;

        const version = data[2];
        if (version != VERSION) return false;

        var offset: usize = 3;
        const topic_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        const required = min_len + @as(usize, topic_len);
        if (data.len != required) return false;

        const crc_hash = Crc32.hash(data[0 .. data.len - 4]);
        const crc = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        if (crc_hash != crc) return false;

        return true;
    }

    /// no validation here. we should panic as we expect the message to be validated earlier
    pub fn peekOffset(data: []const u8) u64 {
        // layout:
        // [magic:u16][version:u8][topic_len:u16][topic][partition:u32][msg_offset:u64][max_bytes:u32][crc:u32]
        // msg_offset starts 16 bytes before the end: [msg_offset:8][max_bytes:4][crc:4]
        const offset = data.len - 16;
        return std.mem.readInt(u64, data[offset..][0..8], .little);
    }

    pub fn decode(data: []const u8) !Self {
        // little-endian:
        // [magic:u16][version:u8][topic_len:u16][topic:[topic_len]u8][partition:u32][msg_offset:u64][max_bytes:u32][crc:u32]

        const min_len = 2 + 1 + 2 + 4 + 8 + 4 + 4;
        if (data.len < min_len) return error.InvalidMessage;

        const magic = std.mem.readInt(u16, data[0..2], .little);
        if (magic != MAGIC) return error.InvalidMessage;

        const version = data[2];
        if (version != VERSION) return error.InvalidMessage;

        var offset: usize = 3;

        const topic_len = std.mem.readInt(u16, data[offset..][0..2], .little);
        offset += 2;

        if (offset + topic_len > data.len) return error.InvalidMessage;
        const topic = data[offset..][0..topic_len];
        offset += topic_len;

        if (offset + 4 > data.len) return error.InvalidMessage;
        const partition = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + 8 > data.len) return error.InvalidMessage;
        const msg_offset = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;

        if (offset + 4 > data.len) return error.InvalidMessage;
        const max_bytes = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        if (offset + 4 != data.len) return error.InvalidMessage;

        const crc_hash = Crc32.hash(data[0..offset]);
        const crc = std.mem.readInt(u32, data[offset..][0..4], .little);

        if (crc_hash != crc) return error.CorruptMessage;

        return .{
            .version = version,
            .topic_len = topic_len,
            .topic = topic,
            .partition = partition,
            .msg_offset = msg_offset,
            .max_bytes = max_bytes,
        };
    }

    pub fn encode(self: *const Self, buffer: []u8) ![]u8 {
        return buildFrame(
            buffer,
            self.version,
            self.topic,
            self.partition,
            self.msg_offset,
            self.max_bytes,
        );
    }
};

/// helper function to build a valid encoded frame into `buffer`. returns the slice written.
/// layout in little-endian:
/// [magic:u16][version:u8][topic_len:u16][topic:[topic_len]u8][partition:u32][msg_offset:u64][max_bytes:u32][crc:u32]
pub fn buildFrame(
    buffer: []u8,
    version: u8,
    topic: []const u8,
    partition: u32,
    msg_offset: u64,
    max_bytes: u32,
) ![]u8 {
    const required = 2 + 1 + 2 + topic.len + 4 + 8 + 4 + 4;
    if (buffer.len < required) return error.BufferTooSmall;
    if (topic.len > std.math.maxInt(u16)) return error.TopicTooLarge;

    var offset: usize = 0;

    std.mem.writeInt(u16, buffer[offset..][0..2], BinaryMessage.MAGIC, .little);
    offset += 2;

    buffer[offset] = version;
    offset += 1;

    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(topic.len), .little);
    offset += 2;

    @memcpy(buffer[offset .. offset + topic.len], topic);
    offset += topic.len;

    std.mem.writeInt(u32, buffer[offset..][0..4], partition, .little);
    offset += 4;

    std.mem.writeInt(u64, buffer[offset..][0..8], msg_offset, .little);
    offset += 8;

    std.mem.writeInt(u32, buffer[offset..][0..4], max_bytes, .little);
    offset += 4;

    const crc = Crc32.hash(buffer[0..offset]);
    std.mem.writeInt(u32, buffer[offset..][0..4], crc, .little);
    offset += 4;

    return buffer[0..offset];
}

test "decode: valid message round-trips correctly" {
    var buffer: [256]u8 = undefined;
    const topic = "orders.events";

    const frame = try buildFrame(&buffer, 1, topic, 7, 12345, 4096);
    const msg = try BinaryMessage.decode(frame);

    try testing.expectEqual(@as(u8, 1), msg.version);
    try testing.expectEqual(@as(u16, @intCast(topic.len)), msg.topic_len);
    try testing.expectEqualSlices(u8, topic, msg.topic);
    try testing.expectEqual(@as(u32, 7), msg.partition);
    try testing.expectEqual(@as(u64, 12345), msg.msg_offset);
    try testing.expectEqual(@as(u32, 4096), msg.max_bytes);
}

test "decode: empty topic is valid" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "", 0, 99, 1024);
    const msg = try BinaryMessage.decode(frame);

    try testing.expectEqual(@as(usize, 0), msg.topic.len);
    try testing.expectEqual(@as(u16, 0), msg.topic_len);
    try testing.expectEqual(@as(u32, 0), msg.partition);
    try testing.expectEqual(@as(u64, 99), msg.msg_offset);
    try testing.expectEqual(@as(u32, 1024), msg.max_bytes);
}

test "decode: wrong magic returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "t", 1, 2, 3);

    buffer[0] = 0xDE;
    buffer[1] = 0xAD;

    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame));
}

test "decode: wrong version returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "t", 1, 2, 3);

    buffer[2] = 99; // unsupported version; version check should fail before crc

    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame));
}

test "decode: flipped byte returns error.CorruptMessage" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic-a", 5, 42, 8192);

    // Flip one byte inside topic/payload area (after magic/version/topic_len)
    const flip_idx: usize = 2 + 1 + 2;
    buffer[flip_idx] ^= 0xFF;

    try testing.expectError(error.CorruptMessage, BinaryMessage.decode(frame));
}

test "decode: truncated frame returns error.InvalidMessage" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic", 1, 2, 3);

    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(frame[0 .. frame.len - 1]));
}

test "decode: trailing garbage bytes returns error.InvalidMessage" {
    var buffer: [260]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic", 1, 2, 3);

    buffer[frame.len] = 0xAB;

    try testing.expectError(error.InvalidMessage, BinaryMessage.decode(buffer[0 .. frame.len + 1]));
}

test "validate: valid message returns true" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic", 3, 12345, 2048);

    try testing.expect(BinaryMessage.validate(frame));
}

test "validate: invalid message returns false" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic", 3, 12345, 2048);

    buffer[0] = 0xDE;
    buffer[1] = 0xAD;

    try testing.expect(!BinaryMessage.validate(frame));
}

test "peekOffset: returns correct offset" {
    var buffer: [256]u8 = undefined;
    const frame = try buildFrame(&buffer, 1, "topic", 9, 12345, 5000);

    try testing.expectEqual(@as(u64, 12345), BinaryMessage.peekOffset(frame));
}
