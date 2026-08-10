---
name: adding-a-coin
description: Step-by-step checklist for wiring a new coin into BoxWallet (registry, TUI entries, GUI logos, tests). Use when adding support for a new cryptocurrency.
---

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
