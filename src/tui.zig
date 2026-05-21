const std = @import("std");
const api = @import("api.zig");

pub const Mode = enum {
    normal,
    search,
    confirm_delete,
};

pub const Event = union(enum) {
    quit,
    up,
    down,
    select,
    cancel,
    add_mode,
    delete_item,
    backspace,
    char: u8,
    resize,
    none,
};

pub const AppState = struct {
    mode: Mode,
    quotes: []const api.Quote,
    portfolio: []const api.PortfolioItem,
    selected: usize,
    search_query: []const u8,
    search_results: []const api.SearchResult,
    search_selected: usize,
    message: []const u8,
    last_update: i64,
    running: bool,
    need_refresh: bool,
};

var original_termios: ?std.posix.termios = null;
var stdout_writer: std.fs.File.DeprecatedWriter = undefined;

pub fn init() !void {
    stdout_writer = std.fs.File.stdout().deprecatedWriter();

    // Save original termios
    const term = try std.posix.tcgetattr(std.fs.File.stdin().handle);
    original_termios = term;

    // Set raw-like mode
    var raw = term;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.fs.File.stdin().handle, .NOW, raw);

    // Hide cursor, clear screen
    try writeAll("\x1b[?25l\x1b[2J\x1b[H");
}

pub fn deinit() void {
    // Show cursor, reset colors
    writeAll("\x1b[?25h\x1b[0m\x1b[2J\x1b[H") catch {};

    if (original_termios) |term| {
        std.posix.tcsetattr(std.fs.File.stdin().handle, .NOW, term) catch {};
    }
}

fn writeAll(bytes: []const u8) !void {
    try stdout_writer.writeAll(bytes);
}

const Size = struct { rows: u16, cols: u16 };

fn getTerminalSize() !Size {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        std.fs.File.stdout().handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&ws),
    );
    if (rc != 0) return error.IoctlFailed;
    return .{ .rows = ws.row, .cols = ws.col };
}

fn moveCursor(row: u16, col: u16) !void {
    try stdout_writer.print("\x1b[{d};{d}H", .{ row, col });
}

fn clearLine() !void {
    try writeAll("\x1b[2K");
}

fn setColor(color: []const u8) !void {
    try writeAll(color);
}

const RESET = "\x1b[0m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const BOLD = "\x1b[1m";
const REVERSE = "\x1b[7m";
const DIM = "\x1b[2m";

fn writePadded(text: []const u8, width: usize) !void {
    const display_width = displayWidth(text);
    if (display_width > width) {
        var written: usize = 0;
        var byte_idx: usize = 0;
        while (byte_idx < text.len and written < width - 1) {
            const len = std.unicode.utf8ByteSequenceLength(text[byte_idx]) catch 1;
            try stdout_writer.writeAll(text[byte_idx..byte_idx + len]);
            written += 1;
            byte_idx += len;
        }
        try writeAll("…");
    } else {
        try stdout_writer.writeAll(text);
        var i = display_width;
        while (i < width) : (i += 1) {
            try writeAll(" ");
        }
    }
}

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            width += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..i + len]) catch 0;
        // CJK characters are roughly double-width
        if (cp >= 0x4E00 and cp <= 0x9FFF or cp >= 0x3400 and cp <= 0x4DBF or cp >= 0x3000 and cp <= 0x303F) {
            width += 2;
        } else {
            width += 1;
        }
        i += len;
    }
    return width;
}

fn fmtPrice(buf: []u8, price: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.2}", .{price}) catch "N/A";
}

fn fmtChangePct(buf: []u8, pct: f64) []const u8 {
    if (pct >= 0) {
        return std.fmt.bufPrint(buf, "+{d:.2}%", .{pct}) catch "N/A";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}%", .{pct}) catch "N/A";
    }
}

fn fmtChangeAmt(buf: []u8, amt: f64) []const u8 {
    if (amt >= 0) {
        return std.fmt.bufPrint(buf, "+{d:.2}", .{amt}) catch "N/A";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2}", .{amt}) catch "N/A";
    }
}

pub fn render(state: *const AppState) !void {
    const size = getTerminalSize() catch Size{ .rows = 24, .cols = 80 };
    const rows = size.rows;
    const cols = size.cols;

    // Clear screen
    try writeAll("\x1b[2J\x1b[H");

    // Title bar
    try setColor(BOLD ++ CYAN);
    try writeAll("  韭菜盒子 leek-tui  ─  实时行情");
    try setColor(DIM);
    const time_buf = try std.fmt.allocPrint(std.heap.page_allocator, "  更新: {d}", .{state.last_update});
    defer std.heap.page_allocator.free(time_buf);
    try stdout_writer.writeAll(time_buf);
    try setColor(RESET);

    // Header line
    try moveCursor(3, 1);
    try setColor(BOLD);
    try writePadded("名称", 16);
    try writePadded("代码", 12);
    try writePadded("现价", 12);
    try writePadded("涨跌幅", 12);
    try writePadded("涨跌额", 12);
    try writeAll(RESET);

    // Separator
    try moveCursor(4, 1);
    try setColor(DIM);
    var sep_i: usize = 0;
    while (sep_i < cols) : (sep_i += 1) {
        try writeAll("─");
    }
    try writeAll(RESET);

    // Quote list
    if (rows < 10 or cols < 40) {
        try moveCursor(1, 1);
        try writeAll("Terminal too small");
        return;
    }

    const list_start_row = 5;
    const max_list_rows = rows - 8;

    if (state.quotes.len == 0) {
        try moveCursor(list_start_row, 3);
        try setColor(DIM);
        try writeAll("暂无关注股票/基金，按 a 添加");
        try writeAll(RESET);
    } else {
        const start_idx = if (state.selected >= max_list_rows) state.selected - max_list_rows + 1 else 0;
        const end_idx = @min(start_idx + max_list_rows, state.quotes.len);

        var row: u16 = list_start_row;
        var i = start_idx;
        while (i < end_idx) : (i += 1) {
            const q = state.quotes[i];
            try moveCursor(@intCast(row), 1);

            if (i == state.selected and state.mode == .normal) {
                try setColor(REVERSE);
            }

            var price_buf: [32]u8 = undefined;
            var pct_buf: [32]u8 = undefined;
            var amt_buf: [32]u8 = undefined;

            // Color based on change
            const color = if (q.change_pct > 0) RED else if (q.change_pct < 0) GREEN else "";

            try writePadded(q.name, 16);
            try setColor(DIM);
            try writePadded(q.code, 12);
            try setColor(RESET);

            if (i == state.selected and state.mode == .normal) {
                try setColor(REVERSE);
            }
            try setColor(color);
            try writePadded(fmtPrice(&price_buf, q.price), 12);
            try writePadded(fmtChangePct(&pct_buf, q.change_pct), 12);
            try writePadded(fmtChangeAmt(&amt_buf, q.change_amt), 12);
            try setColor(RESET);

            row += 1;
        }
    }

    // Search overlay
    if (state.mode == .search) {
        const box_row = @max(1, @divTrunc(rows, 2)) -| 6;
        const box_col = @max(1, @divTrunc(cols, 2)) -| 25;
        const box_width = 50;

        // Draw box border
        try moveCursor(box_row, box_col);
        try setColor(BOLD ++ CYAN);
        try writeAll("┌");
        var b: usize = 0;
        while (b < box_width - 2) : (b += 1) try writeAll("─");
        try writeAll("┐");

        try moveCursor(box_row + 1, box_col);
        try writeAll("│  添加股票/基金");
        try moveCursor(box_row + 1, box_col + box_width - 1);
        try writeAll("│");

        try moveCursor(box_row + 2, box_col);
        try writeAll("├");
        b = 0;
        while (b < box_width - 2) : (b += 1) try writeAll("─");
        try writeAll("┤");

        // Search input
        try moveCursor(box_row + 3, box_col);
        try writeAll("│  > ");
        try setColor(RESET);
        try stdout_writer.writeAll(state.search_query);
        // Clear rest of line
        const query_width = displayWidth(state.search_query);
        var clear_i = 5 + query_width;
        while (clear_i < box_width - 1) : (clear_i += 1) try writeAll(" ");
        try moveCursor(box_row + 3, box_col + box_width - 1);
        try setColor(BOLD ++ CYAN);
        try writeAll("│");

        // Results area
        try moveCursor(box_row + 4, box_col);
        try writeAll("│");
        clear_i = 1;
        while (clear_i < box_width - 1) : (clear_i += 1) try writeAll(" ");
        try moveCursor(box_row + 4, box_col + box_width - 1);
        try writeAll("│");

        const result_start_row = box_row + 5;
        const max_results = 5;
        var r: usize = 0;
        while (r < max_results) : (r += 1) {
            try moveCursor(@intCast(result_start_row + r), box_col);
            if (r < state.search_results.len) {
                const sr = state.search_results[r];
                if (r == state.search_selected) {
                    try setColor(REVERSE);
                } else {
                    try setColor(RESET);
                }
                try writeAll("│  ");
                try writePadded(sr.name, 16);
                try writePadded(sr.code, 10);
                try writePadded(sr.kind, 8);
                try writePadded(sr.market, 6);
                // Clear rest
                const used = 3 + 16 + 10 + 8 + 6;
                var c: usize = used;
                while (c < box_width - 1) : (c += 1) try writeAll(" ");
                try setColor(BOLD ++ CYAN);
                try writeAll("│");
            } else {
                try setColor(RESET);
                try writeAll("│");
                clear_i = 1;
                while (clear_i < box_width - 1) : (clear_i += 1) try writeAll(" ");
                try setColor(BOLD ++ CYAN);
                try writeAll("│");
            }
        }

        try moveCursor(@intCast(result_start_row + max_results), box_col);
        try writeAll("└");
        b = 0;
        while (b < box_width - 2) : (b += 1) try writeAll("─");
        try writeAll("┘");
        try setColor(RESET);
    }

    // Confirm delete overlay
    if (state.mode == .confirm_delete and state.portfolio.len > 0) {
        const box_row = @max(1, @divTrunc(rows, 2)) -| 2;
        const box_col = @divTrunc(cols, 2) - 20;
        try moveCursor(box_row, box_col);
        try setColor(BOLD ++ YELLOW);
        try writeAll("┌────────────────────────────────────────┐");
        try moveCursor(box_row + 1, box_col);
        const item = state.portfolio[state.selected];
        try writeAll("│  确认删除: ");
        try setColor(RESET);
        try stdout_writer.print("{s}({s})", .{ item.name, item.code });
        try setColor(BOLD ++ YELLOW);
        try writeAll("?      │");
        try moveCursor(box_row + 2, box_col);
        try writeAll("│  [Y] 确认    [N] 取消                 │");
        try moveCursor(box_row + 3, box_col);
        try writeAll("└────────────────────────────────────────┘");
        try setColor(RESET);
    }

    // Bottom status bar
    const status_row = rows -| 1;
    try moveCursor(status_row, 1);
    try setColor(DIM);
    try clearLine();
    try moveCursor(status_row, 1);
    switch (state.mode) {
        .normal => try writeAll("[a]添加 [d]删除 [↑/↓]选择 [q]退出"),
        .search => try writeAll("[↑/↓]选择 [Enter]确认 [Esc]取消 [Backspace]删除"),
        .confirm_delete => try writeAll("[Y]确认 [N]取消"),
    }
    try writeAll(RESET);

    // Message line
    if (state.message.len > 0 and rows >= 2) {
        try moveCursor(rows -| 2, 1);
        try setColor(YELLOW);
        try stdout_writer.writeAll(state.message);
        try writeAll(RESET);
    }

    // flush not needed for stdout
}

pub fn readEvent() !Event {
    const stdin = std.fs.File.stdin().handle;

    var c: u8 = undefined;
    const n = std.posix.read(stdin, std.mem.asBytes(&c)) catch return Event.none;
    if (n == 0) return Event.none;

    // Handle escape sequences
    if (c == '\x1b') {
        // Try to read '[' and the final char (non-blocking)
        var seq: [2]u8 = undefined;
        const n2 = std.posix.read(stdin, &seq) catch 0;
        if (n2 >= 2 and seq[0] == '[') {
            switch (seq[1]) {
                'A' => return Event.up,
                'B' => return Event.down,
                'C' => return Event.none,
                'D' => return Event.none,
                else => return Event.none,
            }
        }
        return Event.cancel; // ESC
    }

    // Single characters
    switch (c) {
        'q', 'Q' => return Event.quit,
        'a', 'A' => return Event.add_mode,
        'd', 'D' => return Event.delete_item,
        'j', 'J' => return Event.down,
        'k', 'K' => return Event.up,
        '\r', '\n' => return Event.select,
        '\x7f', '\x08' => return Event.backspace, // backspace / del
        else => return Event{ .char = c },
    }
}
