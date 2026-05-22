const std = @import("std");
const api = @import("api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const results = try api.search(allocator, "茅台");
    defer {
        for (results) |r| {
            allocator.free(r.market);
            allocator.free(r.code);
            allocator.free(r.name);
            allocator.free(r.pinyin);
            allocator.free(r.kind);
        }
        allocator.free(results);
    }

    std.debug.print("搜索 '茅台' 找到 {d} 个结果:\n", .{results.len});
    for (results) |r| {
        std.debug.print("  {s} | {s} | {s} | {s} | {s}\n", .{ r.name, r.code, r.market, r.kind, r.pinyin });
    }
}
