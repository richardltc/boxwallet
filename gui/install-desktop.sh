#!/bin/sh
# Register BoxWallet with the desktop, so the panel and app launcher show its
# logo instead of a generic placeholder.
#
# Why this is needed at all: on Wayland an application cannot set its own window
# icon. The compositor looks the icon up by matching the window's app_id against
# an installed desktop entry, so without one there is nothing to match. Running
# this once fixes it; it is not needed to *use* BoxWallet.
#
# Everything lands under ~/.local/share — no root, nothing outside your account.
# Re-run it after moving the folder, so `Exec=` points at the new location.
set -eu

# Resolve the directory holding this script, so the entry points at *this* copy
# of BoxWallet however the user unpacked it.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exe="$here/boxwallet-gui"

if [ ! -x "$exe" ]; then
    echo "install-desktop: no executable at $exe" >&2
    echo "Run this from the folder you extracted BoxWallet into." >&2
    exit 1
fi

data="${XDG_DATA_HOME:-$HOME/.local/share}"
apps="$data/applications"
icons="$data/icons/hicolor/256x256/apps"
mkdir -p "$apps" "$icons"

cp -f "$here/icons/boxwallet.png" "$icons/boxwallet.png"

# Substitute the real path into Exec=. Written to a temp file and moved into
# place so a half-written entry is never visible to the desktop.
tmp="$apps/.boxwallet.desktop.tmp"
sed "s|@EXEC@|$exe|" "$here/boxwallet.desktop" > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$apps/boxwallet.desktop"

# Best effort: the caches speed lookup up but are not required, and these tools
# are absent on plenty of systems. Never fail the install over them.
update-desktop-database "$apps" 2>/dev/null || true
gtk-update-icon-cache -f -t "$data/icons/hicolor" 2>/dev/null || true

echo "BoxWallet installed to your applications menu."
echo "  entry: $apps/boxwallet.desktop"
echo "  icon:  $icons/boxwallet.png"
echo
echo "If the panel still shows a generic icon, log out and back in — some"
echo "desktops only scan for new entries at session start."
