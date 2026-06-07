const std = @import("std");
const http = @import("../http.zig");
const root = @import("../root.zig");
const utils = @import("../utils.zig");

pub fn getLyrics(allocator: std.mem.Allocator, client: *std.http.Client, options: root.SearchOptions) !?utils.Lyrics {
    var token_store = try TokenStore.init(allocator, options.cache_dir);
    defer token_store.deinit(allocator);
    const token = try token_store.get(allocator, client);
    defer allocator.free(token);

    const encoded = try utils.urlEncode(allocator, options.search_term);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(
        allocator,
        "https://apic-desktop.musixmatch.com/ws/1.1/track.search?q={s}&page_size=5&page=1&app_id=web-desktop-app-v1.0&usertoken={s}&t={d}",
        .{ encoded, token, nowMillis(client.io) },
    );
    defer allocator.free(url);

    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("message") orelse return null).object;
    const header = (message.get("header") orelse return null).object;
    if (jsonInt(header.get("status_code")) != 200) return null;
    const body = (message.get("body") orelse return null).object;
    const tracks = (body.get("track_list") orelse return null).array;
    if (tracks.items.len == 0) return null;

    var best_index: ?usize = null;
    var best_score: f64 = -1;
    for (tracks.items, 0..) |item, i| {
        const track = (item.object.get("track") orelse continue).object;
        const track_name = jsonString(track.get("track_name")) orelse "";
        const artist = jsonString(track.get("artist_name")) orelse "";
        const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ track_name, artist });
        defer allocator.free(label);
        const score = try utils.strScore(allocator, label, options.search_term);
        if (score > best_score) {
            best_score = score;
            best_index = i;
        }
    }
    const index = best_index orelse return null;
    if (best_score < 65) return null;
    const track = (tracks.items[index].object.get("track") orelse return null).object;
    const track_id = jsonInt(track.get("track_id")) orelse return null;
    const track_id_text = try std.fmt.allocPrint(allocator, "{d}", .{track_id});
    defer allocator.free(track_id_text);

    if (options.enhanced) {
        if (try getWordByWord(allocator, client, token, track_id_text)) |lyrics| {
            if (lyrics.synced != null) return lyrics;
        }
    }
    return getLyricsById(allocator, client, token, track_id_text, options.lang);
}

fn getLyricsById(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    token: []const u8,
    track_id: []const u8,
    lang: ?[]const u8,
) !?utils.Lyrics {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://apic-desktop.musixmatch.com/ws/1.1/track.subtitle.get?track_id={s}&subtitle_format=lrc&app_id=web-desktop-app-v1.0&usertoken={s}&t={d}",
        .{ track_id, token, nowMillis(client.io) },
    );
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("message") orelse return null).object;
    const body_value = message.get("body") orelse return null;
    if (body_value == .null) return null;
    const body = body_value.object;
    const subtitle = (body.get("subtitle") orelse return null).object;
    var lrc_text = try allocator.dupe(u8, jsonString(subtitle.get("subtitle_body")) orelse return null);
    errdefer allocator.free(lrc_text);

    if (lang) |language| {
        lrc_text = try addTranslations(allocator, client, token, track_id, language, lrc_text);
    }

    return .{ .synced = lrc_text };
}

fn addTranslations(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    token: []const u8,
    track_id: []const u8,
    language: []const u8,
    original_lrc: []u8,
) ![]u8 {
    var lrc = original_lrc;
    const url = try std.fmt.allocPrint(
        allocator,
        "https://apic-desktop.musixmatch.com/ws/1.1/crowd.track.translations.get?track_id={s}&subtitle_format=lrc&translation_fields_set=minimal&selected_language={s}&app_id=web-desktop-app-v1.0&usertoken={s}&t={d}",
        .{ track_id, language, token, nowMillis(client.io) },
    );
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return lrc;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("message") orelse return lrc).object;
    const body = (message.get("body") orelse return lrc).object;
    const translations = (body.get("translations_list") orelse return lrc).array;
    for (translations.items) |item| {
        const tr = (item.object.get("translation") orelse continue).object;
        const original = jsonString(tr.get("subtitle_matched_line")) orelse continue;
        const translated = jsonString(tr.get("description")) orelse continue;
        const replacement = try std.fmt.allocPrint(allocator, "{s}\n({s})", .{ original, translated });
        defer allocator.free(replacement);
        const replaced = try replaceAll(allocator, lrc, original, replacement);
        allocator.free(lrc);
        lrc = replaced;
    }
    return lrc;
}

fn getWordByWord(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8, track_id: []const u8) !?utils.Lyrics {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://apic-desktop.musixmatch.com/ws/1.1/track.richsync.get?track_id={s}&app_id=web-desktop-app-v1.0&usertoken={s}&t={d}",
        .{ track_id, token, nowMillis(client.io) },
    );
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("message") orelse return null).object;
    const header = (message.get("header") orelse return null).object;
    if (jsonInt(header.get("status_code")) != 200) return null;
    const body = (message.get("body") orelse return null).object;
    const richsync = (body.get("richsync") orelse return null).object;
    const raw = jsonString(richsync.get("richsync_body")) orelse return null;

    var rich = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer rich.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rich.value.array.items) |line| {
        const obj = line.object;
        const ts = jsonFloat(obj.get("ts")) orelse 0;
        const start = try utils.formatTime(allocator, ts);
        defer allocator.free(start);
        const prefix = try std.fmt.allocPrint(allocator, "[{s}] ", .{start});
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
        if (obj.get("l")) |letters_value| {
            for (letters_value.array.items) |letter| {
                const letter_obj = letter.object;
                const offset = jsonFloat(letter_obj.get("o")) orelse 0;
                const c = jsonString(letter_obj.get("c")) orelse "";
                const word_time = try utils.formatTime(allocator, ts + offset);
                defer allocator.free(word_time);
                const word = try std.fmt.allocPrint(allocator, "<{s}> {s} ", .{ word_time, c });
                defer allocator.free(word);
                try out.appendSlice(allocator, word);
            }
        }
        try out.append(allocator, '\n');
    }
    return .{ .synced = try out.toOwnedSlice(allocator) };
}

const TokenStore = struct {
    path: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, cache_dir: ?[]const u8) !TokenStore {
        const base = if (cache_dir) |dir| try allocator.dupe(u8, dir) else try allocator.dupe(u8, ".zig-syncedlyrics-cache");
        errdefer allocator.free(base);
        const path = try std.fs.path.join(allocator, &.{ base, "musixmatch_token.json" });
        allocator.free(base);
        return .{ .path = path };
    }

    fn deinit(self: *TokenStore, allocator: std.mem.Allocator) void {
        if (self.path) |p| allocator.free(p);
        self.* = .{};
    }

    fn get(self: TokenStore, allocator: std.mem.Allocator, client: *std.http.Client) ![]const u8 {
        if (self.path) |path| {
            if (try readCachedToken(allocator, client.io, path)) |token| return token;
        }
        const token = try fetchToken(allocator, client);
        if (self.path) |path| writeCachedToken(allocator, client.io, path, token) catch {};
        return token;
    }
};

fn readCachedToken(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch return null;
    defer allocator.free(data);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const obj = parsed.value.object;
    const expiration = jsonInt(obj.get("expiration_time")) orelse return null;
    if (nowSeconds(io) >= expiration) return null;
    const token = jsonString(obj.get("token")) orelse return null;
    return try allocator.dupe(u8, token);
}

fn writeCachedToken(allocator: std.mem.Allocator, io: std.Io, path: []const u8, token: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const data = try std.fmt.allocPrint(allocator, "{{\"token\":\"{s}\",\"expiration_time\":{d}}}", .{ token, nowSeconds(io) + 600 });
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn fetchToken(allocator: std.mem.Allocator, client: *std.http.Client) ![]u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://apic-desktop.musixmatch.com/ws/1.1/token.get?user_language=en&app_id=web-desktop-app-v1.0&t={d}",
        .{nowMillis(client.io)},
    );
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return error.ProviderUnavailable;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("message") orelse return error.ProviderUnavailable).object;
    const body = (message.get("body") orelse return error.ProviderUnavailable).object;
    return try allocator.dupe(u8, jsonString(body.get("user_token")) orelse return error.ProviderUnavailable);
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, input);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = input;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        try out.appendSlice(allocator, rest[0..index]);
        try out.appendSlice(allocator, replacement);
        rest = rest[index + needle.len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn nowMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn jsonInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn jsonFloat(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
