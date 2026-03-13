const std = @import("std");

const ChannelImpl = @import("../transport/channel.zig").Channel;

pub fn ConsumeHandler(comptime Transport: type) type {
    return struct {
        const Self = @This();
        channel: ?*Channel = null,

        const Channel = ChannelImpl(Transport);

        pub fn handle(self: *Self, frame: []const u8, writer: anytype) !void {
            _ = writer;
            if (self.channel) |channel| {
                try channel.channel.send(Channel.ChannelData{ .data = frame });
            }
        }
    };
}
