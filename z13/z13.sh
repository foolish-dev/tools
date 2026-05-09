#!/usr/bin/env bash
# z13 — setup + optimize for ASUS ROG Flow Z13 GZ302EA-RU004W
#
# Usage:
#   z13               setup, then reboot; run 'z13 --optimize' after
#   z13 --optimize    post-reboot optimization
#   z13 --no-reboot   setup + optimize inline (testing)
#   z13 --status      verify current state without making changes
#   z13 --fix-touchpad  rebind/uninhibit touchpad frozen by armoury crate

set -euo pipefail

FAIL=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!!]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[!!]%s %s\n' "$RED" "$RST" "$*"; : $((++FAIL)); }

trap 'printf "%s[ERR]%s line %d: %s\n" "$RED" "$RST" "$LINENO" "$BASH_COMMAND" >&2' ERR

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

readonly TTM=5242880  # 20 GiB iGPU VRAM cap (pages × 4 KiB)

_ROG_KEY_DONE=0

setup_rog_key() {
  if [[ $_ROG_KEY_DONE -eq 1 ]]; then return; fi
  _ROG_KEY_DONE=1

  local real_user="${SUDO_USER:-}"
  [[ -n "$real_user" ]] || { warn "SUDO_USER unset — ROG key setup skipped"; return; }

  if ! command -v z13ctl &>/dev/null; then
    warn "z13ctl not found — ROG key setup skipped"
    return
  fi

  local rules=/etc/udev/rules.d/99-z13ctl.rules
  local svc=/etc/systemd/system/z13ctl-perms.service
  local dropin_dir=/etc/systemd/system/z13ctl-perms.service.d
  local dropin=${dropin_dir}/ryzen-smu.conf
  local rules_changed=0 perms_changed=0

  # z13ctl setup writes 99-z13ctl.rules granting the group access to all ASUS
  # devices (HID RGB, Armoury Crate button, platform-profile, battery threshold,
  # asus-armoury attrs, fan curve, TDP) and installs z13ctl-perms.service for
  # the battery attribute that appears late in the asus_nb_wmi probe sequence.
  if [[ ! -f "$rules" ]] || ! grep -q 'GROUP="input"' "$rules"; then
    if z13ctl setup --group input; then
      ok "z13ctl udev rules installed/updated"
      rules_changed=1
      perms_changed=1  # z13ctl setup may have (re)installed z13ctl-perms.service
    else
      fail "z13ctl setup"
    fi
  fi

  # Safety: z13ctl setup may emit the perms service with the wrong group.
  if [[ -f "$svc" ]] && grep -q 'chgrp users' "$svc"; then
    cp -a "$svc" "${svc}.bak"
    sed -i 's/chgrp users/chgrp input/g' "$svc"
    ok "z13ctl-perms.service: corrected group users→input"
    perms_changed=1
  fi

  # Move ryzen_smu perms into a drop-in so future z13ctl setup runs can't erase them.
  # `$$f` is systemd's escape for a literal `$f` — sh -c then expands it as a shell var.
  if [[ ! -f "$dropin" ]]; then
    mkdir -p "$dropin_dir"
    cat >"$dropin" <<'EOF'
[Service]
ExecStart=/bin/sh -c 'for f in /sys/kernel/ryzen_smu_drv/smu_args /sys/kernel/ryzen_smu_drv/mp1_smu_cmd /sys/kernel/ryzen_smu_drv/rsmu_cmd; do [ -e "$$f" ] && chgrp input "$$f" && chmod g+w "$$f" || true; done'
EOF
    ok "z13ctl-perms: ryzen_smu drop-in installed"
    perms_changed=1
  fi

  if [[ $perms_changed -eq 1 ]]; then
    systemctl daemon-reload
    systemctl restart z13ctl-perms.service && ok "z13ctl-perms.service restarted"
  fi

  if [[ $rules_changed -eq 1 ]]; then
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=input --subsystem-match=hidraw
    ok "udev rules reloaded"
  fi

  if ! id -nG "$real_user" | grep -qw input; then
    usermod -aG input "$real_user" && ok "$real_user → input group (re-login required)"
  fi

  setup_touchpad_rebind
}

setup_touchpad_rebind() {
  local rule=/etc/udev/rules.d/99-z13-touchpad.rules
  [[ -f "$rule" ]] && grep -q 'hid-multitouch/bind' "$rule" && return
  # When z13ctl opens the ASUS HID control interface the MCU sometimes resets,
  # causing the touchpad to reconnect bound to hid-generic instead of
  # hid-multitouch.  This rule catches that bind event and corrects it.
  cat >"$rule" <<'EOF'
ACTION=="bind", SUBSYSTEM=="hid", DRIVER=="hid-generic", ATTRS{idVendor}=="0b05", ATTRS{name}=="*[Tt]ouchpad*", RUN+="/bin/sh -c 'modprobe hid_multitouch; echo %k >/sys/bus/hid/drivers/hid-generic/unbind; echo %k >/sys/bus/hid/drivers/hid-multitouch/bind'"
EOF
  ok "touchpad rebind rule installed"
  udevadm control --reload-rules
}

fix_touchpad() {
  # HID path: rebind USB touchpad from hid-generic → hid-multitouch
  local any=0
  local dev name id drv
  for dev in /sys/bus/hid/devices/*/; do
    name=$(cat "${dev}name" 2>/dev/null || true)
    [[ "$name" == *[Tt]ouchpad* ]] || continue
    any=1
    id=$(basename "$dev")
    drv=none; [[ -L "${dev}driver" ]] && drv=$(basename "$(readlink -f "${dev}driver")")
    if [[ "$drv" == hid-generic ]]; then
      modprobe hid_multitouch 2>/dev/null || true
      echo "$id" >/sys/bus/hid/drivers/hid-generic/unbind 2>/dev/null || true
      echo "$id" >/sys/bus/hid/drivers/hid-multitouch/bind 2>/dev/null \
        && ok "touchpad rebound to hid-multitouch: $name" || fail "rebind failed: $name"
    elif [[ "$drv" == hid-multitouch ]]; then
      ok "touchpad already on hid-multitouch: $name"
    else
      warn "touchpad driver=$drv: $name"
    fi
  done

  # input path: uninhibit if kernel-inhibited (covers I2C and USB)
  local inh nm
  for inh in /sys/class/input/*/device/inhibited; do
    [[ -f "$inh" ]] || continue
    nm=$(cat "$(dirname "$(dirname "$inh")")/name" 2>/dev/null || true)
    [[ "$nm" == *[Tt]ouchpad* ]] || continue
    any=1
    if [[ $(cat "$inh") == 1 ]]; then
      echo 0 >"$inh" && ok "touchpad uninhibited: $nm" || fail "uninhibit failed: $nm"
    else
      ok "touchpad not inhibited: $nm"
    fi
  done

  [[ $any -eq 0 ]] && warn "no touchpad found"
}

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
  if [[ ! -f "$rule" ]]; then
    cat >"$rule" <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", ATTR{device/power_dpm_force_performance_level}="auto"
EOF
    udevadm control --reload-rules
    # Rule fires on add; cards are already added, so set existing ones directly.
    local lvl
    for lvl in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
      [[ -w "$lvl" ]] && echo auto >"$lvl" 2>/dev/null || true
    done
    ok "amdgpu DPM udev rule created"
  fi

  setup_rog_key
}

status() {
  local pages; pages=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)
  local pool;  pool=$(cat /sys/module/ttm/parameters/page_pool_size 2>/dev/null || echo 0)
  if [[ $pages == "$TTM" ]]; then ok "ttm.pages_limit=$TTM"; else warn "ttm.pages_limit=$pages (reboot pending?)"; fi
  if [[ $pool  == "$TTM" ]]; then ok "ttm.page_pool_size=$TTM"; else warn "ttm.page_pool_size=$pool (reboot pending?)"; fi

  if [[ $(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null) == masked ]]; then
    ok "networkd-wait-online masked"
  else
    fail "networkd-wait-online not masked"
  fi

  if systemctl is-active --quiet systemd-oomd; then ok "systemd-oomd active"; else fail "systemd-oomd not active"; fi

  local wmsf; wmsf=$(sysctl -n vm.watermark_scale_factor 2>/dev/null || echo 0)
  if [[ $wmsf == 100 ]]; then ok "vm.watermark_scale_factor=100"; else fail "vm.watermark_scale_factor=$wmsf"; fi

  local f
  for f in /boot/loader/entries/*linux.conf; do
    [[ "$f" == *.bak* ]] && continue
    [[ -f "$f" ]] || continue
    if grep -q "ttm.pages_limit=${TTM}" "$f"; then
      ok "bootloader patched: $(basename "$f")"
    else
      warn "bootloader not patched: $(basename "$f")"
    fi
  done

  local tp_found=0
  local dev name drv
  for dev in /sys/bus/hid/devices/*/; do
    name=$(cat "${dev}name" 2>/dev/null || true)
    [[ "$name" == *[Tt]ouchpad* ]] || continue
    tp_found=1
    drv=none; [[ -L "${dev}driver" ]] && drv=$(basename "$(readlink -f "${dev}driver")")
    case "$drv" in
      hid-multitouch) ok  "touchpad: hid-multitouch ($name)" ;;
      hid-generic)    fail "touchpad: hid-generic — needs rebind ($name)" ;;
      *)              warn "touchpad: driver=$drv ($name)" ;;
    esac
  done
  [[ $tp_found -eq 0 ]] && warn "touchpad not found in HID devices (may be I2C)"

  if command -v z13ctl &>/dev/null; then
    local rules=/etc/udev/rules.d/99-z13ctl.rules
    if [[ -f "$rules" ]] && grep -q 'GROUP="input"' "$rules"; then
      ok "z13ctl rules: GROUP=input"
    else
      fail "z13ctl rules missing or wrong group"
    fi
    local dropin=/etc/systemd/system/z13ctl-perms.service.d/ryzen-smu.conf
    if [[ -f "$dropin" ]]; then
      ok "z13ctl-perms: ryzen_smu drop-in present"
    else
      warn "z13ctl-perms: ryzen_smu drop-in missing"
    fi
    local real_user="${SUDO_USER:-}"
    if [[ -n "$real_user" ]]; then
      if id -nG "$real_user" | grep -qw input; then
        ok "$real_user in input group"
      else
        fail "$real_user not in input group"
      fi
    fi
  else
    warn "z13ctl not installed"
  fi

  [[ $FAIL -eq 0 ]] && ok "all checks passed" || true
}

optimize() {
  setup_rog_key

  local -a entries=()
  local f
  for f in /boot/loader/entries/*linux.conf; do
    [[ "$f" == *.bak* ]] && continue
    [[ -f "$f" ]] && entries+=("$f")
  done
  [[ ${#entries[@]} -gt 0 ]] || { fail "no systemd-boot entry found"; return 1; }

  local entry
  for entry in "${entries[@]}"; do
    if ! grep -q "ttm.pages_limit=${TTM}" "$entry"; then
      cp -a "$entry" "${entry}.bak"
      sed -i -E \
        -e 's/[[:space:]]*(amdgpu\.gttsize|ttm\.pages_limit|ttm\.page_pool_size)=[0-9]+//g' \
        -e 's/[[:space:]]+$//' \
        "$entry"
      sed -i -E "s|^(options .*)|\1 ttm.pages_limit=${TTM} ttm.page_pool_size=${TTM}|" "$entry"
      ok "bootloader patched: $(basename "$entry")"
    fi
  done

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

  status
}

case "${1:-}" in
  "")          setup; [[ $FAIL -eq 0 ]] || exit $FAIL
               info "rebooting in 10s — run '$0 --optimize' after restart"
               sleep 10; shutdown -r now ;;
  --optimize)  optimize ;;
  --no-reboot) setup; [[ $FAIL -eq 0 ]] || exit $FAIL; optimize ;;
  --status)       status ;;
  --fix-touchpad) fix_touchpad; [[ $FAIL -eq 0 ]] && ok "touchpad OK" || true ;;
  *)              printf 'usage: %s [--optimize | --no-reboot | --status | --fix-touchpad]\n' "$0" >&2; exit 1 ;;
esac

exit $((FAIL > 0 ? 1 : 0))
