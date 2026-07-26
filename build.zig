const std = @import("std");

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

    addReleaseStep(b);
    addGuiStep(b, target, optimize);
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

    addGuiReleaseStep(b, optimize);
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
fn slintDepName(t: std.Target) ?[]const u8 {
    if (t.os.tag != .linux) return null;
    return switch (t.cpu.arch) {
        .x86_64 => "slint_linux_x86_64",
        .aarch64 => "slint_linux_aarch64",
        else => null,
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
    exe_mod.addObjectFile(slint_lib_dir.path(b, "libslint_cpp.so"));
    switch (rpath) {
        .package_dir => exe_mod.addRPath(slint_lib_dir),
        .origin => exe_mod.addRPathSpecial("$ORIGIN"),
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
fn addGuiReleaseStep(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    _ = optimize; // release bundles are always ReleaseSafe, like the TUI's
    const step = b.step("gui-release", "Bundle the Linux GUIs (exe + Slint runtime) into zips");

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

    const GuiTarget = struct { query: std.Target.Query, name: []const u8 };
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

    inline for (gui_targets) |t| {
        const resolved = b.resolveTargetQuery(t.query);
        // Skipped rather than failed while a lazy package is still being fetched
        // (and on a host with no slint-compiler), so the step re-runs complete.
        if (buildGuiExe(b, resolved, .ReleaseSafe, .origin)) |exe| {
            const dep = b.lazyDependency(slintDepName(resolved.result).?, .{}).?;

            // exe → gui-release/<bundle>/boxwallet-gui
            const inst_exe = b.addInstallFile(exe.getEmittedBin(), b.fmt("gui-release/{s}/boxwallet-gui", .{t.name}));
            const fix = b.addRunArtifact(fixer);
            fix.addArg(b.getInstallPath(.prefix, b.fmt("gui-release/{s}/boxwallet-gui", .{t.name})));
            fix.step.dependOn(&inst_exe.step);

            // The Slint runtime, shipped exactly as upstream published it.
            // Deliberately not stripped: measured, it saves 0.7 MB of a 13.7 MB
            // zip (the symbols compress well), and no stripper here handles both
            // arches — the host `strip` refuses a foreign ELF outright, and `zig
            // objcopy --strip-debug` reports "unimplemented" for a shared object.
            // Not worth a hand-rolled ELF rewriter, and an untouched binary still
            // matches upstream's own checksum.
            const inst_so = b.addInstallFile(dep.path("lib/libslint_cpp.so"), b.fmt("gui-release/{s}/libslint_cpp.so", .{t.name}));

            // Slint's licence + third-party notices travel with the binary we
            // redistribute; shipping the runtime without them isn't ours to do.
            const inst_lic = b.addInstallFile(dep.path("licenses/LICENSE.md"), b.fmt("gui-release/{s}/SLINT-LICENSE.md", .{t.name}));
            const inst_third = b.addInstallFile(dep.path("licenses/THIRDPARTY.md"), b.fmt("gui-release/{s}/SLINT-THIRDPARTY.md", .{t.name}));

            // zip the bundle dir (recreated each run so it never accretes stale files).
            const zip = b.addSystemCommand(&.{
                "sh", "-c",
                b.fmt("cd \"$1\" && rm -f {s}.zip && zip -r -q {s}.zip {s}", .{ t.name, t.name, t.name }),
                "zip-gui",
                b.getInstallPath(.prefix, "gui-release"),
            });
            zip.step.dependOn(&fix.step);
            zip.step.dependOn(&inst_so.step);
            zip.step.dependOn(&inst_lic.step);
            zip.step.dependOn(&inst_third.step);
            step.dependOn(&zip.step);
        }
    }
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
fn addReleaseStep(b: *std.Build) void {
    const ReleaseTarget = struct { query: std.Target.Query, name: []const u8 };
    const release_targets = [_]ReleaseTarget{
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .name = "boxwallet-linux-x86_64" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .name = "boxwallet-linux-aarch64" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "boxwallet-macos-x86_64" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "boxwallet-macos-aarch64" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "boxwallet-windows-x86_64.exe" },
    };

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
}
