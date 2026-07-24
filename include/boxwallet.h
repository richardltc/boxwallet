/* BoxWallet core — C ABI for the Slint GUI front-end.
 *
 * Implemented in src/capi.zig; linked into the GUI executable by `zig build gui`.
 * The C++ Slint glue includes this header and calls these functions to drive the
 * exact same coin logic as the TUI. Proof-of-concept surface: read-only status
 * for one coin (Divi). No secrets cross this boundary yet — see the note below.
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

/* Copy the last recorded error message for ctx into buf (up to cap bytes);
 * returns the number of bytes written. Set after any call that returned < 0. */
size_t  bw_last_error(bw_ctx *ctx, char *buf, size_t cap);

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
int     bw_coin_supports_mining(size_t idx);      /* 0/1 — shows the Mining tab */
int     bw_coin_supports_stablecoin(size_t idx);  /* 0/1 — shows the DigiDollar tab */

/* ---- status ----------------------------------------------------------------- */
int     bw_is_installed(bw_ctx *ctx, size_t idx);                 /* 0/1 */
size_t  bw_data_dir(bw_ctx *ctx, size_t idx, char *buf, size_t cap);

/* Daemon control + wallet lock/unlock (the action buttons). Return 0 on success,
 * < 0 on error (then bw_last_error has the reason). They block (spawn / RPC), so
 * call them from a worker thread. The passphrase is a secret: it's copied into a
 * bounded buffer, used, and wiped; the caller must wipe its own copy too. */
int     bw_start_daemon(bw_ctx *ctx, size_t idx);
int     bw_stop_daemon(bw_ctx *ctx, size_t idx);
int     bw_wallet_lock(bw_ctx *ctx, size_t idx);
int     bw_wallet_unlock(bw_ctx *ctx, size_t idx, const uint8_t *passphrase, size_t len, int staking);

/* Wallet lock state for the padlock glyph: 0 unknown, 1 unencrypted, 2 locked,
 * 3 unlocked, 4 unlocked-for-staking. Returns 0 while the daemon isn't answering
 * (so the glyph stays greyed until we actually know the status). */
int     bw_wallet_security(bw_ctx *ctx, size_t idx);

/* Bytes used / total on the filesystem holding the coin's data dir (for the
 * "disk used" gauge). Returns 0 on success, < 0 on error. */
typedef struct {
    uint64_t used_bytes;
    uint64_t total_bytes;
} BwDiskUsage;
int     bw_disk_usage(bw_ctx *ctx, size_t idx, BwDiskUsage *out);

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

/* ---- FUTURE: secrets contract (not yet implemented) -------------------------
 * Wallet ops (create/restore/unlock) will take secrets as (const uint8_t *ptr,
 * size_t len) — NEVER as a Slint property/SharedString, which would copy them
 * into GUI-owned memory we cannot wipe. Zig copies the bytes into its own
 * bounded buffer immediately; the C++ caller must secure-zero its input buffer
 * right after the call returns (explicit_bzero / SecureZeroMemory). A created
 * wallet's seed is shown via a one-shot callback and must be rendered then
 * discarded, never persisted in a property. */

#ifdef __cplusplus
}
#endif

#endif /* BOXWALLET_H */
