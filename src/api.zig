const std = @import("std");

pub const SearchResult = struct {
    market: []const u8,
    code: []const u8,
    name: []const u8,
    pinyin: []const u8,
    kind: []const u8,
};

pub const PortfolioItem = struct {
    market: []const u8,
    code: []const u8,
    name: []const u8,
};

pub const Quote = struct {
    market: []const u8,
    code: []const u8,
    name: []const u8,
    price: f64,
    change_pct: f64,
    change_amt: f64,
};


/// Call curl to fetch URL and return response body as owned string.
fn fetchWithCurl(allocator: std.mem.Allocator, url: []const u8, max_time: u32) ![]u8 {
    const max_time_str = try std.fmt.allocPrint(allocator, "{d}", .{max_time});
    defer allocator.free(max_time_str);
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-s", "--max-time", max_time_str, url },
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CurlFailed;
    }

    return result.stdout;
}

/// Decode simple \uXXXX escape sequences in-place (ASCII source).
fn decodeUnicodeEscapes(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, input.len);
    errdefer allocator.free(output);

    var i: usize = 0;
    var o: usize = 0;
    while (i < input.len) {
        if (i + 6 <= input.len and input[i] == '\\' and input[i + 1] == 'u') {
            const hex = input[i + 2 .. i + 6];
            const codepoint = try std.fmt.parseInt(u21, hex, 16);
            const len = try std.unicode.utf8Encode(codepoint, output[o..]);
            o += len;
            i += 6;
        } else {
            output[o] = input[i];
            o += 1;
            i += 1;
        }
    }

    // shrink to actual size
    if (o < output.len) {
        output = try allocator.realloc(output, o);
    }
    return output;
}

fn isUrlSafeChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '~';
}

fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var count: usize = 0;
    for (input) |c| {
        if (isUrlSafeChar(c)) {
            count += 1;
        } else {
            count += 3;
        }
    }

    var output = try allocator.alloc(u8, count);
    var i: usize = 0;
    for (input) |c| {
        if (isUrlSafeChar(c)) {
            output[i] = c;
            i += 1;
        } else {
            output[i] = '%';
            _ = std.fmt.bufPrint(output[i + 1 ..], "{X:0>2}", .{c}) catch {};
            i += 3;
        }
    }
    return output;
}

/// Search stocks/funds using Tencent smartbox API.
/// Caller owns returned slice and all strings inside.
pub fn search(allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
    const encoded = try urlEncode(allocator, query);
    defer allocator.free(encoded);

    const url = try std.fmt.allocPrint(allocator, "https://smartbox.gtimg.cn/s3/?q={s}&t=all", .{encoded});
    defer allocator.free(url);

    const body = try fetchWithCurl(allocator, url, 5);
    defer allocator.free(body);

    // Format: v_hint="sh~600519~\u8d35\u5dde\u8305\u53f0~gzmt~GP-A^sz~000001~...";
    const prefix = "v_hint=\"";
    const start = std.mem.indexOf(u8, body, prefix) orelse return &[_]SearchResult{};
    const end = std.mem.indexOfPos(u8, body, start + prefix.len, "\";") orelse body.len;
    const content = body[start + prefix.len .. end];

    if (content.len == 0) return &[_]SearchResult{};

    // Count results
    var count: usize = 1;
    for (content) |c| {
        if (c == '^') count += 1;
    }

    var results = try allocator.alloc(SearchResult, count);
    errdefer allocator.free(results);

    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '^');
    while (iter.next()) |item| {
        if (item.len == 0) continue;

        var fields = std.mem.splitScalar(u8, item, '~');
        const market = fields.next() orelse continue;
        const code = fields.next() orelse continue;
        const raw_name = fields.next() orelse continue;
        const pinyin = fields.next() orelse continue;
        const kind = fields.next() orelse continue;

        const name = try decodeUnicodeEscapes(allocator, raw_name);
        errdefer allocator.free(name);

        results[idx] = .{
            .market = try allocator.dupe(u8, market),
            .code = try allocator.dupe(u8, code),
            .name = name,
            .pinyin = try allocator.dupe(u8, pinyin),
            .kind = try allocator.dupe(u8, kind),
        };
        idx += 1;
    }

    return allocator.realloc(results, idx);
}

/// Map tencent market to eastmoney secid prefix.
fn toEastMoneyMarket(market: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, market, "sh")) return "1";
    if (std.mem.eql(u8, market, "sz")) return "0";
    if (std.mem.eql(u8, market, "hk")) return "116";
    if (std.mem.eql(u8, market, "us")) return "105";
    return null;
}

/// Separate items into on-market (eastmoney) and off-market fund (ttjj).
fn categorizeItems(allocator: std.mem.Allocator, items: []const PortfolioItem) struct {
    em_ids: []const u8,
    em_items: []const PortfolioItem,
    jj_codes: []const u8,
    jj_items: []const PortfolioItem,
} {
    var em_buf = std.ArrayList(u8).empty;
    var em_items = std.ArrayList(PortfolioItem).empty;
    var jj_buf = std.ArrayList(u8).empty;
    var jj_items = std.ArrayList(PortfolioItem).empty;

    for (items) |item| {
        if (std.mem.eql(u8, item.market, "jj")) {
            if (jj_buf.items.len > 0) jj_buf.appendSlice(allocator, ",") catch {};
            jj_buf.appendSlice(allocator, item.code) catch {};
            jj_items.append(allocator, item) catch {};
        } else if (toEastMoneyMarket(item.market)) |prefix| {
            if (em_buf.items.len > 0) em_buf.appendSlice(allocator, ",") catch {};
            em_buf.appendSlice(allocator, prefix) catch {};
            em_buf.appendSlice(allocator, ".") catch {};
            em_buf.appendSlice(allocator, item.code) catch {};
            em_items.append(allocator, item) catch {};
        }
    }

    return .{
        .em_ids = em_buf.toOwnedSlice(allocator) catch "",
        .em_items = em_items.toOwnedSlice(allocator) catch &.{},
        .jj_codes = jj_buf.toOwnedSlice(allocator) catch "",
        .jj_items = jj_items.toOwnedSlice(allocator) catch &.{},
    };
}

/// Fetch quotes for given portfolio items.
/// Caller owns returned slice. Each quote's strings are individually allocated.
pub fn fetchQuotes(allocator: std.mem.Allocator, items: []const PortfolioItem) ![]Quote {
    if (items.len == 0) return &[_]Quote{};

    const cat = categorizeItems(allocator, items);
    defer allocator.free(cat.em_ids);
    defer allocator.free(cat.em_items);
    defer allocator.free(cat.jj_codes);
    defer allocator.free(cat.jj_items);

    var quotes = std.ArrayList(Quote).empty;
    errdefer {
        for (quotes.items) |q| {
            allocator.free(q.market);
            allocator.free(q.code);
            allocator.free(q.name);
        }
        quotes.deinit(allocator);
    }

    // Fetch on-market quotes from EastMoney
    if (cat.em_ids.len > 0) {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&invt=2&fields=f12,f13,f14,f2,f3,f4&secids={s}",
            .{cat.em_ids},
        );
        defer allocator.free(url);

        var body: []u8 = &[_]u8{};
        if (fetchWithCurl(allocator, url, 8)) |fetched| {
            body = fetched;
        } else |e| {
            std.log.warn("Failed to fetch on-market quotes: {s}", .{@errorName(e)});
        }
        if (body.len > 0) {
            defer allocator.free(body);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
            defer parsed.deinit();

            const data = parsed.value.object.get("data") orelse return error.InvalidResponse;
            const diff = data.object.get("diff") orelse return error.InvalidResponse;
            const arr = diff.array;

            for (arr.items) |item| {
                const obj = item.object;
                const code = obj.get("f12") orelse continue;
                const raw_name = obj.get("f14") orelse continue;
                const price = obj.get("f2") orelse continue;
                const change_pct = obj.get("f3") orelse continue;
                const change_amt = obj.get("f4") orelse continue;

                // Find original market from code
                var market_str: []const u8 = "sh";
                for (cat.em_items) |orig| {
                    if (std.mem.eql(u8, orig.code, code.string)) {
                        market_str = orig.market;
                        break;
                    }
                }

                try quotes.append(allocator, .{
                    .market = try allocator.dupe(u8, market_str),
                    .code = try allocator.dupe(u8, code.string),
                    .name = try allocator.dupe(u8, raw_name.string),
                    .price = if (price == .float) price.float else if (price == .integer) @floatFromInt(price.integer) else 0,
                    .change_pct = if (change_pct == .float) change_pct.float else if (change_pct == .integer) @floatFromInt(change_pct.integer) else 0,
                    .change_amt = if (change_amt == .float) change_amt.float else if (change_amt == .integer) @floatFromInt(change_amt.integer) else 0,
                });
            }
        }
    }

    // Fetch off-market fund quotes from Tiantian Fund
    if (cat.jj_codes.len > 0) {
        const url = try std.fmt.allocPrint(
            allocator,
            "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo?pageIndex=1&pageSize=20&appType=ttjj&product=EFund&plat=Android&deviceid=abc&Version=1&Fcodes={s}",
            .{cat.jj_codes},
        );
        defer allocator.free(url);

        var body2: []u8 = &[_]u8{};
        if (fetchWithCurl(allocator, url, 8)) |fetched| {
            body2 = fetched;
        } else |e| {
            std.log.warn("Failed to fetch fund quotes: {s}", .{@errorName(e)});
        }
        if (body2.len > 0) {
            defer allocator.free(body2);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body2, .{});
            defer parsed.deinit();

            const datas = parsed.value.object.get("Datas") orelse return error.InvalidResponse;
            const arr = datas.array;

            for (arr.items) |item| {
                const obj = item.object;
                const fcode = obj.get("FCODE") orelse continue;
                const shortname = obj.get("SHORTNAME") orelse continue;
                const nav = obj.get("NAV") orelse continue;
                const navchgrt = obj.get("NAVCHGRT") orelse continue;

                const nav_f = std.fmt.parseFloat(f64, nav.string) catch 0;
                const chg_f = std.fmt.parseFloat(f64, navchgrt.string) catch 0;
                const chg_amt = nav_f * chg_f / 100.0;

                try quotes.append(allocator, .{
                    .market = try allocator.dupe(u8, "jj"),
                    .code = try allocator.dupe(u8, fcode.string),
                    .name = try allocator.dupe(u8, shortname.string),
                    .price = nav_f,
                    .change_pct = chg_f,
                    .change_amt = chg_amt,
                });
            }
        }
    }

    return quotes.toOwnedSlice(allocator);
}

test "decode unicode escapes" {
    const allocator = std.testing.allocator;
    const decoded = try decodeUnicodeEscapes(allocator, "\\u8d35\\u5dde\\u8305\\u53f0");
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("贵州茅台", decoded);
}
