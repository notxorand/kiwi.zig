const std = @import("std");
const testing = std.testing;

const binary = @import("binary.zig");

pub const Segment = struct {
    const Self = @This();
    pub const MAX_SEGMENT_SIZE: u64 = 4096 * 1024; // 4MB
    const INDEX_ENTRY_SIZE: u64 = 16; // offset:u64 + position:u64

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

        var file_log = std.fs.cwd().createFile(path_log, .{ .truncate = false, .read = true }) catch |err| {
            allocator.free(path_log);
            allocator.free(path_index);
            return err;
        };
        errdefer file_log.close();

        const file_index = std.fs.cwd().createFile(path_index, .{ .truncate = false, .read = true }) catch |err| {
            allocator.free(path_log);
            allocator.free(path_index);
            return err;
        };
        errdefer file_index.close();

        var self = Self{
            .allocator = allocator,
            .path_log = path_log,
            .path_index = path_index,
            .file_log = file_log,
            .file_index = file_index,
        };

        try self.recover();

        return self;
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
            if (self.count_index == 0 and self.base_offset == 0) self.base_offset = offset;

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

    fn recover(self: *Self) !void {
        self.size = try self.file_log.getEndPos();

        const size_index = try self.file_index.getEndPos();
        if (size_index == 0) {
            self.count_index = 0;
            self.base_offset = 0;
            self.next_offset = 0;
            return;
        }
        if (size_index % INDEX_ENTRY_SIZE != 0) return error.CorruptIndex;

        self.count_index = size_index / INDEX_ENTRY_SIZE;

        const first = try self.readIndexEntryAt(0);
        self.base_offset = first.offset;

        const last = try self.readIndexEntryAt(self.count_index - 1);
        self.next_offset = last.offset + 1;
    }

    const IndexEntry = struct {
        offset: u64,
        position: u64,
    };

    fn readIndexEntryAt(self: *Self, idx: u64) !IndexEntry {
        var buf: [INDEX_ENTRY_SIZE]u8 = undefined;
        const byte_pos = idx * INDEX_ENTRY_SIZE;
        _ = try self.file_index.preadAll(&buf, byte_pos);

        return .{
            .offset = std.mem.readInt(u64, buf[0..8], .little),
            .position = std.mem.readInt(u64, buf[8..16], .little),
        };
    }

    fn findFloorIndex(self: *Self, target_offset: u64) !?u64 {
        if (self.count_index == 0) return null;

        var lo: u64 = 0;
        var hi: u64 = self.count_index; // exclusive upper bound

        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = try self.readIndexEntryAt(mid);

            if (entry.offset <= target_offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo == 0) return null;
        return lo - 1;
    }

    /// Returns an owned frame slice for the exact `offset`.
    /// WARNING: caller owns and must free returned memory.
    pub fn readAt(self: *Self, offset: u64) ![]u8 {
        if (self.count_index == 0) return error.OffsetNotFound;

        const floor_idx = (try self.findFloorIndex(offset)) orelse return error.OffsetNotFound;
        const floor_entry = try self.readIndexEntryAt(floor_idx);

        if (floor_entry.offset != offset) return error.OffsetNotFound;

        const start = floor_entry.position;
        const end = if (floor_idx + 1 < self.count_index)
            (try self.readIndexEntryAt(floor_idx + 1)).position
        else
            self.size;

        if (end < start) return error.CorruptIndex;

        const len = end - start;
        const out = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(out);

        _ = try self.file_log.preadAll(out, start);
        return out;
    }
};

test "append: simple" {
    const allocator = testing.allocator;

    const name = "simple_test";
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{name});
    defer allocator.free(log_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{name});
    defer allocator.free(idx_path);

    std.fs.cwd().deleteFile(log_path) catch {};
    std.fs.cwd().deleteFile(idx_path) catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile(idx_path) catch {};

    var segment = try Segment.init(allocator, name);
    defer segment.deinit();

    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;
    const frame = binary.buildFrame(&b1, 1, 0, 0, "k", "v", 1);
    const frame2 = binary.buildFrame(&b2, 1, 0, 0, "k", "v", 2);
    const frame3 = binary.buildFrame(&b3, 1, 0, 0, "k", "v", 3);
    const frame4 = binary.buildFrame(&b4, 1, 0, 0, "k", "v", 4);
    var data = [_][]const u8{ "", "", "", "" };
    data[0] = frame;
    data[1] = frame2;
    data[2] = frame3;
    data[3] = frame4;

    try segment.append(&data);
    try segment.sync();

    try testing.expectEqual(@as(u64, 4), segment.count_index);
    try testing.expectEqual(@as(u64, 1), segment.base_offset);
    try testing.expectEqual(@as(u64, 5), segment.next_offset);
}

test "readAt: binary seek exact offset" {
    const allocator = testing.allocator;

    const name = "readat_test";
    const log_path = try std.fmt.allocPrint(allocator, "{s}.log", .{name});
    defer allocator.free(log_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{name});
    defer allocator.free(idx_path);

    std.fs.cwd().deleteFile(log_path) catch {};
    std.fs.cwd().deleteFile(idx_path) catch {};
    defer std.fs.cwd().deleteFile(log_path) catch {};
    defer std.fs.cwd().deleteFile(idx_path) catch {};

    var segment = try Segment.init(allocator, name);
    defer segment.deinit();

    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;

    const frame1 = binary.buildFrame(&b1, 1, 0, 0, "k1", "v1", 0);
    const frame2 = binary.buildFrame(&b2, 1, 0, 0, "k2", "v2", 1);
    const frame3 = binary.buildFrame(&b3, 1, 0, 0, "k3", "v3", 2);
    const frame4 = binary.buildFrame(&b4, 1, 0, 0, "k4", "v4", 3);

    const data = [_][]const u8{ frame1, frame2, frame3, frame4 };
    try segment.append(&data);
    try segment.sync();

    const got10 = try segment.readAt(0);
    defer allocator.free(got10);
    try testing.expectEqualSlices(u8, frame1, got10);

    const got12 = try segment.readAt(2);
    defer allocator.free(got12);
    try testing.expectEqualSlices(u8, frame3, got12);

    const got13 = try segment.readAt(3);
    defer allocator.free(got13);
    try testing.expectEqualSlices(u8, frame4, got13);

    try testing.expectError(error.OffsetNotFound, segment.readAt(9));
    try testing.expectError(error.OffsetNotFound, segment.readAt(99));
    try testing.expectError(error.OffsetNotFound, segment.readAt(11 + 1000));
}
