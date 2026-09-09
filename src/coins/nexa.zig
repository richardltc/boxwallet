const std = @import("std");
const builtin = @import("builtin");
const models = @import("../models.zig");
const rpc = @import("../rpc.zig");
const nft = @import("../nft.zig");
const install_mod = @import("../install.zig");
const conf = @import("../conf.zig");
const walletfile = @import("../walletfile.zig");
const Coin = @import("../coin.zig").Coin;

/// Nexa backend. Constants lifted from
/// `cmd/cli/cmd/coins/nexa/nexa.go`.
pub const Nexa = struct {
    /// Whether the coin is exposed in the nav. False keeps it out of the left
    /// bar entirely (registered but hidden) until it's ready for users.
    pub const live = true;
    pub const coin_name = "Nexa";
    pub const coin_name_abbrev = "NEXA";
    /// One-line description shown under the coin name on the detail pane.
    pub const coin_description = "Scalable proof-of-work blockchain for global payments.";
    /// Nexa brand colour (`#RRGGBB`), for tinting the coin in the frontend.
    pub const coin_color = "#FEE043";
    /// This coin's id on the price host, for the USD quote beside its
    /// balance (see `src/price.zig`).
    ///
    /// **`nexacoin`, not `nexa`.** The host also carries a stale `nexa` entry —
    /// market cap 0, no 24h change — that prices the coin some 865x too high;
    /// `nexacoin` is the one whose homepage is nexa.org. "The host lists it"
    /// and "the host's number is right" are different claims: see `price.Source`.
    pub const price_id = "nexacoin";
    /// Donation address for BoxWallet development, in Nexa's own
    /// currency.
    pub const tip_address = "nexa:nqtsq5g57va7z3jh78vk606nj90m629w9uwrrtkwnejj3lk6";
    /// Nexa is proof-of-work — no wallet staking.
    pub const proof_of_stake = false;
    pub const conf_file = "nexa.conf";
    pub const home_dir = ".nexa";
    pub const home_dir_win = "NEXA";
    /// Which Windows directory that name hangs off — the roaming `%APPDATA%`, as
    /// every bitcoin-derived daemon picks. See `conf.WinBase`.
    pub const home_dir_win_base: conf.WinBase = .roaming;
    /// macOS data dir name. Nexa: `~/Library/Application Support/nexa` (lowercase —
    /// `CBaseChainParams::NEXA`), unlike the Windows `NEXA`.
    pub const home_dir_mac: ?[]const u8 = "nexa";
    pub const rpc_default_username = "nexarpc";
    pub const rpc_default_port = "7227";
    pub const core_version = "2.2.0.0";

    // Binary names. Windows appends `.exe`; Linux/macOS use the bare names. The
    // per-target name is what `isInstalled`, the daemon launcher, and the promote
    // list all use, so a Windows build looks for `nexad.exe` and a POSIX build for
    // `nexad`.
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    pub const daemon_file = "nexad" ++ exe_suffix;
    pub const cli_file = "nexa-cli" ++ exe_suffix;
    pub const tx_file = "nexa-tx" ++ exe_suffix;

    // Download host. Every bundle wraps its executables in `nexa-<ver>/bin/`,
    // identically across platforms (Linux/macOS tar.gz, Windows zip).
    const download_base = "https://bitcoinunlimited.info/nexa/" ++ core_version ++ "/";

    /// The download URL + archive format for the build target, or null where Nexa
    /// publishes no matching binary. Selected at comptime from the OS/arch so a
    /// build only ever references its own platform's artifact. Mirrors the Go
    /// installer's `runtime.GOOS`/`GOARCH` switch, plus the macOS builds the Go
    /// app never wired (arm64 for Apple Silicon, x86 for Intel).
    const download: ?install_mod.Download = switch (builtin.os.tag) {
        .windows => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-win64.zip", .format = .zip },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-macos-arm64.tar.gz", .format = .tar_gz },
            .x86_64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-macos-x86.tar.gz", .format = .tar_gz },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-linux64.tar.gz", .format = .tar_gz },
            .aarch64 => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-arm64.tar.gz", .format = .tar_gz },
            .arm => .{ .url = download_base ++ "nexa-" ++ core_version ++ "-arm32.tar.gz", .format = .tar_gz },
            else => null,
        },
        else => null,
    };

    // Layout inside the archive. BoxWallet keeps only the daemon/cli/tx binaries
    // (from `bin/`) at the install root and discards the rest of the extracted
    // tree — the GUI/miner/rostrum, `lib/`, `share/`, the bundled `INSTALL.md`.
    // `nexad` links only against system libraries, so dropping `lib/libnexa.so`
    // is safe. Matches the Go installer.
    const extracted_dir = "nexa-" ++ core_version;
    const bin_subdir = "bin";
    const promote_files = [_][]const u8{ daemon_file, cli_file, tx_file };

    // Temp file the download streams to. Keyed off the daemon name so a
    // concurrent install of another coin into the same `~/.boxwallet` root uses
    // a different scratch file and the two never collide.
    pub const scratch_file = ".boxwallet-" ++ daemon_file ++ ".part";

    /// Build the type-erased `Coin` handle for this instance.
    pub fn coin(self: *Nexa) Coin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Live `getblockchaininfo`, normalized for a frontend.
    /// `BlockchainIsSynced` in Go is the `synced` field here.
    pub fn blockchainState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.BlockchainState {
        var parsed = try rpc.callParsed(models.NexaBlockchainInfo, allocator, auth, "getblockchaininfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .chain = try allocator.dupe(u8, r.chain),
            .blocks = r.blocks,
            .headers = r.headers,
            .verification_progress = r.verificationprogress,
            // Matches Go: BlockchainIsSynced => verificationprogress > 0.99999
            .synced = r.verificationprogress > 0.99999,
            // Network tip from peers, so the frontend's Headers bar can fill
            // toward it. A getpeerinfo hiccup just leaves it 0 (unknown).
            .network_height = rpc.networkHeight(allocator, auth) catch 0,
            // Tip block timestamp, so the frontend can show how far behind in
            // wall-clock time the chain is while validating. Prefer the exact
            // tip `time`; fall back to `mediantime` when the daemon omits it.
            .tip_time = if (r.time > 0) r.time else r.mediantime,
        };
    }

    /// Live `getinfo`, normalized for a frontend. Nexa is proof-of-work, so
    /// `staking_active` is always false.
    pub fn daemonInfo(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.DaemonInfo {
        var parsed = try rpc.callParsed(models.NexaGetInfo, allocator, auth, "getinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return .{
            .blocks = r.blocks,
            .connections = r.connections,
            .staking_active = false,
            // Freshly formatted on `allocator`, so it outlives `parsed`'s deinit.
            .version = try models.clientVersionString(allocator, r.version),
        };
    }

    /// The daemon's default data directory (`~/.nexa`), where `nexa.conf` lives.
    pub fn dataDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
        return conf.dataDir(allocator, home, home_dir, home_dir_win, home_dir_mac, home_dir_win_base);
    }

    /// The managed wallet's on-disk location (`<datadir>/wallet.dat`) — the
    /// daemon's default wallet, a single file. Caller owns the returned strings.
    pub fn walletPath(allocator: std.mem.Allocator, home: []const u8) !?Coin.WalletFile {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        return .{ .path = try std.fs.path.join(allocator, &.{ data_dir, "wallet.dat" }) };
    }

    /// True if `nexad` (`nexad.exe` on Windows) is already present under
    /// `install_root`.
    pub fn isInstalled(allocator: std.mem.Allocator, install_root: []const u8) bool {
        return install_mod.fileExists(allocator, install_root, daemon_file);
    }

    /// Download + unarchive the Nexa daemon files into `install_root`,
    /// optionally reporting download/extract progress.
    ///
    /// Extracts the versioned wrapper dir intact, then `promoteAndTidy` lifts the
    /// daemon/cli/tx binaries to the install root and removes the wrapper,
    /// leaving `nexad` exactly where `isInstalled` looks for it.
    pub fn install(
        allocator: std.mem.Allocator,
        install_root: []const u8,
        progress: ?install_mod.Progress,
    ) !void {
        const dl = download orelse return error.UnsupportedPlatform;
        try install_mod.downloadAndExtract(allocator, dl.url, dl.format, install_root, scratch_file, 0, progress);
        try install_mod.promoteAndTidy(allocator, install_root, extracted_dir, bin_subdir, &promote_files);
    }

    /// Ensure `nexa.conf` carries the RPC creds (and `server=1`/`daemon=1`/
    /// `rpcport`) BoxWallet needs before the daemon reads it; existing values are
    /// kept. A standard bitcoin-derived `key=value` conf.
    pub fn prepareConf(allocator: std.mem.Allocator, io: std.Io, home: []const u8) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);
        _ = try conf.populate(allocator, io, data_dir, conf_file, rpc_default_username, rpc_default_port);
    }

    /// Nexa is a bitcoin-derived daemon: it forks itself into the background with
    /// `-daemon` on POSIX, but runs in the foreground on Windows.
    pub fn launchMode() Coin.LaunchMode {
        return if (builtin.os.tag == .windows) .foreground else .fork;
    }

    /// The daemon's log file under the data dir, whose tail is read for a
    /// startup-failure reason when the daemon dies without saying why on stderr.
    pub fn daemonLogFile() []const u8 {
        return "debug.log";
    }

    /// The daemon binary path. The launcher appends `-daemon` itself for the fork
    /// path; on Windows it's spawned bare (detached).
    pub fn daemonArgv(allocator: std.mem.Allocator, install_root: []const u8, _: []const u8) ![]const []const u8 {
        const path = try std.fs.path.join(allocator, &.{ install_root, daemon_file });
        const argv = try allocator.alloc([]const u8, 1);
        argv[0] = path;
        return argv;
    }

    /// Ask nexad to shut down via the JSON-RPC `stop`.
    pub fn requestStop(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        const reply = try rpc.call(allocator, auth, "stop");
        allocator.free(reply);
    }

    /// Read the wallet's security state from `getwalletinfo`. Nexa is bitcoin-core
    /// style: `unlocked_until` is **absent** on an unencrypted wallet, `0` when
    /// locked, and a positive unlock timestamp otherwise. Mirrors Go's
    /// `WalletSecurityState`.
    pub fn walletSecurityState(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletSecurity {
        var parsed = try rpc.callParsed(models.NexaWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return securityFromUnlockedUntil(r.unlocked_until);
    }

    /// Read the wallet's balances from `getwalletinfo`. `available` is the
    /// confirmed spendable `balance`; `total` adds the mempool
    /// (`unconfirmed_balance`) and maturing (`immature_balance`) funds, so it
    /// reflects incoming money the moment it's seen. Same `getwalletinfo` shape
    /// as `walletSecurityState`.
    pub fn walletBalance(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) !models.WalletBalance {
        var parsed = try rpc.callParsed(models.NexaWalletInfo, allocator, auth, "getwalletinfo");
        defer parsed.deinit();

        const r = parsed.value.result orelse return error.EmptyRpcResult;
        return models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    }

    /// Map a bitcoin-core `unlocked_until` (absent/0/positive) to the normalized
    /// `WalletSecurity`. Shared by the parse path and its unit test.
    fn securityFromUnlockedUntil(unlocked_until: ?i64) models.WalletSecurity {
        const u = unlocked_until orelse return .unencrypted;
        if (u == 0) return .locked;
        return .unlocked;
    }

    /// Map Nexa's `listtransactions` `category` to the normalized direction.
    /// `"generate"`/`"immature"`/`"orphan"` are coinbase (mined) rewards at their
    /// maturity stages — the normalized `.stake` covers a mined block reward on a
    /// proof-of-work coin (see `models.TxDirection`). Anything else (`"move"`)
    /// has no direction (null; the caller drops it).
    fn directionFromCategory(category: []const u8) ?models.TxDirection {
        if (std.mem.eql(u8, category, "receive")) return .received;
        if (std.mem.eql(u8, category, "send")) return .sent;
        if (std.mem.eql(u8, category, "generate") or
            std.mem.eql(u8, category, "immature") or
            std.mem.eql(u8, category, "orphan")) return .stake;
        return null;
    }

    /// The wallet's most recent transactions, newest-first — the shared
    /// bitcoin-family `listtransactions` flow with Nexa's category map.
    pub fn walletTransactions(allocator: std.mem.Allocator, auth: models.CoinAuth, limit: usize) ![]models.WalletTx {
        return rpc.walletTransactions(allocator, auth, limit, directionFromCategory);
    }

    /// The wallet's receive address. Nexa's Bitcoin-Unlimited-derived wallet
    /// keeps the accounts API, so the shared accounts flow applies:
    /// `getaccountaddress ""` for the stable current address, `getnewaddress`
    /// (no params — its first parameter is the address *type*, defaulting to
    /// p2pkt) on an explicit user-requested rotation (`force_new` — only ever
    /// called on demand, never polled).
    pub fn receiveAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, force_new: bool) ![]const u8 {
        return rpc.receiveAddressAccount(allocator, auth, force_new);
    }

    /// Send `amount` NEXA to `address` via `sendtoaddress`, at Nexa's
    /// **2-decimal** denomination (1 NEXA = 100 satoshi; the daemon parses
    /// amounts as 2-place fixed-point and rejects anything finer — matching
    /// `balanceDecimals`). The daemon's own rejection reason (invalid address,
    /// insufficient funds, locked wallet) rides back verbatim in the
    /// `SendResult`.
    pub fn sendToAddress(allocator: std.mem.Allocator, auth: models.CoinAuth, address: []const u8, amount: f64) !models.SendResult {
        return rpc.sendToAddress(allocator, auth, address, amount, 2);
    }

    /// Encrypt the wallet with `passphrase`. nexad stops itself afterwards (the
    /// caller restarts it). The passphrase is JSON-escaped before splicing.
    pub fn walletEncrypt(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{pw});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "encryptwallet", params);
    }

    /// Unlock the wallet via `walletpassphrase` for `unlock_timeout_secs`.
    ///
    /// The `staking` flag is ignored: Nexa is proof-of-work (`proof_of_stake` is
    /// false, so the wallet menu never offers an unlock-for-staking), and this
    /// daemon's `walletpassphrase` takes **two** arguments — the third
    /// `stakingonly` flag the proof-of-stake forks accept is a usage error here.
    pub fn walletUnlock(allocator: std.mem.Allocator, auth: models.CoinAuth, passphrase: []const u8, _: bool) !void {
        const pw = try rpc.jsonQuote(allocator, passphrase);
        defer allocator.free(pw);
        const params = try std.fmt.allocPrint(allocator, "[{s},{d}]", .{ pw, unlock_timeout_secs });
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "walletpassphrase", params);
    }

    /// How long an unlock lasts, in seconds.
    ///
    /// Nexa is stricter than the Core forks at **both** ends: it rejects `0`
    /// ("The timeout period must be a positive number", RPC `-14`) *and* anything
    /// above a day ("The timeout period can not be greater than 86400 sec"),
    /// rather than clamping. BoxWallet used to send `0`, so an unlock here never
    /// succeeded at all. 86400 is the daemon's own maximum — the longest unlock
    /// it will grant (verified against nexad 2.1.0.0).
    const unlock_timeout_secs = 86400;

    /// Re-lock the wallet via `walletlock`.
    pub fn walletLock(allocator: std.mem.Allocator, auth: models.CoinAuth) !void {
        return rpc.callExpectOk(allocator, auth, "walletlock", "[]");
    }

    /// Back up the wallet to `dest_path` via `dumpwallet` — the human-readable
    /// key dump that `walletImportFile` reads back. nexad refuses it on a locked
    /// wallet (and won't overwrite an existing file), so the menu only offers it
    /// while the wallet is unlocked/unencrypted. The path is JSON-escaped before
    /// splicing. This file *is* the user's backup, not a temp — don't shred it.
    pub fn walletBackup(allocator: std.mem.Allocator, auth: models.CoinAuth, dest_path: []const u8) !void {
        const qpath = try rpc.jsonQuote(allocator, dest_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "dumpwallet", params);
    }

    /// Restore wallet keys from a `dumpwallet` file via `importwallet`, which
    /// imports the keys and rescans the chain. The rescan blocks the RPC until it
    /// finishes, so on a large chain it can outlast the client timeout and read as
    /// a failure while nexad keeps rescanning. Like backup, needs the wallet
    /// unlocked/unencrypted. Path JSON-escaped.
    ///
    /// A binary `wallet.dat` picked by mistake is refused up front: that's the
    /// *other* restore's input, and `importwallet` reports success on it having
    /// imported nothing. Nexa offers both restores at once, so the mix-up is the
    /// likely one.
    pub fn walletImportFile(allocator: std.mem.Allocator, auth: models.CoinAuth, src_path: []const u8) !void {
        if (!walletfile.looksLikeKeyDump(allocator, src_path)) return error.NotAWalletKeyDump;

        const qpath = try rpc.jsonQuote(allocator, src_path);
        defer allocator.free(qpath);
        const params = try std.fmt.allocPrint(allocator, "[{s}]", .{qpath});
        defer allocator.free(params);
        return rpc.callExpectOk(allocator, auth, "importwallet", params);
    }

    /// Restore the wallet by swapping in a user-supplied binary `wallet.dat` —
    /// the file-level counterpart to `walletImportFile`'s key-dump import, for a
    /// wallet carried over from another Nexa install (whose own backup is a
    /// `backupwallet` copy, which `importwallet` cannot read). The daemon holds
    /// `wallet.dat` open while running, so the caller stops it before calling this
    /// and restarts it after; this hook only touches files and takes no auth.
    ///
    /// nexad keeps its wallet at the top of the data dir — it has no named-wallet
    /// sub-directories — so the swap targets `<data_dir>/wallet.dat`, which is
    /// also the wallet every other Nexa app on this machine uses. That's why the
    /// guards in `walletfile.restoreOffline` matter here: a text key dump or an
    /// empty file is refused before anything is touched, and the wallet already
    /// in place is moved aside to a timestamped sibling rather than overwritten,
    /// so a wrong-file restore stays recoverable.
    pub fn walletRestoreFileOffline(
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) !void {
        const data_dir = try dataDir(allocator, home);
        defer allocator.free(data_dir);

        return walletfile.restoreOffline(allocator, data_dir, "wallet.dat", src_path);
    }

    /// Nexa retains `getinfo`, so probe it for the daemon's warm-up phase.
    pub fn warmupProbeMethod() []const u8 {
        return "getinfo";
    }

    // --- group tokens and NFTs ------------------------------------------

    /// The base32 alphabet Nexa's addresses and group identifiers are written
    /// in (the CashAddr alphabet, inherited from the Bitcoin Cash lineage).
    const cashaddr_charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    /// The 8 trailing base32 symbols of every CashAddr string are its checksum,
    /// not payload.
    const cashaddr_checksum_symbols = 8;

    /// A decoded group identifier: the version byte the address type is carried
    /// in, plus the body it prefixes.
    ///
    /// For a group the body is the 32-byte group hash. For a **subgroup** it is
    /// 64 bytes: the 32-byte parent group followed by 32 bytes of subgroup
    /// data. The NFT specification requires that subgroup data to be the
    /// double-SHA256 of the NFT's data file, which is what lets BoxWallet prove
    /// a downloaded bundle really is the NFT the chain committed to.
    const GroupId = struct {
        version: u8,
        body: [64]u8,
        body_len: usize,

        /// The subgroup half, or null when this is a plain group. Only the
        /// 32-byte form is returned: `token subgroup` accepts shorter data, but
        /// an NFT's commitment is a full double-SHA256 by definition, and a
        /// short subgroup is some other use of the mechanism.
        fn subgroup(self: *const GroupId) ?[]const u8 {
            if (self.body_len != 64) return null;
            return self.body[32..64];
        }
    };

    /// Decode a `<prefix>:<base32>` group identifier into its version byte and
    /// body.
    ///
    /// The checksum is deliberately not verified: every identifier that reaches
    /// this function came out of our own daemon's RPC reply in the same process
    /// that asked for it, so there is no untrusted party to guard against, and
    /// a wrong body would fail the far stronger check that follows it — the
    /// bundle's double-SHA256 against these very bytes.
    fn decodeGroupId(id: []const u8) ?GroupId {
        const colon = std.mem.indexOfScalar(u8, id, ':') orelse return null;
        const payload = id[colon + 1 ..];
        if (payload.len <= cashaddr_checksum_symbols) return null;

        const symbols = payload[0 .. payload.len - cashaddr_checksum_symbols];

        // 5 bits per symbol, repacked to 8. The trailing partial byte is
        // padding the encoder added and is dropped, exactly as the CashAddr
        // conversion specifies.
        var out: [65]u8 = undefined;
        var out_len: usize = 0;
        var acc: u32 = 0;
        var bits: u5 = 0;
        for (symbols) |c| {
            const v = std.mem.indexOfScalar(u8, cashaddr_charset, c) orelse return null;
            acc = (acc << 5) | @as(u32, @intCast(v));
            bits += 5;
            while (bits >= 8) {
                bits -= 8;
                if (out_len == out.len) return null;
                out[out_len] = @truncate(acc >> bits);
                out_len += 1;
            }
        }
        if (out_len == 0) return null;

        var g: GroupId = .{ .version = out[0], .body = undefined, .body_len = out_len - 1 };
        if (g.body_len > g.body.len) return null;
        @memcpy(g.body[0..g.body_len], out[1..out_len]);
        return g;
    }

    /// The wallet's group-token holdings, from `token info`.
    ///
    /// The daemon keys its reply by group identifier — one dynamic key per
    /// token — so this parses a `std.json.Value` rather than a fixed struct.
    /// Everything lands in bounded, scalar-only `TokenHolding`s, so the parse
    /// tree is freed before this returns and nothing points back into it.
    pub fn tokenList(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) ![]models.TokenHolding {
        const reply = try rpc.callParams(allocator, auth, "token", "[\"info\"]");
        defer allocator.free(reply);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, reply, .{}) catch {
            return error.RpcCallFailed;
        };
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.RpcCallFailed,
        };
        // A wallet holding nothing answers `{}`, which is a result, not a fault.
        const result = switch (root.get("result") orelse return error.EmptyRpcResult) {
            .object => |o| o,
            else => return error.EmptyRpcResult,
        };

        var list: std.ArrayList(models.TokenHolding) = .empty;
        errdefer list.deinit(allocator);

        var it = result.iterator();
        while (it.next()) |entry| {
            if (list.items.len >= limit) break;
            const fields = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            try list.append(allocator, holdingFrom(entry.key_ptr.*, fields));
        }

        return list.toOwnedSlice(allocator);
    }

    /// Fold one `token info` entry into a normalized holding.
    fn holdingFrom(group: []const u8, fields: std.json.ObjectMap) models.TokenHolding {
        var h: models.TokenHolding = .{};
        h.setGroup(group);
        h.setTicker(jsonString(fields, "ticker"));
        h.setName(jsonString(fields, "name"));
        h.setUrl(jsonString(fields, "url"));
        h.balance = jsonInt(fields, "balance_satoshis");
        h.mintage = jsonInt(fields, "mintage_satoshis");
        // The daemon writes `decimals` as a *string*, empty for a genesis that
        // omitted it — which displays the same as 0.
        h.decimals = std.fmt.parseInt(u8, jsonString(fields, "decimals"), 10) catch 0;

        // A subgroup identifier carrying a full 32-byte commitment is what
        // makes this an NFT rather than a currency-like group.
        if (decodeGroupId(group)) |gid| {
            if (gid.subgroup()) |sub| {
                var hex: [64]u8 = undefined;
                nft.toHex(&hex, sub);
                h.setDataHash(&hex);
                h.kind = .nft;
            }
        }
        return h;
    }

    /// One string field, or empty when absent or of another type.
    fn jsonString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
        const v = obj.get(key) orelse return "";
        return switch (v) {
            .string => |s| s,
            else => "",
        };
    }

    /// One integer field, or 0 when absent or of another type. Token amounts
    /// arrive as JSON integers; a daemon that ever wrote one as a float would
    /// still read sensibly rather than zeroing the row.
    fn jsonInt(obj: std.json.ObjectMap, key: []const u8) i64 {
        const v = obj.get(key) orelse return 0;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => 0,
        };
    }

    /// Where an NFT's data bundle lives: the standardized public route on the
    /// host that serves the token's description document.
    ///
    /// The chain commits to the *hash* of an NFT's data file, not to a location
    /// for it, so the location has to come from somewhere else. The NFT
    /// specification's answer is a route on the issuer's own host — `/public/`
    /// serves the bundle with owner-only content omitted and needs no proof of
    /// ownership — and the issuer's host is the one in the token description
    /// document URL that the group's genesis transaction *does* commit to.
    ///
    /// Because the bundle is then checked against the chain's hash, a wrong or
    /// hostile host cannot substitute a different NFT; it can only fail to
    /// produce this one. Caller owns the returned slice.
    pub fn nftBundleUrl(
        allocator: std.mem.Allocator,
        holding: models.TokenHolding,
    ) ![]const u8 {
        const doc_url = holding.url();
        if (doc_url.len == 0) return error.NoTokenDescriptionUrl;

        const uri = std.Uri.parse(doc_url) catch return error.NoTokenDescriptionUrl;
        const host = switch (uri.host orelse return error.NoTokenDescriptionUrl) {
            .raw, .percent_encoded => |h| h,
        };
        if (host.len == 0) return error.NoTokenDescriptionUrl;

        return std.fmt.allocPrint(
            allocator,
            "{s}://{s}/public/{s}",
            .{ uri.scheme, host, holding.group() },
        );
    }

    /// Fetch, verify and unpack one NFT's data bundle. The hash the bundle must
    /// match is the subgroup identifier already decoded into the holding, so a
    /// bundle served by the issuer's host is still only accepted if it is the
    /// file the chain committed to.
    pub fn fetchNft(
        allocator: std.mem.Allocator,
        holding: models.TokenHolding,
        cache_root: []const u8,
    ) !models.NftMeta {
        if (holding.kind != .nft) return error.NotAnNft;

        var expected: [32]u8 = undefined;
        const hash_hex = holding.dataHash();
        if (hash_hex.len != 64) return error.NotAnNft;
        _ = std.fmt.hexToBytes(&expected, hash_hex) catch return error.NotAnNft;

        const url = try nftBundleUrl(allocator, holding);
        defer allocator.free(url);

        return nft.fetchBundle(allocator, url, cache_root, expected);
    }

    // --- vtable plumbing -------------------------------------------------

    /// The block-index rebuild. Markers are the Core-derived defaults, checked
    /// against the shipped nexad binary.
    pub const reindex_caps: Coin.Reindex = .{
        .warning = "nexad re-reads the block files already on disk to rebuild the index — hours of CPU on a large chain, and the daemon is unusable until it finishes. Nothing is downloaded a second time unless this node is pruned, in which case the blocks it has already deleted are fetched again.",
    };

    /// Nexa's group tokens: fungible tokens and NFTs held in the same wallet
    /// as the coin itself.
    pub const token_caps: Coin.Tokens = .{
        .name = "Tokens",
        .list = vtTokenList,
        .fetch_nft = vtFetchNft,
    };

    const vtable: Coin.VTable = .{
        .coin_name = vtCoinName,
        .coin_name_abbrev = vtCoinNameAbbrev,
        .coin_description = vtCoinDescription,
        .coin_color = vtCoinColor,
        .tip_address = vtTipAddress,
        .price_id = vtPriceId,
        .core_version = vtCoreVersion,
        .proof_of_stake = vtProofOfStake,
        .balance_decimals = vtBalanceDecimals,
        .conf_file = vtConfFile,
        .daemon_file = vtDaemonFile,
        .rpc_default_port = vtRpcDefaultPort,
        .rpc_default_username = vtRpcDefaultUsername,
        .blockchain_state = vtBlockchainState,
        .daemon_info = vtDaemonInfo,
        .data_dir = vtDataDir,
        .wallet_path = vtWalletPath,
        .is_installed = vtIsInstalled,
        .install = vtInstall,
        .prepare_conf = vtPrepareConf,
        .launch_mode = vtLaunchMode,
        .daemon_log_file = vtDaemonLogFile,
        .daemon_argv = vtDaemonArgv,
        .request_stop = vtRequestStop,
        .wallet_security_state = vtWalletSecurityState,
        .wallet_balance = vtWalletBalance,
        .wallet_transactions = vtWalletTransactions,
        .wallet_receive_address = vtWalletReceiveAddress,
        .wallet_send = vtWalletSend,
        .wallet_encrypt = vtWalletEncrypt,
        .wallet_unlock = vtWalletUnlock,
        .wallet_lock = vtWalletLock,
        .wallet_backup = vtWalletBackup,
        .wallet_import_file = vtWalletImportFile,
        .wallet_restore_file_offline = vtWalletRestoreFileOffline,
        .warmup_probe_method = vtWarmupProbeMethod,
        .reindex = &reindex_caps,
        .tokens = &token_caps,
    };

    fn vtCoinName(_: *anyopaque) []const u8 {
        return coin_name;
    }
    fn vtCoinDescription(_: *anyopaque) []const u8 {
        return coin_description;
    }
    fn vtCoinNameAbbrev(_: *anyopaque) []const u8 {
        return coin_name_abbrev;
    }
    fn vtCoinColor(_: *anyopaque) []const u8 {
        return coin_color;
    }
    fn vtTipAddress(_: *anyopaque) []const u8 {
        return tip_address;
    }
    fn vtPriceId(_: *anyopaque) []const u8 {
        return price_id;
    }
    fn vtCoreVersion(_: *anyopaque) []const u8 {
        return core_version;
    }
    fn vtProofOfStake(_: *anyopaque) bool {
        return proof_of_stake;
    }
    /// Nexa balances are denominated to 2 decimal places (1 NEXA = 100 satoshi).
    fn vtBalanceDecimals(_: *anyopaque) u8 {
        return 2;
    }
    fn vtConfFile(_: *anyopaque) []const u8 {
        return conf_file;
    }
    fn vtDaemonFile(_: *anyopaque) []const u8 {
        return daemon_file;
    }
    fn vtRpcDefaultPort(_: *anyopaque) []const u8 {
        return rpc_default_port;
    }
    fn vtRpcDefaultUsername(_: *anyopaque) []const u8 {
        return rpc_default_username;
    }
    fn vtBlockchainState(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.BlockchainState {
        return blockchainState(allocator, auth);
    }
    fn vtDaemonInfo(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.DaemonInfo {
        return daemonInfo(allocator, auth);
    }
    fn vtDataDir(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
    ) anyerror![]const u8 {
        return dataDir(allocator, home);
    }
    fn vtWalletPath(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
    ) anyerror!?Coin.WalletFile {
        return walletPath(allocator, home);
    }
    fn vtIsInstalled(_: *anyopaque, allocator: std.mem.Allocator, install_root: []const u8) bool {
        return isInstalled(allocator, install_root);
    }
    fn vtInstall(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        _: []const u8,
        progress: ?install_mod.Progress,
    ) anyerror!void {
        return install(allocator, install_root, progress);
    }
    fn vtPrepareConf(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        install_root: []const u8,
        home: []const u8,
    ) anyerror!void {
        _ = install_root;
        return prepareConf(allocator, io, home);
    }
    fn vtLaunchMode(_: *anyopaque) Coin.LaunchMode {
        return launchMode();
    }
    fn vtDaemonLogFile(_: *anyopaque) []const u8 {
        return daemonLogFile();
    }
    fn vtDaemonArgv(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        install_root: []const u8,
        home: []const u8,
    ) anyerror![]const []const u8 {
        return daemonArgv(allocator, install_root, home);
    }
    fn vtRequestStop(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return requestStop(allocator, auth);
    }
    fn vtWalletSecurityState(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletSecurity {
        return walletSecurityState(allocator, auth);
    }
    fn vtWalletBalance(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!models.WalletBalance {
        return walletBalance(allocator, auth);
    }
    fn vtWalletTransactions(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.WalletTx {
        return walletTransactions(allocator, auth, limit);
    }
    fn vtWalletReceiveAddress(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        force_new: bool,
    ) anyerror![]const u8 {
        return receiveAddress(allocator, auth, force_new);
    }
    fn vtWalletSend(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        address: []const u8,
        amount: f64,
    ) anyerror!models.SendResult {
        return sendToAddress(allocator, auth, address, amount);
    }
    fn vtWalletEncrypt(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
    ) anyerror!void {
        return walletEncrypt(allocator, auth, passphrase);
    }
    fn vtWalletUnlock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        passphrase: []const u8,
        staking: bool,
    ) anyerror!void {
        return walletUnlock(allocator, auth, passphrase, staking);
    }
    fn vtWalletLock(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
    ) anyerror!void {
        return walletLock(allocator, auth);
    }
    fn vtWalletBackup(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        dest_path: []const u8,
    ) anyerror!void {
        return walletBackup(allocator, auth, dest_path);
    }
    fn vtWalletImportFile(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        src_path: []const u8,
    ) anyerror!void {
        return walletImportFile(allocator, auth, src_path);
    }
    fn vtWalletRestoreFileOffline(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        home: []const u8,
        src_path: []const u8,
    ) anyerror!void {
        return walletRestoreFileOffline(allocator, home, src_path);
    }
    fn vtWarmupProbeMethod(_: *anyopaque) []const u8 {
        return warmupProbeMethod();
    }
    fn vtTokenList(
        allocator: std.mem.Allocator,
        auth: models.CoinAuth,
        limit: usize,
    ) anyerror![]models.TokenHolding {
        return tokenList(allocator, auth, limit);
    }
    fn vtFetchNft(
        allocator: std.mem.Allocator,
        holding: models.TokenHolding,
        cache_root: []const u8,
    ) anyerror!models.NftMeta {
        return fetchNft(allocator, holding, cache_root);
    }
};

test "parses getblockchaininfo into normalized BlockchainState" {
    const allocator = std.testing.allocator;

    // Canned daemon reply — proves parse + map without a running nexad.
    const raw =
        \\{"result":{"chain":"nexa","blocks":1234567,"headers":1234567,
        \\"bestblockhash":"deadbeef","difficulty":12345.678,
        \\"verificationprogress":0.999995,"initialblockdownload":false,
        \\"size_on_disk":987654321,"pruned":false,"mediantime":1700000000,
        \\"softforks":[],"bip9_softforks":{},"bip135_forks":{}},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaBlockchainInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const state: models.BlockchainState = .{
        .chain = try allocator.dupe(u8, r.chain),
        .blocks = r.blocks,
        .headers = r.headers,
        .verification_progress = r.verificationprogress,
        .synced = r.verificationprogress > 0.99999,
        .tip_time = r.mediantime,
    };
    defer state.deinit(allocator);

    try std.testing.expectEqualStrings("nexa", state.chain);
    try std.testing.expectEqual(@as(i64, 1234567), state.blocks);
    try std.testing.expect(state.synced);
    try std.testing.expectEqual(@as(i64, 1700000000), state.tip_time);
}

test "parses getinfo with a numeric version field" {
    const allocator = std.testing.allocator;

    // nexad reports `version` as a number (e.g. 2000000), not a string — the
    // struct must type it that way or the whole poll fails to parse and the
    // daemon reads as "not running" even though it's up.
    const raw =
        \\{"result":{"version":2000000,"protocolversion":80006,
        \\"walletversion":130000,"balance":0.00,"blocks":180763,
        \\"connections":2,"difficulty":42315.13684998719,"testnet":false},
        \\"error":null,"id":"boxwallet"}
    ;

    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaGetInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    try std.testing.expectEqual(@as(i64, 2000000), r.version);
    try std.testing.expectEqual(@as(i64, 2), r.connections);
}

test "platform selection resolves a download for the build target" {
    // Nexa publishes binaries for every OS/arch BoxWallet builds for, so the
    // current target must always resolve a download (and to the right format).
    const dl = Nexa.download orelse return error.SkipZigTest;
    switch (builtin.os.tag) {
        .windows => try std.testing.expectEqual(install_mod.Format.zip, dl.format),
        else => try std.testing.expectEqual(install_mod.Format.tar_gz, dl.format),
    }

    // Binary names carry `.exe` only on Windows.
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("nexad.exe", Nexa.daemon_file);
    } else {
        try std.testing.expectEqualStrings("nexad", Nexa.daemon_file);
    }
}

test "coin vtable dispatches to Nexa metadata" {
    var nexa: Nexa = .{};
    const c = nexa.coin();
    try std.testing.expectEqualStrings("Nexa", c.coinName());
    try std.testing.expectEqualStrings("#FEE043", c.coinColor());
    try std.testing.expect(!c.isProofOfStake());
    try std.testing.expectEqualStrings("nexa.conf", c.confFile());
    try std.testing.expectEqualStrings("7227", c.rpcDefaultPort());
    try std.testing.expectEqualStrings("debug.log", c.daemonLogFile().?);
    // Nexa's daemon auto-creates its wallet, so no explicit ensure step.
    try std.testing.expect(!c.needsWallet());
    // But its wallet is manageable over RPC — the `w` menu is available.
    try std.testing.expect(c.supportsWallet());
}

test "directionFromCategory maps listtransactions categories to normalized direction" {
    try std.testing.expectEqual(models.TxDirection.received, Nexa.directionFromCategory("receive").?);
    try std.testing.expectEqual(models.TxDirection.sent, Nexa.directionFromCategory("send").?);
    // Coinbase (mined) rewards at their maturity stages — Nexa is proof-of-work,
    // so the normalized `.stake` here means a mined block reward.
    try std.testing.expectEqual(models.TxDirection.stake, Nexa.directionFromCategory("generate").?);
    try std.testing.expectEqual(models.TxDirection.stake, Nexa.directionFromCategory("immature").?);
    try std.testing.expectEqual(models.TxDirection.stake, Nexa.directionFromCategory("orphan").?);
    // No direction — dropped by the shared mapper.
    try std.testing.expect(Nexa.directionFromCategory("move") == null);
    try std.testing.expect(Nexa.directionFromCategory("something-unknown") == null);
}

test "coin vtable exposes transactions, receive address, and send for Nexa" {
    var nexa: Nexa = .{};
    const c = nexa.coin();
    try std.testing.expect(c.supportsTransactions());
    try std.testing.expect(c.supportsReceiveAddress());
    try std.testing.expect(c.supportsSend());
    // Send amounts are formatted at the same 2-decimal denomination the
    // balances are displayed to (the daemon rejects finer precision).
    try std.testing.expectEqual(@as(u8, 2), c.balanceDecimals());
}

test "walletPath points at the daemon's default wallet.dat" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var nexa: Nexa = .{};
    const wf = (try nexa.coin().walletPath(allocator, "/home/alice")).?;
    defer allocator.free(wf.path);
    try std.testing.expectEqualStrings("/home/alice/.nexa/wallet.dat", wf.path);
    try std.testing.expect(wf.keys == null);
}

test "coin vtable offers both restore shapes for Nexa" {
    var nexa: Nexa = .{};
    const c = nexa.coin();
    // The key-dump pair against a live daemon (dumpwallet / importwallet)…
    try std.testing.expect(c.supportsWalletBackup());
    try std.testing.expect(c.supportsWalletImport());
    // …and the daemon-stopped wallet.dat swap, which is what moves a wallet
    // brought from another Nexa install (its `backupwallet` copy is binary —
    // importwallet can't read it).
    try std.testing.expect(c.supportsWalletRestoreOffline());
    // nexad exposes no mnemonic RPC (the wallet is HD but reports only an
    // `hdmasterkeyid`), so there is no seed to show or restore from — verified
    // against nexad 2.2.0.0's `help`.
    try std.testing.expect(!c.supportsWalletRestoreSeed());
    try std.testing.expect(!c.supportsSeedBackup());
}

test "offline restore swaps the data dir's wallet.dat and keeps the old one aside" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-nexa-offline-restore";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    // nexad has no named-wallet sub-directories: the wallet it acts on sits at
    // the top of the data dir.
    const data_dir = try Nexa.dataDir(allocator, home);
    defer allocator.free(data_dir);
    var dd = try std.Io.Dir.cwd().createDirPathOpen(io, data_dir, .{});
    defer dd.close(io);
    try dd.writeFile(io, .{ .sub_path = "wallet.dat", .data = "OLD-WALLET" });

    var src = try std.Io.Dir.cwd().createDirPathOpen(io, home ++ "/backups", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "wallet.dat", .data = "NEW-WALLET" });

    try Nexa.walletRestoreFileOffline(allocator, home, home ++ "/backups/wallet.dat");

    const restored = try dd.readFileAlloc(io, "wallet.dat", allocator, .limited(64));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("NEW-WALLET", restored);

    // The wallet that was there is kept, not destroyed — a wrong-file restore
    // stays recoverable.
    // Iterate on a freshly opened handle — the restore reopens the same
    // directory itself, and a Dir listing seeks the descriptor.
    var listing = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer listing.close(io);
    var kept = false;
    var it = listing.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "wallet.dat.bak-")) kept = true;
    }
    try std.testing.expect(kept);
}

test "walletImportFile refuses a binary wallet.dat, which importwallet would 'succeed' on" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "test-nexa-import-guard";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "wallet.dat", .data = "\x00\x00\x00\x00\x62\x31\x05\x00binary" });

    // Refused before any RPC — the auth here is never reached, so this needs no
    // daemon.
    const auth: models.CoinAuth = .{
        .rpc_user = "u",
        .rpc_password = "p",
        .ip_address = "127.0.0.1",
        .port = "1",
    };
    try std.testing.expectError(
        error.NotAWalletKeyDump,
        Nexa.walletImportFile(allocator, auth, root ++ "/wallet.dat"),
    );
}

test "the offline restore refuses a key dump — nexad's own dumpwallet header" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = "test-nexa-restore-guard";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, home, .{});
    defer dir.close(io);

    // The real first line nexad 2.2.0.0 writes — the shared sniff in
    // `walletfile` keys off the "# Wallet dump created by" prefix, so the
    // mix-up is caught before the wallet in place is touched.
    try dir.writeFile(io, .{
        .sub_path = "dump.txt",
        .data = "# Wallet dump created by Nexa v2.2.0.0-6651a9470 (2026-08-26 12:38:25 +0000)\n",
    });

    try std.testing.expectError(
        error.IsAWalletKeyDump,
        Nexa.walletRestoreFileOffline(allocator, home, home ++ "/dump.txt"),
    );
}

test "maps getwalletinfo balances to available + total (mempool reflected immediately)" {
    const allocator = std.testing.allocator;

    // Confirmed 10, plus 2.5 sitting in the mempool and 1 still maturing: total is
    // the sum (13.5) — moving the instant the mempool funds appear — while
    // available stays the confirmed 10 until they settle.
    const raw =
        \\{"result":{"walletversion":130000,"balance":10.0,
        \\"unconfirmed_balance":2.5,"immature_balance":1.0,"unlocked_until":0},
        \\"error":null,"id":"boxwallet"}
    ;
    var parsed = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaWalletInfo),
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    const r = parsed.value.result.?;
    const bal = models.WalletBalance.fromParts(r.balance, r.unconfirmed_balance, r.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), bal.available, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 13.5), bal.total, 1e-9);
    try std.testing.expect(bal.hasPending());

    // A daemon that omits the mempool/immature fields: total collapses to the
    // confirmed balance and nothing reads as pending.
    var settled = try std.json.parseFromSlice(
        models.JsonRpcResponse(models.NexaWalletInfo),
        allocator,
        "{\"result\":{\"balance\":7.0},\"error\":null,\"id\":\"boxwallet\"}",
        .{ .ignore_unknown_fields = true },
    );
    defer settled.deinit();
    const sr = settled.value.result.?;
    const sbal = models.WalletBalance.fromParts(sr.balance, sr.unconfirmed_balance, sr.immature_balance);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), sbal.total, 1e-9);
    try std.testing.expect(!sbal.hasPending());
}

test "maps getwalletinfo unlocked_until to the wallet security state" {
    // Bitcoin-core style: the field is absent on an unencrypted wallet, 0 when
    // locked, and a positive unlock timestamp once unlocked.
    try std.testing.expectEqual(models.WalletSecurity.unencrypted, Nexa.securityFromUnlockedUntil(null));
    try std.testing.expectEqual(models.WalletSecurity.locked, Nexa.securityFromUnlockedUntil(0));
    try std.testing.expectEqual(models.WalletSecurity.unlocked, Nexa.securityFromUnlockedUntil(1893456000));

    // The absent field really does parse to null (so it reads as unencrypted),
    // while a present 0 stays 0 (locked) — the optional is what distinguishes them.
    const allocator = std.testing.allocator;
    {
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(models.NexaWalletInfo),
            allocator,
            "{\"result\":{\"walletversion\":130000,\"balance\":0.0},\"error\":null,\"id\":\"boxwallet\"}",
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        try std.testing.expectEqual(models.WalletSecurity.unencrypted, Nexa.securityFromUnlockedUntil(parsed.value.result.?.unlocked_until));
    }
    {
        var parsed = try std.json.parseFromSlice(
            models.JsonRpcResponse(models.NexaWalletInfo),
            allocator,
            "{\"result\":{\"unlocked_until\":0},\"error\":null,\"id\":\"boxwallet\"}",
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        try std.testing.expectEqual(models.WalletSecurity.locked, Nexa.securityFromUnlockedUntil(parsed.value.result.?.unlocked_until));
    }
}

test "decodeGroupId splits a subgroup identifier into parent and NFT commitment" {
    // A live NiftyArt NFT. Its subgroup half is the double-SHA256 of the NFT's
    // data file — the value `fetchNft` proves a downloaded bundle against.
    const id = "nexa:tr9v70v4s9s6jfwz32ts60zqmmkp50lqv7t0ux620d50xa7dhyqqpqvwsk6yxyy6tq08lklz546z6vu8lqkkygg6wnyuzcs76vx73he65rqejcdy";
    const gid = Nexa.decodeGroupId(id) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 64), gid.body_len);
    const sub = gid.subgroup() orelse return error.TestUnexpectedResult;

    var hex: [64]u8 = undefined;
    nft.toHex(&hex, sub);
    try std.testing.expectEqualStrings(
        "818e85b443109a581e7fdbe2a5742d3387f82d62211a74c9c1621ed30de8df3a",
        &hex,
    );
}

test "decodeGroupId reports a plain group as having no subgroup" {
    // A fungible group: 32 body bytes, so nothing an NFT bundle could hash to.
    const gid = Nexa.decodeGroupId(
        "nexa:tp0an8aj7e635vfrfzldut8ne2wwxn5jcxtgs9a5nzqmkq49rcqqqcsq60666",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 32), gid.body_len);
    try std.testing.expectEqual(@as(?[]const u8, null), gid.subgroup());
}

test "decodeGroupId rejects malformed identifiers instead of guessing" {
    // No prefix separator, nothing but a checksum, and a symbol outside the
    // CashAddr alphabet ('b' is deliberately not in it).
    try std.testing.expectEqual(@as(?Nexa.GroupId, null), Nexa.decodeGroupId("tp0an8aj"));
    try std.testing.expectEqual(@as(?Nexa.GroupId, null), Nexa.decodeGroupId("nexa:qqqqqqqq"));
    try std.testing.expectEqual(@as(?Nexa.GroupId, null), Nexa.decodeGroupId("nexa:bbbbbbbbbbbbbbbb"));
}

test "token info maps a subgroup row to a verifiable NFT holding" {
    const allocator = std.testing.allocator;

    // The daemon's own reply shape, keyed by group identifier, with `decimals`
    // as a string and the amounts as integers — confirmed against nexad 2.2.0.0.
    const raw =
        \\{"nexa:tr9v70v4s9s6jfwz32ts60zqmmkp50lqv7t0ux620d50xa7dhyqqpqvwsk6yxyy6tq08lklz546z6vu8lqkkygg6wnyuzcs76vx73he65rqejcdy":
        \\{"ticker":"NIFTY","name":"NiftyArt","url":"https://niftyart.cash/td/nifty.json",
        \\"hash":"b0fa910a48c81cd09b414850ebec6ba040bf3f8b9e0cc39cfd13e03a02be4a0b",
        \\"decimals":"0","genesis_address":"nexa:nqtsq5g5xhwe2955fwx0ja2jzu20jurzsh2562lz2juyvln7",
        \\"balance_satoshis":1,"mintage_satoshis":1}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var it = parsed.value.object.iterator();
    const entry = it.next() orelse return error.TestUnexpectedResult;
    const h = Nexa.holdingFrom(entry.key_ptr.*, entry.value_ptr.object);

    try std.testing.expectEqual(models.TokenKind.nft, h.kind);
    try std.testing.expectEqualStrings("NIFTY", h.ticker());
    try std.testing.expectEqualStrings("NiftyArt", h.name());
    try std.testing.expectEqual(@as(i64, 1), h.balance);
    try std.testing.expectEqual(@as(i64, 1), h.mintage);
    try std.testing.expectEqual(@as(u8, 0), h.decimals);
    try std.testing.expectEqualStrings(
        "818e85b443109a581e7fdbe2a5742d3387f82d62211a74c9c1621ed30de8df3a",
        h.dataHash(),
    );
}

test "token info maps a plain group to a fungible holding with no commitment" {
    const allocator = std.testing.allocator;

    // An empty `decimals` is what a genesis that omitted it reports; it must
    // read as 0 rather than failing the row.
    const raw =
        \\{"nexa:tp0an8aj7e635vfrfzldut8ne2wwxn5jcxtgs9a5nzqmkq49rcqqqcsq60666":
        \\{"ticker":"BONG","name":"Beer Bong","url":"","hash":"","decimals":"",
        \\"genesis_address":"nexa:nqtsq5g54vc9vcv4acrf5nn7xg3xvaxcf7nmkusvj7yw646a",
        \\"balance_satoshis":5,"mintage_satoshis":12}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var it = parsed.value.object.iterator();
    const entry = it.next() orelse return error.TestUnexpectedResult;
    const h = Nexa.holdingFrom(entry.key_ptr.*, entry.value_ptr.object);

    try std.testing.expectEqual(models.TokenKind.fungible, h.kind);
    try std.testing.expectEqual(@as(u8, 0), h.decimals);
    try std.testing.expectEqual(@as(i64, 5), h.balance);
    try std.testing.expectEqualStrings("", h.dataHash());
}

test "nftBundleUrl puts the public route on the issuer's own host" {
    const allocator = std.testing.allocator;

    var h: models.TokenHolding = .{};
    h.setGroup("nexa:trabc");
    h.setUrl("https://niftyart.cash/td/nifty.json");

    const url = try Nexa.nftBundleUrl(allocator, h);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://niftyart.cash/public/nexa:trabc", url);
}

test "nftBundleUrl fails when the genesis committed to no description document" {
    var h: models.TokenHolding = .{};
    h.setGroup("nexa:trabc");
    // A token whose issuer named no document gives us no host to ask, and
    // there is nowhere else the location could legitimately come from.
    try std.testing.expectError(
        error.NoTokenDescriptionUrl,
        Nexa.nftBundleUrl(std.testing.allocator, h),
    );
}

test "fetchNft refuses a holding that carries no chain commitment" {
    var h: models.TokenHolding = .{};
    h.setGroup("nexa:tp0an8aj");
    h.setUrl("https://example.org/td/x.json");
    // Fungible: nothing to verify a downloaded bundle against, so there is no
    // safe way to show one.
    try std.testing.expectError(
        error.NotAnNft,
        Nexa.fetchNft(std.testing.allocator, h, "/tmp"),
    );
}
