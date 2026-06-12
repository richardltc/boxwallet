#!/usr/bin/env bash
#
# Build a BoxWallet release and publish it to Codeberg.
#
# Cross-builds every distributable binary (`zig build release`), creates the
# `vX.Y.Z` git tag from `app_version`, opens the matching Codeberg release via
# the Forgejo API, and uploads all six artifacts (the five `boxwallet-*`
# binaries + `SHA256SUMS`). The in-app updater downloads from exactly this
# release, so what we publish here is what users auto-update to.
#
# Requirements: bash, git, curl, jq, and a Zig 0.16 toolchain.
#
# Usage:
#   CODEBERG_TOKEN=<token> scripts/release.sh
#
# The token needs `write:repository` scope. It's read only from the environment
# and never printed or written to disk. Bump `app_version` in src/app.zig first;
# the tag and release name are derived from it. The script is idempotent: the
# tag, release, and assets are created if missing and reused/replaced if a
# previous run left them behind, so a failed publish can simply be re-run.

set -euo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- Preconditions ---------------------------------------------------------
if [ -z "${CODEBERG_TOKEN:-}" ]; then
  cat >&2 <<'EOF'
error: CODEBERG_TOKEN is not set.

Create a token with write:repository scope at
https://codeberg.org/user/settings/applications, then export it:

  bash/zsh:  export CODEBERG_TOKEN=<token>
  fish:      set -x CODEBERG_TOKEN <token>

and re-run this script.
EOF
  exit 1
fi
command -v git  >/dev/null || die "git not found"
command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"
command -v zig  >/dev/null || die "zig not found"

# Run from the repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

API="https://codeberg.org/api/v1"

# Derive owner/repo from the origin remote, e.g.
# https://codeberg.org/richardltc/BoxWallet.git -> richardltc / BoxWallet
REMOTE_URL="$(git remote get-url origin)"
SLUG="${REMOTE_URL#*codeberg.org[:/]}"   # strip scheme + host
SLUG="${SLUG%.git}"
OWNER="${SLUG%%/*}"
REPO="${SLUG##*/}"
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ "$OWNER" != "$SLUG" ] \
  || die "could not parse owner/repo from origin remote: $REMOTE_URL"

# --- Version + tag ---------------------------------------------------------
VERSION="$(sed -n 's/.*app_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/app.zig | head -n1)"
[ -n "$VERSION" ] || die "could not read app_version from src/app.zig"
TAG="v$VERSION"

printf 'Releasing %s as %s/%s on Codeberg\n' "$TAG" "$OWNER" "$REPO"

# --- Build & verify --------------------------------------------------------
export ZIG_GLOBAL_CACHE_DIR=zig-pkg
echo "==> zig build test"
zig build test
echo "==> zig build release"
zig build release

REL_DIR="zig-out/release"
[ -d "$REL_DIR" ] || die "$REL_DIR not found after build"
[ -f "$REL_DIR/SHA256SUMS" ] || die "$REL_DIR/SHA256SUMS missing"
# Expect the five binaries named in build.zig's release_targets, plus SHA256SUMS.
for f in \
  boxwallet-linux-x86_64 \
  boxwallet-linux-aarch64 \
  boxwallet-macos-x86_64 \
  boxwallet-macos-aarch64 \
  boxwallet-windows-x86_64.exe \
  SHA256SUMS; do
  [ -f "$REL_DIR/$f" ] || die "expected artifact missing: $REL_DIR/$f"
done

# --- Tag (idempotent: create + push only when missing) ---------------------
echo "==> ensuring tag $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -m "BoxWallet $TAG"
fi
git push origin "refs/tags/$TAG"

# --- Codeberg API ----------------------------------------------------------
AUTH=(-H "Authorization: token $CODEBERG_TOKEN")

# Run a request and split curl's appended status code from the body, so API
# errors are visible (curl -f swallows the body and prints only 'error: 22').
RESP_BODY=""
RESP_STATUS=""
api() { # method url [extra curl args...]
  local method="$1" url="$2"; shift 2
  local out
  out="$(curl -sS -w $'\n%{http_code}' "${AUTH[@]}" -X "$method" "$url" "$@")"
  RESP_STATUS="${out##*$'\n'}"
  RESP_BODY="${out%$'\n'*}"
}

# Sanity-check the token before mutating anything: a 401/403 here means a
# bad/expired token; a 404 on the release endpoints (with this passing) means
# the token lacks write:repository scope or the Releases unit is disabled.
echo "==> verifying token"
api GET "$API/user"
case "$RESP_STATUS" in
  200) ;;
  401|403) die "Codeberg rejected the token ($RESP_STATUS). Check CODEBERG_TOKEN is valid and not expired." ;;
  *) die "unexpected status $RESP_STATUS from $API/user" ;;
esac

# --- Create or reuse the release (idempotent) ------------------------------
# Reusing an existing release lets a failed/partial run be retried cleanly.
echo "==> creating/locating release $TAG"
api GET "$API/repos/$OWNER/$REPO/releases/tags/$TAG"
if [ "$RESP_STATUS" = "200" ]; then
  RELEASE_ID="$(printf '%s' "$RESP_BODY" | jq -r '.id')"
  echo "    reusing existing release id $RELEASE_ID"
  # Correct the metadata in case an earlier/partial release set it wrong.
  api PATCH "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "BoxWallet $TAG" '{name:$name, body:"", draft:false, prerelease:false}')"
  [ "$RESP_STATUS" = "200" ] || { printf '%s\n' "$RESP_BODY" >&2; die "could not update release (HTTP $RESP_STATUS)"; }
elif [ "$RESP_STATUS" = "404" ]; then
  body="$(jq -n --arg tag "$TAG" --arg name "BoxWallet $TAG" \
    '{tag_name:$tag, name:$name, body:"", draft:false, prerelease:false}')"
  api POST "$API/repos/$OWNER/$REPO/releases" -H "Content-Type: application/json" -d "$body"
  if [ "$RESP_STATUS" != "201" ]; then
    printf '%s\n' "$RESP_BODY" >&2
    case "$RESP_STATUS" in
      403|404) die "create release failed ($RESP_STATUS): token likely lacks write:repository scope, or the repo's Releases unit is disabled" ;;
      *) die "create release failed (HTTP $RESP_STATUS)" ;;
    esac
  fi
  RELEASE_ID="$(printf '%s' "$RESP_BODY" | jq -r '.id')"
else
  printf '%s\n' "$RESP_BODY" >&2
  die "could not query release by tag (HTTP $RESP_STATUS)"
fi
[ -n "$RELEASE_ID" ] && [ "$RELEASE_ID" != "null" ] || die "no release id in API response"

# --- Upload assets (idempotent: replace same-named assets) -----------------
api GET "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets"
existing_assets="$RESP_BODY"
for path in "$REL_DIR"/*; do
  name="$(basename "$path")"
  old_id="$(printf '%s' "$existing_assets" | jq -r --arg n "$name" 'map(select(.name==$n)) | (.[0].id // empty)')"
  if [ -n "$old_id" ]; then
    echo "==> replacing $name"
    api DELETE "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets/$old_id"
  else
    echo "==> uploading $name"
  fi
  api POST "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$name" \
    -F "attachment=@$path;type=application/octet-stream"
  if [ "$RESP_STATUS" != "201" ]; then
    printf '%s\n' "$RESP_BODY" >&2
    die "failed to upload $name (HTTP $RESP_STATUS)"
  fi
done

printf '\nReleased: https://codeberg.org/%s/%s/releases/tag/%s\n' "$OWNER" "$REPO" "$TAG"
