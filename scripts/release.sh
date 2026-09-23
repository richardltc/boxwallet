#!/usr/bin/env bash
#
# Build a BoxWallet release and publish it to GitHub.
#
# Cross-builds every distributable asset (`zig build release-all`: the five
# TUI binaries, the four GUI exes (two Linux, Windows x86_64, macOS arm64)
# with their .zip bundles, and RUNTIME, with one merged SHA256SUMS covering
# all of it), creates the `vX.Y.Z` git tag from `app_version`, and publishes
# a GitHub release with everything `release-all` assembled — the file list is
# whatever lands in zig-out/dist/, never a count kept by hand here.
# Both front-ends' in-app updater downloads from exactly this release, so
# what's published here is what users auto-update to.
#
# Requirements: bash, git, a Zig 0.16 toolchain, and the GitHub CLI (gh)
# authenticated with a token that can create releases on the target repo
# (`gh auth login`).
#
# Usage:
#   scripts/release.sh
#
# Bump app_version in src/version.zig and commit it first; the tag and
# release name are derived from it. The script refuses to run with
# uncommitted changes, so the tag always points at exactly what was built.
# It's idempotent: re-running after a partial failure reuses the tag if it
# already exists and overwrites any assets already uploaded to the release.

set -euo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------
command -v git >/dev/null || die "git not found"
command -v zig >/dev/null || die "zig not found"
command -v gh  >/dev/null || die "gh (GitHub CLI) not found - see https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated - run 'gh auth login' first"

# Run from the repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "you have uncommitted changes to tracked files - commit them first so the release tag matches what's built"
fi

# Derive owner/repo from the origin remote, e.g.
# https://github.com/richardltc/boxwallet.git -> richardltc/boxwallet
REMOTE_URL="$(git remote get-url origin)"
SLUG="${REMOTE_URL#*github.com[:/]}"   # strip scheme + host
SLUG="${SLUG%.git}"
[ "$SLUG" != "$REMOTE_URL" ] || die "origin remote is not a github.com URL: $REMOTE_URL"
REPO="$SLUG"

# --- Version + tag -----------------------------------------------------------
VERSION="$(sed -n 's/.*app_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/version.zig | head -n1)"
[ -n "$VERSION" ] || die "could not read app_version from src/version.zig"
TAG="v$VERSION"

printf 'Releasing %s as %s on GitHub\n' "$TAG" "$REPO"

# --- Build & verify ------------------------------------------------------------
export ZIG_GLOBAL_CACHE_DIR=zig-pkg
echo "==> zig build test"
zig build test
echo "==> zig build release-all"
zig build release-all

DIST_DIR="zig-out/dist"
[ -d "$DIST_DIR" ] || die "$DIST_DIR not found after build"
[ -f "$DIST_DIR/SHA256SUMS" ] || die "$DIST_DIR/SHA256SUMS missing"

echo "==> verifying checksums"
(cd "$DIST_DIR" && sha256sum -c SHA256SUMS)

# --- Tag (idempotent: create + push only when missing) -----------------------
echo "==> ensuring tag $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -m "BoxWallet $TAG"
fi
git push origin "refs/tags/$TAG"

# --- Release notes -----------------------------------------------------------
# A GitHub release is a flat, sorted list of files with no folders, and most of
# what's in it is machinery: the `update-*` exes exist for the in-app updater and
# cannot run on their own (they ship without the Slint runtime that the .zip
# carries, so the loader kills them before main - no window, no message, which
# reads exactly like a corrupt download). This table sits directly above that
# list and is the only thing that tells a first-time visitor which of ~19 files
# they actually came for. Deliberately not a changelog: it's the same every
# release, so it can't go stale.
read -r -d '' NOTES <<'EOF' || true
### Which file do I want?

**Desktop app** - download the `.zip`, unzip it, and run `boxwallet-gui` from inside the folder:

| Platform | File |
|---|---|
| Linux x86_64 | `boxwallet-gui-linux-x86_64.zip` |
| Linux aarch64 | `boxwallet-gui-linux-aarch64.zip` |
| Windows x86_64 | `boxwallet-gui-windows-x86_64.zip` |
| macOS Apple Silicon | `boxwallet-gui-macos-aarch64.zip` |

**Terminal app** - a single binary, download and run:

| Platform | File |
|---|---|
| Linux x86_64 | `boxwallet-linux-x86_64` |
| Linux aarch64 | `boxwallet-linux-aarch64` |
| Windows x86_64 | `boxwallet-windows-x86_64.exe` |
| macOS Intel | `boxwallet-macos-x86_64` |
| macOS Apple Silicon | `boxwallet-macos-aarch64` |

Everything else in the list below is machinery, not a download: the `update-*`
files are fetched by BoxWallet's own updater and will not start if you run them
yourself, and `SHA256SUMS` / `RUNTIME` are there so downloads can be verified.
EOF

# --- Publish (idempotent: gh reuses the release, --clobber replaces assets) --
echo "==> creating/updating release $TAG"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  # Assets only. The notes are left alone on a re-run: a partial release that got
  # its notes edited by hand on GitHub shouldn't have that thrown away by a retry.
  gh release upload "$TAG" "$DIST_DIR"/* --repo "$REPO" --clobber
else
  gh release create "$TAG" "$DIST_DIR"/* \
    --repo "$REPO" \
    --title "BoxWallet $TAG" \
    --notes "$NOTES"
fi

printf '\nReleased: https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG"
