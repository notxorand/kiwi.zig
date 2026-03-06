const std = @import("std");
const testing = std.testing;

const binary = @import("binary.zig");

const Segment = struct {
    const Self = @This();
    const MAX_SEGMENT_SIZE: u64 = 4096 * 1024; // 4MB

    allocator: std.mem.Allocator,
    path_log: []const u8,
    path_index: []const u8,
    file_log: std.fs.File,
    file_index: std.fs.File,
    size: u64 = 0,
    base_offset: u64 = 0,
    next_offset: u64 = 0,
    count_index: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        const path_log = try std.fmt.allocPrint(allocator, "{s}.log", .{path});
        const path_index = try std.fmt.allocPrint(allocator, "{s}.idx", .{path});

        return Self{
            .allocator = allocator,
            .path_log = path_log,
            .path_index = path_index,
            .file_log = try std.fs.cwd().createFile(path_log, .{ .truncate = false, .read = true }),
            .file_index = try std.fs.cwd().createFile(path_index, .{ .truncate = false, .read = true }),
        };
    }

    pub fn deinit(self: *Self) void {
        self.file_log.close();
        self.file_index.close();
        self.allocator.free(self.path_log);
        self.allocator.free(self.path_index);
    }

    pub fn append(self: *Self, data: []const []const u8) !void {
        var buffer_log: [4096]u8 = undefined;
        var buffer_index: [4096]u8 = undefined;
        var writer_log = self.file_log.writer(&buffer_log);
        var writer_index = self.file_index.writer(&buffer_index);

        for (data) |frame| {
            const offset = binary.BinaryMessage.peekOffset(frame);
            if (self.size == 0 and self.base_offset == 0) self.base_offset = offset;

            try writer_log.interface.writeAll(frame);
            try writer_index.interface.writeInt(u64, offset, .little);
            try writer_index.interface.writeInt(u64, self.size, .little);

            self.size += frame.len;
            self.next_offset = offset + 1;
            self.count_index += 1;
        }
        try writer_log.interface.flush();
        try writer_index.interface.flush();
    }

    pub fn sync(self: *Self) !void {
        try self.file_log.sync();
        try self.file_index.sync();
    }
};

test "append: simple" {
    const allocator = testing.allocator;

    var segment = try Segment.init(allocator, "simple_test");
    defer segment.deinit();

    var buffer: [256]u8 = undefined;
    const frame = binary.buildFrame(&buffer, 1, 0, 0, "k", "v", 1);
    const frame2 = binary.buildFrame(&buffer, 1, 0, 0, "k", "v", 2);
    const frame3 = binary.buildFrame(&buffer, 1, 0, 0, "k", "v", 3);
    const frame4 = binary.buildFrame(&buffer, 1, 0, 0, "k", "v", 4);
    var data = [_][]const u8{ "", "", "", "" };
    data[0] = frame;
    data[1] = frame2;
    data[2] = frame3;
    data[3] = frame4;

    try segment.append(&data);
}
