# Coin logos

Per-coin logos shown before the coin name in the nav. They are **embedded into
the binary at build time** (via `@image-url` in `gui/app.slint`), so the exe is
self-contained — nothing extra ships alongside it.

Files are named **`<coin>.png`**, where `<coin>` is the coin's source basename
(the `src/coins/<coin>.zig` name): `bitcoin.png`, `divi.png`, `monero.png`, …

The logos are referenced from an array in `AppWindow.coin-logos` **in registry
order** (matching `coinByIndex` in `src/capi.zig`) and selected by each coin's
registry index. So:

- **To change a logo:** replace its `<coin>.png` here and **rebuild**
  (`zig build gui`). `@image-url` bakes the file in at compile time.
- **To add a coin's logo:** drop `<coin>.png` in and add its `@image-url(...)`
  to the `coin-logos` array at the coin's registry index.
- A referenced file must exist at build time (a missing `@image-url` target is a
  compile error).

Square images with transparency look best (the placeholders here are 128×128).
PNG is expected but any format the Slint compiler can embed works.
