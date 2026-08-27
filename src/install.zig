const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;
const bzip2 = @import("bzip2.zig");

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
pub const Format = enum { tar_gz, zip, tar_bz2 };

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

/// The seekable file an extraction pass is reading through, so it can report a
/// real percentage rather than an open-ended byte count.
///
/// A tar stream never states its own size, so counting decompressed bytes gives
/// a numerator with no denominator. The file underneath *is* measurable: how far
/// through it we've read is monotonic and lands exactly on `total` as the pass
/// ends, which is what a progress bar needs. For `.tar.gz` that's the compressed
/// archive (so the fraction tracks output closely, compression being near-uniform
/// across a tarball of binaries — a very good proxy, not literal output bytes);
/// for `.tar.bz2` the untar reads the already-decompressed `.tar`, so there it
/// *is* literal output progress.
///
/// Null for a non-seekable or in-memory source (the unit tests), which keeps the
/// older indeterminate reporting — `total` 0, meaning "unknown" to the frontend.
pub const ArchiveExtent = struct {
    src: *std.Io.File.Reader,
    total: u64,
};

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
    // 1. Stream the archive to the scratch file on disk (flat memory — the body
    //    is never held in RAM). Shared with the file-only `downloadFile` path.
    try downloadFile(allocator, url, dest_root, scratch_name, progress);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);
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
    // The scratch file's size is the denominator for extraction progress: reading
    // through it is monotonic and ends exactly at the total, so the frontend gets a
    // real percentage instead of an open-ended count. A stat failure is not fatal —
    // extraction just reports indeterminate, as it always used to.
    const archive_size = scratch_reader.getSize() catch 0;
    const extent: ?ArchiveExtent = if (archive_size > 0)
        .{ .src = &scratch_reader, .total = archive_size }
    else
        null;

    switch (format) {
        .tar_gz => try extractArchive(io, &scratch_reader.interface, format, dest_root, strip, null, progress, extent, null),
        // Zip seeks around its central directory, so position isn't monotonic and
        // there's no honest percentage to report — it stays indeterminate.
        .zip => try extractZip(&scratch_reader, dest, progress),
        // bz2 measures its own decompressed .tar instead (see extractTarBz2).
        .tar_bz2 => try extractTarBz2(allocator, io, dest, &scratch_reader, scratch_name, strip, progress),
    }
}

/// Extract a `.tar.bz2` (read from the seekable `scratch_reader`) into `dest`.
///
/// bzip2 has no stdlib streaming `Reader`, so the archive is first decompressed to
/// a sibling `.tar` file on disk (our decoder is block-bounded, so memory stays
/// flat — a few MB regardless of archive size), then untarred from that seekable
/// file. This trades a temporary on-disk `.tar` for bounded RAM, per the project's
/// memory rule. `scratch_name` is the on-disk `.tar.bz2`; the temp `.tar` is
/// derived from it and removed afterward.
fn extractTarBz2(
    gpa: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    scratch_reader: *std.Io.File.Reader,
    scratch_name: []const u8,
    strip: u32,
    progress: ?Progress,
) !void {
    // Signal extraction has begun (covers the decompress pass; the untar below
    // then emits per-chunk progress through the TallyReader).
    report(progress, .extract, 0, 0);
    const tar_name = try std.fmt.allocPrint(gpa, "{s}.tar", .{scratch_name});
    defer gpa.free(tar_name);

    {
        var tar_file = try dest.createFile(io, tar_name, .{});
        defer tar_file.close(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var tw = tar_file.writer(io, &wbuf);
        try bzip2.decompress(gpa, &scratch_reader.interface, &tw.interface);
        try tw.interface.flush();
    }
    defer dest.deleteFile(io, tar_name) catch {};

    var tar_file = try dest.openFile(io, tar_name, .{});
    defer tar_file.close(io);
    var rbuf: [64 * 1024]u8 = undefined;
    var tr = tar_file.reader(io, &rbuf);
    // The bunzip pass above can't report (bzip2.decompress has no progress hook),
    // so the bar is indeterminate until here. From this point the source is the
    // decompressed .tar of known size, so the percentage is literal output
    // progress. A stat failure just drops back to indeterminate.
    const tar_size = tr.getSize() catch 0;
    const extent: ?ArchiveExtent = if (tar_size > 0) .{ .src = &tr, .total = tar_size } else null;
    report(progress, .extract, 0, tar_size);
    try untar(io, dest, &tr.interface, strip, null, progress, extent, null);
}

/// Why a download stopped. These names *are* the user-facing message: `app.zig`
/// prints `@errorName(err)` onto the coin pane ("status: ✗ HttpNotFound") and into
/// the log, and every coin's `install` propagates them untouched through `try`.
///
/// They exist because one `DownloadFailed` for every failure hid the only thing
/// worth knowing. A stale pinned URL (404), a rate-limited mirror (429), an
/// upstream outage (5xx), a transport reset mid-body, and a full disk are five
/// different problems with five different fixes — collapsing them forced a reader
/// to reach for `/proc` to tell which had happened.
pub const DownloadError = error{
    /// 404 — the pinned URL is wrong, or upstream moved/withdrew the asset. For a
    /// coin bundle this almost always means `core_version` and the build hash (or
    /// whatever else the URL splices together) have drifted out of lockstep.
    HttpNotFound,
    /// 403 — reachable but refused. Often a mirror blocking the client.
    HttpForbidden,
    /// 401 — the asset is behind credentials we don't send.
    HttpUnauthorized,
    /// 429 — rate-limited. Retrying later is the fix, not a code change.
    HttpTooManyRequests,
    /// 5xx — upstream is broken. Nothing on our side to correct.
    HttpServerError,
    /// Any other non-200. Redirects are followed before we get here, so a 3xx
    /// landing in this bucket means the redirect chain didn't resolve.
    HttpUnexpectedStatus,
    /// 416 — a resume asked to continue from an offset the current body doesn't
    /// reach, so the partial isn't this body. Handled internally by
    /// `downloadFileResumable` (drop the partial, refetch); it only escapes if
    /// the server says it twice.
    HttpRangeNotSatisfiable,
    /// A `206` arrived for a body that isn't the one our partial was cut from —
    /// the server honoured `Range` but ignored `If-Range`, which the real hosts
    /// do. Handled internally exactly like a 416: discard and refetch whole.
    HttpRangeStale,
    /// The transport died partway through the body (reset, timeout, DNS loss).
    /// Distinct from the status errors: the request *was* accepted.
    DownloadInterrupted,
    /// The bytes arrived but couldn't be written — a full disk, a read-only or
    /// unwritable install root. Nothing to do with the network.
    DownloadWriteFailed,
};

/// Map a non-200 response onto the `DownloadError` that names it. Split out and
/// pure so the mapping is unit-testable without a server to answer.
fn statusError(status: std.http.Status) DownloadError {
    return switch (status) {
        .not_found => error.HttpNotFound,
        .forbidden => error.HttpForbidden,
        .unauthorized => error.HttpUnauthorized,
        .too_many_requests => error.HttpTooManyRequests,
        else => switch (status.class()) {
            .server_error => error.HttpServerError,
            else => error.HttpUnexpectedStatus,
        },
    };
}

/// Stream `url` to `<dest_dir>/<dest_name>` (creating `dest_dir` if missing),
/// reporting download progress, **without** extracting anything. Caller owns the
/// resulting file (it is not deleted here).
///
/// `downloadAndExtract` uses this for its download phase; coins whose bundle the
/// streaming extractor can't unpack use it directly — e.g. Zano, whose Linux
/// build is a self-extracting AppImage that must land on disk as a file and then
/// be run with `--appimage-extract`. Memory stays flat: the body is streamed to
/// disk in bounded chunks, never held in RAM.
///
/// Fails with a `DownloadError` naming *why* — see that error set. The destination
/// file is only created once the response status is known good, so a rejected
/// request leaves no truncated file behind.
pub fn downloadFile(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_dir: []const u8,
    dest_name: []const u8,
    progress: ?Progress,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        // Ask the transport for the raw bytes (no re-encoding) so a compressed
        // archive arrives intact and the content-length we need for the progress
        // bar is present.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    // Checked before the destination file is created, so a 404 leaves no stub.
    if (response.head.status != .ok) return statusError(response.head.status);

    const total = response.head.content_length orelse 0;

    // Buffering on disk rather than in memory is the whole point: a coin bundle is
    // tens of MB, which we don't want resident on a low-spec box.
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
    defer dest.close(io);

    var out = try dest.createFile(io, dest_name, .{});
    defer out.close(io);

    var transfer_buffer: [32 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var write_buffer: [32 * 1024]u8 = undefined;
    var out_writer = out.writer(io, &write_buffer);

    var received: u64 = 0;
    report(progress, .download, 0, total);
    while (true) {
        const n = reader.stream(&out_writer.interface, .limited(256 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            // Keep the two sides of the pipe apart: a dead transport and an
            // unwritable disk look identical from here otherwise.
            error.ReadFailed => return error.DownloadInterrupted,
            error.WriteFailed => return error.DownloadWriteFailed,
        };
        received += n;
        report(progress, .download, received, total);
    }
    // The tail of the body is still buffered; a full disk surfaces here rather
    // than in the loop above, so it gets the same name.
    out_writer.interface.flush() catch return error.DownloadWriteFailed;
}

// --- resumable downloads ---------------------------------------------------
//
// A coin bundle is tens of MB: if one dies partway, refetching it costs seconds
// and the simple `downloadFile` above is the right shape. A *chain snapshot* is
// several GB — Divi's is ~4.7 GB — where losing the transfer at 90% and starting
// again is the difference between a usable feature and an unusable one. So the
// snapshot path gets `downloadFileResumable`, which keeps its partial across
// attempts (and across app restarts) and asks the server to continue it.

/// Suffix of the in-progress download. The bytes only take the caller's chosen
/// name once they are **all** there, so "the file exists" means "complete" and
/// nothing downstream has to ask a second question to find out.
const part_suffix = ".part";

/// Suffix of the sidecar that records which upstream body a partial belongs to.
const origin_suffix = ".origin";

/// Longest validator we'll keep. ETags are short; anything longer than this we
/// simply decline to resume against, which costs a restart, never correctness.
const max_validator_len = 128;

/// Whether a resumed transfer picked up where it left off, or started over.
const ResumeKind = enum { fresh, appended };

/// A cooperative stop signal for the long transfers.
///
/// A chain snapshot runs for the better part of an hour, which is long enough
/// that the user will want to pause it — and long enough that it is almost
/// certainly still running when they close the app. Both are the same need: stop
/// promptly, keep what's on disk, and be resumable. `func` is polled between
/// chunks (cheap, and never mid-write), and a true answer unwinds the transfer
/// with `error.Paused` rather than a failure.
pub const Cancel = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) bool,
};

/// Whether a stop has been requested (false when no signal was supplied).
fn stopRequested(cancel: ?Cancel) bool {
    const c = cancel orelse return false;
    return c.func(c.ctx);
}

/// Build the `.part` / `.part.origin` names for `dest_name` in caller-owned
/// buffers. Errors only if the name is too long to suffix, which for our
/// dot-prefixed scratch names cannot happen.
fn partNames(
    dest_name: []const u8,
    part_buf: []u8,
    origin_buf: []u8,
) !struct { part: []const u8, origin: []const u8 } {
    const part = std.fmt.bufPrint(part_buf, "{s}" ++ part_suffix, .{dest_name}) catch
        return error.DownloadWriteFailed;
    const origin = std.fmt.bufPrint(origin_buf, "{s}" ++ origin_suffix, .{part}) catch
        return error.DownloadWriteFailed;
    return .{ .part = part, .origin = origin };
}

/// Stream `url` to `<dest_dir>/<dest_name>` like `downloadFile`, but **resume an
/// interrupted transfer** instead of refetching from byte zero, and stop promptly
/// when `cancel` says so.
///
/// The bytes accumulate in a sibling `<dest_name>.part` and are renamed into place
/// only once the transfer is complete, so `dest_name` existing *is* the "already
/// downloaded" answer. That matters because the caller has more to do afterwards
/// (a snapshot still has to be unpacked): without the split, quitting between the
/// download finishing and the unpack finishing would leave a full-length file with
/// no way to tell it apart from a partial, and cost a multi-GB refetch. With it,
/// this call returns immediately.
///
/// A stopped or failed transfer keeps its `.part` — that's the point — so the
/// caller decides when to discard it (`discardPartial`). A cancelled transfer
/// returns `error.Paused`, which is not a failure: it means "resume me later".
///
/// **Resuming the wrong body is the hazard this guards against.** Snapshot
/// archives are regenerated upstream on a schedule (Divi rebuilds its chain
/// snapshot every 24h), so a `.part` from yesterday may belong to a different
/// archive than the one the server would send today. Appending to it would splice
/// two unrelated gzip streams into a file whose corruption only surfaces at the
/// end of a multi-GB extract. So each partial carries a sidecar holding the
/// response validator (`ETag`, else `Last-Modified`) it was cut from, and the
/// resume sends `If-Range:` with it — then checks the answer rather than trusting
/// it (see `fetchRange`). A partial with no sidecar is never resumed.
///
/// Memory is flat and small — the same fixed buffers as `downloadFile`, plus one
/// bounded validator. Nothing about the file's size is held in RAM.
pub fn downloadFileResumable(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_dir: []const u8,
    dest_name: []const u8,
    progress: ?Progress,
    cancel: ?Cancel,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_dir, .{});
    defer dest.close(io);

    var part_buf: [std.fs.max_name_bytes]u8 = undefined;
    var origin_buf: [std.fs.max_name_bytes]u8 = undefined;
    const names = try partNames(dest_name, &part_buf, &origin_buf);

    // Must run *before* the completeness check below, or an old-layout partial
    // would be mistaken for a finished archive and never repaired.
    migrateLegacyPartial(io, dest, dest_name, names.part, names.origin);

    // Already complete from an earlier run — nothing to fetch, and nothing to
    // check with the server either.
    if (dest.access(io, dest_name, .{})) |_| return else |_| {}

    // What's already on disk, and which body it came from. Both must be present
    // for a resume to be safe; either one alone is worthless, so drop the pair.
    var validator_buf: [max_validator_len]u8 = undefined;
    var have: u64 = 0;
    var validator: []const u8 = "";
    if (readOrigin(io, dest, names.origin, &validator_buf)) |v| {
        have = partialSize(io, dest, names.part);
        if (have > 0) validator = v;
    }
    if (validator.len == 0) {
        have = 0;
        dest.deleteFile(io, names.origin) catch {};
    }

    // Two ways a resume can turn out not to be one, both meaning "this partial
    // isn't the body the server has": a 416 (our offset is past the end of it),
    // and a 206 whose validator doesn't match ours (the server honoured `Range`
    // while ignoring `If-Range` — which the real hosts do). Either way, drop the
    // partial and fetch the whole thing. One retry only, so a server that keeps
    // saying it fails rather than looping.
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        if (fetchRange(allocator, io, dest, url, names.part, names.origin, have, validator, progress, cancel)) |_| {
            break;
        } else |err| switch (err) {
            error.HttpRangeNotSatisfiable, error.HttpRangeStale => {
                if (attempt > 0) return error.HttpUnexpectedStatus;
                discardPartialIn(io, dest, names.part, names.origin);
                have = 0;
                validator = "";
            },
            else => return err,
        }
    }

    // Complete. Publishing the finished bytes under the caller's name is the last
    // step, so a stop at any earlier point leaves only a `.part` to resume.
    try dest.rename(names.part, dest, dest_name, io);
    dest.deleteFile(io, names.origin) catch {};
}

/// One download attempt. Requests `have..` when resuming, writes the body at the
/// offset the server's answer implies, and clears the sidecar once the file is
/// complete. Split out so `downloadFileResumable` can retry it without fighting
/// the request's `defer`s.
fn fetchRange(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    url: []const u8,
    dest_name: []const u8,
    origin_name: []const u8,
    have: u64,
    validator: []const u8,
    progress: ?Progress,
    cancel: ?Cancel,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    // `bytes=<have>-`: everything from where we stopped. Paired with `If-Range`,
    // so the server itself decides whether continuing is valid.
    var range_buf: [64]u8 = undefined;
    var extra: [2]std.http.Header = undefined;
    var extra_n: usize = 0;
    if (have > 0) {
        extra[0] = .{
            .name = "range",
            .value = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have}) catch unreachable,
        };
        extra[1] = .{ .name = "if-range", .value = validator };
        extra_n = 2;
    }

    var req = try client.request(.GET, uri, .{
        // Raw bytes, no re-encoding — a range only means anything against the
        // identity body, and the length we need for the bar comes with it.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = extra[0..extra_n],
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const kind: ResumeKind = switch (response.head.status) {
        // The whole body — either we asked for it, or the server declined to
        // continue ours (regenerated snapshot, no range support). Start over.
        .ok => .fresh,
        .partial_content => blk: {
            // **`If-Range` is not enough.** Verified against the real hosts: both
            // GitHub's asset CDN and the snapshot origin honour `Range` while
            // ignoring `If-Range` outright, answering 206 for a validator that
            // matches nothing. Taking that at face value would append today's tail
            // onto yesterday's snapshot and produce a corrupt multi-GB archive
            // that only fails at the end of the unpack.
            //
            // So the answer is checked here instead of trusted: continue only if
            // the response's own validator is the one the partial was cut from.
            // Anything else — a different validator, or none to compare — is
            // treated as a different body and refetched from zero.
            if (!validatorMatches(&response.head, validator)) return error.HttpRangeStale;
            break :blk .appended;
        },
        .range_not_satisfiable => return error.HttpRangeNotSatisfiable,
        else => return statusError(response.head.status),
    };

    // Where writing starts, and the size of the *whole* file: on a 206 the
    // content-length covers only the remainder, so the bar's denominator has to
    // add back what we already hold.
    const start: u64 = switch (kind) {
        .fresh => 0,
        .appended => have,
    };
    const total: u64 = if (response.head.content_length) |len| start + len else 0;

    // Record which body this partial belongs to *before* writing any of it, so a
    // crash mid-transfer still leaves a resumable pair. A body with no validator
    // is fine — it just can't be resumed later.
    if (kind == .fresh) writeOrigin(io, dest, origin_name, &response.head);

    // `truncate = false` keeps the bytes we're appending to; the fresh path wants
    // the old partial gone, so it truncates.
    var out = try dest.createFile(io, dest_name, .{ .truncate = kind == .fresh });
    defer out.close(io);

    var transfer_buffer: [32 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    var write_buffer: [32 * 1024]u8 = undefined;
    var out_writer = out.writer(io, &write_buffer);
    if (start > 0) out_writer.seekTo(start) catch return error.DownloadWriteFailed;

    var received: u64 = start;
    report(progress, .download, received, total);
    while (true) {
        // Between chunks, never mid-write: a pause must leave the `.part` a
        // prefix of the body, or resuming from its length would skip bytes.
        if (stopRequested(cancel)) {
            out_writer.interface.flush() catch return error.DownloadWriteFailed;
            return error.Paused;
        }
        const n = reader.stream(&out_writer.interface, .limited(256 * 1024)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.DownloadInterrupted,
            error.WriteFailed => return error.DownloadWriteFailed,
        };
        received += n;
        report(progress, .download, received, total);
    }
    out_writer.interface.flush() catch return error.DownloadWriteFailed;
}

/// Rescue a partial written by the first version of this code, which accumulated
/// bytes under the *final* name with the sidecar beside it (`<name>.origin`).
///
/// Under the current layout the final name means "complete", so such a file would
/// be handed straight to the unpacker and fail — throwing away several GB the user
/// had already fetched. The old sidecar is an unambiguous marker (the new one is
/// `<name>.part.origin`), so its presence identifies the old layout exactly:
/// shuffle both into their current names and the transfer resumes as normal.
///
/// Best-effort — if the renames don't take, the worst case is the refetch this is
/// trying to avoid, never a wrong result.
fn migrateLegacyPartial(
    io: std.Io,
    dir: std.Io.Dir,
    dest_name: []const u8,
    part_name: []const u8,
    origin_name: []const u8,
) void {
    var legacy_buf: [std.fs.max_name_bytes]u8 = undefined;
    const legacy_origin = std.fmt.bufPrint(&legacy_buf, "{s}" ++ origin_suffix, .{dest_name}) catch return;
    dir.access(io, legacy_origin, .{}) catch return;

    dir.rename(dest_name, dir, part_name, io) catch {
        // No partial to keep, just a stray sidecar — drop it so it can't be
        // mistaken for one later.
        dir.deleteFile(io, legacy_origin) catch {};
        return;
    };
    dir.rename(legacy_origin, dir, origin_name, io) catch {
        // The bytes moved but their validator didn't, so the partial can't be
        // resumed safely. Discard it rather than risk appending to a different
        // body — `downloadFileResumable` would refuse it anyway.
        dir.deleteFile(io, part_name) catch {};
        dir.deleteFile(io, legacy_origin) catch {};
    };
}

/// Whether a `206` really is a continuation of the body `stored` came from.
///
/// The partial's sidecar holds whichever validator the original response carried
/// — `ETag` for preference, `Last-Modified` otherwise — so a match on either
/// header identifies the same body. A response carrying neither is unverifiable
/// and reads as a mismatch: refetching costs bandwidth, appending to the wrong
/// body costs correctness.
fn validatorMatches(head: *const std.http.Client.Response.Head, stored: []const u8) bool {
    if (stored.len == 0) return false;
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag") or std.ascii.eqlIgnoreCase(h.name, "last-modified")) {
            if (std.mem.eql(u8, h.value, stored)) return true;
        }
    }
    return false;
}

/// Size of an existing partial, or 0 when there isn't one.
fn partialSize(io: std.Io, dir: std.Io.Dir, name: []const u8) u64 {
    var f = dir.openFile(io, name, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

/// Read the recorded validator into `buf`, or null when there's no usable
/// sidecar. Anything unreadable, empty, or over `max_validator_len` reads as
/// "can't resume" — which costs a re-download, never a corrupt file.
fn readOrigin(io: std.Io, dir: std.Io.Dir, origin_name: []const u8, buf: []u8) ?[]const u8 {
    var f = dir.openFile(io, origin_name, .{}) catch return null;
    defer f.close(io);
    var rbuf: [max_validator_len]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const n = fr.interface.readSliceShort(buf) catch return null;
    const v = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (v.len == 0 or v.len >= max_validator_len) return null;
    return v;
}

/// Record the response's validator beside the partial, preferring the strong
/// `ETag` and falling back to `Last-Modified`. Best-effort: a body that carries
/// neither (or a sidecar we can't write) simply won't be resumable.
fn writeOrigin(io: std.Io, dir: std.Io.Dir, origin_name: []const u8, head: *const std.http.Client.Response.Head) void {
    var it = head.iterateHeaders();
    var fallback: ?[]const u8 = null;
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
            if (h.value.len > 0 and h.value.len < max_validator_len) {
                dir.writeFile(io, .{ .sub_path = origin_name, .data = h.value }) catch {};
                return;
            }
        } else if (std.ascii.eqlIgnoreCase(h.name, "last-modified")) {
            if (h.value.len > 0 and h.value.len < max_validator_len) fallback = h.value;
        }
    }
    if (fallback) |v| dir.writeFile(io, .{ .sub_path = origin_name, .data = v }) catch {};
}

/// Throw away a resumable download's partial *and* its sidecar, so the next
/// attempt starts clean. Call this when the partial is known bad (a failed
/// extract) or no longer wanted; a plain failed transfer should keep it.
pub fn discardPartial(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    dest_name: []const u8,
) void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dest_dir, .{}) catch return;
    defer dir.close(io);

    var part_buf: [std.fs.max_name_bytes]u8 = undefined;
    var origin_buf: [std.fs.max_name_bytes]u8 = undefined;
    const names = partNames(dest_name, &part_buf, &origin_buf) catch return;
    // The completed file too: this is "throw the download away", and a finished
    // archive the caller has rejected is no more wanted than a partial one.
    dir.deleteFile(io, dest_name) catch {};
    discardPartialIn(io, dir, names.part, names.origin);
}

/// `discardPartial` against an already-open dir, for the in-progress pair only.
fn discardPartialIn(io: std.Io, dir: std.Io.Dir, part_name: []const u8, origin_name: []const u8) void {
    dir.deleteFile(io, part_name) catch {};
    dir.deleteFile(io, origin_name) catch {};
}

/// How many bytes of this download are already on disk — what a frontend shows as
/// "resume from N" before starting. Counts a completed-but-not-yet-used file at
/// full size, and an in-progress `.part` only when its sidecar is there to resume
/// against. 0 when there's nothing usable.
pub fn partialBytes(
    allocator: std.mem.Allocator,
    dest_dir: []const u8,
    dest_name: []const u8,
) u64 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dest_dir, .{}) catch return 0;
    defer dir.close(io);

    const done = partialSize(io, dir, dest_name);
    if (done > 0) return done;

    var part_buf: [std.fs.max_name_bytes]u8 = undefined;
    var origin_buf: [std.fs.max_name_bytes]u8 = undefined;
    const names = partNames(dest_name, &part_buf, &origin_buf) catch return 0;
    var validator_buf: [max_validator_len]u8 = undefined;
    if (readOrigin(io, dir, names.origin, &validator_buf) == null) return 0;
    return partialSize(io, dir, names.part);
}

/// Extract an already-downloaded `.tar.gz` at `<dir>/<name>` into `dest_root`,
/// dropping `strip` leading path components and reporting extract progress.
///
/// The download half of `downloadAndExtract` fetches to a scratch file it then
/// deletes on every path; a resumable snapshot download instead keeps its partial
/// across attempts, so the two halves are separate calls. Same streaming
/// pipeline, same flat memory: gunzip → untar straight to disk, nothing but the
/// gzip window and fixed buffers resident.
pub fn extractLocalTarGz(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    dest_root: []const u8,
    strip: u32,
    progress: ?Progress,
    cancel: ?Cancel,
) !void {
    return extractLocalTarGzAllowing(allocator, dir_path, name, dest_root, strip, null, progress, cancel);
}

/// `extractLocalTarGz`, restricted to the top-level entries in `allow_top_level`
/// — everything else in the archive is skipped rather than written.
///
/// For unpacking an archive into a directory that is **not ours**: a chain
/// snapshot lands in the coin's data dir, which is the daemon's (and possibly
/// another app's) home. The archive decides its own paths, so without this a
/// tampered or compromised snapshot could create any file it liked there. It
/// can't overwrite what's already present (`.exclusive = true` on create makes
/// extraction fail instead), but *creating* is enough on a first run: the coin's
/// conf doesn't exist yet at snapshot time, and a bitcoin-derived conf can carry
/// `walletnotify=<command>`, which the daemon would then execute. Naming the
/// directories a snapshot is meant to lay down closes that off.
///
/// Null (via `extractLocalTarGz`) keeps the plain, unfiltered path, which is what
/// every install uses — those archives are unpacked into BoxWallet's own install
/// root, and their whole contents are the point.
pub fn extractLocalTarGzAllowing(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    dest_root: []const u8,
    strip: u32,
    allow_top_level: ?[]const []const u8,
    progress: ?Progress,
    cancel: ?Cancel,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var archive = try dir.openFile(io, name, .{});
    defer archive.close(io);

    var read_buffer: [32 * 1024]u8 = undefined;
    var archive_reader = archive.reader(io, &read_buffer);
    const archive_size = archive_reader.getSize() catch 0;
    const extent: ?ArchiveExtent = if (archive_size > 0)
        .{ .src = &archive_reader, .total = archive_size }
    else
        null;

    try extractArchive(io, &archive_reader.interface, .tar_gz, dest_root, strip, allow_top_level, progress, extent, cancel);
}

/// Extract an already-downloaded zip at `dir_path/name` into `dest_root`
/// (created if missing).
///
/// The zip counterpart to `extractLocalTarGz`, and separate for the same reason
/// `extractArchive` refuses `.zip`: a zip's central directory sits at EOF, so it
/// can't be read from a stream — extraction seeks around the on-disk file. Memory
/// stays flat all the same (a deflate window plus the read buffer).
///
/// `strip` is deliberately absent: `std.zip` has no equivalent, and the one
/// caller (the GUI self-update bundle) wants the archive's own layout preserved
/// so it can pick the exe and the runtime directory out of it by name.
pub fn extractLocalZip(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    dest_root: []const u8,
    progress: ?Progress,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);

    var archive = try dir.openFile(io, name, .{});
    defer archive.close(io);

    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    var read_buffer: [32 * 1024]u8 = undefined;
    var archive_reader = archive.reader(io, &read_buffer);
    try extractZip(&archive_reader, dest, progress);
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
/// `allow_top_level`, when given, restricts what may be written to entries whose
/// first path component (after `strip`) is on the list — see
/// `extractLocalTarGzAllowing` for why that exists. Null extracts everything,
/// which is what every install path does.
pub fn extractArchive(
    io: std.Io,
    archive: *std.Io.Reader,
    format: Format,
    dest_root: []const u8,
    strip: u32,
    allow_top_level: ?[]const []const u8,
    progress: ?Progress,
    extent: ?ArchiveExtent,
    cancel: ?Cancel,
) !void {
    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dest.close(io);

    switch (format) {
        .tar_gz => {
            var window: [flate.max_window_len]u8 = undefined;
            var dz = flate.Decompress.init(archive, .gzip, &window);

            // Signal that extraction has begun (a frontend pegs the download bar
            // full here), then stream gunzip → tally → untar. Report the total up
            // front where it's known, so the bar starts determinate at 0% instead
            // of flicking through an indeterminate frame first.
            report(progress, .extract, 0, if (extent) |e| e.total else 0);
            try untar(io, dest, &dz.reader, strip, allow_top_level, progress, extent, cancel);
        },
        // These streaming-from-a-Reader paths are tar.gz only. Zip can't stream
        // (its central directory sits at EOF) and bzip2 has no stdlib streaming
        // decoder, so the download path routes them to `extractZip` /
        // `extractTarBz2` (both seekable, from the on-disk scratch file) and
        // neither reaches here.
        .zip => return error.ZipNotStreamable,
        .tar_bz2 => return error.Bzip2NotStreamable,
    }
}

/// Untar from `src` into the already-open `dest` directory, dropping `strip`
/// leading path components. A `TallyReader` is spliced in so the otherwise-opaque
/// `std.tar.extract` emits periodic `.extract` progress, and so tar has a real
/// buffer for the *buffered* source reads (`takeByte`) that PAX/GNU extended
/// headers (long paths, large file sizes) trigger — a zero-length buffer fails
/// those. Shared by the tar.gz (post-gunzip) and tar.bz2 (post-bunzip2) paths.
fn untar(
    io: std.Io,
    dest: std.Io.Dir,
    src: *std.Io.Reader,
    strip: u32,
    allow_top_level: ?[]const []const u8,
    progress: ?Progress,
    extent: ?ArchiveExtent,
    cancel: ?Cancel,
) !void {
    var tally_buffer: [64 * 1024]u8 = undefined;
    var tally: TallyReader = .init(src, &tally_buffer, progress, extent, cancel);

    // With an allow-list this has to walk the entries itself; without one it
    // stays on `std.tar.extract` exactly as before, so every install path is
    // untouched by the filtered variant existing.
    if (allow_top_level) |allow| return untarFiltered(io, dest, &tally, strip, allow);

    std.tar.extract(io, dest, &tally.interface, .{
        .strip_components = strip,
        .mode_mode = .executable_bit_only,
    }) catch {
        // A stop looks like a read failure from inside tar (that's the only way
        // out of the extractor), so the reader records which it was — otherwise a
        // deliberate pause would be reported to the user as a corrupt archive.
        if (tally.stopped) return error.Paused;
        return error.ExtractFailed;
    };
}

/// Untar, writing only the entries whose first path component is on `allow`.
/// Modelled on `std.tar.extract`'s own loop (which has no filter hook) over the
/// public `std.tar.Iterator`, keeping its two safety properties: files are
/// created **exclusively**, so nothing already on disk is ever replaced, and an
/// entry's unread bytes are skipped by `next()`, so passing over one can't
/// desync the stream.
///
/// Three things are dropped rather than written:
///   * anything whose top-level component isn't on the list;
///   * any path with a `..` component or an absolute root — the allow-list
///     already stops `../x`, but not `blocks/../../x`;
///   * **every symlink**, whatever its name. A chain snapshot has no business
///     carrying one, and a link is the obvious way to aim a permitted name at
///     somewhere unpermitted.
fn untarFiltered(
    io: std.Io,
    dest: std.Io.Dir,
    tally: *TallyReader,
    strip: u32,
    allow: []const []const u8,
) !void {
    var file_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var contents_buffer: [32 * 1024]u8 = undefined;

    var it: std.tar.Iterator = .init(&tally.interface, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });

    while (true) {
        const entry = it.next() catch {
            if (tally.stopped) return error.Paused;
            return error.ExtractFailed;
        } orelse break;

        if (entry.kind == .sym_link) continue;
        const path = permittedPath(entry.name, strip, allow) orelse continue;

        switch (entry.kind) {
            .directory => dest.createDirPath(io, path) catch return error.ExtractFailed,
            .file => {
                const parent = std.fs.path.dirname(path);
                if (parent) |p| dest.createDirPath(io, p) catch return error.ExtractFailed;
                var out = dest.createFile(io, path, .{ .exclusive = true }) catch return error.ExtractFailed;
                defer out.close(io);
                var writer = out.writer(io, &contents_buffer);
                it.streamRemaining(entry, &writer.interface) catch {
                    if (tally.stopped) return error.Paused;
                    return error.ExtractFailed;
                };
                writer.interface.flush() catch return error.ExtractFailed;
            },
            .sym_link => unreachable, // filtered above
        }
    }
}

/// The path an archive entry may be written to, or null to skip it: `strip`
/// leading components removed, rejected unless the remaining path is relative,
/// free of `..`, and rooted at one of `allow`.
fn permittedPath(name: []const u8, strip: u32, allow: []const []const u8) ?[]const u8 {
    // Both separators, so a Windows-style archive path can't slip a component
    // past the checks below on a POSIX host.
    const seps = "/\\";

    var rest = name;
    var i: u32 = 0;
    while (i < strip) : (i += 1) {
        const at = std.mem.indexOfAny(u8, rest, seps) orelse return null;
        rest = rest[at + 1 ..];
    }
    rest = std.mem.trimEnd(u8, rest, seps); // a directory entry's trailing "/"
    if (rest.len == 0) return null;
    if (std.fs.path.isAbsolute(rest) or rest[0] == '/' or rest[0] == '\\') return null;

    var parts = std.mem.splitAny(u8, rest, seps);
    const top = parts.next() orelse return null;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return null;
    }
    if (std.mem.eql(u8, top, "..") or std.mem.eql(u8, top, ".")) return null;

    for (allow) |a| if (std.mem.eql(u8, top, a)) return rest;
    return null;
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
    /// Measurable source underneath the pipeline, when there is one; drives the
    /// percentage instead of `count`. See `ArchiveExtent`.
    extent: ?ArchiveExtent,
    count: u64 = 0,
    /// Stop signal for the pass, polled between the chunks tar pulls.
    cancel: ?Cancel = null,
    /// Set when a pull was refused because a stop was asked for, so `untar` can
    /// tell a deliberate pause from a genuinely unreadable archive — the
    /// extractor collapses both into one opaque failure.
    stopped: bool = false,
    interface: std.Io.Reader,

    fn init(inner: *std.Io.Reader, buffer: []u8, progress: ?Progress, extent: ?ArchiveExtent, cancel: ?Cancel) TallyReader {
        return .{
            .inner = inner,
            .progress = progress,
            .extent = extent,
            .cancel = cancel,
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
        if (self.stop()) return error.ReadFailed;
        const n = try self.inner.stream(w, limit);
        self.bump(n);
        return n;
    }

    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *TallyReader = @fieldParentPtr("interface", r);
        if (self.stop()) return error.ReadFailed;
        const n = try self.inner.discard(limit);
        self.bump(n);
        return n;
    }

    /// Whether to refuse this pull because a stop was requested. Latches
    /// `stopped` so the reason survives tar's error flattening.
    fn stop(self: *TallyReader) bool {
        if (!stopRequested(self.cancel)) return false;
        self.stopped = true;
        return true;
    }

    fn bump(self: *TallyReader, n: usize) void {
        self.count += n;
        if (self.extent) |e| {
            // How far through the underlying file the pipeline has pulled. Clamped
            // because a buffered reader may have read ahead past what tar has
            // actually consumed, and a bar that reports >100% looks broken.
            report(self.progress, .extract, @min(e.src.logicalPos(), e.total), e.total);
        } else {
            // No measurable source: fall back to an open-ended count (total 0),
            // which the frontend renders as indeterminate.
            report(self.progress, .extract, self.count, 0);
        }
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

/// True if the file `name` under `dir_path` hashes (SHA-256) to `expected_hex`
/// (64 lowercase hex chars). Streamed through a fixed buffer — flat memory
/// regardless of file size — for verifying large checksummed downloads (e.g.
/// the Zcash proving parameters BitcoinZ needs) before they're put in place.
/// A missing/unreadable file reads as a mismatch rather than erroring: either
/// way the caller must not trust it.
pub fn fileMatchesSha256(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    name: []const u8,
    expected_hex: *const [64]u8,
) bool {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    var f = dir.openFile(io, name, .{}) catch return false;
    defer f.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = fr.interface.readSliceShort(&chunk) catch return false;
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    const digest = hasher.finalResult();

    var got_hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        const hex_chars = "0123456789abcdef";
        got_hex[i * 2] = hex_chars[b >> 4];
        got_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return std.mem.eql(u8, &got_hex, expected_hex);
}

/// The version-marker filename for a coin: `.<daemon_file>.version`, kept beside
/// the promoted binaries in the install root. Derived from the daemon file because
/// that's already unique per coin. Caller owns the returned slice.
fn versionMarkerName(allocator: std.mem.Allocator, daemon_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".{s}.version", .{daemon_file});
}

/// Run `argv` to completion and return however much of its stdout fits in `out`,
/// or `error.ChildFailed` if it exits non-zero. Generic: the caller supplies the
/// command, so no coin knowledge lives here.
///
/// Built for short, chatty-once probes like `<daemon> --version`. Memory stays
/// flat and no pipe is pumped: the child's stdout is redirected to a scratch file
/// in `scratch_root` (unlinked on every path, like the daemon-startup stderr
/// capture), which is then read back into the caller's fixed buffer. Anything the
/// child prints beyond `out.len` is simply truncated — a version banner is one
/// short line, and a runaway child can't grow our footprint.
///
/// stdin/stderr are `.ignore`d: a probe must never block on input, and its
/// diagnostics aren't ours to surface.
pub fn captureStdout(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    scratch_root: []const u8,
    scratch_name: []const u8,
    out: []u8,
) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Open the scratch directory and work relative to it, rather than joining a
    // path and using the `*Absolute` helpers: `createFileAbsolute` quietly accepts
    // a relative path (it just forwards to the cwd) while `deleteFileAbsolute`
    // asserts on one, so a caller passing a relative root would create the file,
    // then panic in the cleanup `defer` — and leave the scratch file in the cwd.
    // A `Dir` handle can't be asymmetric that way, and matches `downloadFile`.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, scratch_root, .{});
    defer dir.close(io);

    var file = try dir.createFile(io, scratch_name, .{ .read = true });
    defer {
        file.close(io);
        dir.deleteFile(io, scratch_name) catch {};
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = file },
        .stderr = .ignore,
        // Don't flash a console window for the probe (Windows).
        .create_no_window = builtin.os.tag == .windows,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }

    const n = try file.readPositionalAll(io, out, 0);
    return out[0..n];
}

/// Pull the bare version out of a daemon's `--version` banner.
///
/// The daemons word their banners differently but agree on the shape — a dotted
/// version introduced by a `v`, with build noise after it:
///
///     Zano v2.1.17.469[1b1cc03]
///     NERVA 'Legacy Reborn' (v0.2.2.0-51ae77bda)
///     Salvium 'One' (v1.1.3c-release, based on Monero 0.18.4.0-release)
///
/// So we take the first run that starts at a digit *immediately preceded by `v`* —
/// which skips the leading words, and skips Salvium's trailing "based on Monero
/// 0.18.4.0" decoy (no `v` in front of it). The run keeps alphanumerics as well as
/// dots, so Salvium's `1.1.3c` survives intact rather than truncating to `1.1.3`
/// and disagreeing with its pinned `core_version`; it stops at the first `[`, `-`
/// or space, dropping the build hash. A trailing dot is trimmed so `v1.2.` can't
/// yield a version ending in one.
///
/// Null when the banner carries no such run. Returns a slice into `out`. Pure, so
/// it's testable without a binary to run.
pub fn parseVersionBanner(out: []const u8) ?[]const u8 {
    // First line only: later lines are none of our business.
    const line = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!std.ascii.isDigit(line[i])) continue;
        if (i == 0 or line[i - 1] != 'v') continue;
        var j = i;
        while (j < line.len and (std.ascii.isAlphanumeric(line[j]) or line[j] == '.')) j += 1;
        while (j > i and line[j - 1] == '.') j -= 1;
        return line[i..j];
    }
    return null;
}

/// Ask an installed binary its own version by running `<install_root>/<binary_file>
/// --version` and parsing the banner.
///
/// This is the fallback for coins whose daemon reports no version over RPC (the
/// Monero forks, Zano): without it a pre-marker install can never stamp a version
/// marker, so update detection stays silent forever — the coin reads as up to date
/// no matter how far behind it is. Probing the binary closes that gap, and unlike
/// the RPC stamp it works with the daemon *stopped*.
///
/// `--version` prints one line and exits 0 without touching the data directory, so
/// it's safe to run alongside a live daemon (no DB lock contention). Caller owns
/// the returned string.
pub fn probeBinaryVersion(
    allocator: std.mem.Allocator,
    install_root: []const u8,
    binary_file: []const u8,
    scratch_name: []const u8,
) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ install_root, binary_file });
    defer allocator.free(path);

    // One short banner line; anything longer is a daemon we don't recognise.
    var buf: [256]u8 = undefined;
    const out = try captureStdout(allocator, &.{ path, "--version" }, install_root, scratch_name, &buf);
    const ver = parseVersionBanner(out) orelse return error.UnrecognizedVersion;
    return allocator.dupe(u8, ver);
}

/// Record the version BoxWallet just installed, so an update check can compare the
/// on-disk version against the binary's pinned `core_version` without the daemon
/// running. Overwrites any prior marker; creates the install root if absent.
pub fn writeVersionMarker(
    allocator: std.mem.Allocator,
    dest_root: []const u8,
    daemon_file: []const u8,
    version: []const u8,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const name = try versionMarkerName(allocator, daemon_file);
    defer allocator.free(name);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = version });
}

/// Read the recorded installed version, or null when there's no marker (a legacy
/// or hand-installed binary the updater can't vouch for). Caller owns the returned
/// slice; trailing whitespace is trimmed. Bounded buffer — versions are short.
pub fn readVersionMarker(
    allocator: std.mem.Allocator,
    dest_root: []const u8,
    daemon_file: []const u8,
) ?[]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const name = versionMarkerName(allocator, daemon_file) catch return null;
    defer allocator.free(name);

    var dir = std.Io.Dir.cwd().openDir(io, dest_root, .{}) catch return null;
    defer dir.close(io);
    var f = dir.openFile(io, name, .{}) catch return null;
    defer f.close(io);

    var buf: [64]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// The load-time-marker filename for a coin: `.<daemon_file>.loadms`, kept beside
/// the version marker in the install root. Caller owns the returned slice.
fn loadMsMarkerName(allocator: std.mem.Allocator, daemon_file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".{s}.loadms", .{daemon_file});
}

/// Record how long the daemon's last block-index load took (milliseconds), so the
/// next load can show a rough time estimate. Overwrites any prior marker; creates
/// the install root if absent. Used by NovaCoin-era coins whose load exposes no
/// in-daemon progress readout (see `Coin.warmup_phase_from_log`).
pub fn writeLoadMsMarker(
    allocator: std.mem.Allocator,
    dest_root: []const u8,
    daemon_file: []const u8,
    ms: u32,
) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const name = try loadMsMarkerName(allocator, daemon_file);
    defer allocator.free(name);

    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{ms});

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dest_root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
}

/// Read the recorded last block-index-load duration in milliseconds, or null when
/// there's no marker or it can't be parsed. Bounded buffer — the value is a short
/// integer.
pub fn readLoadMsMarker(
    allocator: std.mem.Allocator,
    dest_root: []const u8,
    daemon_file: []const u8,
) ?u32 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const name = loadMsMarkerName(allocator, daemon_file) catch return null;
    defer allocator.free(name);

    var dir = std.Io.Dir.cwd().openDir(io, dest_root, .{}) catch return null;
    defer dir.close(io);
    var f = dir.openFile(io, name, .{}) catch return null;
    defer f.close(io);

    var buf: [16]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

test "captureStdout reads a child's stdout, and cleans up even when the child fails" {
    // Drives real child processes, so it leans on `echo`/`sh` being present as
    // binaries — true on Linux/macOS, not on Windows (they're shell builtins there).
    // The code under test is portable; only this harness isn't.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = ".test-capture-stdout";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var buf: [256]u8 = undefined;

    // Happy path: stdout comes back, truncated to the caller's buffer.
    const out = try captureStdout(allocator, &.{ "echo", "Zano v2.2.1.502[76a791c]" }, root, ".probe", &buf);
    try std.testing.expectEqualStrings("Zano v2.2.1.502[76a791c]\n", out);

    // A relative `scratch_root` must work rather than assert. This is the exact
    // shape that panicked: `createFileAbsolute` accepts a relative path but
    // `deleteFileAbsolute` asserts on one, so cleanup blew up after the child ran.
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    dir.access(io, ".probe", .{}) catch |e| {
        // Expected: the scratch file was removed on the success path above.
        try std.testing.expect(e == error.FileNotFound);
    };

    // Non-zero exit is an error, and the scratch file is still cleaned up.
    try std.testing.expectError(
        error.ChildFailed,
        captureStdout(allocator, &.{ "sh", "-c", "echo out; exit 3" }, root, ".probe", &buf),
    );
    try std.testing.expectError(error.FileNotFound, dir.access(io, ".probe", .{}));
}

test "a download failure names the HTTP status rather than collapsing to one word" {
    // The case that motivated this: a stale pinned URL (version and build hash out
    // of lockstep) 404s, and the pane must say so instead of a generic "failed".
    try std.testing.expectEqual(DownloadError.HttpNotFound, statusError(.not_found));
    try std.testing.expectEqual(DownloadError.HttpForbidden, statusError(.forbidden));
    try std.testing.expectEqual(DownloadError.HttpUnauthorized, statusError(.unauthorized));
    try std.testing.expectEqual(DownloadError.HttpTooManyRequests, statusError(.too_many_requests));

    // Every 5xx is upstream's problem, so they share one name.
    try std.testing.expectEqual(DownloadError.HttpServerError, statusError(.internal_server_error));
    try std.testing.expectEqual(DownloadError.HttpServerError, statusError(.bad_gateway));
    try std.testing.expectEqual(DownloadError.HttpServerError, statusError(.service_unavailable));

    // Anything else non-200, including an unresolved redirect (they're followed
    // before the status is inspected, so reaching here means the chain failed).
    try std.testing.expectEqual(DownloadError.HttpUnexpectedStatus, statusError(.bad_request));
    try std.testing.expectEqual(DownloadError.HttpUnexpectedStatus, statusError(.found));
    try std.testing.expectEqual(DownloadError.HttpUnexpectedStatus, statusError(.teapot));

    // The names reach the user verbatim — `app.zig` renders `@errorName(err)` as
    // "status: ✗ {s}", so a rename here silently rewrites the UI copy.
    try std.testing.expectEqualStrings("HttpNotFound", @errorName(statusError(.not_found)));
    try std.testing.expectEqualStrings("HttpServerError", @errorName(statusError(.bad_gateway)));
}

test "load-ms marker round-trips, and reads null when absent or unparseable" {
    const allocator = std.testing.allocator;
    const root = "test-loadms-marker-root";
    const daemon = "spiderbyted";

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};

    // Absent → null.
    try std.testing.expect(readLoadMsMarker(allocator, root, daemon) == null);

    // Written then read back.
    try writeLoadMsMarker(allocator, root, daemon, 398_473);
    try std.testing.expectEqual(@as(?u32, 398_473), readLoadMsMarker(allocator, root, daemon));

    // Overwritten with a newer figure.
    try writeLoadMsMarker(allocator, root, daemon, 401_000);
    try std.testing.expectEqual(@as(?u32, 401_000), readLoadMsMarker(allocator, root, daemon));

    // Garbage marker reads as null (treated as unknown).
    var dir = try std.Io.Dir.cwd().createDirPathOpen(threaded.io(), root, .{});
    defer dir.close(threaded.io());
    try dir.writeFile(threaded.io(), .{ .sub_path = ".spiderbyted.loadms", .data = "not-a-number" });
    try std.testing.expect(readLoadMsMarker(allocator, root, daemon) == null);
}

test "version marker round-trips, and reads null when absent or empty" {
    const allocator = std.testing.allocator;
    const root = "test-version-marker-root";
    const daemon = "epicd";

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};
    defer std.Io.Dir.cwd().deleteTree(threaded.io(), root) catch {};

    // Absent → null.
    try std.testing.expect(readVersionMarker(allocator, root, daemon) == null);

    // Written then read back (a trailing newline is trimmed).
    try writeVersionMarker(allocator, root, daemon, "4.0.3\n");
    const v = readVersionMarker(allocator, root, daemon) orelse return error.TestUnexpectedResult;
    defer allocator.free(v);
    try std.testing.expectEqualStrings("4.0.3", v);

    // Overwrite with a newer version.
    try writeVersionMarker(allocator, root, daemon, "4.1.0");
    const v2 = readVersionMarker(allocator, root, daemon) orelse return error.TestUnexpectedResult;
    defer allocator.free(v2);
    try std.testing.expectEqualStrings("4.1.0", v2);

    // Empty/whitespace marker reads as null (treated as unknown).
    try writeVersionMarker(allocator, root, daemon, "  \n");
    try std.testing.expect(readVersionMarker(allocator, root, daemon) == null);
}

test "parseVersionBanner lifts the bare version out of the real --version banners" {
    // Verbatim output of the installed binaries, so the parse is pinned to what the
    // daemons actually print rather than what we imagine they print.
    try std.testing.expectEqualStrings(
        "2.1.17.469",
        parseVersionBanner("Zano v2.1.17.469[1b1cc03]\n").?,
    );
    try std.testing.expectEqualStrings(
        "0.2.2.0",
        parseVersionBanner("NERVA 'Legacy Reborn' (v0.2.2.0-51ae77bda)\n").?,
    );
    // Salvium is the awkward one: a letter suffix that must survive (its pinned
    // core_version is literally "1.1.3c"), and a trailing Monero version that must
    // not be mistaken for its own — the decoy has no `v` in front of it.
    try std.testing.expectEqualStrings(
        "1.1.3c",
        parseVersionBanner("Salvium 'One' (v1.1.3c-release, based on Monero 0.18.4.0-release)\n").?,
    );
}

test "parseVersionBanner ignores build noise and unparseable banners" {
    // Only the first line is considered.
    try std.testing.expectEqualStrings("1.2.3", parseVersionBanner("Zano v1.2.3\nnoise v9.9.9\n").?);
    // A trailing dot is trimmed rather than kept.
    try std.testing.expectEqualStrings("1.2", parseVersionBanner("Zano v1.2.").?);
    // No digit-after-`v` run at all → unknown, rather than a wrong guess.
    try std.testing.expect(parseVersionBanner("") == null);
    try std.testing.expect(parseVersionBanner("Zano\n") == null);
    // A bare year isn't a version: it isn't introduced by a `v`.
    try std.testing.expect(parseVersionBanner("Zano 2026 build\n") == null);
}

test "parseVersionBanner round-trips every pinned core_version it must match" {
    // The marker this parse writes is compared against the coin's pinned
    // core_version, so a banner carrying exactly the pinned version must parse back
    // to it byte-for-byte — otherwise an up-to-date install reads as mismatched.
    const cases = .{
        .{ "Zano v2.2.1.502[76a791c]", "2.2.1.502" },
        .{ "NERVA 'Legacy Remade' (v0.3.0.0-abc1234)", "0.3.0.0" },
        .{ "Salvium 'One' (v1.1.3c-release, based on Monero 0.18.4.0-release)", "1.1.3c" },
    };
    inline for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], parseVersionBanner(c[0]).?);
    }
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
    try extractArchive(io, &in, .tar_gz, dest, 1, null, null, null, null);

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
    try extractArchive(io, &in, .tar_gz, dest, 0, null, null, null, null);

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
    try extractArchive(io, &in, .tar_gz, dest, 1, null, progress, null, null);

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

test "extractTarBz2 bunzips + untars a real .tar.bz2" {
    // End-to-end over the install plumbing: build a tarball with a versioned
    // wrapper (mirroring the Nerva bundles), bzip2 it via system `tar`, then run
    // it through our bz2 path. Skips if `tar`/`bzip2` aren't installed.
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-bz2-out";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // Source tree: wrapper/{nervad,nerva-wallet-cli}.
    var made = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/src/wrapper", .{});
    made.close(io);
    var sdir = try std.Io.Dir.cwd().openDir(io, root ++ "/src", .{});
    defer sdir.close(io);
    try sdir.writeFile(io, .{ .sub_path = "wrapper/nervad", .data = "DAEMON" });
    try sdir.writeFile(io, .{ .sub_path = "wrapper/nerva-wallet-cli", .data = "CLI" });

    var dest = try std.Io.Dir.cwd().createDirPathOpen(io, root ++ "/dest", .{});
    defer dest.close(io);

    // tar + bzip2 it into the dest dir under a scratch name.
    const scratch_name = "bundle.tar.bz2";
    const child = std.process.run(allocator, io, .{
        .argv = &.{ "tar", "cjf", root ++ "/dest/" ++ scratch_name, "-C", root ++ "/src", "wrapper" },
    }) catch return error.SkipZigTest;
    defer allocator.free(child.stdout);
    defer allocator.free(child.stderr);
    switch (child.term) {
        .exited => |c| if (c != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var scratch = try dest.openFile(io, scratch_name, .{});
    defer scratch.close(io);
    var rbuf: [32 * 1024]u8 = undefined;
    var sr = scratch.reader(io, &rbuf);
    try extractTarBz2(allocator, io, dest, &sr, scratch_name, 0, null);

    try std.testing.expect(fileExists(allocator, root ++ "/dest", "wrapper/nervad"));
    try std.testing.expect(fileExists(allocator, root ++ "/dest", "wrapper/nerva-wallet-cli"));
}

test "fileMatchesSha256 verifies a streamed digest and rejects a mismatch" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-sha256-verify";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "params.bin", .data = "abc" });

    // SHA-256("abc") — the classic test vector.
    const good = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const bad = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expect(fileMatchesSha256(allocator, root, "params.bin", good));
    try std.testing.expect(!fileMatchesSha256(allocator, root, "params.bin", bad));
    // A missing file is a mismatch, never trusted.
    try std.testing.expect(!fileMatchesSha256(allocator, root, "absent.bin", good));
}

test "extract progress is a real percentage when the source size is known" {
    // The determinate path: given an `ArchiveExtent`, extraction reports the
    // position in the underlying file against its size, so a frontend can draw an
    // actual percentage instead of a sweep. Asserts the contract the bar relies on
    // — a fixed non-zero denominator, monotonic numerator, never over 100%, and
    // ending exactly full.
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-extract-pct";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // The fixture has to be on disk, not in memory: the whole point is measuring a
    // seekable file's size and read position.
    const archive = @embedFile("testdata/fixture.tar.gz");
    try dir.writeFile(io, .{ .sub_path = "fixture.tar.gz", .data = archive });

    var f = try dir.openFile(io, "fixture.tar.gz", .{});
    defer f.close(io);
    var rbuf: [4 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const size = try fr.getSize();
    try std.testing.expect(size > 0);

    const Rec = struct {
        total: u64 = 0,
        last: u64 = 0,
        reports: usize = 0,
        monotonic: bool = true,
        within_total: bool = true,
        stable_total: bool = true,
        fn onProgress(ctx: *anyopaque, phase: Phase, current: u64, total: u64) void {
            if (phase != .extract) return;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.reports > 0 and total != self.total) self.stable_total = false;
            if (current < self.last) self.monotonic = false;
            if (total > 0 and current > total) self.within_total = false;
            self.total = total;
            self.last = current;
            self.reports += 1;
        }
    };
    var rec: Rec = .{};
    const progress: Progress = .{ .ctx = &rec, .func = Rec.onProgress };

    try extractArchive(io, &fr.interface, .tar_gz, root ++ "/out", 1, null, progress, .{ .src = &fr, .total = size }, null);

    try std.testing.expect(rec.reports >= 2);
    // A usable denominator, fixed for the whole pass — not the 0 ("unknown") the
    // indeterminate path reports.
    try std.testing.expectEqual(size, rec.total);
    try std.testing.expect(rec.stable_total);
    try std.testing.expect(rec.monotonic);
    try std.testing.expect(rec.within_total);
    // Ends exactly full, so the bar can't finish stuck at 98%.
    try std.testing.expectEqual(size, rec.last);
}

test "extract progress stays indeterminate without an extent" {
    // The fallback contract: no measurable source (in-memory fixture) means total
    // is reported as 0, which the frontend reads as "unknown" and animates instead
    // of drawing a false percentage.
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dest = "test-extract-indeterminate";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    const Rec = struct {
        all_zero_total: bool = true,
        reports: usize = 0,
        fn onProgress(ctx: *anyopaque, phase: Phase, current: u64, total: u64) void {
            _ = current;
            if (phase != .extract) return;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (total != 0) self.all_zero_total = false;
            self.reports += 1;
        }
    };
    var rec: Rec = .{};
    const progress: Progress = .{ .ctx = &rec, .func = Rec.onProgress };

    var in = std.Io.Reader.fixed(@embedFile("testdata/fixture.tar.gz"));
    try extractArchive(io, &in, .tar_gz, dest, 1, null, progress, null, null);

    try std.testing.expect(rec.reports >= 2);
    try std.testing.expect(rec.all_zero_total);
}

test "partialBytes distinguishes a complete download from a resumable partial" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-partial";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // Nothing on disk at all.
    try std.testing.expectEqual(@as(u64, 0), partialBytes(allocator, root, "snap.tar.gz"));

    // A `.part` with no sidecar can't be validated against the body the server
    // would send now, so it isn't resumable and must read as 0 — otherwise the
    // frontend would offer to continue a download that will actually restart.
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ part_suffix, .data = "0123456789" });
    try std.testing.expectEqual(@as(u64, 0), partialBytes(allocator, root, "snap.tar.gz"));

    // With the sidecar it's resumable, and the byte count is the partial's size.
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ part_suffix ++ origin_suffix, .data = "\"abc123\"" });
    try std.testing.expectEqual(@as(u64, 10), partialBytes(allocator, root, "snap.tar.gz"));

    // An empty sidecar is no sidecar.
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ part_suffix ++ origin_suffix, .data = "" });
    try std.testing.expectEqual(@as(u64, 0), partialBytes(allocator, root, "snap.tar.gz"));

    // The finished file counts at full size: the bytes are all there, they just
    // haven't been used yet (a snapshot still has to be unpacked).
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = "0123456789abcdef" });
    try std.testing.expectEqual(@as(u64, 16), partialBytes(allocator, root, "snap.tar.gz"));
}

test "a completed download is never refetched" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-complete";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = "COMPLETE" });

    // The URL is deliberately unroutable: reaching the network at all would be the
    // bug. Quitting between the download finishing and the unpack finishing must
    // not cost a multi-GB refetch, which is the whole reason the finished bytes
    // are renamed out of `.part`.
    try downloadFileResumable(allocator, "http://127.0.0.1:1/nope.tar.gz", root, "snap.tar.gz", null, null);

    var buf: [16]u8 = undefined;
    const f = try dir.openFile(io, "snap.tar.gz", .{});
    defer f.close(io);
    var rbuf: [16]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const n = try fr.interface.readSliceShort(&buf);
    try std.testing.expectEqualStrings("COMPLETE", buf[0..n]);
}

test "discardPartial removes the partial, its sidecar, and any finished file" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-discard";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = "done" });
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ part_suffix, .data = "partial" });
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ part_suffix ++ origin_suffix, .data = "\"etag\"" });

    discardPartial(allocator, root, "snap.tar.gz");

    // Leaving the sidecar behind would make the *next* partial resume against a
    // validator it was never cut from.
    try std.testing.expect(!fileExists(allocator, root, "snap.tar.gz"));
    try std.testing.expect(!fileExists(allocator, root, "snap.tar.gz" ++ part_suffix));
    try std.testing.expect(!fileExists(allocator, root, "snap.tar.gz" ++ part_suffix ++ origin_suffix));

    // Tolerates a clean slate (called on paths where there may be nothing).
    discardPartial(allocator, root, "snap.tar.gz");
}

test "readOrigin rejects a validator too long to be trusted to a bounded buffer" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-validator";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // Exactly the kind of ETag a CDN sends — kept, whitespace trimmed.
    try dir.writeFile(io, .{ .sub_path = "o", .data = "\"6a63e24d-116deb778\"\n" });
    var buf: [max_validator_len]u8 = undefined;
    try std.testing.expectEqualStrings("\"6a63e24d-116deb778\"", readOrigin(io, dir, "o", &buf).?);

    // Overlong: declined rather than truncated, since a truncated validator would
    // never match and could in principle match the wrong thing.
    const long = "x" ** (max_validator_len + 10);
    try dir.writeFile(io, .{ .sub_path = "o", .data = long });
    try std.testing.expect(readOrigin(io, dir, "o", &buf) == null);
}

test "extractLocalTarGz unpacks an on-disk archive without consuming it" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-local-targz";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = @embedFile("testdata/fixture.tar.gz") });

    // strip 0 — a chain snapshot's entries are already at the layout the
    // destination wants, with no versioned wrapper to drop.
    try extractLocalTarGz(allocator, root, "snap.tar.gz", root ++ "/out", 0, null, null);
    try std.testing.expect(fileExists(allocator, root ++ "/out", "nexa-9.9.9/nexad"));

    // The archive is the caller's to keep or discard — a resumable download must
    // be able to retry the unpack without refetching several GB.
    try std.testing.expect(fileExists(allocator, root, "snap.tar.gz"));
}

test "a snapshot writes only the directories it's allowed to" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-snapshot-allow";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    // A snapshot carrying what a compromised publisher would add to one: the
    // chain dirs it's supposed to have, plus a wallet, a conf (which on a first
    // run doesn't exist yet, and whose `walletnotify` the daemon would execute),
    // a stray directory, and a symlink hidden inside an allowed dir.
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = @embedFile("testdata/fixture-snapshot.tar.gz") });

    const allow = [_][]const u8{ "blocks", "chainstate" };
    try extractLocalTarGzAllowing(allocator, root, "snap.tar.gz", root ++ "/out", 0, &allow, null, null);

    // The chain data lands.
    try std.testing.expect(fileExists(allocator, root ++ "/out", "blocks/blk00000.dat"));
    try std.testing.expect(fileExists(allocator, root ++ "/out", "chainstate/000005.ldb"));

    // Nothing else does — not at the top level, and not the symlink smuggled
    // under an allowed name.
    try std.testing.expect(!fileExists(allocator, root ++ "/out", "wallet.dat"));
    try std.testing.expect(!fileExists(allocator, root ++ "/out", "divi.conf"));
    try std.testing.expect(!fileExists(allocator, root ++ "/out", "evildir/x"));
    try std.testing.expect(!fileExists(allocator, root ++ "/out", "blocks/link.dat"));
}

/// Whether this process may create a symlink in `dir` — the privilege, not the
/// platform. Cleans up after itself; a probe that can't be cleaned up still
/// answers, since the caller only writes into a throwaway tree.
fn canSymlink(io: std.Io, dir: std.Io.Dir) bool {
    dir.symLink(io, "target", "bw-symlink-probe", .{}) catch return false;
    dir.deleteFile(io, "bw-symlink-probe") catch {};
    return true;
}

test "an unfiltered extract still writes the whole archive" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-snapshot-unfiltered";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = @embedFile("testdata/fixture-snapshot.tar.gz") });

    // The fixture carries a symlink (`blocks/link.dat`) — the filtered test above
    // exists to prove it's dropped, so the *unfiltered* extract necessarily tries
    // to create it. Windows only permits that for an administrator or with
    // Developer Mode on, and `std.tar.extract` fails the whole extract when it
    // can't, so a stock Windows box can't run this at all. Probed rather than
    // assumed off Windows: an elevated shell or Developer Mode runs it for real.
    if (!canSymlink(io, dir)) return error.SkipZigTest;

    // The no-allow-list path is what every coin's install uses, where the whole
    // archive is the point — the filter existing must not have narrowed it.
    try extractLocalTarGz(allocator, root, "snap.tar.gz", root ++ "/out", 0, null, null);
    try std.testing.expect(fileExists(allocator, root ++ "/out", "blocks/blk00000.dat"));
    try std.testing.expect(fileExists(allocator, root ++ "/out", "wallet.dat"));
    try std.testing.expect(fileExists(allocator, root ++ "/out", "evildir/x"));
}

test "an allowed path can't lead outside the destination" {
    const allow = [_][]const u8{ "blocks", "chainstate" };

    // The straightforward cases.
    try std.testing.expectEqualStrings("blocks/blk1.dat", permittedPath("blocks/blk1.dat", 0, &allow).?);
    try std.testing.expectEqualStrings("chainstate", permittedPath("chainstate/", 0, &allow).?);
    try std.testing.expect(permittedPath("wallet.dat", 0, &allow) == null);
    try std.testing.expect(permittedPath("", 0, &allow) == null);

    // A traversal that starts inside an allowed dir: the allow-list alone would
    // pass this, which is why the `..` check isn't folded into it.
    try std.testing.expect(permittedPath("blocks/../../wallet.dat", 0, &allow) == null);
    try std.testing.expect(permittedPath("../wallet.dat", 0, &allow) == null);

    // Absolute roots and backslash separators (a Windows-built archive read on a
    // POSIX host, where `/` alone wouldn't split the components).
    try std.testing.expect(permittedPath("/blocks/blk1.dat", 0, &allow) == null);
    try std.testing.expect(permittedPath("blocks\\..\\..\\wallet.dat", 0, &allow) == null);

    // `strip` applies before the check, so the allow-list names what the
    // destination sees, not what the archive happens to wrap it in.
    try std.testing.expectEqualStrings("blocks/blk1.dat", permittedPath("snapshot-2026/blocks/blk1.dat", 1, &allow).?);
    try std.testing.expect(permittedPath("snapshot-2026/wallet.dat", 1, &allow) == null);
}

test "a paused download keeps a resumable partial rather than losing it" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-pause";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    // A cancel that fires immediately: the very first chunk boundary stops it.
    const Stopper = struct {
        fn stop(_: *anyopaque) bool {
            return true;
        }
    };
    var dummy: u8 = 0;
    const cancel: Cancel = .{ .ctx = &dummy, .func = Stopper.stop };

    // Unroutable on purpose — this asserts the *shape* of a pause, not a transfer:
    // whatever happens, a pause must never leave the finished name in place, since
    // that name is precisely what means "complete, don't download this again".
    if (downloadFileResumable(allocator, "http://127.0.0.1:1/x.tar.gz", root, "snap.tar.gz", null, cancel)) |_| {
        return error.TestExpectedStop;
    } else |_| {}
    try std.testing.expect(!fileExists(allocator, root, "snap.tar.gz"));
}

test "stopRequested reads the cancel hook, and is false when none is given" {
    // No signal supplied — the ordinary install path, which never pauses.
    try std.testing.expect(!stopRequested(null));

    const Flag = struct {
        stop: bool,
        fn read(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.stop;
        }
    };
    var f: Flag = .{ .stop = false };
    const c: Cancel = .{ .ctx = &f, .func = Flag.read };
    try std.testing.expect(!stopRequested(c));
    f.stop = true;
    try std.testing.expect(stopRequested(c));
}

test "a partial from the old layout is rescued rather than mistaken for a finished file" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-resume-legacy";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);

    // The old layout: bytes under the final name, sidecar beside it. Left behind
    // by the first shipped version of this code.
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz", .data = "0123456789" });
    try dir.writeFile(io, .{ .sub_path = "snap.tar.gz" ++ origin_suffix, .data = "\"etag\"" });

    var part_buf: [std.fs.max_name_bytes]u8 = undefined;
    var origin_buf: [std.fs.max_name_bytes]u8 = undefined;
    const names = try partNames("snap.tar.gz", &part_buf, &origin_buf);
    migrateLegacyPartial(io, dir, "snap.tar.gz", names.part, names.origin);

    // Rescued into the current layout, and still resumable — the bytes are kept.
    try std.testing.expect(!fileExists(allocator, root, "snap.tar.gz"));
    try std.testing.expect(fileExists(allocator, root, "snap.tar.gz" ++ part_suffix));
    try std.testing.expectEqual(@as(u64, 10), partialBytes(allocator, root, "snap.tar.gz"));

    // A genuinely finished file (no old sidecar) is left exactly as it is.
    try dir.writeFile(io, .{ .sub_path = "done.tar.gz", .data = "COMPLETE" });
    migrateLegacyPartial(io, dir, "done.tar.gz", "done.tar.gz.part", "done.tar.gz.part.origin");
    try std.testing.expect(fileExists(allocator, root, "done.tar.gz"));
    try std.testing.expect(!fileExists(allocator, root, "done.tar.gz.part"));
}
