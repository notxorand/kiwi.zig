const std = @import("std");
const zio = @import("zio");

/// Takes in a transport abstraction and feeds its incoming stream to the shared MPSC channel.
pub fn Channel(comptime Transport: type) type {
    return struct {
        const Self = @This();
        const CHANNEL_CAPACITY = 8192 * 2;

        transport: Transport,
        channel: zio.Channel(ChannelData),
        buffer: []ChannelData,
        allocator: std.mem.Allocator,

        pub const ChannelData = struct {
            data: []const u8,
        };

        pub fn init(allocator: std.mem.Allocator, transport: Transport) !Self {
            const buffer = try allocator.alloc(ChannelData, CHANNEL_CAPACITY);
            return Self{
                // TODO: are we actually freeing the buffer ?
                .allocator = allocator,
                .buffer = buffer,
                .channel = zio.Channel(ChannelData).init(buffer),
                .transport = transport,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Polls the transport for incoming data and writes it to the shared MPSC channel.
        pub fn receive(self: *Self) !void {
            var group: zio.Group = .init;
            defer group.cancel();

            try self.transport.listen(&group, self);
        }
    };
}
