const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;

const Partition = @import("partition.zig").Partition;

pub const TopicRegistry = struct {
    const Self = @This();

    map: StringHashMap(AutoHashMap(u64, Partition)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .map = StringHashMap(AutoHashMap(u64, Partition)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.map.valueIterator();
        while (iterator.next()) |map| {
            var iterator_partitions = map.*.valueIterator();
            while (iterator_partitions.next()) |partition| {
                partition.*.deinit();
            }
            map.*.deinit();
        }
        self.map.deinit();
    }

    pub fn get(self: *Self, topic: []const u8) ?*AutoHashMap(u64, Partition) {
        return self.map.getPtr(topic);
    }

    pub fn put(self: *Self, topic: []const u8, partition: u64, value: Partition) !void {
        if (self.map.getPtr(topic)) |map| {
            try map.put(partition, value);
        } else {
            var new_map = AutoHashMap(u64, Partition).init(self.allocator);
            try new_map.put(partition, value);
            try self.map.put(topic, new_map);
        }
    }
};
