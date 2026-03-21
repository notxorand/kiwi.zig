const std = @import("std");

const binary_consume = @import("../binary/consume.zig");
const TopicRegistry = @import("../registry.zig").TopicRegistry;

pub const ConsumeHandler = struct {
    const Self = @This();
    registry: *TopicRegistry,

    pub fn handle(self: *Self, frame: []const u8, writer: anytype) !void {
        const message = try binary_consume.BinaryMessage.decode(frame);
        const partitions = self.registry.get(message.topic) orelse {
            try writer.interface.writeAll("ERROR: Topic not found\n");
            try writer.interface.flush();
            return;
        };
        var partition = partitions.get(message.partition) orelse {
            try writer.interface.writeAll("ERROR: Partition not found\n");
            try writer.interface.flush();
            return;
        };

        try writer.interface.writeAll(try partition.readAt(message.msg_offset));
        try writer.interface.flush();
    }
};
