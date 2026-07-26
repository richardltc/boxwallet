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

    ui->set_has_mining(bw_coin_supports_mining(idx) != 0);
    ui->set_has_stablecoin(bw_coin_supports_stablecoin(idx) != 0);
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
    ui->set_sync_percent(0);
    ui->set_chain(slint::SharedString(""));
    ui->set_headers_str(slint::SharedString(""));
    ui->set_blocks_str(slint::SharedString(""));
    ui->set_disk_free(slint::SharedString(""));
    ui->set_status_text(slint::SharedString(""));
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

    // The window the user arranged last time. Nothing stored (or nothing usable)
    // leaves Slint's preferred size, so a first run — or a corrupt conf — still
    // opens sensibly.
    //
    // Applied *after* show(), not before: the native window doesn't exist until
    // then, and creating it sizes it from the component's preferred-width/height,
    // discarding anything set beforehand. Measured — a size stored ahead of
    // `run()` was silently replaced by the 700px default every launch.
    //
    // The size is applied even when restoring maximized, so "restore down" gives
    // back the size they chose rather than the default. Position is applied for
    // the platforms that honour it; on Wayland the compositor places windows and
    // ignores it, which is why it's set-and-forget rather than checked.
    BwWindowGeometry geom;
    const bool have_geom = bw_window_geometry(ctx, &geom) == 1;
    auto restore_geometry = [&ui, &geom, have_geom]() {
        if (!have_geom)
            return;
        ui->window().set_size(slint::PhysicalSize({geom.width, geom.height}));
        ui->window().set_position(slint::PhysicalPosition({geom.x, geom.y}));
        if (geom.maximized)
            ui->window().set_maximized(true);
    };

    // Build the nav list: every registered coin, sorted alphabetically by name
    // (Home is pinned separately in the UI). The registry index rides along so
    // callbacks can address the coin over the C ABI.
    std::vector<NavCoin> coins;
    size_t count = bw_coin_count();
    for (size_t i = 0; i < count; ++i) {
        char nm[64];
        size_t nn = bw_coin_name(i, nm, sizeof nm);
        char col[16];
        size_t cn = bw_coin_color(i, col, sizeof col);
        NavCoin nc;
        nc.name = slint::SharedString(std::string_view(nm, nn));
        nc.color = parse_hex_color(col, cn);
        nc.index = static_cast<int>(i);
        // Logo is embedded (see AppWindow.coin-logos), selected by nc.index.
        coins.push_back(nc);
    }
    std::sort(coins.begin(), coins.end(), [](const NavCoin &a, const NavCoin &b) {
        return std::string_view(a.name) < std::string_view(b.name);
    });
    ui->set_nav_coins(std::make_shared<slint::VectorModel<NavCoin>>(coins));

    std::atomic<bool> stop{false};
    slint::ComponentWeakHandle<AppWindow> weak(ui);

    // Nav → select a coin: push its metadata and start polling it.
    ui->on_coin_selected([weak, ctx](int idx) {
        if (auto h = weak.lock()) {
            {
                std::lock_guard<std::mutex> lk(g_poll_mtx);
                g_selected.store(idx);
                g_sel_gen.fetch_add(1);
            }
            g_poll_cv.notify_one(); // poll the new coin immediately
            apply_coin_metadata(&**h, ctx, idx);
        }
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

    ui->on_start_daemon([weak, ctx, launch_daemon]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
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

            // Wallet lock state — only meaningful once the daemon answers.
            int wallet_sec = (di_rc == 0 && bs_rc == 0) ? bw_wallet_security(ctx, coin) : 0;

            // The reads failing doesn't mean "not running": a bitcoin-derived
            // daemon can't serve them for the whole of its start-up (block
            // index, then wallet — tens of seconds to minutes) while it answers
            // -28 with the stage it's at. Ask for that stage, so the UI reports
            // "Loading block index…" / "Rewinding…" / "Verifying…" rather than
            // claiming the daemon it just started isn't running.
            std::string stage;
            if (di_rc != 0 || bs_rc != 0) {
                char sb[128] = {0};
                size_t sn = bw_daemon_stage(ctx, coin, sb, sizeof sb);
                stage.assign(sb, sn);
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

            post_to_ui([weak, di, bs, di_rc, bs_rc, sel, disk_frac, disk_free_str, wallet_sec, stage]() {
                auto h = weak.lock();
                if (!h)
                    return;
                // Selection changed while we were polling → drop this stale result.
                if (g_selected.load() != sel)
                    return;
                (*h)->set_disk_frac(disk_frac);
                (*h)->set_disk_free(slint::SharedString(disk_free_str));
                (*h)->set_wallet_sec(wallet_sec);
                bool running = (di_rc == 0) && (bs_rc == 0);
                (*h)->set_running(running);
                // The poll owns the loading state: it lasts until the daemon
                // answers RPC, which is long after the Start action returns.
                // Start stays latched for that whole window, so the daemon
                // coming up can't be mistaken for a stopped one and started
                // twice (the second attempt just hits the datadir lock).
                (*h)->set_daemon_stage(slint::SharedString(stage));
                (*h)->set_daemon_loading(!running && !stage.empty());
                if (running) {
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
                } else {
                    // Daemon down (e.g. just stopped): clear everything it drove so
                    // the gauges unfill to 0 and the counts/peers reset, rather than
                    // freezing at their last value.
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
        const auto size = ui->window().size();
        const auto pos = ui->window().position();
        const BwWindowGeometry geom = {
            size.width, size.height, pos.x, pos.y,
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

    // `run()` decomposed (it is exactly show + loop + hide) so the saved geometry
    // can be applied in between — see `restore_geometry`.
    ui->show();
    restore_geometry();
    slint::run_event_loop();
    ui->hide();

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
