const std = @import("std");

const ChannelImpl = @import("../transport/channel.zig").Channel;

pub const ConsumeHandler = struct {
    const Self = @This();

    pub fn handle(self: *Self, frame: []const u8, writer: anytype) !void {
        _ = self;
        _ = frame;
        _ = writer;
    }
};
