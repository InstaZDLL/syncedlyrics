const std = @import("std");
const root = @import("../root.zig");
const utils = @import("../utils.zig");

const lrclib = @import("lrclib.zig");
const musixmatch = @import("musixmatch.zig");
const netease = @import("netease.zig");
const genius = @import("genius.zig");
const megalobiz = @import("megalobiz.zig");

pub const Provider = enum {
    musixmatch,
    lrclib,
    netease,
    megalobiz,
    genius,

    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .musixmatch => "Musixmatch",
            .lrclib => "Lrclib",
            .netease => "NetEase",
            .megalobiz => "Megalobiz",
            .genius => "Genius",
        };
    }

    pub fn parse(value: []const u8) ?Provider {
        if (std.ascii.eqlIgnoreCase(value, "musixmatch")) return .musixmatch;
        if (std.ascii.eqlIgnoreCase(value, "lrclib")) return .lrclib;
        if (std.ascii.eqlIgnoreCase(value, "netease")) return .netease;
        if (std.ascii.eqlIgnoreCase(value, "megalobiz")) return .megalobiz;
        if (std.ascii.eqlIgnoreCase(value, "genius")) return .genius;
        return null;
    }
};

pub const default_providers = [_]Provider{ .musixmatch, .lrclib, .netease, .megalobiz, .genius };

pub fn getLyrics(allocator: std.mem.Allocator, provider: Provider, options: root.SearchOptions) !?utils.Lyrics {
    var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
    defer client.deinit();
    return switch (provider) {
        .musixmatch => musixmatch.getLyrics(allocator, &client, options),
        .lrclib => lrclib.getLyrics(allocator, &client, options.search_term),
        .netease => netease.getLyrics(allocator, &client, options.search_term, options.netease_cookie),
        .megalobiz => megalobiz.getLyrics(allocator, &client, options.search_term),
        .genius => genius.getLyrics(allocator, &client, options.search_term, options.genius_cookie),
    };
}
