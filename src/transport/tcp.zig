const std = @import("std");

const zio = @import("zio");

const binary_consume = @import("../binary/consume.zig");
const binary_produce = @import("../binary/produce.zig");
const ConsumeHandler = @import("../handler/consume.zig").ConsumeHandler;
const ProduceHandler = @import("../handler/produce.zig").ProduceHandler;

const Channel = @import("channel.zig").Channel(TcpTransport);

pub const TcpTransport = struct {
    const Self = @This();

    address: zio.net.IpAddress,
    consume_handler: ConsumeHandler(Self),
    produce_handler: ProduceHandler(Self),

    pub fn init(address: []const u8, port: u16) !Self {
        return Self{
            .address = try zio.net.IpAddress.parseIp4(address, port),
            .consume_handler = ConsumeHandler(Self){},
            .produce_handler = ProduceHandler(Self){},
        };
    }

    pub fn listen(self: *Self, group: *zio.Group, channel: *Channel) !void {
        const server = try self.address.listen(.{});
        defer server.close();
        std.log.info("TCP transport server listening on {f}", .{server.socket.address});

        while (true) {
            const stream = try server.accept();
            errdefer stream.close();

            try group.spawn(handle, .{ self, channel, stream });
        }
    }

    fn handle(self: *Self, channel: *Channel, stream: zio.net.Stream) !void {
        self.consume_handler.channel = channel;
        self.produce_handler.channel = channel;

        defer stream.close();
        const socket_address = stream.socket.address;

        std.log.info("Client connected: {f}", .{socket_address});

        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(&read_buffer);

        var writer_buffer: [1024]u8 = undefined;
        var writer = stream.writer(&writer_buffer);

        while (true) {
            var len_buf: [8]u8 = undefined;
            reader.interface.readSliceAll(&len_buf) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return reader.err orelse e,
                else => |e| return e,
            };

            const total_len = std.mem.readInt(u64, &len_buf, .big);

            if (total_len == 0 or total_len > read_buffer.len) {
                try writer.interface.writeAll("ERROR: Invalid Length\n");
                try writer.interface.flush();
                continue;
            }

            const frame = reader.interface.take(total_len) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return reader.err orelse e,
                else => |e| return e,
            };

            if (binary_produce.BinaryMessage.validate(frame)) {
                try self.produce_handler.handle(frame, &writer);
            } else if (binary_consume.BinaryMessage.validate(frame)) {
                try self.consume_handler.handle(frame, &writer);
            } else {
                try writer.interface.writeAll("ERROR: Invalid Message\n");
                try writer.interface.flush();
                continue;
            }
        }

        std.log.info("Client disconnected: {f}", .{socket_address});
    }
};

// Possible writebacks:
// ERROR: <issue>
// ACK: [[offset_range], ack_level]
// CLOSE: <reason>
