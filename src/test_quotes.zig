const std = @import("std");
const api = @import("api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test fetchQuotes with a single stock
    const items = &[_]api.PortfolioItem{
        .{ .market = "sh", .code = "600519", .name = "贵州茅台" },
    };

    const quotes = try api.fetchQuotes(allocator, items);
    defer {
        for (quotes) |q| {
            allocator.free(q.market);
            allocator.free(q.code);
            allocator.free(q.name);
        }
        allocator.free(quotes);
    }

    std.debug.print("获取 {d} 条报价:\n", .{quotes.len});
    for (quotes) |q| {
        std.debug.print("  {s}({s}) | 价格: {d:.2} | 涨跌: {d:.2}% | 涨跌额: {d:.2}\n", .{ q.name, q.code, q.price, q.change_pct, q.change_amt });
    }
}
