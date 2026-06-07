const std = @import("std");

pub const TargetType = enum {
    plaintext,
    prefer_synced,
    synced_only,
};

pub const LyricsType = enum {
    invalid,
    plaintext,
    synced,
};

pub const Lyrics = struct {
    synced: ?[]u8 = null,
    unsynced: ?[]u8 = null,

    pub fn deinit(self: *Lyrics, allocator: std.mem.Allocator) void {
        if (self.synced) |s| allocator.free(s);
        if (self.unsynced) |s| allocator.free(s);
        self.* = .{};
    }

    pub fn addUnknown(self: *Lyrics, allocator: std.mem.Allocator, text: ?[]const u8) !void {
        const value = text orelse return;
        if (value.len == 0) return;
        switch (identifyLyricsType(value)) {
            .synced => {
                if (self.synced) |old| allocator.free(old);
                self.synced = try allocator.dupe(u8, value);
            },
            .plaintext => {
                if (self.unsynced) |old| allocator.free(old);
                self.unsynced = try allocator.dupe(u8, value);
            },
            .invalid => {},
        }
    }

    pub fn updateMove(self: *Lyrics, allocator: std.mem.Allocator, other: *Lyrics) !void {
        if (other.synced) |s| {
            if (self.synced) |old| allocator.free(old);
            self.synced = s;
            other.synced = null;
        }
        if (other.unsynced) |s| {
            if (self.unsynced) |old| allocator.free(old);
            self.unsynced = s;
            other.unsynced = null;
        }
    }

    pub fn isPreferred(self: Lyrics, target_type: TargetType) bool {
        return self.synced != null or (target_type == .plaintext and self.unsynced != null);
    }

    pub fn isAcceptable(self: Lyrics, target_type: TargetType) bool {
        return self.synced != null or (target_type != .synced_only and self.unsynced != null);
    }

    pub fn toString(self: Lyrics, allocator: std.mem.Allocator, target_type: TargetType) ![]u8 {
        return switch (target_type) {
            .plaintext => if (self.unsynced) |u| try allocator.dupe(u8, u) else syncedToPlaintext(allocator, self.synced orelse ""),
            .prefer_synced => if (self.synced) |s| try allocator.dupe(u8, s) else try allocator.dupe(u8, self.unsynced orelse ""),
            .synced_only => try allocator.dupe(u8, self.synced orelse ""),
        };
    }
};

pub fn identifyLyricsType(lrc: []const u8) LyricsType {
    if (lrc.len == 0) return .invalid;
    var it = std.mem.splitScalar(u8, lrc, '\n');
    var index: usize = 0;
    var checked: usize = 0;
    var all_have_bracket = true;
    while (it.next()) |line| : (index += 1) {
        if (index < 5) continue;
        if (index >= 10) break;
        checked += 1;
        if (std.mem.indexOfScalar(u8, line, '[') == null) all_have_bracket = false;
    }
    if (checked > 0 and all_have_bracket) return .synced;
    return .plaintext;
}

pub fn syncedToPlaintext(allocator: std.mem.Allocator, synced: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var line_it = std.mem.splitScalar(u8, synced, '\n');
    var first = true;
    while (line_it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var rest = line;
        while (rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
            if (!looksLikeTimestamp(rest[0 .. close + 1])) break;
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
        }
        try out.appendSlice(allocator, rest);
    }
    return out.toOwnedSlice(allocator);
}

fn looksLikeTimestamp(value: []const u8) bool {
    if (value.len < 8 or value[0] != '[' or value[value.len - 1] != ']') return false;
    const body = value[1 .. value.len - 1];
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return false;
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse return false;
    return colon > 0 and dot > colon + 1;
}

pub fn hasTranslation(lrc: []const u8) bool {
    var lines: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, lrc, '\n');
    var index: usize = 0;
    while (it.next()) |line| : (index += 1) {
        if (index < 5) continue;
        if (index >= 10) break;
        lines[count] = line;
        count += 1;
    }
    for (lines[0..count], 0..) |line, i| {
        if (std.mem.indexOfScalar(u8, line, '[') != null and i + 1 < count) {
            if (std.mem.indexOfScalar(u8, lines[i + 1], '(') == null) return false;
        }
    }
    return true;
}

pub fn formatTime(allocator: std.mem.Allocator, seconds: f64) ![]u8 {
    const total_cs: u64 = @intFromFloat(@floor(seconds * 100.0));
    const minutes = total_cs / 6000;
    const secs = (total_cs / 100) % 60;
    const cs = total_cs % 100;
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}.{d:0>2}", .{ minutes, secs, cs });
}

pub fn strScore(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !f64 {
    const aa = try normalizeForScore(allocator, a, std.mem.indexOf(u8, b, "feat") == null and std.mem.indexOf(u8, b, "Feat") == null);
    defer allocator.free(aa);
    const bb = try normalizeForScore(allocator, b, false);
    defer allocator.free(bb);

    var toks_a = try tokenSet(allocator, aa);
    defer toks_a.deinit(allocator);
    var toks_b = try tokenSet(allocator, bb);
    defer toks_b.deinit(allocator);
    if (toks_a.items.len == 0 and toks_b.items.len == 0) return 100;
    if (toks_a.items.len == 0 or toks_b.items.len == 0) return 0;

    var intersect: usize = 0;
    for (toks_a.items) |ta| {
        for (toks_b.items) |tb| {
            if (std.mem.eql(u8, ta, tb)) {
                intersect += 1;
                break;
            }
        }
    }
    if (intersect == @min(toks_a.items.len, toks_b.items.len)) return 100;
    const precision = @as(f64, @floatFromInt(intersect)) / @as(f64, @floatFromInt(toks_a.items.len));
    const recall = @as(f64, @floatFromInt(intersect)) / @as(f64, @floatFromInt(toks_b.items.len));
    if (precision + recall == 0) return 0;
    return 200.0 * precision * recall / (precision + recall);
}

pub fn strSame(allocator: std.mem.Allocator, a: []const u8, b: []const u8, min_score: f64) !bool {
    return try strScore(allocator, a, b) >= min_score;
}

fn normalizeForScore(allocator: std.mem.Allocator, input: []const u8, strip_feat: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (strip_feat and input[i] == '(') {
            const close = std.mem.indexOfScalarPos(u8, input, i, ')');
            if (close) |end| {
                const inside = input[i + 1 .. end];
                if (containsIgnoreCase(inside, "feat")) {
                    i = end + 1;
                    continue;
                }
            }
        }
        const c = std.ascii.toLower(input[i]);
        try out.append(allocator, if (std.ascii.isAlphanumeric(c)) c else ' ');
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const TokenList = std.ArrayList([]const u8);

fn tokenSet(allocator: std.mem.Allocator, input: []const u8) !TokenList {
    var list: TokenList = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    while (it.next()) |tok| {
        var exists = false;
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, tok)) {
                exists = true;
                break;
            }
        }
        if (!exists) try list.append(allocator, tok);
    }
    return list;
}

pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn htmlTextDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (std.mem.startsWith(u8, input[i..], "<br/>") or std.mem.startsWith(u8, input[i..], "<br>")) {
            try out.append(allocator, '\n');
            i += if (std.mem.startsWith(u8, input[i..], "<br/>")) 5 else 4;
        } else if (input[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse break;
            i = end + 1;
        } else if (std.mem.startsWith(u8, input[i..], "&amp;")) {
            try out.append(allocator, '&');
            i += 5;
        } else if (std.mem.startsWith(u8, input[i..], "&lt;")) {
            try out.append(allocator, '<');
            i += 4;
        } else if (std.mem.startsWith(u8, input[i..], "&gt;")) {
            try out.append(allocator, '>');
            i += 4;
        } else if (std.mem.startsWith(u8, input[i..], "&quot;")) {
            try out.append(allocator, '"');
            i += 6;
        } else if (std.mem.startsWith(u8, input[i..], "&#x27;") or std.mem.startsWith(u8, input[i..], "&#39;")) {
            try out.append(allocator, '\'');
            i += if (std.mem.startsWith(u8, input[i..], "&#x27;")) 6 else 5;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "lyrics type and plaintext conversion" {
    const allocator = std.testing.allocator;
    const lrc = "a\nb\nc\nd\ne\n[00:01.00] one\n[00:02.00] two\n[00:03.00] three\n[00:04.00] four\n[00:05.00] five";
    try std.testing.expectEqual(LyricsType.synced, identifyLyricsType(lrc));
    const plain = try syncedToPlaintext(allocator, lrc);
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "[00:01.00]") == null);
}

test "format time and fuzzy score" {
    const allocator = std.testing.allocator;
    const t = try formatTime(allocator, 61.239);
    defer allocator.free(t);
    try std.testing.expectEqualStrings("01:01.23", t);
    try std.testing.expect(try strSame(allocator, "bad guy billie eilish", "Billie Eilish - Bad Guy", 65));
}
