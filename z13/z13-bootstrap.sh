#!/usr/bin/env bash
# z13-bootstrap — pipeline driver: setup → reboot → (run optimize after reboot)
#
# Usage:
#   z13-bootstrap                 # run setup, then reboot. Run z13_Optimize.sh
#                                 # manually after the machine comes back up.
#   z13-bootstrap --no-reboot     # run setup AND optimize inline (skip reboot).
#                                 # Useful for testing on an already-tuned host.

set -euo pipefail

PASS=0; FAIL=0
GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info() { printf '%s[*]%s %s\n'    "$BLU" "$RST" "$*"; }
ok()   { printf '%s[PASS]%s %s\n' "$GRN" "$RST" "$*"; ((++PASS)); }
warn() { printf '%s[WARN]%s %s\n' "$YLW" "$RST" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RST" "$*"; ((++FAIL)); }

[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"

MODE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Z13_SETUP="${SCRIPT_DIR}/z13-setup.sh"
Z13_OPT="${SCRIPT_DIR}/z13_Optimize.sh"

info "Z13 GZ302EA bootstrap * v1.0"
echo

# ── Preflight ──────────────────────────
for SCRIPT in "$Z13_SETUP" "$Z13_OPT"; do
  if [[ -f "$SCRIPT" ]]; then
    ok "found $SCRIPT"
  else
    fail "$SCRIPT missing"
    info "git clone <repo> ~/tools/z13 then try again"
    exit 1
  fi
done

# ── Step 1: setup ─────────────────────
info "Step 1: z13-setup"
bash "$Z13_SETUP" || { fail "setup failed"; exit 1; }

# ── Step 2: reboot OR skip ────────────
if [[ "$MODE" == "--no-reboot" ]]; then
  info "Step 2: skipping reboot (--no-reboot)"
  info "Step 3: z13_Optimize"
  bash "$Z13_OPT" || fail "optimize failed"
else
  info "Step 2: reboot in 10s — re-run z13_Optimize.sh after the machine is back up"
  sleep 10
  shutdown -r now
  exit 0
fi

if [[ $FAIL -eq 0 ]]; then
  ok "all done"
else
  warn "$FAIL item(s) failed"
fi

exit $FAIL
