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

/// GUI targets not yet cleared for release. They build correctly here, but
/// nothing on this host can *run* a Mach-O, and the whole point of the
/// `--selftest` pre-flight is that an exe/runtime mismatch fails inside the
/// loader before `main` — invisibly. So these are built by their own step and
/// deliberately left out of `release-all`, which means no release can publish
/// one by accident. Move an entry into `gui_targets` once it has launched on
/// real hardware.
const gui_targets_unverified = [_]GuiTarget{
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "boxwallet-gui-macos-aarch64" },
};
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
};


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
        .desc = "Bundle the Linux GUIs (exe + Slint runtime) into zips",
        .out_dir = "gui-release",
        .targets = &gui_targets,
    });
    addReleaseAllStep(b, release_step, gui_release_step);

    // Built, but not releasable: see `gui_targets_unverified`. Its own step and
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
///   * macOS: only `Darwin-arm64` is published (no Intel build), and linking it
///     needs the Apple SDK frameworks Zig doesn't ship — a native macOS host.
///   * Windows: published as an NSIS installer `.exe` (not an archive `zig
///     fetch` can unpack) built against the MSVC ABI — a native Windows host.
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
        else => null,
    };
}

/// The Slint runtime's filename for `t`. Named per-OS because the whole
/// pairing scheme keys off this file: it's what gets hashed into `RUNTIME`,
/// what lands in `slint-<ver>/`, and what `src/update.zig` looks for when
/// deciding whether it can fetch the bare exe.
fn slintRuntimeName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .macos => "libslint_cpp.dylib",
        else => "libslint_cpp.so",
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
    const dep_name = slintDepName(target.result) orelse return null;
    const slint = b.lazyDependency(dep_name, .{}) orelse return null;
    const slint_lib_dir = slint.path("lib");
    const slint_inc_dir = slint.path("include/slint");

    // slint-compiler: gui/app.slint -> generated C++ header. It runs on the build
    // host, so it comes from the host's package, not the target's — and unlike
    // the copy inside the C++ package it's self-contained (no LD_LIBRARY_PATH).
    const compiler_dep_name = slintCompilerDepName(b.graph.host.result) orelse return null;
    const slint_compiler = b.lazyDependency(compiler_dep_name, .{}) orelse return null;

    // Built as a bare Run so the program itself can be a `LazyPath` into the
    // fetched package (an argv string would have to be a repo-relative path).
    const gen = std.Build.Step.Run.create(b, "slint-compiler app.slint");
    gen.addFileArg(slint_compiler.path("slint-compiler"));
    gen.addArgs(&.{ "-f", "cpp", "--style", "fluent", "-o" });
    const gen_header = gen.addOutputFileArg("app.slint.h");
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
    exe_mod.addObjectFile(slint_lib_dir.path(b, slintRuntimeName(target.result.os.tag)));
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

/// `zig build gui-release`: a distributable bundle per Linux target — the GUI exe
/// (rpath `$ORIGIN`) beside a stripped `libslint_cpp.so` and Slint's licences,
/// zipped so it runs on another machine after unzip (no install, just the files
/// together).
///
/// Linux-only, and unlike the TUI's `release` step these are **not** static musl
/// binaries: the prebuilt Slint runtime is glibc-linked and pulls in the system
/// graphics stack (fontconfig, freetype, libxkbcommon, libinput, libgbm, libudev,
/// libstdc++), so a bundle needs a reasonably current desktop Linux. The TUI
/// remains the option for old or headless machines.
///
/// macOS and Windows bundles need a native host — see `slintDepName` — so they
/// belong in a CI matrix rather than here. `zip`/`strip` are host tools.
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
            const dep = b.lazyDependency(slintDepName(resolved.result).?, .{}).?;
            const stage = opts.out_dir ++ "/staging/" ++ t.name;

            // exe → staging/<bundle>/boxwallet-gui
            const inst_exe = b.addInstallFile(exe.getEmittedBin(), stage ++ "/boxwallet-gui");

            // ELF only. `addObjectFile` bakes the fetched package's absolute
            // path into DT_NEEDED (the `.so` has no SONAME), so it has to be cut
            // back to a bare basename for the rpath to find it on another
            // machine. Mach-O needs no such fix: the dylib carries its own
            // install name, `@rpath/libslint_cpp.dylib`, and that is what the
            // linker records — verified on a cross-built binary.
            const ready: *std.Build.Step = if (resolved.result.os.tag == .macos) blk: {
                break :blk &inst_exe.step;
            } else blk: {
                const fix = b.addRunArtifact(fixer);
                fix.addArg(b.getInstallPath(.prefix, stage ++ "/boxwallet-gui"));
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
            const so_name = comptime slintRuntimeName(t.query.os_tag.?);
            const inst_so = b.addInstallFile(
                dep.path("lib/" ++ so_name),
                stage ++ "/" ++ slint_dir ++ "/" ++ so_name,
            );

            // Slint's licence + third-party notices travel with the binary we
            // redistribute; shipping the runtime without them isn't ours to do.
            const inst_lic = b.addInstallFile(dep.path("licenses/LICENSE.md"), stage ++ "/SLINT-LICENSE.md");
            const inst_third = b.addInstallFile(dep.path("licenses/THIRDPARTY.md"), stage ++ "/SLINT-THIRDPARTY.md");

            // Desktop integration, so the panel and app launcher show the
            // BoxWallet logo rather than a generic placeholder. On Wayland an
            // app can't set its own window icon, so the compositor matches the
            // window's app_id against an installed desktop entry — there has to
            // be one. Optional to *run* BoxWallet, which is why it's a script
            // the user chooses to run rather than something we do behind their
            // back on first launch.
            //
            // These sit inside the zip, so SHA256SUMS needs no new lines: the
            // bundle's existing hash covers them.
            const inst_desktop = b.addInstallFile(b.path("gui/boxwallet.desktop"), stage ++ "/boxwallet.desktop");
            const inst_appicon = b.addInstallFile(b.path("gui/icons/boxwallet.png"), stage ++ "/icons/boxwallet.png");
            const inst_dscript = b.addInstallFile(b.path("gui/install-desktop.sh"), stage ++ "/install-desktop.sh");

            // Zip the bundle from staging into gui-release/, and drop a copy of
            // the bare exe beside it. Both are published: the updater fetches the
            // 4.8 MB exe alone when the installed runtime already matches, and
            // only falls back to the 16 MB bundle when it doesn't.
            const pack = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt(
                    // chmod before zipping: `addInstallFile` drops the execute
                    // bit, and zip stores whatever mode it finds — so without
                    // this the installer arrives non-executable and has to be
                    // run as `sh install-desktop.sh`.
                    "cd \"$1\" && chmod +x staging/{0s}/install-desktop.sh && rm -f {0s}.zip {0s} && (cd staging && zip -r -q ../{0s}.zip {0s}) && cp staging/{0s}/boxwallet-gui {0s}",
                    .{t.name},
                ),
                "pack-gui",
                b.getInstallPath(.prefix, opts.out_dir),
            });
            pack.step.dependOn(ready);
            pack.step.dependOn(&inst_so.step);
            pack.step.dependOn(&inst_lic.step);
            pack.step.dependOn(&inst_third.step);
            pack.step.dependOn(&inst_desktop.step);
            pack.step.dependOn(&inst_appicon.step);
            pack.step.dependOn(&inst_dscript.step);
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
            sum_cmds = b.fmt(
                "{0s} && printf '%s  {2s}  ' {1s} >> RUNTIME && (cd staging/{1s}/{2s} && sha256sum {3s} | cut -d' ' -f1) >> RUNTIME",
                .{ sum_cmds, t.name, slint_dir, so_name },
            );
            hash_names = b.fmt("{s} {1s} {1s}.zip", .{ hash_names, t.name });
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
    var expected: []const u8 = "";
    inline for (release_targets) |t| expected = b.fmt("{s} '{s}'", .{ expected, t.name });
    inline for (gui_targets) |t| expected = b.fmt("{s} '{s}' '{s}.zip'", .{ expected, t.name, t.name });
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
