const std = @import("std");
const http = @import("../http.zig");
const utils = @import("../utils.zig");

pub fn getLyrics(allocator: std.mem.Allocator, client: *std.http.Client, search_term: []const u8) !?utils.Lyrics {
    const encoded = try utils.urlEncode(allocator, search_term);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://lrclib.net/api/search?q={s}", .{encoded});
    defer allocator.free(url);

    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const array = parsed.value.array;
    if (array.items.len == 0) return null;

    var best_index: usize = 0;
    var best_score: f64 = -1;
    var best_cluster_count: usize = 0;
    var best_has_synced = false;
    for (array.items, 0..) |item, i| {
        const obj = item.object;
        const artist = jsonString(obj.get("artistName")) orelse "";
        const track = jsonString(obj.get("trackName")) orelse "";
        const synced = jsonString(obj.get("syncedLyrics")) != null;
        const label = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ artist, track });
        defer allocator.free(label);
        const score = try utils.strScore(allocator, label, search_term);
        const cluster_count = try countSimilarArtistMatches(allocator, array.items, artist, track, search_term);
        if (isBetterCandidate(score, synced, cluster_count, best_score, best_has_synced, best_cluster_count)) {
            best_score = score;
            best_index = i;
            best_cluster_count = cluster_count;
            best_has_synced = synced;
        }
    }

    const best = array.items[best_index].object;
    const id_value = best.get("id") orelse return null;
    const id = switch (id_value) {
        .integer => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .number_string => |v| try allocator.dupe(u8, v),
        .string => |v| try allocator.dupe(u8, v),
        else => return null,
    };
    defer allocator.free(id);
    return getLyricsById(allocator, client, id);
}

fn isBetterCandidate(
    score: f64,
    has_synced: bool,
    cluster_count: usize,
    best_score: f64,
    best_has_synced: bool,
    best_cluster_count: usize,
) bool {
    if (score > best_score + 0.001) return true;
    if (@abs(score - best_score) > 0.001) return false;
    if (has_synced != best_has_synced) return has_synced;
    return cluster_count > best_cluster_count;
}

fn countSimilarArtistMatches(
    allocator: std.mem.Allocator,
    items: []const std.json.Value,
    artist: []const u8,
    track: []const u8,
    search_term: []const u8,
) !usize {
    var count: usize = 0;
    for (items) |item| {
        const obj = item.object;
        const other_artist = jsonString(obj.get("artistName")) orelse "";
        const other_track = jsonString(obj.get("trackName")) orelse "";
        if (jsonString(obj.get("syncedLyrics")) == null) continue;
        if (!std.ascii.eqlIgnoreCase(artist, other_artist)) continue;
        if (try utils.strScore(allocator, other_track, track) < 90) continue;
        if (try utils.strScore(allocator, other_track, search_term) < 90) continue;
        count += 1;
    }
    return count;
}

fn getLyricsById(allocator: std.mem.Allocator, client: *std.http.Client, track_id: []const u8) !?utils.Lyrics {
    const url = try std.fmt.allocPrint(allocator, "https://lrclib.net/api/get/{s}", .{track_id});
    defer allocator.free(url);
    var response = try http.get(allocator, client, url, &.{});
    defer response.deinit(allocator);
    if (response.status != .ok) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var lyrics: utils.Lyrics = .{};
    errdefer lyrics.deinit(allocator);
    if (jsonString(obj.get("syncedLyrics"))) |value| lyrics.synced = try allocator.dupe(u8, value);
    if (jsonString(obj.get("plainLyrics"))) |value| lyrics.unsynced = try allocator.dupe(u8, value);
    return lyrics;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}
