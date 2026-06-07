const std = @import("std");
const http = @import("../http.zig");
const utils = @import("../utils.zig");

pub fn getLyrics(allocator: std.mem.Allocator, client: *std.http.Client, search_term: []const u8) !?utils.Lyrics {
    const encoded = try utils.urlEncode(allocator, search_term);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://www.megalobiz.com/search/all?qry={s}&searchButton.x=0&searchButton.y=0", .{encoded});
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    const href = try bestLrcHref(allocator, response.body, search_term) orelse return null;
    defer allocator.free(href);
    const page_url = try std.fmt.allocPrint(allocator, "https://www.megalobiz.com{s}", .{href});
    defer allocator.free(page_url);

    var page = try http.get(allocator, client, page_url, &.{});
    defer page.deinit(allocator);
    if (page.status != .ok) return null;

    const id_start = (std.mem.lastIndexOfScalar(u8, href, '.') orelse return null) + 1;
    const raw = try extractDetailsDiv(allocator, page.body, href[id_start..]) orelse return null;
    defer allocator.free(raw);
    var lyrics: utils.Lyrics = .{};
    errdefer lyrics.deinit(allocator);
    try lyrics.addUnknown(allocator, raw);
    return lyrics;
}

fn bestLrcHref(allocator: std.mem.Allocator, html: []const u8, search_term: []const u8) !?[]u8 {
    var best_href: ?[]u8 = null;
    var best_score: f64 = -1;
    errdefer if (best_href) |href| allocator.free(href);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "href=\"/lrc/maker/")) |href_attr| {
        const href_start = href_attr + "href=\"".len;
        const href_end = std.mem.indexOfScalarPos(u8, html, href_start, '"') orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, html, href_end, '>') orelse break;
        const close = std.mem.indexOfPos(u8, html, tag_end, "</a>") orelse break;
        const decoded = try utils.htmlTextDecode(allocator, html[tag_end + 1 .. close]);
        defer allocator.free(decoded);
        const label = try megalobizComparableText(allocator, decoded, search_term);
        defer allocator.free(label);
        const score = try utils.strScore(allocator, label, search_term);
        if (score > best_score) {
            if (best_href) |old| allocator.free(old);
            best_href = try allocator.dupe(u8, html[href_start..href_end]);
            best_score = score;
        }
        pos = close + 4;
    }

    if (best_score < 65) {
        if (best_href) |old| allocator.free(old);
        return null;
    }
    return best_href;
}

fn megalobizComparableText(allocator: std.mem.Allocator, text: []const u8, search_term: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, text, " \n\t\r");
    const max_words = std.mem.count(u8, search_term, " ") + 1;
    var count: usize = 0;
    while (it.next()) |tok| {
        if (count >= max_words) break;
        if (std.mem.eql(u8, tok, "by")) continue;
        if (count > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, tok);
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn extractDetailsDiv(allocator: std.mem.Allocator, html: []const u8, lrc_id: []const u8) !?[]u8 {
    const marker = try std.fmt.allocPrint(allocator, "id=\"lrc_{s}_details\"", .{lrc_id});
    defer allocator.free(marker);
    const attr_start = std.mem.indexOf(u8, html, marker) orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, html, attr_start, '>') orelse return null;
    const close = std.mem.indexOfPos(u8, html, open_end, "</div>") orelse return null;
    const decoded = try utils.htmlTextDecode(allocator, html[open_end + 1 .. close]);
    defer allocator.free(decoded);
    return try allocator.dupe(u8, std.mem.trim(u8, decoded, " \n\t\r"));
}
