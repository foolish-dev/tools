#!/usr/bin/env bash
# z13-setup — pre-boot baseline for ASUS ROG Flow Z13 GZ302EA-RU004W
#
# Installs hardware-specific packages, udev rules, and reports kernel state.
# z13_Optimize.sh handles bootloader/systemd tuning that needs a reboot and
# idempotent re-checks.
#
# Idempotent: re-running is safe.

set -euo pipefail

PASS=0; FAIL=0; WARN=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n'    "$BLU" "$RST" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$*"; ((++PASS)); }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; ((++WARN)); }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; ((++FAIL)); }

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

info "Setting baseline for ASUS ROG Flow Z13 GZ302EA-RU004W (32 GB, Strix Halo)"

# ── 1. Hardware detection ────────────────────────────
info "detecting hardware…"

PRODUCT="$(cat /sys/devices/dmi/id/product_name 2>/dev/null || true)"
if [[ "$PRODUCT" == *"Z13"*"GZ302"* ]]; then
  ok "Z13 GZ302 family detected: $PRODUCT"
elif [[ "$PRODUCT" == *"Z13"* ]]; then
  warn "Z13 detected but not GZ302 ($PRODUCT) — continuing anyway"
else
  warn "product name does not identify a Z13 ($PRODUCT) — continuing anyway"
fi

if command -v lscpu &>/dev/null; then
  lscpu 2>/dev/null | grep -E '^(Model name|CPU\(s\)|Architecture)' | sed 's/^/  /'
fi

# ── 2. Required packages ──────────────────────────────
# Only packages that exist in the official Arch repos. amdvlk lives in the AUR;
# rocm-hip / rocm-hcc are deprecated meta-package names that no longer exist.
# hip-runtime-amd is the current name for the HIP runtime.
info "installing hardware-specific packages"

PACKAGES=(
  rocm-opencl-runtime
  rocm-device-libs
  hip-runtime-amd
)

for P in "${PACKAGES[@]}"; do
  if pacman -Qi "$P" &>/dev/null; then
    ok "$P already installed"
    continue
  fi
  if ! pacman -Si "$P" &>/dev/null; then
    fail "$P not available in repos"
    continue
  fi
  info "installing $P"
  if pacman -S --noconfirm --needed "$P"; then
    ok "$P installed"
  else
    fail "could not install $P"
  fi
done

info "note: amdvlk is an AUR package — install via your AUR helper if you need the open-source AMD Vulkan driver"

# ── 3. Kernel cmdline (informational) ────────────────
info "checking kernel boot params for Strix Halo features"
KERNELPARAMS=("iommu=pt" "amd_iommu=on")
for P in "${KERNELPARAMS[@]}"; do
  if grep -qw "$P" /proc/cmdline 2>/dev/null; then
    ok "$P present in /proc/cmdline"
  else
    warn "$P missing from /proc/cmdline (z13_Optimize.sh does not patch this; edit your bootloader entry if required)"
  fi
done

# ── 4. udev rules ─────────────────────────────────────
info "applying udev rules"
RULE=/etc/udev/rules.d/99-amdgpu-dpm.rules
if [[ -f "$RULE" ]]; then
  ok "$RULE already in place"
else
  cat > "$RULE" << 'EOF'
# Enable DPM for AMD GPUs on laptops
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", ATTR{device/power_dpm_force_performance_level}="auto"
EOF
  ok "installed $RULE"
fi

# ── 5. Summary ────────────────────────────────────────
echo
echo "── Setup summary ──"
if [[ $FAIL -eq 0 ]]; then
  ok "Setup finished with no errors (${WARN} warning(s))"
else
  warn "Some checks failed — review above before running z13_Optimize.sh"
fi

exit $FAIL
