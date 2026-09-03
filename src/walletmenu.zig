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

/// Most actions any single wallet state offers. The worst case is a coin wiring
/// every capability at once: unencrypted → encrypt + backup + restore + show-seed
/// + the two daemon-stopped restores (file swap and seed). `optionsFor` writes
/// straight into a `[max_options]Action`, so this must not be under-counted —
/// there is a test that holds it to the real worst case.
pub const max_options = 6;
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
    /// Restore the in-daemon wallet from a BIP39 mnemonic, with the daemon
    /// stopped (Divi, whose divid mints an HD wallet from a `mnemonic=` it reads
    /// at startup). Like `restore_file_offline` this replaces the wallet file, so
    /// it shares that action's daemon-stopped orchestration — it just takes words
    /// instead of a path.
    restore_seed = 7,
    /// Show the wallet's own recovery seed so the user can write it down. The
    /// counterpart of `restore_seed`, and the half that was missing: a coin that
    /// can restore from a phrase but never shows you yours has a backup story
    /// with a hole in the middle.
    backup_seed = 8,

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
            .restore_seed => "Restore from seed words",
            .backup_seed => "Show recovery seed",
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
            .lock, .backup, .restore, .restore_file_offline, .restore_seed, .backup_seed => false,
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
            .encrypt, .unlock, .stake, .lock, .restore_seed, .backup_seed => false,
        };
    }

    /// Whether the action takes a mnemonic seed rather than a password or a
    /// path, so the front-end opens seed entry instead of the passphrase prompt
    /// or the file picker.
    pub fn needsSeed(self: Action) bool {
        return self == .restore_seed;
    }

    /// Whether the action needs the daemon **stopped** — it replaces the wallet
    /// file, which a running daemon holds open. Both offline restores do, and
    /// they share one orchestration in each front-end because of it.
    pub fn needsDaemonStopped(self: Action) bool {
        return switch (self) {
            .restore_file_offline, .restore_seed => true,
            .encrypt, .unlock, .stake, .lock, .backup, .restore, .backup_seed => false,
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
    /// Rebuild the wallet from a BIP39 mnemonic, with the daemon stopped.
    restore_seed: bool = false,
    /// Can show the wallet's recovery seed. Needs a *readable* wallet — the
    /// daemon refuses on a locked one — so it goes with the key-dump pair rather
    /// than with the daemon-stopped restores.
    backup_seed: bool = false,
    /// The backup is a **file copy** (`backupwallet`), so it works on a locked
    /// wallet too — unlike a key dump, which the daemon refuses while locked.
    backup_locked: bool = false,

    /// Read the capabilities straight off a coin's vtable, so a front-end never
    /// assembles this by hand.
    pub fn of(coin: Coin) Caps {
        return .{
            .proof_of_stake = coin.isProofOfStake(),
            .encrypt = coin.supportsWalletEncrypt(),
            .backup = coin.supportsWalletBackup(),
            .import = coin.supportsWalletImport(),
            .restore_offline = coin.supportsWalletRestoreOffline(),
            .restore_seed = coin.supportsWalletRestoreSeed(),
            .backup_locked = coin.supportsWalletBackup() and coin.backupKind() == .file_copy,
            .backup_seed = coin.supportsSeedBackup(),
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
/// `dumpwallet`/`importwallet` on a locked wallet. **Unlocked-for-staking counts
/// as locked for this purpose**: the keys are open to the staking thread only,
/// and anything that would reveal or add one is still refused. The *offline* file restore is
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
            // Same requirement as the key dump — a readable wallet — so it sits
            // with that pair and is absent while locked.
            if (caps.backup_seed) {
                buf[n] = .backup_seed;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
            if (caps.restore_seed) {
                buf[n] = .restore_seed;
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
            // A file-copy backup works on a locked wallet (the keys stay
            // encrypted in the copy), so withholding it here would mean
            // encrypting your wallet cost you the ability to back it up. A key
            // dump genuinely can't run locked and stays absent.
            if (caps.backup_locked) {
                buf[n] = .backup;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
            if (caps.restore_seed) {
                buf[n] = .restore_seed;
                n += 1;
            }
        },
        .unlocked => {
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
            // Same requirement as the key dump — a readable wallet — so it sits
            // with that pair and is absent while locked.
            if (caps.backup_seed) {
                buf[n] = .backup_seed;
                n += 1;
            }
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
            if (caps.restore_seed) {
                buf[n] = .restore_seed;
                n += 1;
            }
        },
        // An unlock *for staking* is not a general unlock, and treating it as one
        // was wrong: the daemon opens the keys for the staking thread only and
        // still refuses everything that would reveal or add one. Verified against
        // divid 3.0.0 while `encryption_status` read `unlocked-for-staking` —
        // `dumphdinfo`, `dumpprivkey` and `importprivkey` all answer -13 ("Please
        // enter the wallet passphrase"), while `backupwallet` writes its file
        // happily. So this state gets the key-free actions only.
        //
        // A plain unlock leads the list because it is the way *out* of here: a
        // full `walletpassphrase` escalates straight from staking-unlocked to
        // unlocked (verified) with no need to lock first, and it is what someone
        // who came looking for their seed actually needs.
        .unlocked_for_staking => {
            buf[n] = .unlock;
            n += 1;
            buf[n] = .lock;
            n += 1;
            // A file copy reveals no keys, so it works here exactly as it does
            // when locked. A key dump does not.
            if (caps.backup and caps.backup_locked) {
                buf[n] = .backup;
                n += 1;
            }
            // Both of these need the daemon *stopped*, so the lock state is
            // irrelevant to them.
            if (caps.restore_offline) {
                buf[n] = .restore_file_offline;
                n += 1;
            }
            if (caps.restore_seed) {
                buf[n] = .restore_seed;
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
            if (caps.restore_seed) {
                buf[n] = .restore_seed;
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

    // Unlocked-for-staking does NOT behave as unlocked: divid opens the keys to
    // the staking thread only and still refuses dumpwallet/importwallet (-13), so
    // the key-dump pair stays off the menu. A plain unlock leads instead — it
    // escalates straight to a full unlock, which is the way to reach them.
    n = optionsFor(.unlocked_for_staking, full, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Action.unlock, buf[0]);
    try std.testing.expectEqual(Action.lock, buf[1]);
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

test "the seed restore is offered in every state, unknown included" {
    // Like the file swap it is a daemon-stopped wallet replacement, so it does
    // not depend on what the daemon says it holds — and `unknown` is exactly what
    // a stopped daemon reads as, which is the state the action needs.
    var buf: [max_options]Action = undefined;
    const caps: Caps = .{ .restore_seed = true };
    for (std.enums.values(models.WalletSecurity)) |state| {
        const n = optionsFor(state, caps, &buf);
        var found = false;
        for (buf[0..n]) |a| {
            if (a == .restore_seed) found = true;
        }
        try std.testing.expect(found);
    }
}

test "a coin without a seed restore is never offered one" {
    var buf: [max_options]Action = undefined;
    const caps: Caps = .{ .encrypt = true, .backup = true, .import = true, .restore_offline = true };
    for (std.enums.values(models.WalletSecurity)) |state| {
        const n = optionsFor(state, caps, &buf);
        for (buf[0..n]) |a| {
            try std.testing.expect(a != .restore_seed);
        }
    }
}

test "every action asks for at most one thing, and only the file-replacing ones need the daemon down" {
    // A front-end picks its prompt from these three predicates; two true at once
    // means it cannot tell which to raise. And `needsDaemonStopped` must line up
    // with the actions `optionsFor` is willing to offer in `unknown` — that is
    // the invariant that keeps a stopped-daemon menu honest.
    for (std.enums.values(Action)) |a| {
        var shapes: usize = 0;
        if (a.needsPassword()) shapes += 1;
        if (a.needsPath()) shapes += 1;
        if (a.needsSeed()) shapes += 1;
        try std.testing.expect(shapes <= 1);
        // A label is what makes the row renderable at all.
        try std.testing.expect(a.label().len > 0);
    }

    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
        .restore_seed = true,
    };
    const n = optionsFor(.unknown, all, &buf);
    try std.testing.expect(n > 0);
    for (buf[0..n]) |a| try std.testing.expect(a.needsDaemonStopped());
}

test "max_options really is the worst case a state can produce" {
    // `optionsFor` writes straight into a fixed buffer, so an under-count is a
    // buffer overrun rather than a missing row.
    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
        .restore_seed = true,
    };
    for (std.enums.values(models.WalletSecurity)) |state| {
        try std.testing.expect(optionsFor(state, all, &buf) <= max_options);
    }
}

test "a file-copy backup survives a locked wallet; a key dump doesn't" {
    // Encrypting your wallet must not cost you the ability to back it up. The
    // distinction is the backup's mechanism, not the coin.
    var buf: [max_options]Action = undefined;

    const file_copy: Caps = .{ .backup = true, .backup_locked = true };
    var n = optionsFor(.locked, file_copy, &buf);
    var found = false;
    for (buf[0..n]) |a| {
        if (a == .backup) found = true;
    }
    try std.testing.expect(found);

    // A key dump genuinely can't run on a locked wallet, so it stays hidden —
    // offering it would be offering a guaranteed failure.
    const key_dump: Caps = .{ .backup = true, .backup_locked = false };
    n = optionsFor(.locked, key_dump, &buf);
    for (buf[0..n]) |a| {
        try std.testing.expect(a != .backup);
    }
    // …but it is still offered in the states where the wallet is readable.
    n = optionsFor(.unlocked, key_dump, &buf);
    found = false;
    for (buf[0..n]) |a| {
        if (a == .backup) found = true;
    }
    try std.testing.expect(found);
}

test "showing the seed needs a readable wallet, like a key dump does" {
    // dumphdinfo is refused on a locked wallet, so the action belongs with the
    // key-dump pair rather than with the daemon-stopped restores.
    var buf: [max_options]Action = undefined;
    const caps: Caps = .{ .backup_seed = true };

    for ([_]models.WalletSecurity{ .unencrypted, .unlocked }) |state| {
        const n = optionsFor(state, caps, &buf);
        var found = false;
        for (buf[0..n]) |a| {
            if (a == .backup_seed) found = true;
        }
        try std.testing.expect(found);
    }
    // Staking-unlocked belongs with locked here, not with unlocked: dumphdinfo
    // answers -13 in that state (verified on divid 3.0.0), so offering it would
    // be offering a guaranteed failure.
    for ([_]models.WalletSecurity{ .locked, .unknown, .unlocked_for_staking }) |state| {
        const n = optionsFor(state, caps, &buf);
        for (buf[0..n]) |a| {
            try std.testing.expect(a != .backup_seed);
        }
    }
}

test "a coin that can restore from a seed can also show one" {
    // The gap this closes: restoring from a phrase the user was never given is a
    // backup story with a hole in the middle. Any coin offering the restore must
    // offer the backup too, or its own wallets are unrecoverable.
    const registry = @import("registry.zig");
    var inst: registry.Instances = registry.instances();
    var i: usize = 0;
    while (i < registry.count) : (i += 1) {
        const c = registry.coinAt(&inst, i) orelse continue;
        if (c.supportsWalletRestoreSeed()) {
            try std.testing.expect(c.supportsSeedBackup());
        }
    }
}

test "a staking-only unlock is offered nothing that touches a key" {
    // The bug this pins: unlocked-for-staking was folded in with unlocked, so the
    // menu offered "Show recovery seed" (and the key-dump backup/restore) in a
    // state where divid refuses all three with -13. Verified against divid 3.0.0:
    // dumphdinfo, dumpprivkey and importprivkey are all rejected while
    // encryption_status reads "unlocked-for-staking"; backupwallet succeeds.
    var buf: [max_options]Action = undefined;
    const all: Caps = .{
        .proof_of_stake = true,
        .encrypt = true,
        .backup = true,
        .import = true,
        .restore_offline = true,
        .restore_seed = true,
        .backup_seed = true,
        .backup_locked = true,
    };
    const n = optionsFor(.unlocked_for_staking, all, &buf);
    for (buf[0..n]) |a| {
        try std.testing.expect(a != .backup_seed);
        try std.testing.expect(a != .restore);
    }

    // The escape hatch has to be there, or a staking user can never reach their
    // seed at all: a full walletpassphrase escalates straight out of this state.
    try std.testing.expectEqual(Action.unlock, buf[0]);

    // A key-dump backup is withheld too, but a file copy survives — it reveals
    // no key, and backupwallet is verified to work in this state.
    var found_backup = false;
    for (buf[0..n]) |a| {
        if (a == .backup) found_backup = true;
    }
    try std.testing.expect(found_backup);

    var key_dump: Caps = all;
    key_dump.backup_locked = false;
    const kn = optionsFor(.unlocked_for_staking, key_dump, &buf);
    for (buf[0..kn]) |a| {
        try std.testing.expect(a != .backup);
    }
}
