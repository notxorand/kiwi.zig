const std = @import("std");

const zio = @import("zio");

const binary_consume = @import("binary/consume.zig");
const binary_produce = @import("binary/produce.zig");
const partition = @import("partition.zig");
const registry = @import("registry.zig");
const segment = @import("segment.zig");
const tcp = @import("transport/tcp.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();

    var group: zio.Group = .init;
    defer group.cancel();

    var topic_registry = registry.TopicRegistry.init(allocator);
    defer topic_registry.deinit();

    var transport = try tcp.TcpTransport.init("0.0.0.0", 2049, &topic_registry);
    try transport.listen(&group);
}

test {
    _ = binary_consume;
    _ = binary_produce;
    _ = segment;
    _ = partition;
}
