#!/usr/bin/env bash
# z13 — setup + optimize for ASUS ROG Flow Z13 GZ302EA-RU004W
#
# Usage:
#   z13               setup, then reboot; run 'z13 --optimize' after
#   z13 --optimize    post-reboot optimization
#   z13 --no-reboot   setup + optimize inline (testing)

set -euo pipefail

FAIL=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[!!]%s %s\n' "$RED" "$RST" "$*"; ((++FAIL)); }

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

setup() {
  local prod; prod=$(cat /sys/devices/dmi/id/product_name 2>/dev/null || true)
  [[ "$prod" == *"Z13"*"GZ302"* ]] || warn "unexpected product: $prod"

  for pkg in rocm-opencl-runtime rocm-device-libs hip-runtime-amd; do
    pacman -Qi "$pkg" &>/dev/null && continue
    pacman -S --noconfirm --needed "$pkg" && ok "$pkg" || fail "$pkg"
  done

  for p in iommu=pt amd_iommu=on; do
    grep -qw "$p" /proc/cmdline || warn "$p missing from cmdline"
  done

  local rule=/etc/udev/rules.d/99-amdgpu-dpm.rules
  [[ -f "$rule" ]] || cat >"$rule" <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", ATTR{device/power_dpm_force_performance_level}="auto"
EOF
}

optimize() {
  local TTM=5242880  # 20 GB iGPU VRAM cap

  local entry
  entry=$(ls /boot/loader/entries/*linux.conf 2>/dev/null | grep -v '\.bak' | head -1 || true)
  [[ -n "$entry" ]] || { fail "no systemd-boot entry found"; return 1; }

  if ! grep -q "ttm.pages_limit=${TTM}" "$entry"; then
    cp -a "$entry" "${entry}.bak.$(date +%Y%m%d-%H%M%S)"
    sed -i -E \
      -e 's/[[:space:]]*(amdgpu\.gttsize|ttm\.pages_limit|ttm\.page_pool_size)=[0-9]+//g' \
      -e 's/[[:space:]]+$//' \
      "$entry"
    sed -i -E "s|^(options .*)|\1 ttm.pages_limit=${TTM} ttm.page_pool_size=${TTM}|" "$entry"
    ok "bootloader patched"
  fi

  [[ $(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null) == masked ]] || {
    systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
    systemctl mask systemd-networkd-wait-online.service && ok "networkd-wait-online masked"
  }

  [[ $(systemctl is-enabled systemd-oomd.service 2>/dev/null) == enabled ]] || {
    systemctl enable --now systemd-oomd.service && ok "systemd-oomd enabled"
  }

  local conf=/etc/sysctl.d/99-gz302-32gb.conf
  if ! grep -q 'watermark_scale_factor *= *100' "$conf" 2>/dev/null; then
    printf 'vm.watermark_scale_factor = 100\n' >"$conf"
    sysctl --system >/dev/null && ok "vm.watermark_scale_factor=100"
  fi

  # Verify
  local pages; pages=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)
  [[ $pages == "$TTM" ]] && ok "ttm.pages_limit=$TTM" || warn "ttm.pages_limit=$pages (reboot pending?)"
  [[ $(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null) == masked ]] \
    && ok "networkd-wait-online masked" || fail "networkd-wait-online not masked"
  systemctl is-active --quiet systemd-oomd && ok "systemd-oomd active" || fail "systemd-oomd not active"
  local wmsf; wmsf=$(sysctl -n vm.watermark_scale_factor)
  [[ $wmsf == 100 ]] && ok "vm.watermark_scale_factor=100" || fail "vm.watermark_scale_factor=$wmsf"
}

case "${1:-}" in
  "")          setup; [[ $FAIL -eq 0 ]] || exit $FAIL
               info "rebooting in 10s — run '$0 --optimize' after restart"
               sleep 10; shutdown -r now ;;
  --optimize)  optimize ;;
  --no-reboot) setup; [[ $FAIL -eq 0 ]] || exit $FAIL; optimize ;;
  *)           printf 'usage: %s [--optimize | --no-reboot]\n' "$0" >&2; exit 1 ;;
esac

exit $((FAIL > 0 ? 1 : 0))
