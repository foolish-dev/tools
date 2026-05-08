#!/usr/bin/env bash
# ====================================================================
# z13.sh
# ASUS ROG Flow Z13 GZ302EA-RU004W (Strix Halo, 32GB)
# Modes: optimize  —  verify
# Run as your normal user (yay needs to build as user).
# ====================================================================
set -euo pipefail

MODE="${1:-optimize}"
[ "$MODE" == "verify" ] && shift || true
[ "$MODE" ~= ^(optimize|verify)$ ] || die "Usage: $0 {optimize|verify}"

# -- Colors --
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; X=$'\e[0m'
log()  { printf "${B}[*]${X} %s\n" "$*"; }
ok()   { printf "${G}[+]${X} %s\n" "$*"; }
warn() { printf "${Y}[!]${X} %s\n" "$*"; }
die()  { printf "${R}[x]${X} %s\n" "$*"; exit 1; }

# == MODE: OPTIMIZE ==

OPTIMIZED=0
if [[ "$MODE" == "optimize" ]]; then

  # -- Pre-flight --
  [[ $EUID -eq 0 ]]   && die "Run as your normal user."
  command -v yay >/dev/null || die "yay required."

  log "Caching sudo credentials (single prompt)..."
  sudo -v || die "sudo failed."

  # Keep sudo cache alive for the duration of the script
  ( while true; do sudo -n true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
  KEEPALIVE=$!
  trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

  # 1. KERNEL PARAMETERS
  log "Tuning kernel parameters..."
  ENTRY=$(ls /boot/loader/entries/*linux.conf 2>/dev/null | grep -v fallback | head -1)
  [[ -z "$ENTRY" ]] && die "No systemd-boot entry found."
  sudo cp -n "$ENTRY" "${ENTRY}.bak.$(date +%Y%m%d-%H%M%S)" || true
  ok  "Backup: ${ENTRY}.bak.*"

  add_param() {
    local p="$1"
    if ! sudo grep -q "$p" "$ENTRY"; then
      sudo sed -i "s|^options |options $p |" "$ENTRY"
      ok  "Added: $p"
    else
      log "Already present: $p"
    fi
  }

  add_param "amd_pstate=active"
  add_param "iommu=pt"
  add_param "nvme.noacpi=1"

  # gttsize deprecated — moved to ttm.pages_limit via sysfs
  # (amdgpu.gttsize=24576 left in cmdline for old kernels but ignored)

  log "Final boot options:"
  grep "^options" "$ENTRY"

  # 2. PACKAGES
  log "Installing repo packages..."
  sudo pacman -S --needed --noconfirm \
    fwupd \
    rocm-hip-sdk \
    rocm-ml-sdk \
    rocm-smi-lib \
    rocm-opencl-runtime \
    hipblas \
    python-pip \
    python-virtualenv

  # Replace ollama with ollama-rocm if needed
  if pacman -Q ollama &>/dev/null && ! pacman -Q ollama-rocm &>/dev/null; then
    log "Replacing ollama (CPU) with ollama-rocm..."
    sudo systemctl stop ollama 2>/dev/null || true
    sudo pacman -S --noconfirm ollama-rocm
    ok  "ollama-rocm installed."
  else
    pacman -Q ollama-rocm &>/dev/null && log "ollama-rocm already installed."
  fi

  log "Installing AUR / chaotic-aur packages (asusctl stack)..."
  yay -S --needed --noconfirm \
    asusctl \
    supergfxctl \
    rog-control-center

  # Open WebUI — heavy AUR build, prompt confirmation
  if ! pacman -Q open-webui &>/dev/null; then
    warn "Open WebUI is a heavy AUR build (~10-15 min)."
    read -r -p "Install Open WebUI now? [y/N] " r
    if [[ "$r" =~ ^[Yy]$ ]]; then
      yay -S --needed --noconfirm open-webui
    else
      log "Skipping Open WebUI. Install later with: yay -S open-webui"
    fi
  fi

  # 3. OLLAMA OVERRIDE
  log "Configuring Ollama for gfx1151..."
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="HSA_OVERRIDE_GFX_VERSION=11.5.1"
Environment="HCC_AMDGPU_TARGET=gfx1151"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF
  ok  "Override written."
  sudo systemctl daemon-reload

  # 4. SERVICES
  log "Enabling services..."
  for svc in fwupd power-profiles-daemon asusd supergfxd ollama; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      sudo systemctl enable --now "$svc" 2>/dev/null && ok "$svc enabled" || warn "$svc failed (non-fatal)"
    fi
  done

  # Open WebUI service if installed
  if systemctl list-unit-files open-webui.service &>/dev/null; then
    sudo systemctl enable --now open-webui && ok "open-webui enabled at http://localhost:8080"
  fi

  # 5. CHARGE LIMIT + POWER PROFILE
  log "Setting battery + power profile..."
  asusctl -c 80 2>/dev/null && ok "Charge limit: 80%" || warn "asusctl -c failed (try after reboot)"
  asusctl profile -P Balanced 2>/dev/null && ok "Profile: Balanced" || true

  # 6. FIRMWARE
  log "Checking firmware updates..."
  sudo fwupdmgr refresh --force 2>&1 | tail -3 || true
  echo "--- Available updates ---"
  sudo fwupdmgr get-updates 2>&1 | tail -10 || true
  warn "Run 'sudo fwupdmgr update' manually after reviewing the above."

  OPTIMIZED=1

fi

# == MODE: VERIFY (or post-optimize verification) ==
VERIFY=0
if [[ "$MODE" == "verify" ]]; then VERIFY=1; fi
if [[ -z "${VERIFY+x}" ]] && [[ "${1:-}" == "verify" ]]; then VERIFY=1; fi

if [[ "$VERIFY" == 1 ]]; then
  log "Verifying settings..."
  EXPECTED_PAGES=5242880  # 20 GB

  fail_count=0

  limit=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)
  if [[ "$limit" == "$EXPECTED_PAGES" ]]; then
    ok "ttm.pages_limit = $limit pages (20 GB iGPU VRAM cap)"
  else
    fail "ttm.pages_limit = $limit (expected $EXPECTED_PAGES)"; ((fail_count++))
  fi

  if grep -q 'amdgpu.gttsize' /proc/cmdline; then
    fail "amdgpu.gttsize still in /proc/cmdline (deprecated, no-op)"; ((fail_count++))
  else
    ok "amdgpu.gttsize removed from cmdline"
  fi
  if grep -q 'ttm.pages_limit' /proc/cmdline; then
    ok "ttm.pages_limit present in cmdline"
  else
    fail "ttm.pages_limit missing from cmdline (reboot pending?)"; ((fail_count++))
  fi

  if [[ "$(systemctl is-enabled systemd-networkd-wait-online.service 2>/dev/null)" == "masked" ]]; then
    ok "systemd-networkd-wait-online masked"
  else
    fail "systemd-networkd-wait-online not masked"; ((fail_count++))
  fi

  if systemctl is-active --quiet systemd-oomd.service; then
    ok "systemd-oomd active"
  else
    fail "systemd-oomd not active"; ((fail_count++))
  fi

  wmsf=$(sysctl -n vm.watermark_scale_factor)
  if [[ "$wmsf" == "100" ]]; then
    ok "vm.watermark_scale_factor = 100"
  else
    fail "vm.watermark_scale_factor = $wmsf (expected 100)"; ((fail_count++))
  fi

  echo
  echo "Top 5 systemd boot offenders:"
  systemd-analyze blame 2>/dev/null | head -5 | sed 's/^/  /'

  echo
  gpu_pool=$(rocminfo 2>/dev/null | awk '/Name:.*gfx1151/{f=1} f && /Pool 1/{f=2} f==2 && /Size:/{print $0; exit}')
  [[ -n "$gpu_pool" ]] && ok "iGPU memory pool: $gpu_pool" || warn "could not read iGPU memory pool from rocminfo"

  if [[ "$fail_count" -gt 0 ]]; then
    echo
    warn "$fail_count check(s) failed — you probably need to reboot."
    exit 1
  fi

  ok "All checks passed! (if you recently optimized, you may need to reboot)"
  exit 0
fi

# == SUMMARY (run only if optimized, not verify-mode) ==
if [[ "$OPTIMIZED" == 1 ]]; then

echo
echo "Install complete. Manual steps remaining:"
echo

cat <<'EOF'

  1. REBOOT to activate kernel parameters and ROCm.

  2. AT REBOOT, enter BIOS (F2 / Del) and set:
       Advanced -> AMD CBS -> NBIO -> GFX Config
         UMA Frame Buffer Size : Auto (or smallest available)

     This lets the iGPU borrow up to 24GB of system RAM dynamically
     instead of permanently locking VRAM away from the OS.

  3. AFTER REBOOT, pull the recommended model:
       ollama pull qwen2.5:14b-instruct-q5_K_M
       ollama create qwen14 -f ~/Modelfile-qwen
       ollama run qwen14

  4. Verify everything with:
       z13.sh verify

EOF
fi
