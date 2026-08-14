//! Which wallet actions a coin offers, and in which state — the policy behind
//! both front-ends' wallet menus.
//!
//! This is not presentation. "May this wallet be backed up right now?" has one
//! answer, and if the TUI and the GUI each decide it themselves they will
//! eventually disagree — offering an action the daemon rejects, or hiding one
//! that would have worked. `capi.zig` used to carry its own copy of the setup-op
//! enum under a comment reading "Mirrors the TUI's `WalletSetupOp`", which is an
//! admission rather than a design.
//!
//! Two different wallet shapes live here, deliberately in one module because a
//! front-end has to pick between them:
//!
//! * **In-daemon** (bitcoin-family): the daemon holds the wallet and the menu is
//!   encrypt / unlock / lock / back up / restore — see `Action` and `optionsFor`.
//! * **Managed** (Monero, Nerva, Salvium, Zano, Epic, Ergo): a separate wallet
//!   process or an in-daemon wallet with its own lifecycle, where the menu is
//!   create / restore / unlock / lock / replace — see `SetupChoice`, `SetupOp`
//!   and `choicesFor`.
//!
//! The labels live here too. They are the one part that looks like presentation
//! but isn't: `restore` and `restore_file_offline` take *different files*, and
//! BitcoinZ offers both at once, so a front-end inventing its own wording is how
//! someone picks the wrong one and ends up with an empty wallet.

const std = @import("std");
const models = @import("models.zig");
const Coin = @import("coin.zig").Coin;

/// Most actions any single wallet state offers.
pub const max_options = 4;
/// Most setup choices a managed wallet's menu offers at once.
pub const max_choices = 3;

/// An operation the in-daemon wallet menu can run against the daemon.
pub const Action = enum(u8) {
    encrypt = 0,
    unlock = 1,
    stake = 2,
    lock = 3,
    /// Back up the wallet to a file (bitcoin-core `dumpwallet`).
    backup = 4,
    /// Restore the wallet from a backup file (bitcoin-core `importwallet`).
    restore = 5,
    /// Restore the wallet by swapping in a backup file with the daemon stopped
    /// (a binary `wallet.dat` — SpiderByte, whose daemon has no `importwallet`;
    /// BitcoinZ, which offers it alongside the key-dump import).
    restore_file_offline = 6,

    /// The menu label for the action.
    ///
    /// The two restores name the *file each takes*, not the mechanism, because
    /// BitcoinZ offers both at once and "Restore from file" / "Restore from a
    /// wallet file" were indistinguishable in that menu — picking the wrong one
    /// is exactly the mistake that ends in an empty wallet. Every coin wiring
    /// `restore` uses bitcoin-core `importwallet` (a `dumpwallet` *text* file),
    /// and every coin wiring `restore_file_offline` swaps a binary `wallet.dat`,
    /// so both labels hold for all of them.
    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .encrypt => "Encrypt wallet",
            .unlock => "Unlock",
            .stake => "Unlock for staking",
            .lock => "Lock wallet",
            .backup => "Back up wallet",
            .restore => "Restore from key dump",
            .restore_file_offline => "Restore from wallet.dat",
        };
    }

    /// Whether the action needs a passphrase entered first. `lock` doesn't, and
    /// neither do `backup`/`restore` — they run against an already-unlocked
    /// wallet and set no new credential (so no entry and no confirmation step).
    /// The offline file restore is a daemon-stopped file swap and takes no
    /// password.
    pub fn needsPassword(self: Action) bool {
        return switch (self) {
            .encrypt, .unlock, .stake => true,
            .lock, .backup, .restore, .restore_file_offline => false,
        };
    }

    /// Whether the action *sets* a new wallet password, so the front-end must
    /// ask for it twice and refuse on mismatch. A mistyped password on a wallet
    /// that is being encrypted for the first time makes the funds unrecoverable;
    /// a mistyped one when merely unlocking just fails and is retried.
    pub fn setsNewPassword(self: Action) bool {
        return self == .encrypt;
    }

    /// Whether the action takes a filesystem path rather than a password.
    pub fn needsPath(self: Action) bool {
        return switch (self) {
            .backup, .restore, .restore_file_offline => true,
            .encrypt, .unlock, .stake, .lock => false,
        };
    }
};

/// What a coin's daemon supports, so `optionsFor` can keep an action that could
/// only ever fail off the menu.
pub const Caps = struct {
    /// Proof-of-stake: offers unlock-for-staking alongside a plain unlock.
    proof_of_stake: bool = false,
    /// `encryptwallet` works. BitcoinZ's zcashd lineage ships it disabled.
    encrypt: bool = false,
    /// `dumpwallet` — back up to a key dump.
    backup: bool = false,
    /// `importwallet` — restore from a key dump, online.
    import: bool = false,
    /// Swap in a binary wallet file with the daemon stopped.
    restore_offline: bool = false,

    /// Read the capabilities straight off a coin's vtable, so a front-end never
    /// assembles this by hand.
    pub fn of(coin: Coin) Caps {
        return .{
            .proof_of_stake = coin.isProofOfStake(),
            .encrypt = coin.supportsWalletEncrypt(),
            .backup = coin.supportsWalletBackup(),
            .import = coin.supportsWalletImport(),
            .restore_offline = coin.supportsWalletRestoreOffline(),
        };
    }
};

/// Which actions the wallet menu offers for a given security state, written into
/// `buf` and returned by count.
///
/// Unencrypted → encrypt; locked → unlock (plus unlock-for-staking on
/// proof-of-stake coins); unlocked → lock.
///
/// Backup/restore are offered only while the wallet is reachable for a key dump
/// — unencrypted or unlocked, never locked, because the daemon rejects
/// `dumpwallet`/`importwallet` on a locked wallet. The *offline* file restore is
/// a daemon-stopped file swap, so it needs no live or unlocked wallet and is
/// offered in every state, locked and **unknown** included.
///
/// That last one is the whole point of it. Every other action is decided by what
/// the daemon says it holds, so `unknown` offers none of them — a menu built on a
/// guess is a menu that can destroy a wallet. But `unknown` is exactly what a
/// *stopped* daemon reads as (there's no RPC to ask), and the offline restore is
/// the one action that **requires** the daemon stopped. Excluding it here made it
/// unreachable in both front-ends: greyed out while the daemon was down, and
/// refused by the restore itself once it was up.
///
/// Offering it in `unknown` doesn't guess at anything — it's a file swap, not a
/// wallet operation: it depends on no lock state, refuses a key dump or an empty
/// file, and keeps the wallet it replaces aside under a timestamped name (see
/// `walletfile.restoreOffline`).
pub fn optionsFor(
    state: models.WalletSecurity,
    caps: Caps,
    buf: *[max_options]Action,
) usize {
    var n: usize = 0;
    switch (state) {
        .unencrypted => {
            if (caps.encrypt) {
                buf[n] = .encrypt;
                n += 1;
            }
            if (caps.backup) {
                buf[n] = .backup;
                n += 1;
            }
            if (caps.import) {
                buf[n] = .restore;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
        },
        .locked => {
            buf[n] = .unlock;
            n += 1;
            if (caps.proof_of_stake) {
                buf[n] = .stake;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
        },
        .unlocked, .unlocked_for_staking => {
            buf[n] = .lock;
            n += 1;
            if (caps.backup) {
                buf[n] = .backup;
                n += 1;
            }
            if (caps.import) {
                buf[n] = .restore;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
        },
        // Nothing that depends on what the daemon holds is offered until it has
        // said — a menu built on a guess is a menu that can destroy a wallet.
        // The offline file restore doesn't depend on it, and a stopped daemon
        // (which is what it needs) always reads as unknown, so it is offered.
        .unknown => {
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
        },
    }
    return n;
}

// ---- managed wallets --------------------------------------------------------

/// An operation against a coin's managed wallet.
pub const SetupOp = enum(u8) {
    /// Create a brand-new wallet (returns a mnemonic seed to display).
    create = 0,
    /// Restore a wallet from a mnemonic seed (length per coin — see
    /// `ExternalWallet.seed_word_counts`).
    restore_seed = 1,
    /// Import an existing wallet file browsed to with the file picker.
    restore_file = 2,
    /// Open the existing managed wallet (unlock it for this session).
    open = 3,
    /// Re-lock an open wallet (in-daemon wallets that stay open while the daemon
    /// runs, e.g. Ergo; the process-backed coins lock by killing their process).
    lock = 4,

    pub fn verb(self: SetupOp) []const u8 {
        return switch (self) {
            .create => "Create wallet",
            .restore_seed => "Restore from seed",
            .restore_file => "Restore from file",
            .open => "Unlock wallet",
            .lock => "Lock wallet",
        };
    }

    /// Whether this op *sets* a new wallet password, so the UI asks the user to
    /// confirm it. `open` checks an existing password — a typo there just fails
    /// to unlock and is retried, so no confirmation is needed; `lock` takes none.
    /// `restore_file` also takes an *existing* password, not a new one: the
    /// imported wallet file is already encrypted with its own password, and the
    /// coin opens the copied file with it (a wrong one just fails to decrypt and
    /// is retried), so — like `open` — it's a single unconfirmed prompt.
    pub fn setsNewPassword(self: SetupOp) bool {
        return self == .create or self == .restore_seed;
    }

    /// Whether an *empty* password is a valid entry for this op. Opening or
    /// restoring an existing wallet file must accept a blank password, because
    /// the wallet may have been created elsewhere with no encryption — the user
    /// then submits the empty prompt deliberately (still explicit, never
    /// silent). Ops that *set* a new credential keep requiring a non-empty
    /// password, so a fresh wallet is never left unprotected by accident.
    pub fn allowsEmptyPassword(self: SetupOp) bool {
        return self == .open or self == .restore_file;
    }
};

/// A row on a managed wallet's setup menu.
pub const SetupChoice = enum(u8) {
    create = 0,
    restore_seed = 1,
    restore_file = 2,
    unlock = 3,
    lock = 4,
    /// Destructively remove the current wallet to create/restore a different one.
    replace = 5,

    pub fn label(self: SetupChoice) []const u8 {
        return switch (self) {
            .create => "Create a new wallet",
            .restore_seed => "Restore from seed words",
            .restore_file => "Restore from a wallet file",
            .unlock => "Unlock wallet",
            .lock => "Lock wallet",
            .replace => "Replace wallet…",
        };
    }
};

/// Fill `buf` with the setup-menu choices for `coin`'s managed wallet, in
/// display order, returning the count. Create is always offered;
/// restore-from-seed and restore-from-file only where the coin wires them
/// (Zano's seed restore is interactive-only upstream and deferred, so its menu
/// skips straight to create / restore-file; Ergo's wallet lives in the daemon
/// and has no portable file).
pub fn choicesFor(coin: Coin, buf: *[max_choices]SetupChoice) usize {
    const ew = coin.externalWallet() orelse return 0;
    var n: usize = 0;
    buf[n] = .create;
    n += 1;
    if (coin.supportsSeedRestore()) {
        buf[n] = .restore_seed;
        n += 1;
    }
    if (ew.restore_file != null) {
        buf[n] = .restore_file;
        n += 1;
    }
    return n;
}

test "an unknown wallet state offers nothing that depends on the daemon" {
    // The daemon hasn't said what it holds yet, so every action decided by that
    // is withheld — a menu built on the guess is a menu that can destroy a
    // wallet. Only the offline file swap, which asks the daemon nothing and needs
    // it stopped, survives (see the dedicated test below).
    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
    };
    const n = optionsFor(.unknown, all, &buf);
    for (buf[0..n]) |act| {
        try std.testing.expectEqual(Action.restore_file_offline, act);
    }
}

test "each wallet state offers the actions that fit it" {
    var buf: [max_options]Action = undefined;
    const full: Caps = .{ .encrypt = true, .backup = true, .import = true };

    // Unencrypted: offer to encrypt, and the key-dump pair (the wallet is
    // readable).
    var n = optionsFor(.unencrypted, full, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Action.encrypt, buf[0]);
    try std.testing.expectEqual(Action.backup, buf[1]);
    try std.testing.expectEqual(Action.restore, buf[2]);

    // Locked: unlock only. Backup and restore are absent because the daemon
    // rejects dumpwallet/importwallet on a locked wallet — offering them would
    // be offering a guaranteed failure.
    n = optionsFor(.locked, full, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Action.unlock, buf[0]);

    // Unlocked: lock, plus the key-dump pair again.
    n = optionsFor(.unlocked, full, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Action.lock, buf[0]);

    // Unlocked-for-staking behaves as unlocked.
    n = optionsFor(.unlocked_for_staking, full, &buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Action.lock, buf[0]);
}

test "proof-of-stake adds unlock-for-staking, and only when locked" {
    var buf: [max_options]Action = undefined;
    const pos: Caps = .{ .proof_of_stake = true };

    var n = optionsFor(.locked, pos, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Action.unlock, buf[0]);
    try std.testing.expectEqual(Action.stake, buf[1]);

    // Already unlocked — there is nothing to unlock *for* staking.
    n = optionsFor(.unlocked, pos, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Action.lock, buf[0]);
}

test "a daemon that can't encrypt is never offered encryption" {
    // BitcoinZ's zcashd lineage ships encryptwallet disabled. Offering it would
    // be offering an action that can only fail.
    var buf: [max_options]Action = undefined;
    const n = optionsFor(.unencrypted, .{ .encrypt = false, .backup = true }, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Action.backup, buf[0]);
}

test "the offline file restore is offered in every state, unknown included" {
    // It is a daemon-stopped file swap, so unlike the key-dump pair it needs no
    // live or unlocked wallet — and `unknown` is what a stopped daemon reads as,
    // so leaving it out of that state is what made it unreachable.
    var buf: [max_options]Action = undefined;
    const caps: Caps = .{ .restore_offline = true };
    for (std.enums.values(models.WalletSecurity)) |state| {
        const n = optionsFor(state, caps, &buf);
        var found = false;
        for (buf[0..n]) |a| {
            if (a == .restore_file_offline) found = true;
        }
        try std.testing.expect(found);
    }
}

test "unknown offers the offline restore and nothing else" {
    // Every other action is decided by what the daemon says it holds, and in
    // this state it has said nothing — offering one would be a guess.
    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
    };
    const n = optionsFor(.unknown, all, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Action.restore_file_offline, buf[0]);

    // …and a coin without the offline restore still gets no menu at all.
    try std.testing.expectEqual(@as(usize, 0), optionsFor(.unknown, .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
    }, &buf));
}

test "no state ever overflows the option buffer" {
    // `max_options` sizes every caller's array; a state that could exceed it
    // would be a stack overwrite rather than a truncated menu.
    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
    };
    for ([_]models.WalletSecurity{ .unknown, .unencrypted, .locked, .unlocked, .unlocked_for_staking }) |state| {
        try std.testing.expect(optionsFor(state, all, &buf) <= max_options);
    }
}

test "every action and setup choice has a non-empty label" {
    // A blank row in a wallet menu is unpickable and unreportable.
    for (std.enums.values(Action)) |a| {
        try std.testing.expect(a.label().len > 0);
    }
    for (std.enums.values(SetupChoice)) |c| {
        try std.testing.expect(c.label().len > 0);
    }
    for (std.enums.values(SetupOp)) |o| {
        try std.testing.expect(o.verb().len > 0);
    }
}

test "only the credential-setting ops ask for confirmation" {
    // Getting this wrong in either direction is a real cost: no confirmation on
    // a new password can make funds unrecoverable, and a confirmation on an
    // existing one is a pointless second prompt.
    try std.testing.expect(SetupOp.create.setsNewPassword());
    try std.testing.expect(SetupOp.restore_seed.setsNewPassword());
    try std.testing.expect(!SetupOp.open.setsNewPassword());
    try std.testing.expect(!SetupOp.restore_file.setsNewPassword());
    try std.testing.expect(!SetupOp.lock.setsNewPassword());

    try std.testing.expect(Action.encrypt.setsNewPassword());
    try std.testing.expect(!Action.unlock.setsNewPassword());
    try std.testing.expect(!Action.stake.setsNewPassword());
}

test "opening an existing wallet accepts a blank password; setting one does not" {
    // A wallet created elsewhere may have no encryption at all, so opening must
    // accept an empty prompt the user submits deliberately. Creating one must
    // not, or a fresh wallet ends up unprotected by accident.
    try std.testing.expect(SetupOp.open.allowsEmptyPassword());
    try std.testing.expect(SetupOp.restore_file.allowsEmptyPassword());
    try std.testing.expect(!SetupOp.create.allowsEmptyPassword());
    try std.testing.expect(!SetupOp.restore_seed.allowsEmptyPassword());
}

test "password and path actions are disjoint" {
    // Every action takes one or the other, never both — the front-ends switch on
    // exactly this to decide which prompt to show.
    for (std.enums.values(Action)) |a| {
        try std.testing.expect(!(a.needsPassword() and a.needsPath()));
    }
    try std.testing.expect(Action.backup.needsPath());
    try std.testing.expect(Action.restore.needsPath());
    try std.testing.expect(Action.restore_file_offline.needsPath());
    try std.testing.expect(!Action.lock.needsPassword());
    try std.testing.expect(!Action.lock.needsPath());
}
