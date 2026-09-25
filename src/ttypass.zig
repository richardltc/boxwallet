//! Hand a password to a child process through a **private terminal**, so it never
//! appears on the child's command line.
//!
//! A command line is public on Linux: any local user can read another user's
//! `/proc/<pid>/cmdline` (or just run `ps`) for as long as the process lives. A
//! wallet started as `… -p <password> owner_api` stays unlocked — and its password
//! readable — for the whole session. Some wallet CLIs (epic-wallet) offer nothing
//! else: no environment variable, and they never read a password from stdin, only
//! from their **controlling terminal** (`/dev/tty`); with no terminal they take ""
//! and fail.
//!
//! So `spawn` gives the child a pseudo-terminal of its own: the child becomes a
//! session leader with the pty's slave as its controlling terminal, the parent
//! watches the master for the prompt and types the answer. The password only ever
//! crosses a kernel tty buffer between two processes of the same user.
//!
//! **The caller must keep `Tty` open for as long as the child runs.** Closing the
//! master hangs up the terminal and the kernel SIGHUPs the child (verified with
//! epic-wallet) — which is also what happens if BoxWallet dies, so an unlocked
//! wallet can't outlive the app that unlocked it.
//!
//! POSIX only (`supported`): Linux and macOS. On Windows a command line is only
//! readable by the same user or an administrator — who could read the process's
//! memory anyway — so callers keep passing the password as an argument there.
//!
//! Zig's `std.process.spawn` can put a child in a process group but not in a new
//! session with a controlling terminal, hence the fork/exec here. It follows
//! `std.Io.Threaded.spawnPosix`'s rules: everything is allocated before `fork`, and
//! the child makes only raw system calls until `execve`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = posix.system;

/// Whether `spawn` works on this target. Where it doesn't, callers pass the
/// password the way they did before (see the module note on Windows).
pub const supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// The master end of a child's private terminal. Close it only once the child is
/// gone (or to end it: closing hangs the child up).
pub const Tty = struct {
    /// A plain int off `supported` targets, where `posix.fd_t` is a Windows
    /// handle and there is never a terminal to hold.
    fd: Fd = -1,

    const Fd = if (supported) posix.fd_t else i32;

    pub fn isOpen(self: Tty) bool {
        return self.fd >= 0;
    }

    pub fn close(self: *Tty) void {
        if (!supported) return;
        if (self.fd >= 0) _ = sys.close(self.fd);
        self.fd = -1;
    }
};

pub const Options = struct {
    /// argv[0] must be an absolute path: there is no PATH search.
    argv: []const []const u8,
    /// The child's standard streams; null is `/dev/null`.
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
    /// What to type at each prompt. Never copied, logged, or put in argv.
    secret: []const u8,
    /// Text that marks a prompt on the terminal, e.g. "Password" (which also
    /// matches "New Password:" and "Confirm Password:").
    prompt: []const u8,
    /// How many prompts to answer before handing the child back: 1 for a plain
    /// unlock, 2 for a new password that is asked for twice.
    answers: u8 = 1,
    /// How long to wait for all the prompts before giving up on the child.
    timeout_ms: u32 = 20_000,
};

pub const Spawned = struct {
    child: std.process.Child,
    tty: Tty,
};

pub const Error = error{
    /// Not a `supported` target.
    Unsupported,
    /// The secret can't be typed as one line: it holds a newline (which would end
    /// the answer early) or is too long for a terminal line.
    UntypeableSecret,
    /// `argv[0]` isn't an executable file.
    NotExecutable,
    /// No pseudo-terminal could be opened.
    PtyUnavailable,
    SpawnFailed,
    /// The child exited before asking for everything. It has been reaped; its
    /// own stdout/stderr say why.
    ExitedBeforePrompt,
    /// The child never asked. It has been killed and reaped.
    PromptTimeout,
    OutOfMemory,
};

/// Start `opts.argv` on a private terminal and answer its password prompts.
/// Returns once the last prompt is answered, with the child running and the
/// terminal the caller must now hold (see the module note). On any error there is
/// no child left behind and no terminal to close.
pub fn spawn(a: std.mem.Allocator, opts: Options) Error!Spawned {
    if (!supported) return error.Unsupported;
    if (opts.argv.len == 0) return error.NotExecutable;
    // A canonical-mode terminal line holds at most 4095 bytes plus the newline.
    if (std.mem.indexOfAny(u8, opts.secret, "\r\n") != null or opts.secret.len >= 4000)
        return error.UntypeableSecret;

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Everything the child needs is built before fork (no allocating after it).
    const argv_buf = try arena.allocSentinel(?[*:0]const u8, opts.argv.len, null);
    for (opts.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;
    // The same (empty) environment `std.process.spawn` gives a child under a fresh
    // `std.Io.Threaded`, which is how every other wallet process is started.
    const envp = try arena.allocSentinel(?[*:0]const u8, 0, null);

    if (posix.errno(sys.access(argv_buf[0].?, posix.X_OK)) != .SUCCESS) return error.NotExecutable;

    var slave_path: [128]u8 = undefined;
    var tty: Tty = .{ .fd = try openMaster(&slave_path) };
    errdefer tty.close();
    const slave_z: [*:0]const u8 = @ptrCast(&slave_path);

    // No echo: the answer is never written back to the master, so it can't be
    // read back out of it, whatever the child's own timing.
    if (posix.tcgetattr(tty.fd)) |t| {
        var quiet = t;
        quiet.lflag.ECHO = false;
        posix.tcsetattr(tty.fd, .NOW, quiet) catch {};
    } else |_| {}

    const dev_null = sys.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, @as(posix.mode_t, 0));
    if (posix.errno(dev_null) != .SUCCESS) return error.SpawnFailed;
    const null_fd: posix.fd_t = @intCast(dev_null);
    defer _ = sys.close(null_fd);
    const in_fd = if (opts.stdin) |f| f.handle else null_fd;
    const out_fd = if (opts.stdout) |f| f.handle else null_fd;
    const err_fd = if (opts.stderr) |f| f.handle else null_fd;

    const rc = sys.fork();
    if (posix.errno(rc) != .SUCCESS) return error.SpawnFailed;
    const pid: posix.pid_t = @intCast(rc);
    if (pid == 0) childExec(slave_z, in_fd, out_fd, err_fd, argv_buf.ptr, envp.ptr);

    var child: std.process.Child = .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    answerPrompts(tty.fd, pid, opts) catch |err| {
        if (err == error.PromptTimeout) killAndReap(pid);
        child.id = null;
        return err;
    };
    return .{ .child = child, .tty = tty };
}

/// In the forked child: take the pty as controlling terminal, wire up stdio, exec.
/// Raw system calls only — no allocation, no locks — until `execve`.
fn childExec(
    slave: [*:0]const u8,
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    err_fd: posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    // The fork inherits the calling thread's signal mask; the wallet shouldn't.
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    // A new session with no terminal, then the pty becomes its terminal.
    if (posix.errno(sys.setsid()) != .SUCCESS) childExit();
    const opened = sys.open(slave, .{ .ACCMODE = .RDWR }, @as(posix.mode_t, 0));
    if (posix.errno(opened) != .SUCCESS) childExit();
    const tfd: posix.fd_t = @intCast(opened);
    if (ioctlErr(tfd, tiocsctty, 0) != .SUCCESS) childExit();

    if (posix.errno(sys.dup2(in_fd, 0)) != .SUCCESS) childExit();
    if (posix.errno(sys.dup2(out_fd, 1)) != .SUCCESS) childExit();
    if (posix.errno(sys.dup2(err_fd, 2)) != .SUCCESS) childExit();
    // The terminal stays controlling after its fd closes; the child reopens it
    // as /dev/tty when it prompts.
    if (tfd > 2) _ = sys.close(tfd);

    _ = sys.execve(argv[0].?, argv, envp);
    childExit();
}

/// Leave the forked child without running anything of the parent's (see
/// `std.Io.Threaded.forkBail`).
fn childExit() noreturn {
    if (builtin.link_libc) std.c._exit(127);
    if (builtin.os.tag == .linux) std.os.linux.exit_group(127);
    sys.exit(127);
}

/// Wait for `opts.answers` prompts on the master and type the secret at each.
/// Returns `ExitedBeforePrompt` (child reaped) or `PromptTimeout` (child still
/// running — the caller kills it).
fn answerPrompts(master: posix.fd_t, pid: posix.pid_t, opts: Options) Error!void {
    // Only the prompts pass through here — echo is off — so a small window is
    // plenty. Wiped on the way out regardless.
    var window: [512]u8 = undefined;
    defer @memset(&window, 0);
    var len: usize = 0;
    var answered: u8 = 0;
    const step_ms = 50;
    var waited: u32 = 0;

    while (answered < opts.answers) {
        if (waited >= opts.timeout_ms) return error.PromptTimeout;
        if (reaped(pid)) return error.ExitedBeforePrompt;

        var fds = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, step_ms) catch 0;
        waited += step_ms;
        if (ready == 0 or fds[0].revents & posix.POLL.IN == 0) {
            // Until the child opens its side, the master reports a hang-up (and a
            // read gives EIO) straight away — don't spin on that.
            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) sleepMs(step_ms);
            continue;
        }
        if (len == window.len) {
            // Keep enough of the tail to still catch a prompt split across reads.
            const keep = @min(opts.prompt.len, len);
            std.mem.copyForwards(u8, window[0..keep], window[len - keep .. len]);
            len = keep;
        }
        const n = posix.read(master, window[len..]) catch {
            sleepMs(step_ms);
            continue;
        };
        len += n;

        while (std.mem.indexOf(u8, window[0..len], opts.prompt)) |at| {
            const end = at + opts.prompt.len;
            std.mem.copyForwards(u8, window[0 .. len - end], window[end..len]);
            len -= end;
            try typeLine(master, opts.secret);
            answered += 1;
            if (answered == opts.answers) break;
        }
    }
}

/// Write `secret` then a newline to the terminal, handling short writes.
fn typeLine(master: posix.fd_t, secret: []const u8) Error!void {
    try writeAll(master, secret);
    try writeAll(master, "\n");
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = sys.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (posix.errno(rc)) {
            .SUCCESS => off += @intCast(rc),
            .INTR, .AGAIN => sleepMs(10),
            else => return error.SpawnFailed,
        }
    }
}

/// True once `pid` has exited (and is reaped).
fn reaped(pid: posix.pid_t) bool {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = sys.wait4(pid, &status, posix.W.NOHANG, null);
    return switch (posix.errno(rc)) {
        .SUCCESS => rc != 0,
        .INTR => false,
        else => true,
    };
}

fn killAndReap(pid: posix.pid_t) void {
    posix.kill(pid, posix.SIG.KILL) catch return;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (posix.errno(sys.wait4(pid, &status, 0, null)) == .INTR) {}
}

fn sleepMs(ms: u32) void {
    var fds = [_]posix.pollfd{};
    _ = posix.poll(&fds, @intCast(ms)) catch {};
}

/// "Make this terminal my controlling terminal." `std.c.T` doesn't carry it for
/// Darwin, where it is `_IO('t', 97)`.
const tiocsctty = if (builtin.os.tag == .linux) posix.T.IOCSCTTY else 0x20007461;

/// `ioctl(fd, request, arg)`, as the error it set. Two paths, because the GUI
/// links libc and the TUI doesn't. libc declares `request` as a `c_int`, but
/// requests are 32-bit *patterns* — Linux's `TIOCGPTN` is 0x80045430, past
/// `c_int`'s range — so it is reinterpreted, not range-checked (the kernel takes
/// the command as an unsigned 32-bit value either way).
fn ioctlErr(fd: posix.fd_t, request: u32, arg: usize) posix.E {
    if (builtin.os.tag == .linux and !builtin.link_libc) return posix.errno(std.os.linux.ioctl(fd, request, arg));
    return posix.errno(std.c.ioctl(fd, @as(c_int, @bitCast(request)), arg));
}

/// Open a pty master (close-on-exec, so no other child inherits it) and write the
/// slave's path, NUL-terminated, into `path_out`.
fn openMaster(path_out: *[128]u8) Error!posix.fd_t {
    if (builtin.os.tag == .linux) {
        const rc = sys.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, @as(posix.mode_t, 0));
        if (posix.errno(rc) != .SUCCESS) return error.PtyUnavailable;
        const fd: posix.fd_t = @intCast(rc);
        errdefer _ = sys.close(fd);
        var unlock: c_int = 0;
        if (ioctlErr(fd, posix.T.IOCSPTLCK, @intFromPtr(&unlock)) != .SUCCESS) return error.PtyUnavailable;
        var n: c_uint = 0;
        if (ioctlErr(fd, posix.T.IOCGPTN, @intFromPtr(&n)) != .SUCCESS) return error.PtyUnavailable;
        _ = std.fmt.bufPrintZ(path_out, "/dev/pts/{d}", .{n}) catch return error.PtyUnavailable;
        return fd;
    }
    // macOS: the libc calls, then TIOCPTYGNAME for the name (`ptsname` isn't
    // thread-safe; this is what it does underneath).
    const darwin = struct {
        extern "c" fn posix_openpt(flags: c_int) c_int;
        extern "c" fn grantpt(fd: c_int) c_int;
        extern "c" fn unlockpt(fd: c_int) c_int;
        const TIOCPTYGNAME: c_int = 0x40807453;
    };
    const o_rdwr_noctty: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const fd = darwin.posix_openpt(o_rdwr_noctty);
    if (fd < 0) return error.PtyUnavailable;
    errdefer _ = sys.close(fd);
    _ = std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    if (darwin.grantpt(fd) != 0 or darwin.unlockpt(fd) != 0) return error.PtyUnavailable;
    @memset(path_out, 0);
    if (std.c.ioctl(fd, darwin.TIOCPTYGNAME, @intFromPtr(path_out)) != 0) return error.PtyUnavailable;
    return fd;
}

test "a secret reaches a child that reads it from its terminal, and never its argv" {
    if (!supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.createFile(io, "out", .{ .read = true });
    defer out.close(io);

    // A stand-in for epic-wallet: prompts on /dev/tty, asks twice (as `init`
    // does), reads each answer from /dev/tty, and prints what it got. `read`
    // fails without a controlling terminal, so success proves the pty is one.
    const script =
        \\printf 'New Password: ' > /dev/tty; read -r a < /dev/tty
        \\printf 'Confirm Password: ' > /dev/tty; read -r b < /dev/tty
        \\printf '%s|%s' "$a" "$b"
    ;
    var sp = try spawn(a, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdout = out,
        .secret = "hunter2 with spaces",
        .prompt = "Password",
        .answers = 2,
        .timeout_ms = 10_000,
    });
    defer sp.tty.close();
    const term = try sp.child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);

    var buf: [128]u8 = undefined;
    const n = try out.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("hunter2 with spaces|hunter2 with spaces", buf[0..n]);
}

test "a child that exits without asking is reported, and reaped" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.ExitedBeforePrompt, spawn(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "exit 3" },
        .secret = "x",
        .prompt = "Password",
        .timeout_ms = 10_000,
    }));
}

test "a child that never asks is killed at the deadline" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.PromptTimeout, spawn(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .secret = "x",
        .prompt = "Password",
        .timeout_ms = 300,
    }));
}

test "a secret that can't be typed as one line is refused up front" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.UntypeableSecret, spawn(std.testing.allocator, .{
        .argv = &.{"/bin/true"},
        .secret = "two\nlines",
        .prompt = "Password",
    }));
}
