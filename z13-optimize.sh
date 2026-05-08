#!/usr/bin/env bash
# z13-optimize — tuning for the GZ302EA-RU004W (Strix Halo, 32 GB SKU).
#
# Idempotent: re-running is safe. Each change is gated on detection of the
# already-correct state.
#
# Changes:
#   1. Replace deprecated `amdgpu.gttsize=` (silently ignored on current
#      kernels) with the working `ttm.pages_limit` / `ttm.page_pool_size`,
#      sized at 20 GB. On a 32 GB SKU this fits any practical Strix Halo
#      LLM (~32B-class Q4) while leaving 12 GB for the OS+apps. Backs up
#      the systemd-boot entry first.
#   2. Mask systemd-networkd-wait-online (NM+iwd is the actual stack;
#      networkd-wait-online holds boot for ~7 s for nothing).
#   3. Enable systemd-oomd. PSI is available; on a 32 GB box running
#      large-model inference, the kernel OOM killer fires too late and
#      the system locks. oomd kills the worst offender earlier.
#   4. Bump vm.watermark_scale_factor 10 -> 100. Default starts reclaim
#      at ~32 MB free, which is too late under sudden GPU+CPU pressure
#      on UMA. Earlier reclaim = smoother zram swap-in.

set -euo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[-]%s %s\n' "$RED" "$RST" "$*"; exit 1; }

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

# 20 GB iGPU VRAM cap = 5242880 pages × 4 KB
TTM_PAGES=5242880

# ── 1. Bootloader cmdline ────────────────────────────────────────────────
ENTRY=$(ls /boot/loader/entries/*linux.conf 2>/dev/null | grep -v '\.bak' | head -1)
[[ -z "$ENTRY" ]] && fail "no systemd-boot entry found"

if grep -q "ttm.pages_limit=${TTM_PAGES}" "$ENTRY"; then
  ok "ttm.pages_limit=${TTM_PAGES} already in $ENTRY"
else
  info "patching $ENTRY"
  cp -a "$ENTRY" "${ENTRY}.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i -E "
    s/[[:space:]]*amdgpu\.gttsize=[0-9]+//g
    s/[[:space:]]*ttm\.pages_limit=[0-9]+//g
    s/[[:space:]]*ttm\.page_pool_size=[0-9]+//g
    s/[[:space:]]+\$//
  " "$ENTRY"
  sed -i -E "s|^(options .*)\$|\\1 ttm.pages_limit=${TTM_PAGES} ttm.page_pool_size=${TTM_PAGES}|" "$ENTRY"
  ok "patched: $(grep ^options "$ENTRY")"
fi

# ── 2. Mask networkd-wait-online ─────────────────────────────────────────
if [[ "$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)" == "masked" ]]; then
  ok "systemd-networkd-wait-online already masked"
else
  info "masking systemd-networkd-wait-online (~7 s boot saving)"
  systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl mask systemd-networkd-wait-online.service
  ok "masked"
fi

# ── 3. systemd-oomd ──────────────────────────────────────────────────────
if [[ "$(systemctl is-enabled systemd-oomd.service 2>/dev/null)" == "enabled" ]]; then
  ok "systemd-oomd already enabled"
else
  info "enabling systemd-oomd (PSI-driven userspace OOM, safer than kernel OOM under inference load)"
  systemctl enable --now systemd-oomd.service
  ok "enabled"
fi

# ── 4. watermark_scale_factor ────────────────────────────────────────────
SYSCTL=/etc/sysctl.d/99-gz302-32gb.conf
if [[ -f "$SYSCTL" ]] && grep -q 'watermark_scale_factor = 100' "$SYSCTL"; then
  ok "$SYSCTL already in place"
else
  info "writing $SYSCTL (earlier reclaim under UMA pressure)"
  cat >"$SYSCTL" <<'EOF'
# 32 GB SKU additions (paired with 99-gz302-zram.conf).
# Strix Halo's UMA + heavy iGPU allocations make late reclaim painful.
# Bumping watermark_scale_factor starts reclaim at ~320 MB free instead
# of ~32 MB, smoothing pressure spikes when LLMs page in/out of zram.
vm.watermark_scale_factor = 100
EOF
  sysctl --system >/dev/null
  ok "applied: vm.watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor)"
fi

echo
ok "Done. Reboot to pick up the new kernel cmdline."
echo
echo "After reboot, run /home/fool/z13-verify.sh"
