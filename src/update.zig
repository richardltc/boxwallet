//! BoxWallet's in-app self-updater.
//!
//! BoxWallet keeps itself current without a separate updater binary, in two
//! phases that match the OS constraint that a *running* executable can't be
//! overwritten in place (Windows locks it; POSIX would keep the old inode):
//!
//!  1. **Check + stage** (`checkAndStage`), run on a background worker while the
//!     current build keeps running. It asks Codeberg for the latest release, and
//!     if that's newer than the running version, streams the matching native
//!     binary to `~/.boxwallet/updates/`, verifies its SHA-256 against the
//!     release's `SHA256SUMS`, and drops a version marker beside it. Nothing the
//!     running process uses is touched.
//!  2. **Apply on next launch** (`applyPending`), run from `main` *before* the
//!     TUI starts. If a verified, newer binary is staged, it swaps it into the
//!     executable's path (moving the running binary aside first — allowed while
//!     running on every OS) and the caller re-execs into it via
//!     `std.process.replace`. The swap clears the staged files, so the
//!     re-exec'd process sees nothing pending and runs normally — no loop.
//!
//! Memory stays flat per the project's constraint: the release JSON and
//! `SHA256SUMS` are small, capped reads; the binary itself is streamed to disk
//! by `install.downloadFile` and hashed in fixed-size chunks — neither is ever
//! held whole in RAM.

const std = @import("std");
const builtin = @import("builtin");
const install = @import("install.zig");

/// The Codeberg repo BoxWallet releases come from.
const repo = "richardltc/BoxWallet";

/// Where releases are fetched from. A struct rather than two constants purely so
/// tests can point it at a local `std.http.Server`: without this seam none of the
/// check → stage → apply path can be exercised offline, which for something that
/// replaces a wallet's own binary is not a reasonable place to be.
///
/// Callers should pass `Source.default`. Nothing in the app overrides it.
pub const Source = struct {
    /// Latest-release metadata endpoint (Forgejo API; returns JSON carrying
    /// `tag_name`).
    latest_release_url: []const u8,
    /// Base for a release's downloadable assets: `<base>/<tag>/<asset>`.
    download_base: []const u8,

    pub const default: Source = .{
        .latest_release_url = "https://codeberg.org/api/v1/repos/" ++ repo ++ "/releases/latest",
        .download_base = "https://codeberg.org/" ++ repo ++ "/releases/download",
    };
};
/// The checksums asset published alongside the per-platform binaries, in the
/// standard `sha256sum` format (`<64-hex>␠␠<filename>` per line).
const sums_name = "SHA256SUMS";
/// Sent as User-Agent — some servers reject requests without one.
const user_agent = "BoxWallet (https://codeberg.org/" ++ repo ++ ")";

/// Where staged updates live, relative to the install root (`~/.boxwallet`).
/// Each front-end gets its own subdirectory beneath this — see `Front.dirName`.
const updates_subdir = "updates";
/// The verified, ready-to-apply binary.
const staged_name = "boxwallet.staged";
/// The in-progress download, renamed to `staged_name` only after it verifies.
const part_name = "boxwallet.staged.part";
/// Text file holding the staged binary's version — written last, so its
/// presence means a complete, verified staged binary. Read on next launch to
/// decide whether to apply (and guard against re-applying a stale stage).
const marker_name = "boxwallet.staged.version";
/// Records `<version> <n>`: how many times applying that staged version has
/// failed. Kept after we give up, so a check doesn't just download it again.
const fails_name = "boxwallet.staged.fails";
/// Consecutive failed swaps of one version before we stop retrying it. A swap
/// that fails three times is a standing condition (read-only dir, no space),
/// not a blip, and re-downloading 5 MB every launch forever helps nobody.
const max_apply_failures = 3;

/// Caps on the small metadata reads, so a hostile/broken server can't make us
/// balloon memory. The real binary is streamed to disk, never buffered.
const max_release_json = 1 << 20; // 1 MiB
const max_sums = 1 << 18; // 256 KiB

/// Which front-end is updating itself. They ship as different assets, stage into
/// different directories, and are published for different targets — the TUI
/// everywhere, the GUI only where `gui-release` builds a bundle.
pub const Front = enum {
    tui,
    gui,

    /// Staging subdirectory, so the two never collide. They share one install
    /// root, and before this they shared one `boxwallet.staged` too: with both
    /// installed, the GUI could stage its binary and the TUI would apply it over
    /// itself on the next launch. `isNewer` can't catch that — the versions
    /// genuinely match — and the result is a GUI exe with no runtime beside it.
    fn dirName(self: Front) []const u8 {
        return switch (self) {
            .tui => "tui",
            .gui => "gui",
        };
    }
};

/// The asset name for `front` on *this* build target, or `null` when no such
/// asset is published — which is what keeps the updater dormant rather than
/// erroring. The TUI ships a bare executable per OS/arch; the GUI only exists
/// for the two Linux targets `gui-release` builds, so `assetFor(.gui)` is null
/// everywhere else for free.
pub fn assetFor(comptime front: Front) ?[]const u8 {
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return null,
    };
    return switch (front) {
        .tui => blk: {
            const os = switch (builtin.os.tag) {
                .linux => "linux",
                .macos => "macos",
                .windows => "windows",
                else => return null,
            };
            const ext = if (builtin.os.tag == .windows) ".exe" else "";
            break :blk "boxwallet-" ++ os ++ "-" ++ arch ++ ext;
        },
        // Linux only, and only the two arches with a prebuilt Slint runtime.
        .gui => if (builtin.os.tag == .linux) "boxwallet-gui-linux-" ++ arch else null,
    };
}

/// The TUI's asset name. Kept so existing callers read unchanged.
pub const asset_name: ?[]const u8 = assetFor(.tui);

/// Outcome of a `checkAndStage` round, surfaced to the UI.
pub const CheckStatus = enum {
    /// The running build is the latest release.
    up_to_date,
    /// A newer release was downloaded + verified and is staged for next launch.
    staged,
    /// No binary is published for this OS/arch — the updater is a no-op here.
    unsupported,
    /// Couldn't reach Codeberg / parse its reply. Best-effort: try again next run.
    network_error,
    /// The download didn't match the published checksum — refused.
    verify_failed,
    /// This release was staged and its swap failed `max_apply_failures` times in
    /// a row, so we've stopped retrying it. A later release clears the count.
    gave_up,
};

/// A version string in a fixed inline buffer, so a worker thread can hand its
/// result back by value without a heap allocation outliving its arena.
pub const VersionBuf = struct {
    buf: [32]u8 = [_]u8{0} ** 32,
    len: usize = 0,

    pub fn slice(self: *const VersionBuf) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *VersionBuf, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }
};

/// Result of a `checkAndStage` round: the status plus the latest version seen
/// (populated for `up_to_date`/`staged`, empty otherwise).
pub const Check = struct {
    status: CheckStatus,
    version: VersionBuf = .{},
    /// Only meaningful with `.staged`: true when the executable's own directory
    /// isn't writable, so the swap in `applyPending` would fail on next launch.
    /// Lets the UI say "can't apply — move me somewhere writable" instead of a
    /// "restart to apply" that wouldn't take.
    blocked: bool = false,
};

/// Optional hook fired once a newer release has been found and is *about to* be
/// streamed down — before the (potentially slow) download — carrying the version
/// being fetched. Lets the UI log "downloading vX" up front rather than only
/// after the download lands. Runs on the worker thread, so an implementation
/// must hand the version off to the UI thread safely (see app.zig).
pub const Notify = struct {
    ctx: *anyopaque,
    on_download_start: *const fn (ctx: *anyopaque, version: []const u8) void,
};

/// Check Codeberg for a newer release and, if found, download + verify + stage it
/// for application on next launch. Runs synchronously on its own blocking io
/// (the caller drives it from a worker thread). Never errors — every failure
/// maps to a `CheckStatus`, since a missed update check must not disturb the
/// running app. `notify`, if given, fires once just before the binary download
/// begins.
pub fn checkAndStage(
    gpa: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    current_version: []const u8,
    notify: ?Notify,
) Check {
    return checkAndStageFor(.tui, gpa, io, install_root, current_version, notify, .default);
}

/// As `checkAndStage`, for a named front-end and release source. `src` exists so
/// tests can serve a synthetic release locally; pass `.default` in the app.
pub fn checkAndStageFor(
    comptime front: Front,
    gpa: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    current_version: []const u8,
    notify: ?Notify,
    src: Source,
) Check {
    const asset = comptime assetFor(front) orelse return .{ .status = .unsupported };
    return checkAndStageInner(gpa, io, install_root, current_version, asset, notify, front, src) catch |err| .{
        .status = switch (err) {
            error.VerifyFailed => .verify_failed,
            else => .network_error,
        },
    };
}

fn checkAndStageInner(
    gpa: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    current_version: []const u8,
    asset: []const u8,
    notify: ?Notify,
    front: Front,
    src: Source,
) !Check {
    const json = try fetchText(gpa, io, src.latest_release_url, max_release_json);
    defer gpa.free(json);

    const tag = parseTagName(json) orelse return error.ParseFailed;
    const version = stripV(tag);
    var vbuf: VersionBuf = .{};
    vbuf.set(version);

    if (!isNewer(version, current_version)) return .{ .status = .up_to_date, .version = vbuf };

    const updates_path = try std.fs.path.join(gpa, &.{ install_root, updates_subdir, front.dirName() });
    defer gpa.free(updates_path);

    // Already staged this exact version on a previous launch? The marker is only
    // cleared once the update is applied, so a still-old running build would
    // otherwise re-download every launch until restarted. Skip the work.
    if (readMarker(gpa, io, updates_path)) |staged_ver| {
        defer gpa.free(staged_ver);
        if (std.mem.eql(u8, staged_ver, version))
            return .{ .status = .staged, .version = vbuf, .blocked = !exeDirWritable(gpa, io) };
    }

    // Gave up on this exact version already? The count outlives the staged files,
    // so this is what stops a failing swap from re-downloading every launch.
    if (readFails(io, updates_path, version) >= max_apply_failures)
        return .{ .status = .gave_up, .version = vbuf, .blocked = !exeDirWritable(gpa, io) };

    // Pull the checksum for our asset out of the release's SHA256SUMS first, so a
    // missing/garbled checksum fails before we spend bandwidth on the binary.
    const sums_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ src.download_base, tag, sums_name });
    defer gpa.free(sums_url);
    const sums = try fetchText(gpa, io, sums_url, max_sums);
    defer gpa.free(sums);
    const want = parseChecksum(sums, asset) orelse return error.VerifyFailed;

    // A newer release exists and we're committed to fetching it — let the UI
    // announce the download before we spend time on it.
    if (notify) |n| n.on_download_start(n.ctx, version);

    // Stream the binary to disk (flat memory), then verify before trusting it.
    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ src.download_base, tag, asset });
    defer gpa.free(asset_url);
    try install.downloadFile(gpa, asset_url, updates_path, part_name, null);

    var dir = try std.Io.Dir.cwd().openDir(io, updates_path, .{});
    defer dir.close(io);

    const got = try sha256File(io, dir, part_name);
    if (!std.mem.eql(u8, &got, &want)) {
        dir.deleteFile(io, part_name) catch {};
        return error.VerifyFailed;
    }

    // Commit: promote the verified download, then write the marker last so its
    // presence always implies a complete, verified staged binary.
    try dir.rename(part_name, dir, staged_name, io);
    dir.deleteFile(io, fails_name) catch {};
    try dir.writeFile(io, .{ .sub_path = marker_name, .data = version });

    return .{ .status = .staged, .version = vbuf, .blocked = !exeDirWritable(gpa, io) };
}

/// True if the running executable's directory is writable — i.e. a staged
/// update could actually be swapped in on next launch (`swapBinary` needs to
/// rename the running binary aside and drop the new one beside it). Probes by
/// creating and deleting a temp file there. Conservative: any failure to even
/// resolve/open the directory reads as not writable.
fn exeDirWritable(gpa: std.mem.Allocator, io: std.Io) bool {
    const exe = std.process.executablePathAlloc(io, gpa) catch return false;
    defer gpa.free(exe);
    const dir_path = std.fs.path.dirname(exe) orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    const probe = ".boxwallet-write-probe";
    var f = dir.createFile(io, probe, .{}) catch return false;
    f.close(io);
    dir.deleteFile(io, probe) catch {};
    return true;
}

/// A binary swapped into place by `applyPending`, ready to re-exec.
pub const Applied = struct {
    /// Absolute path of the (now-replaced) executable, heap-allocated. The
    /// caller passes it to `std.process.replace`, which doesn't return on
    /// success, so it's effectively freed by process replacement.
    exe_path: [:0]u8,
};

/// Apply a previously-staged update, if one is ready and newer than the running
/// build. Returns the swapped-in binary's path for the caller to re-exec into,
/// or `null` when there's nothing to do.
///
/// Run from `main` before the TUI starts. Always opportunistically clears a
/// leftover `<exe>.old` from a prior update first. `current_version` is the
/// running build's version, used to ignore a stale marker (e.g. one whose swap
/// completed but whose cleanup didn't) so we never re-apply in a loop.
pub fn applyPending(
    gpa: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    current_version: []const u8,
) !?Applied {
    return applyPendingFor(.tui, gpa, io, install_root, current_version);
}

/// As `applyPending`, for a named front-end. Each stages into its own directory,
/// so the TUI can never apply a binary the GUI staged (or the reverse).
pub fn applyPendingFor(
    front: Front,
    gpa: std.mem.Allocator,
    io: std.Io,
    install_root: []const u8,
    current_version: []const u8,
) !?Applied {
    const exe_path = std.process.executablePathAlloc(io, gpa) catch return null;
    errdefer gpa.free(exe_path);

    // Best-effort sweep of the previous update's set-aside binary. On Windows the
    // just-exited parent may still hold it; if so this fails and a later run gets
    // it. (`deleteFile` tolerates a missing path.)
    cleanupOld(gpa, io, exe_path);
    cleanupLegacyStage(gpa, io, install_root);

    const updates_path = try std.fs.path.join(gpa, &.{ install_root, updates_subdir, front.dirName() });
    defer gpa.free(updates_path);

    var dir = std.Io.Dir.cwd().openDir(io, updates_path, .{}) catch {
        gpa.free(exe_path);
        return null;
    };
    defer dir.close(io);

    const staged_ver = readMarkerDir(gpa, io, dir) orelse {
        gpa.free(exe_path);
        return null;
    };
    defer gpa.free(staged_ver);

    // Marker not newer than what we're running — already applied (or bogus).
    // Clear the staged files so they don't linger and re-trigger.
    if (!isNewer(staged_ver, current_version)) {
        dir.deleteFile(io, staged_name) catch {};
        dir.deleteFile(io, marker_name) catch {};
        gpa.free(exe_path);
        return null;
    }

    // Marker present but the binary vanished — drop the marker and carry on.
    dir.access(io, staged_name, .{}) catch {
        dir.deleteFile(io, marker_name) catch {};
        gpa.free(exe_path);
        return null;
    };

    // Count the attempt *before* making it, so a swap that dies mid-way (killed,
    // power cut) still burns a try rather than looping forever on the same fault.
    const fails = readFailsDir(io, dir, staged_ver);
    if (fails >= max_apply_failures) {
        // Out of tries: drop the staged binary and marker but keep the count, so
        // the next check reports `gave_up` instead of downloading it all again.
        dir.deleteFile(io, staged_name) catch {};
        dir.deleteFile(io, marker_name) catch {};
        gpa.free(exe_path);
        return null;
    }
    writeFails(io, dir, staged_ver, fails + 1);

    const staged_abs = try std.fs.path.join(gpa, &.{ updates_path, staged_name });
    defer gpa.free(staged_abs);

    try swapBinary(gpa, io, staged_abs, exe_path);

    // Swap done — remove the staged files so the re-exec'd process sees nothing
    // pending and runs normally instead of swapping again.
    dir.deleteFile(io, staged_name) catch {};
    dir.deleteFile(io, marker_name) catch {};
    dir.deleteFile(io, fails_name) catch {};

    return .{ .exe_path = exe_path };
}

/// Replace the binary at `target_abs` with the one at `staged_abs`, working
/// while `target_abs` is the running executable on every supported OS.
///
/// The staged binary is first copied next to the target (so the swap renames
/// never cross filesystems — the staging dir under `~/.boxwallet` may be on a
/// different volume than the executable) and marked executable. Then the running
/// binary is moved aside to `<target>.old` (renaming a running exe is allowed on
/// both POSIX and Windows, unlike overwriting it) and the new one moved into its
/// place. A failure after the running binary is moved rolls it back, so the app
/// is never left without its executable.
fn swapBinary(
    gpa: std.mem.Allocator,
    io: std.Io,
    staged_abs: []const u8,
    target_abs: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();

    const tmp_abs = try std.fmt.allocPrint(gpa, "{s}.bw-new", .{target_abs});
    defer gpa.free(tmp_abs);
    const old_abs = try std.fmt.allocPrint(gpa, "{s}.old", .{target_abs});
    defer gpa.free(old_abs);

    // Land the new binary beside the target (same filesystem) as an executable.
    cwd.deleteFile(io, tmp_abs) catch {};
    try cwd.copyFile(staged_abs, cwd, tmp_abs, io, .{ .permissions = .executable_file, .replace = true });

    cwd.deleteFile(io, old_abs) catch {};
    try cwd.rename(target_abs, cwd, old_abs, io);
    cwd.rename(tmp_abs, cwd, target_abs, io) catch |err| {
        // Put the original back so we don't leave a hole where the binary was.
        cwd.rename(old_abs, cwd, target_abs, io) catch {};
        return err;
    };
}

/// Delete a leftover `<exe>.old` from a prior update. Best-effort.
/// Staging moved from `updates/` to `updates/<front>/` when a second front-end
/// gained an updater (a shared name would have let the GUI's binary be swapped
/// over the TUI's). Anything left at the old path is ours and now unreachable,
/// so drop it rather than leaving a stale 5 MB binary behind forever.
fn cleanupLegacyStage(gpa: std.mem.Allocator, io: std.Io, install_root: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ install_root, updates_subdir }) catch return;
    defer gpa.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return;
    defer dir.close(io);
    inline for (.{ staged_name, part_name, marker_name, fails_name }) |name|
        dir.deleteFile(io, name) catch {};
}

fn cleanupOld(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) void {
    const old = std.fmt.allocPrint(gpa, "{s}.old", .{exe_path}) catch return;
    defer gpa.free(old);
    std.Io.Dir.cwd().deleteFile(io, old) catch {};
}

/// HTTP GET `url` into a freshly allocated buffer, capped at `max_bytes`. Used
/// only for the small release JSON and checksum file; the binary itself goes
/// through `install.downloadFile` (streamed to disk). Caller owns the result.
fn fetchText(gpa: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = user_agent },
            // Raw bytes, no re-encoding — keeps the JSON/text intact.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpStatus;

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    while (true) {
        _ = reader.stream(&out.writer, .limited(64 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.ReadFailed,
        };
        if (out.written().len > max_bytes) return error.TooLarge;
    }
    return out.toOwnedSlice();
}

/// SHA-256 of a file under `dir`, streamed through in fixed chunks (flat memory).
fn sha256File(io: std.Io, dir: std.Io.Dir, name: []const u8) ![32]u8 {
    var f = try dir.openFile(io, name, .{});
    defer f.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch return error.ReadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    return hasher.finalResult();
}

/// Read the staged-version marker from `updates_path`, or null if absent/unreadable.
fn readMarker(gpa: std.mem.Allocator, io: std.Io, updates_path: []const u8) ?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, updates_path, .{}) catch return null;
    defer dir.close(io);
    return readMarkerDir(gpa, io, dir);
}

/// Read the staged-version marker from an open updates `dir`. Caller owns the
/// returned (trimmed) slice; null if the marker is absent or unreadable.
/// Failed-apply count for `version`, or 0 when the file is absent, unreadable,
/// or records some *other* version (a newer release always starts fresh).
fn readFails(io: std.Io, updates_path: []const u8, version: []const u8) u32 {
    var dir = std.Io.Dir.cwd().openDir(io, updates_path, .{}) catch return 0;
    defer dir.close(io);
    return readFailsDir(io, dir, version);
}

fn readFailsDir(io: std.Io, dir: std.Io.Dir, version: []const u8) u32 {
    var f = dir.openFile(io, fails_name, .{}) catch return 0;
    defer f.close(io);

    var rbuf: [128]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var out: [128]u8 = undefined;
    const n = fr.interface.readSliceShort(&out) catch return 0;
    const line = std.mem.trim(u8, out[0..n], " \t\r\n");

    var it = std.mem.splitScalar(u8, line, ' ');
    const ver = it.next() orelse return 0;
    if (!std.mem.eql(u8, ver, version)) return 0;
    const count = it.next() orelse return 0;
    return std.fmt.parseInt(u32, count, 10) catch 0;
}

fn writeFails(io: std.Io, dir: std.Io.Dir, version: []const u8, count: u32) void {
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} {d}", .{ version, count }) catch return;
    dir.writeFile(io, .{ .sub_path = fails_name, .data = line }) catch {};
}

fn readMarkerDir(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ?[]u8 {
    var f = dir.openFile(io, marker_name, .{}) catch return null;
    defer f.close(io);

    var rbuf: [128]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var out: [128]u8 = undefined;
    const n = fr.interface.readSliceShort(&out) catch return null;
    const trimmed = std.mem.trim(u8, out[0..n], " \t\r\n");
    return gpa.dupe(u8, trimmed) catch null;
}

/// Strip a leading `v`/`V` from a release tag (`v0.0.4` → `0.0.4`).
fn stripV(tag: []const u8) []const u8 {
    if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) return tag[1..];
    return tag;
}

/// True if dotted version `latest` is strictly greater than `current`, comparing
/// component by component on each one's leading numeric run (so a suffix like
/// `0.31.6a` compares as `0.31.6`). A missing component counts as 0, so
/// `0.1` < `0.1.1`.
pub fn isNewer(latest: []const u8, current: []const u8) bool {
    var li = std.mem.splitScalar(u8, latest, '.');
    var ci = std.mem.splitScalar(u8, current, '.');
    while (true) {
        const lp = li.next();
        const cp = ci.next();
        if (lp == null and cp == null) return false; // all components equal
        const lv = numericPrefix(lp orelse "");
        const cv = numericPrefix(cp orelse "");
        if (lv != cv) return lv > cv;
    }
}

/// True when two dotted versions denote *different* releases — in either direction,
/// unlike `isNewer`. Used to flag a daemon whose binary isn't the version BoxWallet
/// pins, including the case where it's somehow *ahead* of the pin (a hand-installed
/// binary), which an `isNewer`-only check would wave through.
///
/// Compares on `isNewer` in both directions rather than `mem.eql` so it inherits the
/// component padding: "2.0.0" (Nexa's, decoded from its integer `CLIENT_VERSION`) and
/// the pinned "2.0.0.0" are the same release and must not read as a mismatch. By the
/// same token a suffix is ignored, so Salvium's "1.1.3c" and "1.1.3" agree.
pub fn differs(a: []const u8, b: []const u8) bool {
    return isNewer(a, b) or isNewer(b, a);
}

/// Parse the leading run of decimal digits of `s` as a number (0 if none).
fn numericPrefix(s: []const u8) u64 {
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') break;
        v = v *% 10 +% (c - '0');
    }
    return v;
}

/// Extract the `tag_name` string value from a Codeberg release JSON document.
/// A deliberately minimal scan (rather than a full JSON parse) — we only need
/// this one field, and it returns a slice into `json`.
fn parseTagName(json: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const key_at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = key_at + key.len;
    // Skip whitespace and the ':' separator.
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == ':')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null;
    return json[start..i];
}

/// Find `asset`'s SHA-256 in a `sha256sum`-format file and decode it to bytes.
/// Each line is `<64-hex>` then whitespace (and an optional `*` binary marker)
/// then the filename; we match on the trailing filename token.
fn parseChecksum(sums: []const u8, asset: []const u8) ?[32]u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const hex = fields.next() orelse continue;
        var name = fields.next() orelse continue;
        if (name.len > 0 and name[0] == '*') name = name[1..]; // binary-mode marker
        if (hex.len != 64) continue;
        if (!std.mem.eql(u8, name, asset)) continue;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch return null;
        return out;
    }
    return null;
}

test "differs flags a real version gap without tripping on formatting" {
    // The case this was built for: a v0.2.2.0 nervad against a pinned v0.3.0.0.
    try std.testing.expect(differs("0.2.2.0", "0.3.0.0"));
    // Either direction — a binary somehow *ahead* of the pin is still worth flagging.
    try std.testing.expect(differs("0.3.0.0", "0.2.2.0"));

    // Same release, different spelling — must NOT read as a mismatch, or every Nexa
    // install would show a false warning: its `CLIENT_VERSION` decodes to "2.0.0"
    // while the coin pins "2.0.0.0".
    try std.testing.expect(!differs("2.0.0", "2.0.0.0"));
    // A letter suffix is likewise not a difference (Salvium's "1.1.3c").
    try std.testing.expect(!differs("1.1.3c", "1.1.3"));
    try std.testing.expect(!differs("1.1.3c", "1.1.3c"));
    // Identical versions never differ.
    try std.testing.expect(!differs("2.2.1.502", "2.2.1.502"));
}

test "isNewer compares dotted versions numerically" {
    try std.testing.expect(isNewer("0.0.4", "0.0.3"));
    try std.testing.expect(isNewer("0.1.0", "0.0.9"));
    try std.testing.expect(isNewer("1.0.0", "0.9.9"));
    try std.testing.expect(isNewer("0.1.1", "0.1")); // missing component is 0
    try std.testing.expect(!isNewer("0.0.3", "0.0.3"));
    try std.testing.expect(!isNewer("0.0.2", "0.0.3"));
    try std.testing.expect(!isNewer("0.0.10", "0.0.10"));
    try std.testing.expect(isNewer("0.0.10", "0.0.9")); // not string-compared
}

test "stripV drops a leading v" {
    try std.testing.expectEqualStrings("0.0.4", stripV("v0.0.4"));
    try std.testing.expectEqualStrings("0.0.4", stripV("V0.0.4"));
    try std.testing.expectEqualStrings("0.0.4", stripV("0.0.4"));
}

test "parseTagName pulls tag_name out of release JSON" {
    const json =
        \\{"url":"https://codeberg.org/api/v1/...","tag_name": "v0.1.2","name":"Release"}
    ;
    try std.testing.expectEqualStrings("v0.1.2", parseTagName(json).?);
    try std.testing.expect(parseTagName("{\"name\":\"no tag here\"}") == null);
}

test "parseChecksum matches the asset and decodes its digest" {
    const sums =
        \\1111111111111111111111111111111111111111111111111111111111111111  boxwallet-linux-x86_64
        \\abcdef0000000000000000000000000000000000000000000000000000000000  boxwallet-windows-x86_64.exe
    ;
    const got = parseChecksum(sums, "boxwallet-windows-x86_64.exe").?;
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "abcdef0000000000000000000000000000000000000000000000000000000000");
    try std.testing.expectEqualSlices(u8, &want, &got);
    try std.testing.expect(parseChecksum(sums, "boxwallet-macos-aarch64") == null);
}

test "parseChecksum tolerates the binary-mode (*) marker" {
    const sums = "2222222222222222222222222222222222222222222222222222222222222222 *boxwallet-linux-x86_64\n";
    try std.testing.expect(parseChecksum(sums, "boxwallet-linux-x86_64") != null);
}

test "swapBinary replaces the target with the staged binary, keeping a .old" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-swap";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "staged", .data = "NEW BINARY" });
    try dir.writeFile(io, .{ .sub_path = "boxwallet", .data = "OLD BINARY" });

    try swapBinary(allocator, io, root ++ "/staged", root ++ "/boxwallet");

    // The target now holds the new bytes, and the old ones are set aside.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("NEW BINARY", try dir.readFile(io, "boxwallet", &buf));
    try std.testing.expectEqualStrings("OLD BINARY", try dir.readFile(io, "boxwallet.old", &buf));
}

test "the front-ends stage into separate directories" {
    // The whole point: a shared `updates/` let the GUI's staged binary be read
    // by the TUI's marker and swapped over the TUI's exe, with `isNewer` unable
    // to notice because the versions genuinely match.
    try std.testing.expectEqualStrings("tui", Front.tui.dirName());
    try std.testing.expectEqualStrings("gui", Front.gui.dirName());
    try std.testing.expect(!std.mem.eql(u8, Front.tui.dirName(), Front.gui.dirName()));
}

test "assetFor names a per-front-end asset, and nothing where none is published" {
    // The TUI ships everywhere we build; the GUI is Linux-only, which is what
    // keeps its updater correctly dormant on macOS/Windows for free.
    try std.testing.expect(assetFor(.tui) != null);
    switch (builtin.os.tag) {
        .linux => {
            const gui = assetFor(.gui).?;
            try std.testing.expect(std.mem.startsWith(u8, gui, "boxwallet-gui-linux-"));
            // Never the same name as the TUI's, or they'd collide in a release.
            try std.testing.expect(!std.mem.eql(u8, gui, assetFor(.tui).?));
        },
        else => try std.testing.expect(assetFor(.gui) == null),
    }
}

test "the apply-failure count is scoped to its version" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-fails";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // Absent file reads as zero, so a first attempt is never mistaken for a retry.
    try std.testing.expectEqual(@as(u32, 0), readFailsDir(io, dir, "1.2.3"));

    writeFails(io, dir, "1.2.3", 2);
    try std.testing.expectEqual(@as(u32, 2), readFailsDir(io, dir, "1.2.3"));

    // A *different* release starts with a clean slate — otherwise one broken
    // build would permanently wedge the updater against every later one.
    try std.testing.expectEqual(@as(u32, 0), readFailsDir(io, dir, "1.2.4"));

    // Garbage in the file must read as zero, not as "give up".
    try dir.writeFile(io, .{ .sub_path = fails_name, .data = "not a count" });
    try std.testing.expectEqual(@as(u32, 0), readFailsDir(io, dir, "1.2.3"));
}

test "applyPending stops retrying a version that keeps failing" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-giveup";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const stage = root ++ "/" ++ updates_subdir ++ "/tui";
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, stage, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = staged_name, .data = "NEW BINARY" });
    try dir.writeFile(io, .{ .sub_path = marker_name, .data = "99.0.0" });
    writeFails(io, dir, "99.0.0", max_apply_failures);

    // Out of tries: it must not swap, and must clear the staged files so the
    // next launch doesn't keep re-reading them.
    try std.testing.expect(try applyPendingFor(.tui, allocator, io, root, "1.0.0") == null);
    try std.testing.expectError(error.FileNotFound, dir.access(io, staged_name, .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(io, marker_name, .{}));

    // The count survives, which is what makes the next check report `gave_up`
    // instead of cheerfully downloading the same broken release again.
    try std.testing.expectEqual(max_apply_failures, readFailsDir(io, dir, "99.0.0"));
}

test "applyPending sweeps the pre-per-front-end staging files" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-legacy";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var old = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/" ++ updates_subdir, .{});
    defer old.close(io);
    try old.writeFile(io, .{ .sub_path = staged_name, .data = "STALE BINARY" });
    try old.writeFile(io, .{ .sub_path = marker_name, .data = "0.9.0" });
    // Something we didn't write must be left alone.
    try old.writeFile(io, .{ .sub_path = "notes.txt", .data = "user's own file" });

    _ = applyPendingFor(.tui, allocator, io, root, "1.0.0") catch null;

    try std.testing.expectError(error.FileNotFound, old.access(io, staged_name, .{}));
    try std.testing.expectError(error.FileNotFound, old.access(io, marker_name, .{}));
    try old.access(io, "notes.txt", .{});
}
