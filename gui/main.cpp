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

    bw_ctx *ctx = bw_init(home_dir());
    if (!ctx) {
        std::fprintf(stderr, "bw_init failed\n");
        return 1;
    }

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
        slint::invoke_from_event_loop([w, msg, is_err]() {
            if (auto h = w.lock()) {
                (*h)->set_daemon_busy(false);
                (*h)->set_daemon_loading(false); // start finished (running or failed)
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
    ui->on_start_daemon([weak, ctx, wake_poll, finish_action, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Starting daemon…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
            int rc = bw_start_daemon(ctx, static_cast<size_t>(coin));
            finish_action(weak, ctx, rc, "Daemon running");
            wake_poll();
        }).detach();
    });
    ui->on_stop_daemon([weak, ctx, wake_poll, finish_action, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Stopping daemon…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
            int rc = bw_stop_daemon(ctx, static_cast<size_t>(coin));
            finish_action(weak, ctx, rc, "Daemon stopped");
            wake_poll();
        }).detach();
    });
    ui->on_lock_wallet([weak, ctx, wake_poll, finish_action, begin_status]() {
        int coin = g_selected.load();
        if (coin < 0)
            return;
        begin_status(weak, "Locking wallet…");
        std::thread([weak, ctx, coin, wake_poll, finish_action]() {
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

            slint::invoke_from_event_loop([weak, di, bs, di_rc, bs_rc, sel, disk_frac, disk_free_str, wallet_sec]() {
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

    ui->run();

    stop.store(true);
    g_poll_cv.notify_all(); // wake the poller out of its wait so it can exit
    poller.join();
    bw_deinit(ctx);
    return 0;
}
