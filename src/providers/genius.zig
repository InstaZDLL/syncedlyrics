const std = @import("std");
const http = @import("../http.zig");
const utils = @import("../utils.zig");

pub fn getLyrics(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    search_term: []const u8,
    cookie: ?[]const u8,
) !?utils.Lyrics {
    const encoded = try utils.urlEncode(allocator, search_term);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://genius.com/api/search/multi?per_page=5&q={s}", .{encoded});
    defer allocator.free(url);
    const headers = if (cookie) |value| &[_]http.Header{.{ .name = "cookie", .value = value }} else &[_]http.Header{};
    var response = try http.get(allocator, client, url, headers);
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const api_response = (root.get("response") orelse return null).object;
    const sections = (api_response.get("sections") orelse return null).array;
    if (sections.items.len < 2) return null;
    const hits = (sections.items[1].object.get("hits") orelse return null).array;
    if (hits.items.len == 0) return null;
    const result = (hits.items[0].object.get("result") orelse return null).object;
    const lyrics_url = jsonString(result.get("url")) orelse return null;

    var page = try http.get(allocator, client, lyrics_url, &.{});
    defer page.deinit(allocator);
    if (page.status != .ok) return null;

    const text = try extractLyricsContainers(allocator, page.body);
    if (text.len == 0) {
        allocator.free(text);
        return null;
    }
    return .{ .unsynced = text };
}

fn extractLyricsContainers(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    var first = true;
    while (std.mem.indexOfPos(u8, html, pos, "data-lyrics-container=\"true\"")) |attr| {
        const open_start = lastIndexOfBefore(html, '<', attr) orelse break;
        const open_end = std.mem.indexOfScalarPos(u8, html, attr, '>') orelse break;
        const close = std.mem.indexOfPos(u8, html, open_end, "</div>") orelse break;
        _ = open_start;
        const decoded = try utils.htmlTextDecode(allocator, html[open_end + 1 .. close]);
        defer allocator.free(decoded);
        if (!first) try out.appendSlice(allocator, "\n");
        first = false;
        try out.appendSlice(allocator, std.mem.trim(u8, decoded, " \n\t\r"));
        pos = close + 6;
    }
    return out.toOwnedSlice(allocator);
}

fn lastIndexOfBefore(haystack: []const u8, needle: u8, end: usize) ?usize {
    var i = end;
    while (i > 0) {
        i -= 1;
        if (haystack[i] == needle) return i;
    }
    return null;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}
