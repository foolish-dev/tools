# z13

Setup + optimize for the ASUS ROG Flow Z13 GZ302EA-RU004W on Arch Linux —
Rust port of the original `z13.sh`, behavior-faithful.

```text
❯ cargo build --release
❯ ./target/release/z13                  # setup → reboot; then --optimize
❯ ./target/release/z13 --optimize       # post-reboot optimization + verification
❯ ./target/release/z13 --no-reboot      # setup + optimize inline (testing)
❯ ./target/release/z13 --status         # verify current state, read-only
❯ ./target/release/z13 --fix-touchpad   # rebind/uninhibit touchpad frozen by armoury crate
```

What it manages: ROCm/HIP packages, the AMDGPU DPM udev rule, the
systemd-boot cmdline patch (`ttm.pages_limit=5242880` → 20 GB iGPU VRAM
cap, `.bak` preserved on first patch), `systemd-networkd-wait-online`
mask, `systemd-oomd`, `vm.watermark_scale_factor=100`, z13ctl udev rules +
ryzen_smu drop-in for the ROG key, and the hid-generic→hid-multitouch
touchpad rebind (udev rule for future bind events + immediate fix).

Every step is gated on detection of the already-correct state — re-running
is a no-op. Mutating modes self-escalate via sudo; `--status` runs
unprivileged (a deliberate deviation from the bash version). The
bootloader options-line patch is a pure function pinned by tests,
including idempotence.
