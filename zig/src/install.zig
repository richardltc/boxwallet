const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;

/// Resolve the BoxWallet data directory that coin daemons are extracted into,
/// matching the Go app's `HomeFolder`:
///   - POSIX:   `<home>/.boxwallet`
///   - Windows: `<home>/AppData/Roaming/BoxWallet`
///
/// `home_dir` is the process home directory (ZigZag captures this as
/// `ctx.home_dir` from `$HOME` / `%USERPROFILE%`). The caller owns the returned
/// slice. The directory itself is created lazily by `downloadAndExtract`.
pub fn installRoot(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    return if (comptime builtin.os.tag == .windows)
        std.fs.path.join(allocator, &.{ home_dir, "AppData", "Roaming", "BoxWallet" })
    else
        std.fs.path.join(allocator, &.{ home_dir, ".boxwallet" });
}

/// Archive format a coin's daemon bundle ships in.
pub const Format = enum { tar_gz, zip };

/// Which stage of an install a progress report refers to.
pub const Phase = enum { download, extract };

/// Optional sink for install progress, so a frontend can draw a progress bar.
/// `func` is invoked repeatedly with the running byte count for the active
/// `phase`; `total` is the expected byte count (0 when unknown). `current` is
/// monotonic within a phase and ends at `total`.
pub const Progress = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, phase: Phase, current: u64, total: u64) void,

    fn report(self: Progress, phase: Phase, current: u64, total: u64) void {
        self.func(self.ctx, phase, current, total);
    }
};

/// Reports `phase`/`current`/`total` to `progress` when it is non-null.
fn report(progress: ?Progress, phase: Phase, current: u64, total: u64) void {
    if (progress) |p| p.report(phase, current, total);
}

/// Download `url` and extract it into `dest_root` (created if missing).
///
/// `strip` leading path components are dropped — coin archives wrap their
/// binaries in a versioned directory (e.g. `nexa-2.0.0.0/`), so `strip = 1`
/// lands the binaries directly in `dest_root`.
///
/// `progress`, when supplied, is fed the download then extract byte counts so a
/// caller can render a progress bar.
///
/// Runs synchronously on its own blocking io. The whole archive is buffered in
/// memory (coin bundles are tens of MB — acceptable), then gunzipped and
/// untarred straight to disk.
pub fn downloadAndExtract(
    allocator: std.mem.Allocator,
    url: []const u8,
    format: Format,
    dest_root: []const u8,
    strip: u32,
    progress: ?Progress,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Download the whole archive into memory, streaming in chunks so we can
    //    report how many bytes have arrived against the content length.
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        // The archive is already gzip-compressed; ask the transport for the raw
        // bytes (not a re-encoding) so the tarball is intact and the
        // content-length we need for the progress bar is present.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.DownloadFailed;

    const total = response.head.content_length orelse 0;

    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    var received: u64 = 0;
    report(progress, .download, 0, total);
    while (true) {
        const n = reader.stream(&body.writer, .limited(256 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.DownloadFailed,
        };
        received += n;
        report(progress, .download, received, total);
    }

    // 2. Extract the in-memory archive to disk.
    try extractArchive(allocator, io, body.written(), format, dest_root, strip, progress);
}

/// Extract an in-memory archive into `dest_root` (created if missing).
/// Split out from the download so the gunzip+untar path is unit-testable
/// without a network round trip.
///
/// Progress is reported against the compressed input consumed: the archive is
/// gunzipped into memory first (the CPU-bound bulk of the work, which drives
/// the bar), then untarred to disk.
pub fn extractArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    format: Format,
    dest_root: []const u8,
    strip: u32,
    progress: ?Progress,
) !void {
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    switch (format) {
        .tar_gz => {
            // Gunzip the whole archive into memory, reporting progress by how
            // much of the compressed input the decompressor has consumed.
            var in = std.Io.Reader.fixed(bytes);
            var window: [flate.max_window_len]u8 = undefined;
            var dz = flate.Decompress.init(&in, .gzip, &window);

            var tar_bytes: std.Io.Writer.Allocating = .init(allocator);
            defer tar_bytes.deinit();

            report(progress, .extract, 0, bytes.len);
            while (true) {
                _ = dz.reader.stream(&tar_bytes.writer, .limited(256 * 1024)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return error.ExtractFailed,
                };
                report(progress, .extract, in.seek, bytes.len);
            }

            // Untar the decompressed bytes to disk. This is comparatively quick,
            // so the bar is left pegged at 100% for it.
            var tar_in = std.Io.Reader.fixed(tar_bytes.written());
            try std.tar.extract(io, dest, &tar_in, .{
                .strip_components = strip,
                .mode_mode = .executable_bit_only,
            });
            report(progress, .extract, bytes.len, bytes.len);
        },
        // Windows bundles ship as .zip; Linux/macOS use tar.gz, which is all
        // this slice targets. std.zip can fill this in later.
        .zip => return error.ZipNotYetSupported,
    }
}

/// Flatten an extracted coin bundle in place.
///
/// Coin tarballs wrap everything in a versioned directory and nest their
/// executables in a `bin/` subdirectory — e.g. `root/nexa-2.0.0.0/bin/nexad`,
/// alongside `lib/`, `share/`, etc. BoxWallet keeps just the daemon/cli/tx
/// binaries at the top of `~/.boxwallet` (where `isInstalled` and the daemon
/// launcher look for them) and discards everything else.
///
/// Moves each name in `binaries` from `root/<extracted_dir>/<bin_subdir>/` up to
/// `root/`, then deletes the whole `root/<extracted_dir>` tree. Removing the
/// versioned wrapper wholesale means a coin doesn't have to enumerate the
/// archive's other top-level entries (`lib/`, `share/`, `include/`, READMEs, …)
/// — whatever shape the bundle has, only the promoted binaries survive. Mirrors
/// the Go installer's `Install`.
///
/// A rename whose source is missing — a binary already promoted by a prior run —
/// is skipped rather than failing, and a missing `extracted_dir` is ignored, so
/// re-running over an already-flattened layout is a no-op.
pub fn promoteAndTidy(
    allocator: std.mem.Allocator,
    root: []const u8,
    extracted_dir: []const u8,
    bin_subdir: []const u8,
    binaries: []const []const u8,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);

    const bin_path = try std.fs.path.join(allocator, &.{ extracted_dir, bin_subdir });
    defer allocator.free(bin_path);

    // Promote the wanted binaries up to the root. rename replaces an existing
    // destination, so an update overwrites the old binary.
    for (binaries) |name| {
        const src = try std.fs.path.join(allocator, &.{ bin_path, name });
        defer allocator.free(src);
        dir.rename(src, dir, name, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    // Discard the entire extracted tree. deleteTree tolerates a missing path,
    // so a re-run over an already-flattened layout cleans up without erroring.
    dir.deleteTree(io, extracted_dir) catch {};
}

/// True if `sub_path` exists under `dest_root` (used to detect an installed
/// daemon binary).
pub fn fileExists(allocator: std.mem.Allocator, dest_root: []const u8, sub_path: []const u8) bool {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dest_root, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

test "installRoot builds ~/.boxwallet under the home dir (posix)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const root = try installRoot(allocator, "/home/alice");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("/home/alice/.boxwallet", root);
}

test "promoteAndTidy lifts bin/ binaries to root and removes the extracted tree" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-promote-out";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Simulate a strip=0 extraction: the versioned wrapper dir with bin/{daemon,
    // cli,tx,qt}, plus lib/ and a top-level README inside it.
    const wrapper = "nexa-9.9.9";
    inline for (.{ "bin", "lib" }) |sub| {
        var d = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/" ++ wrapper ++ "/" ++ sub, .{});
        d.close(io);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = wrapper ++ "/bin/nexad", .data = "DAEMON" });
    try dir.writeFile(io, .{ .sub_path = wrapper ++ "/bin/nexa-cli", .data = "CLI" });
    try dir.writeFile(io, .{ .sub_path = wrapper ++ "/bin/nexa-qt", .data = "GUI" }); // discarded
    try dir.writeFile(io, .{ .sub_path = wrapper ++ "/lib/libnexa.so", .data = "LIB" });
    try dir.writeFile(io, .{ .sub_path = wrapper ++ "/INSTALL.md", .data = "docs" });

    try promoteAndTidy(allocator, root, wrapper, "bin", &.{ "nexad", "nexa-cli" });

    // Wanted binaries promoted to the root.
    try std.testing.expect(fileExists(allocator, root, "nexad"));
    try std.testing.expect(fileExists(allocator, root, "nexa-cli"));
    // The whole extracted wrapper (incl. the unwanted nexa-qt, lib/, README) is gone.
    try std.testing.expect(!fileExists(allocator, root, wrapper));

    // Idempotent: a second run over the already-flattened layout is a no-op.
    try promoteAndTidy(allocator, root, wrapper, "bin", &.{ "nexad", "nexa-cli" });
    try std.testing.expect(fileExists(allocator, root, "nexad"));
}

test "extractArchive gunzips + untars a real .tar.gz with strip_components" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixture layout: nexa-9.9.9/{nexad,nexa-cli} — strip 1 lands them at root.
    const archive = @embedFile("testdata/fixture.tar.gz");
    const dest = "test-extract-out";

    // Clean any leftover from a prior run, then extract fresh.
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    try extractArchive(allocator, io, archive, .tar_gz, dest, 1, null);

    try std.testing.expect(fileExists(allocator, dest, "nexad"));
    try std.testing.expect(fileExists(allocator, dest, "nexa-cli"));
}
