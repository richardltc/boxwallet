//! Daemon-process helpers shared by both front-ends (TUI and GUI): liveness by
//! binary name, and the reason a start failed, read from the daemon's own log.
//!
//! After a bitcoin-derived launcher daemonizes (`-daemon`), the only cheap way
//! to tell "the daemon stuck around" from "it forked and died" is to look for
//! the process itself: its RPC port opens minutes later (loading the block
//! index, then the wallet), so an RPC probe would read a perfectly healthy
//! start as a failure. Name matching needs no RPC and works from the fork on.
//!
//! And when it *did* die, its daemonized stderr went nowhere we can read, so the
//! reason has to come out of `<datadir>/debug.log` (or the epee family's own
//! log) — bounded tail, most error-like line.

const std = @import("std");
const builtin = @import("builtin");

/// True while a process named `name` exists. `/proc` on Linux, `pgrep`
/// elsewhere; where neither can run (Windows, or a POSIX box with no `/proc`
/// and no `pgrep`) it conservatively reports alive, so a live daemon is never
/// declared dead by mistake.
///
/// A **zombie doesn't count** — see `isZombie`.
pub fn alive(io: std.Io, name: []const u8) bool {
    return aliveMatching(io, name, null);
}

/// `alive`, for a daemon that doesn't run under its own name.
///
/// An interpreter-launched daemon is not the file we launched: Ergo is
/// `java -jar ergo-<ver>.jar`, so its `comm` is `java` and matching on the
/// daemon file finds nothing. `cmdline_needle` switches the match to the
/// process's *command line*, which still carries the jar. It must be specific
/// enough to identify this coin alone — `java` would match any JVM on the
/// machine, `ergo-<ver>.jar` matches ours. Null matches by name, as `alive`.
pub fn aliveMatching(io: std.Io, name: []const u8, cmdline_needle: ?[]const u8) bool {
    if (builtin.os.tag == .windows) return true;
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch
        return aliveByPgrep(io, name, cmdline_needle);
    defer proc.close(io);

    if (cmdline_needle) |needle| return aliveByCmdline(io, proc, needle);

    // comm is truncated to TASK_COMM_LEN-1 (15) bytes.
    const want = if (name.len > 15) name[0..15] else name;

    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        var path_buf: [32]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buf, "{s}/comm", .{entry.name}) catch continue;
        var f = proc.openFile(io, comm_path, .{}) catch continue;
        defer f.close(io);
        var cbuf: [64]u8 = undefined;
        const n = f.readPositionalAll(io, &cbuf, 0) catch continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, cbuf[0..n], " \t\r\n"), want)) continue;
        if (isZombie(io, proc, entry.name)) continue;
        return true;
    }
    return false;
}

/// True if `/proc/<pid>` is a zombie — the process has exited and only its exit
/// status is left, waiting for its parent to reap it.
///
/// A zombie keeps its `comm`, so the name match above sees a daemon that is long
/// dead. That matters because we are frequently that unreaped parent: a
/// foreground daemon (Nerva, Salvium, Zano, Ergo, Epic) is spawned detached and
/// deliberately not waited on, so one that dies on its own — a crash, an OOM
/// kill, an operator `kill` — sits as our zombie child until something reaps it.
/// Counting that as alive told the GUI the daemon was still coming up, which
/// greys out Start (it's "starting") *and* Stop (it isn't running) — with no way
/// out short of restarting the app.
///
/// Best-effort: anything unreadable reads as not-a-zombie, keeping the
/// conservative "never declare a live daemon dead" bias.
fn isZombie(io: std.Io, proc: std.Io.Dir, pid_name: []const u8) bool {
    var path_buf: [32]u8 = undefined;
    const stat_path = std.fmt.bufPrint(&path_buf, "{s}/stat", .{pid_name}) catch return false;
    var f = proc.openFile(io, stat_path, .{}) catch return false;
    defer f.close(io);
    // "pid (comm) S ..." — the state is the third field. comm is at most 15
    // bytes, so the state always lands well inside this buffer.
    var buf: [128]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    return stateFromStat(buf[0..n]) == 'Z';
}

/// The state character out of a `/proc/<pid>/stat` line, or 0 if it isn't there.
///
/// Field 2 is the comm in parentheses and may itself contain spaces *and*
/// parentheses (`(my (odd) name)`), so splitting on whitespace or the first `)`
/// picks the wrong field. The state is the first non-space byte after the
/// **last** `)`.
fn stateFromStat(line: []const u8) u8 {
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return 0;
    var i = close + 1;
    while (i < line.len and line[i] == ' ') i += 1;
    return if (i < line.len) line[i] else 0;
}

/// True while some process's command line contains `needle`. The `/proc` half of
/// `aliveMatching`'s interpreter case: `comm` is deliberately not consulted (it's
/// the interpreter's name, not the coin's), so the needle carries the whole
/// burden of identifying the process — see `aliveMatching`.
///
/// cmdline is NUL-separated argv; the needle is matched against those bytes, so
/// it must not span an argument boundary. A jar path in `-jar <path>` is one
/// argument, so it matches whether or not it's given with a directory prefix.
///
/// No `isZombie` check is needed here: the kernel empties `cmdline` when a
/// process dies, so a zombie matches no needle and drops out on its own.
fn aliveByCmdline(io: std.Io, proc: std.Io.Dir, needle: []const u8) bool {
    var it = proc.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        var path_buf: [32]u8 = undefined;
        const cl_path = std.fmt.bufPrint(&path_buf, "{s}/cmdline", .{entry.name}) catch continue;
        var f = proc.openFile(io, cl_path, .{}) catch continue;
        defer f.close(io);
        // Bounded, like every other read here: a JVM launch line is long (module
        // flags, classpath), but the jar sits early in it, and a truncated read
        // only ever costs a match we'd have made — never a false one.
        var lbuf: [4096]u8 = undefined;
        const n = f.readPositionalAll(io, &lbuf, 0) catch continue;
        if (std.mem.indexOf(u8, lbuf[0..n], needle) != null) return true;
    }
    return false;
}

/// `pgrep` fallback for `aliveMatching` on POSIX systems without `/proc`
/// (macOS): exit 0 = at least one live match, 1 = none. Anything else (pgrep
/// missing or erroring) conservatively reads as alive, per the caller's
/// contract. `-x` matches the process name exactly; `-f` matches the full
/// command line, which is the interpreter case.
///
/// Unlike the `/proc` path this can't filter zombies (pgrep lists them), so a
/// daemon that dies unreaped on macOS still reads as alive until its parent
/// collects it — which the GUI's poll now does every tick (`bw_reap_daemon`).
fn aliveByPgrep(io: std.Io, name: []const u8, cmdline_needle: ?[]const u8) bool {
    const flag = if (cmdline_needle == null) "-x" else "-f";
    const pattern = cmdline_needle orelse name;
    var child = std.process.spawn(io, .{
        .argv = &.{ "pgrep", flag, pattern },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return true;
    return switch (child.wait(io) catch return true) {
        .exited => |code| code != 1,
        else => true,
    };
}

/// Poll `aliveMatching` over a short window, returning false the moment the
/// process is seen gone. A daemon that dies during init is gone almost
/// immediately, while a healthy one is present from the fork on — so this
/// separates the two without waiting on RPC (which a bitcoin-derived daemon
/// won't answer for minutes while it loads the block index).
pub fn stayedAlive(io: std.Io, name: []const u8, cmdline_needle: ?[]const u8) bool {
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};
        if (!aliveMatching(io, name, cmdline_needle)) return false;
    }
    return true;
}

/// The reason a daemon start failed, taken from the tail of its own log
/// (`<data_dir>/<log_name>`) — a daemonized child logs there rather than to the
/// stderr the launcher captured, and the epee family (Nerva/Salvium/Zano) writes
/// fatal init errors to its log, not stderr.
///
/// Reads only a tail into the caller's `buf` (bounded — the log grows without
/// limit) and returns the most error-like line as a slice *into `buf`*, so it
/// stays valid only as long as the caller's buffer. Best-effort: an empty slice
/// on any IO hiccup, so callers fall back to their generic message.
pub fn daemonLogReason(io: std.Io, data_dir: []const u8, log_name: []const u8, buf: []u8) []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return "";
    defer dir.close(io);
    var file = dir.openFile(io, log_name, .{}) catch return "";
    defer file.close(io);
    const stat = file.stat(io) catch return "";
    // A modest tail keeps the read flat and biases toward the latest start
    // attempt (the death burst is the last handful of lines), so an older
    // session's errors further back don't get picked.
    const off = if (stat.size > buf.len) stat.size - buf.len else 0;
    const n = file.readPositionalAll(io, buf, off) catch return "";
    return pickLogError(buf[0..n]);
}

/// Choose the most informative line from a debug.log tail. A daemon's failure
/// burst mixes the root cause with benign warnings and shutdown bookkeeping, so
/// two tiers are used: a "root cause" line (a datadir/block-index/permission
/// problem) wins over a generic error/abort line, which in turn wins over the
/// last non-empty line. Within a tier the *last* match wins, since the fatal
/// line lands late, just before the shutdown. Leading log timestamps are
/// stripped. Returns a slice into `tail` (empty only if `tail` has no content).
pub fn pickLogError(tail: []const u8) []const u8 {
    // Deliberately omits bare "lock" ("block" contains it) — the datadir-lock
    // message carries "cannot" anyway. "exception" and "failed to" carry the
    // epee family's fatal shapes ("Exception in main!", "Failed to initialize
    // p2p server") over its shutdown bookkeeping.
    const root_cause = [_][]const u8{
        "incorrect", "corrupt",   "no genesis", "wrong datadir",
        "cannot",    "unable",    "denied",     "invalid",
        "not found", "exception", "failed to",
    };
    const generic = [_][]const u8{ "error", "abort", "fail", "exiting" };

    var root_hit: []const u8 = "";
    var generic_hit: []const u8 = "";
    var fallback: []const u8 = "";
    var it = std.mem.splitScalar(u8, tail, '\n');
    while (it.next()) |raw| {
        const line = stripLogTimestamp(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        fallback = line;
        if (matchesAny(line, &root_cause)) {
            root_hit = line;
        } else if (matchesAny(line, &generic)) {
            generic_hit = line;
        }
    }
    return if (root_hit.len != 0) root_hit else if (generic_hit.len != 0) generic_hit else fallback;
}

/// Strip a bitcoin-style "YYYY-MM-DD HH:MM:SS " log prefix from `line` so the
/// surfaced reason is just the message. Fractional seconds (the epee family
/// logs "…19:07:04.165") are consumed too, so the reason doesn't lead with an
/// orphaned ".165". Returns `line` unchanged if the prefix isn't there.
pub fn stripLogTimestamp(line: []const u8) []const u8 {
    if (line.len > 20 and line[4] == '-' and line[7] == '-' and
        line[10] == ' ' and line[13] == ':' and line[16] == ':')
    {
        var rest = line[19..];
        if (rest.len > 0 and rest[0] == '.') {
            var i: usize = 1;
            while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
            rest = rest[i..];
        }
        return std.mem.trim(u8, rest, " \t");
    }
    return line;
}

/// True if `line` contains any of `needles` (case-insensitive, ASCII).
pub fn matchesAny(line: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (n.len > line.len) continue;
        var i: usize = 0;
        while (i + n.len <= line.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(line[i .. i + n.len], n)) return true;
        }
    }
    return false;
}

/// SIGTERM `pid`, reaping with `WNOHANG` over a `grace_ms` window so a clean
/// shutdown returns the moment it finishes; SIGKILL + a blocking reap if it
/// overstays. POSIX only — the caller guards Windows (whose `Child.kill` is an
/// immediate TerminateProcess and needs none of this).
///
/// The grace matters because a Monero-family wallet-rpc saves the wallet on
/// SIGTERM, which takes a moment; std's `Child.kill` would block for all of it.
///
/// Reaping (rather than a `kill(pid, 0)` liveness probe) is what makes the
/// early-out actually work: a child that has exited but not yet been waited on
/// is a zombie, and `kill(zombie, 0)` still reports it as alive — so a probe loop
/// never sees it go and waits the whole grace every time.
pub fn terminateAndReap(io: std.Io, pid: std.posix.pid_t, grace_ms: u32) void {
    const posix = std.posix;
    posix.kill(pid, posix.SIG.TERM) catch return; // already gone / not permitted
    var waited: u32 = 0;
    const step: u32 = 50;
    while (waited < grace_ms) : (waited += step) {
        if (reapNoHang(pid)) return;
        io.sleep(.fromMilliseconds(step), .awake) catch {};
    }
    posix.kill(pid, posix.SIG.KILL) catch {};
    // Blocking reap so the killed child doesn't linger as a zombie.
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (posix.errno(posix.system.wait4(pid, &status, 0, null)) == .INTR) {}
}

/// Non-blocking reap: true once `pid` has terminated (and has been reaped, so it
/// won't linger as a zombie), or if there's nothing left to wait on.
pub fn reapNoHang(pid: std.posix.pid_t) bool {
    const posix = std.posix;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = posix.system.wait4(pid, &status, posix.W.NOHANG, null);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc != 0, // 0 = still running; nonzero (the pid) = exited & reaped
        else => true, // ECHILD/EINVAL → nothing to wait on; treat as gone
    };
}

test "a process that cannot exist is not reported alive" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.testing.expect(!alive(io, "bw-no-such-daemon"));
}

test "the running test binary is found by its own comm name" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Our own `/proc/self/comm` is by definition a live process name, so it
    // exercises the match path (including the 15-byte truncation) end to end.
    var f = try std.Io.Dir.openFileAbsolute(io, "/proc/self/comm", .{});
    defer f.close(io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expect(alive(io, std.mem.trim(u8, buf[0..n], " \t\r\n")));
}

test "the state character survives a comm containing spaces and parentheses" {
    try std.testing.expectEqual(@as(u8, 'Z'), stateFromStat("12008 (nervad) Z 11714 12008"));
    try std.testing.expectEqual(@as(u8, 'S'), stateFromStat("42 (my (odd) name) S 1 42"));
    try std.testing.expectEqual(@as(u8, 0), stateFromStat("truncated"));
}

test "an unreaped dead child is not reported alive" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Deliberately never waited on, so it becomes our zombie — the shape a
    // foreground daemon that died on its own leaves behind. Its `comm` still
    // reads "true", so only the state check keeps it out of `alive`.
    var child = try std.process.spawn(io, .{
        .argv = &.{"/bin/true"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer _ = child.wait(io) catch {};

    // Wait for the exit itself (a fresh child is briefly, legitimately alive),
    // then assert — a zombie that read as alive would never clear this loop.
    var i: u8 = 0;
    while (i < 40 and alive(io, "true")) : (i += 1) {
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    try std.testing.expect(!alive(io, "true"));
}

test "reapNoHang: a pid that was never our child reads as gone" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // pid 1 is never ours, so wait4 answers ECHILD → "nothing to wait on", which
    // must read as gone rather than stalling `terminateAndReap`'s whole grace.
    try std.testing.expect(reapNoHang(1));
}
