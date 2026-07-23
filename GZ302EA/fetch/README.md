# gz302ea-fetch

Download + verify the GZ302EA Windows 11 driver pack (~11 GB, 26 ASUS
packages) from the ASUS CDN.

```text
❯ cargo build --release
❯ ./target/release/gz302ea-fetch [dir]   # default: CWD
```

- Pure Rust: `ureq` (rustls) + `sha2` — no curl, bash, coreutils, or system
  TLS. Builds on stock Arch (`pacman -S rust`) and on Windows.
- Every file is checked against the SHA-256 ASUS publishes in its support
  API. Already-present, already-verified files are skipped — re-running is a
  verify pass. Mismatches are deleted and reported; exit is non-zero if
  anything failed.
- Transport errors retry 3×; HTTP errors don't (they won't get better).
  Multi-GB files print a progress line every 64 MiB.
- The manifest ([`../manifest.tsv`](../manifest.tsv): sha + local name + CDN
  path) is embedded at compile time. `cargo test` drift-checks it against
  [`../SHA256SUMS`](../SHA256SUMS), which is kept for plain `sha256sum -c`.
  One rename is deliberate: the Dolby Atmos package has an opaque CDN name
  (`ASUS_Z_V10.806…`) and is stored under a readable one.

Part of the [GZ302EA pack tooling](../README.md):
fetch → [distill](../distill) → [install](../install).
