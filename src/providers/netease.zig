const std = @import("std");
const http = @import("../http.zig");
const utils = @import("../utils.zig");

const cookie =
    "NMTID=00OAVK3xqDG726ITU6jopU6jF2yMk0AAAGCO8l1BA; " ++
    "JSESSIONID-WYYY=8KQo11YK2GZP45RMlz8Kn80vHZ9%2FGvwzRKQXXy0iQoFKycWdBlQjbfT0MJrFa6hwRfmpfBYKeHliUPH287JC3hNW99WQjrh9b9RmKT%2Fg1Exc2VwHZcsqi7ITxQgfEiee50po28x5xTTZXKoP%2FRMctN2jpDeg57dZrXz%2FD%2FWghb%5C4DuZ%3A1659124633932; " ++
    "_iuqxldmzr_=32; playerid=94262567";

pub fn getLyrics(allocator: std.mem.Allocator, client: *std.http.Client, search_term: []const u8) !?utils.Lyrics {
    const encoded = try utils.urlEncode(allocator, search_term);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://music.163.com/api/search/pc?limit=10&type=1&offset=0&s={s}", .{encoded});
    defer allocator.free(url);

    var response = try http.get(allocator, client, url, &.{
        .{ .name = "cookie", .value = cookie },
    });
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const result = (root.get("result") orelse return null).object;
    const songs = (result.get("songs") orelse return null).array;
    if (songs.items.len == 0) return null;

    var best_index: ?usize = null;
    var best_score: f64 = -1;
    for (songs.items, 0..) |song, i| {
        const obj = song.object;
        const name = jsonString(obj.get("name")) orelse "";
        var artist: []const u8 = "";
        if (obj.get("artists")) |artists_v| {
            const artists = artists_v.array;
            if (artists.items.len > 0) artist = jsonString(artists.items[0].object.get("name")) orelse "";
        }
        const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, artist });
        defer allocator.free(label);
        const score = try utils.strScore(allocator, label, search_term);
        if (score > best_score) {
            best_score = score;
            best_index = i;
        }
    }
    const index = best_index orelse return null;
    if (best_score < 65) return null;
    const id = songs.items[index].object.get("id") orelse return null;
    const id_text = switch (id) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .number_string => |v| try allocator.dupe(u8, v),
        .string => |v| try allocator.dupe(u8, v),
        else => return null,
    };
    defer allocator.free(id_text);
    return getLyricsById(allocator, client, id_text);
}

fn getLyricsById(allocator: std.mem.Allocator, client: *std.http.Client, track_id: []const u8) !?utils.Lyrics {
    const url = try std.fmt.allocPrint(allocator, "https://music.163.com/api/song/lyric?id={s}&lv=1", .{track_id});
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{
        .{ .name = "cookie", .value = cookie },
    });
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const lrc_obj = (obj.get("lrc") orelse return null).object;
    var lyrics: utils.Lyrics = .{};
    errdefer lyrics.deinit(allocator);
    try lyrics.addUnknown(allocator, jsonString(lrc_obj.get("lyric")));
    return lyrics;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}
