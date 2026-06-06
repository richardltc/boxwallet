const std = @import("std");
const zz = @import("zigzag");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const Nexa = @import("coins/nexa.zig").Nexa;
const Divi = @import("coins/divi.zig").Divi;

/// Fallback install root used only if the home-dir-based path can't be built
/// (e.g. allocation failure at startup). Normally `App.install_root` is the
/// per-platform `~/.boxwallet` dir resolved in `init`.
const fallback_install_root = "boxwallet-coins";

/// Left-column entries. Index 0 is Home; the rest are coins. Adding a coin is a
/// matter of extending this list, the `App` field + `init`, and the dispatch in
/// `selectedCoin` — the detail pane renders generically through the `Coin`
/// interface, so it needs no per-coin code.
const Entry = enum { home, nexa, divi };
const entries = [_]Entry{ .home, .nexa, .divi };

fn entryLabel(e: Entry) []const u8 {
    return switch (e) {
        .home => "Home",
        .nexa => Nexa.coin_name,
        .divi => Divi.coin_name,
    };
}

/// Outlook-style master/detail TUI: a navigation column on the left (Home +
/// coins), a detail pane on the right. `up`/`down` move the selection, `i`
/// installs the selected coin's daemon, `q` quits.
pub const App = struct {
    /// Persistent (model-lifetime) allocator. Owns `install_root` and backs the
    /// transient work in `isInstalled`. Not the per-frame `ctx.allocator`.
    allocator: std.mem.Allocator,
    /// Per-platform `~/.boxwallet` dir where coin daemons are extracted.
    /// Resolved once in `init` from `ctx.home_dir`; lives for the program.
    install_root: []const u8,
    /// True when `install_root` is heap-allocated (and so must be freed in
    /// `deinit`); false when it's the static `fallback_install_root`.
    install_root_owned: bool,
    nexa: Nexa,
    divi: Divi,
    selected: usize,
    installed: bool,
    status: []const u8,

    pub const Msg = union(enum) { key: zz.KeyEvent };

    pub fn init(self: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        // Resolve ~/.boxwallet (or %USERPROFILE%\AppData\Roaming\BoxWallet on
        // Windows) from the home dir ZigZag captured at startup. Held on the
        // persistent allocator so it outlives the per-frame arena (and is freed
        // in `deinit`); on the unlikely allocation failure, fall back to a
        // relative dir that we don't own.
        var install_root: []const u8 = fallback_install_root;
        var install_root_owned = false;
        if (install_mod.installRoot(ctx.persistent_allocator, ctx.home_dir)) |root| {
            install_root = root;
            install_root_owned = true;
        } else |_| {}

        self.* = .{
            .allocator = ctx.persistent_allocator,
            .install_root = install_root,
            .install_root_owned = install_root_owned,
            .nexa = .{},
            .divi = .{},
            .selected = 0,
            .installed = false,
            .status = "use up/down to navigate",
        };
        return .none;
    }

    /// Called by ZigZag's `Program.deinit` at shutdown. Frees the model's
    /// owned allocations.
    pub fn deinit(self: *App) void {
        if (self.install_root_owned) self.allocator.free(self.install_root);
    }

    pub fn update(self: *App, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    'i' => self.tryInstall(ctx),
                    'k' => self.move(-1),
                    'j' => self.move(1),
                    else => {},
                },
                .up => self.move(-1),
                .down => self.move(1),
                else => {},
            },
        }
        return .none;
    }

    fn move(self: *App, delta: i32) void {
        const n: i32 = @intCast(entries.len);
        var idx: i32 = @intCast(self.selected);
        idx = @max(0, @min(n - 1, idx + delta));
        self.selected = @intCast(idx);
        self.refreshInstalledState();
    }

    /// The coin at the current selection, or null on Home.
    ///
    /// Takes `*const App` so the read-only `view`/`renderDetail` path can use it.
    /// The `coin()` builders want a mutable `*Coin`, but the resulting vtable
    /// only ever reads coin metadata here, and the backing `App` is never const
    /// (it lives mutably inside ZigZag's `Program`), so the `@constCast` is sound.
    fn selectedCoin(self: *const App) ?@import("coin.zig").Coin {
        return switch (entries[self.selected]) {
            .home => null,
            .nexa => @constCast(&self.nexa).coin(),
            .divi => @constCast(&self.divi).coin(),
        };
    }

    fn refreshInstalledState(self: *App) void {
        if (self.selectedCoin()) |coin| {
            self.installed = coin.isInstalled(self.allocator, self.install_root);
            self.status = if (self.installed) "installed — press i to update" else "press i to install";
        } else {
            self.status = "use up/down to navigate";
        }
    }

    fn tryInstall(self: *App, ctx: *zz.Context) void {
        const coin = self.selectedCoin() orelse return;

        // Synchronous — this blocks the UI event loop for the duration of the
        // install. Rather than freeze, `InstallRender` paints download/extract
        // progress bars straight to the terminal as the work reports in.
        const was_installed = self.installed;
        var render: InstallRender = .{ .ctx = ctx, .name = coin.coinName(), .updating = was_installed };
        const progress: install_mod.Progress = .{ .ctx = &render, .func = InstallRender.onProgress };

        if (coin.install(ctx.persistent_allocator, self.install_root, progress)) {
            self.installed = coin.isInstalled(self.allocator, self.install_root);
            self.status = if (self.installed)
                (if (was_installed) "update complete" else "install complete")
            else
                "install ran but daemon not found";
        } else |err| {
            self.status = @errorName(err);
        }
    }

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        return renderTwoPane(a, self.selected, right) catch "render error";
    }

    /// Builds the right-hand detail block for the current selection. The coin
    /// pane is rendered generically through the `Coin` interface, so no per-coin
    /// code lives here — a newly registered coin renders for free.
    fn renderDetail(self: *const App, a: std.mem.Allocator) []const u8 {
        const title = (zz.Style{}).bold(true).fg(.cyan);

        const coin = self.selectedCoin() orelse {
            const head = title.render(a, "BoxWallet") catch "BoxWallet";
            return std.fmt.allocPrint(a,
                \\{s}
                \\
                \\Select a coin on the left to manage it.
                \\
                \\  up/down  navigate
                \\  i        install selected coin
                \\  q        quit
            , .{head}) catch "alloc error";
        };

        const head = title.render(a, coin.coinName()) catch coin.coinName();
        const yn: []const u8 = if (self.installed) "yes" else "no";
        // When the daemon is already present, the action updates it in place
        // rather than doing a first-time install.
        const button = if (self.installed) "[ Update ]" else "[ Install ]";
        return std.fmt.allocPrint(a,
            \\{s}
            \\
            \\daemon   : {s}
            \\rpc port : {s}
            \\location : {s}
            \\installed: {s}
            \\
            \\{s}   (press i)
            \\
            \\status: {s}
        , .{
            head,
            coin.daemonFile(),
            coin.rpcDefaultPort(),
            self.install_root,
            yn,
            button,
            self.status,
        }) catch "alloc error";
    }

    /// Joins the left nav column and the right detail block side by side.
    fn renderTwoPane(a: std.mem.Allocator, selected: usize, right: []const u8) ![]const u8 {
        const col_w = 14;
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();

        var rit = std.mem.splitScalar(u8, right, '\n');
        var i: usize = 0;
        while (true) {
            const have_left = i < entries.len;
            const r = rit.next();
            if (!have_left and r == null) break;

            if (have_left) {
                const marker: []const u8 = if (i == selected) "> " else "  ";
                try out.writer.print("{s}{s: <12}", .{ marker, entryLabel(entries[i]) });
            } else {
                try out.writer.splatByteAll(' ', col_w);
            }
            try out.writer.print(" │ {s}\n", .{r orelse ""});
            i += 1;
        }

        return out.toOwnedSlice();
    }
};

/// Draws live download + extract progress bars to the terminal while a
/// (blocking) install runs. The normal event-loop render is paused for the
/// duration of the install, so this paints straight to the terminal in
/// response to each progress callback; the next frame after install repaints
/// the regular two-pane view over the top.
const InstallRender = struct {
    ctx: *zz.Context,
    name: []const u8,
    /// True when re-installing over an existing daemon, so the heading reads
    /// "Updating" rather than "Installing".
    updating: bool = false,
    dl_cur: u64 = 0,
    dl_total: u64 = 0,
    ex_cur: u64 = 0,
    ex_total: u64 = 0,
    /// Once extraction starts the download is complete; peg its bar to full.
    extract_started: bool = false,

    /// `install_mod.Progress` callback. Records the latest byte counts for the
    /// reported phase and repaints.
    fn onProgress(opaque_ctx: *anyopaque, phase: install_mod.Phase, current: u64, total: u64) void {
        const self: *InstallRender = @ptrCast(@alignCast(opaque_ctx));
        switch (phase) {
            .download => {
                self.dl_cur = current;
                self.dl_total = total;
            },
            .extract => {
                if (!self.extract_started) {
                    self.extract_started = true;
                    if (self.dl_total > 0) self.dl_cur = self.dl_total;
                }
                self.ex_cur = current;
                self.ex_total = total;
            },
        }
        self.paint();
    }

    fn paint(self: *InstallRender) void {
        const term = self.ctx._terminal orelse return;

        // A fresh arena per paint, freed on return, so repeated repaints during
        // a long install don't accumulate. Backed by the persistent allocator
        // (the per-frame arena isn't reset while we're blocking the loop).
        var arena = std.heap.ArenaAllocator.init(self.ctx.persistent_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const screen = self.render(a) catch return;

        const w = term.writer();
        w.writeAll(zz.ansi.sync_start) catch {};
        w.writeAll(zz.ansi.cursor_home) catch {};
        var lines = std.mem.splitScalar(u8, screen, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) w.writeAll("\r\n") catch {};
            first = false;
            w.writeAll(line) catch {};
            w.writeAll(zz.ansi.line_clear_right) catch {};
        }
        // Wipe anything the taller two-pane view left below us.
        w.writeAll(zz.ansi.screen_clear_below) catch {};
        w.writeAll(zz.ansi.sync_end) catch {};
        term.flush() catch {};
    }

    fn render(self: *InstallRender, a: std.mem.Allocator) ![]const u8 {
        const verb: []const u8 = if (self.updating) "Updating" else "Installing";
        const heading = try std.fmt.allocPrint(a, "{s} {s}", .{ verb, self.name });
        const title = (zz.Style{}).bold(true).fg(.cyan).render(a, heading) catch heading;

        const dl_bar = try bar(a, self.dl_cur, self.dl_total);
        const ex_bar = try bar(a, self.ex_cur, self.ex_total);

        return std.fmt.allocPrint(a,
            \\{s}
            \\
            \\  Downloading  {s}
            \\  Extracting   {s}
            \\
            \\  please wait…
        , .{ title, dl_bar, ex_bar });
    }

    /// Render a single ZigZag progress bar for `current`/`total` bytes.
    fn bar(a: std.mem.Allocator, current: u64, total: u64) ![]const u8 {
        var p = zz.Progress.init();
        p.setWidth(30);
        // Guard against a zero total (unknown length) so the bar sits at 0%
        // rather than dividing by zero.
        p.setTotal(@floatFromInt(@max(total, 1)));
        p.setValue(@floatFromInt(current));
        return p.view(a);
    }
};

test "App.init resolves install_root from home dir and deinit frees it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Minimal context: the home dir drives install_root and the persistent
    // allocator owns it. std.testing.allocator fails the test if `deinit`
    // doesn't free what `init` allocated.
    const env: zz.Environment = .{ .home_dir = "/home/tester" };
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    _ = app.init(&ctx);
    defer app.deinit();

    try std.testing.expectEqualStrings("/home/tester/.boxwallet", app.install_root);
    try std.testing.expect(app.install_root_owned);
}

test "renderDetail renders the selected coin generically through the Coin interface" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env: zz.Environment = .{ .home_dir = "/home/tester" };
    var ctx = zz.Context.init(allocator, allocator, io, &env);

    var app: App = undefined;
    _ = app.init(&ctx);
    defer app.deinit();

    // Select Divi and render its detail pane. Nothing in renderDetail is Divi-
    // specific — the coin's name/daemon/port come through the Coin vtable.
    app.selected = std.mem.indexOfScalar(Entry, &entries, .divi).?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const out = app.renderDetail(arena.allocator());

    try std.testing.expect(std.mem.indexOf(u8, out, Divi.coin_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, Divi.daemon_file_lin) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, Divi.rpc_default_port) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/home/tester/.boxwallet") != null);
}
