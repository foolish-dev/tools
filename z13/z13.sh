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

setup_rog_key() {
  local real_user="${SUDO_USER:-}"
  local aur_helper=""
  for h in yay paru pikaur; do command -v "$h" &>/dev/null && { aur_helper="$h"; break; }; done

  for pkg in asusctl rog-control-center; do
    pacman -Qi "$pkg" &>/dev/null && continue
    if [[ -n "$aur_helper" && -n "$real_user" ]]; then
      sudo -u "$real_user" "$aur_helper" -S --noconfirm --needed "$pkg" && ok "$pkg" || fail "$pkg"
    else
      warn "$pkg: install from AUR (yay/paru) then re-run"
    fi
  done

  mkdir -p /etc/asusd
  if pacman -Qi asusctl &>/dev/null; then
    systemctl enable --now asusd.service && ok "asusd" \
      || warn "asusd failed — evdev daemon will handle ROG key"
    local cfg=/etc/asusd/asusd.ron
    if [[ -f "$cfg" ]] && ! grep -q 'rog_key_action.*OpenRogControlCenter' "$cfg"; then
      cp -a "$cfg" "${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
      sed -i 's/rog_key_action:[[:space:]]*[A-Za-z]*/rog_key_action: OpenRogControlCenter/' "$cfg" \
        && ok "ROG key → rog-control-center (asusd)" \
        || warn "could not patch $cfg — set ROG key in rog-control-center GUI"
      systemctl restart asusd.service 2>/dev/null || true
    fi
  fi

  # Evdev daemon: grabs the ROG key input device directly.
  # Exits cleanly if asusd already owns the grab, so both can coexist.
  [[ -n "$real_user" ]] || { warn "SUDO_USER unset — evdev daemon skipped"; return; }
  local uid; uid=$(id -u "$real_user")
  local home; home=$(getent passwd "$real_user" | cut -d: -f6)

  if ! pacman -Qi python-evdev &>/dev/null; then
    pacman -S --noconfirm --needed python-evdev && ok "python-evdev" || { fail "python-evdev"; return; }
  fi

  cat >/etc/udev/rules.d/99-asus-rog-input.rules <<'EOF'
SUBSYSTEM=="input", ATTRS{name}=="*ASUS*", GROUP="input", MODE="0660"
SUBSYSTEM=="input", ATTRS{name}=="*Asus*", GROUP="input", MODE="0660"
EOF
  udevadm control --reload
  usermod -aG input "$real_user" && ok "$real_user → input group (re-login required)"

  mkdir -p /usr/local/lib/z13
  cat >/usr/local/lib/z13/rog-key-daemon <<'PYEOF'
#!/usr/bin/env python3
import evdev, glob, os, subprocess, sys, time

KEY = evdev.ecodes.KEY_PROG3  # asus-nb-wmi maps the ROG/Armoury Crate key here

def find_dev():
    for p in evdev.list_devices():
        try:
            d = evdev.InputDevice(p)
            if KEY in d.capabilities().get(evdev.ecodes.EV_KEY, []):
                if any(k in d.name.lower() for k in ('asus', 'rog', 'wmi', 'acpi')):
                    return d
        except Exception:
            pass
    return None

def launch_env():
    runtime = os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    env = {**os.environ, 'XDG_RUNTIME_DIR': runtime,
           'DBUS_SESSION_BUS_ADDRESS': f'unix:path={runtime}/bus'}
    # Prefer Wayland socket; fall back to X11
    sockets = [f for f in glob.glob(f'{runtime}/wayland-*') if not f.endswith('.lock')]
    if sockets:
        env['WAYLAND_DISPLAY'] = os.path.basename(sockets[0])
        env.pop('DISPLAY', None)
    else:
        env['DISPLAY'] = os.environ.get('DISPLAY', ':0')
    return env

while True:
    while True:
        dev = find_dev()
        if dev:
            break
        time.sleep(2)

    try:
        dev.grab()
    except OSError:
        sys.exit(0)  # asusd already owns the device; nothing to do

    env = launch_env()
    try:
        for ev in dev.read_loop():
            if ev.type == evdev.ecodes.EV_KEY and ev.code == KEY and ev.value == 1:
                subprocess.Popen(['rog-control-center'], env=env)
    except OSError:
        pass  # device lost (e.g. suspend/resume); re-discover and re-grab
PYEOF
  chmod +x /usr/local/lib/z13/rog-key-daemon

  local svc="$home/.config/systemd/user/rog-key-daemon.service"
  local wants="$home/.config/systemd/user/graphical-session.target.wants"
  mkdir -p "$wants"
  cat >"$svc" <<EOF
[Unit]
Description=ROG key → rog-control-center
After=graphical-session.target

[Service]
ExecStart=/usr/local/lib/z13/rog-key-daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
  ln -sf "$svc" "$wants/rog-key-daemon.service"
  chown -R "$real_user:$real_user" "$home/.config/systemd"
  ok "rog-key-daemon user service enabled"
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
  [[ -f "$rule" ]] || cat >"$rule" <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", ATTR{device/power_dpm_force_performance_level}="auto"
EOF

  setup_rog_key
}

optimize() {
  local TTM=5242880  # 20 GB iGPU VRAM cap

  local entry=""
  for f in /boot/loader/entries/*linux.conf; do
    [[ "$f" == *.bak.* ]] && continue
    [[ -f "$f" ]] && { entry="$f"; break; }
  done
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

  pacman -Qi asusctl &>/dev/null && {
    systemctl is-active --quiet asusd || { systemctl start asusd && ok "asusd started"; }
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

  pacman -Qi asusctl &>/dev/null && {
    systemctl is-active --quiet asusd && ok "asusd active" || warn "asusd not active (evdev daemon covers ROG key)"
  }
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
