# Repository Guidelines

## Project Structure & Module Organization

This repository is a Zig project. The public library API lives in `src/root.zig`, CLI parsing and output live in `src/main.zig`, shared helpers live in `src/utils.zig`, and HTTP helpers live in `src/http.zig`. Provider integrations are isolated under `src/providers/`; new providers should be exported through `src/providers/mod.zig` and wired into the provider dispatch there. Package metadata and build steps are declared in `build.zig` and `build.zig.zon`.

## Build, Test, and Development Commands

- `zig build test`: run unit tests.
- `zig build`: build the debug CLI binary.
- `zig build -Doptimize=ReleaseSafe`: build a release-safe binary.
- `zig build run -- "track artist" --no-output`: run the CLI through the build system.
- `zig build run -- "track artist" --no-output --sync -p lrclib`: smoke test one live provider.

## Coding Style & Naming Conventions

Use Zig `0.16.0` syntax and standard formatting. Prefer explicit allocators, clear ownership, and `defer`/`errdefer` cleanup for allocated memory. Return errors with `!T` instead of swallowing failures unless provider fallback behavior explicitly requires continuing. Use `snake_case` for local variables and fields, and keep provider enum names aligned with their public provider identity. Keep network code inside provider modules and use shared helpers from `src/utils.zig` instead of duplicating parsing, scoring, or lyrics-type logic.

## Testing Guidelines

Use Zig's built-in `test` blocks for unit coverage. Keep deterministic helper tests in `src/utils.zig` or near the code they exercise. Provider smoke tests hit live third-party services and may fail because of network issues, upstream changes, rate limits, or anti-bot behavior; run them manually with `zig build run` rather than making flaky provider checks mandatory. When adding unstable providers, document expected limitations and avoid enabling brittle network checks by default.

## Commit & Pull Request Guidelines

Recent commits use short, imperative summaries, for example `Port syncedlyrics to Zig` or `Improve ambiguous Lrclib matching`. Keep commits focused and mention provider names when behavior changes. Pull requests should describe the user-visible change, list affected providers or CLI options, include the test command used, and link related issues. Include screenshots only for documentation or CLI output changes where they clarify behavior.

## Security & Configuration Tips

Do not commit API tokens, cookies, generated lyrics files, local cache data, `.zig-cache/`, or `zig-out/`. Provider cookies must be supplied through configuration such as `SearchOptions` fields or documented environment variables, never embedded as source literals. Logging should avoid exposing private request data.
