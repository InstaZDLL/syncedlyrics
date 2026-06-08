# syncedlyrics

Zig library and CLI for finding synchronized LRC lyrics or plaintext lyrics from a track query. This repository is now the Zig implementation intended for integration in waveflow.

## Status

This is a functional Zig port of the useful public behavior from the previous Python project.

Implemented behavior:

- free-form search query, for example `"bad guy billie eilish"`
- synced LRC preferred by default, with plaintext fallback
- plaintext-only and synced-only modes
- provider selection
- Musixmatch translation language option
- Musixmatch enhanced word-level lyrics option
- CLI and importable Zig library API

This is not an internal 1:1 rewrite of the Python code. The Zig version does not use Python libraries. It uses Zig-native HTTP, JSON parsing, memory ownership, targeted HTML extraction, and a lightweight search-result scoring implementation.

## Providers

Implemented providers:

| Provider | Support | Notes |
| --- | --- | --- |
| Musixmatch | Yes | Supports `lang` and `enhanced` |
| Lrclib | Yes | Synced and plaintext lyrics |
| NetEase | Yes | Synced lyrics when available |
| Megalobiz | Yes | HTML extraction, fragile if upstream HTML changes |
| Genius | Yes | Plaintext lyrics |

Not implemented:

| Provider | Reason |
| --- | --- |
| Deezer | The previous Python provider was marked broken |
| Lyricsify | The previous Python provider was blocked by Cloudflare |
| Spotify | The previous Python provider was TODO/unimplemented |

## Requirements

- Zig `0.16.0`
- Network access for live provider requests

## Build

```sh
zig build test
zig build
```

Build a release binary:

```sh
zig build -Doptimize=ReleaseSafe
```

The CLI binary is written to:

```sh
zig-out/bin/syncedlyrics-zig
```

## CLI

Run through the build system:

```sh
zig build run -- "bad guy billie eilish" --no-output
zig build run -- "bad guy billie eilish" --no-output -p lrclib
zig build run -- "bad guy billie eilish" --plain-only -p genius
zig build run -- "bad guy billie eilish" --sync -p lrclib
```

Run a compiled binary:

```sh
./zig-out/bin/syncedlyrics-zig "bad guy billie eilish" --no-output
```

CLI options:

| Flag | Description |
| --- | --- |
| `-p` | Providers: `musixmatch`, `lrclib`, `netease`, `megalobiz`, `genius` |
| `-l`, `--lang` | Musixmatch translation language code |
| `-o`, `--output` | Save lyrics to path, default: `{search_term}.lrc` |
| `--no-output` | Print only, do not write a `.lrc` file |
| `-v`, `--verbose` | Show provider progress |
| `--plain-only`, `--plaintext-only` | Only return plaintext lyrics |
| `--synced-only`, `--synced`, `--sync` | Only return synced lyrics |
| `--enhanced` | Prefer Musixmatch word-level enhanced LRC |

## Zig Library API

The package exposes a Zig module named `syncedlyrics`.

```zig
const std = @import("std");
const syncedlyrics = @import("syncedlyrics");

pub fn example(io: std.Io, allocator: std.mem.Allocator) !void {
    const result = try syncedlyrics.search(allocator, .{
        .io = io,
        .search_term = "bad guy billie eilish",
        .target_type = .prefer_synced,
        .providers = &.{ .lrclib },
    });
    defer if (result) |lyrics| allocator.free(lyrics);

    if (result) |lyrics| {
        std.debug.print("{s}\n", .{lyrics});
    }
}
```

Use `searchLyrics` when Waveflow needs to access time-aligned synced lyrics and plain-text lyrics as separate values:

```zig
var result = try syncedlyrics.searchLyrics(allocator, .{
    .io = io,
    .search_term = "bad guy billie eilish",
});
defer if (result) |*lyrics| lyrics.deinit(allocator);
```

Returned strings are allocated with the caller-provided allocator and must be freed by the caller.

## Integrating In Waveflow

Add this repository as a local Zig dependency from waveflow, then import the exposed module named `syncedlyrics`.

The library requires a `std.Io` handle in `SearchOptions` because Zig `0.16.0` makes I/O explicit. In a CLI or app entrypoint, this is usually `init.io`.

Musixmatch token caching defaults to `.zig-syncedlyrics-cache/` relative to the working directory. For waveflow, pass `.cache_dir` in `SearchOptions` to use an application-controlled cache directory.

Genius and NetEase can be used without embedded cookies. If a deployment needs provider cookies, pass `.genius_cookie` or `.netease_cookie` in `SearchOptions`. The CLI also reads optional `SYNCEDLYRICS_GENIUS_COOKIE` and `SYNCEDLYRICS_NETEASE_COOKIE` environment variables.

## Tests

Unit tests:

```sh
zig build test
```

Smoke test a live provider:

```sh
zig build run -- "bad guy billie eilish" --no-output -p lrclib
```

Provider smoke commands hit third-party services. Failures can come from network issues, upstream changes, rate limits, or provider anti-bot behavior.

## License

MIT. See `LICENSE`.
