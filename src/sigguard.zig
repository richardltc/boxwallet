//! Keep a handler installed, for the life of the process, for the signals that
//! `std.Io.Threaded` uses.
//!
//! `std.Io.Threaded` sends **SIGIO** to interrupt a thread blocked in a syscall
//! when it cancels, and **SIGPIPE** arrives when a socket we're writing to goes
//! away. It installs no-op handlers for both in `init` and restores whatever was
//! there before in `deinit` — and `sigaction` is **process-wide**, not per
//! instance.
//!
//! The core creates a `Threaded` per call in well over a hundred places (every
//! `rpc` call, every `conf` read, every coin's RPC helpers), and both front-ends
//! drive those from several threads at once. That races:
//!
//!   1. thread A `init`s, saving old = `SIG_DFL` and installing its handler;
//!   2. thread B `init`s, saving old = *A's handler*;
//!   3. thread A `deinit`s, restoring `SIG_DFL` — the process now has none;
//!   4. B's instance sends SIGIO, whose default action is to **terminate**.
//!
//! The GUI died exactly that way when the metadata reads from a click overlapped
//! the poll thread's sequence: the window vanished with "process terminated with
//! signal IO", no message and no core dump. The TUI has the same shape (a
//! `Threaded` per worker) and the same latent exposure.
//!
//! `install` breaks the chain by putting a permanent no-op handler in place
//! *before* any `Threaded` exists. Every later `init` then records **that** as
//! the previous disposition, so no `deinit` can ever restore `SIG_DFL` — the
//! worst a restore can do is reinstate an identical no-op. Call it once, early,
//! from each front-end's entry point.
//!
//! This is deliberately a floor, not a fix for the churn itself: the real
//! improvement is fewer `Threaded` instances (see `capi.zig`'s shared `Io`), but
//! the guard is what makes the remaining ones safe.

const std = @import("std");
const builtin = @import("builtin");

/// Deliberately empty. Its only job is to exist, so the signal interrupts a
/// blocking syscall with `EINTR` instead of killing us — the same thing
/// `std.Io.Threaded` installs, and safe to be reinstated by any `deinit`
/// because every instance's handler is this shape.
fn ignore(_: std.posix.SIG) callconv(.c) void {}

/// Install the permanent handlers. Idempotent, and safe to call more than once;
/// call it before spawning any thread that might touch `std.Io`.
pub fn install() void {
    if (comptime std.posix.Sigaction == void) return; // Windows: no POSIX signals
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = &ignore },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.IO, &act, null);
    std.posix.sigaction(.PIPE, &act, null);
}

test "after install, neither signal is left at the default action" {
    if (comptime std.posix.Sigaction == void) return error.SkipZigTest;

    install();

    // The point of the guard is that the disposition is never SIG_DFL (0), so a
    // stray SIGIO from a `Threaded` cancelling a syscall can't terminate us.
    for ([_]std.posix.SIG{ .IO, .PIPE }) |sig| {
        var current: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &current);
        const handler = current.handler.handler orelse return error.NoHandlerInstalled;
        try std.testing.expect(@intFromPtr(handler) != 0);
    }
}

test "a Threaded's init/deinit cycle can no longer leave the process unguarded" {
    if (comptime std.posix.Sigaction == void) return error.SkipZigTest;

    install();

    // This is the exact sequence that used to disarm the process: create a
    // Threaded (which saves the current disposition) and destroy it (which puts
    // that saved value back). With the guard in place the value it saves and
    // restores is our permanent handler, not SIG_DFL.
    var t: std.Io.Threaded = .init(std.testing.allocator, .{});
    t.deinit();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.IO, null, &current);
    const handler = current.handler.handler orelse return error.HandlerWasCleared;
    try std.testing.expect(@intFromPtr(handler) != 0);
}
