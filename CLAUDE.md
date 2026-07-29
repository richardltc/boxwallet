# CLAUDE.md

## What this project is

BoxWallet is a multi-coin cryptocurrency wallet manager written in **Zig 0.16**,
using [ZigZag](https://github.com/meszmate/zigzag) for its TUI — there is **no
web frontend**.

There is also an **optional desktop GUI** (Slint, Linux-only for now) over the
same core: `gui/main.cpp` + `gui/app.slint` drive the `Coin` vtable through the
C ABI in `src/capi.zig` (declared in `include/boxwallet.h`). It is a second
*front-end*, never a second implementation — anything a front-end needs that
isn't presentation belongs in a shared module both can call, not in `app.zig`
(TUI) or `capi.zig` (GUI). `src/proc.zig` (daemon liveness by process name,
start-failure reasons) and `src/warmup.zig` (what a daemon is doing while its
RPC can't answer yet) exist for exactly that reason.

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

## Share the user's data; never break it

BoxWallet deliberately uses each coin daemon's **standard data directory** (the
one it would pick with no `-datadir`), so it shares whatever is already on the
machine. That's the point: a user with an existing node keeps their synced chain
and their wallet shows up, instead of re-syncing hundreds of GB into a second
copy. **A data dir may therefore already belong to another app** — Bitcoin Core,
Divi Desktop, an existing `monerod` — holding a live wallet and a chain that took
days to build.

**Anything already on disk is the other app's property. Share it; never rewrite,
reconfigure, or discard it.** The user's own words: if a wallet is already there
and used by a different app, always respect it and never do anything that may
break it. Concretely:

- **Never make an irreversible change to data that was already there.** The worked
  example is pruning: an unpruned node has no `prune` key *by definition*, so a
  "has the user chosen yet?" check alone reads someone's full node as "never
  asked" and offers to prune it — discarding their blocks with no un-prune short
  of a full re-sync. `pruneShouldOffer` (`bitcoin.zig`/`litecoin.zig`) therefore
  also requires that no chain (`blocks/`) is present. Ask the same question of any
  new destructive action.
- **Don't overwrite a conf you didn't write.** It carries settings that matter
  (`prune-blockchain`, `out-peers`, Tor, a moved RPC port). Prefer `conf.populate`
  (merges, preserves every other line) over `conf.writeConf` (clobbers). Where a
  coin must write a whole conf, write it **only when absent** — see Monero's
  `prepareConf`. Nerva/Salvium/Zano still clobber; that's tolerable only because
  nobody else is likely to run them, and it is not a pattern to copy.
- **Never delete what you didn't create.** A wallet-`remove` must not `deleteTree`
  a directory BoxWallet didn't make.
- **Use `conf.dataDirHasEntry`** to tell a dir BoxWallet created from one it
  adopted — pass a marker the daemon itself creates (`blocks/`, the conf file).
- **The one unavoidable risk is version skew.** BoxWallet runs its own pinned core
  against their data; if theirs is older, starting ours can upgrade the chainstate
  or wallet format so their app can't open it again. This can't be engineered away,
  only made explicit — don't silently auto-update a daemon that another app also
  drives.

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
| `src/registry.zig` | The registered coins, in one list, in one order. **That order is the GUI's C ABI** — append, never insert. Also carries the duplicate-binary-name comptime guard. |
| `src/coin.zig` | The polymorphic `Coin` vtable interface and its capability structs (`ExternalWallet`, `SyncAccelerator`, `Pruning`, `Stablecoin`). |
| `src/models.zig` | Shared/normalized models (`CoinAuth`, `BlockchainState`, `WalletBalance`, `Seed`, …). Per-coin raw RPC structs may live here or in the coin file. |
| `src/install.zig` | Generic streaming download → gunzip/unzip/bunzip2 + untar (constant memory), `promoteAndTidy`, `installRoot`, version markers. |
| `src/rpc.zig` | JSON-RPC transport over `std.http.Client` (basic + digest auth), warm-up scanning, generic bitcoin-family wallet helpers. |
| `src/conf.zig` | Coin conf read/write (`populate` merges, `writeConf` clobbers), RPC auth resolution, per-platform data dirs, BoxWallet's own `boxwallet.conf`. |
| `src/proc.zig` | Daemon liveness by process name, start-failure reasons from a log tail, terminate+reap. |
| `src/warmup.zig` | What a daemon is doing while its RPC can't answer yet (the `-28` probe + log tail) → phase, sub-stage, percentage, and a ready-made label. |
| `src/extwallet.zig` | The external wallet-rpc **process** lifecycle: per-coin session, credentials, `ensure`/`kill`/`authFor`, friendly error mapping. |
| `src/version.zig` | `app_version`, brand colour, per-front-end names. **Bump the version here** — everything else reads it. |
| `src/update.zig` | The in-app self-updater: check, verify checksum, stage, apply-on-launch. |
| `src/mining.zig` · `src/price.zig` · `src/qrcode.zig` · `src/disk.zig` · `src/memory.zig` · `src/bip39.zig` · `src/bzip2.zig` | Single-purpose helpers, each usable by either front-end. |
| `src/app.zig` | The ZigZag TUI (master/detail). One of two front-ends. |
| `src/capi.zig` | The C ABI the Slint GUI drives (`export fn bw_*`). The other front-end's entry to the same core. |
| `src/main.zig` | TUI entry point + the offline test import block. |

If you find yourself adding coin-specific logic to a shared module, that's the
signal to stop: the coin-specific part belongs in the coin file, and only a
generic, parameterized helper belongs in the shared module.

## Adding a coin

1. Create `src/coins/<coin>.zig` modeled on `nexa.zig`.
2. Implement constants, download/install flow, and RPC mapping.
3. Wire the coin's vtable.
4. **Append** it to `coin_types` in `src/registry.zig` — never insert. That list
   is the index the GUI addresses coins by (it's the C ABI, and
   `gui/app.slint`'s logo array is indexed by it), so inserting renumbers every
   coin after it.
5. Register it in `src/app.zig`: add to the `Entry` enum, the `coin_entries`
   list, the `App` struct field, and the `coinAt`/`selectedCoin` dispatch.
   `coin_entries` **must be in `registry.zig`'s order** — a comptime guard fails
   the build with the offending index if it isn't. The left bar is still sorted
   alphabetically at comptime, with Home pinned on top, so display order is
   independent of registration order.
6. Add its logo to **both** arrays in `gui/app.slint` — `coin-logos` and the
   `coin-logo-names` alongside it. Slint needs `@image-url` to be a literal, so
   the array can't be generated; `main.cpp` checks the names against the registry
   at startup and disables all logos on a mismatch rather than showing one coin's
   brand over another's balance.
7. Add it to the `test { ... }` import block in `src/main.zig`.
8. Add **offline** unit tests (RPC parse/map; install path logic). No daemon, no
   terminal, no network.

## Build, test, run

From the repo root:

```sh
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build test    # offline unit tests
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build         # build the binary
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build run     # launch the TUI
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build release # cross-build all release binaries + SHA256SUMS

ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build gui         # build the Slint GUI
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build gui-run     # build + launch the GUI
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build gui-release # Linux GUI bundles (x86_64 + aarch64)
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
  **`src/version.zig`**, run `zig build release`, and upload all six files to the
  GitHub release. That constant is the single source of truth — `app.zig`
  re-exports it for the TUI and `capi.zig` exposes it as `bw_app_version` for the
  GUI, so **never** write the version anywhere else (it was a literal in
  `gui/app.slint` once, which is how a UI ends up announcing a release it isn't). Asset names + checksums come from one list in `build.zig`, so they
  stay in lockstep with what the updater downloads. The swap targets the real
  running executable wherever it lives — not `~/.boxwallet` (only the staging
  cache). Don't rename assets by hand or the updater can't find them.
- **The GUI's Slint dependency is fetched, not vendored.** Slint is a Rust
  project Zig can't build, so `build.zig.zon` declares upstream's **prebuilt**
  packages as **lazy, hash-pinned** dependencies — one per platform, plus the
  host `slint-compiler` (a separate, self-contained download that turns
  `gui/app.slint` into a C++ header at build time). Lazy means a target's
  package is fetched only when that target is actually built, so `zig build`,
  `zig build test` and `zig build release` never touch it. Add or bump one with
  `zig fetch --save=<name> <url>`, then set `.lazy = true` by hand.
  `build.zig`'s `slintDepName` maps target → package and returns null where
  upstream ships none, which is what keeps the GUI Linux-only without a separate
  platform check. **Never commit the package into the repo** — it was vendored
  under `third_party/` once, and 46 MB of unverifiable binary in git is what
  this replaced.
- **GUI bundles are glibc, not musl.** The prebuilt Slint runtime is
  glibc-linked and needs the system graphics stack (fontconfig, freetype,
  libxkbcommon, libinput, libgbm, libudev, libstdc++), so `gui-release` targets
  `linux-gnu.2.35` and the bundle is exe + `libslint_cpp.so` + Slint's licences,
  zipped. The runtime ships **unmodified** (stripping it saves 0.7 MB of a
  13.7 MB zip, and no stripper handles both arches). The **static-musl TUI stays
  the answer for old, low-spec, or headless machines** — don't "unify" the two
  release paths.
- **macOS and Windows GUIs need a native host.** Upstream publishes no Intel
  macOS package and its Darwin build needs the Apple SDK; the Windows package is
  an MSVC-ABI NSIS installer `zig fetch` can't even unpack. Those belong in a CI
  matrix on native runners — don't try to cross them from Linux.
- **The GUI can't self-update the way the TUI does.** `src/update.zig` swaps a
  single executable; a GUI bundle is an exe plus a sidecar `.so`. Settle that
  before publishing GUI assets, since the naming gets baked into the updater.

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
- **Never add co-authorship trailers to commits.** No `Co-Authored-By:` line, no
  `Claude-Session:` line, no "Generated with …" footer — in commit messages or PR
  bodies. Commit messages here are just the message, nothing appended.
