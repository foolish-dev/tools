# gz302ea-distill

Distill the downloaded ASUS installers into raw payloads under `Extracted/`
— 22 components, 201 INFs, ready for `pnputil`/DISM without running a single
GUI installer.

```text
❯ cargo build --release
❯ ./target/release/gz302ea-distill [dir]   # dir = pack dir, default: CWD
```

Needs `7z` on PATH; wine-method components additionally need `wine`
(skipped with a warning if absent). Every ASUS package is an Inno Setup exe;
three techniques cover all of them:

- **7z overlay** — eight packages keep their payload 7z-readable in the PE
  overlay (GPU, Realtek audio, WLAN, BT, MEP, ASCI, BIOS updater, EZ Flash
  zip): extracted directly.
- **wine silent install** — the rest run with
  `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\payload\<comp>` in a
  throwaway prefix (`~/.cache/gz302ea-distill`, removed afterwards), payload
  copied out. 300 s kill-timeout: the light-bar tool hangs in `[Run]` after
  its payload has landed.
- **wine + `{tmp}` capture** — the PD/keyboard firmware packages stage into
  Inno's self-deleting `{tmp}`: their staging is poll-copied while the
  installer runs, then Inno copy artifacts are dropped. Stale staging from
  earlier killed installers is cleared first — otherwise a later capture
  sweeps the wrong package's files.

Idempotent: components whose output dir already has files are skipped.
`cargo test` checks the component table against
[`../manifest.tsv`](../manifest.tsv).

**Capsule warning:** `Extracted/FW_BIOS_Updater/` contains BIOS 311 as a
UEFI capsule INF — injecting it with pnputil stages a firmware flash. Keep
it out of bulk sweeps ([install](../install) refuses it by test).

Part of the [GZ302EA pack tooling](../README.md):
[fetch](../fetch) → distill → [install](../install).
