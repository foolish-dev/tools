[![per-machine bring-up · hardware-specific tuning · idempotent, re-run safe · arch linux, terminal-first](https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=20&duration=2800&pause=600&color=7AA2F7&center=true&vCenter=true&width=720&lines=%2F%2F+per-machine+bring-up+scripts;%2F%2F+hardware-specific+tuning;%2F%2F+idempotent%2C+re-run+safe;%2F%2F+arch+linux%2C+terminal-first)](https://github.com/foolish-dev/tools)

> *bring-up · tuning · verification*  ·  rust · bash · systemd-boot · sysctl · udev

![Arch Linux](https://img.shields.io/badge/Arch_Linux-7aa2f7?style=flat-square&logo=archlinux&logoColor=1a1b26)
![Rust](https://img.shields.io/badge/Rust-e0af68?style=flat-square&logo=rust&logoColor=1a1b26)
![Bash](https://img.shields.io/badge/Bash-9ece6a?style=flat-square&logo=gnubash&logoColor=1a1b26)
![systemd](https://img.shields.io/badge/systemd-bb9af7?style=flat-square&logoColor=1a1b26)
![AMD](https://img.shields.io/badge/AMD-ff9e64?style=flat-square&logo=amd&logoColor=1a1b26)
![Strix Halo](https://img.shields.io/badge/Strix_Halo-7dcfff?style=flat-square&logoColor=1a1b26)

---

```text
~/tools ❯ tree -L 1

.
├── GZ302EA/  ROG Flow Z13 (2025) — Windows 11 driver pack: manifest + fetcher
├── z13/      GZ302EA (Strix Halo, 32 GB UMA) — setup → reboot → optimize
└── README.md

target        arch linux, idempotent re-runs are safe
discipline    measure twice, patch once
ethos         each change gated on detection of already-correct state
```

---

### ❯ z13

<sub>// ASUS ROG Flow Z13 GZ302EA-RU004W — Strix Halo APU (Radeon 8060S, gfx1151), 32 GB UMA</sub>

**[`z13.sh`](z13/z13.sh)** — single-script pipeline. Hardware detection, ROCm/HIP packages (`rocm-opencl-runtime`, `rocm-device-libs`, `hip-runtime-amd`), AMDGPU udev rule, systemd-boot cmdline patch (`ttm.pages_limit=5242880` → 20 GB iGPU VRAM cap), `systemd-networkd-wait-online` mask, `systemd-oomd` enable, `vm.watermark_scale_factor=100`, verification pass.

```text
~/tools ❯ sudo ./z13/z13.sh                  # setup → reboot
~/tools ❯ sudo ./z13/z13.sh --optimize       # post-reboot optimization + verification
~/tools ❯ sudo ./z13/z13.sh --no-reboot      # setup + optimize inline (testing)
~/tools ❯ sudo ./z13/z13.sh --status         # verify current state without making changes
~/tools ❯ sudo ./z13/z13.sh --fix-touchpad   # rebind/uninhibit touchpad frozen by armoury crate
```

Each step is gated on detection of the already-correct state — re-running is a no-op.

---

### ❯ GZ302EA

<sub>// same machine, other OS — offline Windows 11 driver + firmware pack</sub>

Three Rust tools — **[`gz302ea-fetch`](GZ302EA/fetch)** (download + verify all 26 ASUS packages, ~11 GB, against their ASUS-published SHA-256s; rustls + sha2, no curl), **[`gz302ea-distill`](GZ302EA/distill)** (installers → pnputil-ready INF payloads via 7z overlay / wine silent-install), **[`gz302ea-install`](GZ302EA/install)** (Windows-side: stages every driver INF via pnputil in dependency order — the ASUS installer exes, replaced). Manifest drift-tested end to end; everything idempotent; runs on any distro or macOS (distill prefers `innoextract`, falls back to wine on unix — never executes installers natively). One line runs the whole prep side:

```text
~/tools ❯ curl -fsSL https://raw.githubusercontent.com/foolish-dev/tools/main/GZ302EA/setup.sh | bash -s -- /mnt/usb
```

[`README`](GZ302EA/README.md) covers install order, distilling the Inno installers into pnputil-ready INF trees (7z overlay / wine silent-install) for the 24H2 offline-OOBE dance, and the traps: the BIOS-capsule INF that must stay out of bulk driver sweeps, and the PD/keyboard firmware tools that are online-only downloader harnesses.

---

### ❯ Conventions

<sub>// rules every tool in this repo follows, so re-runs and partial failures stay boring</sub>

- **idempotent.** Detect the desired state first, change only if absent.
- **`set -euo pipefail`.** Fail loud, fail early, fail with a line number.
- **root-escalation in-script.** `[[ $EUID -ne 0 ]] && exec sudo -E "$0" "$@"` — no manual `sudo` dance.
- **backups before mutation.** Anything edited in `/boot` or `/etc` gets a timestamped `.bak`.
- **FAIL counter.** Coloured output, non-zero exit on FAIL.

---

### ❯ Reach me

[![email cardoffools at gmail dot com](https://img.shields.io/badge/cardoffools%40gmail.com-7aa2f7?style=flat-square&logo=gmail&logoColor=1a1b26&labelColor=24283b)](mailto:cardoffools@gmail.com)
[![Follow foolish-dev on GitHub](https://img.shields.io/github/followers/foolish-dev?style=flat-square&logo=github&logoColor=c0caf5&label=follow&labelColor=24283b&color=bb9af7)](https://github.com/foolish-dev)

---

<sub>// keep building, keep breaking</sub>
