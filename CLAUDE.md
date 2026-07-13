# CLAUDE.md

## What this project is

BoxWallet is a multi-coin cryptocurrency wallet manager written in **Zig 0.16**,
using [ZigZag](https://github.com/meszmate/zigzag) for its TUI — there is **no
web frontend**.

BoxWallet is **cross-platform**: it must build and run on **Linux, Windows, and
macOS**. Keep new code portable — no OS-specific assumptions about paths, line
endings, binary names, or environment. Where behaviour genuinely differs per OS
(e.g. install destination, daemon/cli/tx filenames), branch on the platform
rather than hard-coding one OS, and follow the existing patterns (the install
root resolves to a per-platform `~/.boxwallet`; coins declare their own binary
filenames). Don't reach for POSIX-only or Windows-only APIs when a portable
stdlib equivalent exists.

## Security is a first-class constraint

BoxWallet manages **cryptocurrency wallets — real funds and the secrets that
control them** (mnemonic seeds, private keys, wallet passwords). **Security is a
priority on par with correctness.** When a design choice trades safety against
convenience, prefer the safe one unless told otherwise.

- **Guard the secrets.** Seeds, keys, and passwords live in **bounded buffers
  that are wiped (`@memset(..., 0)`) the moment they're no longer needed**, and
  are never held in two places longer than necessary (see how the wallet modal
  copies a password into the worker's buffer, then clears the input). Don't log,
  print, or write secrets to disk. Where a secret *must* touch disk (e.g. the
  Nerva `--generate-from-json` restore spec), treat it as a temp: write it, use
  it, then **overwrite and delete it in a `defer`** so it's gone on every path.
- **Don't lose the user's money to a typo.** Anything that *sets* a new
  credential confirms it (the create/restore flow asks for the password twice and
  refuses to proceed unless they match) — a mistyped password on a fresh wallet
  means the funds are unrecoverable. A wrong password when merely *opening* an
  existing wallet just fails and is retried, so it isn't confirmed.
- **Never create or unlock a wallet silently** — only ever with an explicit,
  user-supplied password.
- **Surface failures honestly.** Don't swallow a daemon/CLI error into a generic
  "failed"; thread the real reason up (see the wallet-op error sink) so the user
  can tell a typo from a stale file from an unreachable service.
- **Bind local services to localhost only.** The daemon and wallet RPC are
  127.0.0.1-bound; keep it that way.

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
  `src/install.zig`). Peak install memory is a few fixed buffers plus the
  gzip window — flat regardless of bundle size.
- Prefer fixed, modest stack/heap buffers over `Allocating` writers that grow to
  hold an entire payload.
- Free as you go; don't keep large slices alive longer than needed.
- New code (RPC bodies, JSON parsing, UI state, future coins) should follow the
  same rule: bound the working set, don't slurp.

## The per-coin rule (important)

Each coin is **one self-contained file**: `src/coins/<coin>.zig`. Everything
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
| `src/coin.zig` | The polymorphic `Coin` vtable interface. |
| `src/install.zig` | Generic streaming download → gunzip+untar (constant memory), `promoteAndTidy`, and `installRoot` (cross-platform `~/.boxwallet`). |
| `src/rpc.zig` | JSON-RPC transport over `std.http.Client` (basic auth). |
| `src/models.zig` | Shared/normalized models (`CoinAuth`, `BlockchainState`). Per-coin raw RPC structs may live here or in the coin file. |
| `src/app.zig` | The ZigZag TUI (master/detail). The one place coins are wired into the UI. |
| `src/main.zig` | Entry point + the offline test import block. |

If you find yourself adding coin-specific logic to a shared module, that's the
signal to stop: the coin-specific part belongs in the coin file, and only a
generic, parameterized helper belongs in the shared module.

## Adding a coin

1. Create `src/coins/<coin>.zig` modeled on `nexa.zig`.
2. Implement constants, download/install flow, and RPC mapping.
3. Wire the coin's vtable.
4. Register it in `src/app.zig`: add to the `Entry` enum, the `coin_entries`
   list (position doesn't matter — the left bar is sorted alphabetically at
   comptime, with Home pinned on top), the `App` struct field, and the
   `selectedCoin` dispatch.
5. Add it to the `test { ... }` import block in `src/main.zig`.
6. Add **offline** unit tests (RPC parse/map; install path logic). No daemon, no
   terminal, no network.

## Build, test, run

From the repo root:

```sh
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build test   # offline unit tests
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build         # build the binary
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build run     # launch the TUI
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build release # cross-build all release binaries + SHA256SUMS
```

- The ZigZag dependency is vendored under `zig-pkg/`;
  `ZIG_GLOBAL_CACHE_DIR=zig-pkg` points the build at it (reproducible / offline).
  A plain `zig build` would otherwise fetch it from the network.
- Manage dependencies with `zig fetch --save …` plus the build.zig wiring.
  **Don't hand-edit anything under `zig-pkg/`.**
- Treat work as **done only when `zig build` and `zig build test` both pass.**
- **Releasing / auto-update:** `zig build release` cross-compiles every
  distributable into `zig-out/release/` (Linux = static musl, all `ReleaseSafe`
  + stripped), named `boxwallet-<os>-<arch>[.exe]` with a `SHA256SUMS`. The app
  self-updates in-app (`src/update.zig` + apply/re-exec in `main.zig` + the
  background check in `app.zig`): to cut a release, bump `app_version` in
  `src/app.zig`, run `zig build release`, and upload all six files to the GitHub
  release. Asset names + checksums come from one list in `build.zig`, so they
  stay in lockstep with what the updater downloads. The swap targets the real
  running executable wherever it lives — not `~/.boxwallet` (only the staging
  cache). Don't rename assets by hand or the updater can't find them.

## Conventions

- Toolchain is **Zig 0.16**. See `README.md` → "Zig 0.16 API notes" for the
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
  `.tar.bz2` is also supported (`Format.tar_bz2`) for coins like Nerva: Zig's
  stdlib has no bzip2, so an in-tree pure-Zig decoder (`src/bzip2.zig`, block-
  bounded memory) bunzips the scratch file to a sibling `.tar` on disk, which is
  then untarred — trading temp disk for bounded RAM. Coin archives usually nest
  binaries in `bin/` (so the daemon/cli/tx are lifted to the install root and the
  rest of the extracted tree discarded), but the promote `bin_subdir` is
  per-coin — Nerva's binaries sit directly under the versioned wrapper, so it
  passes `""`. Each coin declares its own promote/cleanup lists. A coin whose
  bundle isn't a plain `.tar.gz`/`.zip`/`.tar.bz2` (e.g. Zano's AppImage) uses
  `install.downloadFile` (download-only) and unpacks it itself.
- Cross-platform downloads: each coin selects its download URL + archive format
  at **comptime** from `builtin.os.tag`/`builtin.cpu.arch` (a nullable
  `install.Download`; null = no upstream binary for that target, surfaced as
  `error.UnsupportedPlatform` at install time). Binary names get a `.exe` suffix
  on Windows. Note upstream gaps — e.g. Divi has no native Apple-Silicon build,
  so macOS arm64 uses the Intel `osx64` build (runs under Rosetta 2), and Divi
  linux-arm64 is unsupported.
- Starting the daemon (`app.zig` `launchDaemon`): POSIX uses `-daemon` (the
  launcher forks + exits; we wait on it and confirm liveness). Windows daemons
  don't support `-daemon`, and some coins (Ergo/Epic/Nerva/Salvium/Zano) run
  foreground everywhere — those are spawned **detached** and watched briefly
  for an early death, so an init failure is surfaced instead of reading as
  started. Every failed start logs its reason in the action log, sourced from
  the process's stderr (captured to a scratch file), else the coin's own daemon
  log (the optional `daemon_log_file` vtable hook — `debug.log` for
  bitcoin-derived coins, `nerva.log`/`salvium.log`/`zanod.log` for the epee
  family, which reports fatal init errors to its log/stdout, not stderr), else
  the bare exit status.
- Left nav order: **Home is pinned to the top** of the left column; coins follow
  in **alphabetical order by label**. `app.zig` builds `entries` by
  comptime-sorting `coin_entries`, so registering a coin doesn't require placing
  it by hand — add it anywhere in `coin_entries` and it sorts into place.
- **Restore-from-seed always normalizes the seed.** Any wallet restore that takes
  mnemonic words must run them through `models.normalizeSeedWords` (lowercase +
  collapse whitespace) before handing them to the daemon/CLI, so a phrase pasted
  with stray case or double spaces still restores. The seed is a secret — wipe any
  working copy (`@memset(..., 0)`) before freeing. See the note on
  `Coin.ExternalWallet.restore_seed`.
- Match the surrounding code's comment density, naming, and idioms.
- **Don't break other coins** If you need to change code that is being used by another coin, make sure there is no possibility that the other coin functionaility will break.
