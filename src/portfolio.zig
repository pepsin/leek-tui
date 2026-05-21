const std = @import("std");
const api = @import("api.zig");

pub const Item = api.PortfolioItem;

fn getConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return allocator.dupe(u8, ".");
    };
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config", "leek-tui" });
}

fn ensureDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| {
        if (e != error.PathAlreadyExists) return e;
    };
}

pub fn load(allocator: std.mem.Allocator) ![]Item {
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, "portfolio.json" });
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |e| {
        if (e == error.FileNotFound) return &[_]Item{};
        return e;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice([]Item, allocator, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var items = try allocator.alloc(Item, parsed.value.len);
    for (parsed.value, 0..) |src, i| {
        items[i] = .{
            .market = try allocator.dupe(u8, src.market),
            .code = try allocator.dupe(u8, src.code),
            .name = try allocator.dupe(u8, src.name),
        };
    }
    return items;
}

pub fn save(allocator: std.mem.Allocator, items: []const Item) !void {
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    try ensureDir(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, "portfolio.json" });
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, items, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);
    try file.writeAll(json_bytes);
    try file.writeAll("\n");
}
