# BoxWallet

A terminal-based cryptocurrency wallet manager. Install, start, and monitor coin
daemons from a single TUI — no browser, no Electron, no cloud.

Stepping through every coin in the nav — with balances hidden (`h`) for the
recording:

![Browsing the coins with balances hidden](img/demo-coins.gif)

## Why BoxWallet?

- **Run your own nodes, keep your own keys.** BoxWallet manages real coin
  daemons on your machine — full self-custody, no third-party wallet service
  holding your funds or watching your balances.
- **One tool for every coin.** Install, start, stop, and monitor many coins
  from a single screen, instead of juggling a separate wallet app per coin.
- **No install, no bloat.** A single binary — no browser, no Electron, no
  background services. Download it, run it, done.
- **Runs anywhere.** Linux, macOS, and Windows from the same interface, and
  light enough for a Raspberry Pi, an old laptop, or a small VPS.
- **Security first.** Seeds, keys, and passwords are held only as long as
  needed and wiped from memory immediately after; daemons and wallet RPC are
  bound to localhost only. Your secrets never touch a log or a remote server.
- **Set up in seconds.** BoxWallet downloads and installs each coin's daemon
  for you, then shows live sync progress, block height, and disk/memory usage
  at a glance.
- **Always current.** It updates itself in the background — no package manager,
  no manual re-download.

## Supported coins

| Coin | Abbrev |
|------|--------|
| Bitcoin | BTC |
| DigiByte | DGB |
| Divi | DIVI |
| Epic Cash | EPIC |
| Ergo | ERG |
| Litecoin | LTC |
| Nerva | XNV |
| Nexa | NEXA |
| ReddCoin | RDD |
| Salvium | SAL |
| SpiderByte | SPB |
| Zano | ZANO |

DigiByte includes a **DigiDollar** tab (DigiByte core v9.26+): mint DD against
locked DGB collateral at a chosen lock tier, send/receive DD, watch the oracle
DGB/USD price and system health, and redeem vaults once their timelock expires.
The tab tracks the on-chain BIP9 deployment — before the mainnet activation
height it counts down to the activation block, and the mint/send/redeem
actions unlock automatically the moment the chain reaches it.

## Install

Download the latest binary for your platform from the
[Releases](https://github.com/richardltc/boxwallet/releases) page and run it —
no install step needed.

| Platform | File |
|----------|------|
| Linux x86_64 | `boxwallet-linux-x86_64` |
| Linux aarch64 | `boxwallet-linux-aarch64` |
| macOS x86_64 | `boxwallet-macos-x86_64` |
| macOS Apple Silicon | `boxwallet-macos-aarch64` |
| Windows x86_64 | `boxwallet-windows-x86_64.exe` |

BoxWallet keeps coin daemons under `~/.boxwallet/` (Windows:
`%USERPROFILE%\AppData\Roaming\BoxWallet\`). The binary itself can live anywhere.

## Usage

```sh
./boxwallet-linux-x86_64   # launch the TUI
```

Navigate with the keyboard:

| Key | Action |
|-----|--------|
| `↑` / `↓` or `j` / `k` | Move through the coin list |
| `i` | Install (or update) the selected coin's daemon |
| `s` | Start / stop the daemon |
| `w` | Wallet — encrypt, unlock, or check stake |
| `l` | Toggle the log pane |
| `q` | Quit |

Select a coin to see its detail pane with live daemon status, sync progress, and
disk/memory usage:

![Ergo detail pane](img/screenshot-ergo.png)

## Auto-update

BoxWallet updates itself in-app. While running, a background worker checks for a
newer release and downloads it. On next launch the new binary is swapped in
automatically — no package manager, no manual download.

If BoxWallet is in a location you can't write (e.g. `/usr/local/bin` run as a
regular user), the swap can't happen; the Home pane explains why.

## Build from source

Requires [Zig 0.16](https://ziglang.org/download/).

```sh
git clone https://github.com/richardltc/boxwallet.git
cd boxwallet
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build run     # launch the TUI
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build test    # run offline unit tests
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build release # cross-compile all release binaries
```

`ZIG_GLOBAL_CACHE_DIR=zig-pkg` points the build at the vendored
[ZigZag](https://github.com/meszmate/zigzag) dependency for a fully offline,
reproducible build.

## Desktop integration (Linux GUI)

The GUI bundle ships a `.desktop` entry and app icon. Run this once, from the
folder you extracted it into, to get the BoxWallet logo in your panel and an
entry in your applications menu:

```sh
./install-desktop.sh
```

It writes only to `~/.local/share` — no root. Re-run it if you move the folder,
so the launcher keeps pointing at the right place.

This is needed because Wayland gives an application no way to set its own window
icon: the compositor looks it up by matching the window against an installed
desktop entry, so one has to exist. Without it you get a generic placeholder.
Building from source? `zig build gui-install-desktop` does the same for the
binary in `zig-out/bin`.

## The original Go version

BoxWallet started life as a Go CLI. That version still works, and its complete
source and history live on the [`master`](https://github.com/richardltc/boxwallet/tree/master)
branch of this repository, untouched — along with all of its releases. This
branch (`main`) is the Zig rewrite, which is where development continues.
