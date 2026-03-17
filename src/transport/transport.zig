const std = @import("std");
const zio = @import("zio");

/// Takes in a transport abstraction and feeds its incoming stream to the shared MPSC channel.
pub fn TransportImpl(comptime Transport: type) type {
    return struct {
        const Self = @This();

        transport: Transport,

        pub fn init(transport: Transport) !Self {
            return Self{
                .transport = transport,
            };
        }

        /// Polls the transport for incoming data and writes it to the shared MPSC channel.
        pub fn receive(self: *Self) !void {
            var group: zio.Group = .init;
            defer group.cancel();

            try self.transport.listen(&group, self);
        }
    };
}
