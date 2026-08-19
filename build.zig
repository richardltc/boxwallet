const std = @import("std");

/// Every distributable this repo publishes, in one place per front-end.
///
/// `release-all` derives the upload manifest from these two lists, so the
/// assets, the checksums and the completeness check can't drift from what was
/// actually built — the same reason `release`'s own `sha256sum` pass reads from
/// the list rather than a hand-written filename.
const ReleaseTarget = struct { query: std.Target.Query, name: []const u8 };
const release_targets = [_]ReleaseTarget{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "boxwallet-linux-x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "boxwallet-linux-aarch64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "boxwallet-macos-x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "boxwallet-macos-aarch64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "boxwallet-windows-x86_64.exe" },
};


const GuiTarget = struct { query: std.Target.Query, name: []const u8 };

/// GUI targets not yet cleared for release: they build here, but nothing on this
/// host can *run* them, and the whole point of the `--selftest` pre-flight is
/// that an exe/runtime mismatch fails inside the loader before `main` —
/// invisibly. Entries here are built by their own step and deliberately left out
/// of `release-all`, so no release can publish one by accident, and
/// `assetFor(.gui)` returns null for them so the updater stays dormant rather
/// than chasing an asset nobody published.
///
/// **Empty, for the first time since it was introduced** — every target we build
/// has now been run on real hardware by
/// `.github/workflows/gui-selftest.yml`. Kept rather than deleted because it is
/// the holding pen the *next* one lands in: a new OS/arch starts here, gets its
/// green run, and only then moves down. `gui-release-unverified` builds nothing
/// while this is empty, which is the correct answer to "what is unverified?".
const gui_targets_unverified = [_]GuiTarget{};
const gui_targets = [_]GuiTarget{
    // glibc, not musl: the Slint runtime is a glibc binary, so the exe beside
    // it must be too. Each glibc floor is upstream's, read off its `.so` with
    // `readelf -V | grep GLIBC_` — Zig links against its own versioned stubs,
    // so ours never asks for anything newer than the runtime already does.
    // Pinning higher would exclude machines that can run the bundle fine;
    // pinning lower would buy nothing, since the loader still has to satisfy
    // the `.so`. Re-check both when bumping Slint.
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 35, .patch = 0 } }, .name = "boxwallet-gui-linux-x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 30, .patch = 0 } }, .name = "boxwallet-gui-linux-aarch64" },
    // `gnu` (mingw), not `msvc`: nothing about the Slint DLL requires the MSVC
    // ABI — its exported surface is pure C — and mingw is what Zig can produce
    // without a Windows host. See `slintWindowsPackage`.
    //
    // Verified by the `windows` job in `.github/workflows/gui-selftest.yml`,
    // which unzips this bundle, runs `--selftest` from a different cwd, and
    // asserts it fails with the DLL taken away. Green on the v0.8.5 tag, which
    // is what moved this out of `gui_targets_unverified`. It publishes an
    // `…-x86_64.exe` bare asset (not the bare name) — see `exe_asset`.
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .name = "boxwallet-gui-windows-x86_64" },
    // Apple Silicon only — upstream publishes no Intel macOS Slint package at
    // all, and Rosetta translates x86_64→arm64, not the reverse, so an Intel Mac
    // can't run this one either. Intel Macs get the TUI.
    //
    // Cross-built here with no Mac and no Apple SDK: our code references no
    // framework, so the dylib's framework dependencies stay its own, and Zig
    // ad-hoc code-signs the output as Apple Silicon requires. Verified by the
    // `macos` job on an Apple Silicon runner, green on the v0.8.6 tag.
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "boxwallet-gui-macos-aarch64" },
};

/// Marks an asset as the self-updater's, not a download. Mirrored by
/// `update_asset_prefix` in `src/update.zig`, which is the other end of the same
/// name — change one and the updater asks a release for a file it doesn't carry.
const update_asset_prefix = "update-";

/// The bare-exe asset published for `t`, as distinct from `t.name`, which names
/// the bundle (`<name>.zip`) and the directory inside it. Windows needs the
/// `.exe`: the loader keys off it and a browser download without it is inert.
/// `assetFor(.gui)` in `src/update.zig` returns this same name.
///
/// The `update-` prefix is for humans, not for the updater. A GitHub release is a
/// flat, case-insensitively sorted list of files with no folders, so naming is
/// the only way to separate the four updater-only exes from the nine files
/// somebody should actually download — the prefix sorts them into one block
/// below `SHA256SUMS`. It has to be the *name* that says so, because a bare GUI
/// exe downloaded by hand can't explain itself: it is `BIND_NOW` against the
/// Slint runtime and dies in `ld.so` before `main`, with no window and no
/// message. Picking the wrong one of a `…-x86_64` / `…-x86_64.zip` pair used to
/// look exactly like a corrupt download.
///
/// Releases up to v0.8.11 also carried this file a second time under its
/// pre-v0.8.9 unprefixed name, so installs older than the rename could still
/// update themselves — the very copy that kept the confusion alive, since an
/// unprefixed bare exe sat beside the `.zip` regardless. Dropped in v0.8.12:
/// `assetFor(.gui)` is baked in at build time, so a GUI at v0.8.8 or earlier
/// now fails `parseChecksum`/`parseRuntime`, reports `verify_failed` on every
/// launch and has to be re-downloaded by hand. Don't reintroduce the alias for
/// a future rename — an unprefixed name is exactly what must not be published.
fn guiExeAsset(comptime t: GuiTarget) []const u8 {
    return update_asset_prefix ++ if (t.query.os_tag.? == .windows) t.name ++ ".exe" else t.name;
}


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "boxwallet-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    b.installArtifact(exe);

    // `zig build run -- ...` runs the TUI binary.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the offline unit tests (no daemon required).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("zigzag", zigzag.module("zigzag"));
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const release_step = addReleaseStep(b);
    addGuiStep(b, target, optimize);

    // Registered here, not inside `addGuiStep`: that one returns early when the
    // *host* Slint package hasn't been fetched yet, which would leave
    // `gui-release` (and with it `release-all`) undefined as a step rather than
    // merely unbuildable — "no such step" for a reason that has nothing to do
    // with the targets it cross-builds.
    const gui_release_step = addGuiReleaseStep(b, optimize, .{
        .step_name = "gui-release",
        .desc = "Bundle the releasable GUIs (exe + Slint runtime) into zips",
        .out_dir = "gui-release",
        .targets = &gui_targets,
    });
    addReleaseAllStep(b, release_step, gui_release_step);

    // `zig build slint-windows`: materialise upstream's Windows package on its
    // own. Every other platform's package arrives as a lazy `build.zig.zon`
    // dependency that `zig fetch` can pre-warm and verify; this one can't be, so
    // this is the equivalent hook — a way to check the download, the pinned hash
    // and the NSIS unpack in isolation, without building a GUI around it.
    const slint_win_step = b.step("slint-windows", "Fetch + unpack upstream's Slint Windows C++ package");
    const slint_win = slintWindowsPackage(b);
    const show_slint_win = b.addSystemCommand(&.{ "sh", "-c", "ls -la \"$1\"/lib", "slint-windows-show" });
    show_slint_win.addDirectoryArg(slint_win.root);
    slint_win_step.dependOn(&show_slint_win.step);

    // Built, but not releasable: see `gui_targets_unverified` — currently empty,
    // so this step builds nothing until a new target arrives. Its own step and
    // its own output directory, and deliberately not wired into `release-all`.
    _ = addGuiReleaseStep(b, optimize, .{
        .step_name = "gui-release-unverified",
        .desc = "Bundle GUI targets that have not yet been launched on real hardware",
        .out_dir = "gui-release-unverified",
        .targets = &gui_targets_unverified,
    });
}

/// `zig build gui` builds the optional Slint GUI front-end (proof-of-concept).
///
/// Entirely Zig-orchestrated — no CMake, no cargo. `build.zig` runs the
/// `slint-compiler` to turn `gui/app.slint` into a C++ header, compiles the C++
/// glue (`gui/main.cpp`) with Zig's own clang, and links it against the Zig core
/// (built here as a static lib from `src/capi.zig`) plus the Slint runtime. The
/// GUI's `main` lives in the C++ TU, so the executable's Zig module has no root
/// source file — it's a pure C/C++ executable that pulls its C-ABI symbols from
/// the linked-in core lib.
///
/// The only pieces Zig can't build (Slint is a Rust project) come from upstream's
/// prebuilt packages, declared as **lazy dependencies** in `build.zig.zon` — one
/// per platform, each pinned by hash, fetched only when that target is actually
/// built (see `slintDep`). The prebuilt C++ package ships a *shared*
/// `libslint_cpp.so` (no static archive), so the GUI links it dynamically and
/// finds it via an rpath — one sidecar library on Linux, not a fully-static
/// single file.
///
/// Additive: this touches none of the TUI `exe`/`test`/`release` steps.
fn addGuiStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // `zig build gui`: dev build. The rpath points at the package's lib dir so it
    // runs in-place from the repo.
    //
    // Null on the very first run: a lazy dependency isn't on disk yet, so Zig
    // fetches it and re-runs this build script. Nothing to wire up until then.
    const exe = buildGuiExe(b, target, optimize, .package_dir) orelse return;
    const install_exe = b.addInstallArtifact(exe, .{});
    const gui_step = b.step("gui", "Build the optional Slint GUI (proof-of-concept)");
    gui_step.dependOn(&install_exe.step);

    // `zig build gui-run`: build and launch the GUI (like `zig build run` for the
    // TUI). The package-dir rpath lets it find libslint_cpp.so wherever it runs.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_exe.step);
    if (b.args) |args| run_cmd.addArgs(args);
    const gui_run_step = b.step("gui-run", "Build and run the Slint GUI");
    gui_run_step.dependOn(&run_cmd.step);

    // `zig build gui-install-desktop`: register the dev build with the desktop,
    // so the panel shows the BoxWallet logo instead of a generic placeholder.
    //
    // Needed because Wayland gives an application no way to set its own window
    // icon — `Window.icon` in app.slint reaches `winit::Window::set_window_icon`,
    // which is an X11-only path. The compositor instead matches the window's
    // app_id against an installed desktop entry, so one has to exist. See
    // gui/boxwallet.desktop.
    //
    // The same shell script ships in the release bundle, so end users and this
    // build step take the identical code path; it derives the executable path
    // from its own location, which is why it's pointed at zig-out/bin here.
    const desktop_step = b.step("gui-install-desktop", "Install a desktop entry + icon so the panel shows the logo");
    // The script locates everything relative to *itself* (`dirname $0`), so it
    // has to run from a directory laid out like the bundle: the exe, the entry
    // template and `icons/` all beside it. zig-out/bin already holds the exe,
    // so stage the other three there and run that copy — no second layout for
    // the script to know about.
    const stage_entry = b.addInstallFile(b.path("gui/boxwallet.desktop"), "bin/boxwallet.desktop");
    const stage_icon = b.addInstallFile(b.path("gui/icons/boxwallet.png"), "bin/icons/boxwallet.png");
    const stage_script = b.addInstallFile(b.path("gui/install-desktop.sh"), "bin/install-desktop.sh");
    const install_desktop = b.addSystemCommand(&.{
        "sh",
        b.getInstallPath(.bin, "install-desktop.sh"),
    });
    install_desktop.step.dependOn(&install_exe.step);
    install_desktop.step.dependOn(&stage_entry.step);
    install_desktop.step.dependOn(&stage_icon.step);
    install_desktop.step.dependOn(&stage_script.step);
    desktop_step.dependOn(&install_desktop.step);
}

/// The `build.zig.zon` dependency holding upstream's prebuilt Slint C++ package
/// for `t` — the runtime `.so`, the headers, and the licences that must ship
/// beside a redistributed binary. Null where upstream publishes no package for
/// the target, which is how the GUI stays Linux-only for now without any target
/// check of its own:
///
///   * macOS: only `Darwin-arm64` is published (no Intel build).
///   * Windows: published as an NSIS installer `.exe`, which `zig fetch` refuses
///     outright (`unsupported Content-Disposition header value`). It is fetched
///     and unpacked by `slintWindowsPackage` instead — see there for why the
///     MSVC ABI it was built against costs us nothing.
/// The Slint release the GUI links against, and the name of the directory the
/// runtime ships in.
///
/// **Must match the version in every `slint_*` URL in `build.zig.zon`.** It can't
/// be derived from them: the fetched package resolves to a hash-named path, not a
/// versioned one, and the `.so` itself has no SONAME and exports no version
/// query. Bump both together.
///
/// This is also the whole pairing protocol for the GUI self-updater. The runtime
/// lives at `slint-<ver>/libslint_cpp.so` and the exe's RUNPATH points at that
/// exact directory, so an exe and a runtime from different releases reference
/// *different paths* and can never be mistaken for a pair. Versioning the
/// directory rather than the filename is deliberate — `tools/fixneeded.zig` can
/// only shorten `DT_NEEDED` to a tail of the baked string, so it cannot express a
/// versioned filename without string-table surgery.
pub const slint_version = "1.17.1";

/// Where the runtime sits inside a bundle, relative to the exe.
pub const slint_dir = "slint-" ++ slint_version;

fn slintDepName(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .linux => switch (t.cpu.arch) {
            .x86_64 => "slint_linux_x86_64",
            .aarch64 => "slint_linux_aarch64",
            else => null,
        },
        // Apple Silicon only. Upstream publishes no Intel macOS package at all
        // (no `Slint-cpp-…-Darwin-x86_64`, no `slint-compiler-Darwin-x86_64`),
        // and Rosetta can't help — it translates x86_64 to arm64 on Apple
        // Silicon, not the reverse, so an Intel Mac can't run the arm64 runtime.
        // Intel Macs get the TUI. Building this from Linux needs no Mac and no
        // Apple SDK: our code never touches a framework, so the dylib's 21
        // framework dependencies stay its own and are resolved by dyld on the
        // target machine.
        .macos => switch (t.cpu.arch) {
            .aarch64 => "slint_macos_aarch64",
            else => null,
        },
        // Windows has no `build.zig.zon` entry at all — see `slintWindowsPackage`.
        else => null,
    };
}

/// Upstream's Windows C++ package, and the SHA-256 of the exact bytes we accept.
/// **Bump alongside `slint_version`** — the URL embeds it, and the hash pins the
/// one file that version resolves to.
const slint_windows_url = "https://github.com/slint-ui/slint/releases/download/v" ++
    slint_version ++ "/Slint-cpp-" ++ slint_version ++ "-win64-MSVC-AMD64.exe";
const slint_windows_sha256 = "f5b537da448c1e3d72a24a774e19518ae412b9706b8ef49bdee64b62b878fe56";

/// A Slint C++ package, however it was obtained. Upstream lays every platform's
/// package out identically — `lib/` (runtime, plus the import library on
/// Windows), `include/slint/`, `licenses/` — so callers only ever need the root,
/// and the two very different ways of getting one collapse to a single type.
const SlintPackage = struct {
    root: std.Build.LazyPath,

    fn lib(self: SlintPackage, b: *std.Build) std.Build.LazyPath {
        return self.root.path(b, "lib");
    }
    fn include(self: SlintPackage, b: *std.Build) std.Build.LazyPath {
        return self.root.path(b, "include/slint");
    }
    fn licenses(self: SlintPackage, b: *std.Build) std.Build.LazyPath {
        return self.root.path(b, "licenses");
    }
};

/// Fetch + unpack upstream's Slint **Windows** package, returning its root.
///
/// Windows is the one target whose package can't be a `build.zig.zon` dependency:
/// upstream publishes it as an NSIS installer `.exe` and `zig fetch` rejects that
/// outright. `7z` unpacks it perfectly well, so this does by hand what the lazy
/// deps do for every other target — download, verify against a pinned hash,
/// unpack — and keeps the two properties that matter: nothing binary is committed
/// to the repo, and the bytes are pinned rather than trusted.
///
/// **The MSVC ABI it was built against costs us nothing**, which is why no native
/// Windows host appears anywhere in this build. Slint's cross-DLL surface is pure
/// C — 385 `slint_*` functions and 25 `*VTable` data objects, zero C++-mangled
/// symbols — and its C++ API is a header-only layer compiled by *our* compiler.
/// So `x86_64-windows-gnu` links against the MSVC-built import library and the
/// only thing crossing the DLL boundary is C. (Verified: the exe uses Zig's
/// mingw/libc++ while the DLL uses MSVCP140/VCRUNTIME140, and nothing that would
/// care — no allocation, `FILE*`, or exception — ever crosses.)
///
/// Memoised: `buildGuiExe` and `addGuiReleaseStep` both want this, and a second
/// call would mean a second download.
var slint_windows_memo: ?SlintPackage = null;

fn slintWindowsPackage(b: *std.Build) SlintPackage {
    if (slint_windows_memo) |p| return p;

    // `$PLUGINSDIR` is NSIS's own installer scaffolding (its UI plugin DLLs), not
    // part of the package — dropped so what's left is exactly the payload, and a
    // stray `.dll` in there can never be mistaken for the runtime.
    const script =
        \\set -e
        \\out="$1"
        \\command -v curl >/dev/null || { echo "slint-windows: curl not found" >&2; exit 1; }
        \\command -v 7z   >/dev/null || { echo "slint-windows: 7z not found (install p7zip-full) - it is what unpacks upstream's NSIS installer" >&2; exit 1; }
        \\rm -rf "$out"; mkdir -p "$out"
        \\tmp="$out/.installer.exe"
        \\curl -fsSL -o "$tmp" "$2"
        \\got=$(sha256sum "$tmp" | cut -d' ' -f1)
        \\if [ "$got" != "$3" ]; then
        \\  echo "slint-windows: checksum mismatch for $2" >&2
        \\  echo "  expected $3" >&2
        \\  echo "  got      $got" >&2
        \\  exit 1
        \\fi
        \\7z x -y -o"$out" "$tmp" >/dev/null
        \\rm -rf "$tmp" "$out/\$PLUGINSDIR"
        \\test -f "$out/lib/slint_cpp.dll" || { echo "slint-windows: no lib/slint_cpp.dll in the unpacked package" >&2; exit 1; }
        \\test -f "$out/lib/slint_cpp.dll.lib" || { echo "slint-windows: no import library in the unpacked package" >&2; exit 1; }
    ;

    const run = b.addSystemCommand(&.{ "sh", "-c", script, "slint-windows" });
    const out = run.addOutputDirectoryArg("slint-windows");
    run.addArgs(&.{ slint_windows_url, slint_windows_sha256 });

    const pkg = SlintPackage{ .root = out };
    slint_windows_memo = pkg;
    return pkg;
}

/// The Slint package for `t`, from whichever source that target uses. Null where
/// upstream publishes nothing for it, and on the first run of a build that still
/// has to fetch a lazy dependency.
fn slintPackage(b: *std.Build, t: std.Target) ?SlintPackage {
    if (t.os.tag == .windows) {
        // Only x86_64 for now; upstream also publishes a win64-MSVC-ARM64 build.
        if (t.cpu.arch != .x86_64) return null;
        return slintWindowsPackage(b);
    }
    const dep_name = slintDepName(t) orelse return null;
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    return .{ .root = dep.path("") };
}

/// The Slint runtime's filename for `t`. Named per-OS because the whole
/// pairing scheme keys off this file: it's what gets hashed into `RUNTIME`,
/// what lands in `slint-<ver>/`, and what `src/update.zig` looks for when
/// deciding whether it can fetch the bare exe.
fn slintRuntimeName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "libslint_cpp.dylib",
        .windows => "slint_cpp.dll",
        else => "libslint_cpp.so",
    };
}

/// What the *linker* is given, which on Windows is not what ships. ELF and Mach-O
/// link the runtime itself; PE links a separate import library and the DLL is
/// resolved at load time by the bare name recorded in the import table.
fn slintLinkName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "slint_cpp.dll.lib",
        else => slintRuntimeName(os),
    };
}

/// The loader's "directory containing me" token for `t`. ELF spells it
/// `$ORIGIN`, Mach-O `@loader_path`; both take the same version-scoped
/// subdirectory after it, so the self-update design carries over unchanged.
fn originToken(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "@loader_path",
        else => "$ORIGIN",
    };
}

/// The `slint-compiler` for the **build host** (it runs here, at build time, to
/// turn `.slint` markup into a C++ header) — a separate, self-contained upstream
/// download, so it needs none of the runtime's shared libs on the path. Null on
/// a host upstream publishes no compiler for, which is what makes `zig build`,
/// `zig build test` and `zig build release` work anywhere: only the GUI steps
/// ever ask for it.
fn slintCompilerDepName(t: std.Target) ?[]const u8 {
    if (t.os.tag != .linux) return null;
    return switch (t.cpu.arch) {
        .x86_64 => "slint_compiler_linux_x86_64",
        .aarch64 => "slint_compiler_linux_aarch64",
        else => null,
    };
}

const RPathKind = enum { package_dir, origin };

/// Build the GUI executable for `target`. `rpath` selects how it finds
/// `libslint_cpp.so` at run time: `.package_dir` (absolute path into the fetched
/// package, for in-place `zig build gui`) or `.origin` (`$ORIGIN`, so a
/// distributed bundle finds the `.so` sitting next to the exe).
///
/// Null when this target (or this build host) has no upstream Slint package, and
/// on the first run of a build that still has to fetch one — in both cases the
/// caller simply skips wiring the GUI steps up.
fn buildGuiExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rpath: RPathKind,
) ?*std.Build.Step.Compile {
    const slint = slintPackage(b, target.result) orelse return null;
    const slint_lib_dir = slint.lib(b);
    const slint_inc_dir = slint.include(b);

    // slint-compiler: gui/app.slint -> generated C++ header. It runs on the build
    // host, so it comes from the host's package, not the target's — and unlike
    // the copy inside the C++ package it's self-contained (no LD_LIBRARY_PATH).
    const compiler_dep_name = slintCompilerDepName(b.graph.host.result) orelse return null;
    const slint_compiler = b.lazyDependency(compiler_dep_name, .{}) orelse return null;

    // Built as a bare Run so the program itself can be a `LazyPath` into the
    // fetched package (an argv string would have to be a repo-relative path).
    const gen = std.Build.Step.Run.create(b, "slint-compiler app.slint");
    gen.addFileArg(slint_compiler.path("slint-compiler"));
    gen.addArgs(&.{ "-f", "cpp", "--style", "fluent" });
    // `--embed-resources embed-files` bakes every `@image-url` (the coin logos and
    // the app icon) into the generated header as bytes. The compiler's default is
    // `as-absolute-path`, which records this build machine's paths and loads them
    // at run time — fine on the host, but a released bundle ships only the exe and
    // `slint-<ver>/`, so on any other machine every logo silently resolves to
    // nothing. Embedding is what makes the bundle self-contained. SVG sources stay
    // SVG (resvg rasterises them at draw size); only the bytes move.
    gen.addArgs(&.{ "--embed-resources", "embed-files" });
    gen.addArgs(&.{"-o"});
    const gen_header = gen.addOutputFileArg("app.slint.h");
    // The images are now inputs to this step, not paths read later, so the build
    // has to know about them: without the depfile a swapped logo leaves the cached
    // header — and the old bytes — in place.
    gen.addArgs(&.{"--depfile"});
    _ = gen.addDepFileOutputArg("app.slint.d");
    gen.addFileArg(b.path("gui/app.slint"));

    // The Zig core as a static library exposing the C ABI (src/capi.zig).
    //
    // `link_libc = true` matters: this lib links into a libc/libc++ executable
    // whose entry is the C++ `main`, so Zig's own freestanding startup never
    // runs. Without libc, the core's `std.Thread.spawn` would take the manual
    // Linux-clone path that needs TLS initialized by that Zig startup, and the
    // first RPC worker (`std.Io.Threaded`) would crash on uninitialized TLS.
    // With libc, `std.Thread` uses `pthread_create` and libc owns TLS setup.
    const strip = optimize != .Debug;
    const core = b.addLibrary(.{
        .name = "boxwallet-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });

    // Embed the monospace font: convert the vendored TTF into a C header baked
    // into the binary, so the mono gauge values need no system font at run time.
    const bin2c = b.addExecutable(.{
        .name = "bin2c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bin2c.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen_font = b.addRunArtifact(bin2c);
    gen_font.addFileArg(b.path("gui/fonts/DejaVuSansMono.ttf"));
    const font_header = gen_font.addOutputFileArg("monofont.h");

    // The GUI executable: pure C/C++ (main is in main.cpp), no Zig root. In Zig
    // 0.16 the C-source/include/link wiring lives on the Module.
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .strip = strip,
    });
    exe_mod.addCSourceFile(.{ .file = b.path("gui/main.cpp"), .flags = &.{"-std=c++20"} });
    exe_mod.addIncludePath(font_header.dirname()); // generated monofont.h
    exe_mod.addIncludePath(gen_header.dirname()); // generated app.slint.h (also orders the compile after gen)
    exe_mod.addIncludePath(b.path("gui"));
    exe_mod.addIncludePath(b.path("include")); // boxwallet.h
    exe_mod.addIncludePath(slint_inc_dir); // <slint.h> and its "private/…" tree
    exe_mod.linkLibrary(core);
    exe_mod.addObjectFile(slint_lib_dir.path(b, slintLinkName(target.result.os.tag)));
    if (target.result.os.tag == .windows) {
        // `std.crypto.Certificate.Bundle` reads the Windows system cert store, so
        // every HTTPS path in the core (RPC, install, price, the updater) needs
        // crypt32. The TUI gets it for free — Zig propagates the `extern
        // "crypt32"` dependency for a Zig-root exe — but here the core is a
        // *static library* linked into a C++ executable, and that propagation
        // stops at the archive. Without this the link fails on CertOpenSystemStoreW
        // and friends.
        exe_mod.linkSystemLibrary("crypt32", .{});

        // Windows has no rpath of any kind, and no delay-load escape either: 21
        // of the imports are *data* objects (`RectangleVTable`, `EmptyVTable`, …)
        // and delay-load only ever covers function thunks. The DLL therefore has
        // to sit beside the exe, which is the first place the loader looks. What
        // that costs the self-updater — no versioned pairing, so a staged
        // `--selftest` instead — is in `src/update.zig`'s `runtime_flat`.
        const gui = b.addExecutable(.{ .name = "boxwallet-gui", .root_module = exe_mod });

        // Without this the PE is marked console-subsystem and Windows opens a
        // console window behind the GUI on every launch. `main` still works as
        // the entry point: mingw-w64's `WinMainCRTStartup` and `mainCRTStartup`
        // both call the same `__tmainCRTStartup`, so switching the subsystem
        // doesn't oblige us to write a `WinMain`.
        gui.subsystem = .windows;
        return gui;
    }
    switch (rpath) {
        .package_dir => exe_mod.addRPath(slint_lib_dir),
        // Not a bare origin token: the runtime lives in a version-scoped
        // subdirectory so a new exe and an old one resolve *different* files.
        // That is what makes the self-updater's two-file problem a one-file
        // problem — see `slint_version`.
        //
        // Mach-O needs this as much as ELF does, and more visibly: the dylib's
        // install name is `@rpath/libslint_cpp.dylib`, so without an `LC_RPATH`
        // dyld has nothing to resolve it against and the binary won't launch.
        .origin => exe_mod.addRPathSpecial(b.fmt("{s}/{s}", .{ originToken(target.result.os.tag), slint_dir })),
    }

    return b.addExecutable(.{ .name = "boxwallet-gui", .root_module = exe_mod });
}

/// `zig build gui-release`: a distributable bundle per target — the GUI exe
/// beside the Slint runtime it was linked against and Slint's licences, zipped so
/// it runs on another machine after unzip (no install, just the files together).
/// The exe finds the runtime by rpath (`$ORIGIN/slint-<ver>/`) everywhere except
/// Windows, which has no rpath and takes the DLL flat instead.
///
/// Every target here cross-builds from this one Linux host — including Windows,
/// whose only Slint dependency is a DLL with a pure-C export surface. What a
/// native host is still needed for is *running* the result, which is why the
/// `--selftest` gate lives in CI (`.github/workflows/gui-selftest.yml`) and
/// anything it hasn't cleared stays in `gui_targets_unverified`.
///
/// Unlike the TUI's `release` step these are **not** static musl binaries: the
/// prebuilt Slint runtime is glibc-linked and pulls in the system graphics stack
/// (fontconfig, freetype, libxkbcommon, libinput, libgbm, libudev, libstdc++), so
/// a Linux bundle needs a reasonably current desktop. The TUI remains the option
/// for old or headless machines. `zip`/`strip` are host tools.
fn addGuiReleaseStep(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    comptime opts: struct {
        step_name: []const u8,
        desc: []const u8,
        /// Output directory under `zig-out/`, and the prefix for staging.
        out_dir: []const u8,
        targets: []const GuiTarget,
    },
) *std.Build.Step {
    _ = optimize; // release bundles are always ReleaseSafe, like the TUI's
    const step = b.step(opts.step_name, opts.desc);

    // Rewrites an exe's DT_NEEDED for libslint_cpp.so to the bare basename so the
    // `$ORIGIN` rpath resolves it from beside the exe on another machine (the
    // package's `.so` has no SONAME, so the linker baked in the fetched path).
    // Host-built and arch-agnostic: it patches the ELF string table, so one
    // instance serves every bundle.
    const fixer = b.addExecutable(.{
        .name = "fixneeded",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fixneeded.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });


    // Bundles are built under `gui-release/staging/<name>/` and the publishable
    // assets land flat in `gui-release/`, because the bare-exe asset and the
    // bundle directory would otherwise want the same name.
    var sum_cmds: []const u8 = "";
    var hash_names: []const u8 = "";
    var packs: [opts.targets.len]?*std.Build.Step = @splat(null);

    inline for (opts.targets, 0..) |t, ti| {
        const resolved = b.resolveTargetQuery(t.query);
        // Skipped rather than failed while a lazy package is still being fetched
        // (and on a host with no slint-compiler), so the step re-runs complete.
        if (buildGuiExe(b, resolved, .ReleaseSafe, .origin)) |exe| {
            // Non-null for the same reason the exe is: `buildGuiExe` returns null
            // unless the package is already on disk.
            const dep = slintPackage(b, resolved.result).?;
            const stage = opts.out_dir ++ "/staging/" ++ t.name;
            const is_windows = comptime t.query.os_tag.? == .windows;

            // What the exe is called inside the bundle, and the name of the
            // bare-exe asset published beside the zip (`guiExeAsset`). Windows
            // needs the `.exe` in both places — the loader keys off it, and a
            // browser download without it is inert.
            const bundle_exe = if (is_windows) "boxwallet-gui.exe" else "boxwallet-gui";
            const exe_asset = comptime guiExeAsset(t);

            // exe → staging/<bundle>/boxwallet-gui[.exe]
            const inst_exe = b.addInstallFile(exe.getEmittedBin(), stage ++ "/" ++ bundle_exe);

            // ELF only. `addObjectFile` bakes the fetched package's absolute
            // path into DT_NEEDED (the `.so` has no SONAME), so it has to be cut
            // back to a bare basename for the rpath to find it on another
            // machine. Mach-O needs no such fix: the dylib carries its own
            // install name, `@rpath/libslint_cpp.dylib`, and that is what the
            // linker records — verified on a cross-built binary. PE needs none
            // either: the import table records the bare `slint_cpp.dll` that the
            // import library named, never a build-machine path.
            const needs_fix = comptime switch (t.query.os_tag.?) {
                .macos, .windows => false,
                else => true,
            };
            const ready: *std.Build.Step = if (!needs_fix) blk: {
                break :blk &inst_exe.step;
            } else blk: {
                const fix = b.addRunArtifact(fixer);
                fix.addArg(b.getInstallPath(.prefix, stage ++ "/" ++ bundle_exe));
                fix.step.dependOn(&inst_exe.step);
                break :blk &fix.step;
            };

            // The Slint runtime, shipped exactly as upstream published it, in a
            // directory named for its version — see `slint_version` for why the
            // directory and not the file.
            //
            // Deliberately not stripped: measured, it saves 0.7 MB of a 16 MB
            // zip (the symbols compress well), and no stripper here handles both
            // arches — the host `strip` refuses a foreign ELF outright, and `zig
            // objcopy --strip-debug` reports "unimplemented" for a shared object.
            // Not worth a hand-rolled ELF rewriter, and an untouched binary still
            // matches upstream's own checksum.
            //
            // Windows is the exception, and it isn't a choice: PE has no rpath,
            // and delay-load — the usual stand-in — can't help when 21 of the
            // imports are data objects. The DLL therefore ships **flat beside the
            // exe**, the first place the loader looks. The pairing that
            // `slint-<ver>/` buys everyone else is recovered in the updater
            // instead, by selftesting the staged pair before it swaps.
            const runtime_in_bundle = if (is_windows) "" else slint_dir ++ "/";
            const so_name = comptime slintRuntimeName(t.query.os_tag.?);
            const inst_so = b.addInstallFile(
                dep.lib(b).path(b, so_name),
                stage ++ "/" ++ runtime_in_bundle ++ so_name,
            );

            // Slint's licence + third-party notices travel with the binary we
            // redistribute; shipping the runtime without them isn't ours to do.
            const inst_lic = b.addInstallFile(dep.licenses(b).path(b, "LICENSE.md"), stage ++ "/SLINT-LICENSE.md");
            const inst_third = b.addInstallFile(dep.licenses(b).path(b, "THIRDPARTY.md"), stage ++ "/SLINT-THIRDPARTY.md");

            // Per-platform extras, and *only* where they mean something.
            //
            // Linux gets desktop integration, so the panel and app launcher show
            // the BoxWallet logo rather than a generic placeholder. On Wayland an
            // app can't set its own window icon, so the compositor matches the
            // window's app_id against an installed desktop entry — there has to
            // be one. Optional to *run* BoxWallet, which is why it's a script
            // the user chooses to run rather than something we do behind their
            // back on first launch.
            //
            // These sit inside the zip, so SHA256SUMS needs no new lines: the
            // bundle's existing hash covers them.
            //
            // Keyed on `linux`, not "not Windows": an XDG desktop entry, a PNG
            // icon and a shell installer are as meaningless on macOS as they are
            // on Windows. The macOS bundle shipped all three for one release
            // (v0.8.7) because this branch predated having a macOS target at all.
            var extra_steps: [3]*std.Build.Step = undefined;
            var extra_len: usize = 0;
            const is_linux = comptime t.query.os_tag.? == .linux;
            if (is_linux) {
                const inst_desktop = b.addInstallFile(b.path("gui/boxwallet.desktop"), stage ++ "/boxwallet.desktop");
                const inst_appicon = b.addInstallFile(b.path("gui/icons/boxwallet.png"), stage ++ "/icons/boxwallet.png");
                const inst_dscript = b.addInstallFile(b.path("gui/install-desktop.sh"), stage ++ "/install-desktop.sh");
                extra_steps = .{ &inst_desktop.step, &inst_appicon.step, &inst_dscript.step };
                extra_len = 3;
            } else if (is_windows) {
                // Windows ships a readme instead, and it earns its place: the
                // Slint runtime links Microsoft's C++ runtime, which is *not*
                // part of Windows, and when it's absent the loader refuses the
                // program before `main` — no window, no message, nothing we can
                // report. A user with a clean install sees a double-click do
                // nothing, so the one place that can explain it is a file in the
                // folder. `tools/check-windows-deps.sh` keeps this honest.
                const inst_readme = b.addInstallFile(b.path("gui/README-WINDOWS.txt"), stage ++ "/README.txt");
                extra_steps[0] = &inst_readme.step;
                extra_len = 1;
            } else if (comptime t.query.os_tag.? == .macos) {
                // macOS has a first-launch trap of the same shape, and the same
                // answer: a file in the folder, because nothing of ours gets to
                // run. The bundle is ad-hoc signed (which Apple Silicon demands
                // of any binary) but not notarized, which needs a paid developer
                // account — so a zip downloaded through a browser carries
                // `com.apple.quarantine` and Gatekeeper refuses it with a
                // message that reads like a corrupt download.
                const inst_readme = b.addInstallFile(b.path("gui/README-MACOS.txt"), stage ++ "/README.txt");
                extra_steps[0] = &inst_readme.step;
                extra_len = 1;
            }

            // Zip the bundle from staging into gui-release/, and drop the bare
            // exe beside it. Both are published: the updater fetches the 4.8 MB
            // exe alone when the installed runtime already matches, and falls
            // back to the 16 MB bundle when it doesn't.
            const pack = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    // chmod before zipping: `addInstallFile` drops the execute
                    // bit, and zip stores whatever mode it finds — so without
                    // this the installer arrives non-executable and has to be
                    // run as `sh install-desktop.sh`. Only Linux ships that
                    // script; anywhere else this is an `&&` chain that would
                    // fail on a file the bundle deliberately doesn't have.
                    "cd \"$1\" && {3s}rm -f {0s}.zip {2s} && (cd staging && zip -r -q ../{0s}.zip {0s}) && cp staging/{0s}/{1s} {2s}",
                    .{
                        t.name,
                        bundle_exe,
                        exe_asset,
                        if (is_linux) "chmod +x staging/" ++ t.name ++ "/install-desktop.sh && " else "",
                    },
                ),
                "pack-gui",
                b.getInstallPath(.prefix, opts.out_dir),
            });
            pack.step.dependOn(ready);
            pack.step.dependOn(&inst_so.step);
            pack.step.dependOn(&inst_lic.step);
            pack.step.dependOn(&inst_third.step);
            for (extra_steps[0..extra_len]) |s| pack.step.dependOn(s);
            step.dependOn(&pack.step);
            packs[ti] = &pack.step;

            // One RUNTIME line per target: which Slint the release needs, and
            // the hash of the runtime it ships. The *version* is the pairing
            // protocol — the updater compares it against the `slint-<ver>/`
            // directory beside the installed exe to decide whether it can fetch
            // the 4.8 MB exe alone or must take the 16 MB bundle. The hash is
            // there so it can also verify an installed runtime it intends to
            // keep using.
            //
            // Kept out of SHA256SUMS because the runtime is not a top-level
            // asset: listing it by its in-bundle path made `sha256sum -c` report
            // a missing file and a release look corrupt. RUNTIME *is* listed in
            // SHA256SUMS, so it's verified like everything else.
            //
            // Windows keeps the `slint-<ver>` token even though it has no such
            // directory: the version is the *pairing key* the updater compares,
            // not a path, so the manifest stays one shape across front-ends and
            // platforms. Only where the hash is read from differs.
            // The name printed is the *asset* (`update-…-x86_64.exe` on Windows)
            // because that is what the updater looks itself up by; the directory
            // read from is the *staging* one, which never carries the suffix. A
            // line the updater can't find under its own name is `verify_failed`,
            // not "assume the runtime matches", so this name and `assetFor(.gui)`
            // have to stay equal.
            sum_cmds = b.fmt(
                "{0s} && rt=$(cd staging/{4s}/{5s} && sha256sum {3s} | cut -d' ' -f1) && printf '%s  {2s}  %s\\n' {1s} \"$rt\" >> RUNTIME",
                .{ sum_cmds, exe_asset, slint_dir, so_name, t.name, if (is_windows) "." else slint_dir },
            );
            hash_names = b.fmt("{0s} {1s} {2s}.zip", .{ hash_names, exe_asset, t.name });
        }
    }

    // One pass after every bundle is packed, so both files are complete or
    // absent — a partial SHA256SUMS would let the updater verify some assets and
    // silently skip others. RUNTIME is written first and then hashed into
    // SHA256SUMS, so the pairing information is covered by the same trust root as
    // the downloads.
    if (sum_cmds.len > 0) {
        const sums = b.addSystemCommand(&.{
            "sh", "-c",
            b.fmt("cd \"$1\" && rm -f SHA256SUMS RUNTIME{s} && sha256sum{s} RUNTIME > SHA256SUMS", .{ sum_cmds, hash_names }),
            "sums-gui",
            b.getInstallPath(.prefix, opts.out_dir),
        });
        for (packs) |p| if (p) |ps| sums.step.dependOn(ps);
        step.dependOn(&sums.step);
    }
    return step;
}

/// `zig build release` cross-compiles every distributable binary into
/// `zig-out/release/`, named exactly as the in-app updater expects to download
/// them (`boxwallet-<os>-<arch>[.exe]`, see `src/update.zig`), and writes a
/// `SHA256SUMS` the updater verifies each download against. Built locally on
/// one Linux host — Zig cross-compiles all targets with no external toolchain.
///
/// Linux binaries target static musl so they run on any glibc version (and
/// low-spec/old machines) without a runtime dependency; the app links no libc,
/// so the result is a single self-contained file. Built `ReleaseSafe` to keep
/// safety checks in a wallet-adjacent tool.
fn addReleaseStep(b: *std.Build) *std.Build.Step {

    const release_step = b.step("release", "Cross-build all release binaries + SHA256SUMS into zig-out/release/");

    // One `sha256sum` pass over the finished binaries, run after every install.
    // The file list is derived from `release_targets` so it can't drift from
    // what's actually built. POSIX-only (this is a Linux build host).
    var names: []const u8 = "";
    inline for (release_targets) |t| names = b.fmt("{s} {s}", .{ names, t.name });
    const script = b.fmt("cd \"$1\" && sha256sum{s} > SHA256SUMS", .{names});
    const sums = b.addSystemCommand(&.{ "sh", "-c", script, "release-sums", b.getInstallPath(.prefix, "release") });

    inline for (release_targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        const exe = b.addExecutable(.{
            .name = "boxwallet-tui",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                // Strip debug info — these are distributables, so keep the
                // download small (matters on low-spec/slow-link machines).
                .strip = true,
            }),
        });
        exe.root_module.addImport("zigzag", b.dependency("zigzag", .{
            .target = resolved,
            .optimize = .ReleaseSafe,
        }).module("zigzag"));

        // Install the emitted binary under its release asset name.
        const inst = b.addInstallFile(exe.getEmittedBin(), b.fmt("release/{s}", .{t.name}));
        sums.step.dependOn(&inst.step);
    }

    release_step.dependOn(&sums.step);
    return release_step;
}

/// `zig build release-all`: everything a published release needs, assembled and
/// checked in one place — `zig-out/dist/`.
///
/// The two release steps each write their own `SHA256SUMS`, and both updaters
/// fetch `<tag>/SHA256SUMS`. A release can only carry one file of that name, so
/// publishing either one on its own leaves the *other* front-end unable to find
/// its asset's checksum — a `verify_failed` on every update check, for everyone.
/// This merges them into a single manifest covering every asset, which is the
/// only shape that works: one release, one trust root.
///
/// It also refuses to assemble a partial release. `gui-release` skips a target
/// whose Slint package hasn't been fetched (deliberately — that's what keeps
/// `zig build` and `test` free of it), so a distracted release could otherwise
/// publish TUI-only assets under a version the GUI updater then can't satisfy:
/// every GUI user would be told an update exists and be unable to take it. The
/// expected filenames come from `release_targets`/`gui_targets`, so the check
/// tracks whatever is registered rather than a hand-kept list.
fn addReleaseAllStep(b: *std.Build, release_step: *std.Build.Step, gui_step: *std.Build.Step) void {
    const step = b.step("release-all", "Assemble every release asset + one SHA256SUMS into zig-out/dist/");

    // What the release must contain. The bare exe and the bundle are both
    // published per GUI target: the updater takes the exe alone when the
    // installed Slint runtime already matches, and the bundle when it doesn't.
    // The two are *not* the same stem on Windows — `…-x86_64.exe` beside
    // `…-x86_64.zip` — so the exe is asked for by `guiExeAsset` and only the zip
    // is derived from `t.name`.
    var expected: []const u8 = "";
    inline for (release_targets) |t| expected = b.fmt("{s} '{s}'", .{ expected, t.name });
    inline for (gui_targets) |t| expected = b.fmt("{s} '{s}' '{s}.zip'", .{ expected, comptime guiExeAsset(t), t.name });
    expected = b.fmt("{s} 'RUNTIME'", .{expected});

    // `set -e` so a missing source file stops the assembly rather than leaving a
    // half-built dist someone might upload. The final `sha256sum -c` is the real
    // gate: it re-reads every file from `dist/` and fails on a missing or
    // corrupted one, so what's verified is exactly what gets uploaded.
    const script = b.fmt(
        \\set -e
        \\cd "$1"
        \\rm -rf dist && mkdir dist
        \\for f in{0s}; do
        \\  if [ -f "release/$f" ]; then cp "release/$f" "dist/$f"
        \\  elif [ -f "gui-release/$f" ]; then cp "gui-release/$f" "dist/$f"
        \\  else echo "release-all: missing asset: $f" >&2; exit 1; fi
        \\done
        \\cat release/SHA256SUMS gui-release/SHA256SUMS > dist/SHA256SUMS
        \\cd dist && sha256sum -c SHA256SUMS
        \\echo "release-all: $(ls | grep -vc '^SHA256SUMS$') assets + SHA256SUMS ready to upload"
    , .{expected});

    const assemble = b.addSystemCommand(&.{
        "sh", "-c", script, "release-all", b.getInstallPath(.prefix, ""),
    });
    assemble.step.dependOn(release_step);
    assemble.step.dependOn(gui_step);
    step.dependOn(&assemble.step);
}
