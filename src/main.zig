const std = @import("std");
const api = @import("api.zig");
const pf = @import("portfolio.zig");
const tui = @import("tui.zig");

fn freeQuotes(quotes: []const api.Quote, allocator: std.mem.Allocator) void {
    for (quotes) |q| {
        allocator.free(q.market);
        allocator.free(q.code);
        allocator.free(q.name);
    }
    allocator.free(quotes);
}

fn freeSearchResults(results: []const api.SearchResult, allocator: std.mem.Allocator) void {
    for (results) |r| {
        allocator.free(r.market);
        allocator.free(r.code);
        allocator.free(r.name);
        allocator.free(r.pinyin);
        allocator.free(r.kind);
    }
    allocator.free(results);
}

fn refreshQuotes(state: *tui.AppState, allocator: std.mem.Allocator) !void {
    if (state.portfolio.len == 0) {
        state.quotes = &.{};
        state.last_update = std.time.timestamp();
        return;
    }

    const new_quotes = api.fetchQuotes(allocator, state.portfolio) catch |e| {
        state.message = try std.fmt.allocPrint(allocator, "刷新失败: {s}", .{@errorName(e)});
        return;
    };

    freeQuotes(state.quotes, allocator);
    state.quotes = new_quotes;
    state.last_update = std.time.timestamp();
}

fn performSearch(state: *tui.AppState, allocator: std.mem.Allocator) !void {
    if (state.search_query.len == 0) {
        freeSearchResults(state.search_results, allocator);
        state.search_results = &.{};
        return;
    }

    const results = api.search(allocator, state.search_query) catch |e| {
        state.message = try std.fmt.allocPrint(allocator, "搜索失败: {s}", .{@errorName(e)});
        return;
    };

    freeSearchResults(state.search_results, allocator);
    state.search_results = results;
    if (state.search_selected >= state.search_results.len) {
        state.search_selected = 0;
    }
}

fn addSelected(state: *tui.AppState, allocator: std.mem.Allocator, portfolio_items: *[]pf.Item) !void {
    if (state.search_results.len == 0) return;
    const sel = state.search_results[state.search_selected];

    // Check duplicate
    for (state.portfolio) |item| {
        if (std.mem.eql(u8, item.code, sel.code) and std.mem.eql(u8, item.market, sel.market)) {
            state.message = try std.fmt.allocPrint(allocator, "已存在: {s}", .{sel.name});
            return;
        }
    }

    const new_item = pf.Item{
        .market = try allocator.dupe(u8, sel.market),
        .code = try allocator.dupe(u8, sel.code),
        .name = try allocator.dupe(u8, sel.name),
    };

    const new_portfolio = try allocator.realloc(portfolio_items.*, portfolio_items.*.len + 1);
    new_portfolio[new_portfolio.len - 1] = new_item;
    portfolio_items.* = new_portfolio;

    state.portfolio = portfolio_items.*;
    state.message = try std.fmt.allocPrint(allocator, "已添加: {s}", .{sel.name});

    // Refresh quotes immediately
    try refreshQuotes(state, allocator);
}

fn deleteSelected(state: *tui.AppState, allocator: std.mem.Allocator, portfolio_items: *[]pf.Item) !void {
    if (state.portfolio.len == 0 or state.selected >= state.portfolio.len) return;

    const deleted = state.portfolio[state.selected];
    const name = try allocator.dupe(u8, deleted.name);
    defer allocator.free(name);

    // Free deleted item strings
    allocator.free(deleted.market);
    allocator.free(deleted.code);
    allocator.free(deleted.name);

    // Remove from array
    const items = portfolio_items.*;
    for (state.selected..items.len - 1) |i| {
        items[i] = items[i + 1];
    }
    const new_portfolio = try allocator.realloc(items, items.len - 1);
    portfolio_items.* = new_portfolio;

    state.portfolio = portfolio_items.*;
    if (state.selected >= state.portfolio.len and state.portfolio.len > 0) {
        state.selected = state.portfolio.len - 1;
    }

    state.message = try std.fmt.allocPrint(allocator, "已删除: {s}", .{name});

    // Refresh quotes
    try refreshQuotes(state, allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load config
    var config = try pf.load(allocator);
    defer config.deinit(allocator);

    // Init TUI
    try tui.init();
    defer tui.deinit();

    var state = tui.AppState{
        .mode = .normal,
        .quotes = &.{},
        .portfolio = config.portfolio,
        .selected = 0,
        .search_query = "",
        .search_results = &.{},
        .search_selected = 0,
        .message = "",
        .last_update = 0,
        .running = true,
        .need_refresh = true,
    };
    defer {
        freeQuotes(state.quotes, allocator);
        freeSearchResults(state.search_results, allocator);
        allocator.free(state.search_query);
        allocator.free(state.message);
    }

    var last_refresh: i64 = 0;
    var search_dirty = false;
    var search_debounce: u32 = 0;

    // Initial data fetch
    try refreshQuotes(&state, allocator);

    while (state.running) {
        const event = tui.readEvent() catch tui.Event.none;

        if (event != .none) {
            switch (state.mode) {
                .normal => switch (event) {
                    .quit => state.running = false,
                    .add_mode => {
                        state.mode = .search;
                        allocator.free(state.search_query);
                        state.search_query = "";
                        search_dirty = false;
                        search_debounce = 0;
                    },
                    .delete_item => {
                        if (state.portfolio.len > 0) {
                            state.mode = .confirm_delete;
                        }
                    },
                    .up => {
                        if (state.selected > 0) state.selected -= 1;
                    },
                    .down => {
                        if (state.selected + 1 < state.portfolio.len) state.selected += 1;
                    },
                    else => {},
                },
                .search => switch (event) {
                    .cancel => {
                        state.mode = .normal;
                        freeSearchResults(state.search_results, allocator);
                        state.search_results = &.{};
                        search_dirty = false;
                    },
                    .select => {
                        try addSelected(&state, allocator, &config.portfolio);
                        state.mode = .normal;
                        freeSearchResults(state.search_results, allocator);
                        state.search_results = &.{};
                        search_dirty = false;
                    },
                    .up => {
                        if (state.search_selected > 0) state.search_selected -= 1;
                    },
                    .down => {
                        if (state.search_selected + 1 < state.search_results.len) {
                            state.search_selected += 1;
                        }
                    },
                    .backspace => {
                        if (state.search_query.len > 0) {
                            var idx = state.search_query.len - 1;
                            while (idx > 0 and (state.search_query[idx] & 0xC0) == 0x80) {
                                idx -= 1;
                            }
                            const new_query = try allocator.alloc(u8, idx);
                            @memcpy(new_query, state.search_query[0..idx]);
                            allocator.free(state.search_query);
                            state.search_query = new_query;
                            search_dirty = true;
                            search_debounce = 0;
                        }
                    },
                    .char => |c| {
                        const new_query = try allocator.alloc(u8, state.search_query.len + 1);
                        @memcpy(new_query[0..state.search_query.len], state.search_query);
                        new_query[state.search_query.len] = c;
                        allocator.free(state.search_query);
                        state.search_query = new_query;
                        search_dirty = true;
                        search_debounce = 0;
                    },
                    else => {},
                },
                .confirm_delete => switch (event) {
                    .select => {
                        try deleteSelected(&state, allocator, &config.portfolio);
                        state.mode = .normal;
                    },
                    .char => |c| {
                        if (c == 'y' or c == 'Y') {
                            try deleteSelected(&state, allocator, &config.portfolio);
                        }
                        state.mode = .normal;
                    },
                    .cancel => state.mode = .normal,
                    else => {},
                },
            }
        }

        // Debounced search
        if (search_dirty) {
            search_debounce += 1;
            if (search_debounce >= 10) { // ~300ms
                try performSearch(&state, allocator);
                search_dirty = false;
                search_debounce = 0;
            }
        }

        // Periodic refresh
        const now = std.time.timestamp();
        if (now - last_refresh >= config.refresh_interval) {
            try refreshQuotes(&state, allocator);
            last_refresh = now;
        }

        try tui.render(&state);
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Save config on exit
    try pf.save(allocator, config);
}
