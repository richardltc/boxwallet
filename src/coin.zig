const std = @import("std");
const models = @import("models.zig");
const install_mod = @import("install.zig");

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
        /// Valid word counts for this wallet's restore seed, for the seed-entry
        /// UI's prompt and live word counter (the daemon does the real validation).
        /// The first entry is the canonical length named in the prompt. Monero/
        /// CryptoNote coins use the default `{25}`; Ergo's BIP39 mnemonics accept
        /// `{15, 12, 24}` (15 canonical, what its node generates).
        seed_word_counts: []const usize = &.{25},
    };

    /// An optional **sync accelerator** — a large, opt-in helper file that makes a
    /// coin's *initial* chain sync dramatically faster when present at daemon launch
    /// (Nerva's quicksync: precomputed block hashes wired into `daemon_argv`).
    /// Because it's a big download not everyone wants, BoxWallet offers it as a
    /// yes/no choice when the daemon is started on a chain that isn't synced yet.
    /// Coins with no such file leave `sync_accelerator` null.
    pub const SyncAccelerator = struct {
        /// Short name for the prompt (e.g. "QuickSync").
        name: []const u8,
        /// One-line pitch shown in the prompt (what it does, rough download size).
        prompt_detail: []const u8,
        /// Whether to offer it right now: true only when the chain isn't already
        /// synced *and* the accelerator isn't already present/in use — so a synced
        /// node (or one mid-accelerated-sync) is never prompted. A pure disk check,
        /// so it runs before the daemon is up.
        should_offer: *const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            home_dir: []const u8,
        ) bool,
        /// Download the accelerator into `install_root` (blocking, reporting
        /// progress), called on a worker thread when the user opts in. Surfaces
        /// failures (the user asked for it) and must not leave a partial behind.
        download: *const fn (
            allocator: std.mem.Allocator,
            install_root: []const u8,
            progress: ?install_mod.Progress,
        ) anyerror!void,
    };

    /// An optional **block-pruning** capability — for bitcoin-derived coins whose
    /// chain is large enough that the user is asked, the first time the daemon
    /// starts, how much disk to cap the blockchain at (Litecoin). The choice is
    /// persisted in the coin's conf as `prune=<MiB>` (0 = full node), so it's a
    /// one-time prompt and is read back for the Settings tab. Coins with no such
    /// prompt leave `pruning` null; `offersPrunePrompt`/`pruning` key off it.
    ///
    /// Prune target is always in **MiB**, matching the daemon's `prune=` units; the
    /// UI converts to/from GB for display. 0 disables pruning (keep the whole
    /// chain); a positive value is the on-disk cap (the daemon enforces a ~550 MiB
    /// floor).
    pub const Pruning = struct {
        /// Whether to show the first-start prune prompt now: true only when the
        /// conf carries no `prune` setting yet (a fresh install BoxWallet hasn't
        /// configured, and not a conf the user already pruned themselves). A pure
        /// disk check, so it runs before the daemon is up.
        should_offer: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) bool,
        /// Persist the chosen prune target (MiB; 0 = full node) to the conf,
        /// creating the conf/dir if absent. Called once, before the daemon launches.
        apply: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
            prune_mib: i64,
        ) anyerror!void,
        /// The configured prune target for the Settings tab: MiB, 0 (full node), or
        /// null when the conf carries no `prune` setting. A cheap conf read.
        current: *const fn (
            allocator: std.mem.Allocator,
            home_dir: []const u8,
        ) anyerror!?i64,
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
    /// (`coin_name[0..split]`) in the coin's `coin_color`, the tail
    /// (`coin_name[split..]`) in `alt_color`. Lets a coin brand its name with a
    /// second colour (ReddCoin's "Redd"+"Coin"); single-colour coins leave the
    /// `wordmark` vtable hook null.
    pub const Wordmark = struct {
        /// Byte index in `coin_name` where the `alt_color` half begins.
        split: usize,
        /// Hex `#RRGGBB` for the tail half.
        alt_color: []const u8,
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
        /// Optional: a two-tone wordmark for the coin's name (see `Wordmark`).
        /// Null for coins whose name is drawn in a single colour.
        wordmark: ?*const fn (ptr: *anyopaque) Wordmark = null,
        /// The bundled core version this coin installs (e.g. "2.0.0.0"), shown on
        /// the coin's pane the way the app version rides the Home pane.
        core_version: *const fn (ptr: *anyopaque) []const u8,
        /// True for proof-of-stake coins (which expose a staking status); false
        /// for proof-of-work coins.
        proof_of_stake: *const fn (ptr: *anyopaque) bool,
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
        /// Download + unarchive the daemon files into `install_root`,
        /// optionally reporting download/extract progress.
        install: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            install_root: []const u8,
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
        /// Ergo authenticates with a fixed API key — may ignore it).
        request_stop: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            auth: models.CoinAuth,
        ) anyerror!void,
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
        /// Optional: the block-pruning capability (Litecoin's first-start prune
        /// prompt). Null for coins with no prune prompt. `pruning`/`offersPrunePrompt`
        /// key off this.
        pruning: ?*const Pruning = null,
    };

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
    pub fn install(
        self: Coin,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        return self.vtable.install(self.ptr, allocator, install_root, progress);
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
    pub fn requestStop(
        self: Coin,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !void {
        return self.vtable.request_stop(self.ptr, allocator, auth);
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

    /// The RPC method to probe for a warm-up phase, or null for coins with no
    /// bitcoin-style warm-up (their loading phase is always `none`).
    pub fn warmupProbeMethod(self: Coin) ?[]const u8 {
        if (self.vtable.warmup_probe_method) |f| return f(self.ptr);
        return null;
    }

    /// Whether this coin drives the external-wallet setup flow (create-returns-seed
    /// / restore / unlock), whether backed by a separate process or in-daemon. True
    /// iff the coin wires `external_wallet`.
    pub fn hasExternalWallet(self: Coin) bool {
        return self.vtable.external_wallet != null;
    }

    /// Whether the external wallet is backed by a *separate process* BoxWallet must
    /// spawn (Monero-style), as opposed to living in the daemon (Ergo). True iff the
    /// capability wires `process_argv`.
    pub fn hasExternalWalletProcess(self: Coin) bool {
        const ew = self.vtable.external_wallet orelse return false;
        return ew.process_argv != null;
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
        const ew = self.vtable.external_wallet orelse return &.{25};
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
};
