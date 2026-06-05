# BoxWallet — Zig port (vertical slice)

A proof-of-concept port of BoxWallet's **coin backends** from Go to Zig 0.16.
This slice covers a single coin (**Nexa**) end to end to validate the
architecture and the (still-churning) Zig 0.16 stdlib before porting the
remaining ~29 coins. The Go project at the repo root is untouched and still
builds.

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
| `src/install.zig` | Shared download + unarchive: HTTP GET → in-memory → `flate` gunzip → `std.tar.extract`. `extractArchive` is split out so the gunzip+untar path is unit-tested without network. |
| `src/app.zig` | ZigZag master/detail TUI: left nav column (Home + coins), right detail pane with an Install action. |
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
               │ Select a coin on the left to manage it.
```

Selecting **NEXA** shows its detail pane with an `[ Install ]` action. Pressing
`i` downloads the daemon tarball and unarchives it into `boxwallet-coins/`
(a future config layer will use `~/.boxwallet`). The install is synchronous for
now, so the UI blocks during the download.

## What this validates

- **ZigZag integrates on 0.16** — `Program(App).init(gpa, io, environ_map)` driven from `main(init: std.process.Init)`.
- **`std.http.Client`** works on 0.16's new `std.Io` interface (the riskiest dependency).
- **`std.json`** parses daemon replies into typed structs (`ignore_unknown_fields`).
- **Archive extraction** — `flate` gunzip + `std.tar.extract` with `strip_components`, proven on a real fixture (no network).
- **Vtable interface** cleanly decouples the TUI from concrete coins (now spanning RPC *and* install).
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
- **Install root** — derive `~/.boxwallet` from `HOME` (via `init.environ_map`) instead of the relative `boxwallet-coins/`.
- **Process enumeration** (`FindProcess`/`DaemonRunning`): no stdlib equivalent;
  Linux `/proc` scan, cross-platform is more work.
- **Config file** read/write (replaces viper).
