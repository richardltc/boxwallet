---
name: cutting-a-release
description: How to cut a BoxWallet release, and the release/GUI-bundling mechanics (Slint runtime versioning, macOS cross-build limits, self-update swap order). Use when publishing a release or touching build.zig's release targets.
---

- **Releasing / auto-update:** `zig build release` cross-compiles every TUI
  distributable into `zig-out/release/` (Linux = static musl, all `ReleaseSafe`
  + stripped), named `boxwallet-<os>-<arch>[.exe]` with a `SHA256SUMS`; `zig
  build gui-release` does the same for the releasable GUI bundles (two Linux,
  plus Windows x86_64 since v0.8.6 and macOS arm64 since v0.8.7). Both
  front-ends self-update in-app (`src/update.zig` + apply/re-exec in `main.zig`
  and `bw_self_update_apply`, background checks in `app.zig` and `gui/main.cpp`).

  **To cut a release: bump `app_version` in `src/version.zig`, commit it, then
  run `scripts/release.sh`.** The script is the release process — it reads the
  version, runs `zig build test` and `zig build release-all`, verifies
  `sha256sum -c` inside `zig-out/dist/`, then tags `vX.Y.Z`, pushes the tag and
  creates the GitHub release with all 15 assets via `gh`. It refuses to run on a
  dirty tree, so the tag always points at exactly what was built, and it's
  idempotent: re-running after a partial failure reuses the tag and re-uploads
  with `--clobber`. It needs `gh` authenticated (`gh auth login`) and takes the
  repo slug from the `origin` URL. It does **not** push your branch commits (do
  that first) and writes empty release notes. Pushing the `v*` tag is what fires
  the GUI selftest workflow below.

  By hand, that is: `zig build release-all`, then upload the 15 files in
  `zig-out/dist/` to a GitHub release on `github.com/richardltc/boxwallet`. Use
  that step, not the two underneath it — both write a file called
  `SHA256SUMS`, and *both*
  updaters fetch `<tag>/SHA256SUMS`. A release carries one file of that name, so
  publishing either manifest alone leaves the other front-end unable to find its
  asset's checksum: `verify_failed` on every check, for every user of it.
  `release-all` merges them into one manifest over every asset, then refuses to
  assemble at all if anything is missing — `gui-release` skips a target whose
  lazy Slint package hasn't been fetched, which would otherwise publish
  TUI-only assets under a version the GUI updater can't satisfy. The expected
  filenames come from `release_targets`/`gui_targets` at the top of `build.zig`,
  so the check tracks what's registered rather than a hand-kept list, and the
  final `sha256sum -c` runs over `dist/` itself, so what's verified is exactly
  what gets uploaded. `app_version` is the single source of truth — `app.zig`
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
  upstream ships none (Intel macOS, every non-x86_64 Windows), which is what
  bounds the GUI to buildable targets without a separate platform check. **Never commit the package into the repo** — it was vendored
  under `third_party/` once, and 46 MB of unverifiable binary in git is what
  this replaced.
- **GUI bundles are glibc, not musl.** The prebuilt Slint runtime is
  glibc-linked and needs the system graphics stack (fontconfig, freetype,
  libxkbcommon, libinput, libgbm, libudev, libstdc++), so `gui-release` targets
  `linux-gnu.2.35` and the bundle is exe + `slint-<ver>/libslint_cpp.so` +
  Slint's licences, zipped. The runtime ships **unmodified** (stripping it saves
  0.7 MB of a 16 MB zip, and no stripper handles both arches). The **static-musl TUI stays
  the answer for old, low-spec, or headless machines** — don't "unify" the two
  release paths.
- **macOS arm64 and Windows x86_64 cross-build from Linux; Intel macOS can't.**
  Measured, not assumed:
  - **macOS aarch64** builds here with no Mac and no Apple SDK. Our code never
    references a framework, so the dylib's 21 framework dependencies stay its own
    and dyld resolves them on the target; Zig also ad-hoc code-signs the output,
    which Apple Silicon requires. `tools/fixneeded.zig` has no Mach-O
    counterpart to write — the dylib's install name is already
    `@rpath/libslint_cpp.dylib`, so the linker records that and
    `@loader_path/slint-<ver>` resolves it, exactly mirroring ELF.
  - **macOS x86_64 is impossible** short of building Slint from source: upstream
    publishes no `Slint-cpp-…-Darwin-x86_64` at all, and Rosetta translates
    x86_64→arm64 on Apple Silicon, not the reverse, so an Intel Mac can't run the
    arm64 runtime either. Intel Macs get the TUI.
  - **Windows x86_64 needs no native host** — the "MSVC only runs on Windows"
    worry doesn't apply. Slint's cross-DLL surface is **pure C** (385 `slint_*`
    functions + 25 `*VTable` data objects, zero mangled symbols) and its C++ API
    is a header-only layer compiled by *our* compiler, so `x86_64-windows-gnu`
    links against the MSVC-built import library with only C crossing the
    boundary. What *is* true is that `zig fetch` rejects the NSIS installer
    (`unsupported Content-Disposition header value`), so it can't be a
    `build.zig.zon` dep — `slintWindowsPackage` in `build.zig` downloads it,
    checks a pinned SHA-256 and unpacks it with `7z` instead. `zig build
    slint-windows` exercises that on its own. Three things don't port from
    ELF/Mach-O: there is **no rpath**, and no delay-load escape either (21 of the
    imports are *data* objects and delay-load covers only function thunks), so
    the DLL ships **flat beside the exe** rather than in `slint-<ver>/`;
    `tools/fixneeded.zig` has no PE counterpart to write (the import table
    already records the bare `slint_cpp.dll`); and the runtime needs
    **`VCRUNTIME140.dll`/`MSVCP140.dll`**, which upstream does *not* bundle — a
    machine without the VC++ redist fails in the loader before `main`, silently.
- **Building a GUI target is not the same as being allowed to release it.**
  Nothing on a Linux host can *execute* a Mach-O, so the `--selftest` pre-flight
  — the thing that catches an exe/runtime mismatch before it fails invisibly
  inside the loader — can't be run for macOS here. Such targets live in
  `gui_targets_unverified`, build under `zig build gui-release-unverified` into
  their own output directory, and are **deliberately absent from `release-all`**,
  so no release can publish one by accident. `assetFor(.gui)` also returns null
  for them, so the updater stays dormant rather than chasing an asset that was
  never published. Move an entry into `gui_targets` (and light up `assetFor`)
  only once the bundle has actually launched on real hardware. **`gui_targets_unverified`
  is currently empty** — Windows x86_64 was promoted on a green `v0.8.5` run and
  ships from v0.8.6; macOS arm64 on a green `v0.8.6` run, shipping from v0.8.7.
  The list and its step are kept anyway: they are the holding pen the next new
  platform starts in, and `gui-release-unverified` correctly builds nothing until
  then.

  **`.github/workflows/gui-selftest.yml` is how that happens.** It cross-builds
  the bundles on Linux exactly as a release would (`gui-release`, now that
  everything in it is releasable), then runs each one on a real runner of its own
  OS (`windows-latest` and an Apple Silicon `macos-latest`), asserting the
  selftest exits 0 *and* reports this commit's
  `app_version`. Each job then hides the runtime and requires the selftest to
  fail, because a gate that cannot fail is not a gate: a `--selftest` that
  silently returned 0 would wave every broken pair straight through. The Windows
  job deliberately runs from `C:\`, since Windows resolves an implicit import
  from the *executable's* directory and that is the whole premise of the flat
  layout. Triggered manually (`workflow_dispatch`) or by a `v*` tag; it publishes
  nothing and needs no secrets. A green run is the evidence for promoting a
  target — nothing else is. Promotion doesn't retire the job: it is what stops a
  released bundle regressing on the next tag.
- **A Windows GUI asset is `…-x86_64.exe`; its bundle is `…-x86_64.zip`.** The
  two stems differ by that suffix on Windows and nowhere else, so anything
  deriving one from the other must go through `bundleBase` (`src/update.zig`) or
  `guiExeAsset` (`build.zig`). Concatenating `.zip` onto the asset asks a release
  for `…-x86_64.exe.zip` and 404s — reported to the user as a network error, on
  every Windows update that needs the runtime.
- **The Slint runtime lives in a version-named directory, and that is load-bearing.**
  `slint-<ver>/libslint_cpp.so`, with the exe's RUNPATH pointing at that exact
  directory (`slint_version` in `build.zig` — keep it in step with the URLs in
  `build.zig.zon`). It exists so the GUI can self-update: an exe and a runtime
  from different releases reference *different paths*, so they can never be
  mistaken for a pair, and installing a new runtime is a create rather than an
  overwrite. Verified: a runtime under the wrong version name is invisible to the
  loader, not silently loaded.

  This matters because `boxwallet-gui` is **`BIND_NOW` with 115 undefined Slint
  symbols, 21 of them data objects**. A mismatched pair fails in `ld.so` *before
  `main`* — nothing on screen, and none of our code runs to recover. Don't
  "simplify" this back to a bare `$ORIGIN`.

  Versioning the *directory* rather than the filename is also deliberate:
  `tools/fixneeded.zig` can only shorten `DT_NEEDED` to a tail of the baked
  string, so it can't express a versioned filename without string-table surgery.
- **`gui-release` publishes four things per target**, all covered by `SHA256SUMS`:
  the bare exe (what the updater fetches when the installed runtime already
  matches), the `.zip` bundle (when it doesn't), and a `RUNTIME` file naming the
  Slint version each target needs plus its runtime hash. `RUNTIME` is hashed into
  `SHA256SUMS` too, so the pairing information carries the same trust as the
  downloads. Bundles are staged under `gui-release/staging/` and only the
  publishable files sit at the top level — `sha256sum -c SHA256SUMS` must pass
  cleanly there.
- **Releases live on GitHub, and that is not just a preference.** BoxWallet was
  hosted on Codeberg until 2026-08; their Terms of Use § 2 (1) 6 explicitly list
  "cryptocurrency related projects" among content they do not tolerate, with
  § 2 (2) providing for removal and account suspension. Since `update.zig` bakes
  the release host into every shipped binary, a takedown would have silently
  stopped updates for every install (`network_error` is deliberately quiet).
  Don't move release hosting back, and don't add a host without checking its
  terms permit this project.

  The repo also carries the **archived Go version** on `master` — 1152 commits
  and ~100 releases, left byte-for-byte alone. `main` is the Zig rewrite. Old
  release assets are all `boxwallet_<ver>_<os>_<arch>.tar.gz` and share no name
  with ours, so an old release surfacing as "latest" can only ever fail
  `parseChecksum` rather than install a Go binary — one of the two reasons the
  version series didn't need renumbering (the other: GitHub picks "latest" by
  publish date, and every Zig release postdates every Go one).
- **The GUI self-updates too, and the two front-ends must not collide.** Each
  stages into `~/.boxwallet/updates/<front>/` (`update.Front`). They share one
  install root, and a shared `boxwallet.staged` meant the GUI could stage its
  binary and the TUI would apply it over itself next launch — `isNewer` can't
  catch that, because the versions genuinely match. Any new front-end gets its
  own `Front` variant, never a shared name.
- **The GUI update is exe-or-bundle, decided by `RUNTIME`.** `checkAndStage(.gui)`
  reads the release's `RUNTIME` line, hashes the `slint-<ver>/` beside the
  installed exe, and fetches the bare exe only when both agree — otherwise the
  full bundle. A missing or unparseable line is `verify_failed`, **never**
  "probably the same runtime": guessing is precisely how an exe-only update lands
  against the wrong runtime. Apply order is load-bearing — the runtime goes in
  **first**, as a create (`slint-<ver>.bw-new/` → rename the *directory*), then
  the exe swaps. Installing a runtime the old exe doesn't reference changes
  nothing for it, so every intermediate state still boots; the reverse order
  leaves a window where the new exe is live with no runtime to load. Never write
  into a live runtime directory: the kernel refuses to let us overwrite a running
  *executable* but gives no such protection for a mapped `.so`.
- **A GUI swap is pre-flighted, and that's what makes it safe.** `swapBinary`
  runs the new binary with `--selftest` from the target path (so `$ORIGIN`
  resolves against the real install directory) and rolls back on anything but a
  clean exit. `--selftest` prints the version and returns *before*
  `AppWindow::create()`, so it needs no display; because the exe is `BIND_NOW`,
  reaching that line at all proves the pair links. Verified against real bundles:
  a wrong-named runtime dir exits 127, a corrupt one takes SIGBUS, and a
  differently-versioned one is invisible to the loader rather than silently used.
  Keep `--selftest` above `AppWindow::create()`, and keep the re-exec passing
  `argv[0]` only so an updated binary can't re-enter it.
