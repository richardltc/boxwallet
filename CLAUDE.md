# CLAUDE.md

## What this project is

BoxWallet is being **rewritten from Go to Zig**. The Zig rewrite lives in `zig/`
and uses [ZigZag](https://github.com/meszmate/zigzag) for its TUI — there is **no
web frontend**. The end goal is a complete, idiomatic **Zig 0.16** port of the Go
application, one coin at a time.

BoxWallet is **cross-platform**: it must build and run on **Linux, Windows, and
macOS**. Keep new code portable — no OS-specific assumptions about paths, line
endings, binary names, or environment. Where behaviour genuinely differs per OS
(e.g. install destination, daemon/cli/tx filenames), branch on the platform
rather than hard-coding one OS, and follow the existing patterns (the install
root resolves to a per-platform `~/.boxwallet`; coins declare their own binary
filenames). Don't reach for POSIX-only or Windows-only APIs when a portable
stdlib equivalent exists.

## Memory is a first-class constraint

BoxWallet is likely to run on **low-spec machines** (single-board computers, old
hardware, low-RAM VPSes), so **keeping peak memory small is a priority on par
with correctness.** When a design choice trades RAM against disk or CPU, prefer
the one that holds less in memory unless told otherwise.

- **Stream, don't buffer.** Process data in bounded chunks straight from source
  to destination rather than reading whole files / HTTP responses / archives
  into memory. The install path is the worked example: it streams the download
  to a scratch file and pipes gunzip → untar straight to disk, so neither the
  compressed archive nor the decompressed tree is ever fully resident (see
  `zig/src/install.zig`). Peak install memory is a few fixed buffers plus the
  gzip window — flat regardless of bundle size.
- Prefer fixed, modest stack/heap buffers over `Allocating` writers that grow to
  hold an entire payload.
- Free as you go; don't keep large slices alive longer than needed.
- New code (RPC bodies, JSON parsing, UI state, future coins) should follow the
  same rule: bound the working set, don't slurp.

## Default working mode — read this first

- **Work in `zig/`. The Go code is reference only.** All new work happens under
  `zig/src/`.
- **Do not modify the Go code** (`cmd/`, `pkg/`, `ui/`, root `*.go`, `go.mod`,
  etc.) unless I explicitly ask. The Go app still builds and is the behavioural
  spec the port is measured against.
- When porting something: find the Go implementation, understand *what it does*,
  then write clean idiomatic Zig. **Match the behaviour, not the line-by-line
  structure** — don't transliterate Go patterns into Zig.
- If a task doesn't say which side (Go or Zig), assume **Zig**.

## The per-coin rule (important)

Each coin is **one self-contained file**: `zig/src/coins/<coin>.zig`. Everything
specific to that coin lives there and nowhere else:

- Constants — coin name/abbrev, conf file, RPC default user/port, core version,
  daemon/cli/tx filenames.
- Download URL(s) and the **install flow** for that coin (which binaries to
  promote out of the archive's `bin/`, and what to clean up).
- The coin's JSON-RPC result structs and the mapping to the normalized model.
- Its `Coin` vtable wiring (`pub fn coin(self) Coin`).

Nexa-specific code goes in `nexa.zig`; Divi-specific code goes in `divi.zig`;
**coins never reference each other.** `src/coins/nexa.zig` is the reference
implementation — copy its shape for new coins.

**Shared mechanics are not duplicated per coin** — they live in the shared
modules below, and coins call into them with their own parameters:

| Module | Holds |
|---|---|
| `zig/src/coin.zig` | The polymorphic `Coin` vtable interface (Go's `Coin` interface). |
| `zig/src/install.zig` | Generic streaming download → gunzip+untar (constant memory), `promoteAndTidy`, and `installRoot` (cross-platform `~/.boxwallet`). |
| `zig/src/rpc.zig` | JSON-RPC transport over `std.http.Client` (basic auth). |
| `zig/src/models.zig` | Shared/normalized models (`CoinAuth`, `BlockchainState`). Per-coin raw RPC structs may live here or in the coin file. |
| `zig/src/app.zig` | The ZigZag TUI (master/detail). The one place coins are wired into the UI. |
| `zig/src/main.zig` | Entry point + the offline test import block. |

If you find yourself adding coin-specific logic to a shared module, that's the
signal to stop: the coin-specific part belongs in the coin file, and only a
generic, parameterized helper belongs in the shared module.

## Adding / porting a coin

1. Create `zig/src/coins/<coin>.zig` modeled on `nexa.zig`.
2. Port constants, download/install flow, and RPC mapping from
   `cmd/cli/cmd/coins/<coin>/<coin>.go`.
3. Wire the coin's vtable.
4. Register it in `src/app.zig`: add to the `Entry` enum, the `coin_entries`
   list (position doesn't matter — the left bar is sorted alphabetically at
   comptime, with Home pinned on top), the `App` struct field, and the
   `selectedCoin` dispatch.
5. Add it to the `test { ... }` import block in `src/main.zig`.
6. Add **offline** unit tests (RPC parse/map; install path logic). No daemon, no
   terminal, no network.

## Build, test, run

From the `zig/` directory:

```sh
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build test   # offline unit tests
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build         # build the binary
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build run     # launch the TUI
```

- The ZigZag dependency is vendored under `zig/zig-pkg/`;
  `ZIG_GLOBAL_CACHE_DIR=zig-pkg` points the build at it (reproducible / offline).
  A plain `zig build` would otherwise fetch it from the network.
- Manage dependencies with `zig fetch --save …` plus the build.zig wiring.
  **Don't hand-edit anything under `zig-pkg/`.**
- Treat work as **done only when `zig build` and `zig build test` both pass.**

## Conventions

- Toolchain is **Zig 0.16**. See `zig/README.md` → "Zig 0.16 API notes" for the
  stdlib gotchas hit so far (new `std.Io`, `std.process.Init`, `flate`, etc.).
  The stdlib is still churning; verify APIs against the installed std rather than
  assuming older signatures.
- Install destination: per-platform `~/.boxwallet` (Windows
  `%USERPROFILE%\AppData\Roaming\BoxWallet`), resolved via
  `install.installRoot(ctx.home_dir)` — ZigZag captures the home dir for us.
- Install flow: `downloadAndExtract` then `promoteAndTidy` — the archive is
  streamed to a scratch file on disk, then extracted straight to disk (constant
  memory, no whole-archive buffer in RAM). Linux/macOS bundles are `.tar.gz` and
  run a streaming gunzip → untar pipeline; Windows bundles are `.zip`, which
  can't stream (its directory sits at EOF), so it's extracted via `std.zip` from
  the seekable scratch file — still flat memory (a deflate window + read buffer).
  Coin archives nest binaries in `bin/` identically on every platform, so the
  daemon/cli/tx binaries are lifted to the install root and the rest of the
  extracted tree is discarded. Each coin declares its own promote/cleanup lists.
- Cross-platform downloads: each coin selects its download URL + archive format
  at **comptime** from `builtin.os.tag`/`builtin.cpu.arch` (a nullable
  `install.Download`; null = no upstream binary for that target, surfaced as
  `error.UnsupportedPlatform` at install time). Binary names get a `.exe` suffix
  on Windows. Match the Go installer's `runtime.GOOS`/`GOARCH` switch, and note
  upstream gaps — e.g. Divi has no native Apple-Silicon build, so macOS arm64
  uses the Intel `osx64` build (runs under Rosetta 2), and Divi linux-arm64 is
  unsupported.
- Starting the daemon (`app.zig` `launchDaemon`): POSIX uses `-daemon` (the
  launcher forks + exits; we wait on it and confirm liveness). Windows daemons
  don't support `-daemon`, so they're spawned **detached** without waiting
  (mirrors Go's `cmd /C start /b`); the status poll confirms the daemon came up.
- Left nav order: **Home is pinned to the top** of the left column; coins follow
  in **alphabetical order by label**. `app.zig` builds `entries` by
  comptime-sorting `coin_entries`, so registering a coin doesn't require placing
  it by hand — add it anywhere in `coin_entries` and it sorts into place.
- Match the surrounding code's comment density, naming, and idioms.

## Go → Zig reference map

| Need | Go (reference, don't edit) | Zig (edit here) |
|---|---|---|
| Coin interface | `cmd/cli/cmd/coins/coins.go` | `zig/src/coin.zig` |
| A coin backend | `cmd/cli/cmd/coins/<coin>/<coin>.go` | `zig/src/coins/<coin>.zig` |
| Download / unarchive / install | per-coin `DownloadCoin` / `Install` | `zig/src/install.zig` + per-coin lists |
| RPC calls | per-coin HTTP in `<coin>.go` | `zig/src/rpc.zig` + per-coin structs |
| UI / command flow | `ui/`, `cmd/cli/cmd/*` | `zig/src/app.zig` (ZigZag) |

## Port status

- **Ported:** nexa, divi.
- **Remaining (24):** badcoin, bitcoinplus, bitcoinz, denarius, devault,
  digibyte, dogecash, epic, feathercoin, groestlcoin, litecoin, navcoin,
  peercoin, phore, pivx, primecoin, rapids, reddcoin, scala, spiderbyte, syscoin,
  trezarcoin, vertcoin, zano.
