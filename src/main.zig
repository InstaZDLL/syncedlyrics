const std = @import("std");
const syncedlyrics = @import("syncedlyrics");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const parsed = parseArgs(arena, io, init.minimal.environ, args) catch |err| {
        try stderr.print("error: {s}\n\n", .{@errorName(err)});
        try usage(stderr);
        return;
    };

    var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    const result = try syncedlyrics.search(gpa, parsed.options);
    if (result) |lyrics| {
        defer gpa.free(lyrics);
        if (parsed.output_path) |path_template| {
            const path = try expandOutputPath(gpa, path_template, parsed.options.search_term);
            defer gpa.free(path);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = lyrics });
        }
        try stdout.print("{s}\n", .{lyrics});
    } else {
        try stderr.print("No suitable lyrics found for \"{s}\".\n", .{parsed.options.search_term});
    }
}

const ParsedArgs = struct {
    options: syncedlyrics.SearchOptions,
    output_path: ?[]const u8,
};

fn parseArgs(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, args: []const []const u8) !ParsedArgs {
    if (args.len < 2) return error.MissingSearchTerm;

    var providers: std.ArrayList(syncedlyrics.Provider) = .empty;
    errdefer providers.deinit(allocator);

    var output_path: ?[]const u8 = "{search_term}.lrc";
    var lang: ?[]const u8 = null;
    var enhanced = false;
    var verbose = false;
    var target_type: syncedlyrics.TargetType = .prefer_synced;
    var search_term: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingProvider;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "-")) : (i += 1) {
                const provider = syncedlyrics.Provider.parse(args[i]) orelse return error.UnknownProvider;
                try providers.append(allocator, provider);
            }
            i -= 1;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--lang")) {
            i += 1;
            if (i >= args.len) return error.MissingLanguage;
            lang = args[i];
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutput;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--no-output")) {
            output_path = null;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--plain-only") or std.mem.eql(u8, arg, "--plaintext-only")) {
            if (target_type == .synced_only) return error.ConflictingModes;
            target_type = .plaintext;
        } else if (std.mem.eql(u8, arg, "--synced-only") or std.mem.eql(u8, arg, "--synced") or std.mem.eql(u8, arg, "--sync")) {
            if (target_type == .plaintext) return error.ConflictingModes;
            target_type = .synced_only;
        } else if (std.mem.eql(u8, arg, "--enhanced")) {
            enhanced = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (search_term == null) {
            search_term = arg;
        } else {
            return error.TooManySearchTerms;
        }
    }

    return .{
        .options = .{
            .io = io,
            .search_term = search_term orelse return error.MissingSearchTerm,
            .target_type = target_type,
            .providers = try providers.toOwnedSlice(allocator),
            .lang = lang,
            .enhanced = enhanced,
            .genius_cookie = environ.getAlloc(allocator, "SYNCEDLYRICS_GENIUS_COOKIE") catch null,
            .netease_cookie = environ.getAlloc(allocator, "SYNCEDLYRICS_NETEASE_COOKIE") catch null,
            .verbose = verbose,
        },
        .output_path = output_path,
    };
}

fn expandOutputPath(allocator: std.mem.Allocator, template: []const u8, search_term: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var rest = template;
    while (std.mem.indexOf(u8, rest, "{search_term}")) |index| {
        try out.appendSlice(allocator, rest[0..index]);
        try out.appendSlice(allocator, search_term);
        rest = rest[index + "{search_term}".len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: syncedlyrics-zig "SEARCH_TERM" [options]
        \\
        \\Options:
        \\  -p PROVIDER...       Providers: musixmatch, lrclib, netease, megalobiz, genius
        \\  -l, --lang LANG      Musixmatch translation language
        \\  -o, --output PATH    Save lyrics to path, default {search_term}.lrc
        \\  --no-output          Do not write a lyrics file
        \\  --plain-only         Only return plaintext lyrics
        \\  --plaintext-only     Alias for --plain-only
        \\  --synced-only        Only return synced lyrics
        \\  --synced, --sync     Aliases for --synced-only
        \\  --enhanced           Prefer Musixmatch word-level lyrics
        \\  -v, --verbose        Print provider progress
        \\
    );
}

test "expand output path" {
    const allocator = std.testing.allocator;
    const path = try expandOutputPath(allocator, "{search_term}.lrc", "bad guy");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("bad guy.lrc", path);
}
