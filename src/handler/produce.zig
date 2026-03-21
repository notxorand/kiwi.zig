const std = @import("std");

pub const ProduceHandler = struct {
    const Self = @This();

    pub fn handle(self: *Self, frame: []const u8, writer: anytype) !void {
        _ = self;
        _ = frame;
        _ = writer;
    }
};
