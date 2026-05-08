#!/usr/bin/env bash
# finish-z13.sh — completes the optimization after the Open WebUI nodejs conflict.
# Skips Open WebUI (incompatible with your Node.js current install).
# Run as your normal user.

set -euo pipefail

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; X=$'\e[0m'
log()  { printf "${B}[*]${X} %s\n" "$*"; }
ok()   { printf "${G}[+]${X} %s\n" "$*"; }
warn() { printf "${Y}[!]${X} %s\n" "$*"; }
die()  { printf "${R}[x]${X} %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] && die "Run as your normal user."

log "Caching sudo..."
sudo -v || die "sudo failed"
( while true; do sudo -n true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null || true' EXIT

# =============================================================================
# 1. Fix asusd — needs /etc/asusd directory
# =============================================================================
log "Creating /etc/asusd (asusd unit requires it)..."
sudo mkdir -p /etc/asusd
sudo systemctl reset-failed asusd
ok "asusd state reset"

# =============================================================================
# 2. Replace ollama gpu.conf (was Vulkan, switch to ROCm)
# =============================================================================
log "Replacing ollama gpu.conf with ROCm config..."

if [[ -f /etc/systemd/system/ollama.service.d/gpu.conf ]]; then
  sudo mv /etc/systemd/system/ollama.service.d/gpu.conf \
          /etc/systemd/system/ollama.service.d/gpu.conf.bak
  ok "Old Vulkan config backed up to gpu.conf.bak"
fi

sudo tee /etc/systemd/system/ollama.service.d/gpu.conf >/dev/null <<'EOF'
# ROCm config for Strix Halo / Radeon 8060S (gfx1151)
# Used by ollama-rocm.
[Service]
Environment="HSA_OVERRIDE_GFX_VERSION=11.5.1"
Environment="HCC_AMDGPU_TARGET=gfx1151"
Environment="ROCR_VISIBLE_DEVICES=0"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF

sudo systemctl daemon-reload
ok "ROCm config written, daemon reloaded"

# =============================================================================
# 3. Enable + start services
# =============================================================================
log "Enabling services..."
for svc in fwupd asusd supergfxd ollama; do
  if sudo systemctl enable --now "$svc" 2>&1 | tail -1; then
    state=$(systemctl is-active "$svc")
    case "$state" in
      active) ok "$svc: $state" ;;
      *)      warn "$svc: $state" ;;
    esac
  fi
done

# =============================================================================
# 4. Charge limit + power profile (asusctl needs asusd running)
# =============================================================================
log "Configuring battery + profile..."
sleep 2  # let asusd settle
asusctl -c 80 2>/dev/null && ok "Charge limit: 80%" || warn "asusctl -c failed"
asusctl profile -P Balanced 2>/dev/null && ok "Profile: Balanced" || warn "profile cmd failed"

# =============================================================================
# 5. Firmware (refresh metadata, list updates, do not auto-apply)
# =============================================================================
log "Refreshing firmware metadata..."
sudo fwupdmgr refresh --force 2>&1 | tail -3 || true
echo
echo "=== Available firmware updates ==="
sudo fwupdmgr get-updates 2>&1 | tail -15 || true

# =============================================================================
# 6. Final state
# =============================================================================
echo
ok "=========================================================================="
ok "                       Finishing complete."
ok "=========================================================================="
echo
echo "  Service states:"
for s in fwupd power-profiles-daemon asusd supergfxd ollama; do
  printf "    %-25s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null)"
done
echo
echo "  Next steps:"
echo "    1. (Optional) Apply firmware:  sudo fwupdmgr update"
echo "    2. REBOOT to activate kernel params (gttsize=24576, etc.)"
echo "    3. At BIOS (F2): UMA Frame Buffer Size = Auto / minimum"
echo "    4. After reboot:"
echo "         ollama pull qwen2.5:14b-instruct-q5_K_M"
echo "         ollama create qwen14 -f ~/Modelfile-qwen"
echo "         ~/check-z13.sh"
echo
