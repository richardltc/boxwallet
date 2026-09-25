const std = @import("std");
const models = @import("models.zig");
const install_mod = @import("install.zig");
const money = @import("money.zig");
const price = @import("price.zig");

/// Runtime-polymorphic handle to a coin backend — the Zig equivalent of the
/// Go `Coin` interface in `coins.go`. A frontend (the ZigZag TUI) holds a
/// `Coin` and drives any of the ~30 coins through it without knowing which
/// concrete type backs it.
///
/// Each concrete coin exposes a `coin()` method returning one of these,
/// pairing a type-erased `*Self` pointer with a static vtable.
pub const Coin = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    /// An **external wallet** capability — a wallet whose setup model is the
    /// Monero/CryptoNote shape: *create returns a mnemonic to back up*, restore
    /// from seed, unlock with a password. It backs the setup UI (the create /
    /// restore / unlock / seed-display modal). Two backings are supported:
    ///
    ///   * **Separate process** (Nerva, Zano): the wallet is its own RPC process,
    ///     not part of the daemon. `process_argv`/`rpc_port` are set, so BoxWallet
    ///     launches and manages that process (bound to `rpc_port` on localhost)
    ///     alongside the daemon. The `wallet_auth` passed to the hooks is the
    ///     wallet process's own endpoint (127.0.0.1 + `rpc_port`), with per-session
    ///     credentials, distinct from the daemon's `CoinAuth`.
    ///   * **In-daemon** (Ergo): the wallet lives in the daemon itself, reached
    ///     over the same RPC/REST endpoint. `process_argv` (and `rpc_port`) are
    ///     left null — BoxWallet spawns no separate process, and the wallet is
    ///     "ready" whenever the daemon is running. The `wallet_auth` passed to the
    ///     hooks is the daemon's own endpoint; a coin whose in-daemon wallet RPC
    ///     needs real auth resolves it inside its hooks (Ergo uses a fixed
    ///     api_key), so the hooks may ignore `wallet_auth`.
    ///
    /// Bitcoin-derived coins leave `external_wallet` null and use the in-daemon
    /// wallet hooks instead (`ensure_wallet`/`wallet_security_state`/
    /// `wallet_balance`).
    ///
    /// Optional, bounded sink an external-wallet op fills with the daemon's own
    /// failure message before returning an error, so the UI/log can show *why* a
    /// create/restore/open failed rather than a bare error name. Pre-sized (no
    /// allocation), reset by the caller before each op.
    /// What a coin's wallet backup actually produces, which decides when the
    /// action can be offered.
    ///
    /// `key_dump` is bitcoin-core `dumpwallet`: it reads the private keys out, so
    /// the daemon refuses it on a **locked** wallet. `file_copy` is
    /// `backupwallet`: it copies the wallet file, keys still encrypted, and works
    /// in every lock state.
    ///
    /// The distinction is load-bearing rather than cosmetic. Withholding backup
    /// while locked is right for a key dump and exactly wrong for a file copy —
    /// it means encrypting your wallet takes away your ability to back it up,
    /// which punishes the safer configuration.
    pub const BackupKind = enum { key_dump, file_copy };

    /// Everything a user needs written down to rebuild an HD wallet from nothing.
    ///
    /// Three fields rather than one string because they are not interchangeable
    /// and a user who conflates them loses the funds: the words alone are useless
    /// if a passphrase was set, and a wallet restored from a raw seed has **no
    /// words at all** (divid's `dumphdinfo` returns an empty mnemonic for one), so
    /// the hex is the only thing there is to write down in that case.
    ///
    /// All three are secrets. Callers hold this in a bounded, wiped buffer and
    /// never log or persist it.
    pub const SeedBackup = struct {
        /// The BIP39 mnemonic, empty when the wallet has none.
        words: models.Seed = .{},
        /// The BIP39 passphrase, empty when there is none. Useless to show on its
        /// own and fatal to omit when set.
        passphrase: models.Seed = .{},
        /// The raw hex seed — always present, and the *only* backup available for
        /// a wallet that was itself restored from one.
        hex: models.Seed = .{},

        /// Whether there is a mnemonic to write down (and therefore to quiz on).
        pub fn hasWords(self: *const SeedBackup) bool {
            return self.words.len > 0;
        }
    };

    pub const WalletErrSink = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *WalletErrSink, msg: []const u8) void {
            const n = @min(msg.len, self.buf.len);
            @memcpy(self.buf[0..n], msg[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const WalletErrSink) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const ExternalWallet = struct {
        /// Port BoxWallet binds the wallet-rpc process to (localhost only). Null
        /// for an in-daemon wallet (no separate process — the daemon's own port is
        /// used).
        rpc_port: ?*const fn () []const u8 = null,
        /// argv to spawn the wallet-rpc process, bound to `port` and pointed at
        /// the daemon, locked to the per-session `rpc_user`/`rpc_password` (the
        /// wallet RPC exposes the spend key, so it must not be left keyless). The
        /// same credentials are returned by the app's `extWalletAuth`. Caller owns
        /// the returned slice and its strings. **Null marks an in-daemon wallet**:
        /// BoxWallet spawns no separate process, and `hasExternalWalletProcess`
        /// keys off this being non-null.
        process_argv: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            port: []const u8,
            rpc_user: []const u8,
            rpc_password: []const u8,
        ) anyerror![]const []const u8 = null,
        /// Whether the managed wallet already exists. For a process-backed wallet
        /// this is a file check (no running process needed); for an in-daemon
        /// wallet it may probe the daemon's status endpoint (the daemon is up
        /// whenever the UI offers the menu). False → the UI prompts to set one up.
        exists: *const fn (allocator: std.mem.Allocator, home_dir: []const u8) bool,
        /// Create a new wallet with `password`; returns its freshly-generated
        /// mnemonic seed for the user to back up. `detail` receives the daemon's
        /// failure message on error.
        create: *const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!models.Seed,
        /// Restore a wallet from a mnemonic `seed` under `password` (word count per
        /// coin — see `seed_word_counts`). `install_root`/`home_dir` are provided
        /// because the restore may shell out to the coin's wallet CLI (older Monero
        /// forks lack an RPC seed-restore). `detail` receives the daemon's/CLI's
        /// failure message on error.
        ///
        /// **Always normalize the seed first** with `models.normalizeSeedWords`
        /// (lowercase + collapse whitespace) before handing it to the daemon/CLI, so
        /// a phrase pasted with stray case or spacing still restores. The seed is the
        /// secret — wipe any working copy before freeing it.
        restore_seed: *const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            install_root: []const u8,
            home_dir: []const u8,
            password: []const u8,
            seed: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void,
        /// Import an existing wallet file (`src_path`, browsed to) into the managed
        /// wallet dir and open it with `password`. Uses `home_dir` to resolve the
        /// destination; may also need the wallet process (via `wallet_auth`) to open.
        /// `detail` receives the daemon's failure message on error. **Null for coins
        /// with no portable wallet file** (Ergo's in-daemon wallet), in which case
        /// the setup menu omits the "Restore from a wallet file" choice.
        restore_file: ?*const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            home_dir: []const u8,
            src_path: []const u8,
            password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void = null,
        /// Open the existing managed wallet with `password` (so its balance can be
        /// read). Called when a wallet already exists at process start. `detail`
        /// receives the daemon's failure message on error.
        open: *const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void,
        /// Re-lock the open wallet. Null for the Monero-style process-backed coins,
        /// which lock implicitly when their wallet process is killed (so the UI
        /// offers no explicit lock); set for an in-daemon wallet that stays open
        /// while the daemon runs and so needs an explicit lock action. `detail`
        /// receives the daemon's failure message on error.
        lock: ?*const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            detail: *WalletErrSink,
        ) anyerror!void = null,
        /// Remove the managed wallet's on-disk artifacts so a *new* one can be
        /// created/restored in its place — the in-app "Replace wallet". Destructive:
        /// the UI gates it behind a typed confirmation. For an in-daemon wallet
        /// (Ergo) the node caches the secret in memory, so the app stops the daemon
        /// before calling this and restarts it after (see the replace orchestration
        /// in `app.zig`); this hook itself just deletes the files. Null = the coin
        /// offers no in-app replace. `supportsWalletReplace` keys off this.
        remove: ?*const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror!void = null,
        /// Read the open wallet's balances over the wallet RPC.
        balance: *const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
        ) anyerror!models.WalletBalance,
        /// Optional: report wallet rescan progress for a wallet that re-scans the
        /// chain after a restore. Two shapes use it: an in-daemon wallet whose node
        /// scans only forward (Ergo, where a restored seed's history is recovered by
        /// an explicit rescan-from-0), and a process-backed Monero-style wallet whose
        /// `wallet-rpc` background-refreshes a restored wallet from height 0. The
        /// scanned height comes from the *wallet* (`wallet_auth`); the target (chain
        /// tip) comes from the *daemon* (`daemon_auth`) — for an in-daemon wallet the
        /// two auths address the same process, so a coin that sources its own tip can
        /// ignore `daemon_auth`. Returns null when the wallet isn't rescanning (caught
        /// up, locked, or the chain height isn't known yet) or for coins where it
        /// doesn't apply. The UI shows a "Rescanning… X%" indicator while non-null.
        rescan_progress: ?*const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            daemon_auth: models.CoinAuth,
        ) anyerror!?models.RescanProgress = null,
        /// Optional: whether the wallet is currently unlocked *at the daemon*. Only
        /// meaningful for an in-daemon wallet (Ergo) whose node outlives the app and
        /// keeps the wallet unlocked across an app restart — letting the UI re-adopt
        /// the real open-state (and resume balance/rescan polling) instead of falsely
        /// showing "Locked" until the user re-enters a password the node no longer
        /// needs. Not a *security* unlock: it only reports state the node already
        /// holds (balance reads authenticate with the api_key, not this password), so
        /// it never opens a wallet. Null for process-backed wallets, whose RPC dies
        /// with the app.
        is_open: ?*const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
        ) anyerror!bool = null,
        /// Valid word counts for this wallet's restore seed, for the seed-entry
        /// UI's prompt and live word counter (the daemon does the real validation).
        /// The first entry is the canonical length named in the prompt. Monero/
        /// CryptoNote coins use the default `{25}`; Ergo's BIP39 mnemonics accept
        /// `{15, 12, 24}` (15 canonical, what its node generates); Zano uses
        /// `{26, 25, 24}` (26 canonical).
        seed_word_counts: []const usize = &.{25},
        /// Optional: for a wallet whose RPC process can only serve a **single**
        /// wallet file passed at launch with its password (Zano's `simplewallet` —
        /// its RPC exposes no create/open/restore, only balance/seed for the wallet
        /// it was started on). When set, BoxWallet does **not** spawn the wallet
        /// process eagerly and password-less (the Monero `--wallet-dir` model);
        /// instead it (re)launches it per-open with the wallet file + password via
        /// this argv, so `process_argv` is left null. The process binds
        /// localhost:`port`; the wallet RPC is keyless on localhost (Zano
        /// `simplewallet` has no `--rpc-login`), the same localhost-only protection
        /// the daemon's own RPC relies on. `walletLaunchesWithPassword` keys off this.
        launch_server_argv: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            port: []const u8,
            wallet_password: []const u8,
        ) anyerror![]const []const u8 = null,
        /// Optional: argv for a **payment listener** — a second, long-running
        /// wallet process that must be up for payments to complete, for a coin
        /// whose transactions are exchanged through a relay rather than broadcast
        /// (Epic's `epic-wallet listen -m epicbox`: it signs incoming payments and
        /// finalizes outgoing ones). `extwallet` launches it right after a
        /// successful open, with the same password, and kills it with the wallet
        /// process — so it runs exactly while the wallet is unlocked. The password
        /// is not kept to restart it: a listener that dies stays down until the
        /// next unlock. Only meaningful alongside `launch_server_argv`.
        listener_argv: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            wallet_password: []const u8,
        ) anyerror![]const []const u8 = null,
        /// What the payment listener is called on screen ("Epicbox listener").
        /// Paired with `listener_argv`.
        listener_name: []const u8 = "Payment listener",
        /// Non-empty when the wallet server and listener read their password from
        /// a terminal instead of argv: `extwallet` then starts them on a private
        /// pty (`ttypass`) and types the password at each prompt containing this
        /// text, and `launch_server_argv` / `listener_argv` must leave it out of
        /// the command line (where any local user could read it). Set it only
        /// where `ttypass.supported`; elsewhere the argv carries the password.
        password_prompt: []const u8 = "",
        /// Optional: one-shot CLI that materializes the managed wallet file under
        /// `password` *before* the RPC server is launched (Zano
        /// `simplewallet --generate-new-wallet`). Paired with `launch_server_argv`:
        /// the app runs this, then launches the server and calls `create` to read
        /// back the freshly-generated seed over RPC. Null for coins that create over
        /// RPC. The password touches the process argv only (no shell), never disk.
        cli_create: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void = null,
        /// Whether the setup menu offers "Restore from seed words". True for coins
        /// whose wallet BoxWallet can restore from a mnemonic; false where it isn't
        /// wired yet (Zano's restore-from-seed is interactive-only upstream, deferred
        /// for now). `supportsSeedRestore` keys off this.
        supports_seed_restore: bool = true,
        /// Optional: read the wallet's recovery phrase back for the user to write
        /// down — "Show recovery seed", the counterpart of `restore_seed` for a
        /// user who didn't record the words at create time. `password` is asked
        /// for again rather than reused from an unlock: an unattended unlocked
        /// session must not hand out the seed. The implementation must check it
        /// (a wrong one fails as `error.WrongPassword`). It may read the open
        /// wallet over its RPC (`wallet_auth`) or decrypt the wallet file under
        /// `home_dir` itself — see `show_seed_when_locked`. It never opens,
        /// closes or relaunches the wallet. The result is the secret; the caller
        /// wipes it.
        show_seed: ?*const fn (
            allocator: std.mem.Allocator,
            wallet_auth: models.CoinAuth,
            home_dir: []const u8,
            password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!models.Seed = null,
        /// Optional: copy the managed wallet file to `dest_path` — "Back up wallet
        /// file". The copy must be one `restore_file` accepts, so a backup always
        /// has a way back in. Must not create or modify anything in the wallet's
        /// own directory, and must refuse to overwrite an existing `dest_path`.
        /// Works whether or not the wallet is open (it's a file copy, and the file
        /// stays encrypted with the wallet password). `extwallet.backupFile` picks
        /// the timestamped destination.
        backup_file: ?*const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
            dest_path: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void = null,
        /// Extension for the file `backup_file` writes (".seed"), so the backup
        /// reads as what it is. Paired with `backup_file`.
        backup_file_ext: []const u8 = "",
        /// Optional: the **payment relay** the listener collects payments from
        /// (Epic's Epicbox server) and the user's choice of it — shown in
        /// Settings beside the node. `relay_source` reads the one in use into
        /// `buf` (`Coin.relay_max`): empty means the coin's standard relay
        /// (`relay_default`). `set_relay_source` stores a choice (empty = back
        /// to the standard one), refusing one it can't use with
        /// `error.InvalidRelayAddress`; the wallet process reads it at start-up,
        /// so the caller restarts it. A coin wires both or neither —
        /// `offersRelayChoice` checks.
        relay_source: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            buf: []u8,
        ) []const u8 = null,
        set_relay_source: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            value: []const u8,
        ) anyerror!void = null,
        /// What the relay is called on screen ("Epicbox server").
        relay_name: []const u8 = "",
        /// The standard relay, named when none other is chosen.
        relay_default: []const u8 = "",
        /// An example of what to type, shown under the field.
        relay_example: []const u8 = "",
        /// What choosing a different relay means, shown beside that choice.
        relay_note: []const u8 = "",
        /// Whether `show_seed` works on a **locked** wallet too — true when it
        /// reads the words from the wallet file with the password (Epic), rather
        /// than asking the running wallet process, which exists only while it's
        /// open. Decides whether the locked wallet's menu offers it.
        show_seed_when_locked: bool = false,
    };

    /// An optional **sync accelerator** — a large, opt-in download that makes a
    /// coin's *initial* chain sync dramatically faster, offered as a yes/no choice
    /// when the daemon is started on a chain that isn't synced yet. Coins with no
    /// such helper leave `sync_accelerator` null.
    ///
    /// Two shapes are in use, and `apply` is what tells them apart:
    ///   - a **helper file** the daemon is pointed at — Nerva's `quicksync.raw`,
    ///     precomputed block hashes wired into `daemon_argv`. Lands in
    ///     `install_root`; nothing to apply afterwards.
    ///   - a **chain snapshot** — Divi's ~4.7 GB `blocks/` + `chainstate/` tarball,
    ///     downloaded then unpacked into the coin's *data dir*, which is why
    ///     `home_dir` is threaded through.
    pub const SyncAccelerator = struct {
        /// Short name for the prompt (e.g. "QuickSync", "Blockchain snapshot").
        name: []const u8,
        /// One-line pitch shown in the prompt (what it does, rough download size).
        prompt_detail: []const u8,
        /// Whether the download can pick up where an interrupted attempt left off.
        /// True for the multi-GB snapshots (where restarting from zero would make
        /// the feature unusable); false for helper files small enough to refetch.
        /// Purely a UI hint — the coin's own `download` does the resuming.
        resumable: bool = false,
        /// Whether taking this accelerator means trusting its publisher for work
        /// the node would otherwise do itself. True for both shapes above: a
        /// snapshot hands over chain data the daemon never validated, and a
        /// block-hash file exists precisely so it can skip validating.
        ///
        /// **Defaults true** — an accelerator whose author hasn't thought about
        /// this still gets the caution, rather than quietly omitting it. Set
        /// false only where BoxWallet verifies the payload itself (a hash-pinned
        /// file), which is the only thing that makes the trust unnecessary.
        /// Frontends render `accel_trust_note` when it's set.
        trusts_publisher: bool = true,
        /// Whether to offer it right now: true only when the chain isn't already
        /// synced *and* the accelerator isn't already present/in use — so a synced
        /// node (or one mid-accelerated-sync) is never prompted. A pure disk check,
        /// so it runs before the daemon is up.
        ///
        /// For a snapshot this must **also** refuse when chain data is already on
        /// disk: that data may be another app's, and unpacking a snapshot over a
        /// live `chainstate/` would destroy it (see the data-sharing rule).
        should_offer: *const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
        ) bool,
        /// Fetch the accelerator (blocking, reporting progress), called on a worker
        /// thread when the user opts in. `install_root` is BoxWallet's own dir;
        /// `home_dir` lets a coin resolve its data dir. Surfaces failures — the user
        /// asked for it — and must leave nothing half-applied. A `resumable`
        /// accelerator may deliberately keep its partial download behind for the
        /// next attempt; nothing else may.
        ///
        /// `cancel`, when supplied, is polled between chunks: a true answer must
        /// stop promptly and unwind with `error.Paused`, leaving whatever is on
        /// disk resumable. That is how both the user's Pause and a clean app
        /// shutdown are served — a transfer this long is almost always still
        /// running when the window closes.
        download: *const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            progress: ?install_mod.Progress,
            cancel: ?install_mod.Cancel,
        ) anyerror!void,
        /// Put a downloaded snapshot in place (unpack it into the data dir), or null
        /// for an accelerator that is simply a file the daemon reads. Run after
        /// `download`, on the same worker, reporting `.extract` progress.
        apply: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            progress: ?install_mod.Progress,
            cancel: ?install_mod.Cancel,
        ) anyerror!void = null,
        /// Bytes of an interrupted download already on disk, so the prompt can
        /// offer to *continue* rather than appear to start a multi-GB transfer
        /// over. Null for accelerators that don't resume; 0 when there's nothing
        /// waiting. A cheap disk check — the frontend calls it as it opens the
        /// prompt.
        partial_bytes: ?*const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
        ) u64 = null,
    };

    /// The caution shown beside a `trusts_publisher` accelerator's pitch, in both
    /// frontends. Held here, once: the tradeoff is a property of accelerators in
    /// general, not of any one coin, so it isn't copy repeated in the coin files
    /// (they declare the *fact* — `trusts_publisher` — and the frontends decide
    /// the words).
    ///
    /// Deliberately states the tradeoff in both directions and claims nothing it
    /// can't back: BoxWallet verifies neither payload (upstream rebuilds Divi's
    /// snapshot daily and signs nothing), so "you're trusting whoever published
    /// it" is the literal truth, and the user gets to weigh it.
    pub const accel_trust_note =
        "It's faster because it skips the verification your node would otherwise " ++
        "do itself — you're trusting whoever published it. Syncing from the " ++
        "network is slower, but your node proves every block for itself.";

    /// One row of the first-start prune menu: the label the user sees and the
    /// value it applies. What the number means depends on the coin's
    /// `Pruning.Mode` — a disk cap in MiB, or simply on (non-zero) / off (0).
    pub const PrunePreset = struct { label: []const u8, value: i64 };

    /// The stock disk-cap menu for `.size_mib` coins (bitcoin-derived). 1 GB is
    /// taken as 1000 MiB so the choice reads back cleanly as "N GB" on the
    /// Settings tab.
    pub const size_prune_presets = [_]PrunePreset{
        .{ .label = "No pruning (full node)", .value = 0 },
        .{ .label = "Prune to 2 GB", .value = 2000 },
        .{ .label = "Prune to 5 GB", .value = 5000 },
        .{ .label = "Prune to 10 GB", .value = 10000 },
    };

    /// An optional **block-pruning** capability — for coins whose chain is large
    /// enough that the user is asked, the first time the daemon starts, how the
    /// blockchain should be stored. The choice is persisted in the coin's conf, so
    /// it's a one-time prompt and is read back for the Settings tab. Coins with no
    /// such prompt leave `pruning` null; `offersPrunePrompt`/`pruning` key off it.
    pub const Pruning = struct {
        /// What the numbers in `presets`/`apply`/`current` mean, because daemons
        /// don't agree on the shape of the knob:
        ///
        /// - `.size_mib` — bitcoin-derived `prune=<MiB>`: an on-disk cap in MiB
        ///   (matching the daemon's own units; the UI converts to/from GB), 0 = keep
        ///   the whole chain. The daemon enforces a ~550 MiB floor. A free-form
        ///   amount makes sense here, so the menu carries a "Custom…" row.
        /// - `.on_off` — Monero-style `prune-blockchain=1`: pruning is all-or-nothing
        ///   (the daemon drops ~7/8 of the ring-signature data, leaving roughly a
        ///   third of the chain) with no size to choose, so non-zero = pruned, 0 =
        ///   full, and there is no custom amount to type.
        /// How a coin expresses its prune knob. This IS `money.PruneMode` rather
        /// than a parallel enum: both front-ends hand the mode to
        /// `money.pruneValueText` to describe a setting, and two enums converted
        /// by ordinal would let a third mode added to one silently relabel
        /// someone's prune setting. One type, nothing to keep in step.
        pub const Mode = money.PruneMode;

        /// How to read this coin's prune values, and whether a custom amount is
        /// offered.
        mode: Mode = .size_mib,
        /// The menu rows, in display order. By convention the least destructive
        /// choice (keep everything) comes first, since the cursor starts there.
        presets: []const PrunePreset = &size_prune_presets,
        /// The question at the top of the prompt, in the coin's own terms (chain
        /// size, what pruning costs). One sentence — the modal wraps it.
        prompt: []const u8,
        /// Whether to show the first-start prune prompt now: true only when the
        /// conf carries no prune setting yet (a fresh install BoxWallet hasn't
        /// configured, and not a conf the user already pruned themselves). A pure
        /// disk check, so it runs before the daemon is up.
        should_offer: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) bool,
        /// Persist the chosen prune value (see `Mode`; 0 = full node) to the conf,
        /// creating the conf/dir if absent. Called once, before the daemon launches.
        apply: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
            prune_value: i64,
        ) anyerror!void,
        /// The configured prune value for the Settings tab (see `Mode`), 0 (full
        /// node), or null when the conf carries no prune setting. A cheap conf read.
        current: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror!?i64,
        /// Whether the setting may still be **changed** after the first start —
        /// the Settings tab's edit, as opposed to the one-shot prompt. False (the
        /// default) is the right answer for any coin whose daemon can't act on a
        /// changed value: Monero's `prune-blockchain=1` does nothing to an LMDB
        /// that is already synced unpruned (that needs the separate
        /// `monero-blockchain-prune` tool), so offering the edit would promise a
        /// change the node never makes.
        ///
        /// A property of the coin, not of the machine — nothing here asks whose
        /// data dir it is. BoxWallet deliberately shares the daemon's standard
        /// directory, and nothing on disk distinguishes one it set up from one it
        /// adopted: it writes nothing a plain node wouldn't. So rather than guess
        /// at ownership, the front-ends confirm the *consequence* before applying
        /// (`change_warning`, `changeDeletesBlocks`) — which is the same fact
        /// either way, and the fact that actually matters.
        can_change: bool = false,
        /// What a change costs, in the coin's own terms — shown in the confirm,
        /// where the user is about to discard blocks. Required (checked by test)
        /// of any coin setting `can_change`; the one-shot prompt has `prompt` for
        /// the same job.
        change_warning: []const u8 = "",

        /// Whether a change from the currently configured value to `to` is one the
        /// daemon can actually carry out. Pure — both front-ends and the C ABI ask
        /// this, so a row the TUI hides can't be a row the GUI offers.
        ///
        /// The move that is refused is **pruned → full node**. A daemon can start
        /// pruning a chain it has (it deletes the old blocks) and it can be told to
        /// keep more from here on, but it cannot put back blocks it already threw
        /// away: bitcoin-derived cores require the whole chain to be downloaded
        /// again for that. Offering it as a menu row would read as "undo", and it
        /// is the opposite — a silent re-sync of hundreds of GB.
        ///
        /// `from` is the configured value (-1 when the conf carries none, 0 for a
        /// deliberate full node); `to` is the candidate. A negative `to` is never
        /// allowed — it is the ABI's "not configured" sentinel, not a setting.
        pub fn changeAllowed(from: i64, to: i64) bool {
            if (to < 0) return false;
            return !(from > 0 and to == 0);
        }

        /// Whether moving from the configured value to `to` makes the daemon
        /// **delete blocks it currently has**. This is what the change confirm is
        /// about: not who owns the data dir — that can't be established — but
        /// whether this particular move destroys something, which can.
        ///
        ///  - `to == 0` keeps everything: nothing is deleted.
        ///  - a full node (`from == 0`) that starts pruning drops most of its
        ///    chain, and can't get it back short of a full re-sync.
        ///  - a pruned node given a *smaller* cap prunes further; a *larger* one
        ///    only keeps more from here on, and deletes nothing.
        ///  - `from < 0` — no value in the conf, so what the daemon has on disk is
        ///    unknown. Treated as destructive, because the safe reading of "we
        ///    don't know" is the cautious one.
        pub fn changeDeletesBlocks(from: i64, to: i64) bool {
            if (to == 0) return false;
            if (from < 0) return true;
            if (from == 0) return true;
            return to < from;
        }
    };

    /// An optional **block-index rebuild** capability — the repair for a daemon
    /// whose on-disk index has gone bad and which therefore aborts during init,
    /// before its RPC ever answers. Nexa's `FindMostWorkChain()` assertion on an
    /// unlinked `CBlockIndex` is the worked example: the daemon forks, gets as far
    /// as "Activating best chain…", and dies on an `assert` with nothing in its
    /// own log. Nothing in the conf can avoid it; the index has to be rebuilt.
    ///
    /// Coins with no such repair (Monero has no equivalent; Ergo's is unrelated)
    /// leave `reindex` null and the affordance never appears.
    ///
    /// **The flags are one-shot argv, never conf.** A bitcoin-derived daemon takes
    /// `reindex=1` in its conf just as happily as on the command line, and would
    /// then rebuild on *every* start for ever — in a conf BoxWallet shares with
    /// whatever else owns that data dir. Nothing here writes anything down: the
    /// flag lives for exactly one launch (see `app.LaunchOptions`), and the daemon
    /// persists its own "still reindexing" state in the block-tree DB, so an
    /// interrupted rebuild resumes by itself without BoxWallet tracking it.
    pub const Reindex = struct {
        /// Appended to `daemon_argv` for one launch. The coin's own spelling —
        /// generic code never writes the flag text.
        flags: []const []const u8 = &.{"-reindex"},
        /// What the rebuild costs on a node holding the **whole** chain: CPU and
        /// hours, but nothing is re-downloaded. Shown in the confirm.
        warning: []const u8,
        /// What it costs on a **pruned** node, where it is destructive: the daemon
        /// removes the block files it can't reuse and downloads the chain again
        /// (nexad: "Removing unusable blk?????.dat and rev?????.dat files for
        /// -reindex with -prune"). Shown instead of `warning` whenever
        /// `Pruning.current` reports a pruned node, so the confirm names the
        /// consequence that actually applies. Required (checked by test) of any
        /// coin that wires both `reindex` and a `pruning` capability.
        pruned_warning: []const u8 = "",
        /// The line the daemon logs while rebuilding, matched as a prefix so the
        /// warm-up stage can say "Rebuilding block index" rather than leaving it
        /// to look like an ordinary sixty-second start. An hours-long operation
        /// that reads as a normal one gets killed halfway by a user who assumes
        /// it has hung.
        progress_marker: []const u8 = "Reindexing block file",
        /// The line that says it finished, so the stage stops claiming a rebuild
        /// is still running once the daemon moves on to an ordinary start-up.
        done_marker: []const u8 = "Reindexing finished",
        /// The data-dir subdirectory holding the coin's block files, counted to
        /// turn "rebuilding file 42" into a percentage. Named here rather than
        /// assumed by the warm-up reader, which has no business knowing one
        /// bitcoin-family convention from another.
        blocks_dir: []const u8 = "blocks",
        /// Filename bounds of a block file inside `blocks_dir` (`blk00042.dat`),
        /// so the count doesn't also sweep up the undo files (`rev00042.dat`) or
        /// the LevelDB directories beside them.
        block_file_prefix: []const u8 = "blk",
        block_file_suffix: []const u8 = ".dat",
    };

    /// An optional **group-token** capability — tokens and NFTs issued on the
    /// coin's own chain and held in the same wallet as the coin (Nexa's group
    /// tokenization). Coins with one get a dedicated detail-pane tab (named
    /// `name`) listing what the wallet holds and, for an NFT, the artwork and
    /// metadata behind it.
    ///
    /// Amounts are in each token's own finest unit — `models.TokenHolding`
    /// carries the `decimals` needed to place the point, and deliberately does
    /// not apply it, because the daemon accepts and reports nothing else.
    ///
    /// The split between the two hooks is deliberate. `list` is cheap and local
    /// (one RPC to the coin's own daemon) and drives the tab's list. `fetch_nft`
    /// reaches out to the issuer's host over the network for a bundle that can
    /// run to tens of megabytes, so it is only ever called for the one NFT a
    /// user opened, never for the list.
    pub const Tokens = struct {
        /// Display name — the tab label ("Tokens").
        name: []const u8,
        /// What to tell someone whose wallet holds none yet: how tokens reach
        /// this wallet, and where to start. Coin-specific by nature, so it
        /// lives with the coin rather than baked into either front-end.
        ///
        /// Deliberately names **no marketplace**. A wallet naming a site
        /// endorses it, trains people to trust destinations the wallet
        /// suggests — the habit phishing exploits — and can't be corrected
        /// without a release if that domain later dies or changes hands.
        /// Explain the mechanism; let the user choose the venue.
        empty_hint: []const u8 = "",
        /// Everything the wallet holds, newest-first where the daemon orders
        /// them, capped at `limit`. Caller owns the returned slice.
        list: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            limit: usize,
        ) anyerror![]models.TokenHolding,
        /// Send `quantity` of the token identified by `group` to `address`.
        ///
        /// `quantity` is in the token's **finest unit** — the only unit the
        /// daemon accepts, and an integer for the same reason money is: a
        /// float here would let a rounding artifact decide how much actually
        /// moved. Front-ends convert what the user typed with
        /// `money.parseUnits` and that coin's own `decimals`.
        ///
        /// Returns `SendResult`, so a daemon-side rejection (locked wallet,
        /// insufficient token balance, bad address) comes back as a `.failed`
        /// carrying the daemon's own words rather than an opaque error — the
        /// difference between those three is exactly what the user needs.
        send: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            group: []const u8,
            address: []const u8,
            quantity: i64,
        ) anyerror!models.SendResult,
        /// Fetch, verify and unpack one NFT's data bundle, returning its
        /// metadata and the on-disk path of its card art. `cache_root` is a
        /// BoxWallet-owned directory the bundle is unpacked under, so a second
        /// view costs no network.
        ///
        /// The returned `models.NftMeta.verified` is the load-bearing field: it
        /// says the downloaded bytes hashed to the value the chain commits to.
        /// A bundle that fails that check is an **error**, never a result with
        /// the flag cleared — see `src/nft.zig`.
        fetch_nft: *const fn (
            allocator: std.mem.Allocator,
            holding: models.TokenHolding,
            cache_root: []const u8,
        ) anyerror!models.NftMeta,
    };

    /// One lock tier a stablecoin can be minted at: longer locks demand less
    /// collateral. `duration` is the human label ("30 days", "10 years");
    /// `ratio_pct` the required collateral ratio in percent (500 == 500%, i.e.
    /// $5 of collateral per $1 minted).
    pub const StablecoinTier = struct {
        tier: u8,
        duration: []const u8,
        ratio_pct: u32,
    };

    /// An optional **stablecoin** capability — a USD-denominated asset issued on
    /// the coin's own chain by locking the coin as collateral (DigiByte's
    /// DigiDollar). Coins with one get a dedicated detail-pane tab (named
    /// `name`) covering the full lifecycle: mint (lock collateral at a chosen
    /// tier), send/receive, positions (vaults), and redeem (burn the stablecoin
    /// to release the collateral once the timelock expires).
    ///
    /// All amounts are **integer USD cents** (`models.Stablecoin*`), matching
    /// the daemon's unit. Every hook takes the *daemon's* RPC auth — the
    /// stablecoin wallet RPCs live in the coin's own wallet, not a separate
    /// process. Hooks return `SendResult`-style outcomes where a daemon-side
    /// rejection (locked wallet, timelock not expired, price stale) is a normal
    /// outcome to show verbatim, not an exceptional error.
    /// Capability: **payments by slate file**, for a MimbleWimble coin (Epic)
    /// whose transaction is built by the two sides in turn. Instead of a relay
    /// carrying the slate, the user carries it: the sender saves a file, the
    /// receiver opens it and saves a response, the sender opens that to finish.
    ///
    /// Every hook takes the open wallet's auth (the wallet process, as for
    /// `wallet_send`) and returns refusals as outcomes to show, not errors. What
    /// a file *is* comes from its contents, never its name; the names follow the
    /// coin's command-line wallet (`<id>.tx`, replied to as `<id>.tx.response`),
    /// so a reply is always the file you were sent, plus a suffix.
    pub const SlateFiles = struct {
        /// What a file send of `amount` would cost (nothing is built or locked).
        fee: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            amount: f64,
        ) anyerror!models.FeeEstimate,
        /// Build a send of `amount` (with `note`, may be empty), lock the coins it
        /// spends, and write the slate into `out_dir`. `.ok` is the file's path.
        /// The send then waits — like an unanswered Epicbox send, and cancellable
        /// the same way — until the receiver's response is opened with `process`.
        send: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            amount: f64,
            note: []const u8,
            out_dir: []const u8,
        ) anyerror!models.SendResult,
        /// Read the slate file at `path` and say what it is for this wallet, and
        /// so what `process` would do with it. Changes nothing.
        inspect: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            path: []const u8,
        ) anyerror!models.SlateInfo,
        /// Do what `inspect` said, provided the file still is what the user was
        /// shown (`expect`): `.receive` signs it and writes the reply beside it,
        /// `<name><reply_suffix>` (`.ok` is that path); `.finalize` completes and
        /// broadcasts the send.
        process: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            path: []const u8,
            expect: models.SlateKind,
        ) anyerror!models.SendResult,
        /// Extension of a slate file ("tx").
        extension: []const u8 = "tx",
        /// What the reply to `<name>` is called: `<name><reply_suffix>`, as the
        /// coin's command-line wallet names it.
        reply_suffix: []const u8 = ".response",
        /// The prefix the coin's GUI wallet suggests for a reply instead
        /// (`finalize_<name>`) — recognised, so its users' replies are found,
        /// but never written. Empty for none.
        other_reply_prefix: []const u8 = "",

        /// Whether a file name looks like a reply to a send — for filtering what
        /// a "pick their reply" browser shows, never for deciding what a file is.
        pub fn isReplyName(self: *const SlateFiles, name: []const u8) bool {
            if (std.mem.endsWith(u8, name, self.reply_suffix)) return true;
            if (self.other_reply_prefix.len == 0 or !std.mem.startsWith(u8, name, self.other_reply_prefix)) return false;
            return self.hasExtension(name);
        }

        /// Whether a file name looks like a payment to receive: `<name>.<ext>`
        /// that isn't a reply. For filtering the "receive a payment file"
        /// browser, never for deciding what a file is.
        pub fn isPaymentName(self: *const SlateFiles, name: []const u8) bool {
            return self.hasExtension(name) and !self.isReplyName(name);
        }

        fn hasExtension(self: *const SlateFiles, name: []const u8) bool {
            const ext = std.fs.path.extension(name);
            return ext.len > 1 and std.mem.eql(u8, ext[1..], self.extension);
        }
    };

    pub const Stablecoin = struct {
        /// Display name — the tab label ("DigiDollar").
        name: []const u8,
        /// Short unit symbol ("DD").
        symbol: []const u8,
        /// Smallest / largest amount the daemon will mint in one transaction,
        /// in cents, for the mint prompt's bounds hint.
        min_mint_cents: i64,
        max_mint_cents: i64,
        /// The chain's block interval in seconds (DigiByte: 15), so the
        /// pre-activation countdown can turn "N blocks to go" into wall-clock
        /// time. 0 = unknown (the UI shows blocks only).
        block_seconds: u32 = 0,
        /// The mintable lock tiers, in tier order (index == tier number).
        tiers: []const StablecoinTier,
        /// Live system state: deployment (activation) status, oracle price,
        /// supply/collateral/health, whether minting is currently blocked.
        info: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.StablecoinInfo,
        /// The wallet's stablecoin balance, in cents.
        balance: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.StablecoinBalance,
        /// The wallet's stablecoin deposit address. `force_new` mints a fresh
        /// one (the user's explicit rotation); otherwise the current/first
        /// existing address is reused. Caller owns the returned slice.
        receive_address: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            force_new: bool,
        ) anyerror![]const u8,
        /// The wallet's most recent stablecoin transactions, newest-first,
        /// capped at `limit`. Caller owns the returned slice.
        transactions: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            limit: usize,
        ) anyerror![]models.StablecoinTx,
        /// The wallet's collateral positions (vaults), capped at `limit`.
        /// Caller owns the returned slice.
        positions: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            limit: usize,
        ) anyerror![]models.StablecoinPosition,
        /// How much collateral (in the coin's own units) minting `cents` at
        /// `tier` would lock right now, so the user sees the cost before
        /// confirming.
        estimate_collateral: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            cents: i64,
            tier: u8,
        ) anyerror!f64,
        /// Mint `cents` of stablecoin at lock `tier`, locking collateral.
        mint: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            cents: i64,
            tier: u8,
        ) anyerror!models.SendResult,
        /// Send `cents` of stablecoin to `address`.
        send: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            address: []const u8,
            cents: i64,
        ) anyerror!models.SendResult,
        /// Redeem the position `position_id` (its full `cents` amount — the
        /// daemon requires redeeming whole vaults), burning the stablecoin and
        /// unlocking its collateral.
        redeem: *const fn (
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            position_id: []const u8,
            cents: i64,
        ) anyerror!models.SendResult,
    };

    /// How a coin's daemon is launched.
    ///   - `fork`: the daemon forks itself into the background and the launcher
    ///     exits (bitcoin-derived `*coind -daemon`); the launcher waits on it and
    ///     confirms liveness. POSIX only.
    ///   - `foreground`: the process stays in the foreground of its own process
    ///     (Windows `*coind`, or a JVM app like Ergo's `java -jar`), so it's
    ///     spawned detached and the status poll confirms it came up.
    pub const LaunchMode = enum { fork, foreground };

    /// A **two-tone wordmark** — the coin's name drawn in two colours: the head
    /// (`coin_name[0..split]`) and the tail (`coin_name[split..]`). By default the
    /// head wears the coin's `coin_color` and the tail wears `alt_color` (ReddCoin's
    /// "Redd"+"Coin"); a coin that wants the *head* in a different colour (SpiderByte
    /// draws "Spider" white, "Byte" in the brand colour) sets `head_color` to
    /// override it. Single-colour coins leave the `wordmark` vtable hook null.
    pub const Wordmark = struct {
        /// Byte index in `coin_name` where the `alt_color` half begins.
        split: usize,
        /// Hex `#RRGGBB` for the tail half.
        alt_color: []const u8,
        /// Optional hex `#RRGGBB` for the head half. Null → the coin's `coin_color`
        /// (the common case); set it to draw the head in a non-brand colour.
        head_color: ?[]const u8 = null,
    };

    /// Where a coin's managed wallet lives on disk, for the Settings tab. `path`
    /// is the primary wallet file (or directory); `keys` is the Monero-style
    /// `.keys` companion (null for single-file coins). Strings owned by the
    /// caller's allocator.
    pub const WalletFile = struct {
        path: []const u8,
        keys: ?[]const u8 = null,
    };

    pub const VTable = struct {
        coin_name: *const fn (ptr: *anyopaque) []const u8,
        coin_name_abbrev: *const fn (ptr: *anyopaque) []const u8,
        /// A short one-line description of the coin, shown under its name on the
        /// detail pane.
        coin_description: *const fn (ptr: *anyopaque) []const u8,
        /// The coin's brand colour as a `#RRGGBB` hex string, for the frontend.
        coin_color: *const fn (ptr: *anyopaque) []const u8,
        /// The coin's own donation/tip address (in that coin's currency —
        /// addresses aren't cross-chain compatible), shown on every tab of the
        /// coin's detail pane to invite users to fund BoxWallet development.
        tip_address: *const fn (ptr: *anyopaque) []const u8,
        /// Optional: a two-tone wordmark for the coin's name (see `Wordmark`).
        /// Null for coins whose name is drawn in a single colour.
        wordmark: ?*const fn (ptr: *anyopaque) Wordmark = null,
        /// The bundled core version this coin installs (e.g. "2.0.0.0"), shown on
        /// the coin's pane the way the app version rides the Home pane.
        core_version: *const fn (ptr: *anyopaque) []const u8,
        /// True for proof-of-stake coins (which expose a staking status); false
        /// for proof-of-work coins.
        proof_of_stake: *const fn (ptr: *anyopaque) bool,
        /// Optional: this coin's id on the public price host, for the USD quote
        /// shown beside its balance (see `src/price.zig`). Coin-specific data
        /// that isn't derivable from anything else here — the ids don't track
        /// the coin name (Epic is `epic-cash`) — so each coin declares its own.
        ///
        /// **Null means the coin isn't listed** (SpiderByte), which is a normal
        /// state, not an omission: the app simply shows no price for it. A coin
        /// left null is also never sent in the price request.
        price_id: ?*const fn (ptr: *anyopaque) []const u8 = null,
        /// Optional: this coin's **own** price endpoint, used instead of the
        /// roster host. For a coin the roster prices badly rather than not at
        /// all — see `price.Source`. A coin wiring this leaves `price_id` null,
        /// so it is fetched only from here and never falls back to the number
        /// that was wrong.
        price_source: ?*const fn (ptr: *anyopaque) price.Source = null,
        /// Optional: the number of decimal places this coin's balances are shown
        /// to — 8 for bitcoin-derived coins, 12 for the Monero forks (Nerva/Zano),
        /// 9 for Ergo (nanoERG), 2 for Nexa. Drives the fixed-width balance figure
        /// so a zero reads as "0.00000000" rather than a bare "0". Null defaults to
        /// 8 (`Coin.balanceDecimals`).
        balance_decimals: ?*const fn (ptr: *anyopaque) u8 = null,
        conf_file: *const fn (ptr: *anyopaque) []const u8,
        /// Daemon binary filename for the host OS (e.g. `nexad`, `divid`).
        daemon_file: *const fn (ptr: *anyopaque) []const u8,
        rpc_default_port: *const fn (ptr: *anyopaque) []const u8,
        rpc_default_username: *const fn (ptr: *anyopaque) []const u8,
        /// Live call: returns normalized chain state. Returned value owns its
        /// `chain` string and must be `deinit`-ed by the caller.
        blockchain_state: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.BlockchainState,
        /// Live call: returns a normalized `getinfo` snapshot (peer count, block
        /// height, staking). Scalar-only — no cleanup needed.
        daemon_info: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.DaemonInfo,
        /// Resolve the coin daemon's default data directory (where its `.conf`
        /// lives) under the process `home_dir`. Caller owns the returned slice.
        data_dir: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror![]const u8,
        /// True if the daemon binary is present under `install_root`.
        is_installed: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
        ) bool,
        /// Ask the *installed daemon binary* what version it is, by running it with
        /// its version flag — no node started, no RPC, works with the daemon down.
        ///
        /// Only needed by a coin whose daemon doesn't report its version over RPC
        /// (Zano's `getinfo` carries no `version` field). Without it, such a coin's
        /// pre-marker install can never stamp a version marker, so update detection
        /// stays silent forever. Coins whose `daemon_info` already carries a version
        /// leave this null and are stamped from the live daemon instead.
        ///
        /// Caller owns the returned string. Errors when the binary is absent or its
        /// output can't be parsed — the caller treats that as "version unknown".
        installed_version_probe: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
        ) anyerror![]const u8 = null,
        /// Download + unarchive the daemon files into `install_root`,
        /// optionally reporting download/extract progress. `home_dir` is the
        /// process home directory, for the rare coin whose install must also
        /// place support files outside the install root (BitcoinZ downloads the
        /// Zcash proving parameters into the shared per-platform params dir);
        /// most coins ignore it.
        install: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            progress: ?install_mod.Progress,
        ) anyerror!void,
        /// Ensure the coin's config carries everything the daemon needs before
        /// it's launched — RPC creds for a bitcoin-derived `key=value` conf, an
        /// API-key HOCON for Ergo. Idempotent; creates the data dir if absent.
        /// `install_root` is where the coin's binaries live, for the rare coin
        /// (Epic) that must run its own binary to generate a default config before
        /// patching it; coins that only write files themselves ignore it.
        prepare_conf: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            install_root: []const u8,
            home_dir: []const u8,
        ) anyerror!void,
        /// How this coin's daemon is launched (fork vs foreground). See
        /// `LaunchMode`.
        launch_mode: *const fn (ptr: *anyopaque) LaunchMode,
        /// The argv used to spawn the daemon. For `fork` coins this is the bare
        /// daemon binary (the launcher appends `-daemon`); for `foreground` coins
        /// it's the full command (e.g. `java -jar … -c <conf>`). Caller owns the
        /// returned slice and the strings within it (built on `allocator`).
        daemon_argv: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
        ) anyerror![]const []const u8,
        /// Ask the running daemon to shut down. Bitcoin-derived coins issue the
        /// JSON-RPC `stop`; Ergo POSTs its REST `/node/shutdown`. The caller then
        /// polls `daemon_info` until it stops answering, so this need only send
        /// the request. `auth` is the resolved RPC auth (coins that don't use it —
        /// Ergo authenticates with a fixed API key — may ignore it). Left null for
        /// coins whose daemon exposes **no** shutdown RPC (Zano's zanod): the
        /// caller stops those by terminating the process instead (see `hasRpcStop`).
        request_stop: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!void = null,
        /// Optional: ensure the daemon has a usable wallet loaded. Bitcoin-Core
        /// 0.21+ forks (DigiByte, ReddCoin) no longer auto-create a default
        /// wallet, so a fresh daemon has none and wallet RPCs (staking,
        /// addresses) fail until one is created. Coins that need it load-or-create
        /// a "BoxWallet" wallet here; left null for coins whose daemon
        /// auto-creates a wallet, that drive a separate wallet process
        /// (Zano/Nerva), or that have no wallet (Ergo). Called once after the
        /// daemon's RPC comes up.
        ensure_wallet: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!void = null,
        /// Optional: read the wallet's security state (`getwalletinfo`), normalized
        /// to `WalletSecurity`. Non-null marks a coin whose wallet BoxWallet can
        /// manage (the `w` menu) — left null for coins with no manageable wallet
        /// over RPC (Ergo, the external-wallet Zano/Nerva). `supportsWallet` keys
        /// off this being non-null.
        wallet_security_state: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.WalletSecurity = null,
        /// Optional: read the wallet's balances (`getwalletinfo`), normalized to
        /// `WalletBalance` — `available` is the confirmed spendable amount, `total`
        /// adds the mempool + immature funds so it reflects incoming money the
        /// instant it's seen. Non-null for coins whose daemon reports balances over
        /// RPC; `supportsBalance` keys off this being non-null. Independent of
        /// `wallet_security_state` — a coin can show a balance without exposing the
        /// manageable-wallet menu.
        wallet_balance: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.WalletBalance = null,
        /// Optional: list the wallet's most recent transactions (bitcoin-core-style
        /// `listtransactions`), normalized to `WalletTx`, capped at `limit` entries.
        /// Non-null marks a coin whose Transactions tab shows live data;
        /// `supportsTransactions` keys off this being non-null.
        wallet_transactions: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            limit: usize,
        ) anyerror![]models.WalletTx = null,
        /// Optional: the wallet's receive address. `force_new` false gets the
        /// stable "current" address (bitcoin-core-style `getaccountaddress ""`
        /// semantics); `force_new` true mints a brand-new one
        /// (`getnewaddress`-style), for an explicit user-requested rotation.
        /// Non-null marks a coin whose Receive tab shows a live address;
        /// `supportsReceiveAddress` keys off this being non-null.
        /// How many confirmations received funds need before the wallet counts
        /// them as available (Epic: 10, its wallet's `minimum_confirmations`).
        /// When set, the Transactions tab counts up to it ("3/10 confirmations")
        /// and only says Confirmed once a row is spendable. 0: the plain count.
        spendable_confirmations: u32 = 0,
        /// Set when the coin's receive address never changes — one per wallet —
        /// so there's no "new address" to offer (`force_new` returns the same
        /// one). The text, in the coin's own words, is shown where the option
        /// would be, so its absence isn't a mystery. Empty (the default): the
        /// Receive tab offers a new address.
        receive_address_fixed_note: []const u8 = "",
        wallet_receive_address: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            force_new: bool,
        ) anyerror![]const u8 = null,
        /// Optional: send `amount` to `address`. Returns the outcome rather
        /// than erroring on a daemon-side rejection (invalid address,
        /// insufficient funds, locked wallet) — those are normal, expected
        /// outcomes to show the user, not exceptional. Non-null marks a coin
        /// whose Send tab is live; `supportsSend` keys off this being
        /// non-null.
        wallet_send: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            address: []const u8,
            amount: f64,
        ) anyerror!models.SendResult = null,
        /// Optional: `wallet_send` with a note the receiver gets alongside the
        /// payment (Epic: the slate message — signed and kept in both wallets'
        /// transaction logs, never on the chain itself). Only called with a
        /// non-empty note of at most `send_note_max` bytes; an empty one goes
        /// through `wallet_send`. `supportsSendNote` keys off `send_note_max`.
        wallet_send_note: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            address: []const u8,
            amount: f64,
            note: []const u8,
        ) anyerror!models.SendResult = null,
        /// The longest note `wallet_send_note` takes, in bytes — at most
        /// `models.tx_note_max`. 0 (the default) means sends carry no note.
        send_note_max: usize = 0,
        /// Optional: what sending `amount` to `address` would cost, worked out
        /// without sending — so the confirm step can state the fee (and the
        /// total leaving the wallet) before the user agrees to it. A refusal the
        /// wallet can already see (not enough to cover amount + fee, a bad
        /// address) comes back as `.failed`. Paired with `wallet_send`;
        /// `supportsSendFee` keys off this being non-null.
        wallet_send_fee: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            address: []const u8,
            amount: f64,
        ) anyerror!models.FeeEstimate = null,
        /// Optional: cancel a transaction the wallet made but the network never
        /// saw, unlocking what it spent. `txid` is the row's `WalletTx.txid()`;
        /// only rows marked `cancellable` are offered. Like `wallet_send`, a
        /// refusal is an outcome (`.failed` with the wallet's reason), not an
        /// error. `supportsCancelTx` keys off this being non-null.
        wallet_cancel_tx: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            txid: []const u8,
        ) anyerror!models.SendResult = null,
        /// What a successful send's result is introduced with, for a coin where
        /// the front-ends' "Sent. Txid:" would say something untrue — Epic's
        /// send is on its way, not done, and what comes back is a slate id, not
        /// a txid. Empty (the default) keeps each front-end's own wording.
        send_ok_label: []const u8 = "",
        /// Optional: **stake** `amount` — lock it for the coin's staking term to
        /// earn protocol yield (Salvium: a stake transaction paying the wallet's
        /// own address; principal + yield return to the wallet automatically when
        /// the term ends). Like `wallet_send`, returns the outcome rather than
        /// erroring on a daemon-side rejection. Non-null marks a coin with an
        /// explicit stake *action* (distinct from `proof_of_stake`, the passive
        /// stakes-while-unlocked coins); `supportsStakeAction` keys off this.
        wallet_stake: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            amount: f64,
        ) anyerror!models.SendResult = null,
        /// Optional: a one-line description of what staking does on this coin
        /// (term length, how returns arrive), shown in the Stake prompt so the
        /// user knows what they're agreeing to before locking funds. Paired with
        /// `wallet_stake`; null reads as empty.
        stake_hint: ?*const fn (ptr: *anyopaque) []const u8 = null,
        /// Optional: the wallet's stakes — what's locked, for how much longer,
        /// and what already came back — normalized to `models.Stake`, newest
        /// first, capped at `limit`. Non-null marks a coin whose Staking tab can
        /// show a live list; `supportsStakeList` keys off this.
        ///
        /// Separate from `wallet_stake` because listing and staking are different
        /// capabilities: a coin could offer the action before anyone works out
        /// how to enumerate its locked funds, and the tab still earns its place
        /// (the action alone). A front-end asks each question of its own hook.
        wallet_stakes: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            limit: usize,
        ) anyerror![]models.Stake = null,
        /// Optional: the daemon's live CPU-mining state (whether it's mining, on
        /// how many threads, at what hashrate), normalized to `MiningStatus`.
        /// Non-null marks a coin whose daemon mines in-process (the CryptoNote
        /// CPU coins — Nerva) and lights up the Mining tab; `supportsMining`
        /// keys off this. Wired together with `mining_start`/`mining_stop`.
        mining_status: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!models.MiningStatus = null,
        /// Optional: start the daemon mining on `threads` CPU threads, paying
        /// block rewards to `address` (the wallet's own receive address — the
        /// frontend supplies its cached one, so mining always pays the wallet
        /// the user can see). Paired with `mining_status`.
        mining_start: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            address: []const u8,
            threads: u32,
        ) anyerror!void = null,
        /// Optional: stop the daemon mining. Paired with `mining_status`.
        mining_stop: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!void = null,
        /// Optional: encrypt the (currently unencrypted) wallet with `passphrase`.
        /// Bitcoin-derived daemons stop themselves after this — the caller restarts
        /// them. Paired with `wallet_security_state`; null when unsupported.
        wallet_encrypt: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            passphrase: []const u8,
        ) anyerror!void = null,
        /// Optional: unlock the wallet with `passphrase`. `staking` requests an
        /// unlock-for-staking (proof-of-stake coins) rather than a full unlock.
        /// Paired with `wallet_security_state`; null when unsupported.
        wallet_unlock: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            passphrase: []const u8,
            staking: bool,
        ) anyerror!void = null,
        /// Optional: re-lock an unlocked wallet (`walletlock`, no passphrase).
        /// Paired with `wallet_security_state`; null when unsupported.
        wallet_lock: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!void = null,
        /// Optional: write a wallet backup file to `dest_path` (bitcoin-core
        /// `dumpwallet` — a human-readable dump of the wallet's keys + HD seed,
        /// which the user keeps as their backup). Requires the wallet
        /// unlocked/unencrypted. Distinct from `ExternalWallet.restore_file`
        /// (the Monero path); null for coins without a file-backup wallet.
        wallet_backup: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            dest_path: []const u8,
        ) anyerror!void = null,
        /// Optional: import a wallet backup from `src_path` (bitcoin-core
        /// `importwallet`, which rescans). Requires the wallet
        /// unlocked/unencrypted; null when unsupported.
        wallet_import_file: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            src_path: []const u8,
        ) anyerror!void = null,
        /// Optional: restore a wallet by replacing the coin's managed wallet file
        /// with a user-supplied backup, performed OFFLINE (daemon stopped) — for
        /// old daemons whose backup is a binary `wallet.dat` copy and that have no
        /// `importwallet` RPC (SpiderByte). The app stops the daemon, calls this,
        /// then restarts it, so the restored wallet is loaded cleanly. This hook
        /// only touches files; it takes no auth (the daemon is down). Distinct from
        /// `wallet_import_file` (bitcoin-core `importwallet`, which runs over RPC on
        /// a *live* daemon and merges keys into the open wallet). Null = unsupported.
        wallet_restore_file_offline: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            home_dir: []const u8,
            src_path: []const u8,
        ) anyerror!void = null,
        /// Optional: restore an **in-daemon** wallet from a BIP39 mnemonic, with
        /// the daemon stopped. The counterpart of `ExternalWallet.restore_seed`
        /// for the bitcoin-family shape, where there is no separate wallet
        /// process to hand the phrase to.
        ///
        /// The caller stops the daemon first and restarts it afterwards (the same
        /// orchestration `wallet_restore_file_offline` uses — it is the identical
        /// precondition, and both end in a wallet file the daemon must be down to
        /// replace). `install_root` is provided because the restore may have to
        /// run the coin's own daemon to mint the wallet; `detail` receives the
        /// daemon's real failure text so a bad phrase can be told from a bad
        /// install.
        ///
        /// `seed` may be a mnemonic **or** a raw hex seed where the coin accepts
        /// one (Divi's `-hdseed`); the implementation tells them apart
        /// (`bip39.looksLikeHexSeed`) rather than the front-end asking which the
        /// user holds. `passphrase` is the **BIP39 passphrase** (the "25th word"),
        /// empty for none — *not* the wallet encryption password. It matters more
        /// than it looks: the same words with and without one derive entirely
        /// different wallets, so getting it wrong restores an empty wallet instead
        /// of failing. A coin that can't apply it to the form given should refuse
        /// rather than drop it silently.
        ///
        /// **Both are secrets.** Implementations normalize the seed
        /// (`models.normalizeSeedWords`), keep both out of any conf the user's
        /// daemon reads and off any long-lived command line, and wipe every
        /// working copy. Null = unsupported.
        /// What `wallet_backup` produces. Defaults to `key_dump`, the
        /// conservative answer: a coin that hasn't said keeps the old behaviour of
        /// hiding backup on a locked wallet. Coins whose backup is `backupwallet`
        /// declare `file_copy` and get it in every state.
        wallet_backup_kind: BackupKind = .key_dump,
        /// Optional: read the wallet's HD seed back out for the user to write
        /// down (the `w` menu's "Show recovery seed"). The counterpart of the
        /// seed *restore* — without it a coin can restore from a phrase the user
        /// was never given, which is a backup story with a hole in the middle.
        ///
        /// Needs a readable wallet: the daemon refuses on a locked one (divid
        /// answers -13), so the menu offers it only when unencrypted or unlocked.
        /// The result is the secret — see `SeedBackup`.
        wallet_seed_backup: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
            detail: *WalletErrSink,
        ) anyerror!SeedBackup = null,
        wallet_restore_seed: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            seed: []const u8,
            passphrase: []const u8,
            /// Encrypts the restored wallet. A wallet rebuilt from a seed is a
            /// *fresh* one and so unencrypted; without this, restoring over an
            /// encrypted wallet silently strips its password — same funds, no
            /// longer protected. Empty means "leave it unencrypted", which the
            /// front-end must state at the confirm rather than quietly assume.
            wallet_password: []const u8,
            detail: *WalletErrSink,
        ) anyerror!void = null,
        /// Word counts the in-daemon `wallet_restore_seed` accepts, for the seed
        /// prompt and its live counter. The managed shape reads the same thing
        /// off `ExternalWallet.seed_word_counts`; this is where a coin with no
        /// wallet *process* declares it. Empty unless `wallet_restore_seed` is
        /// wired — `seedWordCounts` falls back to the Monero-style 25 otherwise,
        /// which is the wrong answer for a BIP39 coin.
        restore_seed_word_counts: []const usize = &.{},
        /// Optional: the on-disk location of the coin's managed wallet, for the
        /// Settings tab. Returns null for coins BoxWallet manages no discrete
        /// wallet file for (Ergo's node-internal wallet, Epic's node-only build,
        /// Zano). Caller owns the returned struct's strings (built on `allocator`).
        wallet_path: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror!?WalletFile = null,
        /// Optional: the JSON-RPC method to probe for the daemon's warm-up phase
        /// (the bitcoin-derived "-28 in warm-up" reply carries a phase string like
        /// "Verifying blocks…"). Returns a method the daemon supports (`getinfo` /
        /// `getnetworkinfo`); null for coins with no such warm-up (Ergo, Zano,
        /// Nerva), whose loading phase is always reported as `none`.
        warmup_probe_method: ?*const fn (ptr: *anyopaque) []const u8 = null,
        /// Optional: classify a warm-up phase from a `debug.log` tail, for
        /// NovaCoin-era daemons (SpiderByte) that predate the `-28` RPC warm-up —
        /// their RPC is up while the block index loads but can't answer yet, so a
        /// poll just fails and the only signal is a marker they log. Called only
        /// when the RPC probe found no phase and the daemon is believed up. Null
        /// for coins whose warm-up is fully visible over RPC (the common case).
        warmup_phase_from_log: ?*const fn (ptr: *anyopaque, tail: []const u8) models.LoadingPhase = null,
        /// Optional: the daemon's own wording for the start-up stage it's at,
        /// read from a tail of its log. Returns a display-ready string (empty
        /// when the log shows no start-up in progress); the returned slice must
        /// outlive the tail, so it is a static string, not a slice into it.
        ///
        /// For a coin whose start-up is invisible over RPC this is the *only*
        /// source: the epee family (Monero, Nerva, Salvium, Zano) brings its RPC
        /// server up last, so nothing can be asked until the load is already
        /// over. Those four share `warmup.epeeStage`. Null (the common case)
        /// leaves the generic bitcoin-family `init message:` scrape to it.
        warmup_stage_from_log: ?*const fn (ptr: *anyopaque, tail: []const u8) []const u8 = null,
        /// Optional: the working directory to spawn the daemon in. Null (the
        /// common case) inherits BoxWallet's own, which is right for a daemon that
        /// takes every path as an argument and writes nothing relative.
        ///
        /// Ergo needs it: its logback config writes `ergo.log` relative, so the
        /// node scatters its log — and any JVM crash dump — into whatever
        /// directory BoxWallet happened to be launched from, where nothing can
        /// find it. Pointing the child at the data dir puts the log beside the
        /// chain it describes, which is what `daemon_log_file` promises. Caller
        /// owns the returned path (built on `allocator`).
        daemon_cwd: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror!?[]const u8 = null,
        /// Optional: a fragment of the daemon's command line that identifies its
        /// process, for a daemon that doesn't run under its own name. Ergo is
        /// `java -jar ergo-<ver>.jar`, so the OS sees `java` and a liveness check
        /// against `daemon_file` finds nothing. Must be specific to this coin —
        /// it's matched against every process's command line. Null (the common
        /// case) means the daemon runs as `daemon_file` and is matched by name.
        daemon_process_cmdline: ?*const fn (ptr: *anyopaque) []const u8 = null,
        /// Optional: the daemon's own log file, as a name relative to the coin's
        /// data dir (`debug.log` for bitcoin-derived daemons, `nerva.log` /
        /// `salvium.log` / `zanod.log` for the epee family). Its tail is read to
        /// surface a startup-failure reason for daemons whose fatal init errors
        /// go to their log/console rather than stderr. Null for coins with no
        /// fixed daemon log under the data dir (Ergo logs to the CWD; Epic's
        /// failures land on stderr).
        daemon_log_file: ?*const fn (ptr: *anyopaque) []const u8 = null,
        /// Optional: whether this daemon has Bitcoin Core 24+'s headers
        /// *pre-synchronization* pass, where headers are downloaded in a
        /// throwaway anti-DoS pass without being committed. Null (the default)
        /// means yes — every bitcoin-derived coin has it. Coins on a different
        /// lineage (e.g. Ergo) wire this to `false` so the frontend's
        /// "committed header height is stalled → presync" inference, which only
        /// describes Core's behaviour, never fires for them.
        has_header_presync: ?*const fn (ptr: *anyopaque) bool = null,
        /// Optional: the external-wallet capability (Monero-style coins whose
        /// wallet is a separate RPC process). Null for coins with an in-daemon
        /// wallet or none. `hasExternalWallet` keys off this being non-null.
        external_wallet: ?*const ExternalWallet = null,
        /// Optional: one-shot hook run the first time the chain is observed fully
        /// synced (with at least one peer, so a momentary pre-peer "synced" read
        /// doesn't fire it). Nerva uses it to delete its `quicksync.raw` once the
        /// sync it accelerated is done, reclaiming ~130 MB; left null for coins with
        /// nothing to clean up. Best-effort — a failure is ignored and not retried.
        on_synced: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
        ) anyerror!void = null,
        /// Optional: the sync-accelerator capability (Nerva's quicksync). Null for
        /// coins with no such helper. `syncAccelerator`/`offersSyncAccelerator` key
        /// off this.
        sync_accelerator: ?*const SyncAccelerator = null,
        /// Optional: the block-pruning capability (the first-start prune prompt —
        /// Bitcoin, Litecoin, Monero). Null for coins with no prune prompt.
        /// `pruning`/`offersPrunePrompt` key off this.
        pruning: ?*const Pruning = null,
        /// Optional: the stablecoin capability (DigiByte's DigiDollar). Null for
        /// coins with no chain-issued stablecoin. `stablecoin`/`supportsStablecoin`
        /// key off this; non-null lights up the coin's stablecoin tab.
        stablecoin: ?*const Stablecoin = null,
        /// Optional: payments by slate file (Epic). `slateFiles`/
        /// `supportsSlateFiles` key off this.
        slate_files: ?*const SlateFiles = null,
        /// Optional: the group-token capability (Nexa's tokens and NFTs). Null
        /// for coins with no chain-issued tokens. `tokens`/`supportsTokens` key
        /// off this; non-null lights up the coin's Tokens tab.
        tokens: ?*const Tokens = null,
        /// Optional: the block-index rebuild capability (the repair for a daemon
        /// that aborts during init on a corrupt index). Null for coins with no
        /// such repair. `reindex`/`supportsReindex` key off this.
        reindex: ?*const Reindex = null,
        /// Optional: read where this coin's chain data is being read from, into
        /// `buf`. An empty answer means BoxWallet's own managed daemon on
        /// localhost; anything else is the base URL of a node someone else runs.
        /// Null — the default, and every coin but Epic — means the question
        /// doesn't arise: there is only the local daemon.
        ///
        /// Deliberately **two flat hooks rather than a capability struct**. One
        /// coin offers this, so there is nothing yet to generalize from; a
        /// `Pruning`-shaped struct would be a guess at a shape a second coin has
        /// never asked for. The coin owns everything else — how the setting is
        /// stored, what a valid URL is, what it does with the answer.
        ///
        /// `buf` is the caller's fixed buffer (`node_url_max`), so the read
        /// allocates nothing; `allocator` is for the coin's own working set. A
        /// URL longer than `buf` is truncated to empty rather than clipped — a
        /// half URL is worse than falling back to the local daemon.
        node_source: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            buf: []u8,
        ) []const u8 = null,
        /// Optional: persist where this coin reads its chain data from. `url`
        /// empty restores BoxWallet's own managed daemon; otherwise it is a base
        /// URL the coin validates and rejects (`error.InvalidNodeUrl`) if it
        /// isn't one it can use. Paired with `node_source` — a coin wires both or
        /// neither, which `offersNodeChoice` checks.
        set_node_source: ?*const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
            url: []const u8,
        ) anyerror!void = null,
        /// Optional: the node to suggest when the user picks "someone else's
        /// node" and hasn't named one yet — the coin's community node, so the
        /// common case is confirming an address rather than knowing one.
        ///
        /// A **suggestion, not a default mode.** It only ever prefills the
        /// address field; a coin still starts out on its own daemon, and nothing
        /// here changes that. Shipping a third party as the out-of-the-box
        /// destination for a wallet's queries is a choice for the user to make,
        /// not one to inherit.
        ///
        /// Plain data rather than a hook because it is a constant per coin, like
        /// the conf filename. Empty (the default) means the coin suggests
        /// nothing and the field opens blank.
        node_default_remote: []const u8 = "",
        /// What a node address looks like, shown under the address field in
        /// both front-ends so nobody has to guess the shape (scheme? port?).
        /// Empty for a coin without the node choice.
        node_address_example: []const u8 = "",
    };

    /// Bound on a node URL, shared by every caller's buffer so the front-ends,
    /// the C ABI and the coin agree on one size. Generous for a host:port and
    /// short enough to sit on a stack frame.
    pub const node_url_max = 128;

    /// Bound on a payment-relay address (`ExternalWallet.relay_source`).
    pub const relay_max = 96;

    /// What using someone else's node costs, shown beside that choice in both
    /// front-ends. Held here for the same reason as `accel_trust_note`: the
    /// tradeoff is a property of pointing a wallet at a node you don't run, not
    /// of whichever coin happens to offer it, so it isn't copy for a coin file to
    /// own or for a UI to reword.
    ///
    /// All three claims are things that are simply true of the arrangement, not
    /// worst cases: the node answers the wallet's queries, so it learns them; the
    /// wallet believes what it's told about the tip and about confirmations,
    /// because there's no local chain to check against; and when the node is down
    /// the wallet has no chain at all.
    pub const remote_node_caution =
        "A remote node sees every output your wallet asks about, can misreport " ++
        "the chain tip and your confirmation counts, and takes your wallet " ++
        "offline whenever it's down. Your own node answers to nobody — it just " ++
        "has to download and verify the chain first.";

    /// The other side of the same choice, for the row that runs its own node.
    pub const local_node_note =
        "Nothing leaves this machine, and your node proves every block for itself.";

    pub fn coinName(self: Coin) []const u8 {
        return self.vtable.coin_name(self.ptr);
    }
    pub fn coinNameAbbrev(self: Coin) []const u8 {
        return self.vtable.coin_name_abbrev(self.ptr);
    }
    /// A short one-line description of the coin (shown under its name).
    pub fn coinDescription(self: Coin) []const u8 {
        return self.vtable.coin_description(self.ptr);
    }
    /// The coin's brand colour as a `#RRGGBB` hex string.
    pub fn coinColor(self: Coin) []const u8 {
        return self.vtable.coin_color(self.ptr);
    }
    /// The coin's own donation/tip address, for the "TIP" line on the detail
    /// pane.
    pub fn tipAddress(self: Coin) []const u8 {
        return self.vtable.tip_address(self.ptr);
    }
    /// The coin's two-tone wordmark, or null if its name is a single colour.
    pub fn wordmark(self: Coin) ?Wordmark {
        if (self.vtable.wordmark) |f| return f(self.ptr);
        return null;
    }
    /// The bundled core version this coin installs (e.g. "2.0.0.0").
    pub fn coreVersion(self: Coin) []const u8 {
        return self.vtable.core_version(self.ptr);
    }
    /// True for proof-of-stake coins (which expose a staking status).
    pub fn isProofOfStake(self: Coin) bool {
        return self.vtable.proof_of_stake(self.ptr);
    }
    /// This coin's id on the price host, or null when it isn't listed there (so
    /// it shows no USD price and is left out of the request entirely).
    pub fn priceId(self: Coin) ?[]const u8 {
        if (self.vtable.price_id) |f| return f(self.ptr);
        return null;
    }

    /// This coin's own price endpoint, or null when it takes the roster host's
    /// number (nearly all of them). A coin has at most one of `priceId` and
    /// `priceSource`; wiring both would price it twice and let the loser
    /// overwrite the winner depending on which reply landed last.
    pub fn priceSource(self: Coin) ?price.Source {
        if (self.vtable.price_source) |f| return f(self.ptr);
        return null;
    }

    /// The number of decimal places balances are displayed to (default 8). Used
    /// to render every balance figure at fixed width — including a zero, which
    /// shows as "0.<decimals zeros>" rather than a bare "0".
    pub fn balanceDecimals(self: Coin) u8 {
        if (self.vtable.balance_decimals) |f| return f(self.ptr);
        return 8;
    }
    pub fn confFile(self: Coin) []const u8 {
        return self.vtable.conf_file(self.ptr);
    }
    pub fn daemonFile(self: Coin) []const u8 {
        return self.vtable.daemon_file(self.ptr);
    }
    pub fn rpcDefaultPort(self: Coin) []const u8 {
        return self.vtable.rpc_default_port(self.ptr);
    }
    pub fn rpcDefaultUsername(self: Coin) []const u8 {
        return self.vtable.rpc_default_username(self.ptr);
    }
    pub fn blockchainState(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        return self.vtable.blockchain_state(self.ptr, allocator, auth);
    }
    pub fn daemonInfo(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        return self.vtable.daemon_info(self.ptr, allocator, auth);
    }
    pub fn dataDir(
        self: Coin,
        allocator: std.mem.Allocator,
        home_dir: []const u8,
    ) ![]const u8 {
        return self.vtable.data_dir(self.ptr, allocator, home_dir);
    }
    pub fn isInstalled(self: Coin, allocator: std.mem.Allocator, install_root: []const u8) bool {
        return self.vtable.is_installed(self.ptr, allocator, install_root);
    }

    /// The installed daemon binary's own version, probed offline. `null` when the
    /// coin wires no probe (its daemon reports the version over RPC instead);
    /// errors when the probe ran but couldn't answer. Caller owns the string.
    pub fn probeInstalledVersion(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
    ) !?[]const u8 {
        const f = self.vtable.installed_version_probe orelse return null;
        return try f(self.ptr, allocator, install_root);
    }
    pub fn install(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        return self.vtable.install(self.ptr, allocator, install_root, home_dir, progress);
    }
    pub fn prepareConf(
        self: Coin,
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        home_dir: []const u8,
    ) !void {
        return self.vtable.prepare_conf(self.ptr, allocator, io, install_root, home_dir);
    }
    pub fn launchMode(self: Coin) LaunchMode {
        return self.vtable.launch_mode(self.ptr);
    }
    pub fn daemonArgv(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
    ) ![]const []const u8 {
        return self.vtable.daemon_argv(self.ptr, allocator, install_root, home_dir);
    }
    /// Whether this coin's daemon can be shut down over RPC. False means the
    /// caller must stop it by killing the process (zanod has no shutdown RPC).
    pub fn hasRpcStop(self: Coin) bool {
        return self.vtable.request_stop != null;
    }
    pub fn requestStop(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !void {
        return self.vtable.request_stop.?(self.ptr, allocator, auth);
    }

    /// Whether this coin needs an explicit wallet created/loaded after the daemon
    /// starts (true for the Bitcoin-Core 0.21+ forks that don't auto-create one).
    pub fn needsWallet(self: Coin) bool {
        return self.vtable.ensure_wallet != null;
    }

    /// Ensure the coin's wallet is loaded (creating it on first run). A no-op for
    /// coins that don't need it (`needsWallet` false).
    pub fn ensureWallet(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !void {
        if (self.vtable.ensure_wallet) |f| return f(self.ptr, allocator, auth);
    }

    /// The coin's managed wallet location for the Settings tab, or null when the
    /// coin has no single discrete wallet file (or no hook wired). Caller owns
    /// the returned struct's strings.
    pub fn walletPath(
        self: Coin,
        allocator: std.mem.Allocator,
        home_dir: []const u8,
    ) !?WalletFile {
        const f = self.vtable.wallet_path orelse return null;
        return f(self.ptr, allocator, home_dir);
    }

    /// Whether this coin exposes a wallet BoxWallet can manage (drives the `w`
    /// menu). True iff the coin wires `wallet_security_state`.
    pub fn supportsWallet(self: Coin) bool {
        return self.vtable.wallet_security_state != null;
    }

    /// Read the wallet's security state. `unknown` for coins without wallet
    /// support (`supportsWallet` false).
    pub fn walletSecurityState(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        if (self.vtable.wallet_security_state) |f| return f(self.ptr, allocator, auth);
        return .unknown;
    }

    /// Whether this coin reports a wallet balance over RPC (drives the
    /// Total/Available lines). True iff the coin wires `wallet_balance`.
    pub fn supportsBalance(self: Coin) bool {
        return self.vtable.wallet_balance != null;
    }

    /// Read the wallet's balances. Errors `error.Unsupported` if the coin reports
    /// no balance (`supportsBalance` false).
    pub fn walletBalance(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        const f = self.vtable.wallet_balance orelse return error.Unsupported;
        return f(self.ptr, allocator, auth);
    }

    /// Whether this coin reports a wallet transaction history over RPC (drives
    /// the Transactions tab). True iff the coin wires `wallet_transactions`.
    pub fn supportsTransactions(self: Coin) bool {
        return self.vtable.wallet_transactions != null;
    }

    /// Read the wallet's most recent transactions, capped at `limit` entries.
    /// Errors `error.Unsupported` if the coin reports no transaction history
    /// (`supportsTransactions` false).
    pub fn walletTransactions(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) ![]models.WalletTx {
        const f = self.vtable.wallet_transactions orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, limit);
    }

    /// Whether this coin reports a receive address over RPC (drives the
    /// Receive tab). True iff the coin wires `wallet_receive_address`.
    pub fn supportsReceiveAddress(self: Coin) bool {
        return self.vtable.wallet_receive_address != null;
    }

    /// See `spendable_confirmations`; 0 when the coin doesn't declare one.
    pub fn spendableConfirmations(self: Coin) u32 {
        return self.vtable.spendable_confirmations;
    }

    /// Whether the Receive tab offers "new address": the coin has a receive
    /// address, and it isn't one fixed for the wallet's life.
    pub fn canNewReceiveAddress(self: Coin) bool {
        return self.supportsReceiveAddress() and self.vtable.receive_address_fixed_note.len == 0;
    }

    /// Why a coin offers no new address (`receive_address_fixed_note`), or empty.
    pub fn receiveAddressFixedNote(self: Coin) []const u8 {
        return self.vtable.receive_address_fixed_note;
    }

    /// Read the wallet's receive address. `force_new` true mints a brand-new
    /// address; false gets the stable "current" one. Errors
    /// `error.Unsupported` if the coin reports no receive address
    /// (`supportsReceiveAddress` false).
    pub fn walletReceiveAddress(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) ![]const u8 {
        const f = self.vtable.wallet_receive_address orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, force_new);
    }

    /// Whether this coin can send funds over RPC (drives the Send tab). True
    /// iff the coin wires `wallet_send`.
    pub fn supportsSend(self: Coin) bool {
        return self.vtable.wallet_send != null;
    }

    /// Send `amount` to `address`. Errors `error.Unsupported` if the coin
    /// reports no send capability (`supportsSend` false); otherwise returns
    /// the outcome (success or a daemon-reported failure reason) rather than
    /// erroring on a rejected send.
    pub fn walletSend(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) !models.SendResult {
        const f = self.vtable.wallet_send orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, address, amount);
    }

    /// The longest note a send can carry (drives the note field on the send
    /// prompt), 0 when this coin's sends carry none.
    pub fn sendNoteMax(self: Coin) usize {
        if (self.vtable.wallet_send_note == null) return 0;
        return @min(self.vtable.send_note_max, models.tx_note_max);
    }

    /// Send `amount` to `address` with `note` attached, cleaned by
    /// `models.sanitizeNote`. An empty note is a plain `walletSend`. A note on a coin that can't carry one,
    /// or one longer than `sendNoteMax`, is refused as `.failed` rather than
    /// quietly dropped — the user asked for it to go with the payment.
    pub fn walletSendNote(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
        note: []const u8,
    ) !models.SendResult {
        // The same cleaning a received note gets, so what goes out is what the
        // receiver's wallet (ours or not) can show safely.
        const trimmed = std.mem.trim(u8, note, " \t\r\n");
        if (trimmed.len == 0) return self.walletSend(allocator, auth, address, amount);
        const max = self.sendNoteMax();
        if (max == 0) return .{ .failed = "This coin's payments can't carry a note." };
        if (trimmed.len > max) return .{ .failed = "The note is too long." };
        var buf: [models.tx_note_max]u8 = undefined;
        const clean = models.sanitizeNote(&buf, trimmed);
        if (clean.len == 0) return .{ .failed = "The note isn't readable text." };
        return self.vtable.wallet_send_note.?(self.ptr, allocator, auth, address, amount, clean);
    }

    /// Whether the coin can state a send's fee before it's made (drives the fee
    /// line on the send confirm step). True iff the coin wires `wallet_send_fee`.
    pub fn supportsSendFee(self: Coin) bool {
        return self.vtable.wallet_send_fee != null;
    }

    /// What sending `amount` to `address` would cost. Errors
    /// `error.Unsupported` if the coin can't say (`supportsSendFee` false).
    pub fn walletSendFee(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) !models.FeeEstimate {
        const f = self.vtable.wallet_send_fee orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, address, amount);
    }

    /// Whether the coin can cancel an unsent transaction (drives the
    /// Transactions tab's cancel action). True iff it wires `wallet_cancel_tx`.
    pub fn supportsCancelTx(self: Coin) bool {
        return self.vtable.wallet_cancel_tx != null;
    }

    /// Cancel the transaction `txid` (a `cancellable` row's id). Errors
    /// `error.Unsupported` if the coin can't (`supportsCancelTx` false).
    pub fn walletCancelTx(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        txid: []const u8,
    ) !models.SendResult {
        const f = self.vtable.wallet_cancel_tx orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, txid);
    }

    /// The coin's own lead-in for a successful send's result, or empty to keep
    /// the front-end's default ("Sent. Txid:").
    pub fn sendOkLabel(self: Coin) []const u8 {
        return self.vtable.send_ok_label;
    }

    /// Whether this coin offers an explicit stake action (drives the Send tab's
    /// Stake prompt). True iff the coin wires `wallet_stake`. Distinct from
    /// `isProofOfStake` (coins that stake passively while unlocked).
    pub fn supportsStakeAction(self: Coin) bool {
        return self.vtable.wallet_stake != null;
    }

    /// Stake `amount` for the coin's staking term. Errors `error.Unsupported`
    /// if the coin has no stake action (`supportsStakeAction` false); otherwise
    /// returns the outcome (success or a daemon-reported failure reason) rather
    /// than erroring on a rejected stake.
    pub fn walletStake(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        amount: f64,
    ) !models.SendResult {
        const f = self.vtable.wallet_stake orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, amount);
    }

    /// The coin's one-line staking description for the Stake prompt, or "" when
    /// none is wired.
    pub fn stakeHint(self: Coin) []const u8 {
        if (self.vtable.stake_hint) |f| return f(self.ptr);
        return "";
    }

    /// Whether this coin can enumerate the wallet's stakes (drives the Staking
    /// tab's list). True iff the coin wires `wallet_stakes`.
    pub fn supportsStakeList(self: Coin) bool {
        return self.vtable.wallet_stakes != null;
    }

    /// The wallet's stakes, newest first, capped at `limit`. Errors
    /// `error.Unsupported` if the coin can't enumerate them
    /// (`supportsStakeList` false).
    pub fn walletStakes(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) ![]models.Stake {
        const f = self.vtable.wallet_stakes orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, limit);
    }

    /// Whether this coin's daemon mines in-process (drives the Mining tab).
    /// True iff the coin wires the full status/start/stop trio.
    pub fn supportsMining(self: Coin) bool {
        return self.vtable.mining_status != null and
            self.vtable.mining_start != null and
            self.vtable.mining_stop != null;
    }

    /// The daemon's live mining state. Errors `error.Unsupported` if the coin
    /// doesn't mine (`supportsMining` false).
    pub fn miningStatus(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.MiningStatus {
        const f = self.vtable.mining_status orelse return error.Unsupported;
        return f(self.ptr, allocator, auth);
    }

    /// Start mining on `threads` CPU threads, paying block rewards to
    /// `address`. Errors `error.Unsupported` if the coin doesn't mine.
    pub fn miningStart(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        threads: u32,
    ) !void {
        const f = self.vtable.mining_start orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, address, threads);
    }

    /// Stop mining. Errors `error.Unsupported` if the coin doesn't mine.
    pub fn miningStop(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !void {
        const f = self.vtable.mining_stop orelse return error.Unsupported;
        return f(self.ptr, allocator, auth);
    }

    /// Whether this coin's wallet can be *encrypted* in-app. Distinct from
    /// `supportsWallet`: a coin can report/manage its wallet state while its
    /// daemon refuses `encryptwallet` outright (BitcoinZ, whose zcashd lineage
    /// ships wallet encryption disabled) — the `w` menu then skips the Encrypt
    /// action instead of offering one that can only fail.
    pub fn supportsWalletEncrypt(self: Coin) bool {
        return self.vtable.wallet_encrypt != null;
    }

    /// Encrypt the wallet with `passphrase`. Errors `error.Unsupported` if the
    /// coin has no manageable wallet.
    pub fn walletEncrypt(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
    ) !void {
        const f = self.vtable.wallet_encrypt orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, passphrase);
    }

    /// Unlock the wallet with `passphrase` (`staking` for unlock-for-staking).
    /// Errors `error.Unsupported` if the coin has no manageable wallet.
    pub fn walletUnlock(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
        staking: bool,
    ) !void {
        const f = self.vtable.wallet_unlock orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, passphrase, staking);
    }

    /// Re-lock the wallet. Errors `error.Unsupported` if the coin has no
    /// manageable wallet.
    pub fn walletLock(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !void {
        const f = self.vtable.wallet_lock orelse return error.Unsupported;
        return f(self.ptr, allocator, auth);
    }

    /// Whether this coin can back up its wallet to a file (the `w` menu's "Back
    /// up wallet"). True iff the coin wires `wallet_backup`.
    pub fn supportsWalletBackup(self: Coin) bool {
        return self.vtable.wallet_backup != null;
    }

    /// What `wallet_backup` produces — a key dump or a file copy. Decides whether
    /// the action survives a locked wallet; see `BackupKind`.
    pub fn backupKind(self: Coin) BackupKind {
        return self.vtable.wallet_backup_kind;
    }

    /// Whether this coin can show the user its wallet's recovery seed (the `w`
    /// menu's "Show recovery seed"). True iff the coin wires `wallet_seed_backup`.
    pub fn supportsSeedBackup(self: Coin) bool {
        return self.vtable.wallet_seed_backup != null;
    }

    /// Read the wallet's recovery seed for the user to write down. Needs an
    /// unlocked (or unencrypted) wallet. Errors `error.Unsupported` if the coin
    /// has no seed backup.
    pub fn walletSeedBackup(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        detail: *WalletErrSink,
    ) !SeedBackup {
        const f = self.vtable.wallet_seed_backup orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, detail);
    }

    /// Write a wallet backup to `dest_path`. Errors `error.Unsupported` if the
    /// coin has no file-backup wallet.
    pub fn walletBackup(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        dest_path: []const u8,
    ) !void {
        const f = self.vtable.wallet_backup orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, dest_path);
    }

    /// Whether this coin can import a wallet backup from a file (the `w` menu's
    /// "Restore from file"). True iff the coin wires `wallet_import_file`.
    pub fn supportsWalletImport(self: Coin) bool {
        return self.vtable.wallet_import_file != null;
    }

    /// Import a wallet backup from `src_path`. Errors `error.Unsupported` if the
    /// coin has no file-backup wallet.
    pub fn walletImportFile(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        src_path: []const u8,
    ) !void {
        const f = self.vtable.wallet_import_file orelse return error.Unsupported;
        return f(self.ptr, allocator, auth, src_path);
    }

    /// Whether this coin can restore its wallet by an offline file swap (the `w`
    /// menu's "Restore from a wallet file", daemon-stopped). True iff the coin
    /// wires `wallet_restore_file_offline`. Distinct from `supportsWalletImport`.
    pub fn supportsWalletRestoreOffline(self: Coin) bool {
        return self.vtable.wallet_restore_file_offline != null;
    }

    /// Restore the wallet by replacing its managed file with the backup at
    /// `src_path` (daemon must be stopped by the caller). Errors
    /// `error.Unsupported` if the coin has no offline file restore.
    pub fn walletRestoreFileOffline(
        self: Coin,
        allocator: std.mem.Allocator,
        home_dir: []const u8,
        src_path: []const u8,
    ) !void {
        const f = self.vtable.wallet_restore_file_offline orelse return error.Unsupported;
        return f(self.ptr, allocator, home_dir, src_path);
    }

    /// Whether this coin can restore its in-daemon wallet from a mnemonic (the
    /// `w` menu's "Restore from seed words"). True iff the coin wires
    /// `wallet_restore_seed`. Distinct from `supportsSeedRestore`, which answers
    /// the same question for the *managed* wallet shape.
    pub fn supportsWalletRestoreSeed(self: Coin) bool {
        return self.vtable.wallet_restore_seed != null;
    }

    /// Restore the in-daemon wallet from the BIP39 mnemonic `seed` (daemon must
    /// be stopped by the caller, and restarted after). `detail` receives the real
    /// failure reason. Errors `error.Unsupported` if the coin has no seed
    /// restore.
    pub fn walletRestoreSeed(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
        seed: []const u8,
        passphrase: []const u8,
        wallet_password: []const u8,
        detail: *WalletErrSink,
    ) !void {
        const f = self.vtable.wallet_restore_seed orelse return error.Unsupported;
        return f(self.ptr, allocator, install_root, home_dir, seed, passphrase, wallet_password, detail);
    }

    /// The RPC method to probe for a warm-up phase, or null for coins with no
    /// bitcoin-style warm-up (their loading phase is always `none`).
    pub fn warmupProbeMethod(self: Coin) ?[]const u8 {
        if (self.vtable.warmup_probe_method) |f| return f(self.ptr);
        return null;
    }

    /// The working directory to spawn the daemon in, or null to inherit ours.
    /// Caller owns the returned path.
    pub fn daemonCwd(
        self: Coin,
        allocator: std.mem.Allocator,
        home_dir: []const u8,
    ) !?[]const u8 {
        const f = self.vtable.daemon_cwd orelse return null;
        return f(self.ptr, allocator, home_dir);
    }

    /// A command-line fragment identifying this coin's daemon process, for a
    /// daemon that doesn't run under its own name (Ergo: `java -jar ergo-x.jar`).
    /// Null for the common case — pass it to `proc.aliveMatching` alongside
    /// `daemonFile()` and a null simply matches by name.
    pub fn daemonProcessCmdline(self: Coin) ?[]const u8 {
        if (self.vtable.daemon_process_cmdline) |f| return f(self.ptr);
        return null;
    }

    /// Classify the daemon's warm-up phase from a `debug.log` tail, for coins
    /// whose warm-up isn't visible over RPC. Returns `.none` for coins that don't
    /// wire the hook (so the caller falls back to whatever the RPC probe found).
    pub fn warmupPhaseFromLog(self: Coin, tail: []const u8) models.LoadingPhase {
        if (self.vtable.warmup_phase_from_log) |f| return f(self.ptr, tail);
        return .none;
    }

    /// The daemon's own wording for the start-up stage it's at, from a tail of
    /// its log. Empty for coins that don't wire the hook, so the caller falls
    /// back to the generic bitcoin-family `init message:` scrape.
    pub fn warmupStageFromLog(self: Coin, tail: []const u8) []const u8 {
        if (self.vtable.warmup_stage_from_log) |f| return f(self.ptr, tail);
        return "";
    }

    /// The daemon's own log file name (relative to the coin's data dir), or null
    /// for coins that declare none. Read (tail only) for a startup-failure reason
    /// when the daemon died without saying why on stderr.
    pub fn daemonLogFile(self: Coin) ?[]const u8 {
        if (self.vtable.daemon_log_file) |f| return f(self.ptr);
        return null;
    }

    /// Whether the daemon has Core 24+'s headers pre-synchronization pass.
    /// Defaults to true for coins that declare nothing — the bitcoin-derived
    /// majority.
    pub fn hasHeaderPresync(self: Coin) bool {
        if (self.vtable.has_header_presync) |f| return f(self.ptr);
        return true;
    }

    /// Whether this coin drives the external-wallet setup flow (create-returns-seed
    /// / restore / unlock), whether backed by a separate process or in-daemon. True
    /// iff the coin wires `external_wallet`.
    pub fn hasExternalWallet(self: Coin) bool {
        return self.vtable.external_wallet != null;
    }

    /// Whether the external wallet is backed by a *separate process* BoxWallet must
    /// spawn, as opposed to living in the daemon (Ergo). True for both the Monero
    /// model (`process_argv`, spawned once eagerly) and the Zano model
    /// (`launch_server_argv`, (re)launched per-open with the password).
    pub fn hasExternalWalletProcess(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.process_argv != null or ew.launch_server_argv != null;
    }

    /// Whether the wallet process must be (re)launched per-open bound to a specific
    /// wallet file and password (Zano's `simplewallet`), rather than spawned once
    /// password-less (Nerva). True iff the capability wires `launch_server_argv`.
    /// The app skips the eager spawn for these and launches on create/open instead.
    pub fn walletLaunchesWithPassword(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.launch_server_argv != null;
    }

    /// Whether the wallet runs a payment listener alongside its RPC process while
    /// unlocked (Epic's Epicbox listener). True iff the capability wires
    /// `listener_argv`.
    pub fn walletHasListener(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.listener_argv != null;
    }

    /// Whether the external-wallet setup menu offers restore-from-seed (false where
    /// the coin hasn't wired it — Zano). Falls back to false for coins with no
    /// external wallet.
    pub fn supportsSeedRestore(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.supports_seed_restore;
    }

    /// Whether the coin can remove its existing wallet so a different one can be
    /// created/restored (the destructive in-app "Replace wallet"). True iff the
    /// external-wallet capability wires `remove`.
    pub fn supportsWalletReplace(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.remove != null;
    }

    /// The external-wallet capability, or null when the coin has none
    /// (`hasExternalWallet` false). Callers use the fn pointers directly.
    pub fn externalWallet(self: Coin) ?*const ExternalWallet {
        return self.vtable.external_wallet;
    }

    /// Valid restore-seed word counts for the seed-entry UI (canonical length
    /// first). Falls back to `{25}` for coins without an external wallet.
    pub fn seedWordCounts(self: Coin) []const usize {
        const ew = self.vtable.external_wallet orelse {
            // No wallet process: an in-daemon seed restore (Divi) declares its
            // own counts, since the BIP39 lengths aren't the Monero 25 the
            // managed default assumes.
            if (self.vtable.restore_seed_word_counts.len > 0) return self.vtable.restore_seed_word_counts;
            return &.{25};
        };
        return ew.seed_word_counts;
    }

    /// Run the coin's post-sync hook (a no-op for coins that wire none). The caller
    /// is responsible for invoking this only once, when the chain first reads as
    /// fully synced.
    pub fn onSynced(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
    ) !void {
        if (self.vtable.on_synced) |f| return f(self.ptr, allocator, install_root, home_dir);
    }

    /// The coin's sync-accelerator capability, or null when it has none.
    pub fn syncAccelerator(self: Coin) ?*const SyncAccelerator {
        return self.vtable.sync_accelerator;
    }

    /// Whether to offer the coin's sync accelerator before launching the daemon —
    /// false for coins with none, or when the chain is already synced / the helper
    /// is already in use.
    pub fn offersSyncAccelerator(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
    ) bool {
        const sa = self.vtable.sync_accelerator orelse return false;
        return sa.should_offer(allocator, install_root, home_dir);
    }

    /// Bytes of an interrupted accelerator download waiting to be resumed — 0 for
    /// a coin with no accelerator, or one that doesn't resume.
    pub fn syncAcceleratorPartialBytes(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
    ) u64 {
        const sa = self.vtable.sync_accelerator orelse return 0;
        const f = sa.partial_bytes orelse return 0;
        return f(allocator, install_root, home_dir);
    }

    /// The block-pruning capability, or null when the coin has none. Callers use
    /// the fn pointers directly (apply/current).
    pub fn pruning(self: Coin) ?*const Pruning {
        return self.vtable.pruning;
    }

    /// Whether to show the first-start prune prompt before launching the daemon —
    /// false for coins with no prune capability, or when the conf already carries
    /// a `prune` setting (so it's asked exactly once).
    pub fn offersPrunePrompt(self: Coin, allocator: std.mem.Allocator, home_dir: []const u8) bool {
        const pr = self.vtable.pruning orelse return false;
        return pr.should_offer(allocator, home_dir);
    }

    /// Persist the chosen prune target (MiB; 0 = full node) to the coin's conf.
    /// A no-op error path for coins without the capability.
    pub fn applyPrune(self: Coin, allocator: std.mem.Allocator, home_dir: []const u8, prune_mib: i64) !void {
        const pr = self.vtable.pruning orelse return error.Unsupported;
        return pr.apply(allocator, home_dir, prune_mib);
    }

    /// The configured prune target (MiB, 0, or null when unset) for the Settings
    /// tab, or null for coins without the capability.
    pub fn pruningState(self: Coin, allocator: std.mem.Allocator, home_dir: []const u8) !?i64 {
        const pr = self.vtable.pruning orelse return null;
        return pr.current(allocator, home_dir);
    }

    /// Whether this coin's prune setting can be changed after the first start —
    /// a property of the coin, not of the machine (see `Pruning.can_change`).
    /// Front-ends gate the affordance on this **and** on the daemon being stopped:
    /// the conf is only read at launch, so a change made while it runs would show
    /// a value the running node isn't honouring.
    pub fn offersPruneChange(self: Coin) bool {
        const pr = self.vtable.pruning orelse return false;
        return pr.can_change;
    }

    /// What changing this coin's prune setting costs, for the change confirm.
    /// Empty for a coin that doesn't offer the change.
    pub fn pruneChangeWarning(self: Coin) []const u8 {
        const pr = self.vtable.pruning orelse return "";
        return pr.change_warning;
    }

    /// Whether this coin lets the user choose between BoxWallet's own daemon and
    /// someone else's node. False for every coin that only ever runs its own.
    pub fn offersNodeChoice(self: Coin) bool {
        return self.vtable.node_source != null and self.vtable.set_node_source != null;
    }

    /// Where this coin reads its chain data from: empty for BoxWallet's own
    /// managed daemon, else the base URL of the node it's pointed at. The answer
    /// is written into `buf` (see `node_url_max`) and borrowed from it, so it
    /// lives exactly as long as the caller's buffer.
    pub fn nodeSource(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        buf: []u8,
    ) []const u8 {
        const f = self.vtable.node_source orelse return "";
        return f(self.ptr, allocator, install_root, buf);
    }

    /// Whether BoxWallet runs a daemon for this coin at all. True for every coin
    /// that doesn't offer the choice, and for one that does while it's pointed at
    /// its own daemon. Front-ends gate the whole daemon lifecycle on this — the
    /// Start/Stop affordance, the launch, the warm-up narration, the
    /// startup-failure reason — because none of it has a subject when the node
    /// belongs to someone else.
    pub fn usesLocalDaemon(self: Coin, allocator: std.mem.Allocator, install_root: []const u8) bool {
        var buf: [node_url_max]u8 = undefined;
        return self.nodeSource(allocator, install_root, &buf).len == 0;
    }

    /// The node to offer when the user asks for someone else's and hasn't named
    /// one. Empty when the coin suggests none — the field simply opens blank.
    /// A suggestion only: it never changes which node a coin actually uses.
    pub fn defaultRemoteNode(self: Coin) []const u8 {
        return self.vtable.node_default_remote;
    }

    /// What a node address looks like, for the hint under the address field.
    pub fn nodeAddressExample(self: Coin) []const u8 {
        return self.vtable.node_address_example;
    }

    /// Whether this coin lets the user choose its payment relay (Epic's
    /// Epicbox server).
    pub fn offersRelayChoice(self: Coin) bool {
        const ew = self.externalWallet() orelse return false;
        return ew.relay_source != null and ew.set_relay_source != null;
    }

    /// Persist where this coin reads its chain data from; empty `url` restores
    /// the managed daemon. Errors for a coin without the capability, and with
    /// `error.InvalidNodeUrl` for a URL the coin can't use.
    pub fn setNodeSource(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home_dir: []const u8,
        url: []const u8,
    ) !void {
        const f = self.vtable.set_node_source orelse return error.Unsupported;
        return f(self.ptr, allocator, install_root, home_dir, url);
    }

    /// Whether this coin issues a chain-native stablecoin (drives the
    /// stablecoin tab — DigiByte's DigiDollar). True iff the coin wires
    /// `stablecoin`.
    pub fn supportsStablecoin(self: Coin) bool {
        return self.vtable.stablecoin != null;
    }

    /// The stablecoin capability, or null when the coin has none
    /// (`supportsStablecoin` false). Callers use the fn pointers directly.
    pub fn stablecoin(self: Coin) ?*const Stablecoin {
        return self.vtable.stablecoin;
    }

    /// Whether this coin can pay and be paid by slate file. True iff the coin
    /// wires `slate_files`.
    pub fn supportsSlateFiles(self: Coin) bool {
        return self.vtable.slate_files != null;
    }

    /// The slate-file capability, or null (`supportsSlateFiles` false).
    pub fn slateFiles(self: Coin) ?*const SlateFiles {
        return self.vtable.slate_files;
    }

    /// Whether this coin issues chain-native group tokens and NFTs (drives the
    /// Tokens tab — Nexa). True iff the coin wires `tokens`.
    pub fn supportsTokens(self: Coin) bool {
        return self.vtable.tokens != null;
    }

    /// The group-token capability, or null when the coin has none
    /// (`supportsTokens` false). Callers use the fn pointers directly.
    pub fn tokens(self: Coin) ?*const Tokens {
        return self.vtable.tokens;
    }

    /// Whether this coin's daemon can rebuild its block index (see `Reindex`).
    /// Front-ends gate the affordance on this **and** on the daemon being
    /// stopped — the flag only takes effect at launch, and a rebuild started
    /// under a running daemon would just lose to the datadir lock.
    pub fn supportsReindex(self: Coin) bool {
        return self.vtable.reindex != null;
    }

    /// The block-index rebuild capability, or null when the coin has none.
    pub fn reindex(self: Coin) ?*const Reindex {
        return self.vtable.reindex;
    }

    /// The one-shot argv the launcher appends for a rebuild. Empty for a coin
    /// without the capability, which is what makes `LaunchOptions.reindex` a
    /// no-op there rather than an error — the front-ends never offer it.
    pub fn reindexFlags(self: Coin) []const []const u8 {
        const rx = self.vtable.reindex orelse return &.{};
        return rx.flags;
    }

    /// What a rebuild costs, for the confirm. `pruned` picks the wording for a
    /// node that has already thrown blocks away, where the rebuild re-downloads
    /// the chain instead of merely re-reading it. Empty for a coin without the
    /// capability.
    pub fn reindexWarning(self: Coin, pruned: bool) []const u8 {
        const rx = self.vtable.reindex orelse return "";
        if (pruned and rx.pruned_warning.len != 0) return rx.pruned_warning;
        return rx.warning;
    }
};
