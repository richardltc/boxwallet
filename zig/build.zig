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
