const std = @import("std");

pub const utils = @import("utils.zig");
const providers_mod = @import("providers/mod.zig");

pub const Lyrics = utils.Lyrics;
pub const TargetType = utils.TargetType;
pub const Provider = providers_mod.Provider;

pub const SearchOptions = struct {
    io: std.Io,
    search_term: []const u8,
    target_type: TargetType = .prefer_synced,
    providers: []const Provider = &.{},
    lang: ?[]const u8 = null,
    enhanced: bool = false,
    cache_dir: ?[]const u8 = null,
    verbose: bool = false,
};

pub fn search(allocator: std.mem.Allocator, options: SearchOptions) !?[]u8 {
    var lyrics = try searchLyrics(allocator, options) orelse return null;
    defer lyrics.deinit(allocator);
    return try lyrics.toString(allocator, options.target_type);
}

pub fn searchLyrics(allocator: std.mem.Allocator, options: SearchOptions) !?Lyrics {
    var aggregate: Lyrics = .{};
    errdefer aggregate.deinit(allocator);

    const selected = if (options.providers.len == 0) providers_mod.default_providers[0..] else options.providers;
    for (selected) |provider| {
        if (options.verbose) std.debug.print("Looking for lyrics on {s}\n", .{provider.name()});
        var found = providers_mod.getLyrics(allocator, provider, options) catch |err| {
            if (options.verbose) std.debug.print("Provider {s} failed: {s}\n", .{ provider.name(), @errorName(err) });
            if (options.lang != null and provider != .musixmatch) continue;
            continue;
        };
        if (found) |*lyrics| {
            defer lyrics.deinit(allocator);
            try aggregate.updateMove(allocator, lyrics);
            if (aggregate.isPreferred(options.target_type)) break;
        }
    }

    if (!aggregate.isAcceptable(options.target_type)) {
        aggregate.deinit(allocator);
        return null;
    }
    return aggregate;
}

test {
    _ = utils;
    _ = providers_mod;
}
