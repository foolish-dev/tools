#!/usr/bin/env bash
# z13-optimize  —  tuning for the GZ302EA-RU004W (Strix Halo, 32 GB SKU)
#
# Idempotent: re-running is safe. Each change is gated on detection of the
# already-correct state.

set -euo pipefail

echo '─── z13-optimization ───'

PASS=0; FAIL=0; WARN=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n'    "$BLU" "$RST" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$*"; ((++PASS)); }
inok() { :; }  # idempotent no-op for already-correct states
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; ((++FAIL)); }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; ((++WARN)); }

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

# ── 1. Bootloader cmdline ────────────────────────────────────────
TTM_PAGES=5242880  # 20 GB iGPU VRAM cap
ENTRY=$(ls /boot/loader/entries/*linux.conf 2>/dev/null | grep -v '\.bak' | head -1 || true)
if [[ -z "$ENTRY" ]]; then
  fail "no systemd-boot entry found in /boot/loader/entries/*linux.conf"
  exit 1
fi

if grep -q "ttm.pages_limit=${TTM_PAGES}" "$ENTRY"; then
  inok "ttm.pages_limit=${TTM_PAGES} already in $ENTRY"
else
  info "patching $ENTRY"
  cp -a "$ENTRY" "${ENTRY}.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i -E \
    -e 's/[[:space:]]*amdgpu\.gttsize=[0-9]+//g' \
    -e 's/[[:space:]]*ttm\.pages_limit=[0-9]+//g' \
    -e 's/[[:space:]]*ttm\.page_pool_size=[0-9]+//g' \
    -e 's/[[:space:]]+$//' \
    "$ENTRY"
  sed -i -E "s|^(options .*)\$|\\1 ttm.pages_limit=${TTM_PAGES} ttm.page_pool_size=${TTM_PAGES}|" "$ENTRY"
  ok "patched: $(grep ^options "$ENTRY")"
fi

# ── 2. Mask networkd-wait-online ─────────────────────────────────
if [[ "$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)" == "masked" ]]; then
  inok "systemd-networkd-wait-online already masked"
else
  info "masking systemd-networkd-wait-online"
  systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl mask systemd-networkd-wait-online.service
  ok "masked systemd-networkd-wait-online"
fi

# ── 3. systemd-oomd ─────────────────────────────────────────────
if [[ "$(systemctl is-enabled systemd-oomd.service 2>/dev/null)" == "enabled" ]]; then
  inok "systemd-oomd already enabled"
else
  info "enabling systemd-oomd (PSI-driven userspace OOM)"
  systemctl enable --now systemd-oomd.service
  ok "enabled systemd-oomd"
fi

# ── 4. watermark_scale_factor ─────────────────────────────────────
SYSCTL=/etc/sysctl.d/99-gz302-32gb.conf
if [[ -f "$SYSCTL" ]] && grep -q 'watermark_scale_factor *= *100' "$SYSCTL"; then
  inok "$SYSCTL already in place"
else
  info "writing $SYSCTL"
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
if [[ $FAIL -eq 0 ]]; then
  ok "All optimization steps passed (${PASS} change(s), ${WARN} warning(s))"
else
  warn "Done with ${FAIL} failure(s) — review above"
fi

# ── verification (post-reboot) ────────────────────────────────────
echo
echo '─── Running verification ───'
verify() {
  local vpass=0 vfail=0

  local pages_limit
  pages_limit=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)
  if [[ "$pages_limit" == "$TTM_PAGES" ]]; then
    ok "ttm.pages_limit = ${pages_limit} (20 GB cap)"; ((++vpass))
  else
    fail "ttm.pages_limit = ${pages_limit} (expected ${TTM_PAGES} — reboot pending?)"; ((++vfail))
  fi

  if grep -q 'ttm.pages_limit' /proc/cmdline; then
    ok "ttm.pages_limit present in /proc/cmdline"; ((++vpass))
  else
    fail "ttm.pages_limit missing from /proc/cmdline (reboot pending?)"; ((++vfail))
  fi

  if [[ "$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)" == "masked" ]]; then
    ok "systemd-networkd-wait-online masked"; ((++vpass))
  else
    fail "systemd-networkd-wait-online not masked"; ((++vfail))
  fi

  if systemctl is-active --quiet systemd-oomd.service; then
    ok "systemd-oomd active"; ((++vpass))
  else
    fail "systemd-oomd not active"; ((++vfail))
  fi

  local wmsf
  wmsf=$(sysctl -n vm.watermark_scale_factor)
  if [[ "$wmsf" == "100" ]]; then
    ok "vm.watermark_scale_factor = 100"; ((++vpass))
  else
    fail "vm.watermark_scale_factor = ${wmsf} (expected 100)"; ((++vfail))
  fi

  echo
  echo 'Top systemd boot offenders:'
  systemd-analyze blame 2>/dev/null | head -5 | sed 's/^/  /' || echo '  (unavailable)'
  echo

  if command -v rocminfo &>/dev/null; then
    local gpu_pool
    gpu_pool=$(rocminfo 2>/dev/null | awk '/Name:.*gfx1151/{f=1} f && /Pool 1/{f=2} f==2 && /Size:/{print; exit}')
    if [[ -n "$gpu_pool" ]]; then
      ok "iGPU memory pool: ${gpu_pool}"
    else
      warn "could not read iGPU memory pool from rocminfo"
    fi
  else
    warn "rocminfo not installed — skipping iGPU pool check"
  fi

  echo
  echo "Verification: ${vpass} passed, ${vfail} failed"
  return $vfail
}

if [[ $FAIL -eq 0 ]]; then
  info "Running full verification checks"
  verify || true
else
  info "There were optimization failures above; fix those before verifying"
fi

exit $((FAIL > 0 ? 1 : 0))
