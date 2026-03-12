const std = @import("std");
const testing = std.testing;
const binary = @import("binary.zig");

const Segment = @import("segment.zig").Segment;
const TopicRegistry = @import("registry.zig").TopicRegistry;

/// A partition is a collection of segments that share the same path prefix.
/// Note: we leave out recovery from here and instead pass in existing segments on creation.
pub const Partition = struct {
    const Self = @This();

    prefix: []const u8,
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment),

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8, segments: []Segment) !Self {
        try std.fs.cwd().makePath(prefix);
        var partition = Self{
            .prefix = prefix,
            .allocator = allocator,
            .segments = .empty,
        };
        for (segments) |segment| {
            try partition.segments.append(allocator, segment);
        }
        return partition;
    }

    pub fn deinit(self: *Self) void {
        for (self.segments.items) |*segment| {
            segment.deinit();
        }
        self.segments.deinit(self.allocator);
    }

    pub fn activeSegment(self: *Self) ?*Segment {
        const latest_id = if (self.segments.items.len > 0) self.segments.items.len - 1 else return null;
        const segment = &self.segments.items[latest_id];

        if (segment.size >= Segment.MAX_SEGMENT_SIZE) {
            return null;
        }
        return segment;
    }

    pub fn append(self: *Self, data: []const []const u8) !void {
        if (self.activeSegment()) |segment| {
            try segment.append(data);
        } else {
            const segment_path = try std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ self.prefix, self.segments.items.len });
            defer self.allocator.free(segment_path);

            var new_segment = try Segment.init(self.allocator, segment_path);
            try new_segment.append(data);
            try self.segments.append(self.allocator, new_segment);
        }
    }

    pub fn readAt(self: *Self, offset: u64) ![]u8 {
        for (self.segments.items) |*segment| {
            if (segment.count_index == 0) continue;
            if (offset >= segment.base_offset and offset < segment.next_offset) {
                return segment.readAt(offset);
            }
        }
        return error.OutOfBounds;
    }
};

test "append: create first segment and read/write data" {
    std.fs.cwd().deleteTree("partition_append") catch {};
    defer std.fs.cwd().deleteTree("partition_append") catch {};

    var partition = try Partition.init(testing.allocator, "partition_append", &[_]Segment{});
    // note: we don't deinit here cause our topic registry handles that

    try testing.expectEqualStrings("partition_append", partition.prefix);
    try testing.expectEqual(@as(usize, 0), partition.segments.items.len);

    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;

    const frame1 = binary.buildFrame(&b1, 1, 0, 0, "k1", "v1", 0);
    const frame2 = binary.buildFrame(&b2, 1, 0, 0, "k2", "v2", 1);
    const frame3 = binary.buildFrame(&b3, 1, 0, 0, "k3", "v3", 2);
    const frame4 = binary.buildFrame(&b4, 1, 0, 0, "k4", "v4", 3);

    const data = [_][]const u8{ frame1, frame2, frame3, frame4 };

    try partition.append(&data);

    try testing.expectEqual(@as(usize, 1), partition.segments.items.len);

    const first = try partition.readAt(0);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings(frame1, first);

    const second = try partition.readAt(1);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(frame2, second);

    const third = try partition.readAt(2);
    defer testing.allocator.free(third);
    try testing.expectEqualStrings(frame3, third);

    const fourth = try partition.readAt(3);
    defer testing.allocator.free(fourth);
    try testing.expectEqualStrings(frame4, fourth);

    var topic_registry = TopicRegistry.init(testing.allocator);
    defer topic_registry.deinit();

    try topic_registry.put("partition", 0, partition);
    const got = topic_registry.get("partition").?.get(0).?;
    try testing.expectEqual(partition, got);
}

test "readAt: return OutOfBounds when offset exceeds data" {
    var partition = try Partition.init(testing.allocator, "partition_oob", &[_]Segment{});
    defer partition.deinit();

    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;

    const frame1 = binary.buildFrame(&b1, 1, 0, 0, "k1", "v1", 0);
    const frame2 = binary.buildFrame(&b2, 1, 0, 0, "k2", "v2", 1);

    const data = [_][]const u8{ frame1, frame2 };

    try partition.append(&data);

    try testing.expectError(error.OutOfBounds, partition.readAt(999));
}
