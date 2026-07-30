/* BoxWallet core — C ABI for the Slint GUI front-end.
 *
 * Implemented in src/capi.zig; linked into the GUI executable by `zig build gui`.
 * The C++ Slint glue includes this header and calls these functions to drive the
 * exact same coin logic as the TUI.
 *
 * The surface covers every registered coin: metadata, install and update, the
 * sync accelerators, daemon start/stop and warm-up, both wallet shapes, balances,
 * transactions, receive addresses, sending, and mining.
 *
 * Secrets DO cross this boundary — passwords in, one mnemonic out — under the
 * contract at the foot of this file. Read it before calling anything that takes
 * or returns one.
 *
 * Conventions throughout:
 *   - Buffer-filling calls copy up to `cap` bytes and return the length written.
 *     The result is NOT NUL-terminated; use the returned length.
 *   - Nothing allocated on one side is ever freed by the other.
 *   - Calls that block on RPC or the network are marked as worker-thread-only.
 *     The pure metadata reads are safe on the UI thread.
 */
#ifndef BOXWALLET_H
#define BOXWALLET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque per-process context. Create with bw_init, free with bw_deinit. */
typedef struct bw_ctx bw_ctx;

/* Flattened mirror of the Zig models.DaemonInfo. */
typedef struct {
    int64_t blocks;
    int64_t connections;
    int      staking_active; /* 0/1 — meaningful for proof-of-stake coins (Divi) */
    char     version[64];    /* NUL-terminated */
} BwDaemonInfo;

/* Flattened mirror of the Zig models.BlockchainState. */
typedef struct {
    int64_t blocks;
    int64_t headers;
    double  verification_progress; /* 0.0 .. 1.0 — the sync fraction */
    int      synced;               /* 0/1 */
    int64_t network_height;
    int64_t tip_time;
    int64_t seconds_behind;        /* -1 = "not supplied" */
    char     chain[32];            /* NUL-terminated chain name, e.g. "main" */
} BwBlockchainState;

/* ---- lifecycle --------------------------------------------------------------
 * bw_init resolves the per-platform install root under home_dir. Returns NULL on
 * failure. */
bw_ctx *bw_init(const char *home_dir);
void    bw_deinit(bw_ctx *ctx);

/* The last error, copied into buf (up to cap bytes); returns the bytes written.
 * Set after any call that returned < 0.
 *
 * PER-THREAD. Each thread has its own slot, so read it on the same thread that
 * made the failing call — which is what every caller already does. It is not a
 * mailbox: a worker cannot pick up the poller's message, and vice versa. That is
 * the point, since a dozen detached workers run alongside a continuous poller
 * and a shared slot would put one wallet's failure on another's dialog.
 *
 * The ctx argument is accepted for symmetry and may be NULL. */
size_t  bw_last_error(bw_ctx *ctx, char *buf, size_t cap);

/* The bare error name behind that message (e.g. "WrongPassword"), for callers
 * that need to branch rather than just display — a wallet setup modal keeps
 * itself on the password step when it sees that one. Same per-thread rule. */
size_t  bw_last_error_code(bw_ctx *ctx, char *buf, size_t cap);

/* ---- mnemonic seed helpers (no ctx needed) ----------------------------------
 * The backup quiz is the last moment a mis-transcribed word can be caught, and
 * after that the funds are gone with no recourse — so both front-ends ask it the
 * same way, from here, rather than each writing their own.
 *
 * None of these copies or retains the words: they read your buffer in place, so
 * you can wipe it straight afterwards.
 *
 * bw_seed_word_matches ignores surrounding whitespace and case, because a
 * wordlist is lowercase but people type with a capital and rejecting "Abandon"
 * would fail someone who copied their seed down correctly.
 *
 * bw_seed_verify_positions draws from the OS CSPRNG and returns ascending
 * positions. Do NOT substitute a local PRNG — a clock-seeded generator makes the
 * quiz predictable, which is exactly what it must not be. */
size_t  bw_seed_word_count(const char *words, size_t len);
int     bw_seed_word_matches(const char *words, size_t words_len, size_t pos,
                             const char *answer, size_t answer_len);
size_t  bw_seed_verify_positions(size_t word_count, uint32_t *out, size_t cap);

/* ---- number formatting (no ctx needed) --------------------------------------
 * Exported rather than reimplemented here so both front-ends show the same
 * balance the same way. They did diverge once: the GUI carried its own snprintf
 * + manual comma insertion against the TUI's printFloat + digit grouping.
 *
 * bw_format_amount keeps trailing zeros, so a coin's full precision always shows
 * and a zero balance reads as a balance rather than a bare "0". bw_trim_zeros
 * strips them for transaction lists, where a column of full-width figures is
 * noise — don't use it on a balance. Both are cheap and safe on the UI thread. */
size_t  bw_format_amount(double value, uint8_t decimals, char *buf, size_t cap);
size_t  bw_trim_zeros(const char *text, size_t len, char *buf, size_t cap);

/* ---- application identity (no ctx needed) -----------------------------------
 * BoxWallet's own name, version and brand colour. The version has no "v" prefix
 * — add your own. Take these rather than hardcoding: they come from the same
 * constant the TUI shows and the self-updater compares against, so a copy in the
 * UI would go stale one release later and claim a version that isn't running. */
size_t  bw_app_version(char *buf, size_t cap);   /* e.g. "0.8.4" */
size_t  bw_app_name(char *buf, size_t cap);      /* "BoxWallet" */
size_t  bw_brand_color(char *buf, size_t cap);   /* "#RRGGBB" */

/* ---- coin registry / metadata (no ctx needed) ------------------------------
 * Coins are addressed by a stable size_t index in [0, bw_coin_count()). The
 * metadata calls copy up to cap bytes into buf and return the length written
 * (not NUL-terminated — use the returned length). */
size_t  bw_coin_count(void);
size_t  bw_coin_name(size_t idx, char *buf, size_t cap);
size_t  bw_coin_abbrev(size_t idx, char *buf, size_t cap);
size_t  bw_coin_color(size_t idx, char *buf, size_t cap); /* "#RRGGBB" */
size_t  bw_coin_description(size_t idx, char *buf, size_t cap);
size_t  bw_coin_version(size_t idx, char *buf, size_t cap); /* bundled core version */
/* A coin's two-tone wordmark: 1 with *out filled, 0 if it has none (most coins —
 * draw the whole name in bw_coin_color and stop). `split` is a BYTE INDEX into
 * the coin name where the tail half begins, so "ReddCoin" splits at 4 into
 * "Redd" + "Coin". The head colour is resolved for you: coins that don't name
 * one use their own brand colour. Cheap; safe on the UI thread. */
typedef struct {
    size_t split;
    char   head_color[8]; /* "#RRGGBB", NUL-terminated */
    char   tail_color[8];
} BwWordmark;
int     bw_coin_wordmark(size_t idx, BwWordmark *out);

int     bw_coin_supports_mining(size_t idx);      /* 0/1 — shows the Mining tab */
int     bw_coin_supports_stablecoin(size_t idx);  /* 0/1 — shows the DigiDollar tab */

/* What this coin's managed wallet can do, as a bitfield — 0 means it has no
 * external wallet at all. One call rather than six so a coin added later can't
 * arrive half-described (a wallet the GUI can't restore, or a Replace it
 * wrongly offers). */
#define BW_EW_HAS_PROCESS    (1 << 0)  /* spawns its own wallet-rpc process */
#define BW_EW_SEED_RESTORE   (1 << 1)  /* restore from mnemonic words */
#define BW_EW_FILE_RESTORE   (1 << 2)  /* import an existing wallet file */
#define BW_EW_REPLACE        (1 << 3)  /* in-app "replace wallet" (destructive) */
#define BW_EW_EXPLICIT_LOCK  (1 << 4)  /* in-daemon wallet needing a Lock action */
/* Wallet process is launched per-open with the password on its command line
 * (Zano, Epic). NOT YET WIRED for this front-end: every bw_ext_wallet_* op on
 * such a coin returns -1 with "Unsupported". Check this bit and tell the user
 * plainly rather than offering actions that can only fail. */
#define BW_EW_LAUNCH_WITH_PW (1 << 5)
int     bw_coin_ext_wallet(size_t idx);

/* Word counts this wallet's restore seed may have (25 for the CryptoNote coins,
 * {15,12,24} for Ergo, {26,25,24} for Zano). Writes up to cap and returns how
 * many; the first is the canonical length to name in the prompt. */
size_t  bw_coin_seed_word_counts(size_t idx, uint32_t *out, size_t cap);

/* Which wallet tabs a coin earns — about the *coin*, not about whether its
 * wallet happens to be open. Use these to hide a tab rather than render it
 * empty. Note bw_coin_supports_balance is true for a managed-wallet coin too:
 * its balance comes from the wallet-rpc rather than the daemon, but it has one.
 * Epic answers 0 for receive/send — a MimbleWimble payment is an interactive
 * slate exchange, with no address to show and nothing to fire and forget. */
int     bw_coin_supports_balance(size_t idx);
int     bw_coin_supports_transactions(size_t idx);
int     bw_coin_supports_receive_address(size_t idx);
int     bw_coin_supports_send(size_t idx);
uint8_t bw_coin_balance_decimals(size_t idx);

/* ---- status ----------------------------------------------------------------- */
int     bw_is_installed(bw_ctx *ctx, size_t idx);                 /* 0/1 */
size_t  bw_data_dir(bw_ctx *ctx, size_t idx, char *buf, size_t cap);

/* Update detection, matching the TUI. bw_update_available is 1 when the bundled
 * core version is newer than the installed one. An installed coin with no version
 * marker reads as up to date (0), not out of date — its version is unknown, and
 * assuming it's behind would nag on every hand-installed binary.
 * bw_installed_version writes the marker's version, or 0 bytes if unknown. */
int     bw_update_available(bw_ctx *ctx, size_t idx);             /* 0/1 */
size_t  bw_installed_version(bw_ctx *ctx, size_t idx, char *buf, size_t cap);

/* Daemon control + wallet lock/unlock (the action buttons). Return 0 on success,
 * < 0 on error (then bw_last_error has the reason). They block (spawn / RPC), so
 * call them from a worker thread. The passphrase is a secret: it's copied into a
 * bounded buffer, used, and wiped; the caller must wipe its own copy too. */
int     bw_start_daemon(bw_ctx *ctx, size_t idx);
int     bw_stop_daemon(bw_ctx *ctx, size_t idx);

/* Download + install the coin's daemon. Returns 0 on success, < 0 on error (then
 * bw_last_error has the reason — e.g. UnsupportedPlatform for a coin with no
 * build for this OS/arch). Streams hundreds of MB, so it blocks for minutes:
 * call it from a worker thread and poll bw_install_progress from the UI.
 *
 * bw_install_progress writes through any non-NULL out-param and returns the
 * phase below. `total` is 0 when the server sent no content-length, so treat the
 * fraction as unknown rather than dividing by zero. Extraction streams in a
 * single pass with no byte total, hence a spinner rather than a bar. */
#define BW_INSTALL_IDLE        0
#define BW_INSTALL_DOWNLOADING 1
#define BW_INSTALL_EXTRACTING  2
int      bw_install(bw_ctx *ctx, size_t idx);
uint8_t  bw_install_progress(bw_ctx *ctx, uint64_t *cur, uint64_t *total);

/* Sync accelerator: a large, opt-in download offered *before* the first daemon
 * start that skips most of the initial chain sync — Divi's ~4.7 GB blockchain
 * snapshot, Nerva's QuickSync hashes.
 *
 * Ask bw_sync_accel_offered before bw_start_daemon; if it returns 1, show the
 * name + detail and let the user decide. On yes, run bw_sync_accel_run on a
 * worker thread and start the daemon after it succeeds; on no, just start the
 * daemon. bw_sync_accel_offered does cheap disk checks only, so it's safe on the
 * UI thread — and for a chain snapshot it is false whenever chain data already
 * exists, which is what stops a snapshot ever landing on top of another app's
 * blockchain.
 *
 * bw_sync_accel_trust_note returns the caution to show beside the pitch: these
 * accelerators are fast precisely because they skip verification the node would
 * otherwise do, and neither payload is verified by BoxWallet. It returns 0 bytes
 * for an accelerator that carries no such tradeoff, so render the block only when
 * there is text. Show it, and prefer "sync normally" as the default answer.
 *
 * bw_sync_accel_resume_bytes reports bytes of an interrupted download waiting on
 * disk (0 when there's nothing to resume), so the prompt can say the transfer
 * continues rather than restarts. A failed run keeps its partial for next time.
 *
 * bw_sync_accel_run blocks for a long time (GBs, then an unpack) and reports
 * progress through bw_install_progress — the same phases, so the existing
 * install progress pump drives it unchanged. Returns 0 on success,
 * BW_SYNC_ACCEL_PAUSED if the caller asked it to stop, and < 0 on error (then
 * bw_last_error has the reason).
 *
 * bw_sync_accel_pause asks a running transfer to stop at the next chunk boundary
 * and returns immediately; what's on disk is kept and resumable. It backs both
 * the Pause button and application shutdown — a multi-GB snapshot is very likely
 * still running when the user closes the window, so the correct close sequence
 * is: pause, WAIT FOR THE WORKER THREAD, then bw_deinit. Skipping the wait is a
 * use-after-free: the worker is still using the context bw_deinit frees. */
#define BW_SYNC_ACCEL_PAUSED 1
int      bw_sync_accel_offered(bw_ctx *ctx, size_t idx);          /* 0/1 */
size_t   bw_sync_accel_name(size_t idx, char *buf, size_t cap);
size_t   bw_sync_accel_detail(size_t idx, char *buf, size_t cap);
size_t   bw_sync_accel_trust_note(size_t idx, char *buf, size_t cap);
uint64_t bw_sync_accel_resume_bytes(bw_ctx *ctx, size_t idx);
int      bw_sync_accel_run(bw_ctx *ctx, size_t idx);
void     bw_sync_accel_pause(bw_ctx *ctx);
int     bw_wallet_lock(bw_ctx *ctx, size_t idx);
int     bw_wallet_unlock(bw_ctx *ctx, size_t idx, const uint8_t *passphrase, size_t len, int staking);

/* Wallet lock state for the padlock glyph. Returns BW_WSEC_UNKNOWN while the
 * daemon isn't answering (so the glyph stays greyed until we actually know).
 *
 * This is the *encryption* state of an in-daemon wallet, not a "can I read it"
 * flag: a bitcoin-family daemon serves getbalance / listtransactions /
 * getnewaddress on a LOCKED wallet. Only spending needs BW_WSEC_UNLOCKED (or
 * _STAKING, or an _UNENCRYPTED wallet that never locks). */
#define BW_WSEC_UNKNOWN     0
#define BW_WSEC_UNENCRYPTED 1
#define BW_WSEC_LOCKED      2
#define BW_WSEC_UNLOCKED    3
#define BW_WSEC_STAKING     4
int     bw_wallet_security(bw_ctx *ctx, size_t idx);

/* Bytes used / total on the filesystem holding the coin's data dir (for the
 * "disk used" gauge). Returns 0 on success, < 0 on error. */
typedef struct {
    uint64_t used_bytes;
    uint64_t total_bytes;
} BwDiskUsage;
int     bw_disk_usage(bw_ctx *ctx, size_t idx, BwDiskUsage *out);

/* ---- the in-daemon wallet menu -----------------------------------------------
 * Which actions a wallet state permits is decided in the core, by the same
 * module the TUI asks — so DON'T enumerate actions here. Call bw_wallet_menu and
 * render what comes back.
 *
 * Pass the BW_WSEC_* value you already have rather than making the core re-read
 * it: your padlock is drawn from that same value, and a menu describing a
 * different state than the glyph beside it is worse than a stale one. An
 * BW_WSEC_UNKNOWN state returns 0 actions — a menu built before the daemon has
 * said what it holds is a menu that can destroy a wallet.
 *
 * Every action takes a passphrase OR a path, never both; ask
 * bw_wallet_action_needs_password / _needs_path to decide which prompt to raise.
 * bw_wallet_action_sets_new_password marks the one that SETS a credential
 * (encrypt) — confirm it twice and refuse on mismatch, because there is no
 * recovering a wallet encrypted with a password nobody knows.
 *
 * Labels come from bw_wallet_action_label, never from here: "Restore from key
 * dump" and "Restore from wallet.dat" name the FILE each takes, BitcoinZ offers
 * both at once, and picking the wrong one is what ends in an empty wallet. */
#define BW_WCAP_ENCRYPT         (1 << 0)
#define BW_WCAP_BACKUP          (1 << 1)
#define BW_WCAP_IMPORT          (1 << 2)
#define BW_WCAP_RESTORE_OFFLINE (1 << 3)
#define BW_WCAP_PROOF_OF_STAKE  (1 << 4)  /* offers unlock-for-staking */
#define BW_WCAP_STAKE_ACTION    (1 << 5)  /* explicit stake (Salvium) */
int     bw_coin_wallet_caps(size_t idx);

#define BW_WA_ENCRYPT              0
#define BW_WA_UNLOCK               1
#define BW_WA_STAKE                2  /* unlock FOR staking */
#define BW_WA_LOCK                 3
#define BW_WA_BACKUP               4
#define BW_WA_RESTORE              5  /* key dump, daemon running */
#define BW_WA_RESTORE_FILE_OFFLINE 6  /* wallet.dat swap, daemon STOPPED */
size_t  bw_wallet_menu(size_t idx, int wallet_sec, uint8_t *out, size_t cap);
size_t  bw_wallet_action_label(uint8_t action, char *buf, size_t cap);
int     bw_wallet_action_needs_password(uint8_t action);
int     bw_wallet_action_needs_path(uint8_t action);
int     bw_wallet_action_sets_new_password(uint8_t action);

/* All of these block on RPC or the disk — worker thread.
 *
 * bw_wallet_encrypt: 0 ok, -1. Most daemons shut down after encrypting, which is
 * normal and not a failure.
 *
 * bw_wallet_backup generates a timestamped destination under the install root
 * (no save dialog; the timestamp dodges the daemon's refusal to overwrite) and
 * writes that path into buf, returning its length or 0 on failure. THE FILE
 * CONTAINS PRIVATE KEYS — say so, and say where it went.
 *
 * bw_wallet_restore_file_offline REFUSES while the daemon is alive, because a
 * daemon holds its wallet open and would overwrite the file on shutdown. Stop it
 * first: unlike the TUI, this does not stop and restart for you. */
int     bw_wallet_encrypt(bw_ctx *ctx, size_t idx, const uint8_t *passphrase, size_t len);
size_t  bw_wallet_backup(bw_ctx *ctx, size_t idx, char *buf, size_t cap);
int     bw_wallet_import_file(bw_ctx *ctx, size_t idx, const char *src_path);
int     bw_wallet_restore_file_offline(bw_ctx *ctx, size_t idx, const char *src_path);

/* Salvium's explicit stake. Same tri-state as bw_wallet_send: 0 broadcast (out =
 * txid), 1 rejected (out = the daemon's own reason), -1 transport failure.
 * bw_stake_hint is the coin's description of what staking commits to — show it
 * at the confirm step. */
int     bw_wallet_stake(bw_ctx *ctx, size_t idx, double amount, char *out, size_t cap);
size_t  bw_stake_hint(size_t idx, char *buf, size_t cap);

/* ---- settings: wallet file and pruning ---------------------------------------
 * bw_wallet_file_path returns 0 when the node manages the wallet itself and
 * there is no single file to name (Ergo, Epic). bw_wallet_keys_path returns the
 * `.keys` companion for coins whose wallet is a PAIR (the Monero family) and 0
 * for everyone else — worth showing, because someone who backs up the wallet
 * file and not its keys has backed up nothing they can restore from.
 *
 * bw_prune_mode: 0 = size cap in MiB, 1 = on/off, -1 = this coin doesn't prune.
 *
 * bw_prune_current writes the value from the conf and returns 1; returns 0 when
 * the key isn't there at all (NEVER CONFIGURED, which is not the same as a
 * deliberate 0 meaning full node), or -1 on error. It is NOT interchangeable
 * with bw_prune_should_offer: an adopted full node answers 0 here and still must
 * not be offered pruning, because its chain is already on disk.
 *
 * bw_prune_value_text describes a value in the coin's own units ("2 GB",
 * "disabled (full node)", "not set"). Pass -1 for "not configured". Use it
 * rather than formatting locally — "not set" and "disabled" look alike and mean
 * very different things.
 *
 * The two path calls and bw_prune_current read the disk: worker thread. The
 * other two are cheap and UI-thread safe. */
size_t  bw_wallet_file_path(bw_ctx *ctx, size_t idx, char *buf, size_t cap);
size_t  bw_wallet_keys_path(bw_ctx *ctx, size_t idx, char *buf, size_t cap);
int     bw_prune_mode(size_t idx);
int     bw_prune_current(bw_ctx *ctx, size_t idx, int64_t *out);
size_t  bw_prune_value_text(size_t idx, int64_t prune_mib, char *buf, size_t cap);

/* ---- the first-start prune prompt --------------------------------------------
 * bw_prune_should_offer: 1 = ask the user how to store the chain before starting
 * this daemon for the first time, 0 = don't (also 0 for coins that never prune).
 *
 * Cheap disk checks only, so it is fine straight from a click handler — and
 * calling it there is what keeps it uncacheable.
 *
 * CALL IT INSIDE THE START HANDLER AND ACT ON THE ANSWER IMMEDIATELY. Never
 * cache it; never put it in a UI property. It is an instant-in-time predicate
 * over two things that both move underneath you — whether the conf has a prune
 * key, and whether any chain data exists yet.
 *
 * The second half is why a stale answer is dangerous. An unpruned node has no
 * prune key BY DEFINITION, so "has the user chosen?" alone reads somebody's
 * fully-synced full node as "never asked" and offers to throw their blocks away,
 * with no un-prune short of a complete re-sync. The coins pair that check with
 * "and no blocks/ present", so the honest answer flips to 0 the moment a daemon
 * starts writing a chain — and a `true` cached from before then would offer to
 * discard it.
 *
 * Take the menu from bw_prune_preset_* rather than hard-coding one: Monero is an
 * on/off coin with its own rows and no custom amount, so a hard-coded GB list
 * would offer it a value it cannot honour. Row 0 is by convention the least
 * destructive choice, so a dialog defaulting to row 0 cannot discard a chain on
 * a stray Enter.
 *
 * bw_prune_apply writes the conf: 0 ok, -1 see bw_last_error. A failure is NOT a
 * reason to abort the start — log it and start unpruned, which is what the TUI
 * does. The user asked for a daemon; an unwritten preference is the smaller
 * problem. Apply the prune BEFORE the sync-accelerator prompt: both write into
 * the data dir, and that is the order the TUI uses. */
int     bw_prune_should_offer(bw_ctx *ctx, size_t idx);
size_t  bw_prune_prompt(size_t idx, char *buf, size_t cap);
size_t  bw_prune_preset_count(size_t idx);
size_t  bw_prune_preset_label(size_t idx, size_t row, char *buf, size_t cap);
int64_t bw_prune_preset_value(size_t idx, size_t row);
int     bw_prune_apply(bw_ctx *ctx, size_t idx, int64_t prune_value);

/* Whether the coin's RPC port accepts a connection right now: 1 reachable, 0 not.
 * A cheap TCP connect and close — no request, no auth. Worker thread only.
 *
 * Use it to tell UP-BUT-BUSY apart from DOWN. A daemon under load accepts the
 * connection instantly while stalling its RPC reply for seconds (Nerva does this
 * behind its blockchain lock), so treating a failed bw_daemon_info as "not
 * running" makes the whole UI flip to stopped and back every time the node is
 * busy. When the status reads fail, ask this: reachable means keep showing it as
 * running, and keep the last figures rather than zeroing them. */
int     bw_daemon_reachable(bw_ctx *ctx, size_t idx);

/* Window geometry, remembered across runs in BoxWallet's own settings conf (the
 * same file the TUI keeps hide_balances in, so writes merge rather than clobber).
 *
 * bw_window_geometry returns 1 with *out filled, or 0 when there's nothing usable
 * stored — then just let the window open at its default size. The size is
 * validated in the core, so a corrupt or hand-edited conf can't produce a window
 * too small to grab or larger than any screen. Position is optional: a conf with
 * only a size still returns 1, with x/y 0.
 *
 * The size is in LOGICAL pixels, so it means the same apparent size on a screen
 * with a different scale factor. Divide by the scale factor before saving; apply
 * it as the window's *preferred* size (not a resize) before showing the window.
 * A toolkit settles a window on its preferred size when it maps it, and a Wayland
 * compositor may refuse to let an app resize itself afterwards, so a resize is
 * the one way that does not survive.
 *
 * Save on the way out, from the UI thread (every slint::Window accessor asserts
 * it). A maximized window's size is deliberately not stored — it reports the
 * whole screen, which would become the restored "normal" size — so pass
 * maximized=1 and the previous size is kept.
 *
 * NOTE: position is not restorable on Wayland; the compositor places windows and
 * ignores an application asking otherwise. Size and maximized work everywhere. */
typedef struct {
    uint32_t width, height;
    int32_t  x, y;
    int      maximized;
} BwWindowGeometry;
int      bw_window_geometry(bw_ctx *ctx, BwWindowGeometry *out);   /* 1 = have one, 0 = none */
void     bw_save_window_geometry(bw_ctx *ctx, const BwWindowGeometry *g);

/* ---- file browsing (in-app file picker, backed by the core) -----------------
 * bw_home_dir fills a good starting directory. bw_list_dir lists a directory
 * into buf as newline-separated "<t> name" lines — t is 'd' for a directory or
 * 'f' otherwise, directories first, each group sorted. Returns bytes written (0
 * on error; truncates at a line boundary if buf fills). */
size_t  bw_home_dir(bw_ctx *ctx, char *buf, size_t cap);
size_t  bw_list_dir(const char *path, char *buf, size_t cap);

/* Live RPC reads. Return 0 on success (out filled), < 0 on error (then call
 * bw_last_error for the real daemon/RPC reason). These block on network I/O —
 * call them from a worker thread, never the Slint event-loop thread. */
int     bw_daemon_info(bw_ctx *ctx, size_t idx, BwDaemonInfo *out);
int     bw_blockchain_state(bw_ctx *ctx, size_t idx, BwBlockchainState *out);

/* What the daemon is doing while it can't answer the reads above yet: fills buf
 * with its start-up stage ("Loading block index…", "Rewinding…", "Verifying…",
 * "Loading blocks… 42.00%") and returns the length. 0 means it isn't warming
 * up — answering normally, or genuinely not running.
 *
 * A bitcoin-derived daemon opens its RPC port long before it can serve getinfo
 * (it answers -28 with its current init message meanwhile — 37s for Divi on a
 * loaded chain, minutes on a big one), so bw_daemon_info fails for all of a
 * healthy start. Call this when it does, to tell "still loading" from "not
 * running". Blocks on RPC + a log read: worker thread only. */
size_t  bw_daemon_stage(bw_ctx *ctx, size_t idx, char *buf, size_t cap);

/* ---- external wallet: service lifecycle + state -----------------------------
 * For a BW_EW_HAS_PROCESS coin the wallet is a *second* process BoxWallet spawns
 * alongside the daemon (Nerva's nerva-wallet-rpc) and tears down with it. It is
 * bound to localhost and locked to credentials generated fresh each run, because
 * a wallet RPC exposes the spend key.
 *
 * Drive it from the poller: _service_ensure whenever the daemon is running,
 * _service_stop whenever it isn't. Both spawn or kill a process — worker thread
 * only. _ensure returns 1 running, 0 nothing to do, BW_BUSY when a wallet op is
 * in flight, -1 failed (bw_last_error has why; the usual cause is a wallet-rpc
 * binary missing from an older install, so offer a reinstall). _ensure is
 * idempotent and cheap once up, and reports a failure only once per daemon run
 * rather than every tick. Both SKIP rather than wait when a wallet op holds the
 * core's lock — they run on your poll, and blocking there would freeze the whole
 * status pane behind a restore that can run for minutes. You call them again
 * next tick, and bw_deinit kills anything still standing.
 *
 * Running two BoxWallets against the same coin does not work: the wallet port is
 * fixed and the wallet dir is one directory, so the second instance's service
 * fails to bind. Close the other window rather than trying to share.
 *
 * bw_ext_wallet_state is the whole display state machine, computed in the core
 * so the GUI never re-derives it from separate booleans. It and
 * bw_ext_wallet_exists are cheap (a stat) — safe on the UI thread. */
#define BW_WALLET_NONE   0  /* nothing on disk yet          -> "No wallet" */
#define BW_WALLET_LOCKED 1  /* exists, not opened here      -> "Locked" */
#define BW_WALLET_OPEN   2  /* opened this session          -> "Unlocked" */
#define BW_WALLET_RESCAN 3  /* opened, still scanning       -> "Rescanning… X%" */
int     bw_ext_wallet_state(bw_ctx *ctx, size_t idx);
int     bw_ext_wallet_exists(bw_ctx *ctx, size_t idx);
int     bw_ext_wallet_service_ensure(bw_ctx *ctx, size_t idx);
void    bw_ext_wallet_service_stop(bw_ctx *ctx, size_t idx);

/* ---- external wallet: the operations ----------------------------------------
 * Every one of these blocks (spawn / RPC / a wallet CLI) and takes the core's
 * wallet lock: worker thread only, never the Slint event loop. They return 0 on
 * success and < 0 on failure — and on failure bw_last_error carries the sentence
 * meant for the user (the daemon's own message wherever it gave one, never
 * collapsed to a generic "failed"), while bw_last_error_code carries the bare
 * error name to branch on.
 *
 * Passwords and seeds are secrets and cross as raw bytes, never as a Slint
 * SharedString — that would copy them into GUI-owned memory nothing can wipe.
 * The core copies them into a bounded buffer and zeroes it on every return path;
 * the caller must secure-zero its own buffer immediately after the call
 * (explicit_bzero / SecureZeroMemory).
 *
 * A NEW password must be confirmed by the caller before it gets here: on a
 * freshly created wallet a mistyped password means the funds are unrecoverable.
 * bw_ext_wallet_open takes an existing password, which just fails and is retried,
 * so it needs no confirmation. */
int     bw_ext_wallet_create(bw_ctx *ctx, size_t idx, const uint8_t *pw, size_t pw_len);
int     bw_ext_wallet_restore_seed(bw_ctx *ctx, size_t idx, const uint8_t *pw, size_t pw_len,
                                   const uint8_t *seed, size_t seed_len);
int     bw_ext_wallet_restore_file(bw_ctx *ctx, size_t idx, const uint8_t *pw, size_t pw_len,
                                   const char *src_path);
int     bw_ext_wallet_open(bw_ctx *ctx, size_t idx, const uint8_t *pw, size_t pw_len);
int     bw_ext_wallet_lock(bw_ctx *ctx, size_t idx);   /* BW_EW_EXPLICIT_LOCK coins only */

/* DESTRUCTIVE: deletes the managed wallet's files so a different one can take
 * its place. Gate it behind an explicit typed confirmation. It kills the wallet
 * service first (releasing the file locks) and leaves the daemon running — the
 * chain sync is not the wallet's to throw away. Only ever removes what BoxWallet
 * itself created. For an in-daemon wallet (Ergo) the node caches the secret, so
 * the caller must stop the daemon, remove, then start it again. */
int     bw_ext_wallet_remove(bw_ctx *ctx, size_t idx);

/* A created wallet's mnemonic. Take it ONCE, render it, then let it go.
 *
 * Returns the byte count written and wipes the core's copy. Returns 0 when
 * nothing is pending, so the words can never be re-shown. If cap is smaller than
 * the phrase it returns the required size and copies NOTHING, keeping the user's
 * only backup rather than truncating it — pass a 256-byte buffer.
 *
 * bw_ext_wallet_seed_discard drops a pending seed unshown (Cancel, or navigating
 * away). Both are cheap and safe on the UI thread. */
size_t  bw_ext_wallet_seed_take(bw_ctx *ctx, char *buf, size_t cap);
void    bw_ext_wallet_seed_discard(bw_ctx *ctx);

/* ---- wallet reads -----------------------------------------------------------
 * All of these block on RPC — worker thread only. BW_BUSY means a wallet op
 * holds the core's lock: keep your last value rather than stalling the status
 * pump behind a restore that may run for minutes. */
#define BW_BUSY (-2)
typedef struct { double  total, available; } BwWalletBalance;
typedef struct { int64_t scanned, target;  } BwRescanProgress;
typedef struct {
    int     direction;      /* 0 received, 1 sent, 2 stake/mined */
    double  amount;         /* positive magnitude; direction carries the sign */
    int64_t time;           /* unix seconds */
    int64_t confirmations;
} BwWalletTx;

/* The coin's wallet balance, whichever backing it has: 0 with *out filled,
 * BW_BUSY, or -1. A managed wallet answers from its own wallet-rpc, an in-daemon
 * wallet from the daemon — one question, one call.
 *
 * The "wallet must be open" gate applies only to a managed wallet. A
 * bitcoin-family daemon serves getbalance on a *locked* wallet, so don't gate
 * this on the padlock: Bitcoin, Litecoin, DigiByte, Divi, Nexa, ReddCoin,
 * BitcoinZ and SpiderByte all report a balance the moment the daemon answers. */
int     bw_wallet_balance(bw_ctx *ctx, size_t idx, BwWalletBalance *out);

/* Managed-wallet spelling of bw_wallet_balance: -1 for a coin whose wallet lives
 * in its daemon, otherwise identical. */
int     bw_ext_wallet_balance(bw_ctx *ctx, size_t idx, BwWalletBalance *out);

/* 1 = still scanning (*out filled), 0 = not scanning, BW_BUSY, -1 = error.
 * After a restore the wallet refreshes from height 0 in the background and its
 * balance reads 0 until it catches up — show this progress rather than an
 * empty wallet the user will read as lost funds. */
int     bw_ext_wallet_rescan(bw_ctx *ctx, size_t idx, BwRescanProgress *out);

/* Most recent transactions, newest first; returns how many were written. 0 on
 * any failure — an unreadable list is empty, not worth interrupting the user. */
size_t  bw_wallet_transactions(bw_ctx *ctx, size_t idx, BwWalletTx *out, size_t cap);

/* The wallet's receive address; returns its length, 0 on failure. force_new
 * mints a fresh one.
 *
 * NEVER call this on a timer. The underlying RPC rotates the address once it has
 * been paid, so polling would swap it out from under a user part-way through
 * sending to it. Call it once when nothing is cached, and again only when the
 * user explicitly asks for a new one — your cache decides, not the clock. */
size_t  bw_wallet_receive_address(bw_ctx *ctx, size_t idx, int force_new, char *buf, size_t cap);

/* 0 = broadcast (out = txid), 1 = the daemon rejected it (out = its own reason,
 * verbatim), -1 = transport failure (bw_last_error has why). A rejection is an
 * answer, not an error: "insufficient funds" is something the user must read.
 *
 * Confirm the full, untruncated address with the user before calling. It is the
 * one typo safety net a machine cannot provide. */
int     bw_wallet_send(bw_ctx *ctx, size_t idx, const char *address, double amount,
                       char *out, size_t cap);

/* ---- mining -----------------------------------------------------------------
 * Only meaningful for a coin where bw_coin_supports_mining is 1: its daemon
 * mines in-process (the CryptoNote CPU coins — Nerva), so the miner is driven
 * through the *daemon's* RPC, not the wallet's.
 *
 * bw_mining_status returns 0 with *out filled, or < 0 (bw_last_error has why).
 * It blocks on RPC — worker thread only. `threads` and `speed` are zero
 * whenever `active` is 0, so a stale figure from the last run can never read as
 * current. */
typedef struct {
    int      active;
    uint32_t threads;
    uint64_t speed;   /* hashes per second */
} BwMiningStatus;
int      bw_mining_status(bw_ctx *ctx, size_t idx, BwMiningStatus *out);

/* Start / stop the miner. Both block on RPC — worker thread only. 0 on success,
 * < 0 on failure (bw_last_error_code names it; bw_mining_failure_text turns that
 * into a sentence — "the daemon is still syncing" is the common one).
 *
 * `address` is supplied by YOU, not looked up here: it must be the wallet's own
 * receive address, the one the user can actually see. `threads` must be in
 * 1..bw_cpu_threads(). */
int      bw_mining_start(bw_ctx *ctx, size_t idx, const char *address, uint32_t threads);
int      bw_mining_stop(bw_ctx *ctx, size_t idx);

/* Cheap helpers — no I/O, safe on the Slint event-loop thread.
 * bw_cpu_threads is the upper bound on what the miner may be asked for.
 * bw_format_hashrate renders a speed ("1.23 MH/s"); it is exported rather than
 * reimplemented C++-side so both front-ends round and label identically.
 * bw_mining_failure_text turns the bare error name from a failed start/stop
 * into a sentence the user can act on. All three return the length written. */
uint32_t bw_cpu_threads(void);
size_t   bw_format_hashrate(uint64_t speed, char *buf, size_t cap);
size_t   bw_mining_failure_text(const char *err_name, char *buf, size_t cap);

/* ---- secrets contract -------------------------------------------------------
 * PASSWORDS AND SEEDS IN. They cross as (const uint8_t *ptr, size_t len), never
 * as a Slint property/SharedString, which would copy them into GUI-owned memory
 * nothing can wipe. Zig copies the bytes into its own bounded buffer immediately
 * and zeroes it on every return path; the C++ caller must secure-zero its input
 * buffer right after the call returns (explicit_bzero / SecureZeroMemory).
 *
 * A CREATED WALLET'S SEED OUT. This one cannot be held to the same standard, and
 * saying so is better than implying otherwise. Slint renders text only from a
 * property, so the words must land in one. The contract is therefore:
 *
 *   The seed is taken once via bw_ext_wallet_seed_take (which wipes the core's
 *   copy) and held in EXACTLY ONE property for EXACTLY as long as the
 *   seed-display modal is open, then set to "". Never a second property, never
 *   split into per-word properties, never the clipboard, never a log, never disk.
 *
 * What that guarantees: the core holds no copy after the take; nothing outside
 * the modal's lifetime holds one; the modal cannot be reopened to show it again.
 *
 * What it does NOT guarantee: a Slint SharedString is a reference-counted heap
 * allocation freed without zeroing, so the words may persist in the GUI process's
 * heap until that memory is reused, and could surface in a core dump or swap.
 * C++ cannot securely wipe it. This is the same exposure the TUI has (ZigZag
 * renders into its own frame buffers), so it is not a GUI-specific regression —
 * but it is a real limit, and it belongs written down rather than assumed away.
 *
 * What follows: keep the display window short. Walk the user straight from
 * "write this down" to a verification step that proves they did, and clear the
 * property on every exit path from the modal. */

#ifdef __cplusplus
}
#endif

#endif /* BOXWALLET_H */
