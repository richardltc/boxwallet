const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

/// BoxWallet's own settings file (a plain `key=value` conf, read and written
/// through `readValue`/`setValue`), kept alongside the coins under the install
/// root. **Both frontends share this one file** — the TUI's `hide_balances`
/// privacy toggle and the GUI's `gui_window_*` geometry live in it together —
/// which is why writes go through `setValue`, that preserves every other line.
pub const settings_file = "boxwallet.conf";

/// True if `data_dir` already contains `entry` (a file or a subdirectory).
///
/// The point of this is telling a data directory BoxWallet created from one it
/// **adopted**. BoxWallet deliberately shares the daemon's standard data dir, so
/// that directory may already belong to another wallet app (Bitcoin Core, Divi
/// Desktop, an existing monerod) and hold a synced chain and a live wallet. The
/// rule is that anything already on disk is the other app's property: BoxWallet
/// shares it and must never rewrite or discard it. Callers use a marker entry the
/// daemon itself creates (a bitcoin-derived coin's `blocks/`) to ask "was someone
/// here before me?" before doing anything irreversible.
///
/// A pure disk check — no daemon needed, and nothing held beyond a path, so it's
/// safe on the pre-start preflight path.
pub fn dataDirHasEntry(allocator: std.mem.Allocator, data_dir: []const u8, entry: []const u8) bool {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch return false;
    defer dir.close(io);
    dir.access(io, entry, .{}) catch return false;
    return true;
}

/// Resolve a coin daemon's default data directory — where it writes its `.conf`
/// and chain data when started without an explicit `-datadir`:
///   - Linux/other: `<home>/<posix_name>`                        e.g. `~/.divi`
///   - macOS:       `<home>/Library/Application Support/<mac_name>`
///   - Windows:     `<home>/AppData/Roaming/<win_name>`          e.g. `…\Roaming\DIVI`
///
/// BoxWallet passes no `-datadir`, so this **must** agree with what the daemon
/// itself would pick — otherwise BoxWallet writes its conf and reads its RPC
/// credentials from one directory while the daemon runs out of another. That was
/// live for the bitcoin-derived coins on macOS, which resolved `~/.divi` while
/// `divid` used `~/Library/Application Support/DIVI`.
///
/// **`mac_name` is required and none of the names is derivable from the others.**
/// Each project picks its own capitalisation: `.bitcoin` → `Bitcoin`, `.nexa` →
/// `nexa`, `.reddcoin` → `Reddcoin`. `win_name` can't stand in for it either — the
/// two disagree for ReddCoin (`REDDCOIN` vs `Reddcoin`) and Nexa (`NEXA` vs
/// `nexa`), which a case-insensitive Mac volume would paper over and a
/// case-sensitive one would not.
///
/// **`mac_name` is nullable, and null is a real answer, not "unset":** it means the
/// daemon uses its POSIX path on macOS as well. That's the whole CryptoNote family
/// — Monero and its forks put the data dir at `~/.<name>` on Mac too ("Unix & Mac:
/// ~/.CRYPTONOTE_NAME"). Their macOS path is *not* a `Library/Application Support`
/// dir, so it can't be expressed by any name passed here. Having no default forces
/// each coin to state which convention it follows; getting it wrong points a coin
/// at an empty directory and orphans a live wallet.
///
/// **`win_base` is required for the same reason `mac_name` is:** Windows has two
/// conventions and neither is derivable from the names. See `WinBase`.
///
/// `home_dir` is the process home directory; the caller owns the returned slice.
pub fn dataDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    posix_name: []const u8,
    win_name: []const u8,
    mac_name: ?[]const u8,
    win_base: WinBase,
) ![]const u8 {
    return dataDirFor(allocator, home_dir, builtin.os.tag, posix_name, win_name, mac_name, win_base);
}

/// Which Windows directory a coin's data dir hangs off. Two conventions are in
/// play and **nothing in the names says which**, so every coin states its own —
/// exactly as it must for `mac_name`, and for the same reason: guessing points
/// BoxWallet at a directory the daemon never touches.
///
/// The consequences are quiet rather than loud, which is what makes this worth a
/// required parameter. Getting it wrong means BoxWallet writes the coin's conf
/// where the daemon won't read it, reads warm-up progress and start-failure
/// reasons out of a log that never appears, and puts a managed wallet somewhere
/// the daemon's own tooling won't find — a daemon that dies during init then
/// reports nothing at all.
pub const WinBase = enum {
    /// `%APPDATA%` — `<home>\AppData\Roaming\<win_name>`. The bitcoin-derived
    /// coins, and Zano (verified from `zanod --help`).
    roaming,
    /// `%ProgramData%` — `C:\ProgramData\<win_name>`. The CryptoNote family picks
    /// `CSIDL_COMMON_APPDATA` on Windows, not the per-user roaming dir: verified
    /// from each daemon's own `--help` — `C:\ProgramData\bitmonero` (monerod),
    /// `C:\ProgramData\nerva` (nervad), `C:\ProgramData\salvium` (salviumd).
    /// Note it is **not** per-user, so the POSIX `<home>` plays no part in it.
    program_data,
};

/// `%ProgramData%`'s standard location. Only the fallback: the real path is read
/// from the environment (below), since Windows lets it be relocated at install
/// time and the daemons resolve it through the shell API, not this literal.
const default_program_data = "C:\\ProgramData";

/// The `%ProgramData%` root, honouring a relocated one. Caller owns the slice.
///
/// Off Windows this is the literal default and nothing is read from the
/// environment — so `dataDirFor`'s Windows branch stays deterministic when a
/// Linux/macOS test run walks the whole platform matrix (which is the only way
/// that branch is checkable at all; see `dataDirFor`).
fn programDataRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        if (environ.getAlloc(allocator, "ProgramData")) |value| {
            if (value.len > 0) return value;
            allocator.free(value);
        } else |_| {}
    }
    return allocator.dupe(u8, default_program_data);
}

/// `dataDir` for an explicit `os`, rather than the build target.
///
/// Split out so the whole platform matrix is checkable from one native test run:
/// a test compiled for Linux can't otherwise reach the macOS or Windows branch at
/// all, and would pass while proving nothing about them — which is precisely how
/// the macOS paths stayed wrong.
pub fn dataDirFor(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    os: std.Target.Os.Tag,
    posix_name: []const u8,
    win_name: []const u8,
    mac_name: ?[]const u8,
    win_base: WinBase,
) ![]const u8 {
    return switch (os) {
        .windows => switch (win_base) {
            .roaming => std.fs.path.join(allocator, &.{ home_dir, "AppData", "Roaming", win_name }),
            .program_data => blk: {
                const root = try programDataRoot(allocator);
                defer allocator.free(root);
                break :blk std.fs.path.join(allocator, &.{ root, win_name });
            },
        },
        // A null `mac_name` means macOS follows the POSIX layout (the CryptoNote
        // family), not that it was forgotten — see `dataDir`.
        .macos => if (mac_name) |m|
            std.fs.path.join(allocator, &.{ home_dir, "Library", "Application Support", m })
        else
            std.fs.path.join(allocator, &.{ home_dir, posix_name }),
        else => std.fs.path.join(allocator, &.{ home_dir, posix_name }),
    };
}

/// The directory holding a coin's BoxWallet-managed wallet — `<data_dir>/wallets`,
/// unless an earlier BoxWallet already put one somewhere else.
///
/// Correcting a coin's `win_base` moves its data dir, and the managed wallet
/// rides along: a Windows user who created a Monero/Nerva/Salvium wallet before
/// that fix has it under `%APPDATA%\<win_name>\wallets`, because that is where
/// BoxWallet pointed `--wallet-dir` at the time. It worked — the wallet dir is
/// passed to the wallet RPC explicitly, so only the *daemon* (always in
/// `%ProgramData%`) noticed the disagreement. Silently resolving the corrected
/// dir would leave that wallet on disk but invisible, reading as "no wallet — set
/// one up" for someone who has funds in it. So the old location wins whenever it
/// actually holds the wallet (`marker`, e.g. `BoxWallet.keys`) and the new one
/// does not — never merely because it exists.
///
/// A no-op everywhere else: off Windows, for `.roaming` coins, and on any Windows
/// machine with no such leftover. Caller owns the returned slice.
pub fn managedWalletDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    data_dir: []const u8,
    win_name: []const u8,
    win_base: WinBase,
    marker: []const u8,
) ![]const u8 {
    const current = try std.fs.path.join(allocator, &.{ data_dir, "wallets" });
    if (builtin.os.tag != .windows or win_base != .program_data) return current;
    errdefer allocator.free(current);

    // The corrected location wins the moment it holds a wallet, so a machine that
    // has already moved on never gets dragged back to the leftover.
    if (dataDirHasEntry(allocator, current, marker)) return current;

    const legacy = try std.fs.path.join(allocator, &.{ home_dir, "AppData", "Roaming", win_name, "wallets" });
    if (dataDirHasEntry(allocator, legacy, marker)) {
        allocator.free(current);
        return legacy;
    }
    allocator.free(legacy);
    return current;
}

/// Build RPC connection details for a coin daemon by reading its `conf_file`
/// from `data_dir` (e.g. `~/.divi/divi.conf`). The conf is a small `key=value`
/// file; we pull `rpcuser`/`rpcpassword`/`rpcport` and fall back to the supplied
/// defaults (and `127.0.0.1`) for anything it omits.
///
/// The conf is scanned line by line through a fixed 8 KiB buffer — never read
/// whole into memory — keeping with the project's flat-memory rule. All four
/// returned `CoinAuth` strings are owned by `allocator`; release them with
/// `freeAuth`.
pub fn readAuth(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    default_user: []const u8,
    default_port: []const u8,
) !models.CoinAuth {
    // Seed every field with an owned default so `freeAuth` can release them
    // uniformly and a conf that omits a key still yields a usable value.
    var auth: models.CoinAuth = .{
        .rpc_user = try allocator.dupe(u8, default_user),
        .rpc_password = try allocator.dupe(u8, ""),
        .ip_address = try allocator.dupe(u8, "127.0.0.1"),
        .port = try allocator.dupe(u8, default_port),
        // Carry the data dir so a coin can locate an out-of-band credential file
        // (e.g. Epic's `.api_secret`) that isn't part of the `key=value` conf.
        .data_dir = try allocator.dupe(u8, data_dir),
    };
    errdefer freeAuth(allocator, auth);

    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{});
    defer dir.close(io);

    var file = try dir.openFile(io, conf_file, .{});
    defer file.close(io);

    // Each `takeDelimiter` returns a slice into `buf` that the next call
    // overwrites, so any value we keep is duped out immediately.
    var buf: [8 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    while (try fr.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const slot: ?*[]const u8 =
            if (std.mem.eql(u8, key, "rpcuser")) &auth.rpc_user else if (std.mem.eql(u8, key, "rpcpassword")) &auth.rpc_password else if (std.mem.eql(u8, key, "rpcport")) &auth.port else null;
        if (slot) |s| {
            const dup = try allocator.dupe(u8, val);
            allocator.free(s.*);
            s.* = dup;
        }
    }

    return auth;
}

/// Ensure the coin's conf carries the settings BoxWallet needs to drive the
/// daemon over RPC: an `rpcuser`, a generated `rpcpassword`, `server=1`, and
/// `rpcport`. Without these a daemon falls back to cookie auth (or no RPC at
/// all), which BoxWallet can't use — the symptom that left Nexa unmanageable
/// while Divi (whose conf already had creds) worked.
///
/// An enabled `daemon=…` line is *removed* if present: BoxWallet supplies
/// `-daemon` on the launch command line itself (POSIX) and spawns the daemon
/// detached on Windows, so it never needs it in the conf — and leaving it there
/// breaks the coin's own Qt GUI (which can't daemonize) and the Windows daemon
/// (no `-daemon` support), so neither could share the file. A user's explicit
/// `daemon=0` is left untouched.
///
/// Existing values are preserved — a user's own password/port stay put — and
/// only missing keys are appended, so the conf's comments and ordering survive.
/// The data dir and conf are created if absent. Returns true if anything was
/// written (a key added or a `daemon` line stripped). The conf is a tiny
/// `key=value` file, read whole through one bounded buffer and rewritten only
/// when something changed.
pub fn populate(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    default_user: []const u8,
    default_port: []const u8,
) !bool {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);

    // Slurp the current conf if it exists; absent means every key is missing.
    var content: []const u8 = "";
    var content_owned = false;
    if (dir.openFile(io, conf_file, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 64 * 1024));
        const data = try allocator.alloc(u8, size);
        const n = try file.readPositionalAll(io, data, 0);
        content = data[0..n];
        content_owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (content_owned) allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Copy the conf forward verbatim, dropping any enabled `daemon` line (see the
    // doc comment for why). A removal counts as a change so the file is rewritten.
    var wrote = try stripDaemon(&out.writer, content);

    // Start appends on a fresh line so a conf without a trailing newline stays valid.
    const so_far = out.written();
    if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') try out.writer.writeByte('\n');

    if (!hasKey(content, "rpcuser")) {
        try out.writer.print("rpcuser={s}\n", .{default_user});
        wrote = true;
    }
    if (!hasKey(content, "rpcpassword")) {
        var pw_buf: [20]u8 = undefined;
        try out.writer.print("rpcpassword={s}\n", .{randomPassword(io, &pw_buf)});
        wrote = true;
    }
    if (!hasKey(content, "server")) {
        try out.writer.writeAll("server=1\n");
        wrote = true;
    }
    if (!hasKey(content, "rpcport")) {
        try out.writer.print("rpcport={s}\n", .{default_port});
        wrote = true;
    }

    if (wrote) try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
    return wrote;
}

/// Rewrite `conf_file` under `data_dir` to exactly `body`, creating the dir if
/// absent and replacing any existing file. Unlike `populate`'s careful append-
/// only merge, this is a clobbering write for coins whose daemon parses the conf
/// itself and owns it outright — there's nothing user-authored to preserve, and
/// a stale/incompatible file is actively harmful (e.g. nervad rejecting bitcoin
/// keys), so the canonical content must win. Self-healing: a bad conf is
/// overwritten on the next prepare.
pub fn writeConf(
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    body: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = conf_file, .data = body });
}

/// Read a single `key=value` setting from `conf_file` under `data_dir`, returning
/// the (allocator-owned) value, or null when the conf or the key is absent. The
/// conf is scanned line by line through a fixed buffer — never slurped whole —
/// like `readAuth`. Used for settings BoxWallet exposes/reads back individually
/// (e.g. a coin's `prune` target). The last occurrence wins, mirroring how a
/// bitcoin daemon takes the final value of a repeated key.
pub fn readValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    key: []const u8,
) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, data_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var file = dir.openFile(io, conf_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var found: ?[]const u8 = null;
    errdefer if (found) |f| allocator.free(f);

    var buf: [8 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    while (try fr.interface.takeDelimiter('\n')) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        // Each `takeDelimiter` slice is overwritten by the next read, so dup the
        // value out now; a later occurrence frees the earlier one and wins.
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const dup = try allocator.dupe(u8, val);
        if (found) |f| allocator.free(f);
        found = dup;
    }
    return found;
}

/// Set `key=value` in `conf_file` under `data_dir`, replacing an existing
/// (non-comment) line for `key` in place or appending one if absent; every other
/// line — comments, blank lines, ordering, line endings — is preserved. The data
/// dir and conf are created if missing. For settings BoxWallet owns the value of
/// (e.g. a coin's `prune` target chosen at first start). The conf is a tiny file,
/// read whole through one bounded buffer and rewritten once.
pub fn setValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);

    var content: []const u8 = "";
    var content_owned = false;
    if (dir.openFile(io, conf_file, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 64 * 1024));
        const data = try allocator.alloc(u8, size);
        const n = try file.readPositionalAll(io, data, 0);
        content = data[0..n];
        content_owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (content_owned) allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Copy lines forward verbatim, swapping the first matching key line for the
    // new value. Preserves original line endings on every untouched line.
    var replaced = false;
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const end = if (nl < content.len) nl + 1 else nl;
        const line = std.mem.trim(u8, content[i..nl], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const is_key = !replaced and line.len > 0 and line[0] != '#' and eq != null and
            std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), key);
        if (is_key) {
            try out.writer.print("{s}={s}\n", .{ key, value });
            replaced = true;
        } else {
            try out.writer.writeAll(content[i..end]);
        }
        i = end;
    }
    if (!replaced) {
        const so_far = out.written();
        if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.print("{s}={s}\n", .{ key, value });
    }

    try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
}

/// Append each of `lines` (verbatim `key=value` lines) to `conf_file` under
/// `data_dir` unless an identical (trimmed) line is already present; every
/// existing line — comments, ordering, the user's own entries — is preserved
/// untouched. For *repeatable* keys (`addnode=…`) that `setValue` can't
/// express: it replaces the first `key` match, which would clobber a user's
/// own entries, while this only ever adds. Idempotent — a rerun appends
/// nothing. The data dir and conf are created if missing. Returns true if
/// anything was written.
pub fn ensureLines(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: []const u8,
    conf_file: []const u8,
    lines: []const []const u8,
) !bool {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dir.close(io);

    var content: []const u8 = "";
    var content_owned = false;
    if (dir.openFile(io, conf_file, .{})) |file| {
        defer file.close(io);
        const stat = try file.stat(io);
        const size: usize = @intCast(@min(stat.size, 64 * 1024));
        const data = try allocator.alloc(u8, size);
        const n = try file.readPositionalAll(io, data, 0);
        content = data[0..n];
        content_owned = true;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    defer if (content_owned) allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(content);

    var wrote = false;
    for (lines) |line| {
        if (hasLine(content, line)) continue;
        const so_far = out.written();
        if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.print("{s}\n", .{line});
        wrote = true;
    }

    if (wrote) try dir.writeFile(io, .{ .sub_path = conf_file, .data = out.written() });
    return wrote;
}

/// True if `content` contains a line whose trimmed form equals `line`.
fn hasLine(content: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), line)) return true;
    }
    return false;
}

/// Copy `content` into `w`, dropping any line that *enables* `daemon` (a truthy
/// `daemon=…`). Returns true if such a line was removed, so the caller knows to
/// rewrite the conf. Everything else — comments, blank lines, ordering, other
/// keys, and the original line endings — is preserved byte-for-byte; an explicit
/// `daemon=0` is kept.
fn stripDaemon(w: *std.Io.Writer, content: []const u8) !bool {
    var removed = false;
    var i: usize = 0;
    while (i < content.len) {
        const nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const end = if (nl < content.len) nl + 1 else nl; // include the '\n' if present
        const line = std.mem.trim(u8, content[i..nl], " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const drop = line.len > 0 and line[0] != '#' and eq != null and
            std.mem.eql(u8, std.mem.trim(u8, line[0..eq.?], " \t"), "daemon") and
            isEnabled(std.mem.trim(u8, line[eq.? + 1 ..], " \t"));
        if (drop) {
            removed = true;
        } else {
            try w.writeAll(content[i..end]);
        }
        i = end;
    }
    return removed;
}

/// Bitcoin-conf truthiness for a boolean value (`1`/`true`/`yes`/`on`).
fn isEnabled(val: []const u8) bool {
    return std.mem.eql(u8, val, "1") or
        std.ascii.eqlIgnoreCase(val, "true") or
        std.ascii.eqlIgnoreCase(val, "yes") or
        std.ascii.eqlIgnoreCase(val, "on");
}

/// True if `content` has a non-comment line whose key (left of `=`) is `key`.
fn hasKey(content: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) return true;
    }
    return false;
}

/// Fill `buf` with a random alphanumeric password, returning it as a slice. Bytes
/// come from the platform's cryptographically secure RNG via `io.random` (a CSPRNG
/// seeded from OS entropy), so the rpcpassword guarding the daemon's localhost RPC
/// isn't guessable by another local user — the same CSPRNG on every OS, with no
/// weak fallback. Each byte is drawn with rejection sampling so the alphabet maps
/// onto it without modulo bias.
pub fn randomPassword(io: std.Io, buf: []u8) []const u8 {
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    // Reject the few high bytes that would skew the modulo, so every charset index
    // is equally likely (256 % 62 == 8 bytes fall outside the uniform run).
    const limit = 256 - (256 % charset.len);
    io.random(buf); // seed every slot; the rare biased bytes are resampled below
    for (buf) |*c| {
        var b = c.*;
        while (b >= limit) {
            var one: [1]u8 = undefined;
            io.random(&one);
            b = one[0];
        }
        c.* = charset[b % charset.len];
    }
    return buf;
}

/// Free the four strings owned by a `CoinAuth` built by `readAuth`.
pub fn freeAuth(allocator: std.mem.Allocator, auth: models.CoinAuth) void {
    allocator.free(auth.rpc_user);
    allocator.free(auth.rpc_password);
    allocator.free(auth.ip_address);
    allocator.free(auth.port);
    allocator.free(auth.data_dir);
}

test "dataDir builds the coin home per platform, macOS included" {
    const allocator = std.testing.allocator;
    const pathtest = @import("pathtest.zig");

    // Via `dataDirFor`, so all three branches are checked from one run. The old
    // test only covered the build target's branch — which is why the macOS paths
    // could be wrong for every bitcoin-derived coin without a test noticing.
    const cases = [_]struct { os: std.Target.Os.Tag, want: []const u8 }{
        .{ .os = .linux, .want = "/home/alice/.divi" },
        // The bug this fixes: BoxWallet passes no `-datadir`, and `divid` on macOS
        // uses `~/Library/Application Support/DIVI`. Resolving `~/.divi` here left
        // BoxWallet writing its conf and reading its RPC creds from a directory the
        // daemon never opened.
        .{ .os = .macos, .want = "/home/alice/Library/Application Support/DIVI" },
        .{ .os = .windows, .want = "/home/alice/AppData/Roaming/DIVI" },
    };
    for (cases) |c| {
        const dir = try dataDirFor(allocator, "/home/alice", c.os, ".divi", "DIVI", "DIVI", .roaming);
        defer allocator.free(dir);
        // Compared on '/' so one expectation reads the same on every host — these
        // resolve paths for a *simulated* OS, so the host's separator is not the
        // one under test.
        try pathtest.expectEqual(c.want, dir);
    }

    // The CryptoNote exception: Monero and its forks use `~/.<name>` on macOS too,
    // so they pass their POSIX name as `mac_name`. A shared macOS branch that
    // reached for the Windows name instead would relocate them on Mac and orphan a
    // live wallet.
    const xmr = try dataDirFor(allocator, "/home/alice", .macos, ".bitmonero", "bitmonero", null, .program_data);
    defer allocator.free(xmr);
    try pathtest.expectEqual("/home/alice/.bitmonero", xmr);
}

test "readAuth parses rpc creds from a conf and falls back to defaults" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    // A typical conf: comments and blank lines, rpcuser/rpcpassword/rpcport set,
    // plus unrelated keys that must be ignored. rpcport is intentionally omitted
    // to exercise the default fallback.
    try d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\# divi.conf
        \\rpcuser=divirpc
        \\rpcpassword=UOE7xXiT3MIAagYjNt5B
        \\daemon=1
        \\server=1
        \\
    });

    const auth = try readAuth(allocator, io, dir, "divi.conf", "fallbackuser", "51473");
    defer freeAuth(allocator, auth);

    try std.testing.expectEqualStrings("divirpc", auth.rpc_user);
    try std.testing.expectEqualStrings("UOE7xXiT3MIAagYjNt5B", auth.rpc_password);
    try std.testing.expectEqualStrings("127.0.0.1", auth.ip_address);
    // rpcport absent → default kept.
    try std.testing.expectEqualStrings("51473", auth.port);
}

test "populate appends missing creds and settings, then readAuth reads them back" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-populate-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A comments-only conf, like a freshly-created nexa.conf: no creds at all.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "nexa.conf", .data = "# NEXA config\n" }) catch {};
    d.close(io);

    const wrote = try populate(allocator, io, dir, "nexa.conf", "nexarpc", "7227");
    try std.testing.expect(wrote);

    const auth = try readAuth(allocator, io, dir, "nexa.conf", "fallbackuser", "1111");
    defer freeAuth(allocator, auth);

    // rpcuser falls to the coin default, rpcport is written, and a non-empty
    // random password was generated.
    try std.testing.expectEqualStrings("nexarpc", auth.rpc_user);
    try std.testing.expectEqualStrings("7227", auth.port);
    try std.testing.expectEqual(@as(usize, 20), auth.rpc_password.len);

    // The original comment is preserved (append-only, not a rewrite from scratch).
    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "nexa.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "# NEXA config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "server=1") != null);

    // Idempotent: a second pass finds everything present and writes nothing.
    try std.testing.expect(!try populate(allocator, io, dir, "nexa.conf", "nexarpc", "7227"));
}

test "populate preserves existing creds rather than overwriting them" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-populate-keep-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\rpcuser=divirpc
        \\rpcpassword=keepme
        \\
    }) catch {};
    d.close(io);

    _ = try populate(allocator, io, dir, "divi.conf", "shouldnotwin", "51473");

    const auth = try readAuth(allocator, io, dir, "divi.conf", "x", "0");
    defer freeAuth(allocator, auth);
    try std.testing.expectEqualStrings("divirpc", auth.rpc_user);
    try std.testing.expectEqualStrings("keepme", auth.rpc_password);
}

test "populate strips an enabled daemon line, preserving the rest" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-daemon-strip-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // A conf an older BoxWallet (or the user) left carrying daemon=1, with a
    // comment and creds to prove the rest of the file survives the rewrite.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data =
        \\# divi.conf
        \\rpcuser=divirpc
        \\rpcpassword=keepme
        \\daemon=1
        \\server=1
        \\
    }) catch {};
    d.close(io);

    // Removing the daemon line counts as a change → wrote=true, file rewritten.
    try std.testing.expect(try populate(allocator, io, dir, "divi.conf", "x", "51473"));

    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "divi.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    const out = rb[0..n];
    try std.testing.expect(std.mem.indexOf(u8, out, "daemon=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# divi.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rpcpassword=keepme") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "server=1") != null);

    // Idempotent now: nothing left to strip or add.
    try std.testing.expect(!try populate(allocator, io, dir, "divi.conf", "x", "51473"));
}

test "populate leaves an explicit daemon=0 in place" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-daemon-keep-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // Everything BoxWallet needs is already present and daemon is *disabled*, so
    // there's nothing to add and nothing to strip — populate is a no-op.
    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "divi.conf", .data = "rpcuser=u\nrpcpassword=p\nserver=1\nrpcport=51473\ndaemon=0\n" }) catch {};
    d.close(io);

    try std.testing.expect(!try populate(allocator, io, dir, "divi.conf", "x", "51473"));

    var rb: [4096]u8 = undefined;
    var f = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer f.close(io);
    var cf = try f.openFile(io, "divi.conf", .{});
    defer cf.close(io);
    const n = try cf.readPositionalAll(io, &rb, 0);
    try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "daemon=0") != null);
}

test "readAuth keeps defaults when the conf omits everything" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-empty-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "x.conf", .data = "# nothing useful here\n" });

    const auth = try readAuth(allocator, io, dir, "x.conf", "defuser", "1234");
    defer freeAuth(allocator, auth);

    try std.testing.expectEqualStrings("defuser", auth.rpc_user);
    try std.testing.expectEqualStrings("", auth.rpc_password);
    try std.testing.expectEqualStrings("1234", auth.port);
}

test "readValue returns null for a missing conf or missing key, the value when present" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-readvalue-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    // No conf at all → null (no error).
    try std.testing.expect((try readValue(allocator, io, dir, "litecoin.conf", "prune")) == null);

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "litecoin.conf", .data =
        \\# litecoin.conf
        \\rpcuser=ltc
        \\prune=5000
        \\
    });

    const present = try readValue(allocator, io, dir, "litecoin.conf", "prune");
    defer if (present) |p| allocator.free(p);
    try std.testing.expectEqualStrings("5000", present.?);

    // A key the conf omits → null.
    try std.testing.expect((try readValue(allocator, io, dir, "litecoin.conf", "txindex")) == null);
}

test "setValue replaces an existing key in place and appends a missing one" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-setvalue-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    d.writeFile(io, .{ .sub_path = "litecoin.conf", .data =
        \\# litecoin.conf
        \\prune=2000
        \\rpcuser=ltc
        \\
    }) catch {};
    d.close(io);

    // Replace prune in place; the comment, ordering, and other keys survive.
    try setValue(allocator, io, dir, "litecoin.conf", "prune", "10000");
    {
        const v = try readValue(allocator, io, dir, "litecoin.conf", "prune");
        defer if (v) |p| allocator.free(p);
        try std.testing.expectEqualStrings("10000", v.?);
        const u = try readValue(allocator, io, dir, "litecoin.conf", "rpcuser");
        defer if (u) |p| allocator.free(p);
        try std.testing.expectEqualStrings("ltc", u.?);
    }

    // A key not present is appended.
    try setValue(allocator, io, dir, "litecoin.conf", "txindex", "1");
    const t = try readValue(allocator, io, dir, "litecoin.conf", "txindex");
    defer if (t) |p| allocator.free(p);
    try std.testing.expectEqualStrings("1", t.?);
}

test "setValue creates the conf (and dir) when absent" {
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "test-conf-setvalue-fresh-out";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};

    try setValue(allocator, io, dir, "litecoin.conf", "prune", "0");
    const v = try readValue(allocator, io, dir, "litecoin.conf", "prune");
    defer if (v) |p| allocator.free(p);
    try std.testing.expectEqualStrings("0", v.?);
}

test "randomPassword fills the buffer with charset-only bytes" {
    // Randomness quality isn't unit-testable, but charset compliance is the one
    // externally observable property — and the rejection-sampling loop must always
    // terminate with an in-alphabet byte for every slot, on every OS.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var buf: [20]u8 = undefined;
    const pw = randomPassword(io, &buf);
    try std.testing.expectEqual(@as(usize, 20), pw.len);
    for (pw) |c| try std.testing.expect(std.mem.indexOfScalar(u8, charset, c) != null);
}

test "every coin's macOS data dir matches what its own daemon would pick" {
    const allocator = std.testing.allocator;

    // BoxWallet passes no `-datadir`, so each coin's resolved dir must equal the
    // daemon's own default, or the two run out of different directories. Every
    // expectation below was read from that project's `GetDefaultDataDir()`, not
    // inferred — the names aren't derivable from each other (`.bitcoin` → `Bitcoin`,
    // but `.nexa` → `nexa` and `.reddcoin` → `Reddcoin`).
    //
    // This is the check whose absence let macOS stay broken: each coin owned its
    // names, but nothing asserted they agreed with upstream.
    const pathtest = @import("pathtest.zig");
    const Bitcoin = @import("coins/bitcoin.zig").Bitcoin;
    const Litecoin = @import("coins/litecoin.zig").Litecoin;
    const Divi = @import("coins/divi.zig").Divi;
    const ReddCoin = @import("coins/reddcoin.zig").ReddCoin;
    const Nexa = @import("coins/nexa.zig").Nexa;
    const DigiByte = @import("coins/digibyte.zig").DigiByte;
    const Monero = @import("coins/monero.zig").Monero;
    const Nerva = @import("coins/nerva.zig").Nerva;
    const Salvium = @import("coins/salvium.zig").Salvium;
    const Zano = @import("coins/zano.zig").Zano;

    const Case = struct {
        name: []const u8,
        posix: []const u8,
        win: []const u8,
        mac: ?[]const u8,
        want: []const u8,
    };
    const cases = [_]Case{
        // Bitcoin-derived: macOS is `Library/Application Support/<Name>`.
        .{ .name = "bitcoin", .posix = Bitcoin.home_dir, .win = Bitcoin.home_dir_win, .mac = Bitcoin.home_dir_mac, .want = "/h/Library/Application Support/Bitcoin" },
        .{ .name = "litecoin", .posix = Litecoin.home_dir, .win = Litecoin.home_dir_win, .mac = Litecoin.home_dir_mac, .want = "/h/Library/Application Support/Litecoin" },
        .{ .name = "divi", .posix = Divi.home_dir, .win = Divi.home_dir_win, .mac = Divi.home_dir_mac, .want = "/h/Library/Application Support/DIVI" },
        .{ .name = "reddcoin", .posix = ReddCoin.home_dir, .win = ReddCoin.home_dir_win, .mac = ReddCoin.home_dir_mac, .want = "/h/Library/Application Support/Reddcoin" },
        .{ .name = "nexa", .posix = Nexa.home_dir, .win = Nexa.home_dir_win, .mac = Nexa.home_dir_mac, .want = "/h/Library/Application Support/nexa" },
        .{ .name = "digibyte", .posix = DigiByte.home_dir, .win = DigiByte.home_dir_win, .mac = DigiByte.home_dir_mac, .want = "/h/Library/Application Support/DigiByte" },
        // CryptoNote family: `~/.<name>` on macOS as well as Linux, i.e. a null mac
        // name. Read from each coin's own decl, not hardcoded here — a table that
        // asserted `null` directly would keep passing if the coin started handing
        // `dataDir` a Library name, which is the exact mistake this must catch.
        // Getting these wrong relocates a live Monero/Nerva/Salvium/Zano wallet.
        .{ .name = "monero", .posix = Monero.home_dir, .win = Monero.home_dir_win, .mac = Monero.home_dir_mac, .want = "/h/.bitmonero" },
        .{ .name = "nerva", .posix = Nerva.home_dir, .win = Nerva.home_dir_win, .mac = Nerva.home_dir_mac, .want = "/h/.nerva" },
        .{ .name = "salvium", .posix = Salvium.home_dir, .win = Salvium.home_dir_win, .mac = Salvium.home_dir_mac, .want = "/h/.salvium" },
        .{ .name = "zano", .posix = Zano.home_dir, .win = Zano.home_dir_win, .mac = Zano.home_dir_mac, .want = "/h/.Zano" },
    };

    for (cases) |c| {
        const got = try dataDirFor(allocator, "/h", .macos, c.posix, c.win, c.mac, .roaming);
        defer allocator.free(got);
        pathtest.expectEqual(c.want, got) catch |e| {
            std.debug.print("macOS data dir mismatch for {s}\n", .{c.name});
            return e;
        };
    }
}

test "every coin's Windows data dir matches what its own daemon would pick" {
    const allocator = std.testing.allocator;

    // The Windows twin of the macOS check above, and the check whose absence let
    // the CryptoNote coins stay broken on Windows: `%APPDATA%` is *not* the only
    // convention. Monero and its forks resolve `CSIDL_COMMON_APPDATA`, so their
    // data dir is `C:\ProgramData\<name>` — BoxWallet resolved a roaming path
    // nobody wrote to, which left the coin's conf unread, and warm-up progress and
    // start-failure reasons being looked for in a log that never existed. A
    // Salvium daemon that failed to start therefore reported nothing at all.
    //
    // Every expectation below was read off the daemon's own `--help` on Windows
    // ("--data-dir arg (=…)"), not inferred. Each case passes the coin's *declared*
    // base, so a coin that declares the wrong one produces the wrong path and
    // fails here rather than in the field.
    const pathtest = @import("pathtest.zig");
    const Bitcoin = @import("coins/bitcoin.zig").Bitcoin;
    const Litecoin = @import("coins/litecoin.zig").Litecoin;
    const Divi = @import("coins/divi.zig").Divi;
    const ReddCoin = @import("coins/reddcoin.zig").ReddCoin;
    const Nexa = @import("coins/nexa.zig").Nexa;
    const DigiByte = @import("coins/digibyte.zig").DigiByte;
    const BitcoinZ = @import("coins/bitcoinz.zig").BitcoinZ;
    const SpiderByte = @import("coins/spiderbyte.zig").SpiderByte;
    const Monero = @import("coins/monero.zig").Monero;
    const Nerva = @import("coins/nerva.zig").Nerva;
    const Salvium = @import("coins/salvium.zig").Salvium;
    const Zano = @import("coins/zano.zig").Zano;

    const Case = struct {
        name: []const u8,
        posix: []const u8,
        win: []const u8,
        mac: ?[]const u8,
        /// The base the coin *declares* — what's under test.
        base: WinBase,
        /// The base upstream actually uses, stated here independently so a coin
        /// that declares the wrong one can't move the goalposts with it.
        want_base: WinBase,
        /// The final path component the daemon's `--help` names.
        want_name: []const u8,
    };
    const cases = [_]Case{
        // Bitcoin-derived: the roaming `%APPDATA%\<Name>`.
        .{ .name = "bitcoin", .posix = Bitcoin.home_dir, .win = Bitcoin.home_dir_win, .mac = Bitcoin.home_dir_mac, .base = Bitcoin.home_dir_win_base, .want_base = .roaming, .want_name = "Bitcoin" },
        .{ .name = "litecoin", .posix = Litecoin.home_dir, .win = Litecoin.home_dir_win, .mac = Litecoin.home_dir_mac, .base = Litecoin.home_dir_win_base, .want_base = .roaming, .want_name = "Litecoin" },
        .{ .name = "divi", .posix = Divi.home_dir, .win = Divi.home_dir_win, .mac = Divi.home_dir_mac, .base = Divi.home_dir_win_base, .want_base = .roaming, .want_name = "DIVI" },
        .{ .name = "reddcoin", .posix = ReddCoin.home_dir, .win = ReddCoin.home_dir_win, .mac = ReddCoin.home_dir_mac, .base = ReddCoin.home_dir_win_base, .want_base = .roaming, .want_name = "REDDCOIN" },
        .{ .name = "nexa", .posix = Nexa.home_dir, .win = Nexa.home_dir_win, .mac = Nexa.home_dir_mac, .base = Nexa.home_dir_win_base, .want_base = .roaming, .want_name = "NEXA" },
        .{ .name = "digibyte", .posix = DigiByte.home_dir, .win = DigiByte.home_dir_win, .mac = DigiByte.home_dir_mac, .base = DigiByte.home_dir_win_base, .want_base = .roaming, .want_name = "DIGIBYTE" },
        .{ .name = "bitcoinz", .posix = BitcoinZ.home_dir, .win = BitcoinZ.home_dir_win, .mac = BitcoinZ.home_dir_mac, .base = BitcoinZ.home_dir_win_base, .want_base = .roaming, .want_name = "BitcoinZ" },
        .{ .name = "spiderbyte", .posix = SpiderByte.home_dir, .win = SpiderByte.home_dir_win, .mac = SpiderByte.home_dir_mac, .base = SpiderByte.home_dir_win_base, .want_base = .roaming, .want_name = "SpiderByte" },
        // Zano is CryptoNote but does *not* follow Monero here — `zanod --help`
        // names the roaming dir. It sits next to the three that don't precisely so
        // the difference is on the record rather than looking like an oversight.
        .{ .name = "zano", .posix = Zano.home_dir, .win = Zano.home_dir_win, .mac = Zano.home_dir_mac, .base = Zano.home_dir_win_base, .want_base = .roaming, .want_name = "ZANO" },
        // The CryptoNote exception: `%ProgramData%`, per-machine rather than
        // per-user, so `<home>` plays no part in the result at all.
        .{ .name = "monero", .posix = Monero.home_dir, .win = Monero.home_dir_win, .mac = Monero.home_dir_mac, .base = Monero.home_dir_win_base, .want_base = .program_data, .want_name = "bitmonero" },
        .{ .name = "nerva", .posix = Nerva.home_dir, .win = Nerva.home_dir_win, .mac = Nerva.home_dir_mac, .base = Nerva.home_dir_win_base, .want_base = .program_data, .want_name = "nerva" },
        .{ .name = "salvium", .posix = Salvium.home_dir, .win = Salvium.home_dir_win, .mac = Salvium.home_dir_mac, .base = Salvium.home_dir_win_base, .want_base = .program_data, .want_name = "salvium" },
    };

    // Built rather than hardcoded so the expectation holds on a machine that has
    // relocated `%ProgramData%` (off Windows this is the literal default).
    const pd_root = try programDataRoot(allocator);
    defer allocator.free(pd_root);

    for (cases) |c| {
        const want = switch (c.want_base) {
            .roaming => try std.fmt.allocPrint(allocator, "/h/AppData/Roaming/{s}", .{c.want_name}),
            .program_data => try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pd_root, c.want_name }),
        };
        defer allocator.free(want);

        const got = try dataDirFor(allocator, "/h", .windows, c.posix, c.win, c.mac, c.base);
        defer allocator.free(got);

        pathtest.expectEqual(want, got) catch |e| {
            std.debug.print("Windows data dir mismatch for {s}\n", .{c.name});
            return e;
        };
    }
}

test "ensureLines appends only missing lines and keeps the user's own" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dd = "test-conf-ensurelines";
    std.Io.Dir.cwd().deleteTree(io, dd) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dd) catch {};

    // An adopted conf: a comment, the user's own addnode, no trailing newline.
    {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dd, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "x.conf", .data = "# mine\naddnode=1.2.3.4:1989" });
    }

    const wanted = [_][]const u8{ "addnode=1.2.3.4:1989", "addnode=5.6.7.8:1989" };
    try std.testing.expect(try ensureLines(allocator, io, dd, "x.conf", &wanted));

    // Rerun is a no-op — nothing left to add.
    try std.testing.expect(!try ensureLines(allocator, io, dd, "x.conf", &wanted));

    // The user's line survives once, the missing one was appended, comment kept.
    {
        var dir = try std.Io.Dir.cwd().openDir(io, dd, .{});
        defer dir.close(io);
        var f = try dir.openFile(io, "x.conf", .{});
        defer f.close(io);
        var buf: [512]u8 = undefined;
        const n = try f.readPositionalAll(io, &buf, 0);
        const got = buf[0..n];
        try std.testing.expectEqualStrings("# mine\naddnode=1.2.3.4:1989\naddnode=5.6.7.8:1989\n", got);
    }
}
