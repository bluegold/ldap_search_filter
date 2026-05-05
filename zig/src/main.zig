const std = @import("std");

const Allocator = std.mem.Allocator;
const Managed = std.array_list.Managed;

const Format = enum {
    auto,
    csv,
    ltsv,
};

const Entry = struct {
    key: []const u8,
    value: ?[]const u8,
};

const OrderedAttrs = struct {
    entries: Managed(Entry),

    fn init(allocator: Allocator) OrderedAttrs {
        return .{ .entries = Managed(Entry).init(allocator) };
    }

    fn deinit(self: *OrderedAttrs) void {
        self.entries.deinit();
    }

    fn add(self: *OrderedAttrs, key: []const u8, value: ?[]const u8) !void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                return;
            }
        }

        try self.entries.append(.{ .key = key, .value = value });
    }

    fn contains(self: *const OrderedAttrs, key: []const u8) bool {
        return self.tryGetValue(key) != null;
    }

    fn tryGetValue(self: *const OrderedAttrs, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }
};

const ItemNode = struct {
    attr: []const u8,
    op: []const u8,
    value: []const u8,
    wildcard: ?[]const u8,
};

const FilterNode = union(enum) {
    item: ItemNode,
    and_node: []*FilterNode,
    or_node: []*FilterNode,
    not_node: *FilterNode,
};

const CliOptions = struct {
    filter: ?[]const u8 = null,
    input: ?[]const u8 = null,
    format: Format = .auto,
    help: bool = false,
};

const ParseError = error{
    EmptyFilter,
    ParenthesisMismatch,
    NotOperatorArity,
    InvalidItemSyntax,
};

pub fn main(minimal: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    const args = try argsToSlices(allocator, minimal.args.vector);
    defer allocator.free(args);

    if (args.len > 0) {
        var stdout_stream = StdStream.init(.stdout(), allocator);
        var stderr_stream = StdStream.init(.stderr(), allocator);
        try run(allocator, args[1..], &stdout_stream, &stderr_stream);
    }
}

const StdStream = struct {
    file: std.Io.File,
    io: std.Io,
    allocator: Allocator,

    fn init(file: std.Io.File, allocator: Allocator) StdStream {
        return .{
            .file = file,
            .io = std.Io.Threaded.global_single_threaded.io(),
            .allocator = allocator,
        };
    }

    fn writeAll(self: *StdStream, bytes: []const u8) !void {
        try std.Io.File.writeStreamingAll(self.file, self.io, bytes);
    }

    fn print(self: *StdStream, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }
};

fn argsToSlices(allocator: Allocator, args: std.process.Args.Vector) ![][]const u8 {
    var list = Managed([]const u8).init(allocator);
    errdefer list.deinit();

    for (args) |arg| {
        try list.append(std.mem.span(arg));
    }

    return try list.toOwnedSlice();
}

fn run(allocator: Allocator, args: [][]const u8, stdout: anytype, stderr: anytype) !void {
    const options = try parseArgs(args);

    if (options.help) {
        try stdout.writeAll("Usage: ldap_filter [options] FILTER INPUT\n");
        return;
    }

    const filter = options.filter orelse return error.MissingFilter;
    const input = options.input orelse return error.MissingInput;

    const started = monotonicNs();
    const boot_ns = elapsedNs(started);
    try stderr.print("phase=boot t={} elapsed_ns={}\n", .{ boot_ns, boot_ns });

    const format = if (options.format == .auto) detectFormat(input) else options.format;

    const ready_ns = elapsedNs(started);
    try stderr.print("phase=ready t={} elapsed_ns={}\n", .{ ready_ns, ready_ns });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ast = try parseFilter(arena.allocator(), filter);
    try processInput(allocator, input, format, ast, stdout);

    const done_ns = elapsedNs(started);
    try stderr.print("phase=done t={} elapsed_ns={}\n", .{ done_ns, done_ns });
}

fn elapsedNs(started: u64) u64 {
    return monotonicNs() - started;
}

fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn parseArgs(args: [][]const u8) !CliOptions {
    var options = CliOptions{};
    var positional = Managed([]const u8).init(std.heap.page_allocator);
    defer positional.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) return error.MissingFilterValue;
            options.filter = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingInputValue;
            options.input = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingFormatValue;
            options.format = parseFormat(args[i]) catch return error.UnsupportedFormat;
            continue;
        }
        if (std.mem.eql(u8, arg, "--jit") or
            std.mem.eql(u8, arg, "--no-jit") or
            std.mem.eql(u8, arg, "--yjit") or
            std.mem.eql(u8, arg, "--no-yjit") or
            std.mem.eql(u8, arg, "--yjit-stats"))
        {
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            options.help = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        }
        try positional.append(arg);
    }

    if (options.filter == null and positional.items.len > 0) {
        options.filter = positional.items[0];
    }
    if (options.input == null and positional.items.len > 1) {
        options.input = positional.items[1];
    }

    return options;
}

fn parseFormat(value: []const u8) !Format {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "csv")) return .csv;
    if (std.mem.eql(u8, value, "ltsv")) return .ltsv;
    return error.UnsupportedFormat;
}

fn detectFormat(input: []const u8) Format {
    if (std.mem.endsWith(u8, input, ".csv") or std.mem.endsWith(u8, input, ".csv.xz")) {
        return .csv;
    }
    if (std.mem.endsWith(u8, input, ".ltsv") or std.mem.endsWith(u8, input, ".ltsv.xz")) {
        return .ltsv;
    }
    return .ltsv;
}

fn processInput(allocator: Allocator, input: []const u8, format: Format, ast: *const FilterNode, stdout: anytype) !void {
    const io = std.Io.Threaded.global_single_threaded.io();

    if (std.mem.endsWith(u8, input, ".xz")) {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "xz", "-dc", input },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.InputCommandFailed,
            else => return error.InputCommandFailed,
        }
        try processData(allocator, result.stdout, format, ast, stdout);
        return;
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(io, input, allocator, .unlimited);
    defer allocator.free(data);
    try processData(allocator, data, format, ast, stdout);
}

fn processData(allocator: Allocator, data: []const u8, format: Format, ast: *const FilterNode, stdout: anytype) !void {
    switch (format) {
        .csv => try processCsv(allocator, data, ast, stdout),
        .ltsv => try processLtsv(allocator, data, ast, stdout),
        .auto => return error.InvalidFormat,
    }
}

fn processCsv(allocator: Allocator, data: []const u8, ast: *const FilterNode, stdout: anytype) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header_line_raw = lines.next() orelse return;
    const header_line = trimCarriageReturn(stripBom(header_line_raw));

    var header_arena = std.heap.ArenaAllocator.init(allocator);
    defer header_arena.deinit();
    const headers = try parseCsvFields(header_arena.allocator(), header_line);
    if (headers.len == 0) return;

    while (lines.next()) |raw_line| {
        const line = trimCarriageReturn(raw_line);
        if (line.len == 0) continue;

        var row_arena = std.heap.ArenaAllocator.init(allocator);
        defer row_arena.deinit();

        const row = try parseCsvFields(row_arena.allocator(), line);
        var attrs = try csvRowToAttrs(row_arena.allocator(), headers, row);
        defer attrs.deinit();

        if (evaluate(ast, &attrs)) {
            const rendered = try inspectAttrs(row_arena.allocator(), &attrs);
            try stdout.print("{s}\n", .{rendered});
        }
    }
}

fn csvRowToAttrs(allocator: Allocator, headers: []const []const u8, row: []const []const u8) !OrderedAttrs {
    var attrs = OrderedAttrs.init(allocator);
    errdefer attrs.deinit();

    for (headers, 0..) |header, index| {
        const value: []const u8 = if (index < row.len) row[index] else "";
        try attrs.add(header, value);
    }

    return attrs;
}

fn processLtsv(allocator: Allocator, data: []const u8, ast: *const FilterNode, stdout: anytype) !void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = trimCarriageReturn(raw_line);
        if (line.len == 0) continue;

        var row_arena = std.heap.ArenaAllocator.init(allocator);
        defer row_arena.deinit();

        var attrs = try parseLtsvLine(row_arena.allocator(), line);
        defer attrs.deinit();

        if (evaluate(ast, &attrs)) {
            const rendered = try inspectAttrs(row_arena.allocator(), &attrs);
            try stdout.print("{s}\n", .{rendered});
        }
    }
}

fn parseLtsvLine(allocator: Allocator, line: []const u8) !OrderedAttrs {
    var attrs = OrderedAttrs.init(allocator);
    errdefer attrs.deinit();

    var entries = std.mem.splitScalar(u8, line, '\t');
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse continue;
        const key = try allocator.dupe(u8, entry[0..colon]);
        const value_raw = entry[colon + 1 ..];
        const value = if (value_raw.len == 0) null else try unescapeLtsvValue(allocator, value_raw);
        try attrs.add(key, value);
    }

    return attrs;
}

fn unescapeLtsvValue(allocator: Allocator, value: []const u8) ![]const u8 {
    var out = Managed(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (ch == '\\' and i + 1 < value.len) {
            i += 1;
            switch (value[i]) {
                'r' => try out.append('\r'),
                'n' => try out.append('\n'),
                't' => try out.append('\t'),
                '\\' => try out.append('\\'),
                else => {
                    try out.append('\\');
                    try out.append(value[i]);
                },
            }
            continue;
        }
        try out.append(ch);
    }

    return try out.toOwnedSlice();
}

fn parseCsvFields(allocator: Allocator, line: []const u8) ![]const []const u8 {
    var fields = Managed([]const u8).init(allocator);
    errdefer fields.deinit();

    var cell = Managed(u8).init(allocator);
    errdefer cell.deinit();

    var quoted = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quoted) {
            if (ch == '"') {
                if (i + 1 < line.len and line[i + 1] == '"') {
                    try cell.append('"');
                    i += 1;
                } else {
                    quoted = false;
                }
            } else {
                try cell.append(ch);
            }
            continue;
        }

        switch (ch) {
            ',' => {
                try fields.append(try cell.toOwnedSlice());
                cell = Managed(u8).init(allocator);
            },
            '"' => {
                if (cell.items.len == 0) {
                    quoted = true;
                } else {
                    try cell.append(ch);
                }
            },
            else => try cell.append(ch),
        }
    }

    try fields.append(try cell.toOwnedSlice());
    return try fields.toOwnedSlice();
}

fn stripBom(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) {
        return line[3..];
    }
    return line;
}

fn trimCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

fn parseFilter(allocator: Allocator, expr: []const u8) (ParseError || Allocator.Error)!*FilterNode {
    if (expr.len == 0) return error.EmptyFilter;

    if (expr[0] == '(') {
        if (expr[expr.len - 1] != ')') return error.ParenthesisMismatch;
        return parseFilter(allocator, expr[1 .. expr.len - 1]);
    }

    switch (expr[0]) {
        '&' => return parseNary(allocator, expr[1..], .and_node),
        '|' => return parseNary(allocator, expr[1..], .or_node),
        '!' => return parseNot(allocator, expr[1..]),
        else => return parseItem(allocator, expr),
    }
}

fn parseNary(allocator: Allocator, expr: []const u8, tag: enum { and_node, or_node }) (ParseError || Allocator.Error)!*FilterNode {
    const parts = try splitTopLevel(allocator, expr);
    defer allocator.free(parts);

    if (parts.len == 0) return error.EmptyFilter;

    var children = try allocator.alloc(*FilterNode, parts.len);
    errdefer allocator.free(children);

    for (parts, 0..) |part, index| {
        children[index] = try parseFilter(allocator, part);
    }

    const node = try allocator.create(FilterNode);
    node.* = switch (tag) {
        .and_node => .{ .and_node = children },
        .or_node => .{ .or_node = children },
    };
    return node;
}

fn parseNot(allocator: Allocator, expr: []const u8) (ParseError || Allocator.Error)!*FilterNode {
    const parts = try splitTopLevel(allocator, expr);
    defer allocator.free(parts);

    if (parts.len != 1) return error.NotOperatorArity;

    const node = try allocator.create(FilterNode);
    node.* = .{ .not_node = try parseFilter(allocator, parts[0]) };
    return node;
}

fn parseItem(allocator: Allocator, expr: []const u8) (ParseError || Allocator.Error)!*FilterNode {
    const op_info = findOperator(expr) orelse return error.InvalidItemSyntax;
    const attr = expr[0..op_info.index];
    const raw_value = expr[op_info.index + op_info.len ..];
    if (attr.len == 0) return error.InvalidItemSyntax;

    const value = try unescapeHex(allocator, raw_value);
    const wildcard = if (std.mem.indexOfScalar(u8, value, '*') != null) value else null;

    const node = try allocator.create(FilterNode);
    node.* = .{
        .item = .{
            .attr = attr,
            .op = op_info.op,
            .value = value,
            .wildcard = wildcard,
        },
    };
    return node;
}

const OperatorInfo = struct {
    index: usize,
    len: usize,
    op: []const u8,
};

fn findOperator(expr: []const u8) ?OperatorInfo {
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        if (i + 1 < expr.len) {
            if (expr[i] == '~' and expr[i + 1] == '=') {
                return .{ .index = i, .len = 2, .op = "~=" };
            }
            if (expr[i] == '>' and expr[i + 1] == '=') {
                return .{ .index = i, .len = 2, .op = ">=" };
            }
            if (expr[i] == '<' and expr[i + 1] == '=') {
                return .{ .index = i, .len = 2, .op = "<=" };
            }
        }

        if (expr[i] == '=') {
            return .{ .index = i, .len = 1, .op = "=" };
        }
    }
    return null;
}

fn unescapeHex(allocator: Allocator, text: []const u8) ![]const u8 {
    var out = Managed(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 2 < text.len) {
            const hi = hexDigit(text[i + 1]);
            const lo = hexDigit(text[i + 2]);
            if (hi != null and lo != null) {
                try out.append(@as(u8, hi.? * 16 + lo.?));
                i += 2;
                continue;
            }
        }
        try out.append(text[i]);
    }

    return try out.toOwnedSlice();
}

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => 10 + (ch - 'a'),
        'A'...'F' => 10 + (ch - 'A'),
        else => null,
    };
}

fn splitTopLevel(allocator: Allocator, expr: []const u8) (ParseError || Allocator.Error)![]const []const u8 {
    var parts = Managed([]const u8).init(allocator);
    errdefer parts.deinit();

    var depth: i32 = 0;
    var start: usize = 0;
    var saw_paren = false;

    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const ch = expr[i];
        switch (ch) {
            '(' => {
                if (depth == 0) {
                    start = i + 1;
                    saw_paren = true;
                }
                depth += 1;
            },
            ')' => {
                depth -= 1;
                if (depth < 0) return error.ParenthesisMismatch;
                if (depth == 0) {
                    try parts.append(expr[start..i]);
                }
            },
            else => {},
        }
    }

    if (depth != 0) return error.ParenthesisMismatch;
    if (parts.items.len > 0 or saw_paren) {
        return try parts.toOwnedSlice();
    }

    try parts.append(expr);
    return try parts.toOwnedSlice();
}

fn evaluate(node: *const FilterNode, attrs: *const OrderedAttrs) bool {
    return switch (node.*) {
        .item => |item| evaluateItem(item, attrs),
        .and_node => |children| blk: {
            for (children) |child| {
                if (!evaluate(child, attrs)) break :blk false;
            }
            break :blk true;
        },
        .or_node => |children| blk: {
            for (children) |child| {
                if (evaluate(child, attrs)) break :blk true;
            }
            break :blk false;
        },
        .not_node => |child| !evaluate(child, attrs),
    };
}

fn evaluateItem(item: ItemNode, attrs: *const OrderedAttrs) bool {
    const actual = attrs.tryGetValue(item.attr);

    if (std.mem.eql(u8, item.op, "=")) {
        if (item.value.len == 1 and item.value[0] == '*') {
            return attrs.contains(item.attr);
        }

        if (item.wildcard) |pattern| {
            return actual != null and wildcardMatch(pattern, actual.?);
        }

        return actual != null and std.mem.eql(u8, actual.?, item.value);
    }

    if (std.mem.eql(u8, item.op, "~=")) {
        if (actual) |actual_value| {
            const distance = levenshtein(item.value, actual_value) catch return false;
            return distance < 3;
        }
        return false;
    }

    if (std.mem.eql(u8, item.op, ">=")) {
        return actual != null and std.mem.order(u8, actual.?, item.value) != .lt;
    }

    if (std.mem.eql(u8, item.op, "<=")) {
        return actual != null and std.mem.order(u8, actual.?, item.value) != .gt;
    }

    return false;
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var match_index: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
            continue;
        }
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            match_index = t;
            continue;
        }
        if (star) |star_pos| {
            p = star_pos + 1;
            match_index += 1;
            t = match_index;
            continue;
        }
        return false;
    }

    while (p < pattern.len and pattern[p] == '*') {
        p += 1;
    }

    return p == pattern.len;
}

fn levenshtein(a: []const u8, b: []const u8) !usize {
    const prev = try std.heap.page_allocator.alloc(usize, b.len + 1);
    defer std.heap.page_allocator.free(prev);

    const curr = try std.heap.page_allocator.alloc(usize, b.len + 1);
    defer std.heap.page_allocator.free(curr);

    for (prev, 0..) |*slot, i| {
        slot.* = i;
    }

    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        curr[0] = i;
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            const deletion = prev[j] + 1;
            const insertion = curr[j - 1] + 1;
            const substitution = prev[j - 1] + cost;
            curr[j] = @min(@min(deletion, insertion), substitution);
        }

        std.mem.copyForwards(usize, prev, curr);
    }

    return prev[b.len];
}

fn inspectAttrs(allocator: Allocator, attrs: *const OrderedAttrs) ![]const u8 {
    var out = Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.append('{');
    for (attrs.entries.items, 0..) |entry, index| {
        if (index > 0) {
            try out.appendSlice(", ");
        }
        try appendRubySymbolKey(&out, entry.key);
        try out.appendSlice("=>");
        if (entry.value) |value| {
            try out.append('"');
            try appendEscapedRubyString(&out, value);
            try out.append('"');
        } else {
            try out.appendSlice("nil");
        }
    }
    try out.append('}');

    return try out.toOwnedSlice();
}

fn appendRubySymbolKey(out: *Managed(u8), key: []const u8) !void {
    if (isRubySymbolKey(key)) {
        try out.append(':');
        try out.appendSlice(key);
        return;
    }

    try out.appendSlice(":\"");
    try appendEscapedRubyString(out, key);
    try out.append('"');
}

fn isRubySymbolKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!isRubySymbolStart(key[0])) return false;
    for (key[1..]) |ch| {
        if (!isRubySymbolContinue(ch)) return false;
    }
    return true;
}

fn isRubySymbolStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isRubySymbolContinue(ch: u8) bool {
    return isRubySymbolStart(ch) or (ch >= '0' and ch <= '9');
}

fn appendEscapedRubyString(out: *Managed(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice("\\\\"),
            '"' => try out.appendSlice("\\\""),
            else => try out.append(ch),
        }
    }
}

test "parser and evaluator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var attrs = OrderedAttrs.init(std.testing.allocator);
    defer attrs.deinit();
    try attrs.add("host", "example.com");
    try attrs.add("pass", "true");
    try attrs.add("cn", "foo bar");
    try attrs.add("age", "10");

    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(host=*)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(host=example.com)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(host=exam*ple.com)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(host~=exampel.com)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(age>=10)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(age<=10)"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(cn=foo\\20bar)"), &attrs));
    try std.testing.expect(!evaluate(try parseFilter(arena.allocator(), "(!(pass=true))"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(&(host=example.com)(pass=true))"), &attrs));
    try std.testing.expect(evaluate(try parseFilter(arena.allocator(), "(|(host=nope)(pass=true))"), &attrs));
}

test "csv and ltsv helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const headers = try parseCsvFields(arena.allocator(), "host,pass,comment");
    const row = try parseCsvFields(arena.allocator(), "\"example,com\",\"tr\"\"ue\",tail");
    var csv_attrs = try csvRowToAttrs(arena.allocator(), headers, row);
    defer csv_attrs.deinit();

    try std.testing.expectEqualStrings("example,com", csv_attrs.tryGetValue("host").?);
    try std.testing.expectEqualStrings("tr\"ue", csv_attrs.tryGetValue("pass").?);
    try std.testing.expectEqualStrings("tail", csv_attrs.tryGetValue("comment").?);

    var ltsv_attrs = try parseLtsvLine(arena.allocator(), "host:example\\tcom\tpass:true\tcomment:line\\nnext");
    defer ltsv_attrs.deinit();
    try std.testing.expectEqualStrings("example\tcom", ltsv_attrs.tryGetValue("host").?);
    try std.testing.expectEqualStrings("true", ltsv_attrs.tryGetValue("pass").?);
    try std.testing.expectEqualStrings("line\nnext", ltsv_attrs.tryGetValue("comment").?);
}

test "cli output and phases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "zig-test-input.csv";
    {
        const file = try tmp.dir.createFile(std.testing.io, file_name, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "host,pass\nexample.com,true\nother,false\n");
    }

    const input_path = try tmp.dir.realPathFileAlloc(std.testing.io, file_name, std.testing.allocator);
    defer std.testing.allocator.free(input_path);

    var stdout_capture = Capture.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = Capture.init(std.testing.allocator);
    defer stderr_capture.deinit();

    var args = [_][]const u8{ "--format", "auto", "(host=example.com)", input_path };
    try run(
        std.testing.allocator,
        args[0..],
        &stdout_capture,
        &stderr_capture,
    );

    try std.testing.expectEqualStrings("{:host=>\"example.com\", :pass=>\"true\"}\n", stdout_capture.items());

    const stderr_text = stderr_capture.items();
    var lines = std.mem.splitScalar(u8, stderr_text, '\n');
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "phase=boot "));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "phase=ready "));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "phase=done "));
}

const Capture = struct {
    buffer: Managed(u8),

    fn init(allocator: Allocator) Capture {
        return .{ .buffer = Managed(u8).init(allocator) };
    }

    fn deinit(self: *Capture) void {
        self.buffer.deinit();
    }

    fn writeAll(self: *Capture, bytes: []const u8) !void {
        try self.buffer.appendSlice(bytes);
    }

    fn print(self: *Capture, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.buffer.allocator, fmt, args);
        defer self.buffer.allocator.free(rendered);
        try self.buffer.appendSlice(rendered);
    }

    fn items(self: *const Capture) []const u8 {
        return self.buffer.items;
    }
};
