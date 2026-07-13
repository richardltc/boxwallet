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
        /// Optional: the daemon's own log file, as a name relative to the coin's
        /// data dir (`debug.log` for bitcoin-derived daemons, `nerva.log` /
        /// `salvium.log` / `zanod.log` for the epee family). Its tail is read to
        /// surface a startup-failure reason for daemons whose fatal init errors
        /// go to their log/console rather than stderr. Null for coins with no
        /// fixed daemon log under the data dir (Ergo logs to the CWD; Epic's
        /// failures land on stderr).
        daemon_log_file: ?*const fn (ptr: *anyopaque) []const u8 = null,
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
        /// Optional: the stablecoin capability (DigiByte's DigiDollar). Null for
        /// coins with no chain-issued stablecoin. `stablecoin`/`supportsStablecoin`
        /// key off this; non-null lights up the coin's stablecoin tab.
        stablecoin: ?*const Stablecoin = null,
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

    /// The RPC method to probe for a warm-up phase, or null for coins with no
    /// bitcoin-style warm-up (their loading phase is always `none`).
    pub fn warmupProbeMethod(self: Coin) ?[]const u8 {
        if (self.vtable.warmup_probe_method) |f| return f(self.ptr);
        return null;
    }

    /// Classify the daemon's warm-up phase from a `debug.log` tail, for coins
    /// whose warm-up isn't visible over RPC. Returns `.none` for coins that don't
    /// wire the hook (so the caller falls back to whatever the RPC probe found).
    pub fn warmupPhaseFromLog(self: Coin, tail: []const u8) models.LoadingPhase {
        if (self.vtable.warmup_phase_from_log) |f| return f(self.ptr, tail);
        return .none;
    }

    /// The daemon's own log file name (relative to the coin's data dir), or null
    /// for coins that declare none. Read (tail only) for a startup-failure reason
    /// when the daemon died without saying why on stderr.
    pub fn daemonLogFile(self: Coin) ?[]const u8 {
        if (self.vtable.daemon_log_file) |f| return f(self.ptr);
        return null;
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
};
