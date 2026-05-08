#!/usr/bin/env bash
# z13-verify — confirm z13-optimize.sh changes took effect after reboot.
set -u
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; RST=$'\033[0m'
pass() { printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }

EXPECTED_PAGES=5242880  # 20 GB

limit=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)
if [[ "$limit" == "$EXPECTED_PAGES" ]]; then
  pass "ttm.pages_limit = $limit pages (20 GB iGPU VRAM cap)"
else
  fail "ttm.pages_limit = $limit (expected $EXPECTED_PAGES)"
fi

if grep -q 'amdgpu.gttsize' /proc/cmdline; then
  fail "amdgpu.gttsize still in /proc/cmdline (deprecated, no-op)"
else
  pass "amdgpu.gttsize removed from cmdline"
fi
if grep -q 'ttm.pages_limit' /proc/cmdline; then
  pass "ttm.pages_limit present in cmdline"
else
  fail "ttm.pages_limit missing from cmdline (reboot pending?)"
fi

if [[ "$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)" == "masked" ]]; then
  pass "systemd-networkd-wait-online masked"
else
  fail "systemd-networkd-wait-online not masked"
fi

if systemctl is-active --quiet systemd-oomd.service; then
  pass "systemd-oomd active"
else
  fail "systemd-oomd not active"
fi

wmsf=$(sysctl -n vm.watermark_scale_factor)
if [[ "$wmsf" == "100" ]]; then
  pass "vm.watermark_scale_factor = 100"
else
  fail "vm.watermark_scale_factor = $wmsf (expected 100)"
fi

echo
echo "Top 5 systemd boot offenders:"
systemd-analyze blame 2>/dev/null | head -5 | sed 's/^/  /'

echo
gpu_pool=$(rocminfo 2>/dev/null | awk '/Name:.*gfx1151/{f=1} f && /Pool 1/{f=2} f==2 && /Size:/{print $0; exit}')
[[ -n "$gpu_pool" ]] && pass "iGPU memory pool: $gpu_pool" || warn "could not read iGPU memory pool from rocminfo"
