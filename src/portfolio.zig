const std = @import("std");
const api = @import("api.zig");

pub const Item = api.PortfolioItem;

pub const Config = struct {
    portfolio: []Item = &[_]Item{},
    refresh_interval: i64 = 5,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.portfolio) |item| {
            allocator.free(item.market);
            allocator.free(item.code);
            allocator.free(item.name);
        }
        allocator.free(self.portfolio);
    }
};

fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return allocator.dupe(u8, ".leek_tui.json");
    };
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".leek_tui.json" });
}

fn migrateFromOld(allocator: std.mem.Allocator) !?[]Item {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);

    const old_path = try std.fs.path.join(allocator, &.{ home, ".config", "leek-tui", "portfolio.json" });
    defer allocator.free(old_path);

    const data = std.fs.cwd().readFileAlloc(allocator, old_path, 1024 * 1024) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice([]Item, allocator, data, .{});
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

pub fn load(allocator: std.mem.Allocator) !Config {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |e| {
        if (e == error.FileNotFound) {
            if (try migrateFromOld(allocator)) |items| {
                return Config{ .portfolio = items };
            }
            return Config{};
        }
        return e;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Config, allocator, data, .{});
    defer parsed.deinit();

    // Deep copy portfolio since parsed will be deinit
    var items = try allocator.alloc(Item, parsed.value.portfolio.len);
    for (parsed.value.portfolio, 0..) |src, i| {
        items[i] = .{
            .market = try allocator.dupe(u8, src.market),
            .code = try allocator.dupe(u8, src.code),
            .name = try allocator.dupe(u8, src.name),
        };
    }

    return Config{
        .portfolio = items,
        .refresh_interval = parsed.value.refresh_interval,
    };
}

pub fn save(allocator: std.mem.Allocator, config: Config) !void {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    const json_bytes = try std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);
    try file.writeAll(json_bytes);
    try file.writeAll("\n");
}
