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

fn setMessage(state: *tui.AppState, allocator: std.mem.Allocator, msg: []const u8) void {
    allocator.free(state.message);
    state.message = msg;
}

fn refreshQuotes(state: *tui.AppState, allocator: std.mem.Allocator) !void {
    if (state.portfolio.len == 0) {
        freeQuotes(state.quotes, allocator);
        state.quotes = try allocator.alloc(api.Quote, 0);
        state.last_update = std.time.timestamp();
        return;
    }

    const new_quotes = api.fetchQuotes(allocator, state.portfolio) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "刷新失败: {s}", .{@errorName(e)}) catch return;
        setMessage(state, allocator, msg);
        return;
    };

    // Only replace if we got valid data; keep old quotes otherwise
    if (new_quotes.len > 0) {
        freeQuotes(state.quotes, allocator);
        state.quotes = new_quotes;
        state.last_update = std.time.timestamp();
    } else {
        // Got empty result but no error — free it and keep old data
        allocator.free(new_quotes);
        state.last_update = std.time.timestamp();
    }
}

fn performSearch(state: *tui.AppState, allocator: std.mem.Allocator) !void {
    if (state.search_query.len == 0) {
        freeSearchResults(state.search_results, allocator);
        state.search_results = try allocator.alloc(api.SearchResult, 0);
        return;
    }

    const results = api.search(allocator, state.search_query) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "搜索失败: {s}", .{@errorName(e)}) catch return;
        setMessage(state, allocator, msg);
        return;
    };

    freeSearchResults(state.search_results, allocator);
    state.search_results = results;
    if (state.search_selected >= state.search_results.len) {
        state.search_selected = 0;
    }
}

fn addSelected(state: *tui.AppState, allocator: std.mem.Allocator, config: *pf.Config) !void {
    if (state.search_results.len == 0) return;
    const sel = state.search_results[state.search_selected];

    // Check duplicate
    for (state.portfolio) |item| {
        if (std.mem.eql(u8, item.code, sel.code) and std.mem.eql(u8, item.market, sel.market)) {
            const msg = try std.fmt.allocPrint(allocator, "已存在: {s}", .{sel.name});
            setMessage(state, allocator, msg);
            return;
        }
    }

    const new_item = pf.Item{
        .market = try allocator.dupe(u8, sel.market),
        .code = try allocator.dupe(u8, sel.code),
        .name = try allocator.dupe(u8, sel.name),
    };
    errdefer {
        allocator.free(new_item.market);
        allocator.free(new_item.code);
        allocator.free(new_item.name);
    }

    const new_portfolio = try allocator.realloc(config.portfolio, config.portfolio.len + 1);
    new_portfolio[new_portfolio.len - 1] = new_item;
    config.portfolio = new_portfolio;

    state.portfolio = config.portfolio;
    const msg = try std.fmt.allocPrint(allocator, "已添加: {s}", .{sel.name});
    setMessage(state, allocator, msg);

    // Save immediately
    pf.save(allocator, config.*) catch {};

    // Refresh quotes immediately
    try refreshQuotes(state, allocator);
}

fn deleteSelected(state: *tui.AppState, allocator: std.mem.Allocator, config: *pf.Config) !void {
    if (state.portfolio.len == 0 or state.selected >= state.portfolio.len) return;

    const deleted = state.portfolio[state.selected];
    const name = try allocator.dupe(u8, deleted.name);
    defer allocator.free(name);

    // Free deleted item strings
    allocator.free(deleted.market);
    allocator.free(deleted.code);
    allocator.free(deleted.name);

    // Remove from array
    const items = config.portfolio;
    for (state.selected..items.len - 1) |i| {
        items[i] = items[i + 1];
    }
    const new_portfolio = try allocator.realloc(items, items.len - 1);
    config.portfolio = new_portfolio;

    state.portfolio = config.portfolio;
    if (state.selected >= state.portfolio.len and state.portfolio.len > 0) {
        state.selected = state.portfolio.len - 1;
    }

    const msg = try std.fmt.allocPrint(allocator, "已删除: {s}", .{name});
    setMessage(state, allocator, msg);

    // Save immediately
    pf.save(allocator, config.*) catch {};

    // Refresh quotes
    try refreshQuotes(state, allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
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
        .quotes = try allocator.alloc(api.Quote, 0),
        .portfolio = config.portfolio,
        .selected = 0,
        .search_query = try allocator.alloc(u8, 0),
        .search_results = try allocator.alloc(api.SearchResult, 0),
        .search_selected = 0,
        .message = try allocator.alloc(u8, 0),
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

    // Initial data fetch
    try refreshQuotes(&state, allocator);
    var last_refresh: i64 = std.time.timestamp();
    var search_dirty = false;
    var search_debounce: u32 = 0;

    while (state.running) {
        const event = tui.readEvent(state.mode) catch tui.Event.none;

        if (event != .none) {
            switch (state.mode) {
                .normal => switch (event) {
                    .quit => state.running = false,
                    .add_mode => {
                        state.mode = .search;
                        allocator.free(state.search_query);
                        state.search_query = try allocator.alloc(u8, 0);
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
                        state.search_results = try allocator.alloc(api.SearchResult, 0);
                        search_dirty = false;
                    },
                    .select => {
                        try addSelected(&state, allocator, &config);
                        state.mode = .normal;
                        freeSearchResults(state.search_results, allocator);
                        state.search_results = try allocator.alloc(api.SearchResult, 0);
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
                        try deleteSelected(&state, allocator, &config);
                        state.mode = .normal;
                    },
                    .char => |c| {
                        if (c == 'y' or c == 'Y') {
                            try deleteSelected(&state, allocator, &config);
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
