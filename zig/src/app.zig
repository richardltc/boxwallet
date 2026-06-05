const std = @import("std");
const zz = @import("zigzag");
const models = @import("models.zig");
const Nexa = @import("coins/nexa.zig").Nexa;

/// Where daemon binaries get installed. A real version would derive
/// ~/.boxwallet from HOME (available via `init.environ_map`); the slice uses a
/// fixed relative dir.
const install_root = "boxwallet-coins";

/// Left-column entries. Index 0 is Home; the rest are coins. Adding a coin to
/// the port is (eventually) a matter of extending this list + the dispatch in
/// `selectedCoin`.
const Entry = enum { home, nexa };
const entries = [_]Entry{ .home, .nexa };

fn entryLabel(e: Entry) []const u8 {
    return switch (e) {
        .home => "Home",
        .nexa => Nexa.coin_name,
    };
}

/// Outlook-style master/detail TUI: a navigation column on the left (Home +
/// coins), a detail pane on the right. `up`/`down` move the selection, `i`
/// installs the selected coin's daemon, `q` quits.
pub const App = struct {
    allocator: std.mem.Allocator,
    nexa: Nexa,
    selected: usize,
    installed: bool,
    status: []const u8,

    pub const Msg = union(enum) { key: zz.KeyEvent };

    pub fn init(self: *App, ctx: *zz.Context) zz.Cmd(Msg) {
        self.* = .{
            .allocator = ctx.allocator,
            .nexa = .{},
            .selected = 0,
            .installed = false,
            .status = "use up/down to navigate",
        };
        return .none;
    }

    pub fn update(self: *App, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .char => |c| switch (c) {
                    'q' => return .quit,
                    'i' => self.tryInstall(),
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
    fn selectedCoin(self: *App) ?@import("coin.zig").Coin {
        return switch (entries[self.selected]) {
            .home => null,
            .nexa => self.nexa.coin(),
        };
    }

    fn refreshInstalledState(self: *App) void {
        if (self.selectedCoin()) |coin| {
            self.installed = coin.isInstalled(self.allocator, install_root);
            self.status = if (self.installed) "installed — press i to reinstall" else "press i to install";
        } else {
            self.status = "use up/down to navigate";
        }
    }

    fn tryInstall(self: *App) void {
        const coin = self.selectedCoin() orelse return;
        // NOTE: synchronous — this blocks the UI thread during download. A real
        // version would dispatch it as a Cmd and stream progress.
        if (coin.install(self.allocator, install_root)) {
            self.installed = coin.isInstalled(self.allocator, install_root);
            self.status = if (self.installed) "install complete" else "install ran but daemon not found";
        } else |err| {
            self.status = @errorName(err);
        }
    }

    pub fn view(self: *const App, ctx: *const zz.Context) []const u8 {
        const a = ctx.allocator;

        const right = self.renderDetail(a);
        return renderTwoPane(a, self.selected, right) catch "render error";
    }

    /// Builds the right-hand detail block for the current selection.
    fn renderDetail(self: *const App, a: std.mem.Allocator) []const u8 {
        const title = (zz.Style{}).bold(true).fg(.cyan);
        switch (entries[self.selected]) {
            .home => {
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
            },
            .nexa => {
                const head = title.render(a, "NEXA") catch "NEXA";
                const yn: []const u8 = if (self.installed) "yes" else "no";
                const button = if (self.installed)
                    "[ Reinstall ]"
                else
                    "[ Install ]";
                return std.fmt.allocPrint(a,
                    \\{s}
                    \\
                    \\daemon   : {s}
                    \\rpc port : {s}
                    \\installed: {s}
                    \\
                    \\{s}   (press i)
                    \\
                    \\status: {s}
                , .{
                    head,
                    Nexa.daemon_file_lin,
                    Nexa.rpc_default_port,
                    yn,
                    button,
                    self.status,
                }) catch "alloc error";
            },
        }
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
