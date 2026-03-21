//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize, // exclusive
};

pub const TemplateSpan = struct {
    start: usize,
    end: usize, // exclusive
    in_quotes: bool,
};

pub const MaskResult = struct {
    masked: []u8,
    spans: []Span,
};

pub const Placeholder = struct {
    token: []const u8,
    original: []const u8,
};

pub const FormatMaskResult = struct {
    masked: []u8,
    placeholders: []Placeholder,
};

pub fn maskJinja(allocator: std.mem.Allocator, input: []const u8) !MaskResult {
    var masked = try allocator.dupe(u8, input);
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i + 1 < masked.len) : (i += 1) {
        if (masked[i] == '{' and masked[i + 1] == '{') {
            const start = i;
            var j = i + 2;
            while (j + 1 < masked.len) : (j += 1) {
                if (masked[j] == '}' and masked[j + 1] == '}') {
                    const end = j + 2;
                    try spans.append(allocator, .{ .start = start, .end = end });
                    @memset(masked[start..end], ' ');
                    i = end - 1;
                    break;
                }
            }
        }
    }

    return .{
        .masked = masked,
        .spans = try spans.toOwnedSlice(allocator),
    };
}

pub fn templateSpans(allocator: std.mem.Allocator, input: []const u8) ![]TemplateSpan {
    var spans: std.ArrayList(TemplateSpan) = .empty;
    errdefer spans.deinit(allocator);

    var state: QuoteState = .none;
    var i: usize = 0;
    while (i + 1 < input.len) : (i += 1) {
        updateQuoteState(input, &i, &state);

        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            const start = i;
            var j = i + 2;
            while (j + 1 < input.len) : (j += 1) {
                if (input[j] == '}' and input[j + 1] == '}') {
                    const end = j + 2;
                    try spans.append(allocator, .{
                        .start = start,
                        .end = end,
                        .in_quotes = state != .none,
                    });
                    i = end - 1;
                    break;
                }
            }
        }
    }

    return spans.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn maskJinjaForFormat(allocator: std.mem.Allocator, input: []const u8) !FormatMaskResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var placeholders: std.ArrayList(Placeholder) = .empty;
    errdefer placeholders.deinit(allocator);

    var line_start: usize = 0;
    var state: QuoteState = .none;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\n') {
            line_start = i + 1;
            try out.append(allocator, '\n');
            continue;
        }

        updateQuoteState(input, &i, &state);

        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            const start = i;
            var j = i + 2;
            while (j + 1 < input.len) : (j += 1) {
                if (input[j] == '}' and input[j + 1] == '}') {
                    const end = j + 2;

                    if (state == .none) {
                        return error.TemplateOutsideQuotes;
                    }

                    const line_end = std.mem.indexOfScalarPos(u8, input, start, '\n') orelse input.len;
                    if (std.mem.indexOfScalarPos(u8, input, line_start, '=')) |eq| {
                        if (eq >= line_end or start < eq) {
                            return error.TemplateInKey;
                        }
                    } else {
                        const line_slice = std.mem.trim(u8, input[line_start..line_end], " \t");
                        if (line_slice.len > 0 and line_slice[0] == '[') {
                            return error.TemplateInKey;
                        }
                        // Allow templates in multiline array values (no '=' on this line).
                    }

                    const token = try std.fmt.allocPrint(allocator, "__JADE_{d}__", .{placeholders.items.len});
                    const original = try allocator.dupe(u8, input[start..end]);
                    try placeholders.append(allocator, .{ .token = token, .original = original });

                    try out.appendSlice(allocator, token);

                    i = end - 1;
                    break;
                }
            }
            continue;
        }

        try out.append(allocator, input[i]);
    }

    return .{
        .masked = try out.toOwnedSlice(allocator),
        .placeholders = try placeholders.toOwnedSlice(allocator),
    };
}

pub const QuoteState = enum {
    none,
    single,
    double,
    multi_single,
    multi_double,
};

pub fn updateQuoteState(input: []const u8, i: *usize, state: *QuoteState) void {
    switch (state.*) {
        .none => {
            if (i.* + 2 < input.len and input[i.*] == '"' and input[i.* + 1] == '"' and input[i.* + 2] == '"') {
                state.* = .multi_double;
                i.* += 2;
                return;
            }
            if (i.* + 2 < input.len and input[i.*] == '\'' and input[i.* + 1] == '\'' and input[i.* + 2] == '\'') {
                state.* = .multi_single;
                i.* += 2;
                return;
            }
            if (input[i.*] == '"') {
                state.* = .double;
                return;
            }
            if (input[i.*] == '\'') {
                state.* = .single;
                return;
            }
        },
        .double => {
            if (input[i.*] == '\\' and i.* + 1 < input.len) {
                i.* += 1;
                return;
            }
            if (input[i.*] == '"') {
                state.* = .none;
                return;
            }
        },
        .single => {
            if (input[i.*] == '\'') {
                state.* = .none;
                return;
            }
        },
        .multi_double => {
            if (input[i.*] == '\\' and i.* + 1 < input.len) {
                i.* += 1;
                return;
            }
            if (i.* + 2 < input.len and input[i.*] == '"' and input[i.* + 1] == '"' and input[i.* + 2] == '"') {
                state.* = .none;
                i.* += 2;
                return;
            }
        },
        .multi_single => {
            if (i.* + 2 < input.len and input[i.*] == '\'' and input[i.* + 1] == '\'' and input[i.* + 2] == '\'') {
                state.* = .none;
                i.* += 2;
                return;
            }
        },
    }
}

pub fn lineSlice(text: []const u8, target_line: usize) ?[]const u8 {
    var line_index: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            if (line_index == target_line) {
                return text[start..i];
            }
            line_index += 1;
            start = i + 1;
        }
    }
    return null;
}

pub fn errorSpan(line_text: []const u8, column: usize) Span {
    if (line_text.len == 0) return .{ .start = column, .end = column + 1 };
    const start = if (column > line_text.len) line_text.len else column;

    var left = start;
    while (left > 0) : (left -= 1) {
        const c = line_text[left - 1];
        if (c == ' ' or c == '\t') break;
    }

    var right = start;
    while (right < line_text.len) : (right += 1) {
        const c = line_text[right];
        if (c == ' ' or c == '\t') break;
    }

    if (right == left) {
        return .{ .start = start, .end = start + 1 };
    }
    return .{ .start = left, .end = right };
}

pub fn isMaskedPosition(spans: []const Span, text: []const u8, line_1based: usize, col_1based: usize) bool {
    if (line_1based == 0 or col_1based == 0) return false;
    const line = line_1based - 1;
    const col = col_1based - 1;

    var line_index: usize = 0;
    var index: usize = 0;
    while (index < text.len and line_index < line) : (index += 1) {
        if (text[index] == '\n') {
            line_index += 1;
        }
    }

    if (line_index != line) return false;
    const offset = index + col;
    for (spans) |span| {
        if (offset >= span.start and offset < span.end) return true;
    }
    return false;
}

pub const LineInfo = struct {
    lines: usize,
    last_line_len: usize,
};

pub fn lineInfo(text: []const u8) LineInfo {
    if (text.len == 0) return .{ .lines = 1, .last_line_len = 0 };
    var lines: usize = 1;
    var last_len: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            lines += 1;
            last_len = 0;
        } else {
            last_len += 1;
        }
    }
    return .{ .lines = lines, .last_line_len = last_len };
}

pub fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "maskJinja captures spans and masks" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = "a = {{ params.value }}\n";
    const res = try maskJinja(allocator, input);
    defer allocator.free(res.masked);
    defer allocator.free(res.spans);

    try std.testing.expect(res.spans.len == 1);
    try std.testing.expect(res.spans[0].start == 4);
    try std.testing.expect(res.spans[0].end == input.len - 1);
    try std.testing.expect(std.mem.indexOf(u8, res.masked, "{{") == null);
}

test "maskJinjaForFormat allows value templates and blocks key templates" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ok_input =
        "arr = [\n" ++
        "  \"{{ params.a }}\",\n" ++
        "  \"{{ params.b }}\",\n" ++
        "]\n";
    const ok = try maskJinjaForFormat(allocator, ok_input);
    defer allocator.free(ok.masked);
    defer {
        for (ok.placeholders) |ph| {
            allocator.free(ph.token);
            allocator.free(ph.original);
        }
        allocator.free(ok.placeholders);
    }
    try std.testing.expect(ok.placeholders.len == 2);

    const bad_input = "{{ key }} = 1\n";
    try std.testing.expectError(error.TemplateOutsideQuotes, maskJinjaForFormat(allocator, bad_input));
}

test "replaceAll replaces all matches" {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const out = try replaceAll(allocator, "a __X__ b __X__", "__X__", "42");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a 42 b 42", out);
}

test "lineSlice and errorSpan" {
    const text = "a = 1\nb = 22\n";
    const line1 = lineSlice(text, 1) orelse "";
    try std.testing.expectEqualStrings("b = 22", line1);

    const span = errorSpan(line1, 4);
    try std.testing.expect(span.start <= span.end);
    try std.testing.expect(span.end <= line1.len);
}

pub const Document = struct {
    uri: []const u8,
    text: []u8,
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    docs: std.StringHashMapUnmanaged(Document) = .{},

    pub fn init(allocator: std.mem.Allocator) DocumentStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DocumentStore) void {
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.text);
        }
        self.docs.deinit(self.allocator);
    }

    pub fn set(self: *DocumentStore, uri: []const u8, text: []const u8) !void {
        if (self.docs.getEntry(uri)) |entry| {
            self.allocator.free(entry.value_ptr.text);
            entry.value_ptr.text = try self.allocator.dupe(u8, text);
            return;
        }

        const uri_owned = try self.allocator.dupe(u8, uri);
        const text_owned = try self.allocator.dupe(u8, text);
        try self.docs.put(self.allocator, uri_owned, .{
            .uri = uri_owned,
            .text = text_owned,
        });
    }

    pub fn remove(self: *DocumentStore, uri: []const u8) void {
        if (self.docs.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value.text);
        }
    }

    pub fn get(self: *DocumentStore, uri: []const u8) ?[]const u8 {
        const doc = self.docs.get(uri) orelse return null;
        return doc.text;
    }
};
