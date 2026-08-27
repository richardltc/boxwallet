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

/// True while a process named `name` exists. `/proc` on Linux, the Toolhelp
/// process snapshot on Windows, `pgrep` elsewhere; where none of those can
/// answer it conservatively reports alive, so a live daemon is never declared
/// dead by mistake.
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
    if (builtin.os.tag == .windows) {
        // The snapshot carries only the image name, so the interpreter case has
        // to go one step further and read each process's command line out of its
        // own address space. Ergo is the only coin that takes that path.
        if (cmdline_needle) |needle| return aliveByCmdlineWindows(needle);
        return aliveByToolhelp(name);
    }
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

// --- Windows process enumeration ------------------------------------------
//
// There is no portable stdlib equivalent, and std declares no Toolhelp bindings,
// so the three kernel32 entry points are declared here. Toolhelp is used rather
// than `NtQuerySystemInformation` because it is documented, stable, and hands
// back the image name directly — which is the whole question being asked.

const TH32CS_SNAPPROCESS: u32 = 0x00000002;

/// `PROCESSENTRY32W`. The field order and `dwSize` are load-bearing: the API
/// rejects a snapshot entry whose `dwSize` isn't `@sizeOf` this struct.
const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    /// The base image name (`salviumd.exe`), not the full path. MAX_PATH wide
    /// chars, NUL-terminated.
    szExeFile: [260]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(
    dwFlags: u32,
    th32ProcessID: u32,
) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn Process32FirstW(
    hSnapshot: std.os.windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn Process32NextW(
    hSnapshot: std.os.windows.HANDLE,
    lppe: *PROCESSENTRY32W,
) callconv(.winapi) std.os.windows.BOOL;

/// Enough to ask a process where its PEB is and to read a few words out of it —
/// and no more. `QUERY_LIMITED_INFORMATION` (not `QUERY_INFORMATION`) is the
/// modern, least-privileged form and is what a same-user process is granted.
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const PROCESS_VM_READ: u32 = 0x0010;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: u32,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: u32,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn ReadProcessMemory(
    hProcess: std.os.windows.HANDLE,
    lpBaseAddress: ?*const anyopaque,
    lpBuffer: *anyopaque,
    nSize: usize,
    lpNumberOfBytesRead: ?*usize,
) callconv(.winapi) std.os.windows.BOOL;

/// `PROCESS_BASIC_INFORMATION`, of which only `PebBaseAddress` is wanted — the
/// rest is here so the struct is the size `NtQueryInformationProcess` expects.
const PROCESS_BASIC_INFORMATION = extern struct {
    ExitStatus: std.os.windows.NTSTATUS,
    PebBaseAddress: ?*anyopaque,
    AffinityMask: usize,
    BasePriority: std.os.windows.LONG,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
};

/// True while some process's image name equals `name` (case-insensitively — the
/// Windows filesystem and process table both are).
///
/// This replaces an unconditional `return true`, which quietly made every
/// Windows caller believe a daemon was up: `bw_daemon_alive` always answered yes,
/// so the GUI's "starting" pulse ran forever, for every coin, from launch, with
/// nothing running at all.
///
/// Keeps the conservative bias on any failure (no snapshot, no first entry): a
/// live daemon must never be declared dead, and the RPC probe is the real
/// authority anyway — this only decides whether a *non-answering* daemon reads as
/// "coming up" or "not there".
fn aliveByToolhelp(name: []const u8) bool {
    const windows = std.os.windows;
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return true;
    defer windows.CloseHandle(snapshot);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (!Process32FirstW(snapshot, &entry).toBool()) return true;
    while (true) {
        if (imageNameEquals(&entry.szExeFile, name)) return true;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        if (!Process32NextW(snapshot, &entry).toBool()) return false;
    }
}

/// Case-insensitive ASCII compare of a NUL-terminated WTF-16 image name against
/// `want`. Daemon filenames are ASCII by construction (each coin declares its
/// own), so any wide character above 0x7F is a mismatch rather than something to
/// decode — which also keeps this allocation-free.
fn imageNameEquals(image: []const u16, want: []const u8) bool {
    var i: usize = 0;
    while (i < image.len and image[i] != 0) : (i += 1) {
        if (i >= want.len) return false; // image is longer
        const wide = image[i];
        if (wide > 0x7F) return false;
        if (!std.ascii.eqlIgnoreCase(&.{@intCast(wide)}, &.{want[i]})) return false;
    }
    return i == want.len; // both ended together
}

/// True while some process's command line contains `needle` — the Windows half
/// of `aliveMatching`'s interpreter case, and the counterpart to the `/proc`
/// walk in `aliveByCmdline`.
///
/// This replaced an unconditional `return true`, which made Ergo — the only coin
/// matched this way — read as permanently alive on Windows. Merely *selecting*
/// Ergo, with nothing running, set the GUI's smiley pulsing "daemon starting"
/// (`coming_up` in main.cpp falls back to this liveness check for a coin with no
/// `-28` warm-up protocol to report a stage), and it never stopped. It also made
/// `stayedAlive` answer yes to a start that had already died.
///
/// A Windows command line isn't in the Toolhelp snapshot — that carries only the
/// image name, which for Ergo is the JVM's and says nothing about which jar it is
/// running. It lives in the process's own address space, in the
/// `RTL_USER_PROCESS_PARAMETERS` block the PEB points at, so each process is
/// opened and walked: PEB address → parameters pointer → the `UNICODE_STRING`
/// that is the command line → a bounded read of its text.
///
/// Keeps the file's conservative bias where it can't tell (no snapshot, no first
/// entry): a live daemon must never be declared dead. A process that simply
/// can't be opened is skipped rather than counted as a match — we launch the
/// daemon ourselves, as this user, so ours is always readable, and every process
/// that isn't is one we'd have had no business matching.
fn aliveByCmdlineWindows(needle: []const u8) bool {
    const windows = std.os.windows;
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return true;
    defer windows.CloseHandle(snapshot);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (!Process32FirstW(snapshot, &entry).toBool()) return true;
    while (true) {
        // Skip pid 0 (the idle process): it has no user-mode address space, so
        // the walk below can only fail on it.
        if (entry.th32ProcessID != 0 and cmdlineContains(entry.th32ProcessID, needle)) return true;
        entry.dwSize = @sizeOf(PROCESSENTRY32W);
        if (!Process32NextW(snapshot, &entry).toBool()) return false;
    }
}

/// True if process `pid`'s command line contains `needle` (case-insensitive
/// ASCII). False for anything that can't be read — a process we may not open, a
/// 32-bit process seen from a 64-bit build, one that exited mid-walk.
fn cmdlineContains(pid: u32, needle: []const u8) bool {
    const windows = std.os.windows;
    const handle = OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ,
        .FALSE,
        pid,
    ) orelse return false;
    defer windows.CloseHandle(handle);

    var pbi: PROCESS_BASIC_INFORMATION = undefined;
    if (windows.ntdll.NtQueryInformationProcess(
        handle,
        .BasicInformation,
        &pbi,
        @sizeOf(PROCESS_BASIC_INFORMATION),
        null,
    ) != .SUCCESS) return false;
    const peb = @intFromPtr(pbi.PebBaseAddress orelse return false);

    // Two pointer hops, each a single word read across the process boundary.
    // `@offsetOf` rather than the documented constants (0x20 / 0x70 on x86_64)
    // so a stdlib layout change or a 32-bit build can't silently read garbage.
    var params: usize = 0;
    if (!readAcross(handle, peb + @offsetOf(windows.PEB, "ProcessParameters"), std.mem.asBytes(&params)))
        return false;

    var cmdline: windows.UNICODE_STRING = undefined;
    if (!readAcross(
        handle,
        params + @offsetOf(windows.RTL_USER_PROCESS_PARAMETERS, "CommandLine"),
        std.mem.asBytes(&cmdline),
    )) return false;
    const text = @intFromPtr(cmdline.Buffer orelse return false);

    // Bounded, as the `/proc` side is: a JVM launch line is long (heap flags, a
    // full path to the jar), but the jar sits early in it, and a truncated read
    // only ever costs a match we'd have made — never a false one. `Length` is a
    // byte count, and the string is not NUL-terminated.
    var buf: [2048]u16 = undefined;
    const chars = @min(cmdline.Length / @sizeOf(u16), buf.len);
    if (chars == 0) return false;
    if (!readAcross(handle, text, std.mem.sliceAsBytes(buf[0..chars]))) return false;
    return wideContains(buf[0..chars], needle);
}

/// Fill `out` from `addr` in another process. False unless every byte arrived —
/// a short read means the layout wasn't what we assumed, which is not something
/// to then go matching against.
fn readAcross(handle: std.os.windows.HANDLE, addr: usize, out: []u8) bool {
    if (addr == 0) return false;
    var read: usize = 0;
    if (!ReadProcessMemory(handle, @ptrFromInt(addr), out.ptr, out.len, &read).toBool()) return false;
    return read == out.len;
}

/// Case-insensitive ASCII substring search of a WTF-16 haystack. The needle is a
/// coin's daemon/jar filename, ASCII by construction, so any wide character
/// above 0x7F is simply a non-match — no decoding, no allocation.
fn wideContains(haystack: []const u16, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, haystack[i .. i + needle.len]) |want, wide| {
            if (wide > 0x7F) continue :outer;
            if (!std.ascii.eqlIgnoreCase(&.{@as(u8, @intCast(wide))}, &.{want})) continue :outer;
        }
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
        const line = stripLogColumns(stripLogTimestamp(std.mem.trim(u8, raw, " \t\r")));
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

/// Strip the epee family's tab-separated log columns, leaving just the message.
///
/// After the timestamp, Nerva/Salvium/Zano write
/// `<thread>\t<LEVEL>\t<category>\t<file>:<line>\t<message>` — so the reason
/// surfaced to the user read
/// "4224\tERROR\tdaemon\tsrc/daemon/main.cpp:432\tException in main! Failed to
/// initialize p2p server.", which buries the one part that means anything.
///
/// Everything after the **last** tab is the message; a bitcoin-derived
/// `debug.log` line has no tabs at all and comes back untouched, which is why
/// this is safe to run over every line rather than per coin family.
pub fn stripLogColumns(line: []const u8) []const u8 {
    const last_tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return line;
    return std.mem.trim(u8, line[last_tab + 1 ..], " \t");
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

/// Non-blocking probe of a just-spawned child: null while it's still running,
/// its exit `Term` once it has terminated.
///
/// This is what separates "the daemon started" from "it flashed and died" for a
/// foreground coin, which is spawned detached and can't be waited on — so it is
/// also the only thing that turns a failed start into a *reported* one. Both
/// front-ends need it: without it the GUI's Start reported success for a daemon
/// that never came up, and said nothing at all.
///
/// POSIX reaps via `wait4(NOHANG)`, so after a non-null return the child must not
/// be `wait`ed on or `kill`ed again (std treats a double reap as a bug). Windows
/// tests the process handle with a zero timeout and, once signaled, lets
/// `child.wait` (immediate by then) collect the code and release the handles.
///
/// A probe hiccup reads as "still running", keeping the same conservative bias as
/// `alive`: never declare a live daemon dead by mistake.
pub fn probeChild(io: std.Io, child: *std.process.Child) ?std.process.Child.Term {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const handle = child.id orelse return .{ .unknown = 0 };
        var timeout: windows.LARGE_INTEGER = 0; // zero = test state, don't wait
        switch (windows.ntdll.NtWaitForSingleObject(handle, .FALSE, &timeout)) {
            windows.NTSTATUS.WAIT_0 => {},
            else => return null, // TIMEOUT (still running), or can't tell
        }
        return child.wait(io) catch .{ .unknown = 0 };
    }
    const posix = std.posix;
    const pid = child.id orelse return .{ .unknown = 0 };
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = posix.system.wait4(pid, &status, posix.W.NOHANG, null);
    return switch (posix.errno(rc)) {
        .SUCCESS => if (rc == 0) null else blk: {
            child.id = null; // reaped right here; nothing left for wait/kill
            break :blk std.Io.Threaded.statusToTerm(@bitCast(status));
        },
        .INTR => null, // retried on the next probe round
        else => .{ .unknown = 0 }, // ECHILD — already gone
    };
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

test "an image name matches case-insensitively, and only in full" {
    // The Windows liveness match. `imageNameEquals` is pure, so the whole table
    // is checkable from any host — the enumeration around it is not.
    const wide = struct {
        fn of(comptime s: []const u8) [s.len + 1]u16 {
            var out: [s.len + 1]u16 = undefined;
            for (s, 0..) |c, i| out[i] = c;
            out[s.len] = 0;
            return out;
        }
    };

    const salviumd = wide.of("salviumd.exe");
    try std.testing.expect(imageNameEquals(&salviumd, "salviumd.exe"));
    // Windows process names are case-insensitive; the snapshot's casing is not
    // ours to predict.
    const shouty = wide.of("SALVIUMD.EXE");
    try std.testing.expect(imageNameEquals(&shouty, "salviumd.exe"));
    // A prefix must not match, or `divid.exe` would answer for `divid.exe.bak`
    // and every coin whose name starts the same way.
    const longer = wide.of("salviumd.exe.bak");
    try std.testing.expect(!imageNameEquals(&longer, "salviumd.exe"));
    const shorter = wide.of("salvium.exe");
    try std.testing.expect(!imageNameEquals(&shorter, "salviumd.exe"));
    try std.testing.expect(!imageNameEquals(&salviumd, "monerod.exe"));
}

test "a process that cannot exist is not reported alive on Windows either" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The regression this guards: `aliveMatching` used to answer true here
    // unconditionally, which is what left the GUI pulsing "daemon starting" with
    // no daemon anywhere.
    try std.testing.expect(!alive(io, "bw-no-such-daemon.exe"));

    // The positive half needs a process whose image name is known to be running,
    // which nothing here can guarantee offline — so it is covered by the spawned
    // child below rather than by naming some system process and hoping.
    var child = std.process.spawn(io, .{
        // `cmd /c pause` sits waiting on a keypress it will never get, because
        // stdin is closed — long enough to be seen, and it exits on `kill`.
        .argv = &.{ "cmd.exe", "/c", "pause" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        child.kill(io);
    }
    try std.testing.expect(alive(io, "cmd.exe"));
}

test "wideContains matches a jar name case-insensitively, and only whole" {
    const wide = struct {
        fn of(comptime s: []const u8) [s.len]u16 {
            var out: [s.len]u16 = undefined;
            for (s, 0..) |c, i| out[i] = c;
            return out;
        }
    };

    // The shape of the real thing: a JVM launch line with the jar mid-way.
    const line = wide.of("C:\\Users\\me\\java.exe -Xmx2g -jar C:\\bw\\ergo-5.0.32.jar --mainnet");
    try std.testing.expect(wideContains(&line, "ergo-5.0.32.jar"));
    // A different version is a different node — the needle carries the whole
    // burden of saying "this JVM is ours", so a near miss must not match.
    try std.testing.expect(!wideContains(&line, "ergo-5.0.31.jar"));
    // Windows paths are case-insensitive and the casing isn't ours to predict.
    const shouty = wide.of("JAVA.EXE -JAR ERGO-5.0.32.JAR");
    try std.testing.expect(wideContains(&shouty, "ergo-5.0.32.jar"));
    // A needle longer than the line can't match, and mustn't read past it.
    const short = wide.of("java");
    try std.testing.expect(!wideContains(&short, "ergo-5.0.32.jar"));
    // Non-ASCII in the path is a mismatch at that position, not a decode.
    var accented = wide.of("C:\\x\\ergo-5.0.32.jar");
    accented[3] = 0x00e9; // é
    try std.testing.expect(wideContains(&accented, "ergo-5.0.32.jar"));
    accented[8] = 0x00e9;
    try std.testing.expect(!wideContains(&accented, "ergo-5.0.32.jar"));
}

test "an interpreter-launched daemon is matched by its command line on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The regression: the needle case used to `return true` unconditionally, so
    // Ergo read as running on Windows from the moment it was selected — the GUI
    // smiley pulsed "daemon starting" with no node anywhere.
    //
    // Composed at runtime rather than written as a literal: a literal needle
    // would sit in this test binary's own command line whenever it is invoked by
    // name, and match itself.
    var absent: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&absent, "bw-{s}-{d}.jar", .{ "absent", 4242 });
    try std.testing.expect(!aliveMatching(io, "irrelevant.exe", needle));

    // The positive half: a child whose command line carries a marker `pause`
    // ignores. The *name* it runs under is `cmd.exe` — exactly the interpreter
    // case, where the name says nothing and the needle says everything.
    var child = std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "pause", "bw-marker-1a2b3c.jar" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    defer {
        child.kill(io);
    }
    try std.testing.expect(aliveMatching(io, "no-such-image.exe", "bw-marker-1a2b3c.jar"));
}

test "an epee log line surfaces its message, not its columns" {
    // The real shape of a Salvium start failure, verified against `salvium.log` on
    // Windows. Before the columns were stripped this reached the user with the
    // thread id, level, category and source location in front of it.
    const tail =
        "2026-08-26 10:23:47.929\t800\tINFO\tglobal\tsrc/daemon/main.cpp:364\tSalvium 'One' (v1.1.3c-release)\n" ++
        "2026-08-26 10:27:07.531\t4224\tERROR\tdaemon\tsrc/daemon/main.cpp:432\tException in main! Failed to initialize p2p server.\n";
    try std.testing.expectEqualStrings(
        "Exception in main! Failed to initialize p2p server.",
        pickLogError(tail),
    );

    // A bitcoin-derived `debug.log` has no columns to strip, so it must come
    // through exactly as before.
    try std.testing.expectEqualStrings(
        "Error: Cannot obtain a lock on data directory",
        pickLogError("2026-08-26 10:00:00 init message\n2026-08-26 10:00:01 Error: Cannot obtain a lock on data directory\n"),
    );
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
