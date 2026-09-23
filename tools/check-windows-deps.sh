#!/usr/bin/env bash
#
# Fail if the Windows GUI bundle depends on a DLL it neither ships nor can count
# on Windows providing.
#
# This exists because of how that failure looks. An import the target machine
# can't satisfy is resolved by the loader *before `main`*, so the app dies with
# no window, no message, and none of our code running to explain it — the user
# double-clicks and nothing happens. `--selftest` can't catch it either: CI
# runners have the Visual C++ redistributable installed, so a dependency that
# would strand real users passes there quite happily.
#
# So the check is static, runs on the Linux build host, and is about *change*:
# the current external dependency is the VC++ runtime, which is known and
# documented (see README-WINDOWS.txt in the bundle). What must never happen
# quietly is a Slint bump adding a *second* one. Anything not shipped in the
# bundle, not part of Windows, and not on the acknowledged list below is an
# error.
#
# Usage: tools/check-windows-deps.sh <bundle-dir>

set -euo pipefail

dir="${1:?usage: check-windows-deps.sh <bundle-dir>}"
[ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 1; }
command -v objdump >/dev/null || { echo "objdump not found (binutils)" >&2; exit 1; }

# Shipped beside the exe, so the loader finds them in the first place it looks.
shipped=$(cd "$dir" && ls *.dll 2>/dev/null | tr 'A-Z' 'a-z' | sort -u || true)

# Present on every supported Windows. `api-ms-win-*` is the API-set stub scheme
# (including the Universal CRT, part of Windows since 10); the rest are
# System32 components. d3dcompiler_47.dll is included deliberately — it ships
# with Windows 10+, unlike its numbered predecessors, which had to be
# redistributed.
os_provided='^(api-ms-win-.*|advapi32|bcryptprimitives|combase|comctl32|crypt32|d3d12|d3dcompiler_47|dwmapi|dwrite|dxgi|gdi32|imm32|kernel32|ntdll|ole32|oleaut32|opengl32|shell32|shlwapi|uiautomationcore|user32|uxtheme|ws2_32)\.dll$'

# Known, documented, NOT shipped. Upstream's Slint DLL is built with MSVC and
# links the VC++ runtime dynamically, and that runtime is not part of Windows —
# a clean install does not have it. Deliberately listed rather than silently
# tolerated: if this list ever needs a new entry, that is a decision about what
# users must install before BoxWallet runs, not a detail.
acknowledged='^(msvcp140|vcruntime140)\.dll$'

missing=""
for pe in "$dir"/*.exe "$dir"/*.dll; do
  [ -e "$pe" ] || continue
  while read -r dll; do
    [ -n "$dll" ] || continue
    printf '%s\n' "$shipped" | grep -qx "$dll" && continue
    printf '%s' "$dll" | grep -qE "$os_provided" && continue
    printf '%s' "$dll" | grep -qE "$acknowledged" && continue
    missing="$missing$(basename "$pe") -> $dll"$'\n'
  done < <(objdump -p "$pe" 2>/dev/null | awk '/DLL Name:/ {print tolower($3)}' | sort -u)
done

if [ -n "$missing" ]; then
  echo "error: the Windows bundle depends on DLLs it does not ship and Windows does not provide:" >&2
  printf '%s' "$missing" | sed 's/^/  /' >&2
  echo >&2
  echo "Each one is an app that dies in the loader before main on any machine lacking it," >&2
  echo "with nothing on screen. Either ship it in the bundle, or add it to the acknowledged" >&2
  echo "list in this script AND to README-WINDOWS.txt so users are told to install it." >&2
  exit 1
fi

echo "windows deps OK: everything is shipped, part of Windows, or acknowledged"
printf '%s\n' "$shipped" | sed 's/^/  ships: /'
echo "  requires installed: Visual C++ redistributable (msvcp140.dll, vcruntime140.dll)"
