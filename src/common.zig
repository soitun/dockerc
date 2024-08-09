const std = @import("std");

const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

pub fn mkdtemp(in: []u8) !void {
    try std.posix.getrandom(in[in.len - 6 ..]);
    for (in[in.len - 6 ..]) |*v| {
        v.* = letters[v.* % letters.len];
    }

    try std.posix.mkdir(in, 0o700);
}

// TODO: ideally we can use memfd_create
// The problem is that zig doesn't have fexecve support by default so it would
// be a pain to find the location of the file.
pub fn extract_file(tmpDir: []const u8, name: []const u8, data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmpDir, name });

    const file = try std.fs.createFileAbsolute(path, .{ .mode = 0o700 });
    defer file.close();
    try file.writeAll(data);

    return path;
}

pub fn getOffset(path: []const u8) !u64 {
    var file = try std.fs.cwd().openFile(path, .{});
    try file.seekFromEnd(-8);

    var buffer: [8]u8 = undefined;
    std.debug.assert(try file.readAll(&buffer) == 8);

    return std.mem.readInt(u64, buffer[0..8], std.builtin.Endian.big);
}
