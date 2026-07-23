// gz302ea-fetch — download + verify the GZ302EA Windows 11 driver pack (~11 GB)
//
// Pulls all 26 ASUS packages (drivers, BIOS 311 + EZ Flash image, firmware
// tools, Armoury Crate offline suite) from the ASUS CDN into the target
// directory (argument, default CWD) and verifies each against its
// ASUS-published SHA-256. Idempotent: files already present and verified are
// skipped. The embedded manifest is drift-tested against ../SHA256SUMS.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::time::Duration;

use sha2::{Digest, Sha256};

const CDN: &str = "https://dlcdnets.asus.com/pub/ASUS";
const MANIFEST: &str = include_str!("../../manifest.tsv");
const ATTEMPTS: u32 = 3;

const GRN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const BLU: &str = "\x1b[0;34m";
const RST: &str = "\x1b[0m";

fn info(msg: &str) {
    println!("{BLU}[*]{RST} {msg}");
}

fn ok(msg: &str) {
    println!("{GRN}[OK]{RST} {msg}");
}

fn fail(msg: &str) {
    println!("{RED}[!!]{RST} {msg}");
}

struct Entry {
    sha: &'static str,
    name: &'static str,
    path: &'static str,
}

fn manifest() -> Vec<Entry> {
    MANIFEST
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| {
            let mut f = l.split_whitespace();
            let (Some(sha), Some(name), Some(path), None) =
                (f.next(), f.next(), f.next(), f.next())
            else {
                panic!("malformed manifest line: {l}");
            };
            Entry { sha, name, path }
        })
        .collect()
}

fn sha256_file(name: &str) -> std::io::Result<String> {
    let mut file = File::open(name)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

fn verified(e: &Entry) -> bool {
    fs::metadata(e.name).is_ok_and(|m| m.is_file())
        && sha256_file(e.name).is_ok_and(|sha| sha == e.sha)
}

fn download(agent: &ureq::Agent, e: &Entry) -> Result<(), String> {
    let url = format!("{CDN}/{}", e.path);
    let mut last = String::new();
    for attempt in 1..=ATTEMPTS {
        if attempt > 1 {
            std::thread::sleep(Duration::from_secs(2));
        }
        match agent.get(&url).call() {
            Ok(resp) => {
                let total = resp
                    .header("Content-Length")
                    .and_then(|v| v.parse::<u64>().ok());
                return copy_body(resp.into_reader(), e.name, total)
                    .map_err(|err| format!("write {}: {err}", e.name));
            }
            // 4xx/5xx won't get better on retry; transport errors might.
            Err(ureq::Error::Status(code, _)) => return Err(format!("HTTP {code}: {url}")),
            Err(err) => last = err.to_string(),
        }
    }
    Err(format!("{last} ({ATTEMPTS} attempts): {url}"))
}

fn copy_body(mut body: impl Read, name: &str, total: Option<u64>) -> std::io::Result<()> {
    let mut out = File::create(name)?;
    let mut buf = vec![0u8; 1 << 20];
    let mut copied: u64 = 0;
    let mut shown: u64 = 0;
    loop {
        let n = body.read(&mut buf)?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n])?;
        copied += n as u64;
        // Progress line every 64 MiB so multi-GB files aren't silent.
        if copied - shown >= 64 << 20 {
            shown = copied;
            match total {
                Some(t) => print!("\r    {name}  {} / {} MiB", copied >> 20, t >> 20),
                None => print!("\r    {name}  {} MiB", copied >> 20),
            }
            std::io::stdout().flush()?;
        }
    }
    if shown > 0 {
        println!();
    }
    Ok(())
}

fn main() {
    if let Some(dir) = std::env::args().nth(1) {
        if let Err(err) = std::env::set_current_dir(&dir) {
            fail(&format!("cd {dir}: {err}"));
            std::process::exit(1);
        }
    }

    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(30))
        .timeout_read(Duration::from_secs(60))
        .build();

    let mut failed = 0u32;
    for e in manifest() {
        if verified(&e) {
            ok(&format!("{} (already verified)", e.name));
            continue;
        }
        info(&format!("fetching {}", e.name));
        if let Err(err) = download(&agent, &e) {
            let _ = fs::remove_file(e.name);
            fail(&format!("download: {err}"));
            failed += 1;
            continue;
        }
        if verified(&e) {
            ok(e.name);
        } else {
            let _ = fs::remove_file(e.name);
            fail(&format!("sha256 mismatch: {} (removed)", e.name));
            failed += 1;
        }
    }

    if failed == 0 {
        ok("all 26 packages present and verified");
    } else {
        fail(&format!("{failed} package(s) failed"));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    const SHA256SUMS: &str = include_str!("../../SHA256SUMS");

    #[test]
    fn manifest_parses_and_is_sane() {
        let m = manifest();
        assert_eq!(m.len(), 26);
        let names: BTreeSet<_> = m.iter().map(|e| e.name).collect();
        assert_eq!(names.len(), m.len(), "duplicate names");
        for e in &m {
            assert_eq!(e.sha.len(), 64, "bad sha for {}", e.name);
            assert!(
                e.sha
                    .chars()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
                "sha not lowercase hex for {}",
                e.name
            );
            assert!(!e.path.starts_with('/') && !e.path.contains(".."));
        }
    }

    #[test]
    fn manifest_matches_sha256sums() {
        let from_manifest: BTreeSet<_> = manifest().into_iter().map(|e| (e.sha, e.name)).collect();
        let from_sums: BTreeSet<_> = SHA256SUMS
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(|l| {
                let mut f = l.split_whitespace();
                (f.next().unwrap(), f.next().unwrap())
            })
            .collect();
        assert_eq!(
            from_manifest, from_sums,
            "manifest.tsv and SHA256SUMS drifted"
        );
    }
}
