# gz302ea-install

Apply the distilled GZ302EA driver payloads on Windows — the Rust
replacement for running seventeen ASUS installer exes by hand.

```text
PS> .\gz302ea-install.exe <pack-dir>            # elevated prompt
❯  gz302ea-install --dry-run [dir]              # prints the plan, any OS
```

- Walks `Extracted/` in dependency order — chipset first, then GPU,
  WLAN/BT, the audio stack (Realtek, Cirrus SmartAMP, Dolby Atmos), ASCI,
  Armoury Crate CI, Smart Display Control, touchpad, camera + NPU effects,
  card reader, USB4 retimer — staging every driver INF via
  `pnputil /add-driver <inf> /install`. Smart Display Control ships as a
  clean MSI and goes through `msiexec /qn /norestart`.
- 200 of the pack's 201 INFs are staged. The one exception and the whole
  firmware family are pinned by tests as never-installed: the BIOS capsule
  INF (stages a firmware flash on boot), the PD/keyboard/light-bar tools
  (run those exes directly), and the app payloads (own installers).
- WLAN and BT carry the identical MediaTek payload; pnputil no-ops the
  second copy.
- Applying refuses to run off-Windows; `--dry-run` works anywhere and shows
  the exact commands. Exit is non-zero if any component fails. Reboot when
  it's done.

Cross-compile from Linux with the `x86_64-pc-windows-gnu` target, or build
on Windows with stock stable — the crate is dependency-free.

Part of the [GZ302EA pack tooling](../README.md):
[fetch](../fetch) → [distill](../distill) → install.
