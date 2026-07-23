// gz302ea-setup — one-command bring-up for the GZ302EA driver pack.
//
//   cargo install --git https://github.com/foolish-dev/tools gz302ea-setup
//   gz302ea-setup /mnt/usb        # target dir, default: CWD
//
// Builds the trilogy (fetch / distill / install), downloads + verifies all
// 26 ASUS packages (~11 GB) into the target dir, distills them to
// pnputil-ready payloads in Extracted/, and previews the Windows install
// plan. Idempotent — re-runs verify instead of re-doing. Run from a repo
// checkout it uses that checkout; installed standalone, it clones into
// ~/.cache/gz302ea-tools (git pull on re-runs).

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const REPO: &str = "https://github.com/foolish-dev/tools";

const GRN: &str = "\x1b[0;32m";
const RED: &str = "\x1b[0;31m";
const YLW: &str = "\x1b[1;33m";
const BLU: &str = "\x1b[0;34m";
const RST: &str = "\x1b[0m";

fn info(msg: &str) {
    println!("{BLU}[*]{RST} {msg}");
}

fn ok(msg: &str) {
    println!("{GRN}[OK]{RST} {msg}");
}

fn warn(msg: &str) {
    println!("{YLW}[!!]{RST} {msg}");
}

fn fail(msg: &str) {
    println!("{RED}[!!]{RST} {msg}");
}

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

fn run(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .status()
        .is_ok_and(|s| s.success())
}

fn run_quiet(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Package manager, for phrasing "missing dep" hints only.
fn pm_hint() -> &'static str {
    [
        "pacman",
        "apt",
        "dnf",
        "zypper",
        "apk",
        "xbps-install",
        "brew",
        "winget",
    ]
    .into_iter()
    .find(|pm| have(pm))
    .unwrap_or("your package manager")
}

/// GZ302EA source dir: the checkout this binary was built in, if it still
/// exists; otherwise a clone under ~/.cache.
fn source_dir() -> Result<PathBuf, String> {
    if let Ok(exe) = std::env::current_exe() {
        for dir in exe.ancestors() {
            if dir.join("fetch/Cargo.toml").is_file() && dir.join("manifest.tsv").is_file() {
                return Ok(dir.to_path_buf());
            }
        }
    }
    let home = std::env::var("HOME").map_err(|_| "HOME unset".to_string())?;
    let cache = Path::new(&home).join(".cache/gz302ea-tools");
    if cache.join(".git").is_dir() {
        info(&format!("updating {}", cache.display()));
        if !run_quiet(
            "git",
            &["-C", &cache.to_string_lossy(), "pull", "--ff-only", "-q"],
        ) {
            warn("git pull failed — using the cached checkout as-is");
        }
    } else {
        info(&format!("cloning {REPO}"));
        if !run(
            "git",
            &[
                "clone",
                "-q",
                "--depth",
                "1",
                REPO,
                &cache.to_string_lossy(),
            ],
        ) {
            return Err("git clone failed".into());
        }
    }
    Ok(cache.join("GZ302EA"))
}

fn tool(src: &Path, name: &str) -> PathBuf {
    src.join(name)
        .join("target/release")
        .join(format!("gz302ea-{name}"))
}

fn main() {
    let target = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().expect("cwd"));

    let pm = pm_hint();
    let mut missing = false;
    for cmd in ["git", "cargo"] {
        if !have(cmd) {
            fail(&format!("missing: {cmd} (install via {pm})"));
            missing = true;
        }
    }
    if !["7z", "7zz", "7za"].into_iter().any(have) {
        fail(&format!(
            "missing: 7-Zip (none of 7z/7zz/7za on PATH — install 7zip/p7zip via {pm})"
        ));
        missing = true;
    }
    if missing {
        std::process::exit(1);
    }
    if !(have("innoextract") || cfg!(unix) && have("wine")) {
        warn(&format!(
            "neither innoextract nor wine found — distill will skip the Inno-stream components (innoextract via {pm} fixes this on any OS)"
        ));
    }

    let src = match source_dir() {
        Ok(s) => s,
        Err(e) => {
            fail(&e);
            std::process::exit(1);
        }
    };
    ok(&format!("tools source: {}", src.display()));

    for crate_name in ["fetch", "distill", "install"] {
        info(&format!("building gz302ea-{crate_name}"));
        let manifest = src.join(crate_name).join("Cargo.toml");
        if !run(
            "cargo",
            &[
                "build",
                "--release",
                "--locked",
                "--quiet",
                "--manifest-path",
                &manifest.to_string_lossy(),
            ],
        ) {
            fail(&format!("cargo build gz302ea-{crate_name}"));
            std::process::exit(1);
        }
    }

    if std::fs::create_dir_all(&target).is_err() {
        fail(&format!("cannot create {}", target.display()));
        std::process::exit(1);
    }
    let target_s = target.to_string_lossy().into_owned();
    info(&format!("pack target: {target_s} (~11 GB)"));

    let mut failed = false;
    for step in ["fetch", "distill"] {
        if !run(&tool(&src, step).to_string_lossy(), &[&target_s]) {
            fail(step);
            failed = true;
        }
    }

    info("Windows install plan (preview):");
    if run_quiet(
        &tool(&src, "install").to_string_lossy(),
        &["--dry-run", &target_s],
    ) {
        ok("gz302ea-install --dry-run ok — run gz302ea-install elevated on Windows");
    } else {
        warn("install preview incomplete (distill skipped components?)");
    }

    if !failed {
        ok(&format!(
            "done. next: copy '{target_s}' to USB → install Windows → run gz302ea-install"
        ));
        info(
            "OOBE offline Wi-Fi: Shift+F10 → pnputil /add-driver <usb>\\Extracted\\WLAN_MediaTek\\WLAN\\mtkwecx.inf /install",
        );
        info("afterwards by hand: BIOS 311 / firmware tools / Armoury Crate full package");
    }
    std::process::exit(i32::from(failed));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_paths_are_inside_the_source_dir() {
        let src = Path::new("/x/GZ302EA");
        assert_eq!(
            tool(src, "fetch"),
            Path::new("/x/GZ302EA/fetch/target/release/gz302ea-fetch")
        );
    }

    #[test]
    fn pm_hint_never_panics() {
        let _ = pm_hint();
    }
}
