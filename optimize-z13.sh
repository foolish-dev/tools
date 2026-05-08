#!/usr/bin/env bash
# =============================================================================
# optimize-z13.sh
# ASUS ROG Flow Z13 GZ302EA-RU004W (Strix Halo, 32GB) — AI/productivity tuning
# Run as your normal user. Will prompt for sudo password once.
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

# -- Colors --
R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; X=$'\e[0m'
log()  { printf "${B}[*]${X} %s\n" "$*"; }
ok()   { printf "${G}[+]${X} %s\n" "$*"; }
warn() { printf "${Y}[!]${X} %s\n" "$*"; }
die()  { printf "${R}[x]${X} %s\n" "$*"; exit 1; }

# -- Pre-flight --
[[ $EUID -eq 0 ]]   && die "Run as your normal user (yay needs to build as user)."
command -v yay >/dev/null || die "yay required."

log "Caching sudo credentials (single prompt)..."
sudo -v || die "sudo failed."

# Keep sudo cache alive for the duration of the script
( while true; do sudo -n true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

# =============================================================================
# 1. KERNEL PARAMETERS — systemd-boot entry
# =============================================================================
log "Tuning kernel parameters..."

ENTRY=$(ls /boot/loader/entries/*linux.conf 2>/dev/null | grep -v fallback | head -1)
[[ -z "$ENTRY" ]] && die "No systemd-boot entry found."

sudo cp -n "$ENTRY" "${ENTRY}.bak.$(date +%Y%m%d-%H%M%S)" || true
ok  "Backup: ${ENTRY}.bak.*"

# Add params idempotently (only if missing)
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
add_param "amdgpu.gttsize=24576"
add_param "iommu=pt"
add_param "nvme.noacpi=1"

log "Final boot options:"
grep "^options" "$ENTRY"

# =============================================================================
# 2. PACKAGES — repo + AUR
# =============================================================================
log "Installing repo packages (ROCm + firmware tools)..."
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
  warn "Open WebUI is a heavy AUR build (Python + frontend assets, ~10-15 min)."
  read -r -p "Install Open WebUI now? [y/N] " r
  if [[ "$r" =~ ^[Yy]$ ]]; then
    yay -S --needed --noconfirm open-webui
  else
    log "Skipping Open WebUI. Install later with: yay -S open-webui"
  fi
fi

# =============================================================================
# 3. OLLAMA — systemd override for gfx1151 + 32GB tuning
# =============================================================================
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

# =============================================================================
# 4. SERVICES
# =============================================================================
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

# =============================================================================
# 5. CHARGE LIMIT + POWER PROFILE
# =============================================================================
log "Setting battery + power profile..."
asusctl -c 80 2>/dev/null && ok "Charge limit: 80%" || warn "asusctl -c failed (try after reboot)"
asusctl profile -P Balanced 2>/dev/null && ok "Profile: Balanced" || true

# =============================================================================
# 6. FIRMWARE
# =============================================================================
log "Checking firmware updates..."
sudo fwupdmgr refresh --force 2>&1 | tail -3 || true
echo "--- Available updates ---"
sudo fwupdmgr get-updates 2>&1 | tail -10 || true
warn "Run 'sudo fwupdmgr update' manually after reviewing the above."

# =============================================================================
# 7. SUMMARY
# =============================================================================
echo
ok "=========================================================================="
ok "                   Install complete. Manual steps remaining:"
ok "=========================================================================="
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
       ~/check-z13.sh

EOF
