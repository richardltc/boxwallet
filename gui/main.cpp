// BoxWallet GUI — proof-of-concept host (Slint + the Zig core over a C ABI).
//
// This is the only C++ in the project: the thin glue Slint's binding requires.
// All wallet/coin logic lives in the Zig core and is reached through bw_* (see
// include/boxwallet.h). A background thread polls the live daemon (blocking RPC)
// and marshals results onto the Slint event-loop thread via
// slint::invoke_from_event_loop — the RPC calls must never run on the UI thread.
//
// Built by `zig build gui` (no CMake): build.zig runs slint-compiler to produce
// app.slint.h, then compiles+links this with Zig's own clang.

#include "app.slint.h" // generated from gui/app.slint by slint-compiler
#include <slint.h>      // Slint runtime: SharedString, invoke_from_event_loop
#include "boxwallet.h"  // the Zig core's C ABI
#include "monofont.h"   // embedded DejaVu Sans Mono (mono_font / mono_font_len)

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <ctime>
#include <random>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

// The selected coin's registry index, or -1 for the Home page. Shared between
// the UI thread (nav callback) and the poller thread.
static std::atomic<int> g_selected{-1};

// Lets the nav callback wake the poller the instant the selection changes,
// instead of it waiting out its ~2s cadence — so a freshly-clicked coin shows
// its stats right away. `g_sel_gen` bumps on every selection; the poller waits
// until it changes (or times out) rather than sleeping blindly.
static std::mutex g_poll_mtx;
static std::condition_variable g_poll_cv;
static std::atomic<uint64_t> g_sel_gen{0};

// Registry index of the coin currently installing, or -1 for none. An install
// runs for minutes while the install-* UI properties are global (one detail
// pane, reused by every coin), so the progress pump gates on this: it only
// paints the bar while that same coin is on screen, and blanks it when the user
// navigates away — otherwise a Bitcoin download would render as progress on
// whatever coin they switched to.
static std::atomic<int> g_installing{-1};

// Number of detached worker threads still using the bw_ctx.
//
// Every action here runs detached, but `ui->run()` returning goes straight on to
// bw_deinit — so without a barrier, any worker still in flight when the window
// closes reads a freed context. That was a reliable SEGV on quit, and a 4.7 GB
// snapshot download makes the window it can happen in enormous. Workers bump
// this around their whole lifetime and shutdown waits for it to drain.
static std::atomic<int> g_workers{0};
static std::mutex g_workers_mtx;
static std::condition_variable g_workers_cv;
// Set once the window has closed, so a worker finishing afterwards doesn't try
// to touch the (now dead) event loop.
static std::atomic<bool> g_shutting_down{false};

// RAII claim on the context for the life of a detached worker.
struct WorkerGuard {
    WorkerGuard() { g_workers.fetch_add(1); }
    ~WorkerGuard()
    {
        if (g_workers.fetch_sub(1) == 1) {
            std::lock_guard<std::mutex> lk(g_workers_mtx);
            g_workers_cv.notify_all();
        }
    }
};

// Serialises "is the event loop still there?" with the actual post. Posting into
// a loop that has already quit is not survivable, and the check and the post have
// to be one step or the loop can die between them — hence a mutex rather than a
// bare flag. Shutdown declares itself under the same lock, from the window's
// close callback, which runs while the loop is still alive: any post is then
// either already complete or blocked and about to see the flag.
static std::mutex g_ui_mtx;

template <typename F> static void post_to_ui(F &&fn)
{
    std::lock_guard<std::mutex> lk(g_ui_mtx);
    if (g_shutting_down.load())
        return;
    slint::invoke_from_event_loop(std::forward<F>(fn));
}

// One managed-wallet op at a time. The core serialises them anyway; this stops
// the UI from firing a second while the first is still in flight.
static std::atomic<bool> g_wallet_busy{false};

// How many transactions the list holds. Fixed, like the TUI's cache: bounded
// working set beats an unbounded history nobody scrolls through.
static constexpr size_t TX_CAP = 20;

// The receive address, cached per coin. This cache — not the poll timer — is
// what decides when bw_wallet_receive_address is called, because the underlying
// RPC rotates the address once it has been paid. `g_want_new_addr` is the user
// explicitly asking for a fresh one.
static std::vector<std::string> g_recv_addr;
static std::atomic<bool> g_want_new_addr{false};

// Last wallet-service failure shown, so a persistent one is reported once
// rather than rewritten over the status line on every poll. UI thread only.
static std::string g_last_wallet_svc_err;

// ---- secrets ----------------------------------------------------------------
// Passwords and seeds cross the C ABI as raw bytes, never as a SharedString —
// see the secrets contract in include/boxwallet.h. These two are the only way
// they should be handled, so no call site can forget the wipe.

static std::vector<uint8_t> to_secret_bytes(const slint::SharedString &s)
{
    std::string_view sv(s);
    return std::vector<uint8_t>(sv.begin(), sv.end());
}

// Zero through a volatile pointer so the compiler can't elide the store on a
// buffer that is about to be destroyed.
static void wipe_secret(std::vector<uint8_t> &v)
{
    volatile uint8_t *p = v.data();
    for (size_t i = 0; i < v.size(); ++i)
        p[i] = 0;
}

// The message a failed call left behind, already turned into a sentence for the
// user by the core (the daemon's own reason wherever it gave one).
static std::string last_error_text(bw_ctx *ctx, int rc)
{
    if (rc >= 0)
        return {};
    char b[256] = {0};
    size_t n = bw_last_error(ctx, b, sizeof b);
    std::string msg(b, n);
    return msg.empty() ? std::string("that didn't work") : msg;
}

// The bare error name, for branching (a wrong password shouldn't throw the user
// out of the modal — it should put them back on the password field).
static std::string last_error_code(bw_ctx *ctx)
{
    char b[64] = {0};
    size_t n = bw_last_error_code(ctx, b, sizeof b);
    return std::string(b, n);
}

// Settle a mining start/stop. On failure the core names the error and turns it
// into a sentence — "the daemon is still syncing" is the one users hit most, and
// it means wait, not that anything is broken.
static void finish_mining(slint::ComponentWeakHandle<AppWindow> w, bw_ctx *ctx, int rc)
{
    std::string msg;
    if (rc < 0) {
        char code[64] = {0};
        size_t cn = bw_last_error_code(ctx, code, sizeof code);
        char text[256] = {0};
        size_t tn = bw_mining_failure_text(std::string(code, cn).c_str(), text, sizeof text);
        msg.assign(text, tn);
        if (msg.empty())
            msg = last_error_text(ctx, rc);
    }
    post_to_ui([w, msg]() {
        if (auto h = w.lock()) {
            (*h)->set_mining_busy(false);
            (*h)->set_mining_error(slint::SharedString(msg));
        }
    });
}

// Declare shutdown: no further posts to the event loop after this returns.
static void begin_shutdown()
{
    std::lock_guard<std::mutex> lk(g_ui_mtx);
    g_shutting_down.store(true);
}

static const char *home_dir()
{
    const char *h = std::getenv("HOME");
    return h ? h : "/";
}

// Parse a "#RRGGBB" brand-colour string into a Slint colour (falls back to grey).
static slint::Color parse_hex_color(const char *s, size_t n)
{
    auto hexval = [](char c) -> int {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    };
    if (n == 7 && s[0] == '#') {
        int r = hexval(s[1]) * 16 + hexval(s[2]);
        int g = hexval(s[3]) * 16 + hexval(s[4]);
        int b = hexval(s[5]) * 16 + hexval(s[6]);
        if (r >= 0 && g >= 0 && b >= 0)
            return slint::Color::from_rgb_uint8(
                static_cast<uint8_t>(r), static_cast<uint8_t>(g), static_cast<uint8_t>(b));
    }
    return slint::Color::from_rgb_uint8(0x88, 0x88, 0x88);
}

// Sync fraction for one gauge: full when the node reports synced, otherwise the
// share of the network tip reached (0 when the tip isn't known yet).
static float sync_frac(int64_t part, int64_t total, bool synced)
{
    if (synced)
        return 1.0f;
    if (total <= 0)
        return 0.0f;
    double f = static_cast<double>(part) / static_cast<double>(total);
    return static_cast<float>(f < 0 ? 0 : (f > 1 ? 1 : f));
}

// "4136946" -> "4,136,946".
static std::string group_int(int64_t n)
{
    bool neg = n < 0;
    std::string s = std::to_string(neg ? -static_cast<uint64_t>(n) : static_cast<uint64_t>(n));
    for (int i = static_cast<int>(s.size()) - 3; i > 0; i -= 3)
        s.insert(static_cast<size_t>(i), ",");
    return neg ? "-" + s : s;
}

// Bytes -> "12.3 GB".
static std::string humanize_bytes(uint64_t b)
{
    static const char *unit[] = {"B", "KB", "MB", "GB", "TB", "PB"};
    double v = static_cast<double>(b);
    int u = 0;
    while (v >= 1024.0 && u < 5) {
        v /= 1024.0;
        u++;
    }
    char buf[32];
    std::snprintf(buf, sizeof buf, u == 0 ? "%.0f %s" : "%.1f %s", v, unit[u]);
    return std::string(buf);
}

// An amount to the coin's own precision, thousands-grouped ("1,234.56789012").
// Amount text comes from the core, not from a local implementation. It used to
// be a C++ snprintf plus manual comma insertion, against the TUI's printFloat
// plus digit grouping — two implementations of one number, free to disagree on
// rounding and on where the commas land. Now there is one.
static std::string format_amount(double v, int decimals)
{
    char buf[96];
    size_t n = bw_format_amount(v, static_cast<uint8_t>(decimals), buf, sizeof buf);
    return std::string(buf, n);
}

// As format_amount, with trailing zeros dropped — for the Transactions column,
// where a stack of full-precision figures is noise. This is what the TUI shows
// there. Balances keep their full precision, so a zero one still reads as a
// balance rather than a bare "0".
static std::string format_amount_trimmed(double v, int decimals)
{
    char raw[96];
    size_t rn = bw_format_amount(v, static_cast<uint8_t>(decimals), raw, sizeof raw);
    char out[96];
    size_t n = bw_trim_zeros(raw, rn, out, sizeof out);
    return std::string(out, n);
}

// A unix timestamp as "3 hours ago". Coarse on purpose: the exact second of a
// transaction is never what the user is asking.
static std::string relative_time(int64_t t)
{
    if (t <= 0)
        return "pending";
    int64_t now = static_cast<int64_t>(std::time(nullptr));
    int64_t d = now - t;
    if (d < 0)
        d = 0;
    if (d < 60)
        return "just now";
    auto plural = [](int64_t n, const char *unit) {
        return std::to_string(n) + " " + unit + (n == 1 ? "" : "s") + " ago";
    };
    if (d < 3600)
        return plural(d / 60, "minute");
    if (d < 86400)
        return plural(d / 3600, "hour");
    if (d < 2592000)
        return plural(d / 86400, "day");
    if (d < 31536000)
        return plural(d / 2592000, "month");
    return plural(d / 31536000, "year");
}

// Turn the core's scalar transactions into display rows.
static std::shared_ptr<slint::VectorModel<WalletTxRow>>
make_tx_rows(const std::vector<BwWalletTx> &txs, int decimals)
{
    std::vector<WalletTxRow> rows;
    rows.reserve(txs.size());
    for (const BwWalletTx &t : txs) {
        bool incoming = (t.direction != 1); // 0 received, 2 mined
        WalletTxRow r;
        r.direction = slint::SharedString(t.direction == 0   ? "Received"
                                          : t.direction == 1 ? "Sent"
                                                             : "Mined");
        // The core sends a positive magnitude and the direction alongside it, so
        // the sign is applied here rather than guessed from the number.
        r.amount = slint::SharedString((incoming ? "+" : "-") + format_amount_trimmed(t.amount, decimals));
        r.when = slint::SharedString(relative_time(t.time));
        r.confirmations = slint::SharedString(
            t.confirmations <= 0 ? std::string("unconfirmed")
                                 : group_int(t.confirmations) + " conf");
        r.incoming = incoming;
        rows.push_back(std::move(r));
    }
    return std::make_shared<slint::VectorModel<WalletTxRow>>(std::move(rows));
}

// Re-read the coin's update state from disk (a tiny marker file, cheap enough for
// the UI thread). Called on selection and after an install, so the Update button
// appears as soon as the coin is known to be behind and clears once it isn't.
static void refresh_update_state(const AppWindow *ui, bw_ctx *ctx, int idx)
{
    char ver[32];
    size_t n = bw_installed_version(ctx, static_cast<size_t>(idx), ver, sizeof ver);
    ui->set_installed_version(slint::SharedString(std::string_view(ver, n)));
    ui->set_update_available(bw_update_available(ctx, static_cast<size_t>(idx)) != 0);
}

// Run `work` on the calling thread while a second thread pumps progress into the
// UI at ~8 fps, and return `work`'s rc. Shared by Install, Update, and the sync
// accelerator — they differ in what they do, not in how progress is driven, and
// all three report through the same download/extract phases in the Zig context.
static int run_with_progress(slint::ComponentWeakHandle<AppWindow> weak, bw_ctx *ctx, int coin,
                             const std::function<int()> &work)
{
    auto done = std::make_shared<std::atomic<bool>>(false);
    std::thread pump([weak, ctx, coin, done]() {
        while (!done->load()) {
            uint64_t cur = 0, total = 0;
            uint8_t phase = bw_install_progress(ctx, &cur, &total);
            // A negative fraction means "length unknown" — the bar renders that as
            // indeterminate rather than as a stuck 0%.
            float frac = total > 0
                ? static_cast<float>(static_cast<double>(cur) / static_cast<double>(total))
                : -1.0f;
            std::string bytes;
            if (total > 0)
                bytes = humanize_bytes(cur) + " / " + humanize_bytes(total);
            else if (cur > 0)
                bytes = humanize_bytes(cur);
            post_to_ui([weak, coin, phase, frac, bytes]() {
                auto h = weak.lock();
                if (!h)
                    return;
                // Only paint onto the coin actually installing (see g_installing).
                if (g_selected.load() != coin) {
                    (*h)->set_install_busy(false);
                    (*h)->set_install_phase(0);
                    return;
                }
                (*h)->set_install_busy(true);
                (*h)->set_install_phase(static_cast<int>(phase));
                (*h)->set_install_frac(frac);
                (*h)->set_install_bytes(slint::SharedString(bytes));
            });
            std::this_thread::sleep_for(std::chrono::milliseconds(125));
        }
    });

    int rc = work();
    done->store(true);
    pump.join();
    return rc;
}

// The install/update flavour: download + install the coin's daemon bundle.
static int install_with_progress(slint::ComponentWeakHandle<AppWindow> weak, bw_ctx *ctx, int coin)
{
    return run_with_progress(weak, ctx, coin,
                             [ctx, coin]() { return bw_install(ctx, static_cast<size_t>(coin)); });
}

// Clear the progress readout and publish an install/update outcome, releasing the
// g_installing claim. Re-reads installed state and update state from disk rather
// than inferring them from rc — that's what the buttons gate on, and it's the
// honest answer either way (it's also what makes the Update button disappear once
// the coin is current).
static void finish_install(slint::ComponentWeakHandle<AppWindow> weak, bw_ctx *ctx, int coin,
                           int rc, const std::string &ok_msg, const char *fail_msg)
{
    bool is_err = rc < 0;
    std::string msg = ok_msg;
    if (is_err) {
        char b[256] = {0};
        size_t n = bw_last_error(ctx, b, sizeof b);
        msg.assign(b, n);
        if (msg.empty())
            msg = fail_msg;
    }
    bool installed = bw_is_installed(ctx, static_cast<size_t>(coin)) != 0;
    char ver[32];
    size_t vn = bw_installed_version(ctx, static_cast<size_t>(coin), ver, sizeof ver);
    std::string version(ver, vn);
    bool upd = bw_update_available(ctx, static_cast<size_t>(coin)) != 0;
    g_installing.store(-1);

    post_to_ui([weak, coin, msg, is_err, installed, version, upd]() {
        auto h = weak.lock();
        if (!h)
            return;
        (*h)->set_install_busy(false);
        (*h)->set_install_phase(0);
        (*h)->set_install_frac(0);
        (*h)->set_install_bytes(slint::SharedString(""));
        // The user may have navigated elsewhere during the install — don't stamp
        // this coin's result onto whatever they're looking at now.
        if (g_selected.load() != coin)
            return;
        (*h)->set_installed(installed);
        (*h)->set_installed_version(slint::SharedString(version));
        (*h)->set_update_available(upd);
        (*h)->set_status_text(slint::SharedString(msg));
        (*h)->set_status_is_error(is_err);
    });
}

// Push the selected coin's static metadata into the UI and clear any live status
// left over from the previously-selected coin (the poller refills it).
static void apply_coin_metadata(const AppWindow *ui, bw_ctx *ctx, int idx)
{
    char name[64];
    size_t nn = bw_coin_name(idx, name, sizeof name);
    ui->set_coin_name(slint::SharedString(std::string_view(name, nn)));

    char desc[128];
    size_t dn = bw_coin_description(idx, desc, sizeof desc);
    ui->set_coin_desc(slint::SharedString(std::string_view(desc, dn)));

    char color[16];
    size_t cn = bw_coin_color(idx, color, sizeof color);
    ui->set_coin_color(parse_hex_color(color, cn));

    char ver[32];
    size_t vn = bw_coin_version(idx, ver, sizeof ver);
    ui->set_coin_version(slint::SharedString(std::string_view(ver, vn)));

    // Ticker, for the balance label on the title line ("DIVI: 123.45").
    char abbrev[16];
    size_t an = bw_coin_abbrev(idx, abbrev, sizeof abbrev);
    ui->set_coin_abbrev(slint::SharedString(std::string_view(abbrev, an)));

    // Two-tone wordmark, for the three coins that have one — ReddCoin's "Redd" +
    // "Coin", SpiderByte's white "Spider" + brand "Byte", BitcoinZ's "Bitcoin" +
    // "Z". The core owns the split and both colours so the GUI wears exactly the
    // branding the TUI does; everything else draws its whole name in coin-color.
    BwWordmark wm;
    const bool has_wordmark =
        bw_coin_wordmark(idx, &wm) == 1 && wm.split > 0 && wm.split < nn;
    ui->set_has_wordmark(has_wordmark);
    if (has_wordmark) {
        std::string_view full(name, nn);
        ui->set_wordmark_head(slint::SharedString(full.substr(0, wm.split)));
        ui->set_wordmark_tail(slint::SharedString(full.substr(wm.split)));
        ui->set_wordmark_head_color(parse_hex_color(wm.head_color, std::strlen(wm.head_color)));
        ui->set_wordmark_tail_color(parse_hex_color(wm.tail_color, std::strlen(wm.tail_color)));
    }

    ui->set_has_mining(bw_coin_supports_mining(idx) != 0);
    ui->set_has_stablecoin(bw_coin_supports_stablecoin(idx) != 0);
    // Which wallet tabs this coin earns. Pure metadata, so it's settled here at
    // selection time rather than waiting up to two seconds for the first poll —
    // the tab strip must not flicker its way into shape.
    ui->set_has_balance(bw_coin_supports_balance(idx) != 0);
    ui->set_has_transactions(bw_coin_supports_transactions(idx) != 0);
    ui->set_has_receive(bw_coin_supports_receive_address(idx) != 0);
    ui->set_has_send(bw_coin_supports_send(idx) != 0);
    // Whether a send can go through is live state, not metadata: it needs the
    // wallet unlocked, which only the poll knows. Start closed.
    ui->set_can_send(false);
    ui->set_wallet_menu_count(0);
    ui->set_installed(bw_is_installed(ctx, idx) != 0);
    refresh_update_state(ui, ctx, idx);

    // Carry the install readout only if *this* coin is the one installing; any
    // other coin starts blank rather than inheriting the last one's bar. The
    // progress pump repaints it within a tick if we're switching back to it.
    bool this_installing = (g_installing.load() == static_cast<int>(idx));
    ui->set_install_busy(this_installing);
    if (!this_installing) {
        ui->set_install_phase(0);
        ui->set_install_frac(0);
        ui->set_install_bytes(slint::SharedString(""));
    }
    // A paused transfer belongs to the coin it was started on, and the readout is
    // global to the pane — so switching coins drops it rather than showing another
    // coin someone else's paused bar. The partial is still on disk: that coin's
    // Start offers to resume it, as it did before this button existed.
    ui->set_accel_paused(false);
    ui->set_accel_pausing(false);

    // Reset live status so the new coin doesn't briefly show the old one's.
    ui->set_running(false);
    ui->set_synced(false);
    ui->set_staking(false);
    ui->set_blocks(0);
    ui->set_headers(0);
    ui->set_peers(0);
    ui->set_headers_frac(0);
    ui->set_blocks_frac(0);
    ui->set_disk_frac(0);
    ui->set_wallet_sec(0);
    const int ew_flags = bw_coin_ext_wallet(idx);
    ui->set_ew_flags(ew_flags);
    // Decoded here rather than in Slint (no bitwise operators there) because it
    // gates the whole wallet menu, not one button: the core has no per-open
    // launch-with-password lifecycle for this front-end yet, so offering the
    // actions would only ever produce "Unsupported".
    ui->set_wallet_launch_with_pw((ew_flags & BW_EW_LAUNCH_WITH_PW) != 0);
    ui->set_wallet_state(BW_WALLET_NONE);
    uint32_t counts[4] = {25, 0, 0, 0};
    if (bw_coin_seed_word_counts(idx, counts, 4) > 0)
        ui->set_seed_word_count(static_cast<int>(counts[0]));
    // A modal left open over the coin we're leaving would ask its question about
    // the wrong wallet; and any seed still pending was never shown.
    ui->set_wallet_stage(0);
    ui->set_wallet_seed_words(slint::SharedString(""));
    bw_ext_wallet_seed_discard(ctx);
    // Settings are per-coin and static; a worker fills them in just after this
    // (see on_coin_selected). Cleared here so the tab never shows the coin we
    // just left — a wallet path is exactly the sort of thing someone copies.
    ui->set_wallet_file_path(slint::SharedString(""));
    ui->set_wallet_keys_path(slint::SharedString(""));
    ui->set_prune_mode(bw_prune_mode(idx));
    ui->set_prune_text(slint::SharedString(""));
    ui->set_balance_total(slint::SharedString("—"));
    ui->set_balance_avail(slint::SharedString("—"));
    ui->set_rescan_frac(0);
    ui->set_receive_address(slint::SharedString(""));
    ui->set_tx_rows(std::make_shared<slint::VectorModel<WalletTxRow>>(std::vector<WalletTxRow>{}));
    ui->set_mining(false);
    ui->set_mining_threads(0);
    ui->set_mining_hashrate(slint::SharedString(""));
    ui->set_cpu_threads(static_cast<int>(bw_cpu_threads()));
    ui->set_sync_percent(0);
    ui->set_chain(slint::SharedString(""));
    ui->set_headers_str(slint::SharedString(""));
    ui->set_blocks_str(slint::SharedString(""));
    ui->set_disk_free(slint::SharedString(""));
    ui->set_status_text(slint::SharedString(""));
    ui->set_live_status(slint::SharedString(""));
    ui->set_status_is_error(false);
    // Including the warm-up readout: the coin we're leaving may well still be
    // loading, and its stage must not read as this one's.
    ui->set_daemon_loading(false);
    ui->set_daemon_stage(slint::SharedString(""));
}

// ---- in-app file browser state + helpers ------------------------------------
// The browser navigates the filesystem via the core (bw_home_dir / bw_list_dir).
// C++ owns the current path and the current entries; the Slint callbacks below
// drive navigation. All run on the UI thread (no blocking I/O to speak of).
//
// Seeded to the home dir at startup, not left empty: the wallet restore-from-file
// flow opens the browser directly, and an empty path lists nothing — the user
// would meet a blank pane where their wallet backup should be.
// Which coin the prune prompt was opened for. The dialog acts on THIS, not on
// g_selected: the user can move the nav while a modal is up, and applying a
// prune choice to the wrong coin would rewrite the wrong conf.
static int g_prune_coin = -1;

// The in-daemon wallet action in flight: which coin, which action ordinal, and
// the menu we last showed. Like the prune dialog, the action targets the coin it
// was opened FOR — the nav stays live behind a modal.
static int g_wa_coin = -1;
static uint8_t g_wa_action = 0;
static std::vector<uint8_t> g_wa_menu;

static std::string g_browse_path;
static std::vector<BrowseEntry> g_entries;

static std::string path_join(const std::string &base, const std::string &name)
{
    if (base.empty())
        return "/" + name;
    return base.back() == '/' ? base + name : base + "/" + name;
}

static std::string path_parent(const std::string &p)
{
    std::string s = p;
    if (s.size() > 1 && s.back() == '/')
        s.pop_back();
    auto pos = s.find_last_of('/');
    if (pos == std::string::npos || pos == 0)
        return "/";
    return s.substr(0, pos);
}

// List g_browse_path via the core and push the result into the UI.
static void browse_refresh(const AppWindow *ui)
{
    static char buf[65536];
    size_t n = bw_list_dir(g_browse_path.c_str(), buf, sizeof buf);

    g_entries.clear();
    size_t i = 0;
    while (i < n) {
        char t = buf[i];              // 'd' or 'f'
        size_t start = (i + 2 <= n) ? i + 2 : n; // skip "<t> "
        size_t j = start;
        while (j < n && buf[j] != '\n')
            j++;
        BrowseEntry e;
        e.name = slint::SharedString(std::string_view(buf + start, j - start));
        e.is_dir = (t == 'd');
        g_entries.push_back(e);
        i = j + 1;
    }

    ui->set_browse_entries(std::make_shared<slint::VectorModel<BrowseEntry>>(g_entries));
    ui->set_browse_path(slint::SharedString(g_browse_path));
}

int main()
{
    // Give the window a stable Wayland app_id before it's shown. Without one,
    // some compositors (e.g. COSMIC) can't match a taskbar left-click back to the
    // window, so a minimized window won't restore on click (right-click → name
    // still works). No-op off Wayland.
    slint::set_xdg_app_id("boxwallet");

    auto ui = AppWindow::create();

    // Register the embedded monospace font so the mono gauge values render
    // consistently with no dependency on a system font being installed.
    ui->window().window_handle().register_font_from_data(mono_font, mono_font_len);

    bw_ctx *ctx = bw_init(home_dir());
    if (!ctx) {
        std::fprintf(stderr, "bw_init failed\n");
        return 1;
    }

    // Who we are, from the core — never a literal in app.slint. The version and
    // the self-updater read the same constant, so the Home page can't advertise a
    // release the running binary isn't.
    {
        char b[64];
        size_t n = bw_app_name(b, sizeof b);
        ui->set_app_name(slint::SharedString(std::string_view(b, n)));
        n = bw_app_version(b, sizeof b);
        ui->set_app_version(slint::SharedString(std::string_view(b, n)));
        n = bw_brand_color(b, sizeof b);
        ui->set_brand_color(parse_hex_color(b, n));
    }

    // Start the file browser at the user's home dir. Whoever opens it (today the
    // wallet restore-from-file stage) then lands somewhere useful without having
    // to remember to reset it first.
    {
        char hb[512];
        size_t hn = bw_home_dir(ctx, hb, sizeof hb);
        if (hn > 0)
            g_browse_path.assign(hb, hn);
    }

    // The logo array in app.slint is indexed by registry index and maintained by
    // hand — Slint needs @image-url to be a literal, so it can't be generated.
    // Check it against the registry before showing anything. A coin inserted in
    // src/registry.zig and appended there would otherwise put one coin's brand
    // over another coin's balance, which is a wallet showing you the wrong thing.
    {
        auto names = ui->get_coin_logo_names();
        const size_t n_coins = bw_coin_count();
        std::string mismatch;
        if (names->row_count() != n_coins) {
            mismatch = "coin-logo-names has " + std::to_string(names->row_count()) +
                       " entries but " + std::to_string(n_coins) + " coins are registered";
        } else {
            for (size_t i = 0; i < n_coins && mismatch.empty(); ++i) {
                char nb[64];
                size_t nn = bw_coin_name(i, nb, sizeof nb);
                std::string want(nb, nn);
                std::string got(names->row_data(i).value_or(slint::SharedString()));
                if (want != got)
                    mismatch = "logo slot " + std::to_string(i) + " is labelled \"" + got +
                               "\" but coin " + std::to_string(i) + " is \"" + want + "\"";
            }
        }
        if (!mismatch.empty()) {
            // Loud on stderr for whoever is building, and visible in the window
            // for whoever is running it. Showing no logo is the safe failure.
            std::fprintf(stderr,
                         "BoxWallet: gui/app.slint's coin logos are out of step with "
                         "src/registry.zig — %s\n",
                         mismatch.c_str());
            ui->set_logo_mismatch(slint::SharedString(mismatch));
        }
    }

    // The window the user arranged last time. Nothing stored (or nothing usable)
    // leaves the defaults in app.slint, so a first run — or a corrupt conf — still
    // opens sensibly.
    //
    // The size goes in as the component's *preferred* size (AppWindow.initial-*),
    // not through Window::set_size, and it must be set before show(). Measured:
    // set_size is honoured for a moment and then thrown away, because showing the
    // window resets it to whatever the preferred size says; and after the window
    // is up, this compositor (COSMIC/Wayland) ignores the app resizing itself
    // altogether. The preferred size is the one route that holds, everywhere.
    //
    // The size is applied even when restoring maximized, so "restore down" gives
    // back the size they chose rather than the default. Position is applied for
    // the platforms that honour it; on Wayland the compositor places windows and
    // ignores it, which is why it's set-and-forget rather than checked.
    //
    // A window manager is free to cap that preferred size — COSMIC opens a new
    // window at no more than about two thirds of the screen — so `correct_size`
    // below asks once more, later, for anything that didn't fit.
    BwWindowGeometry geom;
    const bool have_geom = bw_window_geometry(ctx, &geom) == 1;
    if (have_geom) {
        ui->set_initial_width(static_cast<float>(geom.width));
        ui->set_initial_height(static_cast<float>(geom.height));
        ui->window().set_position(slint::PhysicalPosition({geom.x, geom.y}));
        if (geom.maximized)
            ui->window().set_maximized(true);
    }

    // Build the nav list: every registered coin, sorted alphabetically by name
    // (Home is pinned separately in the UI). The registry index rides along so
    // callbacks can address the coin over the C ABI.
    std::vector<NavCoin> coins;
    size_t count = bw_coin_count();
    g_recv_addr.assign(count, std::string()); // one address cache slot per coin
    for (size_t i = 0; i < count; ++i) {
        char nm[64];
        size_t nn = bw_coin_name(i, nm, sizeof nm);
        char col[16];
        size_t cn = bw_coin_color(i, col, sizeof col);
        NavCoin nc;
        nc.name = slint::SharedString(std::string_view(nm, nn));
        nc.color = parse_hex_color(col, cn);
        nc.index = static_cast<int>(i);
        // Two-tone wordmark, pre-split here so the row can draw it directly.
        // Left empty for the coins that don't have one, which is how NavItem
        // knows to fall back to a single-colour label.
        BwWordmark wm;
        if (bw_coin_wordmark(i, &wm) == 1 && wm.split > 0 && wm.split < nn) {
            std::string_view full(nm, nn);
            nc.head = slint::SharedString(full.substr(0, wm.split));
            nc.tail = slint::SharedString(full.substr(wm.split));
            nc.head_color = parse_hex_color(wm.head_color, std::strlen(wm.head_color));
            nc.tail_color = parse_hex_color(wm.tail_color, std::strlen(wm.tail_color));
        }
        // Logo is embedded (see AppWindow.coin-logos), selected by nc.index.
        coins.push_back(nc);
    }
    std::sort(coins.begin(), coins.end(), [](const NavCoin &a, const NavCoin &b) {
        return std::string_view(a.name) < std::string_view(b.name);
    });
    ui->set_nav_coins(std::make_shared<slint::VectorModel<NavCoin>>(coins));

    std::atomic<bool> stop{false};
    slint::ComponentWeakHandle<AppWindow> weak(ui);

    // Nav → select a coin: push its metadata and start polling it. -1 is Home,
    // which has nothing to poll and no metadata to apply — but still has to be
    // reported, so the poller stops working on the coin we just left.
    ui->on_coin_selected([weak, ctx](int idx) {
        if (auto h = weak.lock()) {
            {
                std::lock_guard<std::mutex> lk(g_poll_mtx);
                g_selected.store(idx);
                g_sel_gen.fetch_add(1);
            }
            g_poll_cv.notify_one(); // poll the new coin immediately
            if (idx >= 0)
                apply_coin_metadata(&**h, ctx, idx);
        }
        if (idx < 0)
            return;
        // The Settings readouts touch the disk (a path resolve and a conf
        // parse), so they go on a worker rather than the click handler. They're
        // static per coin, which is why this fires on selection instead of
        // riding the 2s poll and re-parsing a conf that hasn't changed.
        std::thread([weak, ctx, idx]() {
            WorkerGuard wg;
            char wf[512];
            size_t wn = bw_wallet_file_path(ctx, static_cast<size_t>(idx), wf, sizeof wf);
            char wk[512];
            size_t kn = bw_wallet_keys_path(ctx, static_cast<size_t>(idx), wk, sizeof wk);

            std::string prune;
            if (bw_prune_mode(static_cast<size_t>(idx)) >= 0) {
                // -1 is "no key in the conf" — never configured, which reads
                // differently from a deliberate full node and is what
                // bw_prune_value_text spells out.
                int64_t v = -1;
                (void)bw_prune_current(ctx, static_cast<size_t>(idx), &v);
                char pb[64];
                size_t pn = bw_prune_value_text(static_cast<size_t>(idx), v, pb, sizeof pb);
                prune.assign(pb, pn);
            }

            post_to_ui([weak, idx,
                        file = std::string(wf, wn),
                        keys = std::string(wk, kn),
                        prune]() {
                auto h = weak.lock();
                if (!h)
                    return;
                // Selection moved on while we read — these belong to a coin the
                // user is no longer looking at.
                if (g_selected.load() != idx)
                    return;
                (*h)->set_wallet_file_path(slint::SharedString(file));
                (*h)->set_wallet_keys_path(slint::SharedString(keys));
                (*h)->set_prune_text(slint::SharedString(prune));
            });
        }).detach();
    });

    // Keyboard nav (Up/Down), the GUI's answer to the TUI's j/k. Slint can't
    // resolve this itself: `nav-coins` is alphabetical display order while
    // `selected` is a registry index, so the current row has to be searched for,
    // and a Slint function body has no loop. We only answer the question — the
    // UI owns the selection and applies the result. Row -1 is Home, pinned above
    // the coins; NO_MOVE means "already at that end".
    ui->on_nav_step([weak](int current, int delta) -> int {
        constexpr int NO_MOVE = -2; // must match AppWindow.no-move
        auto h = weak.lock();
        if (!h)
            return NO_MOVE;
        auto coins = (*h)->get_nav_coins();
        const int n = static_cast<int>(coins->row_count());
        if (n == 0)
            return NO_MOVE;

        int row = -1; // Home, until the current index is found among the coins
        for (int i = 0; i < n; ++i) {
            auto c = coins->row_data(i);
            if (c && c->index == current) {
                row = i;
                break;
            }
        }
        const int want = std::clamp(row + delta, -1, n - 1);
        if (want == row)
            return NO_MOVE;
        return want < 0 ? -1 : coins->row_data(want)->index;
    });

    // Wake the poller now so an action's result (running/lock state) shows fast.
    auto wake_poll = []() {
        {
            std::lock_guard<std::mutex> lk(g_poll_mtx);
            g_sel_gen.fetch_add(1);
        }
        g_poll_cv.notify_one();
    };

    // Report an action's outcome on the UI thread: clear the busy flag and show
    // the result in the status line — the success message, or the real error.
    auto finish_action = [](slint::ComponentWeakHandle<AppWindow> w, bw_ctx *c, int rc,
                            std::string success) {
        bool is_err = rc < 0;
        std::string msg = std::move(success);
        if (is_err) {
            char b[256] = {0};
            size_t n = bw_last_error(c, b, sizeof b);
            msg.assign(b, n);
            if (msg.empty())
                msg = "action failed";
        }
        post_to_ui([w, msg, is_err]() {
            if (auto h = w.lock()) {
                (*h)->set_daemon_busy(false);
                // `daemon-loading` is not cleared here: the spawn returning is
                // not the daemon being ready. It loads its block index and
                // wallet for tens of seconds more, so the poll owns that flag
                // (and the stage shown with it) until the daemon answers RPC or
                // its process is gone.
                (*h)->set_status_text(slint::SharedString(msg));
                (*h)->set_status_is_error(is_err);
            }
        });
    };

    // Settle the wallet modal after an op finishes. Success on a *create* means
    // there's a mnemonic waiting: take it (which wipes the core's copy), pick the
    // three positions to quiz on, and move to the write-it-down stage. Any other
    // success just reports itself; a wrong password puts the user back on the
    // password field rather than closing the modal out from under them.
    auto finish_wallet_op = [](slint::ComponentWeakHandle<AppWindow> w, bw_ctx *c, int rc,
                               int op, int coin) {
        std::string seed;
        int p1 = 1, p2 = 2, p3 = 3;
        if (rc == 0 && op == 0) {
            char sb[256] = {0};
            size_t sn = bw_ext_wallet_seed_take(c, sb, sizeof sb);
            if (sn > 0 && sn <= sizeof sb)
                seed.assign(sb, sn);
            // Quiz three distinct positions spread across the phrase, so the
            // check can't be passed by copying only the first few words. Both
            // the count and the draw come from the core: the positions are
            // drawn from the OS CSPRNG, where this used to seed a std::mt19937
            // from the clock.
            size_t words = bw_seed_word_count(seed.data(), seed.size());
            uint32_t pos[3] = {1, 2, 3};
            if (bw_seed_verify_positions(words, pos, 3) == 3) {
                p1 = static_cast<int>(pos[0]);
                p2 = static_cast<int>(pos[1]);
                p3 = static_cast<int>(pos[2]);
            }
        }
        std::string err = (rc < 0) ? last_error_text(c, rc) : std::string();
        std::string code = (rc < 0) ? last_error_code(c) : std::string();
        bool wrong_pw = (code == "WrongPassword");

        post_to_ui([w, rc, op, coin, seed, p1, p2, p3, err, wrong_pw]() {
            auto h = w.lock();
            if (!h)
                return;
            // The user navigated to another coin mid-op: don't reopen a modal
            // over a coin this result has nothing to do with.
            if (g_selected.load() != coin) {
                (*h)->set_wallet_stage(0);
                return;
            }
            if (rc < 0) {
                (*h)->set_wallet_result_error(true);
                (*h)->set_wallet_result(slint::SharedString(err));
                // A mistyped password is a retry, not a dead end.
                (*h)->set_wallet_stage(wrong_pw ? (op == 0 ? 3 : (op == 1 ? 4 : 2)) : 10);
                if (wrong_pw) {
                    (*h)->set_status_text(slint::SharedString(err));
                    (*h)->set_status_is_error(true);
                }
                return;
            }
            if (op == 0 && !seed.empty()) {
                (*h)->set_verify_pos_1(p1);
                (*h)->set_verify_pos_2(p2);
                (*h)->set_verify_pos_3(p3);
                (*h)->set_wallet_verify_step(0);
                (*h)->set_wallet_verify_bad(false);
                (*h)->set_wallet_seed_words(slint::SharedString(seed));
                (*h)->set_wallet_stage(7);
                return;
            }
            (*h)->set_wallet_result_error(false);
            (*h)->set_wallet_result(slint::SharedString(
                op == 1 ? "Wallet restored. It will scan the chain for your funds."
                : op == 2 ? "Wallet imported and unlocked."
                          : "Wallet unlocked."));
            (*h)->set_wallet_stage(10);
        });
    };

    // Set an "in progress" status on the UI thread (called from the callback).
    auto begin_status = [](slint::ComponentWeakHandle<AppWindow> w, const char *msg) {
        if (auto h = w.lock()) {
            (*h)->set_status_text(slint::SharedString(msg));
            (*h)->set_status_is_error(false);
        }
    };

    // Start / Stop the daemon on a worker thread (they spawn / block on RPC).
    // The coin index is captured on the UI thread so a mid-action nav switch
    // can't retarget it. `daemon-busy` was set true by the button's click.
    //
    // The launch itself, shared by the plain path and by both answers to the
    // sync-accelerator prompt. Call it from the UI thread.
    auto launch_daemon = [weak, ctx, wake_poll, finish_action, begin_status](int coin) {
        begin_status(weak, "Starting daemon…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = bw_start_daemon(ctx, static_cast<size_t>(coin));
            finish_action(weak, ctx, rc, "Daemon running");
            wake_poll();
        }).detach();
    };

    // The sync-accelerator offer, then the start. Shared by the plain Start path
    // and by the prune prompt's continuation, so the two can't drift on ordering:
    // the prune choice is written BEFORE this, because both touch the data dir
    // and that is the order the TUI uses.
    auto offer_accel_or_launch = [weak, ctx, launch_daemon](int coin) {
        // Before the first start on an empty chain, some coins offer a large
        // opt-in download that skips most of the sync (Divi's blockchain
        // snapshot). Ask first — this is only disk checks, so it's cheap enough
        // for the UI thread, and it answers false once any chain data exists, so
        // a snapshot can never land on top of an existing blockchain.
        if (bw_sync_accel_offered(ctx, static_cast<size_t>(coin)) != 0) {
            char name[64] = {0};
            char detail[256] = {0};
            char trust[256] = {0};
            size_t nn = bw_sync_accel_name(static_cast<size_t>(coin), name, sizeof name);
            size_t dn = bw_sync_accel_detail(static_cast<size_t>(coin), detail, sizeof detail);
            // Empty for an accelerator with nothing to caution about, which is
            // what hides the block rather than showing an empty rule.
            size_t tn = bw_sync_accel_trust_note(static_cast<size_t>(coin), trust, sizeof trust);
            uint64_t partial = bw_sync_accel_resume_bytes(ctx, static_cast<size_t>(coin));
            std::string resume;
            if (partial > 0)
                resume = humanize_bytes(partial) +
                         " already downloaded — this will continue from there.";
            if (auto h = weak.lock()) {
                (*h)->set_accel_name(slint::SharedString(std::string_view(name, nn)));
                (*h)->set_accel_detail(slint::SharedString(std::string_view(detail, dn)));
                (*h)->set_accel_trust(slint::SharedString(std::string_view(trust, tn)));
                (*h)->set_accel_resume(slint::SharedString(resume));
                // The click set daemon-busy to latch the Start button; the prompt
                // is now the thing in flight, so release it or the buttons stay
                // frozen behind the dialog.
                (*h)->set_daemon_busy(false);
                (*h)->set_accel_open(true);
            }
            return;
        }
        launch_daemon(coin);
    };

    ui->on_start_daemon([weak, ctx, offer_accel_or_launch]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        // How should this chain be stored? Asked once, before a prune-capable
        // daemon ever runs, because the answer can't be changed afterwards
        // without downloading the chain again.
        //
        // Asked HERE, fresh, and acted on immediately — the answer is never
        // stored. It is an instant-in-time predicate: an unpruned node has no
        // prune key by definition, so the coins pair "no key" with "no chain data
        // yet", and the honest answer flips to false the moment a daemon starts
        // writing blocks. A cached true would offer to discard them.
        if (bw_prune_should_offer(ctx, static_cast<size_t>(coin)) != 0) {
            char prompt[512] = {0};
            size_t pn = bw_prune_prompt(static_cast<size_t>(coin), prompt, sizeof prompt);
            // The rows are the coin's own — Monero's are on/off rather than
            // sizes, so a hard-coded GB list would offer it a value it can't
            // honour.
            std::vector<slint::SharedString> rows;
            size_t nrows = bw_prune_preset_count(static_cast<size_t>(coin));
            for (size_t r = 0; r < nrows; ++r) {
                char lb[64] = {0};
                size_t ln = bw_prune_preset_label(static_cast<size_t>(coin), r, lb, sizeof lb);
                rows.push_back(slint::SharedString(std::string_view(lb, ln)));
            }
            if (rows.empty()) { // no menu to show — don't block the start on it
                offer_accel_or_launch(coin);
                return;
            }
            g_prune_coin = coin;
            if (auto h = weak.lock()) {
                (*h)->set_prune_prompt(slint::SharedString(std::string_view(prompt, pn)));
                (*h)->set_prune_rows(std::make_shared<slint::VectorModel<slint::SharedString>>(rows));
                // Row 0 is the coin's least destructive choice, so the default
                // selection can't discard a chain on a stray Enter.
                (*h)->set_prune_sel(0);
                (*h)->set_daemon_busy(false);
                (*h)->set_prune_open(true);
            }
            return;
        }
        offer_accel_or_launch(coin);
    });

    // ---- in-daemon wallet menu ----
    // The rows come from bw_wallet_menu; this side renders them and routes the
    // pick. It never decides what a wallet state permits.
    ui->on_wallet_menu_open([weak, ctx]() {
        auto h = weak.lock();
        if (!h)
            return;
        int coin = g_selected.load();
        if (coin < 0)
            return;
        uint8_t acts[8];
        size_t n = bw_wallet_menu(static_cast<size_t>(coin), (*h)->get_wallet_sec(),
                                  acts, sizeof acts);
        if (n == 0)
            return; // nothing this state permits — don't open an empty dialog
        g_wa_coin = coin;
        g_wa_menu.assign(acts, acts + n);

        std::vector<slint::SharedString> rows;
        for (size_t i = 0; i < n; ++i) {
            char lb[64] = {0};
            size_t ln = bw_wallet_action_label(acts[i], lb, sizeof lb);
            rows.push_back(slint::SharedString(std::string_view(lb, ln)));
        }
        (*h)->set_wa_rows(std::make_shared<slint::VectorModel<slint::SharedString>>(rows));
        (*h)->set_wa_pw_mismatch(false);
        (*h)->set_wa_result(slint::SharedString(""));
        (*h)->set_picked_file(slint::SharedString(""));
        (*h)->set_wa_stage(1);
    });

    // A row was picked: ask the core what it needs and raise that prompt.
    ui->on_wallet_menu_pick([weak, ctx, wake_poll](int row) {
        auto h = weak.lock();
        if (!h)
            return;
        if (row < 0 || static_cast<size_t>(row) >= g_wa_menu.size())
            return;
        const uint8_t action = g_wa_menu[static_cast<size_t>(row)];
        g_wa_action = action;

        char lb[64] = {0};
        size_t ln = bw_wallet_action_label(action, lb, sizeof lb);
        (*h)->set_wa_title(slint::SharedString(std::string_view(lb, ln)));
        (*h)->set_wa_confirm_pw(bw_wallet_action_sets_new_password(action) != 0);
        (*h)->set_wa_pw_mismatch(false);

        if (bw_wallet_action_needs_password(action)) {
            (*h)->set_wa_stage(2);
            return;
        }
        if (bw_wallet_action_needs_path(action)) {
            // The offline restore swaps the wallet file itself, so it is the one
            // that can lose funds outright if the wrong file is chosen.
            (*h)->set_wa_caution(
                action == BW_WA_RESTORE_FILE_OFFLINE
                    ? slint::SharedString("This replaces the current wallet file. Stop the daemon first, and be sure this is the wallet you want.")
                    : slint::SharedString(""));
            (*h)->set_wa_stage(3);
            return;
        }
        // Neither: Lock and Backup run straight away.
        (*h)->set_wa_stage(4);
        int coin = g_wa_coin;
        std::thread([weak, ctx, coin, action, wake_poll]() {
            WorkerGuard wg;
            std::string msg;
            bool err = false;
            if (action == BW_WA_LOCK) {
                err = bw_wallet_lock(ctx, static_cast<size_t>(coin)) < 0;
                msg = err ? last_error_text(ctx, -1) : "Wallet locked.";
            } else if (action == BW_WA_BACKUP) {
                char path[512] = {0};
                size_t pn = bw_wallet_backup(ctx, static_cast<size_t>(coin), path, sizeof path);
                err = (pn == 0);
                // Say where it went AND what it is: a key dump is the wallet.
                msg = err ? last_error_text(ctx, -1)
                          : "Backed up to " + std::string(path, pn) +
                                "\n\nThis file contains your private keys. Anyone with it can spend your coins.";
            } else {
                err = true;
                msg = "That action isn't wired up.";
            }
            post_to_ui([weak, msg, err]() {
                if (auto hh = weak.lock()) {
                    (*hh)->set_wa_result(slint::SharedString(msg));
                    (*hh)->set_wa_result_error(err);
                    (*hh)->set_wa_stage(5);
                }
            });
            wake_poll();
        }).detach();
    });

    // A passphrase was entered for the chosen action.
    ui->on_wallet_action_password([weak, ctx, wake_poll](slint::SharedString pass) {
        auto h = weak.lock();
        if (!h)
            return;
        int coin = g_wa_coin;
        const uint8_t action = g_wa_action;
        if (coin < 0)
            return;
        auto secret = to_secret_bytes(pass);
        (*h)->set_wa_stage(4);
        std::thread([weak, ctx, coin, action, wake_poll, secret = std::move(secret)]() mutable {
            WorkerGuard wg;
            int rc = 0;
            std::string ok_msg;
            switch (action) {
            case BW_WA_ENCRYPT:
                rc = bw_wallet_encrypt(ctx, static_cast<size_t>(coin), secret.data(), secret.size());
                // Most daemons stop after encrypting — normal, not a failure,
                // and the user needs to know why their node just went away.
                ok_msg = "Wallet encrypted. The daemon usually stops afterwards — start it again when you're ready.";
                break;
            case BW_WA_UNLOCK:
                rc = bw_wallet_unlock(ctx, static_cast<size_t>(coin), secret.data(), secret.size(), 0);
                ok_msg = "Wallet unlocked.";
                break;
            case BW_WA_STAKE:
                rc = bw_wallet_unlock(ctx, static_cast<size_t>(coin), secret.data(), secret.size(), 1);
                ok_msg = "Wallet unlocked for staking.";
                break;
            default:
                rc = -1;
                break;
            }
            wipe_secret(secret);
            std::string msg = (rc < 0) ? last_error_text(ctx, rc) : ok_msg;
            bool err = rc < 0;
            post_to_ui([weak, msg, err]() {
                if (auto hh = weak.lock()) {
                    (*hh)->set_wa_result(slint::SharedString(msg));
                    (*hh)->set_wa_result_error(err);
                    (*hh)->set_wa_stage(5);
                }
            });
            wake_poll();
        }).detach();
    });

    // A file was chosen for one of the two restores.
    ui->on_wallet_action_path([weak, ctx, wake_poll](slint::SharedString path) {
        auto h = weak.lock();
        if (!h)
            return;
        int coin = g_wa_coin;
        const uint8_t action = g_wa_action;
        if (coin < 0)
            return;
        std::string src(path);
        (*h)->set_wa_stage(4);
        std::thread([weak, ctx, coin, action, src, wake_poll]() {
            WorkerGuard wg;
            int rc;
            if (action == BW_WA_RESTORE_FILE_OFFLINE)
                rc = bw_wallet_restore_file_offline(ctx, static_cast<size_t>(coin), src.c_str());
            else
                rc = bw_wallet_import_file(ctx, static_cast<size_t>(coin), src.c_str());
            std::string msg = (rc < 0)
                ? last_error_text(ctx, rc)
                : std::string("Wallet restored. Rescanning may take a while before "
                              "the balance is right.");
            post_to_ui([weak, msg, rc]() {
                if (auto hh = weak.lock()) {
                    (*hh)->set_wa_result(slint::SharedString(msg));
                    (*hh)->set_wa_result_error(rc < 0);
                    (*hh)->set_wa_stage(5);
                }
            });
            wake_poll();
        }).detach();
    });

    ui->on_wallet_action_cancel([weak]() {
        g_wa_coin = -1;
        g_wa_menu.clear();
        if (auto h = weak.lock())
            (*h)->set_picked_file(slint::SharedString(""));
    });

    // The prune choice was made: write it, then carry on with the start.
    ui->on_prune_choose([weak, ctx, offer_accel_or_launch](int row) {
        // The coin the dialog was opened FOR, not whatever is selected now — the
        // user can move the selection while a modal is up.
        int coin = g_prune_coin;
        if (coin < 0)
            return;
        g_prune_coin = -1;
        int64_t value = bw_prune_preset_value(static_cast<size_t>(coin), static_cast<size_t>(row));
        if (value >= 0 && bw_prune_apply(ctx, static_cast<size_t>(coin), value) < 0) {
            // Not a reason to abort: they asked for a daemon, and an unwritten
            // preference is the smaller problem. Say so and start unpruned —
            // same call the TUI makes.
            std::string why = last_error_text(ctx, -1);
            if (auto h = weak.lock()) {
                (*h)->set_status_text(slint::SharedString(
                    "Couldn't save the pruning choice (" + why + ") — starting unpruned."));
                (*h)->set_status_is_error(true);
            }
        }
        offer_accel_or_launch(coin);
    });

    // Declined. The question was asked *before* starting, so declining it
    // declines the start — this must not fall through to launch.
    ui->on_prune_cancel([weak]() {
        g_prune_coin = -1;
        if (auto h = weak.lock())
            (*h)->set_daemon_busy(false);
    });

    // Declined the accelerator: start the daemon and let it sync from the network.
    ui->on_accel_decline([weak, launch_daemon]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        if (auto h = weak.lock())
            (*h)->set_daemon_busy(true);
        launch_daemon(coin);
    });

    // Fetch and apply the accelerator (GBs, then an unpack), then start the
    // daemon. It reports through the install progress slots, so it takes the same
    // g_installing claim an install would — they share those slots, and the
    // install root the download streams into.
    //
    // Shared by the prompt's Accept and by Resume after a pause: resuming *is*
    // the same transfer (`bw_sync_accel_run` continues from the bytes already on
    // disk), so it must not be a second, subtly different path. Call from the UI
    // thread.
    auto run_accel = [weak, ctx, launch_daemon, begin_status](int coin) {
        int none = -1;
        if (!g_installing.compare_exchange_strong(none, coin)) {
            begin_status(weak, "Another install is already running");
            if (auto h = weak.lock())
                (*h)->set_status_is_error(true);
            return;
        }
        begin_status(weak, "Downloading…");
        if (auto h = weak.lock()) {
            (*h)->set_install_busy(true);
            // Tells the pane this bar belongs to the accelerator, so the
            // Pause/Resume button appears under it (an ordinary install has
            // nothing to pause).
            (*h)->set_accel_busy(true);
            (*h)->set_accel_paused(false);
            (*h)->set_accel_pausing(false);
        }
        std::thread([weak, ctx, coin, launch_daemon]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = run_with_progress(weak, ctx, coin, [ctx, coin]() {
                return bw_sync_accel_run(ctx, static_cast<size_t>(coin));
            });
            std::string msg;
            if (rc < 0) {
                char b[256] = {0};
                size_t n = bw_last_error(ctx, b, sizeof b);
                msg.assign(b, n);
                if (msg.empty())
                    msg = "download failed";
            }
            uint64_t have = bw_sync_accel_resume_bytes(ctx, static_cast<size_t>(coin));
            g_installing.store(-1);
            post_to_ui([weak, coin, rc, msg, have, launch_daemon]() {
                auto h = weak.lock();
                if (!h)
                    return;
                (*h)->set_install_busy(false);
                (*h)->set_install_phase(0);
                (*h)->set_accel_busy(false);
                (*h)->set_accel_pausing(false);
                if (rc == BW_SYNC_ACCEL_PAUSED) {
                    // Not an error: the bytes are on disk. Hold the progress block
                    // on screen with the button flipped to Resume, so picking it
                    // back up is one click on the control that stopped it. The
                    // frozen bar and byte count are the pump's last values, left
                    // untouched on purpose — they're exactly where it stopped.
                    (*h)->set_accel_paused(true);
                    (*h)->set_status_text(slint::SharedString(
                        "Paused — " + humanize_bytes(have) + " downloaded, resumes from here"));
                    (*h)->set_status_is_error(false);
                    (*h)->set_daemon_busy(false);
                    return;
                }
                if (rc < 0) {
                    // A failed resumable download keeps its partial, so the next
                    // Start offers to continue rather than begin again.
                    (*h)->set_status_text(slint::SharedString(msg));
                    (*h)->set_status_is_error(true);
                    (*h)->set_daemon_busy(false);
                    return;
                }
                (*h)->set_daemon_busy(true);
                launch_daemon(coin);
            });
        }).detach();
    };

    // Accepted at the prompt: start the transfer from nothing (or from a partial
    // an earlier run left behind).
    ui->on_accel_accept([run_accel]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        run_accel(coin);
    });

    // Resume after a pause: the same transfer, continuing from the bytes on disk.
    ui->on_accel_continue([run_accel]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        run_accel(coin);
    });

    // Pause: raise the flag and return. The worker notices between chunks and
    // unwinds on its own, which is what keeps the partial flushed and consistent.
    // The button flips to Resume when the worker reports back, not here — until
    // it has actually stopped, the transfer is still running.
    ui->on_accel_pause([weak, ctx]() {
        if (auto h = weak.lock())
            (*h)->set_accel_pausing(true);
        bw_sync_accel_pause(ctx);
    });
    ui->on_stop_daemon([weak, ctx, wake_poll, finish_action, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Stopping daemon…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = bw_stop_daemon(ctx, static_cast<size_t>(coin));
            finish_action(weak, ctx, rc, "Daemon stopped");
            wake_poll();
        }).detach();
    });
    // Install the selected coin. Two threads: one blocks in bw_install streaming
    // the bundle to disk, the other pumps bw_install_progress into the UI ~8x a
    // second so the bar moves smoothly. The main poller can't do this job — it's
    // on a 2s RPC cadence, and there's no daemon to talk to yet anyway.
    ui->on_install_coin([weak, ctx, wake_poll, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        // Refuse a second concurrent install: they share the one install root and
        // the single set of progress slots in the Zig context.
        int none = -1;
        if (!g_installing.compare_exchange_strong(none, coin)) {
            begin_status(weak, "Another install is already running");
            if (auto h = weak.lock()) {
                (*h)->set_install_busy(false);
                (*h)->set_status_is_error(true);
            }
            return;
        }
        begin_status(weak, "Installing…");
        std::thread([weak, ctx, coin, wake_poll]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = install_with_progress(weak, ctx, coin);
            finish_install(weak, ctx, coin, rc, "Installed", "install failed");
            wake_poll();
        }).detach();
    });

    // Update: same download+install, but over a working install, so the daemon has
    // to come down first (its binary is being replaced) and go back up afterwards
    // if it was running. Mirrors the TUI's stop → reinstall → restart sequence.
    ui->on_update_coin([weak, ctx, wake_poll, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        int none = -1;
        if (!g_installing.compare_exchange_strong(none, coin)) {
            begin_status(weak, "Another install is already running");
            if (auto h = weak.lock()) {
                (*h)->set_install_busy(false);
                (*h)->set_status_is_error(true);
            }
            return;
        }
        // Whether to bring it back up is decided from the UI thread before any of
        // this starts, so it reflects what the user could actually see.
        bool was_running = false;
        if (auto h = weak.lock())
            was_running = (*h)->get_running();

        begin_status(weak, was_running ? "Stopping daemon…" : "Updating…");
        std::thread([weak, ctx, coin, was_running, wake_poll]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            // Stop first: on Windows the running binary can't be replaced at all,
            // and everywhere else a live daemon would keep running the old code.
            if (was_running) {
                if (bw_stop_daemon(ctx, static_cast<size_t>(coin)) < 0) {
                    char b[256] = {0};
                    size_t n = bw_last_error(ctx, b, sizeof b);
                    std::string msg(b, n);
                    if (msg.empty())
                        msg = "could not stop the daemon — update aborted";
                    g_installing.store(-1);
                    post_to_ui([weak, coin, msg]() {
                        auto h = weak.lock();
                        if (!h || g_selected.load() != coin)
                            return;
                        (*h)->set_install_busy(false);
                        (*h)->set_status_text(slint::SharedString(msg));
                        (*h)->set_status_is_error(true);
                    });
                    return; // leave the old install intact rather than half-replacing it
                }
            }

            int rc = install_with_progress(weak, ctx, coin);
            bool ok = rc >= 0;
            finish_install(weak, ctx, coin, rc,
                           ok && was_running ? "Updated — restarting daemon…" : "Updated",
                           "update failed");

            // Put it back the way we found it. A restart failure is reported but
            // doesn't undo the update, which did succeed.
            if (ok && was_running) {
                // Mark the daemon busy for the restart: finish_install has already
                // released install-busy, so without this the Start button is live
                // and a click here would race us into a second launch.
                post_to_ui([weak, coin]() {
                    auto h = weak.lock();
                    if (!h || g_selected.load() != coin)
                        return;
                    (*h)->set_daemon_busy(true);
                    (*h)->set_daemon_loading(true);
                });
                int src = bw_start_daemon(ctx, static_cast<size_t>(coin));
                std::string msg = "Updated";
                bool is_err = src < 0;
                if (is_err) {
                    char b[256] = {0};
                    size_t n = bw_last_error(ctx, b, sizeof b);
                    msg.assign(b, n);
                    if (msg.empty())
                        msg = "updated, but the daemon did not restart";
                }
                post_to_ui([weak, coin, msg, is_err]() {
                    auto h = weak.lock();
                    if (!h)
                        return;
                    // Always release the busy flag, even if the user navigated away —
                    // it's global to the pane, so leaving it set would freeze the
                    // buttons on whatever coin is on screen. `daemon-loading` is
                    // left to the poll: the restarted daemon is still coming up.
                    (*h)->set_daemon_busy(false);
                    if (g_selected.load() != coin)
                        return;
                    (*h)->set_status_text(slint::SharedString(msg));
                    (*h)->set_status_is_error(is_err);
                });
            }
            wake_poll();
        }).detach();
    });

    ui->on_lock_wallet([weak, ctx, wake_poll, finish_action, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Locking wallet…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = bw_wallet_lock(ctx, static_cast<size_t>(coin));
            finish_action(weak, ctx, rc, "Wallet locked");
            wake_poll();
        }).detach();
    });
    // Unlock: the passphrase is a secret. Copy it to a local byte buffer, hand it
    // to the core (which copies into a bounded buffer and wipes), then wipe our
    // copy. The Slint field is cleared by the modal the instant it's submitted.
    ui->on_unlock_wallet([weak, ctx, wake_poll, finish_action, begin_status](slint::SharedString pass) {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Unlocking wallet…");
        std::string_view sv(pass);
        std::vector<uint8_t> secret(sv.begin(), sv.end());
        std::thread([weak, ctx, coin, wake_poll, finish_action, secret = std::move(secret)]() mutable {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            int rc = bw_wallet_unlock(ctx, static_cast<size_t>(coin),
                                      secret.data(), secret.size(), 0);
            volatile uint8_t *p = secret.data();
            for (size_t i = 0; i < secret.size(); ++i)
                p[i] = 0; // wipe our copy
            finish_action(weak, ctx, rc, "Wallet unlocked");
            wake_poll();
        }).detach();
    });

    // ---- managed wallet (external-wallet coins) ----------------------------
    // Every op blocks (spawns a process, drives RPC, sometimes shells out to a
    // wallet CLI), so it runs on a worker. The modal sits on its "working" stage
    // meanwhile; the outcome lands back on the UI thread.
    ui->on_wallet_setup([weak, ctx, wake_poll, finish_wallet_op](int op, slint::SharedString pw,
                                               slint::SharedString seed,
                                               slint::SharedString file) {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        // One wallet op at a time — the core serialises them anyway, but this
        // stops the UI firing a second while the first is in flight.
        bool expected = false;
        if (!g_wallet_busy.compare_exchange_strong(expected, true)) {
            return;
        }
        std::vector<uint8_t> pw_bytes = to_secret_bytes(pw);
        std::vector<uint8_t> seed_bytes = to_secret_bytes(seed);
        std::string path{std::string_view(file)};

        std::thread([weak, ctx, coin, op, wake_poll, finish_wallet_op,
                     pw_bytes = std::move(pw_bytes),
                     seed_bytes = std::move(seed_bytes), path]() mutable {
            WorkerGuard wg; // keeps bw_ctx alive until this worker is done
            size_t c = static_cast<size_t>(coin);
            int rc = -1;
            switch (op) {
            case 0: rc = bw_ext_wallet_create(ctx, c, pw_bytes.data(), pw_bytes.size()); break;
            case 1: rc = bw_ext_wallet_restore_seed(ctx, c, pw_bytes.data(), pw_bytes.size(),
                                                    seed_bytes.data(), seed_bytes.size()); break;
            case 2: rc = bw_ext_wallet_restore_file(ctx, c, pw_bytes.data(), pw_bytes.size(),
                                                    path.c_str()); break;
            default: rc = bw_ext_wallet_open(ctx, c, pw_bytes.data(), pw_bytes.size()); break;
            }
            wipe_secret(pw_bytes);
            wipe_secret(seed_bytes);
            finish_wallet_op(weak, ctx, rc, op, coin);
            wake_poll();
            g_wallet_busy.store(false);
        }).detach();
    });

    // Replace: destructive, and already behind a typed REPLACE confirmation in
    // the modal. Deletes the wallet's files so a different one can take its
    // place; the daemon keeps running (its chain sync isn't the wallet's to
    // throw away).
    ui->on_wallet_replace([weak, ctx, wake_poll]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        bool expected = false;
        if (!g_wallet_busy.compare_exchange_strong(expected, true))
            return;
        std::thread([weak, ctx, coin, wake_poll]() {
            WorkerGuard wg;
            int rc = bw_ext_wallet_remove(ctx, static_cast<size_t>(coin));
            post_to_ui([weak, rc, msg = last_error_text(ctx, rc)]() {
                if (auto h = weak.lock()) {
                    (*h)->set_wallet_result_error(rc < 0);
                    (*h)->set_wallet_result(slint::SharedString(
                        rc < 0 ? msg : "Wallet removed. Set up a new one when you're ready."));
                    (*h)->set_wallet_stage(10);
                }
            });
            wake_poll();
            g_wallet_busy.store(false);
        }).detach();
    });

    ui->on_wallet_lock([weak, ctx, wake_poll]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        std::thread([weak, ctx, coin, wake_poll]() {
            WorkerGuard wg;
            (void)bw_ext_wallet_lock(ctx, static_cast<size_t>(coin));
            wake_poll();
        }).detach();
    });

    // Backup check. The seed is read back out of the one property holding it
    // rather than kept in a second C++ copy — see the secrets contract in
    // include/boxwallet.h.
    ui->on_verify_word([weak](int pos, slint::SharedString answer) -> bool {
        auto h = weak.lock();
        if (!h)
            return false;
        // Both the words and the answer are read in place by the core; nothing
        // is copied, so the property remains the only place the seed lives.
        std::string_view words((*h)->get_wallet_seed_words());
        std::string_view a(answer);
        return bw_seed_word_matches(words.data(), words.size(),
                                    static_cast<size_t>(pos < 1 ? 0 : pos),
                                    a.data(), a.size()) != 0;
    });

    ui->on_seed_discard([ctx]() { bw_ext_wallet_seed_discard(ctx); });

    // A fresh receive address, only ever on an explicit ask — the poller never
    // decides this for itself.
    ui->on_new_address([wake_poll]() {
        g_want_new_addr.store(true);
        wake_poll();
    });

    // Send. The modal has already shown the user the full, untruncated address
    // and had them confirm it — that is the one typo safety net a machine can't
    // provide, so it is not optional.
    ui->on_send_funds([weak, ctx, wake_poll](slint::SharedString address, slint::SharedString amount) {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        std::string addr{std::string_view(address)};
        double amt = 0;
        try {
            amt = std::stod(std::string(std::string_view(amount)));
        } catch (...) {
            if (auto h = weak.lock()) {
                (*h)->set_send_result_error(true);
                (*h)->set_send_result(slint::SharedString("That isn't an amount."));
            }
            return;
        }
        if (auto h = weak.lock())
            (*h)->set_send_busy(true);

        std::thread([weak, ctx, coin, addr, amt, wake_poll]() {
            WorkerGuard wg;
            char out[256] = {0};
            int rc = bw_wallet_send(ctx, static_cast<size_t>(coin), addr.c_str(), amt,
                                    out, sizeof out);
            std::string reply(out);
            std::string err = (rc < 0) ? last_error_text(ctx, rc) : std::string();
            post_to_ui([weak, rc, reply, err]() {
                if (auto h = weak.lock()) {
                    (*h)->set_send_busy(false);
                    (*h)->set_send_result_error(rc != 0);
                    // A daemon rejection (rc == 1) carries its own reason
                    // verbatim — it's an answer the user needs to read, not a
                    // generic failure.
                    (*h)->set_send_result(slint::SharedString(
                        rc == 0   ? "Sent. Transaction " + reply
                        : rc == 1 ? reply
                                  : err));
                }
            });
            wake_poll();
        }).detach();
    });

    // ---- mining ------------------------------------------------------------
    // Start/stop drive the *daemon's* miner. The payout address is read off the
    // UI thread's cache before the worker starts, so the poll thread rewriting
    // that cache can't retarget a start already in flight.
    ui->on_mining_start([weak, ctx, wake_poll](int threads) {
        int coin = g_selected.load();
        if (coin < 0 || static_cast<size_t>(coin) >= g_recv_addr.size())
            return;
        std::string addr = g_recv_addr[coin];
        if (addr.empty()) {
            if (auto h = weak.lock()) {
                (*h)->set_mining_error(slint::SharedString(
                    "No payout address yet — unlock your wallet first."));
            }
            return;
        }
        if (auto h = weak.lock()) {
            (*h)->set_mining_busy(true);
            (*h)->set_mining_error(slint::SharedString(""));
        }
        std::thread([weak, ctx, coin, addr, threads, wake_poll]() {
            WorkerGuard wg;
            int rc = bw_mining_start(ctx, static_cast<size_t>(coin), addr.c_str(),
                                     static_cast<uint32_t>(threads));
            finish_mining(weak, ctx, rc);
            wake_poll();
        }).detach();
    });

    ui->on_mining_stop([weak, ctx, wake_poll]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        if (auto h = weak.lock()) {
            (*h)->set_mining_busy(true);
            (*h)->set_mining_error(slint::SharedString(""));
        }
        std::thread([weak, ctx, coin, wake_poll]() {
            WorkerGuard wg;
            int rc = bw_mining_stop(ctx, static_cast<size_t>(coin));
            finish_mining(weak, ctx, rc);
            wake_poll();
        }).detach();
    });

    // File-browser callbacks. Start at HOME; navigate into folders; picking a
    // file records its path and closes the overlay.
    ui->on_browse_home([weak, ctx]() {
        if (auto h = weak.lock()) {
            char hb[4096];
            size_t hn = bw_home_dir(ctx, hb, sizeof hb);
            g_browse_path.assign(hb, hn);
            browse_refresh(&**h);
        }
    });
    ui->on_browse_up([weak]() {
        if (auto h = weak.lock()) {
            g_browse_path = path_parent(g_browse_path);
            browse_refresh(&**h);
        }
    });
    ui->on_browse_enter([weak](int idx) {
        auto h = weak.lock();
        if (!h || idx < 0 || static_cast<size_t>(idx) >= g_entries.size())
            return;
        const BrowseEntry &e = g_entries[idx];
        std::string name(std::string_view(e.name));
        if (e.is_dir) {
            g_browse_path = path_join(g_browse_path, name);
            browse_refresh(&**h);
        } else {
            (*h)->set_picked_file(slint::SharedString(path_join(g_browse_path, name)));
            (*h)->set_browse_open(false);
        }
    });

    // Poll the *selected* coin's daemon every ~2s off the UI thread. Home (-1)
    // polls nothing.
    std::thread poller([ctx, weak, &stop]() {
        while (!stop.load()) {
            int sel = g_selected.load();
            uint64_t gen = g_sel_gen.load();
            if (sel < 0) {
                std::unique_lock<std::mutex> lk(g_poll_mtx);
                g_poll_cv.wait_for(lk, std::chrono::seconds(2), [&] {
                    return stop.load() || g_sel_gen.load() != gen;
                });
                continue;
            }
            size_t coin = static_cast<size_t>(sel);

            BwDaemonInfo di;
            BwBlockchainState bs;
            std::memset(&di, 0, sizeof di);
            std::memset(&bs, 0, sizeof bs);

            int di_rc = bw_daemon_info(ctx, coin, &di);
            int bs_rc = bw_blockchain_state(ctx, coin, &bs);
            // Whether we got fresh figures this tick.
            const bool rpc_ok = (di_rc == 0 && bs_rc == 0);

            // A failed read is NOT the same as a stopped daemon. One under load
            // accepts the connection instantly while stalling its RPC reply for
            // seconds — Nerva does this behind its blockchain lock — so binding
            // "running" straight to the read made the whole UI flip to stopped
            // and back every time the node got busy. A cheap connect probe tells
            // busy apart from down, which is the rule the TUI already follows.
            //
            // Only probed when the read failed, so a healthy tick costs nothing.
            const bool busy = !rpc_ok && bw_daemon_reachable(ctx, coin) == 1;
            const bool daemon_up = rpc_ok || busy;

            // Wallet lock state — only meaningful once the daemon actually
            // answers. While busy it would fail too, so keep the last one rather
            // than reporting "unknown" and greying the padlock mid-sync.
            int wallet_sec = rpc_ok ? bw_wallet_security(ctx, coin) : BW_WSEC_UNKNOWN;

            // The reads failing doesn't mean "not running": a bitcoin-derived
            // daemon can't serve them for the whole of its start-up (block
            // index, then wallet — tens of seconds to minutes) while it answers
            // -28 with the stage it's at. Ask for that stage, so the UI reports
            // "Loading block index…" / "Rewinding…" / "Verifying…" rather than
            // claiming the daemon it just started isn't running.
            std::string stage;
            if (!daemon_up) {
                char sb[128] = {0};
                size_t sn = bw_daemon_stage(ctx, coin, sb, sizeof sb);
                stage.assign(sb, sn);
            }

            // The managed wallet lives in a second process we spawn alongside the
            // daemon and tear down with it — mirroring the TUI's per-tick block.
            // The teardown matters as much as the start: a wallet service left
            // running would keep holding the user's wallet files.
            int ew_flags = bw_coin_ext_wallet(coin);
            int wallet_state = BW_WALLET_NONE;
            int decimals = static_cast<int>(bw_coin_balance_decimals(coin));
            std::string wallet_svc_err;
            if (ew_flags != 0) {
                if (daemon_up) {
                    // A failure here is why a later unlock would report the
                    // service "still starting" — surface the real reason now
                    // rather than letting the user meet it at the password box.
                    if (bw_ext_wallet_service_ensure(ctx, coin) == -1)
                        wallet_svc_err = last_error_text(ctx, -1);
                } else {
                    bw_ext_wallet_service_stop(ctx, coin);
                }
                wallet_state = bw_ext_wallet_state(ctx, coin);
            }

            // What this coin has to show at all — about the coin, not about the
            // wallet's current state. Drives tab visibility, so a coin without a
            // capability shows no tab rather than an empty one.
            const bool has_balance_cap = bw_coin_supports_balance(coin) != 0;
            const bool has_tx_cap      = bw_coin_supports_transactions(coin) != 0;
            const bool has_recv_cap    = bw_coin_supports_receive_address(coin) != 0;
            const bool has_send_cap    = bw_coin_supports_send(coin) != 0;

            // When the wallet reads are answerable. The two wallet shapes differ,
            // and conflating them is what left Transactions/Receive/Send blank for
            // every in-daemon coin: a managed wallet lives in a second process we
            // must have opened, but an in-daemon wallet answers as soon as its
            // daemon does — bitcoin-core serves getbalance / listtransactions /
            // getnewaddress on a *locked* wallet.
            // `rpc_ok`, not `daemon_up`: a busy daemon can't serve these either,
            // and a failed read here would blank the balance to "—" and empty the
            // transaction list for that tick — the same flicker, one layer down.
            const bool reads_ok = !busy &&
                ((ew_flags != 0) ? (wallet_state >= BW_WALLET_OPEN) : rpc_ok);

            // Spending is the exception: that one genuinely needs the wallet
            // unlocked. Note the in-daemon test blocks on a *positive* "locked"
            // rather than requiring a positive "unlocked" — a coin whose daemon
            // reports no lock state at all (BW_WSEC_UNKNOWN) has no lock to open,
            // and demanding one would park its Send tab on "unlock first"
            // forever. If we're wrong, the daemon rejects the send and says why,
            // which is a better answer than a permanent client-side refusal.
            const bool can_send = has_send_cap && (ew_flags != 0
                ? wallet_state >= BW_WALLET_OPEN
                : (rpc_ok && wallet_sec != BW_WSEC_LOCKED));

            // BW_BUSY means a wallet op holds the lock — keep the last value
            // rather than stalling the whole status pump behind a restore.
            BwWalletBalance bal;
            std::memset(&bal, 0, sizeof bal);
            bool have_balance = false;
            BwRescanProgress rp;
            std::memset(&rp, 0, sizeof rp);
            bool rescanning = false;
            std::vector<BwWalletTx> txs;
            std::string recv_addr;
            if (reads_ok) {
                if (has_balance_cap)
                    have_balance = (bw_wallet_balance(ctx, coin, &bal) == 0);

                // Rescan is a managed-wallet concept: it's the wallet-rpc
                // refreshing from height 0 after a restore.
                if (ew_flags != 0) {
                    rescanning = (bw_ext_wallet_rescan(ctx, coin, &rp) == 1);
                    if (rescanning)
                        wallet_state = BW_WALLET_RESCAN;
                }

                if (has_tx_cap) {
                    BwWalletTx tx_buf[TX_CAP];
                    size_t ntx = bw_wallet_transactions(ctx, coin, tx_buf, TX_CAP);
                    txs.assign(tx_buf, tx_buf + ntx);
                }

                // The address is fetched ONCE and then cached, never on this
                // timer: the RPC rotates it after it's been paid, so polling
                // would swap it out from under someone mid-send.
                if (has_recv_cap) {
                    bool want_new = g_want_new_addr.exchange(false);
                    if (want_new || g_recv_addr[coin].empty()) {
                        char ab[256] = {0};
                        size_t an = bw_wallet_receive_address(ctx, coin, want_new ? 1 : 0, ab, sizeof ab);
                        if (an > 0)
                            g_recv_addr[coin].assign(ab, an);
                    }
                    recv_addr = g_recv_addr[coin];
                }
            } else if (!busy) {
                // Not readable: the cached address belongs to a wallet we can no
                // longer vouch for, so drop it rather than keep showing it. Not
                // while merely busy, though — the wallet hasn't gone anywhere and
                // dropping it would clear the Receive tab mid-sync.
                g_recv_addr[coin].clear();
            } else {
                recv_addr = g_recv_addr[coin];
            }

            // Mining rides the *daemon's* RPC (the miner runs inside nervad), so
            // it's readable as soon as the daemon answers — no wallet needed.
            BwMiningStatus ms;
            std::memset(&ms, 0, sizeof ms);
            std::string hashrate;
            if (bw_coin_supports_mining(coin) && di_rc == 0 && bs_rc == 0) {
                if (bw_mining_status(ctx, coin, &ms) == 0 && ms.active) {
                    char hb[32] = {0};
                    size_t hn = bw_format_hashrate(ms.speed, hb, sizeof hb);
                    hashrate.assign(hb, hn);
                } else {
                    std::memset(&ms, 0, sizeof ms); // a failed read is not "mining"
                }
            }

            // Disk usage is a filesystem read — independent of the daemon.
            BwDiskUsage du;
            std::memset(&du, 0, sizeof du);
            float disk_frac = 0.0f;
            std::string disk_free_str;
            if (bw_disk_usage(ctx, coin, &du) == 0 && du.total_bytes > 0) {
                disk_frac = static_cast<float>(static_cast<double>(du.used_bytes) /
                                               static_cast<double>(du.total_bytes));
                disk_free_str = humanize_bytes(du.total_bytes - du.used_bytes) + " free";
            }

            // The status line, from the core — same wording and priority order
            // the TUI uses, rather than a sentence assembled here. We can't fill
            // every field (no presync detection or load sub-stage on this side
            // yet), and we don't have to: each unknown is 0, and the readout
            // degrades to a coarser but still correct label.
            BwStatusInput si;
            std::memset(&si, 0, sizeof si);
            si.installed = 1; // the Start button is unreachable otherwise
            si.daemon = daemon_up ? 2 : 0;
            si.peers = static_cast<uint32_t>(di.connections < 0 ? 0 : di.connections);
            si.sync = daemon_up ? (bs.synced ? 2 : 1) : 0;
            si.headers_cur = static_cast<uint64_t>(bs.headers < 0 ? 0 : bs.headers);
            si.blocks_cur = static_cast<uint64_t>(bs.blocks < 0 ? 0 : bs.blocks);
            {
                int64_t tip = bs.network_height > 0
                    ? bs.network_height
                    : (bs.headers > bs.blocks ? bs.headers : bs.blocks);
                si.headers_total = static_cast<uint64_t>(tip < 0 ? 0 : tip);
                si.blocks_total = si.headers_total;
            }
            char sl[192] = {0};
            size_t sll = rpc_ok ? bw_status_line(&si, sl, sizeof sl) : 0;
            std::string live_status(sl, sll);

            post_to_ui([weak, di, bs, daemon_up, sel, disk_frac, disk_free_str, wallet_sec, stage, live_status,
                        ms, hashrate, ew_flags, wallet_state, bal, have_balance,
                        rp, rescanning, txs, recv_addr, decimals, wallet_svc_err, can_send,
                        rpc_ok, busy, coin]() {
                auto h = weak.lock();
                if (!h)
                    return;
                // Selection changed while we were polling → drop this stale result.
                if (g_selected.load() != sel)
                    return;
                (*h)->set_disk_frac(disk_frac);
                (*h)->set_disk_free(slint::SharedString(disk_free_str));
                // Skipped while busy: wallet_sec is BW_WSEC_UNKNOWN there and
                // publishing it would grey the padlock every time the node
                // stalls, which is the flicker this whole branch exists to stop.
                if (!busy) {
                    (*h)->set_wallet_sec(wallet_sec);
                    // How many actions this state permits, so the Wallet button
                    // greys out rather than opening an empty dialog. The core
                    // decides; this only counts.
                    uint8_t acts[8];
                    (*h)->set_wallet_menu_count(static_cast<int>(
                        bw_wallet_menu(coin, wallet_sec, acts, sizeof acts)));
                }
                (*h)->set_ew_flags(ew_flags);
                (*h)->set_wallet_state(wallet_state);
                // Everything below came from a wallet read, so on a busy tick
                // there is nothing new to say and the last values stand. Writing
                // them anyway would blank the balance to "—" and empty the
                // transaction list every time the node stalled.
                if (!busy) {
                    (*h)->set_can_send(can_send);
                    (*h)->set_balance_total(slint::SharedString(
                        have_balance ? format_amount(bal.total, decimals) : std::string("—")));
                    (*h)->set_balance_avail(slint::SharedString(
                        have_balance ? format_amount(bal.available, decimals) : std::string("—")));
                    (*h)->set_rescan_frac(rescanning && rp.target > 0
                        ? static_cast<float>(static_cast<double>(rp.scanned) /
                                             static_cast<double>(rp.target))
                        : 0.0f);
                    (*h)->set_receive_address(slint::SharedString(recv_addr));
                    (*h)->set_tx_rows(make_tx_rows(txs, decimals));
                }
                // Only when it changes, so a persistent fault doesn't rewrite
                // the status line every two seconds over whatever else is there.
                if (!wallet_svc_err.empty() && wallet_svc_err != g_last_wallet_svc_err) {
                    (*h)->set_status_text(slint::SharedString(wallet_svc_err));
                    (*h)->set_status_is_error(true);
                }
                g_last_wallet_svc_err = wallet_svc_err;
                const bool running = daemon_up;
                (*h)->set_running(running);
                // The poll owns the loading state: it lasts until the daemon
                // answers RPC, which is long after the Start action returns.
                // Start stays latched for that whole window, so the daemon
                // coming up can't be mistaken for a stopped one and started
                // twice (the second attempt just hits the datadir lock).
                (*h)->set_live_status(slint::SharedString(live_status));
                (*h)->set_daemon_stage(slint::SharedString(stage));
                (*h)->set_daemon_loading(!running && !stage.empty());
                // Three states, not two. `rpc_ok` publishes fresh figures;
                // `busy` holds the last ones (the daemon is up, we just couldn't
                // read it this tick, and zeroing would make the gauges stutter);
                // down clears everything.
                if (rpc_ok) {
                    bool synced = bs.synced != 0;
                    int64_t tip = bs.network_height > 0
                        ? bs.network_height
                        : (bs.headers > bs.blocks ? bs.headers : bs.blocks);
                    (*h)->set_blocks(static_cast<int>(bs.blocks));
                    (*h)->set_headers(static_cast<int>(bs.headers));
                    (*h)->set_peers(static_cast<int>(di.connections));
                    (*h)->set_staking(di.staking_active != 0);
                    (*h)->set_synced(synced);
                    (*h)->set_headers_frac(sync_frac(bs.headers, tip, synced));
                    (*h)->set_blocks_frac(sync_frac(bs.blocks, tip, synced));
                    (*h)->set_headers_str(slint::SharedString(group_int(bs.headers)));
                    (*h)->set_blocks_str(slint::SharedString(group_int(bs.blocks)));
                    (*h)->set_sync_percent(synced
                            ? 100.0f
                            : static_cast<float>(bs.verification_progress * 100.0));
                    (*h)->set_chain(slint::SharedString(bs.chain));
                    (*h)->set_mining(ms.active != 0);
                    (*h)->set_mining_threads(static_cast<int>(ms.threads));
                    (*h)->set_mining_hashrate(slint::SharedString(hashrate));
                } else if (!busy) {
                    // Daemon down (e.g. just stopped): clear everything it drove so
                    // the gauges unfill to 0 and the counts/peers reset, rather than
                    // freezing at their last value. Deliberately NOT done while
                    // busy — there the last figures are the truest thing we have.
                    (*h)->set_blocks(0);
                    (*h)->set_headers(0);
                    (*h)->set_peers(0);
                    (*h)->set_staking(false);
                    (*h)->set_synced(false);
                    (*h)->set_headers_frac(0);
                    (*h)->set_blocks_frac(0);
                    (*h)->set_sync_percent(0);
                    (*h)->set_headers_str(slint::SharedString(""));
                    (*h)->set_blocks_str(slint::SharedString(""));
                    // The miner dies with the daemon, so a stale hashrate here
                    // would be a lie, not merely out of date.
                    (*h)->set_mining(false);
                    (*h)->set_mining_threads(0);
                    (*h)->set_mining_hashrate(slint::SharedString(""));
                }
            });

            // Wait ~2s, but wake immediately if the selection changed (or we're
            // shutting down) so the next coin polls without the cadence delay.
            std::unique_lock<std::mutex> lk(g_poll_mtx);
            g_poll_cv.wait_for(lk, std::chrono::seconds(2), [&] {
                return stop.load() || g_sel_gen.load() != gen;
            });
        }
    });

    // Shut the background work down *from the close callback*, which runs while
    // the event loop is still alive. Doing it after `run()` returns would be too
    // late: the poller posts every ~2s, and a post landing in a loop that has
    // already quit is not survivable.
    ui->window().on_close_requested([&stop, &ui, ctx]() {
        // Remember the window as the user left it. First, while the window still
        // exists and we're on the UI thread — every slint::Window accessor
        // asserts that, and after this callback there's nothing left to measure.
        //
        // Stored in logical pixels, because that's what it is restored as (the
        // preferred size) and the scale factor isn't known yet at that point.
        const auto size = ui->window().size();
        const auto pos = ui->window().position();
        const float sf = ui->window().scale_factor() > 0 ? ui->window().scale_factor() : 1.0f;
        const BwWindowGeometry geom = {
            static_cast<uint32_t>(static_cast<float>(size.width) / sf),
            static_cast<uint32_t>(static_cast<float>(size.height) / sf),
            pos.x,
            pos.y,
            ui->window().is_maximized() ? 1 : 0,
        };
        bw_save_window_geometry(ctx, &geom);

        begin_shutdown();
        // Effectively "press Pause" on the way out. A chain snapshot runs for the
        // better part of an hour, so it is very likely still running here — and a
        // paused transfer keeps its bytes, so the next run offers to carry on from
        // exactly where this one stopped rather than refetching several GB.
        bw_sync_accel_pause(ctx);
        stop.store(true);
        g_poll_cv.notify_all(); // wake the poller out of its wait so it can exit
        return slint::CloseRequestResponse::HideWindow;
    });

    // Second (and last) attempt at the remembered size, for a window the window
    // manager opened smaller than asked for.
    //
    // The preferred size set before show() is the only sizing a Wayland compositor
    // is obliged to honour, and it may cap it: COSMIC will not open a window taller
    // than about two thirds of the screen, so a taller remembered window comes back
    // short. X11, Windows and macOS all let an application resize itself once the
    // window is up, so ask them for the rest.
    //
    // Delayed rather than immediate, because showing a window settles it onto its
    // preferred size over the first few frames (~100ms here) and a resize landing
    // before that is simply overwritten. One shot, and the result isn't checked: on
    // a compositor that refuses application-driven resizes — COSMIC ignores them
    // outright, having flagged the surface as tiled — this is a no-op, and there is
    // nothing to be done about that from in here.
    slint::Timer correct_size;
    if (have_geom && !geom.maximized) {
        correct_size.start(
            slint::TimerMode::SingleShot, std::chrono::milliseconds(300), [&ui, &geom]() {
                const float sf = ui->window().scale_factor() > 0 ? ui->window().scale_factor() : 1.0f;
                const auto now = ui->window().size();
                const float w = static_cast<float>(now.width) / sf;
                const float h = static_cast<float>(now.height) / sf;
                // Only ever grow back towards what was stored. A window the user's
                // screen genuinely can't fit stays capped, and asking again costs
                // one refused request.
                if (w + 1 < static_cast<float>(geom.width) || h + 1 < static_cast<float>(geom.height))
                    ui->window().set_size(slint::LogicalSize({static_cast<float>(geom.width),
                                                              static_cast<float>(geom.height)}));
            });
    }

    ui->run();

    // --- shutdown ---------------------------------------------------------
    //
    // The window is gone, but detached workers may still be mid-flight and they
    // are all using `ctx`. Freeing it underneath them is a use-after-free — a
    // reliable SEGV on quit before this barrier existed. So wait for every worker
    // to let go before tearing the context down.
    //
    // Repeated here as well as in the close callback because `run()` can also
    // return without a close request (quit_event_loop, or the window never having
    // been closed by the user), and this must hold on every path.
    begin_shutdown();
    bw_sync_accel_pause(ctx);
    stop.store(true);
    g_poll_cv.notify_all();
    poller.join();

    {
        std::unique_lock<std::mutex> lk(g_workers_mtx);
        g_workers_cv.wait(lk, [] { return g_workers.load() == 0; });
    }
    bw_deinit(ctx);
    return 0;
}
