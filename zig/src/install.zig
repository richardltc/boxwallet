const std = @import("std");
const flate = std.compress.flate;

/// Archive format a coin's daemon bundle ships in.
pub const Format = enum { tar_gz, zip };

/// Download `url` and extract it into `dest_root` (created if missing).
///
/// `strip` leading path components are dropped — coin archives wrap their
/// binaries in a versioned directory (e.g. `nexa-2.0.0.0/`), so `strip = 1`
/// lands the binaries directly in `dest_root`.
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
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Download the whole archive into memory.
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
    });
    if (res.status != .ok) return error.DownloadFailed;

    // 2. Extract the in-memory archive to disk.
    try extractArchive(io, body.written(), format, dest_root, strip);
}

/// Extract an in-memory archive into `dest_root` (created if missing).
/// Split out from the download so the gunzip+untar path is unit-testable
/// without a network round trip.
pub fn extractArchive(
    io: std.Io,
    bytes: []const u8,
    format: Format,
    dest_root: []const u8,
    strip: u32,
) !void {
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    switch (format) {
        .tar_gz => {
            var in = std.Io.Reader.fixed(bytes);
            var window: [flate.max_window_len]u8 = undefined;
            var dz = flate.Decompress.init(&in, .gzip, &window);
            try std.tar.extract(io, dest, &dz.reader, .{
                .strip_components = strip,
                .mode_mode = .executable_bit_only,
            });
        },
        // Windows bundles ship as .zip; Linux/macOS use tar.gz, which is all
        // this slice targets. std.zip can fill this in later.
        .zip => return error.ZipNotYetSupported,
    }
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

    try extractArchive(io, archive, .tar_gz, dest, 1);

    try std.testing.expect(fileExists(allocator, dest, "nexad"));
    try std.testing.expect(fileExists(allocator, dest, "nexa-cli"));
}
