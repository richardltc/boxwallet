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
/// The GUI release's pairing manifest, one line per target:
/// `<asset>␠␠slint-<ver>␠␠<64-hex>`. Names which Slint runtime that build needs
/// and hashes the copy the release ships. Itself listed in `SHA256SUMS`, so it
/// carries the same trust as the downloads — see `Runtime`.
const runtime_name = "RUNTIME";
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
/// The staged bundle's runtime, unpacked at stage time and moved into place
/// beside the exe at apply time. Named `slint-<ver>` exactly as it must end up,
/// so the staged exe's `$ORIGIN/slint-<ver>` RUNPATH resolves to it *in the
/// staging directory* — which is what lets the pre-flight test the real pair.
const staged_runtime_prefix = "slint-";
/// Scratch directory the downloaded bundle is unpacked into before its pieces
/// are moved to their staged names. Removed on every path.
const unpack_subdir = "unpack";
/// Suffix for a runtime directory being installed. It's built under this name
/// and renamed into place, so the live directory is only ever created whole —
/// never written into while a process might be mapping the `.so` inside it.
const runtime_new_suffix = ".bw-new";
/// The Slint shared library inside a runtime directory, and the GUI executable's
/// name inside a bundle. Both are fixed by `gui-release`'s layout.
///
/// Per-OS because the pairing scheme keys off this exact filename: it's what
/// `RUNTIME` hashes, what sits in `slint-<ver>/`, and what we hash to decide
/// whether the installed runtime already matches. Must stay in step with
/// `slintRuntimeName` in `build.zig`.
const runtime_so_name = switch (builtin.os.tag) {
    .macos => "libslint_cpp.dylib",
    else => "libslint_cpp.so",
};
const gui_exe_name = "boxwallet-gui";
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

    /// The GUI is checked before it's committed to; the TUI isn't. A TUI binary
    /// is self-contained, so there's no pair to get wrong and nothing a
    /// pre-flight would catch that the checksum didn't. The GUI's exe is one
    /// half of a pair, and the half that fails loudly and invisibly.
    fn preflight(self: Front) Preflight {
        return switch (self) {
            .tui => .none,
            .gui => .selftest,
        };
    }
};

/// Whether `swapBinary` proves the new binary runs before committing to it.
const Preflight = enum {
    /// Commit the swap once the bytes are in place.
    none,
    /// Run the new binary with `--selftest` from its final path and require a
    /// clean exit first.
    selftest,
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
        // Only where upstream publishes a Slint runtime we can build against.
        // Null everywhere else is what keeps the GUI updater dormant rather
        // than erroring — no asset was ever published for those targets.
        .gui => switch (builtin.os.tag) {
            .linux => "boxwallet-gui-linux-" ++ arch,
            // Apple Silicon only: there is no Intel macOS Slint package at all.
            // Not yet published — the bundle builds but hasn't been launched on
            // real hardware, so it's built by `gui-release-unverified` and left
            // out of `release-all`. Until a release carries it, a check here
            // finds no asset in SHA256SUMS and reports verify_failed, so this
            // stays null until the bundle actually ships.
            .macos => null,
            else => null,
        },
    };
}

/// The TUI's asset name. Kept so existing callers read unchanged.
pub const asset_name: ?[]const u8 = assetFor(.tui);

/// Which Slint runtime a published GUI build needs, read from the release's
/// `RUNTIME` manifest.
///
/// This is the whole pairing protocol. `boxwallet-gui` is linked `BIND_NOW`
/// against 115 undefined Slint symbols (21 of them data objects), so an exe and
/// a runtime from different releases don't degrade — `ld.so` fails the process
/// *before* `main`, with nothing on screen and none of our recovery code
/// running. The runtime is therefore installed into a version-named directory
/// and the exe's RUNPATH points at that exact name, so a mismatched pair can
/// never be assembled: the old exe keeps finding the old directory.
///
/// `dir` is what the exe will look for; `sha` lets us verify a runtime that's
/// *already installed* before deciding we can skip downloading the bundle.
const Runtime = struct {
    /// Directory name, e.g. `slint-1.17.1` — bounded because it's server-supplied
    /// and ends up in a filesystem path.
    dir_buf: [64]u8 = @splat(0),
    dir_len: usize = 0,
    sha: [32]u8 = @splat(0),

    fn dir(self: *const Runtime) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }
};

/// Pull `asset`'s line out of a `RUNTIME` manifest.
///
/// Returns null on anything unexpected — a missing line, a directory name that
/// isn't `slint-<something>`, a name long enough to overflow the buffer, or a
/// malformed digest. The caller treats null as `verify_failed` rather than
/// "probably fine": guessing here is how an exe-only update gets applied against
/// the wrong runtime, which is precisely the unbootable pair this exists to
/// prevent.
fn parseRuntime(text: []const u8, asset: []const u8) ?Runtime {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        if (!std.mem.eql(u8, name, asset)) continue;

        const dir_name = it.next() orelse return null;
        const hex = it.next() orelse return null;
        // A stray fourth field means we're reading a format we don't understand.
        if (it.next() != null) return null;

        // Must look like a runtime directory: the name is joined onto a path, so
        // a `..` or an absolute path here would escape the install directory.
        if (!std.mem.startsWith(u8, dir_name, staged_runtime_prefix)) return null;
        if (dir_name.len <= staged_runtime_prefix.len) return null;
        if (std.mem.indexOfAny(u8, dir_name, "/\\") != null) return null;

        var rt: Runtime = .{};
        if (dir_name.len > rt.dir_buf.len) return null;
        @memcpy(rt.dir_buf[0..dir_name.len], dir_name);
        rt.dir_len = dir_name.len;
        if (hex.len != 64) return null;
        _ = std.fmt.hexToBytes(&rt.sha, hex) catch return null;
        return rt;
    }
    return null;
}

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
    // Resolved at comptime, but the `orelse` has to stay ordinary control flow:
    // `comptime <expr> orelse return` puts the return inside the comptime scope,
    // which fails to compile on exactly the targets where the answer is null.
    const maybe_asset = comptime assetFor(front);
    const asset = maybe_asset orelse return .{ .status = .unsupported };
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

    // The GUI ships as an exe plus a Slint runtime that must match it exactly.
    // Read the release's RUNTIME manifest and compare the runtime it names
    // against what's installed beside our exe: if they already agree we can take
    // the 4.8 MB exe on its own, otherwise we need the 16 MB bundle. The TUI is a
    // single file and skips all of this.
    var runtime: ?Runtime = null;
    var fetch_asset = asset;
    var bundle_buf: [96]u8 = undefined;
    if (front == .gui) {
        const rt_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ src.download_base, tag, runtime_name });
        defer gpa.free(rt_url);
        const rt_text = try fetchText(gpa, io, rt_url, max_sums);
        defer gpa.free(rt_text);

        // Fail closed. A missing or unparseable line is not "probably the same
        // runtime" — assuming that is exactly how an exe-only update lands
        // against the wrong runtime and the app stops starting.
        const rt = parseRuntime(rt_text, asset) orelse return error.VerifyFailed;
        runtime = rt;
        if (!installedRuntimeMatches(gpa, io, &rt))
            fetch_asset = try std.fmt.bufPrint(&bundle_buf, "{s}.zip", .{asset});
    }

    const want = parseChecksum(sums, fetch_asset) orelse return error.VerifyFailed;

    // A newer release exists and we're committed to fetching it — let the UI
    // announce the download before we spend time on it.
    if (notify) |n| n.on_download_start(n.ctx, version);

    // Stream the binary to disk (flat memory), then verify before trusting it.
    const asset_url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ src.download_base, tag, fetch_asset });
    defer gpa.free(asset_url);
    try install.downloadFile(gpa, asset_url, updates_path, part_name, null);

    var dir = try std.Io.Dir.cwd().openDir(io, updates_path, .{ .iterate = true });
    defer dir.close(io);

    const got = try sha256File(io, dir, part_name);
    if (!std.mem.eql(u8, &got, &want)) {
        dir.deleteFile(io, part_name) catch {};
        return error.VerifyFailed;
    }

    // Clear any runtime staged by an earlier attempt, so what's on disk always
    // belongs to the version we're about to mark.
    clearStagedRuntimes(io, dir);

    if (fetch_asset.ptr != asset.ptr) {
        // A bundle: unpack it and move its two pieces to their staged names. The
        // runtime keeps its `slint-<ver>` name *here*, so the staged exe's
        // `$ORIGIN/slint-<ver>` RUNPATH resolves within the staging directory —
        // which is what lets the pre-flight exercise the real pair before we
        // commit to it.
        try unpackStagedBundle(gpa, io, dir, updates_path, asset, &runtime.?);
    } else {
        try dir.rename(part_name, dir, staged_name, io);
    }

    // Commit: the download is promoted, so write the marker last — its presence
    // always implies a complete, verified stage.
    dir.deleteFile(io, fails_name) catch {};
    try dir.writeFile(io, .{ .sub_path = marker_name, .data = version });

    return .{ .status = .staged, .version = vbuf, .blocked = !exeDirWritable(gpa, io) };
}

/// True if the running executable's directory is writable — i.e. a staged
/// update could actually be swapped in on next launch (`swapBinary` needs to
/// rename the running binary aside and drop the new one beside it). Probes by
/// creating and deleting a temp file there. Conservative: any failure to even
/// resolve/open the directory reads as not writable.
/// The directory holding the running executable — where a GUI's Slint runtime
/// sits, since its RUNPATH is `$ORIGIN/slint-<ver>`. Caller frees.
fn exeDirAlloc(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    return gpa.dupe(u8, std.fs.path.dirname(exe) orelse ".");
}

/// Is the runtime `rt` names already installed beside our exe, byte-for-byte?
///
/// Both halves matter. The *directory* answers "will the new exe find a runtime
/// at all", and the *hash* answers "is it the right one" — a user who unzipped a
/// bundle by hand, or a half-finished earlier install, can leave a directory with
/// the right name and the wrong contents. Getting this wrong means skipping the
/// bundle download and shipping an exe whose runtime doesn't match, so it's
/// checked rather than assumed. Only runs when a newer release exists; hashing
/// 34 MB measures ~84 ms.
fn installedRuntimeMatches(gpa: std.mem.Allocator, io: std.Io, rt: *const Runtime) bool {
    const exe_dir = exeDirAlloc(gpa, io) catch return false;
    defer gpa.free(exe_dir);

    const rt_path = std.fs.path.join(gpa, &.{ exe_dir, rt.dir() }) catch return false;
    defer gpa.free(rt_path);

    var d = std.Io.Dir.cwd().openDir(io, rt_path, .{}) catch return false;
    defer d.close(io);

    const got = sha256File(io, d, runtime_so_name) catch return false;
    return std.mem.eql(u8, &got, &rt.sha);
}

/// Drop any runtime (and unpack scratch) left in the staging directory.
///
/// `dir` must have been opened with `.iterate = true` — scanning it for
/// `slint-*` is the point, and without that flag the handle can't be read. Called
/// before a new stage commits, so the runtime sitting there always belongs to
/// the version the marker names — a stale one would be installed beside the new
/// exe and produce exactly the mismatch this design exists to rule out.
fn clearStagedRuntimes(io: std.Io, dir: std.Io.Dir) void {
    dir.deleteTree(io, unpack_subdir) catch {};
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, staged_runtime_prefix)) continue;
        dir.deleteTree(io, entry.name) catch {};
    }
}

/// Unpack the verified GUI bundle at `part_name` into its staged shape: the exe
/// at `staged_name` and the runtime at `slint-<ver>/`, both directly under the
/// staging directory.
///
/// The bundle's own layout is `<asset>/boxwallet-gui` plus
/// `<asset>/slint-<ver>/libslint_cpp.so`, so this flattens one level. The runtime
/// is re-hashed against `RUNTIME` afterwards: the zip as a whole already matched
/// `SHA256SUMS`, so this only catches a release whose manifest and bundle
/// disagree — but that release would produce an unbootable install, and catching
/// it here costs one pass over a file we just wrote.
fn unpackStagedBundle(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    updates_path: []const u8,
    asset: []const u8,
    rt: *const Runtime,
) !void {
    const unpack_path = try std.fs.path.join(gpa, &.{ updates_path, unpack_subdir });
    defer gpa.free(unpack_path);

    // Scratch, on every path — a half-unpacked tree left behind would be picked
    // up by the next `clearStagedRuntimes` anyway, but not before it had wasted
    // the disk on a machine that may not have it.
    defer dir.deleteTree(io, unpack_subdir) catch {};
    defer dir.deleteFile(io, part_name) catch {};

    try install.extractLocalZip(gpa, updates_path, part_name, unpack_path, null);

    var top = try dir.openDir(io, unpack_subdir, .{});
    defer top.close(io);
    var inner = try top.openDir(io, asset, .{});
    defer inner.close(io);

    // Copied rather than renamed so the executable bit is set explicitly: zip
    // stores modes, but nothing guarantees the extractor honoured them, and the
    // pre-flight has to be able to *run* this file.
    try inner.copyFile(gui_exe_name, dir, staged_name, io, .{ .permissions = .executable_file, .replace = true });

    var src_rt = try inner.openDir(io, rt.dir(), .{});
    defer src_rt.close(io);
    var dst_rt = try dir.createDirPathOpen(io, rt.dir(), .{});
    defer dst_rt.close(io);
    try src_rt.copyFile(runtime_so_name, dst_rt, runtime_so_name, io, .{ .replace = true });

    const got = try sha256File(io, dst_rt, runtime_so_name);
    if (!std.mem.eql(u8, &got, &rt.sha)) {
        dir.deleteTree(io, rt.dir()) catch {};
        dir.deleteFile(io, staged_name) catch {};
        return error.VerifyFailed;
    }
}

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

    var dir = std.Io.Dir.cwd().openDir(io, updates_path, .{ .iterate = true }) catch {
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

    // A staged runtime goes in *first*, and as a create rather than an
    // overwrite. Order matters and is the reason this is safe to interrupt:
    // installing a runtime the old exe doesn't reference changes nothing for it,
    // so between this line and the swap the old pair is still intact and still
    // boots. The reverse order would leave a window where the new exe is live
    // with no runtime it can load — an app that won't start.
    if (try installStagedRuntime(gpa, io, dir, exe_path)) |rt_name| gpa.free(rt_name);

    // Prove the exact pair we're about to commit actually links, before we
    // commit it. `boxwallet-gui` is BIND_NOW against 115 undefined Slint
    // symbols, so a mismatch is a failure inside `ld.so` *before* `main` — no
    // window, no message, and none of our code running to recover. `swapBinary`
    // runs this on the copy already sitting at the target path, so RUNPATH
    // resolves against the real install directory and the test is the real
    // thing rather than an approximation.
    swapBinary(gpa, io, staged_abs, exe_path, front.preflight()) catch |err| {
        // The exe never changed (swapBinary rolls back), so the old pair is
        // still whole. A runtime we installed for a swap that didn't happen is
        // harmless — nothing references it — and the next attempt reuses it.
        return err;
    };

    // Swap done — remove the staged files so the re-exec'd process sees nothing
    // pending and runs normally instead of swapping again.
    dir.deleteFile(io, staged_name) catch {};
    dir.deleteFile(io, marker_name) catch {};
    dir.deleteFile(io, fails_name) catch {};
    clearStagedRuntimes(io, dir);

    return .{ .exe_path = exe_path };
}

/// Move a staged `slint-<ver>/` runtime into place beside `exe_path`, if one is
/// staged. Returns the directory name installed (or null when there was none —
/// the ordinary case, where the release only changed the exe).
///
/// Installed as a **create**: the files go into `slint-<ver>.bw-new/` and the
/// *directory* is renamed into place, so a live runtime directory is never
/// written into. That isn't fussiness — the kernel refuses to let us overwrite a
/// running executable, but gives no such protection for a mapped `.so`: writing
/// one under a running process makes it re-read modified pages at old offsets,
/// or `SIGBUS` if the file shrinks.
///
/// An existing directory of the same name is left exactly as it is. It's the
/// runtime some already-installed exe is using, and the version in the name is
/// the promise that its contents match.
fn installStagedRuntime(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    exe_path: []const u8,
) !?[]u8 {
    const name = stagedRuntimeName(gpa, io, dir) orelse return null;
    errdefer gpa.free(name);

    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
    const dest = try std.fs.path.join(gpa, &.{ exe_dir, name });
    defer gpa.free(dest);

    const cwd = std.Io.Dir.cwd();
    // Already there — the version in the directory name is the guarantee, and
    // replacing it would be writing under whichever process is mapping it.
    if (cwd.access(io, dest, .{})) |_| return name else |_| {}

    const tmp = try std.fmt.allocPrint(gpa, "{s}{s}", .{ dest, runtime_new_suffix });
    defer gpa.free(tmp);
    cwd.deleteTree(io, tmp) catch {};

    var src = try dir.openDir(io, name, .{});
    defer src.close(io);
    var dst = try cwd.createDirPathOpen(io, tmp, .{});
    defer dst.close(io);
    try src.copyFile(runtime_so_name, dst, runtime_so_name, io, .{ .replace = true });

    cwd.rename(tmp, cwd, dest, io) catch |err| {
        cwd.deleteTree(io, tmp) catch {};
        return err;
    };
    return name;
}

/// Name of the runtime directory staged alongside the binary, if any. Caller
/// frees.
fn stagedRuntimeName(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ?[]u8 {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, staged_runtime_prefix)) continue;
        return gpa.dupe(u8, entry.name) catch null;
    }
    return null;
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
    preflight: Preflight,
) !void {
    const cwd = std.Io.Dir.cwd();

    const tmp_abs = try std.fmt.allocPrint(gpa, "{s}.bw-new", .{target_abs});
    defer gpa.free(tmp_abs);
    const old_abs = try std.fmt.allocPrint(gpa, "{s}.old", .{target_abs});
    defer gpa.free(old_abs);

    // Land the new binary beside the target (same filesystem) as an executable.
    cwd.deleteFile(io, tmp_abs) catch {};
    try cwd.copyFile(staged_abs, cwd, tmp_abs, io, .{ .permissions = .executable_file, .replace = true });

    // Test it where it will live, not where it was staged: RUNPATH is
    // `$ORIGIN`-relative, so only a copy sitting in the target directory
    // resolves the same libraries the committed binary would. If it can't
    // start, back out now — the target hasn't been touched yet.
    if (preflight == .selftest and !selftestOk(io, tmp_abs)) {
        cwd.deleteFile(io, tmp_abs) catch {};
        return error.SelftestFailed;
    }

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

/// Run `path --selftest` and report whether it exited cleanly.
///
/// The binary prints its version and exits before opening a window, so this
/// needs no display and costs ~100 ms, once per update. What it actually proves
/// is that the dynamic linker resolved every symbol: `boxwallet-gui` is
/// `BIND_NOW`, so reaching `main` at all means the exe and the Slint runtime
/// beside it are a working pair. A mismatch dies in `ld.so` with a non-zero
/// status, which is the case this exists to catch — otherwise the user's first
/// sign of trouble is an icon that does nothing when clicked.
///
/// Anything other than a clean exit — a signal, a spawn failure — reads as a
/// failure. Refusing an update we can't verify is recoverable; committing one
/// that won't start is not.
fn selftestOk(io: std.Io, path: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ path, "--selftest" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    return switch (child.wait(io) catch return false) {
        .exited => |code| code == 0,
        else => false,
    };
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

    try swapBinary(allocator, io, root ++ "/staged", root ++ "/boxwallet", .none);

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

test "parseRuntime reads the pairing line for our asset" {
    const text =
        \\boxwallet-gui-linux-x86_64  slint-1.17.1  ce76672d4201dfb172215d1d5e6a1052e865740a97b59b6506a99380b65cff82
        \\boxwallet-gui-linux-aarch64  slint-1.17.1  491aff4f54508deec4aee0140639b739c96dd09ae349e2da2fc111adfe115622
        \\
    ;
    const rt = parseRuntime(text, "boxwallet-gui-linux-aarch64").?;
    try std.testing.expectEqualStrings("slint-1.17.1", rt.dir());

    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "491aff4f54508deec4aee0140639b739c96dd09ae349e2da2fc111adfe115622");
    try std.testing.expectEqualSlices(u8, &want, &rt.sha);

    // An asset with no line is null, not the first line that happens to parse.
    try std.testing.expect(parseRuntime(text, "boxwallet-gui-linux-riscv64") == null);
}

test "parseRuntime fails closed on anything it doesn't fully understand" {
    // Every one of these must be null rather than a best guess: the caller turns
    // null into `verify_failed`, and a wrong guess here is what puts an exe next
    // to a runtime it can't load — a build that stops starting, with no window
    // and no message.
    const asset = "boxwallet-gui-linux-x86_64";
    const good_sha = "ce76672d4201dfb172215d1d5e6a1052e865740a97b59b6506a99380b65cff82";

    const cases = [_][]const u8{
        // No runtime directory field.
        asset ++ "  " ++ good_sha,
        // No digest.
        asset ++ "  slint-1.17.1",
        // Digest isn't hex.
        asset ++ "  slint-1.17.1  zzzz672d4201dfb172215d1d5e6a1052e865740a97b59b6506a99380b65cff82",
        // Digest is the wrong length.
        asset ++ "  slint-1.17.1  ce76672d",
        // An extra field means a format we don't know; don't guess at it.
        asset ++ "  slint-1.17.1  " ++ good_sha ++ "  extra",
        // Not a runtime directory name at all.
        asset ++ "  runtime  " ++ good_sha,
        // Bare prefix with no version.
        asset ++ "  slint-  " ++ good_sha,
        // Path traversal: this name is joined onto the install directory, so a
        // separator in it would let a release write outside where we intend.
        asset ++ "  slint-../../etc  " ++ good_sha,
        asset ++ "  slint-a/b  " ++ good_sha,
    };
    for (cases, 0..) |text, i| {
        errdefer std.debug.print("case {d} parsed when it should not have: {s}\n", .{ i, text });
        try std.testing.expect(parseRuntime(text, asset) == null);
    }

    // A directory name too long for the fixed buffer is refused, not truncated —
    // truncation would silently name a *different* directory.
    var long: [200]u8 = undefined;
    const overlong = try std.fmt.bufPrint(&long, "{s}  slint-{s}  {s}", .{ asset, "9" ** 80, good_sha });
    try std.testing.expect(parseRuntime(overlong, asset) == null);
}

test "installStagedRuntime creates the runtime, and never touches one already there" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-runtime";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var stage = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/stage/slint-1.17.1", .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = runtime_so_name, .data = "NEW RUNTIME" });

    var stage_dir = try std.Io.Dir.cwd().openDir(io, root ++ "/stage", .{ .iterate = true });
    defer stage_dir.close(io);

    var app_dir = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/app", .{});
    defer app_dir.close(io);

    // Nothing installed yet: the runtime lands under its version name.
    const name = (try installStagedRuntime(allocator, io, stage_dir, root ++ "/app/boxwallet-gui")).?;
    defer allocator.free(name);
    try std.testing.expectEqualStrings("slint-1.17.1", name);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("NEW RUNTIME", try app_dir.readFile(io, "slint-1.17.1/" ++ runtime_so_name, &buf));

    // No scratch left behind — a `.bw-new` directory surviving would be copied
    // over on the next attempt and waste the disk in the meantime.
    try std.testing.expectError(error.FileNotFound, app_dir.access(io, "slint-1.17.1" ++ runtime_new_suffix, .{}));

    // Run it again against a runtime already in place. It must be left exactly
    // as it is: some installed exe is linked against it, and overwriting a
    // mapped .so under a running process is the one thing this design forbids.
    try app_dir.writeFile(io, .{ .sub_path = "slint-1.17.1/" ++ runtime_so_name, .data = "IN USE" });
    const again = (try installStagedRuntime(allocator, io, stage_dir, root ++ "/app/boxwallet-gui")).?;
    defer allocator.free(again);
    try std.testing.expectEqualStrings("IN USE", try app_dir.readFile(io, "slint-1.17.1/" ++ runtime_so_name, &buf));
}

test "installStagedRuntime is a no-op when no runtime is staged" {
    // The ordinary case: a release that only changed the exe stages the bare
    // binary, and apply must not invent a runtime directory beside it.
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-nort";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var made = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/stage", .{});
    made.close(io);
    var stage = try std.Io.Dir.cwd().openDir(io, root ++ "/stage", .{ .iterate = true });
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = staged_name, .data = "NEW BINARY" });

    try std.testing.expect(try installStagedRuntime(allocator, io, stage, root ++ "/app/boxwallet-gui") == null);
}

test "clearStagedRuntimes drops staged runtimes and scratch, and nothing else" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-clear";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var made = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    made.close(io);
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var rt = try dir.createDirPathOpen(io, "slint-1.17.1", .{});
    rt.close(io);
    var un = try dir.createDirPathOpen(io, unpack_subdir, .{});
    un.close(io);
    try dir.writeFile(io, .{ .sub_path = staged_name, .data = "NEW BINARY" });
    try dir.writeFile(io, .{ .sub_path = marker_name, .data = "1.2.3" });

    clearStagedRuntimes(io, dir);

    try std.testing.expectError(error.FileNotFound, dir.access(io, "slint-1.17.1", .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(io, unpack_subdir, .{}));
    // The staged binary and its marker are the caller's to manage — a stale
    // runtime is cleared before a *new* stage commits, and the binary isn't.
    try dir.access(io, staged_name, .{});
    try dir.access(io, marker_name, .{});
}

test "swapBinary refuses to commit a binary that fails its pre-flight" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-update-preflight";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "boxwallet", .data = "OLD BINARY" });

    // Stands in for a GUI exe that can't link against the runtime beside it: a
    // non-zero exit is exactly what `ld.so` gives us for a mismatched pair.
    try dir.writeFile(io, .{ .sub_path = "bad", .data = "#!/bin/sh\nexit 1\n", .flags = .{ .permissions = .executable_file } });
    try std.testing.expectError(
        error.SelftestFailed,
        swapBinary(allocator, io, root ++ "/bad", root ++ "/boxwallet", .selftest),
    );

    // Refusing must leave the working install completely untouched — the whole
    // point is that a bad update costs the user nothing.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("OLD BINARY", try dir.readFile(io, "boxwallet", &buf));
    try std.testing.expectError(error.FileNotFound, dir.access(io, "boxwallet.bw-new", .{}));
    try std.testing.expectError(error.FileNotFound, dir.access(io, "boxwallet.old", .{}));

    // And a binary that passes goes in as normal.
    try dir.writeFile(io, .{ .sub_path = "good", .data = "#!/bin/sh\nexit 0\n", .flags = .{ .permissions = .executable_file } });
    try swapBinary(allocator, io, root ++ "/good", root ++ "/boxwallet", .selftest);
    try std.testing.expectEqualStrings("#!/bin/sh\nexit 0\n", try dir.readFile(io, "boxwallet", &buf));
    try std.testing.expectEqualStrings("OLD BINARY", try dir.readFile(io, "boxwallet.old", &buf));
}
