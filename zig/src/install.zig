const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;

/// Resolve the BoxWallet data directory that coin daemons are extracted into,
/// matching the Go app's `HomeFolder`:
///   - POSIX:   `<home>/.boxwallet`
///   - Windows: `<home>/AppData/Roaming/BoxWallet`
///
/// `home_dir` is the process home directory (the caller reads it from `$HOME` /
/// `%USERPROFILE%` via ZigZag's `ctx.environ_map`). The caller owns the returned
/// slice. The directory itself is created lazily by `downloadAndExtract`.
pub fn installRoot(allocator: std.mem.Allocator, home_dir: []const u8) ![]const u8 {
    return if (comptime builtin.os.tag == .windows)
        std.fs.path.join(allocator, &.{ home_dir, "AppData", "Roaming", "BoxWallet" })
    else
        std.fs.path.join(allocator, &.{ home_dir, ".boxwallet" });
}

/// Archive format a coin's daemon bundle ships in.
pub const Format = enum { tar_gz, zip };

/// A coin's download for one build target: where to fetch the bundle and the
/// format it ships in. Coins build this at comptime from the OS/arch (a coin's
/// platform matrix is its own data), and pass it to `downloadAndExtract`. A null
/// `Download` means the coin publishes no binary for the target.
pub const Download = struct {
    url: []const u8,
    format: Format,
};

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
/// `scratch_name` is the temporary file the archive is streamed to inside
/// `dest_root`. It **must be unique per concurrent install** — BoxWallet runs a
/// coin's install on its own thread, and several can target the same
/// `~/.boxwallet` root at once, so each coin passes a name derived from its own
/// daemon (e.g. `.boxwallet-nexad.part`). A shared name would have two downloads
/// clobbering one file.
///
/// Runs synchronously on its own blocking io. **Memory stays flat regardless of
/// bundle size:** the archive is streamed to a scratch file on disk (never held
/// in RAM), then gunzip → untar runs as a streaming pipeline straight to disk.
/// Only small fixed buffers and the gzip window are resident at any point —
/// which matters because BoxWallet targets low-spec machines.
pub fn downloadAndExtract(
    allocator: std.mem.Allocator,
    url: []const u8,
    format: Format,
    dest_root: []const u8,
    scratch_name: []const u8,
    strip: u32,
    progress: ?Progress,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

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

    // Open the destination and a scratch file to stream the download into.
    // Buffering on disk rather than in memory is the whole point: a coin bundle
    // is tens of MB compressed and several times that decompressed, none of
    // which we want resident on a low-spec box.
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    {
        // 1. Stream the archive to the scratch file in bounded chunks, reporting
        //    bytes arrived against the content length.
        var scratch = try dest.createFile(io, scratch_name, .{});
        defer scratch.close(io);

        var transfer_buffer: [32 * 1024]u8 = undefined;
        const reader = response.reader(&transfer_buffer);

        var write_buffer: [32 * 1024]u8 = undefined;
        var scratch_writer = scratch.writer(io, &write_buffer);

        var received: u64 = 0;
        report(progress, .download, 0, total);
        while (true) {
            const n = reader.stream(&scratch_writer.interface, .limited(256 * 1024)) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return error.DownloadFailed,
            };
            received += n;
            report(progress, .download, received, total);
        }
        try scratch_writer.interface.flush();
    }
    // The scratch file is consumed by extraction below, then discarded. Closing
    // the read handle (registered after this) runs first, so the delete is safe
    // on Windows too.
    defer dest.deleteFile(io, scratch_name) catch {};

    // 2. Extract the on-disk archive into dest_root — no intermediate copy in
    //    memory. tar.gz streams straight through; zip needs random access to its
    //    end-of-file central directory, so it reads from the seekable scratch
    //    file directly (still constant memory: a deflate window plus this buffer).
    var scratch = try dest.openFile(io, scratch_name, .{});
    defer scratch.close(io);
    var read_buffer: [32 * 1024]u8 = undefined;
    var scratch_reader = scratch.reader(io, &read_buffer);
    switch (format) {
        .tar_gz => try extractArchive(io, &scratch_reader.interface, format, dest_root, strip, progress),
        .zip => try extractZip(&scratch_reader, dest, progress),
    }
}

/// Extract a zip archive (read from the seekable `archive`) into the already-open
/// `dest` directory. Windows coin bundles ship as zip; unlike tar.gz, zip stores
/// its directory at the end of the file, so extraction seeks rather than streams
/// — hence the `*File.Reader` (backed by the on-disk scratch file) instead of a
/// plain stream. Memory still stays flat: only a deflate window and the reader's
/// buffer are resident.
///
/// `std.zip` has no `strip_components`, but coin zips nest their binaries under
/// `<coin>-<ver>/bin/` exactly like the tarballs, and `promoteAndTidy` flattens
/// that afterward — so no stripping is needed here. The pass is opaque (no
/// per-byte callback), so progress is a single begin/end `.extract` pulse, enough
/// for the frontend to animate its spinner. `allow_backslashes` tolerates zips
/// that use `\` path separators.
fn extractZip(
    archive: *std.Io.File.Reader,
    dest: std.Io.Dir,
    progress: ?Progress,
) !void {
    report(progress, .extract, 0, 0);
    std.zip.extract(dest, archive, .{ .allow_backslashes = true }) catch return error.ExtractFailed;
    report(progress, .extract, 1, 0);
}

/// Extract an already-downloaded archive, read from `archive`, into `dest_root`
/// (created if missing). Split out from the download so the gunzip+untar path is
/// unit-testable from an in-memory fixture without a network round trip.
///
/// The decompressor pulls compressed bytes from `archive` on demand and the tar
/// extractor writes each entry to disk as it is produced, so the pipeline runs
/// in constant memory: neither the compressed archive nor the decompressed tree
/// is ever fully resident — only the gzip window.
///
/// `std.tar.extract` is a single opaque call that would otherwise report nothing
/// between start and finish, so a `TallyReader` is spliced between the
/// decompressor and the extractor to emit `.extract` progress as bytes flow.
/// That lets a frontend animate a spinner during the pass; the extract byte
/// counts are indeterminate, so `total` is reported as 0.
pub fn extractArchive(
    io: std.Io,
    archive: *std.Io.Reader,
    format: Format,
    dest_root: []const u8,
    strip: u32,
    progress: ?Progress,
) !void {
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    switch (format) {
        .tar_gz => {
            var window: [flate.max_window_len]u8 = undefined;
            var dz = flate.Decompress.init(archive, .gzip, &window);

            // Signal that extraction has begun (a frontend pegs the download bar
            // full and starts its spinner here), then stream gunzip → tally →
            // untar. The tally fires a report per chunk the extractor pulls.
            report(progress, .extract, 0, 0);
            // The tally needs a real buffer: archives produced with PAX/GNU
            // extended headers (long paths, large file sizes — the JRE bundles
            // use them) make `std.tar` do *buffered* source reads (`takeByte`),
            // which a zero-length-buffer reader can't satisfy.
            var tally_buffer: [64 * 1024]u8 = undefined;
            var tally: TallyReader = .init(&dz.reader, &tally_buffer, progress);
            std.tar.extract(io, dest, &tally.interface, .{
                .strip_components = strip,
                .mode_mode = .executable_bit_only,
            }) catch return error.ExtractFailed;
        },
        // This streaming path is tar.gz only. Zip can't stream — its central
        // directory sits at EOF — so the download path routes zip to `extractZip`
        // (seekable) instead and never reaches here.
        .zip => return error.ZipNotStreamable,
    }
}

/// A pass-through `std.Io.Reader` that reports throughput as bytes flow through
/// it, holding nothing beyond the `buffer` it's handed.
///
/// Wrapped around the decompressor's reader so the otherwise-opaque
/// `std.tar.extract` pass emits periodic `.extract` progress (one report per
/// chunk the extractor pulls), letting the UI animate a spinner instead of
/// sitting frozen. The `stream`/`discard` vtable forwards straight to `inner`,
/// counting bytes as they pass.
///
/// It must be given a non-empty `buffer`: tar reads file content and padding via
/// `stream`/`discard` (which forward fine), but archives carrying PAX/GNU
/// extended headers — long paths, large file sizes, as the bundled-JRE tarballs
/// do — make tar perform *buffered* source reads (`takeByte` while parsing the
/// extended header). Those draw from this reader's own buffer, so a zero-length
/// buffer would fail them with `ReadFailed`. (`readVec` is left to the default,
/// which routes through `stream`.)
const TallyReader = struct {
    inner: *std.Io.Reader,
    progress: ?Progress,
    count: u64 = 0,
    interface: std.Io.Reader,

    fn init(inner: *std.Io.Reader, buffer: []u8, progress: ?Progress) TallyReader {
        return .{
            .inner = inner,
            .progress = progress,
            .interface = .{
                .vtable = &.{ .stream = stream, .discard = discard },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TallyReader = @fieldParentPtr("interface", r);
        const n = try self.inner.stream(w, limit);
        self.bump(n);
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *TallyReader = @fieldParentPtr("interface", r);
        const n = try self.inner.discard(limit);
        self.bump(n);
        return n;
    }

    fn bump(self: *TallyReader, n: usize) void {
        self.count += n;
        report(self.progress, .extract, self.count, 0);
    }
};

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

    var in = std.Io.Reader.fixed(archive);
    try extractArchive(io, &in, .tar_gz, dest, 1, null);

    try std.testing.expect(fileExists(allocator, dest, "nexad"));
    try std.testing.expect(fileExists(allocator, dest, "nexa-cli"));
}

test "extractArchive handles PAX/GNU extended headers (long paths)" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A regression guard for the bundled-JRE tarballs: they're written with PAX
    // extended headers (for paths past the 100-byte ustar limit, and large file
    // sizes), which make `std.tar` do *buffered* source reads while parsing the
    // extended header. A tally reader with a zero-length buffer failed those,
    // surfacing as `ExtractFailed`. This fixture carries a >100-byte path, so it
    // exercises the PAX path the plain-ustar `fixture.tar.gz` never reaches.
    const archive = @embedFile("testdata/fixture-pax.tar.gz");
    const dest = "test-extract-pax-out";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var in = std.Io.Reader.fixed(archive);
    try extractArchive(io, &in, .tar_gz, dest, 0, null);

    try std.testing.expect(fileExists(allocator, dest, "pax-node/jre/bin/java"));
    try std.testing.expect(fileExists(
        allocator,
        dest,
        "pax-node/a-deliberately-long-path-that-exceeds-the-ustar-one-hundred-byte-name-limit-to-force-extended-headers.jar",
    ));
}

test "extractArchive reports extract progress periodically (drives the UI spinner)" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const archive = @embedFile("testdata/fixture.tar.gz");
    const dest = "test-extract-progress-out";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    // Count `.extract` reports. A streaming extract fires the initial report
    // plus one per chunk the tar reader pulls, so we expect several — unlike a
    // non-streaming extract, which could only report a single "done".
    const Counter = struct {
        extract_reports: usize = 0,
        fn onProgress(ctx: *anyopaque, phase: Phase, current: u64, total: u64) void {
            _ = current;
            _ = total;
            if (phase == .extract) {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.extract_reports += 1;
            }
        }
    };
    var counter: Counter = .{};
    const progress: Progress = .{ .ctx = &counter, .func = Counter.onProgress };

    var in = std.Io.Reader.fixed(archive);
    try extractArchive(io, &in, .tar_gz, dest, 1, progress);

    try std.testing.expect(counter.extract_reports >= 2);
}

test "extractZip unzips a real .zip preserving the nested bin/ layout" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Fixture layout: nexa-9.9.9/bin/{nexad,nexa-cli,nexa-qt}. Zip has no
    // strip_components, so the wrapper is preserved here and promoteAndTidy
    // flattens it afterward — same as the live Windows install path.
    const archive = @embedFile("testdata/fixture.zip");
    const dest = "test-zip-out";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dest, .{});
    defer dir.close(io);

    // Zip seeks to its end-of-file central directory, so the source must be a
    // real on-disk file (not an in-memory reader). Stage the fixture to a scratch
    // file and extract from it, mirroring the download path.
    try dir.writeFile(io, .{ .sub_path = "fixture.zip", .data = archive });
    var f = try dir.openFile(io, "fixture.zip", .{});
    defer f.close(io);
    var buf: [4 * 1024]u8 = undefined;
    var fr = f.reader(io, &buf);

    try extractZip(&fr, dir, null);

    try std.testing.expect(fileExists(allocator, dest, "nexa-9.9.9/bin/nexad"));
    try std.testing.expect(fileExists(allocator, dest, "nexa-9.9.9/bin/nexa-cli"));
}
