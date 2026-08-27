//! The registered coins, in one place, in one order.
//!
//! Both front-ends need the same roster, but they used to declare it twice: the
//! TUI's `Entry` enum plus `coin_entries` in `app.zig`, and a parallel set of
//! static instances plus a hand-written `switch` in `capi.zig`. Two lists that
//! must agree and nothing checking that they do — and the C++ side addresses
//! coins by the index this order produces, so a coin inserted in one list and
//! appended to the other would silently point the GUI at the wrong coin.
//!
//! This module owns that order. `capi.zig` derives its whole registry from it;
//! `app.zig` keeps its enum (it needs a `.home` row and per-coin `App` fields)
//! but is pinned to this order by a comptime assertion.
//!
//! **The order is the C ABI.** `gui/main.cpp` stores coin indices, the GUI's
//! logo array is indexed by them, and a user's window can be sitting on one when
//! the app restarts. Append new coins; don't insert.

const std = @import("std");
const Coin = @import("coin.zig").Coin;

const Nexa = @import("coins/nexa.zig").Nexa;
const Divi = @import("coins/divi.zig").Divi;
const Ergo = @import("coins/ergo.zig").Ergo;
const DigiByte = @import("coins/digibyte.zig").DigiByte;
const Zano = @import("coins/zano.zig").Zano;
const Nerva = @import("coins/nerva.zig").Nerva;
const ReddCoin = @import("coins/reddcoin.zig").ReddCoin;
const Epic = @import("coins/epic.zig").Epic;
const Salvium = @import("coins/salvium.zig").Salvium;
const Litecoin = @import("coins/litecoin.zig").Litecoin;
const Bitcoin = @import("coins/bitcoin.zig").Bitcoin;
const BitcoinZ = @import("coins/bitcoinz.zig").BitcoinZ;
const SpiderByte = @import("coins/spiderbyte.zig").SpiderByte;
const Monero = @import("coins/monero.zig").Monero;
const Pivx = @import("coins/pivx.zig").Pivx;

/// Every registered coin backend, in C-ABI index order. Append only.
pub const coin_types = .{
    Nexa,
    Divi,
    Ergo,
    DigiByte,
    Zano,
    Nerva,
    ReddCoin,
    Epic,
    Salvium,
    Litecoin,
    Bitcoin,
    BitcoinZ,
    SpiderByte,
    Monero,
    Pivx,
};

/// How many coins are registered. Every index either front-end passes is in
/// `[0, count)`.
pub const count = coin_types.len;

// Compile-time guard: no two coins may declare the same executable filename.
// Every coin promotes its binaries into the one shared install root
// (`~/.boxwallet`) and `isInstalled` keys off the daemon filename, so a name
// clash would silently overwrite another coin's binary on install and confuse
// install detection. A duplicate — e.g. a future CryptoNote coin shipping a
// stock `simplewallet` like Zano's — fails the build here rather than
// corrupting an install on disk. (Ergo's versioned jar and the Windows subdir
// bundles live outside the shared root, but the promoted daemon/cli/tx/
// wallet-rpc executables all share it, so those four filename decls are what's
// checked.)
//
// This lives here rather than in `app.zig` so *both* front-ends inherit it —
// the clash is a property of the install root, not of the TUI.
comptime {
    // The pairwise scan below is O(names²) in comptime branches, and `names`
    // grows with every coin registered, so the default 1000 doesn't cover the
    // roster.
    @setEvalBranchQuota(20_000);

    const exe_fields = .{ "daemon_file", "cli_file", "tx_file", "wallet_rpc_file" };
    var names: []const []const u8 = &.{};
    for (coin_types) |C| {
        for (exe_fields) |f| {
            if (@hasDecl(C, f)) names = names ++ &[_][]const u8{@field(C, f)};
        }
    }
    for (names, 0..) |a, i| {
        for (names[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b))
                @compileError("two coins declare the same binary filename '" ++ a ++
                    "': they would collide in the shared install root — give one a unique name");
        }
    }
}

fn typeList() [count]type {
    var out: [count]type = undefined;
    for (coin_types, 0..) |C, i| out[i] = C;
    return out;
}

/// One instance per registered coin, as a tuple indexed the same way everything
/// else here is. Every coin backend is a zero-field struct, so a default-init
/// costs nothing and holds no state.
pub const Instances = std.meta.Tuple(&typeList());

/// A fresh set of coin instances. The caller owns them; `coinAt` borrows.
pub fn instances() Instances {
    var out: Instances = undefined;
    inline for (0..count) |i| out[i] = .{};
    return out;
}

/// The `Coin` vtable for registry index `idx`, or null if it isn't one. The
/// `inline for` unrolls to the same jump table the hand-written switch was,
/// without a switch that can fall out of step with the list above.
pub fn coinAt(inst: *Instances, idx: usize) ?Coin {
    inline for (0..count) |i| {
        if (i == idx) return inst[i].coin();
    }
    return null;
}

/// The display name of registry index `idx`, without needing an instance —
/// `coin_name` is a comptime constant on each backend. Empty for a bad index.
pub fn name(idx: usize) []const u8 {
    inline for (coin_types, 0..) |C, i| {
        if (i == idx) return C.coin_name;
    }
    return "";
}

test "every index in range resolves to a coin, and nothing outside it does" {
    var inst = instances();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const coin = coinAt(&inst, i) orelse return error.MissingCoin;
        // The vtable's name and the comptime table must be the same string, or
        // the `name` shortcut would be lying to anyone using it to check order.
        try std.testing.expectEqualStrings(name(i), coin.coinName());
        try std.testing.expect(name(i).len > 0);
    }
    try std.testing.expect(coinAt(&inst, count) == null);
    try std.testing.expectEqualStrings("", name(count));
}

test "coin names are unique" {
    // The GUI verifies its logo array against these names, and the TUI's log
    // pane maps a line's tag back to a coin by name. Two coins sharing one would
    // break both in ways that look like a rendering bug rather than a registry
    // one.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = i + 1;
        while (j < count) : (j += 1) {
            try std.testing.expect(!std.mem.eql(u8, name(i), name(j)));
        }
    }
}
