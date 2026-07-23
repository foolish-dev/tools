#!/usr/bin/env bash
# setup.sh — one-line bring-up for the GZ302EA Windows 11 driver pack:
#
#   curl -fsSL https://raw.githubusercontent.com/foolish-dev/tools/main/GZ302EA/setup.sh | bash -s -- /mnt/usb
#
# Builds the three tools (fetch / distill / install), downloads + verifies all
# 26 ASUS packages (~11 GB) into the target dir (default: CWD), distills them
# to pnputil-ready payloads in Extracted/, and previews the Windows install
# plan. Idempotent: re-runs verify instead of re-downloading/re-extracting.
# Run from a repo checkout it uses that checkout; piped, it clones into
# ~/.cache/gz302ea-tools.

set -Eeuo pipefail

FAIL=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[!!]%s %s\n' "$RED" "$RST" "$*"; : $((++FAIL)); }

trap 'printf "%s[ERR]%s line %d: %s (exit %d)\n" "$RED" "$RST" "$LINENO" "$BASH_COMMAND" "$?" >&2' ERR

REPO=https://github.com/foolish-dev/tools
TARGET="${1:-$PWD}"

# Package-manager-agnostic: only used to phrase the "missing dep" hints.
PM="your package manager"
for pm in pacman apt dnf zypper apk xbps-install brew winget; do
  command -v "$pm" &>/dev/null && { PM=$pm; break; }
done

for cmd in git cargo; do
  command -v "$cmd" &>/dev/null || fail "missing: $cmd (install via $PM)"
done
SEVENZ=""
for z in 7z 7zz 7za; do
  command -v "$z" &>/dev/null && { SEVENZ=$z; break; }
done
[[ -n "$SEVENZ" ]] || fail "missing: 7-Zip (none of 7z/7zz/7za on PATH — install 7zip/p7zip via $PM)"
[[ $FAIL -eq 0 ]] || exit 1

if ! command -v innoextract &>/dev/null && ! command -v wine &>/dev/null; then
  warn "neither innoextract nor wine found — distill will skip the Inno-stream components (innoextract via $PM fixes this on any OS)"
fi

# Use the checkout this script lives in, if any; otherwise clone/update a cache copy.
src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [[ -f "$src/fetch/Cargo.toml" ]] || src=""
fi
if [[ -z "$src" ]]; then
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/gz302ea-tools"
  if [[ -d "$cache/.git" ]]; then
    info "updating $cache"
    git -C "$cache" pull --ff-only -q
  else
    info "cloning $REPO"
    git clone -q --depth 1 "$REPO" "$cache"
  fi
  src="$cache/GZ302EA"
fi
ok "tools source: $src"

for crate in fetch distill install; do
  info "building gz302ea-$crate"
  cargo build --release --locked --quiet --manifest-path "$src/$crate/Cargo.toml"
done
bin() { echo "$src/$1/target/release/gz302ea-$1"; }

mkdir -p "$TARGET"
info "pack target: $TARGET (~11 GB)"
"$(bin fetch)" "$TARGET"   || fail "fetch"
"$(bin distill)" "$TARGET" || fail "distill"

info "Windows install plan (preview):"
"$(bin install)" --dry-run "$TARGET" >/dev/null 2>&1 \
  && ok "gz302ea-install --dry-run ok — run gz302ea-install elevated on Windows" \
  || warn "install preview incomplete (distill skipped components?)"

if [[ $FAIL -eq 0 ]]; then
  ok "done. next: copy '$TARGET' to USB → install Windows → run gz302ea-install"
  info "OOBE offline Wi-Fi: Shift+F10 → pnputil /add-driver <usb>\\Extracted\\WLAN_MediaTek\\WLAN\\mtkwecx.inf /install"
  info "afterwards by hand: BIOS 311 / firmware tools / Armoury Crate full package"
fi

exit $((FAIL > 0 ? 1 : 0))
