# BoxWallet

A multi-coin cryptocurrency wallet manager. Install, start, and monitor real
coin daemons on your own machine — no browser, no Electron, no cloud, no
third-party holding your keys.

It comes in two forms over the same core:

- **The desktop app** — a native window with a coin list, live status, and
  panels for transactions, sending, receiving, mining, and wallet management.
  This is the one most people want.
- **The terminal app** — the same functionality as a single self-contained
  binary, for headless servers, SSH sessions, a Raspberry Pi, or anything too
  old or too small for a desktop.

<!-- A desktop screenshot belongs here. Take it with Settings → Privacy →
     "Hide balance figures" switched on, so no real balance is published. -->

## Why BoxWallet?

- **Run your own nodes, keep your own keys.** BoxWallet manages real coin
  daemons on your machine — full self-custody, no third-party wallet service
  holding your funds or watching your balances.
- **One app for every coin.** Install, start, stop, and monitor many coins from
  a single window, instead of juggling a separate wallet app per coin.
- **It shares what you already have.** BoxWallet uses each daemon's standard
  data directory, so an existing synced node and its wallet are picked up as
  they are — no second copy of the chain, no re-sync.
- **Set up in seconds.** BoxWallet downloads and installs each coin's daemon for
  you, then shows live sync progress, block height, and disk/memory usage at a
  glance.
- **Security first.** Seeds, keys, and passwords are held only as long as needed
  and wiped from memory immediately after; daemons and wallet RPC are bound to
  localhost only. Your secrets never touch a log or a remote server.
- **Private by default.** Balance figures can be masked with one switch, and USD
  price lookups can be turned off entirely for a build that makes no network
  request beyond your own nodes.
- **Always current.** It updates itself in the background — no package manager,
  no manual re-download.

## Supported coins

| Coin | Abbrev |
|------|--------|
| Bitcoin | BTC |
| BitcoinZ | BTCZ |
| DigiByte | DGB |
| Divi | DIVI |
| Epic Cash | EPIC |
| Ergo | ERG |
| Litecoin | LTC |
| Monero | XMR |
| Nerva | XNV |
| Nexa | NEXA |
| ReddCoin | RDD |
| Salvium | SAL |
| SpiderByte | SPB |
| Zano | ZANO |

DigiByte includes a **DigiDollar** panel (DigiByte core v9.26+): mint DD against
locked DGB collateral at a chosen lock tier, send/receive DD, watch the oracle
DGB/USD price and system health, and redeem vaults once their timelock expires.
It tracks the on-chain BIP9 deployment — before the mainnet activation height it
counts down to the activation block, and the mint/send/redeem actions unlock
automatically the moment the chain reaches it.

## Install

Everything is on the
[Releases](https://github.com/richardltc/boxwallet/releases) page. There is no
installer and no package to manage.

### Desktop app

Download the `.zip` for your platform, unzip it, and run `boxwallet-gui` from
inside the folder.

| Platform | File |
|----------|------|
| Linux x86_64 | `boxwallet-gui-linux-x86_64.zip` |
| Linux aarch64 | `boxwallet-gui-linux-aarch64.zip` |
| Windows x86_64 | `boxwallet-gui-windows-x86_64.zip` |
| macOS Apple Silicon | `boxwallet-gui-macos-aarch64.zip` |

**Keep the folder together.** The graphics library sits beside the program, and
BoxWallet will not start without it — move or copy the whole folder, never the
program on its own.

Two first-launch traps, both covered by a `README.txt` inside the bundle:

- **Windows:** if double-clicking does nothing at all, you need the
  [Microsoft Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).
  Windows refuses to start the program before any of our code runs, so there is
  no error message we can show you.
- **macOS:** unzip from Terminal (`unzip boxwallet-gui-macos-aarch64.zip`)
  rather than double-clicking in Finder. Finder copies the quarantine flag onto
  every extracted file, and macOS then refuses to run a build Apple hasn't
  notarized. Nothing is wrong with the download.

Intel Macs have no desktop build — the graphics library we depend on publishes
nothing for them, and Rosetta translates Intel to Apple Silicon, not the
reverse. Use the terminal app there.

### Terminal app

A single binary. Download it and run it.

| Platform | File |
|----------|------|
| Linux x86_64 | `boxwallet-linux-x86_64` |
| Linux aarch64 | `boxwallet-linux-aarch64` |
| macOS x86_64 | `boxwallet-macos-x86_64` |
| macOS Apple Silicon | `boxwallet-macos-aarch64` |
| Windows x86_64 | `boxwallet-windows-x86_64.exe` |

The terminal build has no desktop or graphics requirements at all (and on Linux
is statically linked, so no system libraries either), which is what makes it the
right choice for a server, an SSH session, or old hardware.

### The rest of the release page

Anything named `update-…` is fetched by BoxWallet's own updater and will not
start if you run it yourself — it ships without the graphics library the `.zip`
carries. `SHA256SUMS` and `RUNTIME` are there so downloads can be verified.
Every release publishes checksums for every file:

```sh
sha256sum -c SHA256SUMS        # Linux
shasum -a 256 <file>           # macOS
certutil -hashfile <file> SHA256   # Windows
```

BoxWallet keeps coin daemons under `~/.boxwallet/` (Windows:
`%USERPROFILE%\AppData\Roaming\BoxWallet\`). BoxWallet itself can live anywhere.

## Using the desktop app

Pick a coin on the left. The main pane shows its daemon status, sync progress,
chain tip, blockchain size, and memory use, with buttons to **Install**,
**Update**, **Start**, **Stop**, and open the **Wallet** actions.

The panels along the coin's pane cover the rest:

| Panel | What it does |
|-------|--------------|
| **Transactions** | Recent activity for the wallet |
| **Receive** | Your address as text and a QR code, plus a fresh one on demand |
| **Send** | Destination and amount, with a review step before anything is broadcast |
| **Mining** | Where the daemon can mine, with a thread count and your payout address |
| **DigiDollar** | DigiByte only — mint, send, and redeem DD |
| **Settings** | Wallet file locations, backup reminders, and the privacy switches |

Wallet actions — create, restore from seed, encrypt, unlock, change password —
live behind the **Wallet…** button and always ask for a password explicitly.
A new wallet's password is confirmed twice, because a typo on a fresh wallet
means the funds are gone.

**Hiding balances.** Settings → Privacy → *Hide balance figures* masks every
amount on screen while leaving everything else working. Turn it on before
screen-sharing, screenshotting, or recording. The same panel has a switch for
USD price lookups — off means BoxWallet makes no network request except to your
own daemons.

### Desktop integration (Linux)

The Linux bundle ships a `.desktop` entry and app icon. Run this once, from the
folder you extracted into, to get the BoxWallet logo in your panel and an entry
in your applications menu:

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

## Using the terminal app

```sh
./boxwallet-linux-x86_64
```

Navigate with the keyboard:

| Key | Action |
|-----|--------|
| `↑` / `↓` or `j` / `k` | Move through the coin list |
| `i` | Install (or update) the selected coin's daemon |
| `s` | Start / stop the daemon |
| `w` | Wallet — encrypt, unlock, or check stake |
| `h` | Hide / show balance figures |
| `l` | Toggle the log pane |
| `q` | Quit |

Stepping through every coin in the nav — with balances hidden (`h`) for the
recording:

![Browsing the coins with balances hidden](img/demo-coins.gif)

Select a coin to see its detail pane with live daemon status, sync progress, and
disk/memory usage:

![Ergo detail pane](img/screenshot-ergo.png)

## Auto-update

Both apps update themselves. While running, a background worker checks for a
newer release, verifies the download against the release's `SHA256SUMS`, and
stages it; on next launch the new version is swapped in. The desktop app also
confirms the new build actually starts before committing to it, and keeps the
version you have if it doesn't.

If BoxWallet sits somewhere you can't write (e.g. `/usr/local/bin` run as a
regular user), the swap can't happen; the Home pane explains why.

## Build from source

Requires [Zig 0.16](https://ziglang.org/download/).

```sh
git clone https://github.com/richardltc/boxwallet.git
cd boxwallet
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build gui-run  # build + launch the desktop app
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build run      # launch the terminal app
ZIG_GLOBAL_CACHE_DIR=zig-pkg zig build test     # run offline unit tests
```

`ZIG_GLOBAL_CACHE_DIR=zig-pkg` points the build at the vendored
[ZigZag](https://github.com/meszmate/zigzag) dependency for a fully offline,
reproducible build. The desktop app additionally fetches a prebuilt
[Slint](https://slint.dev) runtime for your platform, hash-pinned in
`build.zig.zon` — that download happens only when you build the GUI.

## The original Go version

BoxWallet started life as a Go CLI. That version still works, and its complete
source and history live on the [`master`](https://github.com/richardltc/boxwallet/tree/master)
branch of this repository, untouched — along with all of its releases. This
branch (`main`) is the Zig rewrite, which is where development continues.
