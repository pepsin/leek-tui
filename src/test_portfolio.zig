const std = @import("std");
const pf = @import("portfolio.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test save
    var portfolio = try allocator.alloc(pf.Item, 2);
    portfolio[0] = .{ .market = "sh", .code = "600519", .name = "贵州茅台" };
    portfolio[1] = .{ .market = "sz", .code = "000001", .name = "平安银行" };

    const config = pf.Config{
        .portfolio = portfolio,
        .refresh_interval = 10,
    };
    try pf.save(allocator, config);
    allocator.free(portfolio);
    std.debug.print("保存 config 成功\n", .{});

    // Test load
    var loaded = try pf.load(allocator);
    defer loaded.deinit(allocator);

    std.debug.print("加载 config: portfolio={d} 条, refresh_interval={d}\n", .{ loaded.portfolio.len, loaded.refresh_interval });
    for (loaded.portfolio) |item| {
        std.debug.print("  {s} | {s} | {s}\n", .{ item.name, item.code, item.market });
    }
}
