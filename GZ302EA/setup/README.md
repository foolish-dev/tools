# gz302ea-setup

One-command bring-up for the GZ302EA Windows 11 driver pack — the Rust
replacement for `setup.sh`.

```text
❯ cargo install --git https://github.com/foolish-dev/tools gz302ea-setup
❯ gz302ea-setup /mnt/usb   # target dir, default: CWD
```

Checks deps (git, cargo, any 7-Zip flavor; recommends innoextract when
neither it nor wine is present — hints phrased for whatever package
manager it detects), resolves the tools source (the checkout it was built
in, else a shallow clone under `~/.cache/gz302ea-tools`, pulled on
re-runs), builds [fetch](../fetch) / [distill](../distill) /
[install](../install), downloads + verifies all 26 ASUS packages (~11 GB)
into the target, distills them to pnputil-ready payloads in `Extracted/`,
and previews the Windows install plan. Idempotent end to end — re-runs
verify instead of re-doing.
