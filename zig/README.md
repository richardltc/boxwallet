# BoxWallet — Zig port (vertical slice)

A proof-of-concept port of BoxWallet's **coin backends** from Go to Zig 0.16.
Two coins (**Nexa** and **Divi**) are wired end to end to validate the
architecture and the (still-churning) Zig 0.16 stdlib before porting the
remaining ~24 coins. Each coin is a self-contained file under `src/coins/`;
adding one is the file plus a few registration lines in `app.zig`. The Go
project at the repo root is untouched and still builds.

The frontend is a TUI built on [**ZigZag**](https://github.com/meszmate/zigzag)
(an Elm-architecture framework, à la Bubble Tea); there is **no web frontend**.
Because the backend exposes a coin-agnostic `Coin` interface, the TUI consumes
it without knowing which coin it's driving.

## Layout

| File | Role |
|------|------|
| `src/coin.zig` | `Coin` vtable interface — the Zig equivalent of Go's `Coin` interface in `coins.go`. Frontends hold a `Coin` and never know the concrete type. |
| `src/models.zig` | `CoinAuth`, raw per-coin JSON-RPC result structs, and the normalized `BlockchainState` a frontend renders. |
| `src/rpc.zig` | JSON-RPC over `std.http.Client` (basic auth, `text/plain` body) — matches the Go request shape. |
| `src/coins/nexa.zig` | Nexa backend: constants from the Go source + `blockchainState` / `install` / `isInstalled`, wired into the `Coin` vtable. |
| `src/coins/divi.zig` | Divi backend — same shape as `nexa.zig`, modeled on it. A self-contained coin file: everything Divi-specific (download URL, archive layout, RPC mapping) lives here and nowhere else. |
| `src/install.zig` | Shared download + unarchive: HTTP GET → in-memory → `flate` gunzip → `std.tar.extract`, then `promoteAndTidy` lifts the daemon/cli/tx binaries out of the extracted `<coin>-<ver>/bin/` to the install root and deletes the wrapper dir. `extractArchive`/`promoteAndTidy`/`installRoot` are split out so they're unit-tested without network. |
| `src/app.zig` | ZigZag master/detail TUI: left nav column (Home + coins), right detail pane rendered generically through the `Coin` interface (no per-coin UI code). |
| `src/main.zig` | Entry point: hands ZigZag's `Program(App)` the 0.16 `std.process.Init`. |
| `src/testdata/fixture.tar.gz` | Tiny archive fixture for the extraction test. |

## Dependencies

- [`zigzag`](https://github.com/meszmate/zigzag) — TUI framework, added via
  `zig fetch --save git+https://github.com/meszmate/zigzag#main`.

## Build & run

```sh
zig build test    # offline unit tests (no daemon, no terminal needed)
zig build run     # launches the TUI
```

Outlook-style layout: navigate the left column with `up`/`down` (or `j`/`k`),
press `i` to install the selected coin's daemon, `q` to quit.

```
> Home         │ BoxWallet
  NEXA         │
  DIVI         │ Select a coin on the left to manage it.
```

Selecting a coin (e.g. **NEXA** or **DIVI**) shows its detail pane with an
`[ Install ]` action. Pressing `i` downloads that coin's daemon tarball and
unarchives it into the per-platform BoxWallet data dir — `~/.boxwallet` on
Linux/macOS, `%USERPROFILE%\AppData\Roaming\BoxWallet` on Windows — resolved
from the home dir ZigZag captures at startup (`ctx.home_dir`). The path is shown
in the detail pane. Coin tarballs wrap everything in a versioned `<coin>-<ver>/`
dir with binaries under `bin/`, so after extraction the daemon/cli/tx binaries
are lifted to the data dir's root and the whole wrapper dir is removed. When the
daemon is already present the action becomes `[ Update ]` (a re-download over the
existing files). The install is synchronous for now, so the UI blocks during the
download.

The detail pane is rendered entirely through the `Coin` interface, so a newly
registered coin appears and renders with no UI changes.

## Releasing (and the in-app auto-updater)

BoxWallet updates itself in-app — no separate updater. On launch it applies any
update staged by a previous session (swapping the running binary and re-execing
into it); while running, a background worker checks GitHub for a newer release,
and if found downloads + SHA-256-verifies it and stages it for next launch. The
swap targets the **actual running executable** (`std.process.executablePathAlloc`
→ `/proc/self/exe` on Linux), wherever the user runs BoxWallet from, and keeps
their chosen filename — `~/.boxwallet/updates/` is only the verified-download
cache. See `src/update.zig`; the apply/re-exec is in `src/main.zig`, the
background check + Home-pane notice in `src/app.zig`.

Build all distributable binaries locally on one Linux host (Zig cross-compiles
every target with no external toolchain):

```sh
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build release
```

This writes `zig-out/release/` with the binaries **named exactly as the updater
downloads them** plus a `SHA256SUMS` it verifies against:

```
boxwallet-linux-x86_64        (static musl — runs on any glibc)
boxwallet-linux-aarch64       (static musl)
boxwallet-macos-x86_64
boxwallet-macos-aarch64
boxwallet-windows-x86_64.exe
SHA256SUMS
```

Built `ReleaseSafe` + stripped (~1.5 MB each). To cut a release: bump
`app_version` in `src/app.zig`, run `zig build release`, then upload **all six
files** to the matching GitHub release (`tag_name` is compared against
`app_version`). The asset names and `SHA256SUMS` are generated from one target
list in `build.zig`, so they can't drift from the updater's expectations.

If BoxWallet is installed where the user can't write (e.g. a root-owned
`/usr/local/bin` run unprivileged), the swap can't happen; the Home pane says so
rather than promising a restart that wouldn't take.

## What this validates

- **ZigZag integrates on 0.16** — `Program(App).init(gpa, io, environ_map)` driven from `main(init: std.process.Init)`.
- **`std.http.Client`** works on 0.16's new `std.Io` interface (the riskiest dependency).
- **`std.json`** parses daemon replies into typed structs (`ignore_unknown_fields`).
- **Archive extraction** — `flate` gunzip + `std.tar.extract` with `strip_components`, proven on a real fixture (no network).
- **Vtable interface** cleanly decouples the TUI from concrete coins (spanning metadata, RPC *and* install) — proven by **two coins** (Nexa, Divi) where the TUI renders both with zero per-coin UI code.
- **Per-coin isolation** — each coin is one self-contained file; Divi was added without touching Nexa or the shared download/RPC/render code beyond registration.
- **Normalized models** (`BlockchainState`) keep per-coin JSON shapes out of the TUI.

## Zig 0.16 API notes (gotchas hit during this slice)

These changed from older Zig and bit us — worth knowing before scaling up:

- `b.standardOptimizeOptions` → **`b.standardOptimizeOption`** (singular).
- `std.heap.GeneralPurposeAllocator` → **`std.heap.DebugAllocator`**.
- `std.http.Client` now requires an **`.io`** field — construct one via
  `std.Io.Threaded.init(allocator, .{})` then `.io()`.
- HTTP response bodies are captured with **`std.Io.Writer.Allocating`**
  passed as `response_writer`; read back with `.toOwnedSlice()` / `.written()`.
- Stdout is **`std.Io.File.stdout()`**; writes take an `io`:
  `file.writeStreamingAll(io, bytes)`.
- `std.process.getEnvVarOwned` and `std.posix.getenv` are **gone** — env/args
  now flow into `main` via a `std.process.Init` struct
  (`init.gpa`, `init.io`, `init.environ_map`, `init.args`). Signature is
  `pub fn main(init: std.process.Init) !void`. ZigZag's `Program.init` takes
  exactly these, so the TUI entry point gets the allocator + io for free.

## Still to figure out before the full port

- **`.zip` extraction** (`std.zip`) — Windows bundles; only `.tar.gz` is wired so far.
- **Async install** — the download currently blocks the UI thread; move it to a ZigZag `Cmd` with progress.
- **Process enumeration** (`FindProcess`/`DaemonRunning`): no stdlib equivalent;
  Linux `/proc` scan, cross-platform is more work.
- **Config file** read/write (replaces viper).
