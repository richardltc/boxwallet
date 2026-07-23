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
/// Entirely Zig-orchestrated — no CMake, no cargo. `build.zig` runs the vendored
/// `slint-compiler` to turn `gui/app.slint` into a C++ header, compiles the C++
/// glue (`gui/main.cpp`) with Zig's own clang, and links it against the Zig core
/// (built here as a static lib from `src/capi.zig`) plus the vendored Slint
/// runtime. The GUI's `main` lives in the C++ TU, so the executable's Zig module
/// has no root source file — it's a pure C/C++ executable that pulls its C-ABI
/// symbols from the linked-in core lib.
///
/// The only pieces Zig can't build (Slint is a Rust project) are vendored under
/// `third_party/slint/`: the runtime shared lib, the headers, and the compiler.
/// The prebuilt Slint C++ package ships a *shared* `libslint_cpp.so` (no static
/// archive), so the GUI links it dynamically and finds it via an rpath into the
/// vendored dir — one sidecar library on Linux, not a fully-static single file.
///
/// Additive: this touches none of the TUI `exe`/`test`/`release` steps.
fn addGuiStep(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // `zig build gui`: dev build. The rpath points at the vendored lib dir so it
    // runs in-place from the repo.
    const exe = buildGuiExe(b, target, optimize, .vendored_dir);
    const install_exe = b.addInstallArtifact(exe, .{});
    const gui_step = b.step("gui", "Build the optional Slint GUI (proof-of-concept)");
    gui_step.dependOn(&install_exe.step);

    addGuiReleaseStep(b, target);
}

const RPathKind = enum { vendored_dir, origin };

/// Build the GUI executable. `rpath` selects how it finds `libslint_cpp.so` at
/// run time: `.vendored_dir` (absolute path into the repo, for in-place `zig
/// build gui`) or `.origin` (`$ORIGIN`, so a distributed bundle finds the `.so`
/// sitting next to the exe).
fn buildGuiExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    rpath: RPathKind,
) *std.Build.Step.Compile {
    const slint_lib_dir = b.path("third_party/slint/lib");
    const slint_inc_dir = b.path("third_party/slint/include/slint");

    // slint-compiler: gui/app.slint -> generated C++ header. The compiler itself
    // links libslint_cpp.so, so point its loader at the vendored lib dir.
    const gen = b.addSystemCommand(&.{
        b.pathFromRoot("third_party/slint/bin/slint-compiler"),
        "-f", "cpp",
        "--style", "fluent",
        "-o",
    });
    const gen_header = gen.addOutputFileArg("app.slint.h");
    gen.addFileArg(b.path("gui/app.slint"));
    gen.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathFromRoot("third_party/slint/lib"));

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

    // The GUI executable: pure C/C++ (main is in main.cpp), no Zig root. In Zig
    // 0.16 the C-source/include/link wiring lives on the Module.
    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .strip = strip,
    });
    exe_mod.addCSourceFile(.{ .file = b.path("gui/main.cpp"), .flags = &.{"-std=c++20"} });
    exe_mod.addIncludePath(gen_header.dirname()); // generated app.slint.h (also orders the compile after gen)
    exe_mod.addIncludePath(b.path("gui"));
    exe_mod.addIncludePath(b.path("include")); // boxwallet.h
    exe_mod.addIncludePath(slint_inc_dir); // <slint.h> and its "private/…" tree
    exe_mod.linkLibrary(core);
    exe_mod.addObjectFile(slint_lib_dir.path(b, "libslint_cpp.so"));
    switch (rpath) {
        .vendored_dir => exe_mod.addRPath(slint_lib_dir),
        .origin => exe_mod.addRPathSpecial("$ORIGIN"),
    }

    return b.addExecutable(.{ .name = "boxwallet-gui", .root_module = exe_mod });
}

/// `zig build gui-release`: a distributable Linux bundle — the GUI exe (rpath
/// `$ORIGIN`) beside a stripped `libslint_cpp.so`, zipped so it runs on another
/// machine after unzip (no install, just the two files together). Host-only:
/// the GUI links the vendored Linux-x86_64 Slint runtime, so this produces the
/// linux-x86_64 bundle. `zip`/`strip` are host tools (Linux build host).
fn addGuiReleaseStep(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const bundle = "boxwallet-gui-linux-x86_64";
    const exe = buildGuiExe(b, target, .ReleaseSafe, .origin);

    // exe → gui-release/<bundle>/boxwallet-gui
    const inst_exe = b.addInstallFile(exe.getEmittedBin(), b.fmt("gui-release/{s}/boxwallet-gui", .{bundle}));

    // Rewrite the exe's DT_NEEDED for libslint_cpp.so to the bare basename so the
    // `$ORIGIN` rpath resolves it from beside the exe on another machine (the
    // vendored `.so` has no SONAME, so the linker baked in the repo path).
    const fixer = b.addExecutable(.{
        .name = "fixneeded",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fixneeded.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const fix = b.addRunArtifact(fixer);
    fix.addArg(b.getInstallPath(.prefix, b.fmt("gui-release/{s}/boxwallet-gui", .{bundle})));
    fix.step.dependOn(&inst_exe.step);

    // strip the Slint runtime → gui-release/<bundle>/libslint_cpp.so
    const strip_so = b.addSystemCommand(&.{ "strip", "--strip-unneeded", "-o" });
    const so_out = strip_so.addOutputFileArg("libslint_cpp.so");
    strip_so.addFileArg(b.path("third_party/slint/lib/libslint_cpp.so"));
    const inst_so = b.addInstallFile(so_out, b.fmt("gui-release/{s}/libslint_cpp.so", .{bundle}));

    // zip the bundle dir (recreated each run so it never accretes stale files).
    const zip = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt("cd \"$1\" && rm -f {s}.zip && zip -r -q {s}.zip {s}", .{ bundle, bundle, bundle }),
        "zip-gui",
        b.getInstallPath(.prefix, "gui-release"),
    });
    zip.step.dependOn(&fix.step);
    zip.step.dependOn(&inst_so.step);

    const step = b.step("gui-release", "Bundle the Linux GUI (exe + Slint runtime) into a zip");
    step.dependOn(&zip.step);
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
