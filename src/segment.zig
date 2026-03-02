const std = @import("std");
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

    pub fn append(self: *Self, data: []const u8) !void {
        var buffer_log: [4096]u8 = undefined;
        var buffer_index: [4096]u8 = undefined;
        const writer_log = self.file_log.writer(&buffer_log);
        const writer_index = self.file_index.writer(&buffer_index);
        const offset = binary.BinaryMessage.peekOffset(data);
        if (self.size == 0 and self.base_offset == 0) self.base_offset = offset;
        // TODO: write log and index
    }

    pub fn sync(self: *Self) !void {
        try self.file_log.sync();
        try self.file_index.sync();
    }
};
