const std = @import("std");
const pf = @import("portfolio.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test save
    const items = &[_]pf.Item{
        .{ .market = "sh", .code = "600519", .name = "贵州茅台" },
        .{ .market = "sz", .code = "000001", .name = "平安银行" },
    };
    try pf.save(allocator, items);
    std.debug.print("保存 portfolio 成功\n", .{});

    // Test load
    const loaded = try pf.load(allocator);
    defer {
        for (loaded) |item| {
            allocator.free(item.market);
            allocator.free(item.code);
            allocator.free(item.name);
        }
        allocator.free(loaded);
    }

    std.debug.print("加载 portfolio: {d} 条\n", .{loaded.len});
    for (loaded) |item| {
        std.debug.print("  {s} | {s} | {s}\n", .{ item.name, item.code, item.market });
    }
}
