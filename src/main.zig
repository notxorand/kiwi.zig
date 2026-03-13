const std = @import("std");

const zio = @import("zio");

const binary_consume = @import("binary/consume.zig");
const binary_produce = @import("binary/produce.zig");
const partition = @import("partition.zig");
const registry = @import("registry.zig");
const segment = @import("segment.zig");
const channel = @import("transport/channel.zig");
const tcp = @import("transport/tcp.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var transport_channel = try channel.Channel(tcp.TcpTransport).init(allocator, try tcp.TcpTransport.init("0.0.0.0", 2049));
    defer transport_channel.deinit();

    try transport_channel.receive();
}

test {
    _ = binary_consume;
    _ = binary_produce;
    _ = segment;
    _ = partition;
}
